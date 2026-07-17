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

  // 4. Generate immutable entity keys (`cus_xxxxxxxxx`, `inst_xxxxxxxxx`, `sub_xxxxxxxxx`)
  const now = Date.now();
  const customerId = `cus_${generateShortId()}`;
  const installationId = identity.installationId || identity.installationUuid || `inst_${generateShortId()}`;
  const subscriptionId = `sub_${generateShortId()}`;
  const expiresAtEpochMs = now + (30 * 86400000); // exactly 30 calendar days

  // 5. Generate cryptographic signedLeaseToken using Web Crypto HMAC-SHA256
  const secretKey = env.LEASE_SIGNING_SECRET || env.RAZORPAY_WEBHOOK_SECRET || 'vendsoft_authoritative_worker_secret_v1';
  const leasePayload = {
    subscriptionId,
    customerId,
    activeInstallationId: installationId,
    planId: 'DEMO_FREE',
    planName: '30-Day Free Demo License',
    startsAtEpochMs: now,
    expiresAtEpochMs,
    maxCustomers: 50,
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


