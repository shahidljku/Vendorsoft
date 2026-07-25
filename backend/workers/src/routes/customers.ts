import { Env, CompositeIdentity, ApiResponse } from '../types';
import { getDocument, setDocument, commitAtomicWrites, queryCollection, logAuditEvent } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateShortId, generateSignedLeaseToken } from '../cryptoEngine';
import { findSubscription, DiscoveryStrategy } from '../services/discovery';
import { InstallationFSM } from '../services/fsm/installationFSM';
import { InstallationService } from '../services/installationService';

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

  // Handle security headers for hardware fingerprint
  const reqHardwareId = request.headers.get('x-hardware-id');
  const nonce = request.headers.get('x-registration-nonce');
  const timestampStr = request.headers.get('x-timestamp');
  const ipAddress = request.headers.get('cf-connecting-ip') || 'unknown';

  if (!reqHardwareId || !/^[A-F0-9]{32,64}$/.test(reqHardwareId)) {
    return createErrorResponse(400, 'INVALID_HARDWARE_ID', 'Missing or invalid hardware identifier format.');
  }

  if (nonce && timestampStr) {
    const reqTime = parseInt(timestampStr, 10);
    if (isNaN(reqTime) || Math.abs(Date.now() - reqTime) > 5 * 60 * 1000) {
      return createErrorResponse(403, 'REPLAY_DETECTED', 'Registration request expired or invalid.');
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
  const rawMobileNumber = (body.mobileNumber || body.phoneNumber || '').trim();
  const inputMobileNumber = rawMobileNumber.replace(/\D/g, ''); // Strip non-numeric

  // Pillar 4: Payload Bloat Protection
  const businessName = (body.businessName || '').trim().substring(0, 100);
  const ownerName = (body.ownerName || '').trim().substring(0, 100);

  if (!businessName || !ownerName || !inputMobileNumber) {
    return createErrorResponse(
      400,
      'MISSING_REQUIRED_FIELDS',
      'Payload must contain businessName, ownerName, and mobileNumber.'
    );
  }

  // Pillar 10: Strict Phone Validation
  if (!/^\d{10}$/.test(inputMobileNumber)) {
    return createErrorResponse(
      400,
      'INVALID_MOBILE_NUMBER',
      'Mobile number must be exactly 10 digits.'
    );
  }

  const recoverOnly = body.recoverOnly === true;

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
      const { sub: foundSub } = await findSubscription(env, oldCust.customerId, DiscoveryStrategy.CUSTOMER_UPDATE);
      let latestSub = foundSub;

      if (!latestSub) {
        // The user exists but has no subscriptions or trials (e.g. they were completely deleted).
        // Synthesize a CANCELLED subscription so the frontend allows them to log in and purchase a plan.
        latestSub = {
          subscriptionId: `SUB_NONE_${oldCust.customerId}`,
          planId: 'FREE_TRIAL_30',
          activeInstallationId: reqHardwareId || identity.installationId,
          status: 'CANCELLED',
          expiresAtEpochMs: 0
        };
      }

      if (latestSub) {
        let isSameDevice = (latestSub.activeInstallationId === reqHardwareId || latestSub.activeInstallationId === identity.installationId);
        
        // Data healing for legacy trials that were missing hardwareId
        if (!latestSub.activeInstallationId && latestSub.planId === 'FREE_TRIAL_30') {
          isSameDevice = true;
          try {
            await setDocument(env, 'hardware_trials', reqHardwareId, {
              hardwareId: reqHardwareId,
              startedAtEpochMs: latestSub.expiresAtEpochMs - (30 * 24 * 60 * 60 * 1000),
              expiresAtEpochMs: latestSub.expiresAtEpochMs,
              customerId: oldCust.customerId,
              trialUsed: true
            });
          } catch(e) {}
        }

        if (!isSameDevice) {
          const activeInst = await getDocument(env, 'installations', latestSub.activeInstallationId);
          if (activeInst && activeInst.hardwareId === reqHardwareId) {
            isSameDevice = true;
          } else if (latestSub.status === 'EXPIRED' || latestSub.status === 'CANCELLED' || (latestSub.expiresAtEpochMs && now > latestSub.expiresAtEpochMs)) {
            // If subscription is dead, allow login on new device so they can purchase a new one
            isSameDevice = true;
            if (latestSub.planId !== 'FREE_TRIAL_30') {
              latestSub.activeInstallationId = reqHardwareId || identity.installationId;
              latestSub.updatedAtEpochMs = now;
              await setDocument(env, 'subscriptions', latestSub.subscriptionId, latestSub);
            }
          }
        }

        if (isSameDevice) {
          let token = latestSub.signedLeaseToken;
          
          // If this is a trial recovery or synthetic, the token wasn't saved in DB, so generate it on the fly
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

          if (body.fcmToken) {
            const existingInst = await getDocument(env, 'installations', latestSub.activeInstallationId);
            if (existingInst) {
              const updatedInst = {
                ...existingInst,
                fcmToken: body.fcmToken,
                lastSeenAtEpochMs: Date.now()
              };
              await setDocument(env, 'installations', latestSub.activeInstallationId, updatedInst);
            }
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
    }
  } catch (err: any) {
    console.error('Database error during mobileNumber lookup:', err);
    return createErrorResponse(500, 'DB_ERROR', 'Failed to verify account uniqueness. Please try again.');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 4.5. MULTI-LAYER HARDWARE-LOCKED TRIAL CHECK
  // ═══════════════════════════════════════════════════════════════════════════
  let trialStartsAt = now;
  let trialExpiresAt = now + THIRTY_DAYS_MS;
  let isHardwareTrialExpired = false;

  try {
    await InstallationService.checkHardwareTrialEligibility(env, reqHardwareId, identity, inputMobileNumber, businessName, ipAddress, request.headers.get('x-app-version') || 'unknown');
  } catch(err: any) {
    if (err.code === 'TRIAL_ALREADY_USED') {
      return createErrorResponse(409, 'TRIAL_ALREADY_USED', err.message);
    }
    console.error('Hardware Trial check error:', err);
    return createErrorResponse(500, 'DB_ERROR', 'Failed to verify hardware trial status.');
  }

  if (recoverOnly) {
    return createErrorResponse(404, 'NO_CUSTOMER_FOUND', 'No active account found with this mobile number. Please register as a new user.');
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
      collectionPath: 'hardware_trials',
      documentId: reqHardwareId,
      data: {
        hardwareId: reqHardwareId,
        installationUuid: identity.installationUuid,
        firebaseUid: identity.uid,
        mobileNumber: inputMobileNumber,
        startedAtEpochMs: trialStartsAt,
        expiresAtEpochMs: trialExpiresAt,
        customerId: customerId,
        trialUsed: true,
        lastSeenAtEpochMs: now,
      },
      requireDoesNotExist: true // Guarantees atomic one-time trial creation
    }
  ];

  const activationOp = InstallationService.buildActivation(
    installationId,
    customerId,
    reqHardwareId,
    identity,
    body.deviceModel ? body.deviceModel.trim() : null,
    body.fcmToken || null,
    now
  );
  batchWrites.push(...activationOp.writes);

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

    // SUCCESS AUDIT LOG
    await logAuditEvent(env, 'REGISTRATION_SUCCESS', {
        actorType: 'USER',
        actorId: identity.customerId || 'unknown',
        targetType: 'hardware_trials',
        targetId: reqHardwareId,
        details: 'Issued new hardware trial.',
        timestampMs: now,
        mobileNumber: inputMobileNumber,
        businessName: businessName,
        ipAddress,
        appVersion: request.headers.get('x-app-version') || 'unknown'
    });

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

export async function handleUpdateFcmToken(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    if (!identity.installationId) {
      return createErrorResponse(400, 'MISSING_INSTALLATION_ID', 'Missing x-installation-uuid');
    }
    const body = await request.json() as any;
    const fcmToken = typeof body.fcmToken === 'string' ? body.fcmToken.substring(0, 255) : body.fcmToken;
    if (!fcmToken) {
      return createErrorResponse(400, 'MISSING_FCM_TOKEN', 'Missing fcmToken in body');
    }

    const instDoc = await getDocument(env, 'installations', identity.installationId);
    if (instDoc) {
      if (instDoc.fcmToken !== fcmToken) {
        const updated = { ...instDoc, fcmToken, lastSeenAtEpochMs: Date.now() };
        await setDocument(env, 'installations', identity.installationId, updated);
      }
    } else {
      // If it doesn't exist, we could create it, but usually registration creates it.
      await setDocument(env, 'installations', identity.installationId, {
        installationId: identity.installationId,
        hardwareId: identity.hardwareId,
        customerId: identity.customerId || 'UNKNOWN',
        deviceModel: 'Unknown',
        fcmToken,
        createdAtEpochMs: Date.now(),
        lastSeenAtEpochMs: Date.now()
      });
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error updating FCM token:', err);
    return createErrorResponse(500, 'FCM_UPDATE_FAILED', 'Failed to update FCM token');
  }
}

export async function handleCustomerLogout(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  const installationId = identity.installationId || identity.installationUuid;
  if (!installationId) {
    return createErrorResponse(400, 'MISSING_INSTALLATION_ID', 'Missing installation UUID.');
  }

  try {
    const inst = await getDocument(env, 'installations', installationId);
    if (inst) {
      inst.fcmToken = null;
      inst.updatedAtEpochMs = Date.now();
      await setDocument(env, 'installations', installationId, inst);
    }
  } catch (err) {
    console.error('Error logging out from server:', err);
  }

  return new Response(JSON.stringify({ success: true, message: 'Logged out successfully' }), {
    status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
  });
}

