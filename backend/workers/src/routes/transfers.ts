import { Env, CompositeIdentity, ApiResponse } from '../types';
import { getDocument, setDocument, queryCollection, commitAtomicWrites } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateShortId, generateSignedLeaseToken } from '../cryptoEngine';

/**
 * Handles POST /api/v1/transfers/request
 * Initiates a Peer-to-Peer device transfer claim.
 * See API_SPECIFICATION.md Section 2.5.1 & FIRESTORE_SCHEMA.md Section 3.7.
 */
export async function handleRequestTransfer(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    // 1. Check system config gate
    const config = await getDocument(env, 'system_configs', 'global');
    if (config && (config.allowTransfers === false || config.maintenanceMode === true)) {
      return createErrorResponse(
        config.maintenanceMode ? 503 : 403,
        config.maintenanceMode ? 'MAINTENANCE_MODE' : 'TRANSFERS_DISABLED',
        'Device transfers are currently disabled or system is under maintenance.'
      );
    }

    const body = await request.json() as any;
    const customerId = body.customerId || identity.customerId;
    const subscriptionId = body.subscriptionId;

    if (!customerId && !subscriptionId) {
      return createErrorResponse(400, 'MISSING_PARAMETERS', 'Must provide customerId or subscriptionId.');
    }

    // 2. Locate target subscription
    let sub: any = null;
    if (subscriptionId) {
      sub = await getDocument(env, 'subscriptions', subscriptionId);
    } else if (customerId) {
      const subs = await queryCollection(env, 'subscriptions', [
        { field: 'customerId', op: 'EQUAL', value: customerId },
        { field: 'status', op: 'EQUAL', value: 'ACTIVE' }
      ]);
      if (subs && subs.length > 0) sub = subs[0];
    }

    if (!sub || sub.status !== 'ACTIVE') {
      return createErrorResponse(404, 'NO_ACTIVE_SUBSCRIPTION', 'No active subscription found to transfer.');
    }

    // 3. If already active on this installation, return success immediately
    if (sub.activeInstallationId && identity.installationId && sub.activeInstallationId === identity.installationId) {
      return new Response(JSON.stringify({
        success: true,
        data: {
          transferId: 'trn_already_active',
          status: 'APPROVED',
          message: 'Already the active installation for this subscription.'
        }
      }), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
    }

    // 4. Check if a pending transfer already exists (`ONLY_ONE_PENDING_TRANSFER_ALLOWED`)
    const pendingList = await queryCollection(env, 'device_transfers', [
      { field: 'subscriptionId', op: 'EQUAL', value: sub.subscriptionId },
      { field: 'status', op: 'EQUAL', value: 'PENDING' }
    ]);

    const now = Date.now();
    for (const pending of pendingList) {
      if (pending.expiresAtEpochMs > now) {
        return createErrorResponse(
          409,
          'ONLY_ONE_PENDING_TRANSFER_ALLOWED',
          'A transfer request is already pending for this subscription. Please approve or reject it on your old device.',
          { existingTransferId: pending.transferId, expiresAtEpochMs: pending.expiresAtEpochMs }
        );
      }
    }

    // 5. Create new transfer document (`trn_xxxxxxxxx`)
    const transferId = `trn_${generateShortId()}`;
    const expiresAtEpochMs = now + (24 * 3600000); // 24 hours lock

    const transferData = {
      transferId,
      subscriptionId: sub.subscriptionId,
      customerId: sub.customerId,
      oldInstallationId: sub.activeInstallationId || 'UNKNOWN',
      newInstallationId: identity.installationId,
      deviceModel: body.deviceModel || 'Unknown New Device',
      status: 'PENDING',
      requestedAtEpochMs: now,
      expiresAtEpochMs
    };

    await setDocument(env, 'device_transfers', transferId, transferData);

    return new Response(JSON.stringify({
      success: true,
      data: {
        transferId,
        status: 'PENDING',
        message: 'Transfer request sent to your old device. Please open VendSoft on your old device and tap "Approve" to complete activation.'
      }
    }), { status: 202, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
  } catch (err: any) {
    console.error('Error in POST /api/v1/transfers/request:', err);
    return createErrorResponse(500, 'TRANSFER_REQUEST_FAILED', `Failed to initiate transfer: ${err.message || err}`);
  }
}

/**
 * Handles GET /api/v1/transfers/pending
 * Mandatory polling endpoint called by old device upon foregrounding/sync to detect pending claims.
 * See API_SPECIFICATION.md Section 2.5.2.
 */
export async function handleGetPendingTransfers(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    if (!identity.installationId) {
      return createErrorResponse(400, 'MISSING_INSTALLATION_ID', 'Header x-installation-uuid is required.');
    }

    const pendingList = await queryCollection(env, 'device_transfers', [
      { field: 'oldInstallationId', op: 'EQUAL', value: identity.installationId },
      { field: 'status', op: 'EQUAL', value: 'PENDING' }
    ]);

    const now = Date.now();
    const activePending = pendingList.filter((t) => t.expiresAtEpochMs > now).map((t) => ({
      transferId: t.transferId,
      newInstallationId: t.newInstallationId,
      deviceModel: t.deviceModel || 'Unknown Device',
      requestedAtEpochMs: t.requestedAtEpochMs,
      expiresAtEpochMs: t.expiresAtEpochMs
    }));

    return new Response(JSON.stringify({
      success: true,
      data: { pendingTransfers: activePending }
    }), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
  } catch (err: any) {
    console.error('Error in GET /api/v1/transfers/pending:', err);
    return createErrorResponse(500, 'TRANSFER_POLL_FAILED', `Failed to query pending transfers: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/transfers/approve
 * Atomically approves transfer, reassigns activeInstallationId, revokes old device, and generates signedLeaseToken.
 * See API_SPECIFICATION.md Section 2.5.3.
 */
export async function handleApproveTransfer(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    const body = await request.json() as any;
    const transferId = body.transferId;
    const idempotencyKey = identity.idempotencyKey;

    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Parameter transferId is required.');
    }

    // Check idempotency lock
    if (idempotencyKey) {
      const existingIdem = await getDocument(env, 'idempotency_keys', idempotencyKey);
      if (existingIdem && existingIdem.expiresAtEpochMs > Date.now() && existingIdem.responsePayload) {
        let cachedData: any;
        try { cachedData = JSON.parse(existingIdem.responsePayload); } catch (e) { cachedData = existingIdem.responsePayload; }
        return new Response(JSON.stringify({ success: true, data: cachedData }), {
          status: 200,
          headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
        });
      }
    }

    const transferDoc = await getDocument(env, 'device_transfers', transferId);
    const now = Date.now();

    if (!transferDoc || transferDoc.status !== 'PENDING' || now > transferDoc.expiresAtEpochMs) {
      return createErrorResponse(400, 'TRANSFER_NOT_PENDING', 'Transfer request is either expired, already resolved, or invalid.');
    }

    // Security check: Only the old installation can approve its own transfer
    if (transferDoc.oldInstallationId !== identity.installationId) {
      return createErrorResponse(403, 'UNAUTHORIZED_APPROVAL', 'Only the current active device (`oldInstallationId`) can approve a transfer.');
    }

    const sub = await getDocument(env, 'subscriptions', transferDoc.subscriptionId);
    if (!sub) {
      return createErrorResponse(404, 'SUBSCRIPTION_NOT_FOUND', 'The subscription associated with this transfer no longer exists.');
    }

    // Generate cryptographic signedLeaseToken for the new device
    const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
    const leasePayload = {
      subscriptionId: sub.subscriptionId,
      customerId: sub.customerId,
      activeInstallationId: transferDoc.newInstallationId,
      hasActiveSubscription: true,
      planId: sub.planId || 'DEMO_FREE',
      planName: sub.planId === 'PRO_YEARLY' ? 'Pro Annual License' : '30-Day Free Demo License',
      startsAtEpochMs: sub.startsAtEpochMs || now,
      expiresAtEpochMs: sub.expiresAtEpochMs,
      maxCustomers: sub.planId === 'PRO_YEARLY' ? 10000 : 50,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      issuedAt: now
    };
    const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

    const responseData = {
      transferId,
      status: 'APPROVED',
      message: 'Transfer approved. This device has now been deactivated.'
    };

    const auditLogId = `aud_${generateShortId()}`;

    // Atomic batch write (`:commit`)
    const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any>; requireDoesNotExist?: boolean }> = [
      {
        collectionPath: 'subscriptions',
        documentId: sub.subscriptionId,
        data: {
          ...sub,
          activeInstallationId: transferDoc.newInstallationId,
          signedLeaseToken,
          updatedAtEpochMs: now
        }
      },
      {
        collectionPath: 'installations',
        documentId: transferDoc.oldInstallationId,
        data: {
          installationId: transferDoc.oldInstallationId,
          customerId: sub.customerId,
          status: 'REVOKED',
          updatedAtEpochMs: now
        }
      },
      {
        collectionPath: 'installations',
        documentId: transferDoc.newInstallationId,
        data: {
          installationId: transferDoc.newInstallationId,
          customerId: sub.customerId,
          status: 'ACTIVE',
          updatedAtEpochMs: now
        }
      },
      {
        collectionPath: 'device_transfers',
        documentId: transferId,
        data: {
          ...transferDoc,
          status: 'APPROVED',
          approvedBy: 'PEER_OLD_DEVICE',
          completedAtEpochMs: now
        }
      },
      {
        collectionPath: 'audit_logs',
        documentId: auditLogId,
        data: {
          logId: auditLogId,
          event: 'TRANSFER_APPROVED_PEER',
          transferId,
          subscriptionId: sub.subscriptionId,
          customerId: sub.customerId,
          oldInstallationId: transferDoc.oldInstallationId,
          newInstallationId: transferDoc.newInstallationId,
          timestampEpochMs: now
        }
      }
    ];

    if (idempotencyKey) {
      batchWrites.push({
        collectionPath: 'idempotency_keys',
        documentId: idempotencyKey,
        data: {
          keyId: idempotencyKey,
          expiresAtEpochMs: now + (24 * 3600000),
          responsePayload: JSON.stringify(responseData)
        },
        requireDoesNotExist: true
      });
    }

    try {
      await commitAtomicWrites(env, batchWrites);

      return new Response(JSON.stringify({ success: true, data: responseData }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
      });
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS' && idempotencyKey) {
        const existingIdem = await getDocument(env, 'idempotency_keys', idempotencyKey);
        if (existingIdem && existingIdem.responsePayload) {
          let cachedData: any;
          try { cachedData = JSON.parse(existingIdem.responsePayload); } catch (e) { cachedData = existingIdem.responsePayload; }
          return new Response(JSON.stringify({ success: true, data: cachedData }), {
            status: 200,
            headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
          });
        }
      }
      throw err;
    }
  } catch (err: any) {
    console.error('Error in POST /api/v1/transfers/approve:', err);
    return createErrorResponse(500, 'TRANSFER_APPROVAL_FAILED', `Failed to approve transfer: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/transfers/reject
 * Rejects transfer claim, preserving old device's rights.
 * See API_SPECIFICATION.md Section 2.5.4.
 */
export async function handleRejectTransfer(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    const body = await request.json() as any;
    const transferId = body.transferId;

    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Parameter transferId is required.');
    }

    const transferDoc = await getDocument(env, 'device_transfers', transferId);
    const now = Date.now();

    if (!transferDoc || transferDoc.status !== 'PENDING') {
      return createErrorResponse(400, 'TRANSFER_NOT_PENDING', 'Transfer request is not in PENDING state.');
    }

    if (transferDoc.oldInstallationId !== identity.installationId) {
      return createErrorResponse(403, 'UNAUTHORIZED_REJECTION', 'Only the current active device can reject this transfer.');
    }

    const auditLogId = `aud_${generateShortId()}`;
    const batchWrites = [
      {
        collectionPath: 'device_transfers',
        documentId: transferId,
        data: {
          ...transferDoc,
          status: 'REJECTED',
          rejectedBy: 'PEER_OLD_DEVICE',
          completedAtEpochMs: now
        }
      },
      {
        collectionPath: 'audit_logs',
        documentId: auditLogId,
        data: {
          logId: auditLogId,
          event: 'TRANSFER_REJECTED_PEER',
          transferId,
          subscriptionId: transferDoc.subscriptionId,
          customerId: transferDoc.customerId,
          oldInstallationId: transferDoc.oldInstallationId,
          newInstallationId: transferDoc.newInstallationId,
          timestampEpochMs: now
        }
      }
    ];

    await commitAtomicWrites(env, batchWrites);

    return new Response(JSON.stringify({
      success: true,
      data: {
        transferId,
        status: 'REJECTED',
        message: 'Transfer request rejected.'
      }
    }), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
  } catch (err: any) {
    console.error('Error in POST /api/v1/transfers/reject:', err);
    return createErrorResponse(500, 'TRANSFER_REJECTION_FAILED', `Failed to reject transfer: ${err.message || err}`);
  }
}
