import { Env, CompositeIdentity, ApiResponse } from '../types';
import { getDocument, setDocument, commitAtomicWrites, queryCollection, logAuditEvent } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateShortId, generateSignedLeaseToken } from '../cryptoEngine';

/**
 * Handles POST /api/v1/customers/register
 * Onboards a new vendor on first launch, creates immutable cus_xxxxxxxxx, composite inst_xxxxxxxxx,
 * and grants a 30-day DEMO_FREE subscription where activeInstallationId == inst_xxxxxxxxx.
 * See API_SPECIFICATION.md Section 2.2 & FIRESTORE_SCHEMA.md Section 3.2, 3.3, 3.4.
 */
export async function handleCustomerRegistration(
  request: Request,
  env: Env,
  identity: CompositeIdentity
): Promise<Response> {
  if (request.method !== 'POST') {
    return createErrorResponse(405, 'METHOD_NOT_ALLOWED', 'Only POST method is permitted on /api/v1/customers/register.');
  }

  // 1. Check global system configuration flags (`system_configs/global`)
  try {
    const sysConfig = await getDocument(env, 'system_configs', 'global');
    if (sysConfig) {
      if (sysConfig.maintenanceMode === true) {
        return createErrorResponse(
          503,
          'MAINTENANCE_MODE',
          sysConfig.maintenanceMessage || 'VendSoft servers are undergoing scheduled maintenance. Offline billing continues normally.'
        );
      }
      if (sysConfig.allowRegistrations === false) {
        return createErrorResponse(
          403,
          'REGISTRATIONS_DISABLED',
          'New customer registration is currently disabled by system administrators.'
        );
      }
    }
  } catch (err) {
    console.warn('System config check warning during onboarding:', err);
  }

  // 2. Check Idempotency Key deduplication lock (`idempotency_keys/{keyId}`)
  const idempotencyKey = identity.idempotencyKey;
  if (idempotencyKey) {
    try {
      const existingIdem = await getDocument(env, 'idempotency_keys', idempotencyKey);
      if (existingIdem && existingIdem.expiresAtEpochMs > Date.now() && existingIdem.responsePayload) {
        let cachedData: any;
        try {
          cachedData = JSON.parse(existingIdem.responsePayload);
        } catch (e) {
          cachedData = existingIdem.responsePayload;
        }
        return new Response(JSON.stringify({ success: true, data: cachedData }), {
          status: 200,
          headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
        });
      }
    } catch (err) {
      console.warn('Idempotency lookup warning:', err);
    }
  }

  // 3. Parse and validate request body payload
  let body: any;
  try {
    body = await request.json();
  } catch (err) {
    return createErrorResponse(400, 'INVALID_JSON', 'Request body must be a valid JSON object.');
  }

  // Handle both `phoneNumber` (from older Flutter app) and `mobileNumber`
  const inputMobileNumber = (body.mobileNumber || body.phoneNumber || '').trim();
  const businessName = (body.businessName || '').trim();
  const ownerName = (body.ownerName || '').trim();

  if (!businessName || !ownerName || !inputMobileNumber) {
    return createErrorResponse(
      400,
      'MISSING_REQUIRED_FIELDS',
      'Payload must contain businessName, ownerName, and mobileNumber.'
    );
  }

  const now = Date.now();
  const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;

  // 4. Strict One-Device Limit: Check by Mobile Number FIRST
  try {
    const existingCustomers = await queryCollection(env, 'customers', [
      { field: 'mobileNumber', op: 'EQUAL', value: inputMobileNumber }
    ]);

    if (existingCustomers && existingCustomers.length > 0) {
      const oldCust = existingCustomers[0];

      if (oldCust.status === 'DEACTIVATED') {
        return createErrorResponse(403, 'CUSTOMER_DEACTIVATED', 'This account has been deactivated by the administrator.');
      }

      // Fetch their subscriptions
      const subs = await queryCollection(env, 'subscriptions', [
        { field: 'customerId', op: 'EQUAL', value: oldCust.customerId }
      ]);

      let latestSub: any = null;
      if (subs && subs.length > 0) {
        subs.sort((a: any, b: any) => (b.createdAtEpochMs || 0) - (a.createdAtEpochMs || 0));
        latestSub = subs[0];
      } else {
        // Fallback: Check if they have a hardware trial
        const trials = await queryCollection(env, 'hardware_trials', [
          { field: 'customerId', op: 'EQUAL', value: oldCust.customerId }
        ]);
        if (trials && trials.length > 0) {
          const trial = trials[0];
          latestSub = {
            subscriptionId: `TRIAL_${trial.hardwareId}`,
            planId: 'FREE_TRIAL_30',
            activeInstallationId: trial.hardwareId,
            status: Date.now() > trial.expiresAtEpochMs ? 'EXPIRED' : 'ACTIVE',
            expiresAtEpochMs: trial.expiresAtEpochMs
          };
        }
      }

      if (latestSub) {
        if (latestSub.activeInstallationId === identity.hardwareId || latestSub.activeInstallationId === identity.installationId) {
          let token = latestSub.signedLeaseToken;
          
          // If this is a trial recovery, the token wasn't saved in DB, so generate it on the fly
          if (!token && latestSub.planId === 'FREE_TRIAL_30') {
            const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
            const leasePayload = {
              subscriptionId: latestSub.subscriptionId,
              customerId: oldCust.customerId,
              activeInstallationId: latestSub.activeInstallationId,
              planId: latestSub.planId,
              planName: '30-Day Pro Trial',
              startsAtEpochMs: latestSub.expiresAtEpochMs - (30 * 24 * 60 * 60 * 1000),
              expiresAtEpochMs: latestSub.expiresAtEpochMs,
              maxCustomers: 10000,
              allowWhatsAppAutoSend: true,
              allowThermalPrinting: true,
              issuedAt: Date.now()
            };
            token = await generateSignedLeaseToken(leasePayload, secretKey);
          }

          const cachedData = {
            customerId: oldCust.customerId,
            installationId: latestSub.activeInstallationId,
            subscriptionId: latestSub.subscriptionId,
            planId: latestSub.planId,
            activeInstallationId: latestSub.activeInstallationId,
            status: latestSub.status,
            expiresAtEpochMs: latestSub.expiresAtEpochMs,
            signedLeaseToken: token
          };
          return new Response(JSON.stringify({ success: true, data: cachedData, message: 'Account recovered successfully.' }), {
            status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
          });
        } else {
          // DIFFERENT DEVICE: TRANSFER REQUIRED!
          return createErrorResponse(403, 'TRANSFER_REQUIRED', `This phone number is registered to another device. Please request a transfer.`);
        }
      }
      
      return createErrorResponse(400, 'ACCOUNT_ERROR', 'Account exists but has no subscriptions or trials. Please contact support.');
    }
  } catch (err: any) {
    console.error('Database error during mobileNumber lookup:', err);
    return createErrorResponse(500, 'DB_ERROR', 'Failed to verify account uniqueness. Please try again.');
  }

  // 4.5. Hardware-Locked Trial Check
  let trialStartsAt = now;
  let trialExpiresAt = now + THIRTY_DAYS_MS;
  let isHardwareTrialExpired = false;

  try {
    // Check if this physical hardware OR this specific installation UUID has already claimed a trial
    const hardwareTrials = await queryCollection(env, 'hardware_trials', [
      { field: 'hardwareId', op: 'EQUAL', value: identity.hardwareId }
    ]);
    
    let hardwareTrialDoc = await getDocument(env, 'hardware_trials', identity.hardwareId);
    
    if (!hardwareTrialDoc && hardwareTrials && hardwareTrials.length > 0) {
      hardwareTrialDoc = hardwareTrials[0];
    }

    if (hardwareTrialDoc) {
      // If they already claimed a trial on this device, we DO NOT give them a fresh 30 days
      // even if they entered a brand new phone number.
      trialStartsAt = hardwareTrialDoc.startedAtEpochMs || now;
      trialExpiresAt = hardwareTrialDoc.expiresAtEpochMs || (now + THIRTY_DAYS_MS);
      if (now > trialExpiresAt) {
        isHardwareTrialExpired = true;
      }
    }
  } catch(err) {
     console.error('Hardware Trial check error:', err);
     return createErrorResponse(500, 'DB_ERROR', 'Failed to verify hardware trial status.');
  }

  // 5. Generate immutable entity keys (`cus_xxxxxxxxx`, `inst_xxxxxxxxx`)
  const customerId = `cus_${generateShortId()}`;
  const installationId = identity.installationId || identity.installationUuid || `inst_${generateShortId()}`;

  // 6. Generate cryptographic signedLeaseToken using Web Crypto HMAC-SHA256
  const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
  const leasePayload = {
    subscriptionId: `TRIAL_${installationId}`,
    customerId,
    activeInstallationId: installationId,
    planId: 'FREE_TRIAL_30',
    planName: '30-Day Pro Trial',
    startsAtEpochMs: trialStartsAt,
    expiresAtEpochMs: trialExpiresAt,
    maxCustomers: 10000,
    allowWhatsAppAutoSend: true,
    allowThermalPrinting: true,
    issuedAt: now
  };
  const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

  // 6. Write records atomically to Google Cloud Firestore using commitAtomicWrites (`:commit`)
  const responsePayloadData = {
    customerId,
    installationId,
    subscriptionId: `TRIAL_${installationId}`,
    planId: 'FREE_TRIAL_30',
    activeInstallationId: installationId,
    status: isHardwareTrialExpired ? 'EXPIRED' : 'ACTIVE',
    expiresAtEpochMs: trialExpiresAt,
    signedLeaseToken
  };

  const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any>; requireDoesNotExist?: boolean }> = [
    {
      collectionPath: 'customers',
      documentId: customerId,
      data: {
        customerId,
        mobileNumber: body.mobileNumber.trim(),
        ownerName: body.ownerName.trim(),
        businessName: body.businessName.trim(),
        city: body.city ? body.city.trim() : null,
        status: 'ACTIVE',
        createdAtEpochMs: now,
        updatedAtEpochMs: now
      }
    },
    {
      collectionPath: 'installations',
      documentId: installationId,
      data: {
        installationId,
        customerId,
        hardwareId: identity.hardwareId,
        installationUuid: identity.installationUuid,
        firebaseUid: identity.uid,
        platform: identity.platform,
        appVersion: identity.appVersion,
        deviceModel: body.deviceModel ? body.deviceModel.trim() : null,
        status: 'ACTIVE',
        isBanned: false,
        createdAtEpochMs: now,
        lastSeenAtEpochMs: now
      }
    },
    {
      collectionPath: 'hardware_trials',
      documentId: identity.hardwareId,
      data: {
        hardwareId: identity.hardwareId,
        startedAtEpochMs: trialStartsAt,
        expiresAtEpochMs: trialExpiresAt,
        customerId: customerId,
        trialUsed: true
      }
    }
  ];

  if (idempotencyKey) {
    batchWrites.push({
      collectionPath: 'idempotency_keys',
      documentId: idempotencyKey,
      data: {
        keyId: idempotencyKey,
        expiresAtEpochMs: now + (24 * 3600000), // 24 hours
        responsePayload: JSON.stringify(responsePayloadData)
      },
      requireDoesNotExist: true // Prevents concurrent race condition duplicate entity creation
    });
  }

  try {
    await commitAtomicWrites(env, batchWrites);

    const responseWrapper: ApiResponse = {
      success: true,
      data: responsePayloadData
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 201,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      }
    });
  } catch (err: any) {
    // If two requests raced with the exact same idempotencyKey, the second fails precondition (`ALREADY_EXISTS`)
    if (err.code === 'ALREADY_EXISTS' && idempotencyKey) {
      try {
        const existingIdem = await getDocument(env, 'idempotency_keys', idempotencyKey);
        if (existingIdem && existingIdem.responsePayload) {
          let cachedData: any;
          try {
            cachedData = JSON.parse(existingIdem.responsePayload);
          } catch (e) {
            cachedData = existingIdem.responsePayload;
          }
          return new Response(JSON.stringify({ success: true, data: cachedData }), {
            status: 200,
            headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
          });
        }
      } catch (lookupErr) {
        console.warn('Fallback idempotency lookup failed:', lookupErr);
      }
    }

    console.error('Error committing onboarding records to Firestore:', err);
    return createErrorResponse(
      500,
      'REGISTRATION_FAILED',
      `Failed to create customer and subscription records: ${err.message || err}`
    );
  }
}


