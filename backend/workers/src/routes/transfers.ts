import { Env, CompositeIdentity, ApiResponse } from '../types';
import { getDocument, setDocument, queryCollection, commitAtomicWrites, sendFcmNotification, deleteDocument } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateShortId, generateSignedLeaseToken } from '../cryptoEngine';
import { LockService } from '../services/lock';
import { findSubscription, DiscoveryStrategy } from '../services/discovery';

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
    if (typeof body.customerId === 'string' && body.customerId.length > 100) return createErrorResponse(400, 'INVALID_CUSTOMER_ID', 'customerId exceeds maximum allowed length.');
    if (typeof body.subscriptionId === 'string' && body.subscriptionId.length > 100) return createErrorResponse(400, 'INVALID_SUBSCRIPTION_ID', 'subscriptionId exceeds maximum allowed length.');
    if (typeof body.mobileNumber === 'string' && body.mobileNumber.length > 20) return createErrorResponse(400, 'INVALID_MOBILE_NUMBER', 'mobileNumber exceeds maximum allowed length.');

    let customerId = typeof body.customerId === 'string' ? body.customerId : (identity.customerId || undefined);
    const subscriptionId = typeof body.subscriptionId === 'string' ? body.subscriptionId : undefined;
    const mobileNumber = typeof body.mobileNumber === 'string' ? body.mobileNumber : undefined;

    if (!customerId && !subscriptionId && !mobileNumber) {
      return createErrorResponse(400, 'MISSING_PARAMETERS', 'Must provide customerId, subscriptionId, or mobileNumber.');
    }

    // Lookup customer by mobile number if customerId is not directly provided
    if (!customerId && !subscriptionId && mobileNumber) {
      const customers = await queryCollection(env, 'customers', [
        { field: 'mobileNumber', op: 'EQUAL', value: mobileNumber }
      ]);
      if (customers && customers.length > 0) {
        customerId = customers[0].customerId;
      } else {
        return createErrorResponse(404, 'NO_CUSTOMER_FOUND', 'No account found with this mobile number.');
      }
    }

    // 2. Locate target subscription
    let sub: any = null;
    const now = Date.now();

    if (subscriptionId) {
      if (subscriptionId.startsWith('TRIAL_')) {
        const hardwareId = subscriptionId.replace('TRIAL_', '');
        const trial = await getDocument(env, 'hardware_trials', hardwareId);
        if (trial) {
          sub = {
            subscriptionId,
            customerId: trial.customerId,
            activeInstallationId: trial.hardwareId,
            planId: 'FREE_TRIAL_30',
            status: now > trial.expiresAtEpochMs ? 'EXPIRED' : 'ACTIVE',
            expiresAtEpochMs: trial.expiresAtEpochMs
          };
        }
      } else {
        sub = await getDocument(env, 'subscriptions', subscriptionId);
      }
    } else if (customerId) {
      const { sub: foundSub } = await findSubscription(env, customerId, DiscoveryStrategy.TRANSFER);
      sub = foundSub;
    }

    if (!sub || (sub.status !== 'ACTIVE' && sub.status !== 'EXPIRED')) {
      return createErrorResponse(404, 'NO_ACTIVE_SUBSCRIPTION', 'No active subscription or trial found to transfer.');
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

    try {
      return await LockService.withLock(
        env,
        'transfer_lock',
        sub.subscriptionId,
        5000,
        { customerId: sub.customerId, subscriptionId: sub.subscriptionId },
        async () => {
          const rawPendingListForSub = await queryCollection(env, 'device_transfers', [
            { field: 'subscriptionId', op: 'EQUAL', value: sub.subscriptionId }
          ]);
          
          // Pillar 3: Cancel-Spam Harassment Bypass Patch (Global 5-Request Limit)
          const recentTransfers = rawPendingListForSub.filter((t: any) => t.requestedAtEpochMs > now - (24 * 60 * 60 * 1000));
          if (recentTransfers.length >= 5) {
            return createErrorResponse(429, 'TOO_MANY_REQUESTS', 'Too many transfer attempts. Please try again tomorrow to protect the account owner from spam.');
          }

          const pendingList = rawPendingListForSub.filter((t: any) => t.status === 'PENDING');

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

          // Pillar 8: The Block (If Free Trial, check if hardwareId already used a trial)
          if (sub.planId === 'FREE_TRIAL_30') {
            const trialHistory = await getDocument(env, 'hardware_trials', identity.hardwareId);
            if (trialHistory) {
              return createErrorResponse(403, 'TRIAL_ALREADY_USED', 'This device has already used a 30-Day Free Trial. Please purchase a Pro Plan to use this device.');
            }
          }

          // Pillar 4: Payload Bloat Protection
          const deviceModel = (body.deviceModel || 'Unknown New Device').substring(0, 100);

          const transferData = {
            transferId,
            subscriptionId: sub.subscriptionId,
            customerId: sub.customerId,
            oldInstallationId: sub.activeInstallationId || 'UNKNOWN',
            newInstallationId: identity.installationId,
            newHardwareId: identity.hardwareId, // Pillar 8: API Spoofing Patch
            deviceModel: deviceModel,
            status: 'PENDING',
            requestedAtEpochMs: now,
            expiresAtEpochMs
          };

          await setDocument(env, 'device_transfers', transferId, transferData);

          // Fetch the old installation to send an FCM notification
          const oldInstallationId = sub.activeInstallationId;
          if (oldInstallationId) {
            try {
              const oldInstallation = await getDocument(env, 'installations', oldInstallationId);
              if (oldInstallation && oldInstallation.fcmToken) {
                await sendFcmNotification(
                  env,
                  oldInstallation.fcmToken,
                  'Device Transfer Request',
                  'Another device is trying to claim your active VendSoft license.',
                  { transferId }
                );
              }
            } catch (fcmErr) {
              console.error('FCM Notification error:', fcmErr);
            }
          }

          return new Response(JSON.stringify({
            success: true,
            data: {
              transferId,
              status: 'PENDING',
              message: 'Transfer request sent to your old device. Please open VendSoft on your old device and tap "Approve" to complete activation.'
            }
          }), { status: 202, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        return createErrorResponse(429, 'TOO_MANY_REQUESTS', 'Please wait a few seconds before requesting another transfer.');
      }
      throw err;
    }
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

    const rawPendingList = await queryCollection(env, 'device_transfers', [
      { field: 'oldInstallationId', op: 'EQUAL', value: identity.installationId }
    ]);
    
    const pendingList = rawPendingList.filter((t: any) => t.status === 'PENDING');

    if (identity.hardwareId && identity.hardwareId !== identity.installationId) {
      const trialRawList = await queryCollection(env, 'device_transfers', [
        { field: 'oldInstallationId', op: 'EQUAL', value: identity.hardwareId }
      ]);
      pendingList.push(...trialRawList.filter((t: any) => t.status === 'PENDING'));
    }

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
    if (transferDoc.oldInstallationId !== identity.installationId && transferDoc.oldInstallationId !== identity.hardwareId) {
      return createErrorResponse(403, 'UNAUTHORIZED_APPROVAL', 'Only the current active device (`oldInstallationId`) can approve a transfer.');
    }

    try {
      return await LockService.withLock(
        env,
        'sub_lock',
        transferDoc.subscriptionId,
        30000,
        { customerId: identity.customerId, transferId },
        async () => {
          // Authoritative Re-Read of Subscription under mutex
          let sub: any = null;
          let isTrial = false;
          if (transferDoc.subscriptionId && transferDoc.subscriptionId.startsWith('TRIAL_')) {
            isTrial = true;
            const hardwareId = transferDoc.subscriptionId.replace('TRIAL_', '');
            const trial = await getDocument(env, 'hardware_trials', hardwareId);
            if (trial) {
              sub = {
                subscriptionId: transferDoc.subscriptionId,
                customerId: trial.customerId,
                activeInstallationId: trial.hardwareId,
                planId: 'FREE_TRIAL_30',
                startsAtEpochMs: trial.startedAtEpochMs,
                expiresAtEpochMs: trial.expiresAtEpochMs
              };
            }
          } else {
            sub = await getDocument(env, 'subscriptions', transferDoc.subscriptionId);
          }

          if (!sub) {
            return createErrorResponse(404, 'SUBSCRIPTION_NOT_FOUND', 'The subscription or trial associated with this transfer no longer exists.');
          }

          // Pillar 9: Double-Spend Fix
          if (sub.activeInstallationId !== transferDoc.oldInstallationId) {
            return createErrorResponse(409, 'TRANSFER_ALREADY_PROCESSED', 'This subscription has already been transferred to a different device.');
          }

          // Generate cryptographic signedLeaseToken for the new device
          const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
          const leasePayload = {
            subscriptionId: sub.subscriptionId,
            customerId: sub.customerId,
            activeInstallationId: transferDoc.newInstallationId,
            hasActiveSubscription: true,
            planId: sub.planId || 'FREE_TRIAL_30',
            planName: sub.planId === 'PRO_YEARLY' ? 'Pro Annual License' : sub.planId === 'FREE_TRIAL_30' ? '30-Day Pro Trial' : 'Pro Monthly License',
            startsAtEpochMs: sub.startsAtEpochMs || now,
            expiresAtEpochMs: sub.expiresAtEpochMs,
            maxCustomers: sub.planId === 'PRO_YEARLY' || sub.planId === 'FREE_TRIAL_30' ? 10000 : 50,
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

          // We must retrieve the hardware ID of the new installation to correctly migrate the trial lock.
          let newHardwareId = transferDoc.newHardwareId; // Pillar 8 sealed value
          if (!newHardwareId) {
            // Fallback for older transfers
            newHardwareId = transferDoc.newInstallationId;
            try {
              const newInst = await getDocument(env, 'installations', transferDoc.newInstallationId);
              if (newInst && newInst.hardwareId) {
                newHardwareId = newInst.hardwareId;
              }
            } catch(e) {}
          }

          // Pillar 9: The Block
          if (isTrial) {
            const trialHistory = await getDocument(env, 'hardware_trials', newHardwareId);
            if (trialHistory) {
               transferDoc.status = 'REJECTED';
               await setDocument(env, 'device_transfers', transferId, transferDoc);
               return createErrorResponse(403, 'TRIAL_ALREADY_USED', 'The receiving device has already used a Free Trial. Transfer aborted.');
            }
          }

          // Atomic batch write (`:commit`)
          const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any>; requireDoesNotExist?: boolean }> = [
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

          if (isTrial) {
            batchWrites.push({
              collectionPath: 'hardware_trials',
              documentId: newHardwareId,
              data: {
                hardwareId: newHardwareId,
                startedAtEpochMs: sub.startsAtEpochMs,
                expiresAtEpochMs: sub.expiresAtEpochMs,
                customerId: sub.customerId,
                trialUsed: true
              }
            });
            batchWrites.push({
              collectionPath: 'hardware_trials',
              documentId: sub.activeInstallationId,
              data: {
                hardwareId: sub.activeInstallationId,
                startedAtEpochMs: sub.startsAtEpochMs,
                expiresAtEpochMs: 0,
                customerId: sub.customerId,
                trialUsed: true
              }
            });
          } else {
            batchWrites.push({
              collectionPath: 'subscriptions',
              documentId: sub.subscriptionId,
              data: {
                ...sub,
                activeInstallationId: transferDoc.newInstallationId,
                signedLeaseToken,
                updatedAtEpochMs: now
              }
            });
          }

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

          await commitAtomicWrites(env, batchWrites);

          return new Response(JSON.stringify({ success: true, data: responseData }), {
            status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
          });
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        if (idempotencyKey) {
           // We might hit ALREADY_EXISTS from idempotency key caching, or from the LockService!
           // Actually, if LockService threw it, it means the lock was taken.
           // If idempotency key write threw it, it means we processed twice.
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
        return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', 'Subscription is currently locked by another process.');
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
    const idempotencyKey = identity.idempotencyKey;

    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Parameter transferId is required.');
    }

    const transferDoc = await getDocument(env, 'device_transfers', transferId);
    const now = Date.now();

    if (!transferDoc || transferDoc.status !== 'PENDING') {
      return createErrorResponse(400, 'TRANSFER_NOT_PENDING', 'Transfer request is not in PENDING state.');
    }

    if (transferDoc.oldInstallationId !== identity.installationId && transferDoc.oldInstallationId !== identity.hardwareId) {
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

    if (idempotencyKey) {
      batchWrites.push({
        collectionPath: 'idempotency_keys',
        documentId: idempotencyKey,
        data: {
          keyId: idempotencyKey,
          expiresAtEpochMs: now + (24 * 3600000),
          responsePayload: JSON.stringify({
            transferId,
            status: 'REJECTED',
            message: 'Transfer request rejected.'
          })
        }
      });
    }

    try {
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
      if (err.code === 'ALREADY_EXISTS' && idempotencyKey) {
        return createErrorResponse(409, 'TRANSFER_ALREADY_PROCESSED', 'Transfer already rejected.');
      }
      throw err;
    }
  } catch (err: any) {
    console.error('Error in POST /api/v1/transfers/reject:', err);
    return createErrorResponse(500, 'TRANSFER_REJECTION_FAILED', `Failed to reject transfer: ${err.message || err}`);
  }
}

/**
 * Handles GET /api/v1/transfers/:transferId/status
 * Allows the requesting device to poll for the status of a transfer.
 */
export async function handleGetTransferStatus(request: Request, env: Env, identity: CompositeIdentity, path: string): Promise<Response> {
  try {
    const transferId = path.substring('/v1/transfers/'.length, path.length - '/status'.length);
    
    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Transfer ID is required in URL path.');
    }

    const transferDoc = await getDocument(env, 'device_transfers', transferId);
    
    if (!transferDoc) {
      return createErrorResponse(404, 'TRANSFER_NOT_FOUND', 'The requested transfer was not found.');
    }

    // Security: Only allow if the requester is either the old or new installation
    if (transferDoc.oldInstallationId !== identity.installationId && 
        transferDoc.oldInstallationId !== identity.hardwareId && 
        transferDoc.newInstallationId !== identity.installationId) {
      return createErrorResponse(403, 'UNAUTHORIZED_ACCESS', 'You are not authorized to view this transfer status.');
    }

    return new Response(JSON.stringify({
      success: true,
      data: {
        transferId: transferDoc.transferId,
        status: transferDoc.status,
        expiresAtEpochMs: transferDoc.expiresAtEpochMs,
        resolvedAtEpochMs: transferDoc.resolvedAtEpochMs || null,
        completedAtEpochMs: transferDoc.completedAtEpochMs || null
      }
    }), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
    
  } catch (err: any) {
    console.error('Error in GET /api/v1/transfers/status:', err);
    return createErrorResponse(500, 'TRANSFER_STATUS_FAILED', `Failed to get transfer status: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/transfers/cancel
 * Cancels a transfer claim from the requesting device (new device).
 */
export async function handleCancelTransfer(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    const body = await request.json() as any;
    const transferId = body.transferId;
    
    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Parameter transferId is required.');
    }

    const transferDoc = await getDocument(env, 'device_transfers', transferId);
    if (!transferDoc) {
      return createErrorResponse(404, 'TRANSFER_NOT_FOUND', 'Transfer request not found.');
    }

    if (transferDoc.status !== 'PENDING') {
      return createErrorResponse(409, 'TRANSFER_NOT_PENDING', `Transfer request is already ${transferDoc.status}.`);
    }

    // Security check: Only the NEW installation can cancel its own transfer
    if (transferDoc.newInstallationId !== identity.installationId) {
      return createErrorResponse(403, 'UNAUTHORIZED_CANCEL', 'Only the requesting device can cancel this transfer.');
    }

    const now = Date.now();
    const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any> }> = [
      {
        collectionPath: 'device_transfers',
        documentId: transferId,
        data: {
          ...transferDoc,
          status: 'CANCELLED',
          resolvedAtEpochMs: now,
          updatedAtEpochMs: now
        }
      }
    ];

    await commitAtomicWrites(env, batchWrites);

    return new Response(JSON.stringify({
      success: true,
      data: {
        transferId,
        status: 'CANCELLED',
        message: 'Transfer request cancelled.'
      }
    }), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });

  } catch (err: any) {
    console.error('Error in POST /api/v1/transfers/cancel:', err);
    return createErrorResponse(500, 'TRANSFER_CANCELLATION_FAILED', `Failed to cancel transfer: ${err.message || err}`);
  }
}
