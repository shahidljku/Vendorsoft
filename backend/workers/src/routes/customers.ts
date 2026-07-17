import { Env, CompositeIdentity, ApiResponse } from '../types';
import { getDocument, setDocument, commitAtomicWrites } from '../services/firestore';
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
  let body: {
    businessName?: string;
    ownerName?: string;
    mobileNumber?: string;
    city?: string;
    deviceModel?: string;
  };
  try {
    body = await request.json();
  } catch (err) {
    return createErrorResponse(400, 'INVALID_JSON', 'Request body must be a valid JSON object.');
  }

  if (!body.businessName || !body.ownerName || !body.mobileNumber) {
    return createErrorResponse(
      400,
      'MISSING_REQUIRED_FIELDS',
      'Payload must contain businessName, ownerName, and mobileNumber.'
    );
  }

  // 4. Strict One-Device Limit: Check by Mobile Number FIRST
  const now = Date.now();
  let expiresAtEpochMs = now + (30 * 86400000); // 30 calendar days
  const inputMobileNumber = body.mobileNumber.trim();

  try {
    const existingCustomers = await queryCollection(env, 'customers', [
      { field: 'mobileNumber', op: 'EQUAL', value: inputMobileNumber }
    ]);

    if (existingCustomers && existingCustomers.length > 0) {
      const oldCust = existingCustomers[0];

      if (oldCust.status === 'DEACTIVATED') {
        return createErrorResponse(403, 'CUSTOMER_DEACTIVATED', 'This account has been deactivated by the administrator.');
      }

      // Check their active subscription
      const subs = await queryCollection(env, 'subscriptions', [
        { field: 'customerId', op: 'EQUAL', value: oldCust.customerId },
        { field: 'status', op: 'EQUAL', value: 'ACTIVE' }
      ]);

      if (subs && subs.length > 0) {
        const activeSub = subs[0];
        
        // If they are on the SAME hardware device, just recover their account
        if (activeSub.activeInstallationId === identity.hardwareId || activeSub.activeInstallationId === identity.installationId) {
          const cachedData = {
            customerId: oldCust.customerId,
            installationId: activeSub.activeInstallationId,
            subscriptionId: activeSub.subscriptionId,
            planId: activeSub.planId,
            activeInstallationId: activeSub.activeInstallationId,
            status: activeSub.status,
            expiresAtEpochMs: activeSub.expiresAtEpochMs,
            signedLeaseToken: activeSub.signedLeaseToken
          };
          return new Response(JSON.stringify({ success: true, data: cachedData, message: 'Account recovered successfully.' }), {
            status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
          });
        } else {
          // DIFFERENT DEVICE: STRICT BLOCK!
          return createErrorResponse(403, 'DEVICE_LIMIT_REACHED', 'This phone number is already active on another device. Please use the "Transfer Account" option.');
        }
      }
    }
  } catch (err) {
    console.warn('Strict device limit check error:', err);
  }

  // 4.5. Prevent Free Trial Abuse (New number on old phone)
  try {
    const existingInstalls = await queryCollection(env, 'installations', [
      { field: 'hardwareId', op: 'EQUAL', value: identity.hardwareId }
    ]);
    if (existingInstalls && existingInstalls.length > 0) {
      // Grant exactly 0 days to force purchase if they try to abuse the free trial by changing sim cards.
      expiresAtEpochMs = now;
    }
  } catch(err) {
     console.warn('Hardware ID check error:', err);
  }

  // 5. Generate immutable entity keys (`cus_xxxxxxxxx`, `inst_xxxxxxxxx`, `sub_xxxxxxxxx`)
  const customerId = `cus_${generateShortId()}`;
  const installationId = identity.installationId || identity.installationUuid || `inst_${generateShortId()}`;
  const subscriptionId = `sub_${generateShortId()}`;

  // 6. Generate cryptographic signedLeaseToken using Web Crypto HMAC-SHA256
  const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
  const leasePayload = {
    subscriptionId,
    customerId,
    activeInstallationId: installationId,
    planId: 'DEMO_FREE',
    planName: '30-Day Free Demo License',
    startsAtEpochMs: now,
    expiresAtEpochMs,
    maxCustomers: 50  ,
    allowWhatsAppAutoSend: true,
    allowThermalPrinting: true,
    issuedAt: now
  };
  const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

  // 6. Write records atomically to Google Cloud Firestore using commitAtomicWrites (`:commit`)
  const responsePayloadData = {
    customerId,
    installationId,
    subscriptionId,
    planId: 'DEMO_FREE',
    activeInstallationId: installationId,
    status: 'ACTIVE',
    expiresAtEpochMs,
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
      collectionPath: 'subscriptions',
      documentId: subscriptionId,
      data: {
        subscriptionId,
        customerId,
        activeInstallationId: installationId,
        planId: 'DEMO_FREE',
        status: 'ACTIVE',
        startsAtEpochMs: now,
        expiresAtEpochMs,
        signedLeaseToken,
        createdAtEpochMs: now,
        updatedAtEpochMs: now
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


