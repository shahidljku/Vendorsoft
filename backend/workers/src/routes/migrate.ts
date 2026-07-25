import { Env, CompositeIdentity, ApiResponse } from '../types';
import { queryCollection, commitAtomicWrites, logAuditEvent } from '../services/firestore';
import { SubscriptionFSM } from '../services/fsm/subscriptionFSM';
import { InstallationFSM } from '../services/fsm/installationFSM';
import { generateSignedLeaseToken, computeSha256Hash, verifyRsaSha256Signature } from '../cryptoEngine';
import { createErrorResponse } from '../authGuard';

// Canonical RSA Public Key matching lib/services/license_service.dart
const RSA_PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAq5K1M4RgVKtFNqVfRQ71
ocBrAfUu9uhK6rR91r07iJstUzygBjpqCbIxAc0BzATIxgQ6yHd3zp5rr4xrKRIh
9Kl7o4A6uRiiaAb61S9Tcf/D6Chq8etZJ4VQc2WBzyi00Kw5lKmZtYFqmgQPuzcy
nykc3e8LoQ8HeMdoUp41nQdlf4ycmqq2fi5TVFFodvE21O+9Q9Kr3OM91QFrxKVd
of9lekmxqtIFjL3ia7w+dkenebHxq/YbCFHHgZvRbnABRRyxToVHFPLS+6ZOnVL3
TMj+g3jEHWMMdOrqXtNXkCcXfe8lFNpIKZx7zBoLp2DGPhneZwPgSvrhYiWirefA
MQIDAQAB
-----END PUBLIC KEY-----`;

/**
 * Handles POST /api/v1/migrate/legacy-key
 * Phase 5: Automatically migrates historical offline RSA license keys into modern Cloudflare Worker
 * composite device leases without double-charging or downtime.
 */
export async function handleMigrateLegacyKey(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    const body: any = await request.json();
    let { legacyLicenseKey } = body;
    legacyLicenseKey = typeof legacyLicenseKey === 'string' ? legacyLicenseKey.substring(0, 10000) : legacyLicenseKey;

    if (!legacyLicenseKey || typeof legacyLicenseKey !== 'string') {
      return createErrorResponse(400, 'MISSING_LEGACY_KEY', 'legacyLicenseKey (Base64 string) is required.');
    }

    // 1. Decode base64 JSON structure
    let licenseObj: any;
    try {
      const decodedStr = atob(legacyLicenseKey);
      licenseObj = JSON.parse(decodedStr);
    } catch (err) {
      return createErrorResponse(400, 'INVALID_LEGACY_KEY_FORMAT', 'Legacy license key is not valid Base64 encoded JSON.');
    }

    const payloadStr = licenseObj.payload;
    const signatureBase64 = licenseObj.signature;
    if (!payloadStr || !signatureBase64) {
      return createErrorResponse(400, 'INVALID_LEGACY_KEY_STRUCTURE', 'Legacy key missing payload or signature fields.');
    }

    const isValidSignature = await verifyRsaSha256Signature(payloadStr, signatureBase64, RSA_PUBLIC_KEY_PEM);
    if (!isValidSignature) {
      return createErrorResponse(403, 'INVALID_LEGACY_SIGNATURE', 'Cryptographic signature verification failed for this legacy license key.');
    }

    // 3. Parse payload and verify device ID match
    let payload: any;
    try {
      payload = JSON.parse(payloadStr);
    } catch (parseErr) {
      return createErrorResponse(400, 'INVALID_PAYLOAD_JSON', 'Legacy license payload is not valid JSON.');
    }

    const licensedDeviceId = payload.deviceId;
    if (!licensedDeviceId) {
      return createErrorResponse(400, 'MISSING_DEVICE_ID_IN_KEY', 'Legacy license key payload does not contain a deviceId.');
    }

    // Check if the hardware ID or installation ID matches the licensed device ID
    if (licensedDeviceId !== identity.hardwareId && licensedDeviceId !== identity.installationId && licensedDeviceId !== identity.installationUuid) {
      return createErrorResponse(403, 'DEVICE_ID_MISMATCH', `Legacy license key is bound to device '${licensedDeviceId}', which does not match current device identity '${identity.hardwareId || identity.installationId}'.`);
    }

    // 4. Compute unique hash of the legacy key for idempotency checking
    const legacyKeyHash = await computeSha256Hash(legacyLicenseKey);

    // Check if already migrated
    const existingSubs = await queryCollection(env, 'subscriptions', [
      { field: 'legacyKeyHash', op: 'EQUAL', value: legacyKeyHash }
    ]);

    if (existingSubs && existingSubs.length > 0) {
      const existingSub = existingSubs[0];
      const responseBody: ApiResponse = {
        success: true,
        data: {
          migrated: true,
          status: 'ALREADY_MIGRATED',
          customerId: existingSub.customerId,
          subscriptionId: existingSub.subscriptionId,
          activeInstallationId: existingSub.activeInstallationId,
          planId: existingSub.planId,
          expiresAtEpochMs: existingSub.expiresAtEpochMs,
          signedLeaseToken: existingSub.signedLeaseToken,
          message: 'This legacy RSA license was previously migrated to Cloudflare composite lease.'
        }
      };
      return new Response(JSON.stringify(responseBody), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
      });
    }

    // 5. First-time migration: prepare atomic writes
    const now = Date.now();
    const targetInstallationId = identity.installationId || identity.installationUuid || `inst_${Math.random().toString(36).substring(2, 12).toUpperCase()}`;
    const customerId = identity.customerId || `cus_${Math.random().toString(36).substring(2, 12).toUpperCase()}`;
    const subscriptionId = `sub_${Math.random().toString(36).substring(2, 12).toUpperCase()}`;

    // Calculate expiration from legacy payload string
    let expiresAtEpochMs = now + 365 * 86400 * 1000; // Default 1 year if unparseable or lifetime
    if (payload.customerType !== 'Lifetime' && payload.expiryDate) {
      const parsedExp = Date.parse(payload.expiryDate);
      if (!isNaN(parsedExp)) {
        expiresAtEpochMs = parsedExp;
      }
    } else if (payload.customerType === 'Lifetime') {
      expiresAtEpochMs = now + 50 * 365 * 86400 * 1000; // 50 years
    }

    const customerRecord = {
      customerId,
      mobileNumber: identity.uid || '+910000000000',
      ownerName: payload.customerName || 'Legacy Migrated Vendor',
      businessName: payload.customerName || 'Legacy Newspaper Agency',
      city: 'Migrated from v0.9.x',
      status: 'ACTIVE',
      createdAtEpochMs: now,
      updatedAtEpochMs: now
    };

    const installationRecord = {
      installationId: targetInstallationId,
      customerId,
      hardwareId: identity.hardwareId || targetInstallationId,
      installationUuid: identity.installationUuid || targetInstallationId,
      firebaseUid: identity.uid,
      platform: identity.platform || 'android',
      appVersion: identity.appVersion || '1.0.0',
      deviceModel: payload.customerType || 'Legacy RSA Device',
      status: InstallationFSM.transition({}, 'ACTIVATE'),
      isBanned: false,
      createdAtEpochMs: now,
      lastSeenAtEpochMs: now
    };

    // Generate signed lease token for the migrated subscription
    const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
    const leasePayload = {
      subscriptionId,
      customerId,
      activeInstallationId: targetInstallationId,
      planId: 'LEGACY_MIGRATED',
      planName: payload.customerType ? `Legacy (${payload.customerType})` : 'Legacy Migrated License',
      startsAtEpochMs: now,
      expiresAtEpochMs,
      maxCustomers: 10000,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      issuedAt: now
    };
    const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

    const subscriptionRecord = {
      subscriptionId,
      customerId,
      activeInstallationId: targetInstallationId,
      planId: 'LEGACY_MIGRATED',
      planName: leasePayload.planName,
      status: SubscriptionFSM.transition({}, 'ACTIVATE'),
      startsAtEpochMs: now,
      expiresAtEpochMs,
      signedLeaseToken,
      legacyKeyHash,
      createdAtEpochMs: now,
      updatedAtEpochMs: now
    };

    const batchWrites = [
      { collectionPath: 'customers', documentId: customerId, data: customerRecord },
      { collectionPath: 'installations', documentId: targetInstallationId, data: installationRecord },
      { collectionPath: 'subscriptions', documentId: subscriptionId, data: subscriptionRecord }
    ];

    await commitAtomicWrites(env, batchWrites);
    await logAuditEvent(env, 'MIGRATED_LEGACY_RSA_LICENSE', {
      customerId,
      installationId: targetInstallationId,
      subscriptionId,
      legacyKeyHash,
      licensedDeviceId
    });

    const responseBody: ApiResponse = {
      success: true,
      data: {
        migrated: true,
        status: 'SUCCESS',
        customerId,
        subscriptionId,
        activeInstallationId: targetInstallationId,
        planId: 'LEGACY_MIGRATED',
        expiresAtEpochMs,
        signedLeaseToken,
        message: 'Legacy RSA license successfully migrated to Cloudflare composite lease.'
      }
    };

    return new Response(JSON.stringify(responseBody), {
      status: 201,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleMigrateLegacyKey:', err);
    return createErrorResponse(500, 'MIGRATION_FAILED', `Server error during legacy key migration: ${err.message || err}`);
  }
}
