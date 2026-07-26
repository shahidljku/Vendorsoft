import { RequestContext } from './logger';
import { Env, CompositeIdentity } from '../types';
import { getDocument, setDocument, queryCollection, commitAtomicWrites, sendFcmNotification, buildAuditLogOp, AtomicWriteOp } from './firestore';
import { generateShortId } from '../cryptoEngine';
import { generateSignedLeaseToken } from '../cryptoEngine';
import { LockService } from './lock';
import { findSubscription, DiscoveryStrategy } from './discovery';
import { TransferFSM } from './fsm/transferFSM';
import { SubscriptionService } from './subscriptionService';
import { InstallationService } from './installationService';
import { InstallationFSM } from './fsm/installationFSM';
import { resetRateLimit } from './resilience/rateLimiter';

export class TransferService {
  /**
   * Initiates a Peer-to-Peer device transfer claim.
   */
  static async requestTransfer(ctx: RequestContext, env: Env, customerId: string | undefined, subscriptionId: string | undefined, mobileNumber: string | undefined, identity: CompositeIdentity, deviceModel: string, isRateLimited: boolean = false): Promise<{ success: boolean; data: any }> {
    const now = Date.now();

    // Lookup customer by mobile number if customerId is not directly provided
    if (!customerId && !subscriptionId && mobileNumber) {
      const customers = await queryCollection(ctx, env, 'customers', [
        { field: 'mobileNumber', op: 'EQUAL', value: mobileNumber }
      ]);
      if (customers && customers.length > 0) {
        customerId = customers[0].customerId;
      } else {
        const err: any = new Error('No account found with this mobile number.');
        err.code = 'NO_CUSTOMER_FOUND';
        throw err;
      }
    }

    let sub: any = null;
    if (subscriptionId) {
      sub = await getDocument(ctx, env, 'subscriptions', subscriptionId);

      if (!sub && subscriptionId.startsWith('TRIAL_')) {
        const hardwareId = subscriptionId.replace('TRIAL_', '');
        const trial = await getDocument(ctx, env, 'hardware_trials', hardwareId);
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
      }
    } else if (customerId) {
      const { sub: foundSub } = await findSubscription(ctx, env, customerId, DiscoveryStrategy.TRANSFER);
      sub = foundSub;
    }

    if (!sub || (sub.status !== 'ACTIVE' && sub.status !== 'EXPIRED')) {
      const err: any = new Error('No active subscription or trial found to transfer.');
      err.code = 'NO_ACTIVE_SUBSCRIPTION';
      throw err;
    }

    if (sub.activeInstallationId && identity.installationId && sub.activeInstallationId === identity.installationId) {
      return {
        success: true,
        data: {
          transferId: 'trn_already_active',
          status: 'APPROVED',
          message: 'Already the active installation for this subscription.'
        }
      };
    }

    try {
      return await LockService.withLock(ctx, env,
        'transfer_lock',
        sub.subscriptionId,
        5000,
        { customerId: sub.customerId, subscriptionId: sub.subscriptionId },
        async () => {
          const rawPendingListForSub = await queryCollection(ctx, env, 'device_transfers', [
            { field: 'subscriptionId', op: 'EQUAL', value: sub.subscriptionId }
          ]);
          
          const recentTransfers = rawPendingListForSub.filter((t: any) => t.requestedAtEpochMs > now - (24 * 60 * 60 * 1000));
          if (recentTransfers.length >= 20) {
            const err: any = new Error('Too many transfer attempts. Please try again tomorrow to protect the account owner from spam.');
            err.code = 'TOO_MANY_REQUESTS';
            throw err;
          }
          if (recentTransfers.length >= 5) {
            isRateLimited = true;
          }

          const pendingList = rawPendingListForSub.filter((t: any) => t.status === 'PENDING');

          for (const pending of pendingList) {
            if (pending.expiresAtEpochMs > now) {
              const err: any = new Error('A transfer request is already pending for this subscription. Please approve or reject it on your old device.');
              err.code = 'ONLY_ONE_PENDING_TRANSFER_ALLOWED';
              err.details = { existingTransferId: pending.transferId, expiresAtEpochMs: pending.expiresAtEpochMs };
              throw err;
            }
          }

          const transferId = `trn_${generateShortId()}`;
          const expiresAtEpochMs = now + (24 * 3600000);

          if (sub.planId === 'FREE_TRIAL_30') {
            const trialHistory = await getDocument(ctx, env, 'hardware_trials', identity.hardwareId);
            if (trialHistory && (trialHistory.status === 'EXPIRED' || trialHistory.status === 'CANCELLED' || (trialHistory.expiresAtEpochMs && trialHistory.expiresAtEpochMs > 0 && now > trialHistory.expiresAtEpochMs))) {
              const err: any = new Error('This device has an expired Free Trial. Cannot transfer another Free Trial to an expired device. Please purchase a Pro Plan.');
              err.code = 'TRIAL_ALREADY_USED';
              throw err;
            }
          }

          const transferData = {
            transferId,
            subscriptionId: sub.subscriptionId,
            customerId: sub.customerId,
            oldInstallationId: sub.activeInstallationId || 'UNKNOWN',
            newInstallationId: identity.installationId,
            newHardwareId: identity.hardwareId,
            deviceModel,
            status: isRateLimited ? 'RATE_LIMITED' : TransferFSM.transition({}, 'REQUEST'),
            requestedAtEpochMs: now,
            expiresAtEpochMs
          };

          await setDocument(ctx, env, 'device_transfers', transferId, transferData);

          const oldInstallationId = sub.activeInstallationId;
          if (oldInstallationId && !isRateLimited) {
            try {
              let oldInstallation = null;
              if (sub.customerId) {
                const oldInstallations = await queryCollection(ctx, env, 'installations', [{ field: 'customerId', op: 'EQUAL', value: sub.customerId }]);
                oldInstallation = oldInstallations.find((inst: any) => 
                  inst.installationId === oldInstallationId || 
                  inst.hardwareId === oldInstallationId || 
                  inst.id === oldInstallationId || 
                  inst.documentId === oldInstallationId
                );
              }
              if (!oldInstallation) {
                oldInstallation = await getDocument(ctx, env, 'installations', oldInstallationId);
              }
              
              if (oldInstallation && oldInstallation.fcmToken) {
                await sendFcmNotification(ctx, env,
                  oldInstallation.fcmToken,
                  'Device Transfer Request',
                  'Another device is trying to claim your active VendSoft license.',
                  { transferId }
                );
              }
            } catch (fcmErr) {
              ctx.logger.error('Failed to notify old device about transfer request:', fcmErr);
            }
          }

          return {
            success: true,
            data: {
              transferId,
              status: 'PENDING',
              message: 'Transfer request sent to your old device. Please open VendSoft on your old device and tap "Approve" to complete activation.'
            }
          };
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const newErr: any = new Error('Please wait a few seconds before requesting another transfer.');
        newErr.code = 'TOO_MANY_REQUESTS';
        throw newErr;
      }
      throw err;
    }
  }

  /**
   * Atomically approves transfer, reassigns activeInstallationId, revokes old device, and generates signedLeaseToken.
   */
  static async approveTransfer(ctx: RequestContext, env: Env, transferId: string, identity: CompositeIdentity, idempotencyKey?: string): Promise<{ success: boolean; data: any }> {
    return ctx.telemetry.measure('transfer.saga.duration', { transferId }, async () => {
    const transferDoc = await getDocument(ctx, env, 'device_transfers', transferId);
    const now = Date.now();

    if (!transferDoc || transferDoc.status !== 'PENDING' || now > transferDoc.expiresAtEpochMs) {
      const err: any = new Error('Transfer request is either expired, already resolved, or invalid.');
      err.code = 'TRANSFER_NOT_PENDING';
      throw err;
    }

    if (transferDoc.oldInstallationId !== identity.installationId && transferDoc.oldInstallationId !== identity.hardwareId) {
      const err: any = new Error('Only the current active device (`oldInstallationId`) can approve a transfer.');
      err.code = 'UNAUTHORIZED_APPROVAL';
      throw err;
    }

    const lockKey = transferDoc.subscriptionId || transferDoc.customerId;
    try {
      return await LockService.withLock(ctx, env,
        'transfer_lock',
        lockKey,
        30000,
        { customerId: identity.customerId, transferId, lockKey },
        async () => {
          let newHardwareId = transferDoc.newHardwareId;
          if (!newHardwareId) {
            newHardwareId = transferDoc.newInstallationId;
            try {
              const newInst = await getDocument(ctx, env, 'installations', transferDoc.newInstallationId);
              if (newInst && newInst.hardwareId) {
                newHardwareId = newInst.hardwareId;
              }
            } catch(e) {}
          }

          const ops = [];
          
          const isTrial = transferDoc.subscriptionId.startsWith('TRIAL_');
          let subDoc = null;
          let targetHardwareTrial = null;

          if (isTrial) {
            const hwId = transferDoc.subscriptionId.replace('TRIAL_', '');
            const trial = await getDocument(ctx, env, 'hardware_trials', hwId);
            if (trial) {
              subDoc = {
                subscriptionId: transferDoc.subscriptionId,
                customerId: trial.customerId,
                activeInstallationId: trial.hardwareId,
                planId: 'FREE_TRIAL_30',
                startsAtEpochMs: trial.startedAtEpochMs,
                expiresAtEpochMs: trial.expiresAtEpochMs
              };
            }
            targetHardwareTrial = await getDocument(ctx, env, 'hardware_trials', newHardwareId);
          } else {
            subDoc = await getDocument(ctx, env, 'subscriptions', transferDoc.subscriptionId);
          }

          const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
          
          const ownershipOp = await SubscriptionService.buildTransferOwnership(
            subDoc, isTrial, targetHardwareTrial, secretKey, transferDoc.subscriptionId, transferDoc.customerId, transferDoc.oldInstallationId, transferDoc.newInstallationId, newHardwareId, now
          );
          ops.push(...ownershipOp.writes);
          
          // Sweep ALL installations for this customer and revoke every one except the new device
          const allInsts = await queryCollection(ctx, env, 'installations', [{ field: 'customerId', op: 'EQUAL', value: transferDoc.customerId }]);
          for (const inst of allInsts) {
            if (inst.installationId !== transferDoc.newInstallationId && inst.hardwareId !== newHardwareId && inst.status !== 'REVOKED' && inst.status !== 'BANNED') {
              ops.push({
                collectionPath: 'installations',
                documentId: inst.installationId || inst.hardwareId,
                data: {
                  ...inst,
                  status: InstallationFSM.transition(inst, 'REVOKE'),
                  revokedAtEpochMs: now,
                  revokedReason: `Peer transfer approved (${transferId})`
                }
              });
            }
          }

          // For trials, sweep ALL trials for this customer and expire every one except the new device
          if (isTrial) {
            const allTrials = await queryCollection(ctx, env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: transferDoc.customerId }]);
            for (const t of allTrials) {
              if (t.hardwareId !== newHardwareId && t.hardwareId !== transferDoc.newInstallationId) {
                ops.push({
                  collectionPath: 'hardware_trials',
                  documentId: t.hardwareId,
                  data: {
                    ...t,
                    expiresAtEpochMs: 0,
                    updatedAtEpochMs: now
                  }
                });
              }
            }
          }
          
          const activationOp = InstallationService.buildActivation(transferDoc.newInstallationId, transferDoc.customerId, newHardwareId, { ...identity, installationUuid: transferDoc.newInstallationId } as any, transferDoc.deviceModel, null, now);
          ops.push(...activationOp.writes);
          
          ops.push({
            collectionPath: 'device_transfers',
            documentId: transferId,
            data: {
              ...transferDoc,
              status: TransferFSM.transition(transferDoc, 'APPROVE'),
              approvedBy: 'PEER_OLD_DEVICE',
              completedAtEpochMs: now
            }
          });
          
          const auditLogId = `aud_${generateShortId()}`;
          ops.push({
            collectionPath: 'audit_logs',
            documentId: auditLogId,
            data: {
              logId: auditLogId,
              event: 'TRANSFER_APPROVED_PEER',
              transferId,
              subscriptionId: transferDoc.subscriptionId,
              customerId: transferDoc.customerId,
              oldInstallationId: transferDoc.oldInstallationId,
              newInstallationId: transferDoc.newInstallationId,
              timestampEpochMs: now
            }
          });

          const responseData = {
            transferId,
            status: 'APPROVED',
            message: 'Transfer approved. This device has now been deactivated.'
          };

          if (idempotencyKey) {
            ops.push({
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

          await commitAtomicWrites(ctx, env, ops);

          try {
            await env.APK_STORE.delete(`ratelimit:transfer:${newHardwareId}`);
            await env.APK_STORE.delete(`ratelimit:transfer_hard:${newHardwareId}`);
            if (transferDoc.newInstallationId && transferDoc.newInstallationId !== newHardwareId) {
              await env.APK_STORE.delete(`ratelimit:transfer:${transferDoc.newInstallationId}`);
              await env.APK_STORE.delete(`ratelimit:transfer_hard:${transferDoc.newInstallationId}`);
            }
          } catch(e) {}

          return {
            success: true,
            data: responseData
          };
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const newErr: any = new Error('Subscription or trial is currently locked by another process.');
        newErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw newErr;
      }
      throw err;
    }
    }); // End of transfer.saga.duration telemetry wrapper
  }

  /**
   * Rejects transfer claim, preserving old device's rights.
   */
  static async rejectTransfer(ctx: RequestContext, env: Env, transferId: string, identity: CompositeIdentity, idempotencyKey?: string): Promise<{ success: boolean; data: any }> {
    const transferDoc = await getDocument(ctx, env, 'device_transfers', transferId);
    const now = Date.now();

    if (!transferDoc || transferDoc.status !== 'PENDING') {
      const err: any = new Error('Transfer request is not in PENDING state.');
      err.code = 'TRANSFER_NOT_PENDING';
      throw err;
    }

    if (transferDoc.oldInstallationId !== identity.installationId && transferDoc.oldInstallationId !== identity.hardwareId) {
      const err: any = new Error('Only the current active device can reject this transfer.');
      err.code = 'UNAUTHORIZED_REJECTION';
      throw err;
    }

    const lockKey = transferDoc.subscriptionId || transferDoc.customerId;
    try {
      return await LockService.withLock(ctx, env,
        'transfer_lock',
        lockKey,
        15000,
        { customerId: transferDoc.customerId, transferId, lockKey },
        async () => {
          const auditLogId = `aud_${generateShortId()}`;
          const batchWrites = [
            {
              collectionPath: 'device_transfers',
              documentId: transferId,
              data: {
                ...transferDoc,
                status: TransferFSM.transition(transferDoc, 'REJECT'),
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

          const responseData = {
            transferId,
            status: 'REJECTED',
            message: 'Transfer request rejected.'
          };

          if (idempotencyKey) {
            batchWrites.push({
              collectionPath: 'idempotency_keys',
              documentId: idempotencyKey,
              data: {
                keyId: idempotencyKey,
                expiresAtEpochMs: now + (24 * 3600000),
                responsePayload: JSON.stringify(responseData)
              }
            });
          }

          await commitAtomicWrites(ctx, env, batchWrites);

          return {
            success: true,
            data: responseData
          };
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const newErr: any = new Error('Transfer is currently locked by another process.');
        newErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw newErr;
      }
      throw err;
    }
  }

  /**
   * Cancels a transfer claim from the requesting device (new device).
   */
  static async cancelTransfer(ctx: RequestContext, env: Env, transferId: string, identity: CompositeIdentity): Promise<{ success: boolean; data: any }> {
    const transferDoc = await getDocument(ctx, env, 'device_transfers', transferId);
    if (!transferDoc) {
      const err: any = new Error('Transfer request not found.');
      err.code = 'TRANSFER_NOT_FOUND';
      throw err;
    }

    if (transferDoc.status !== 'PENDING') {
      const err: any = new Error(`Transfer request is already ${transferDoc.status}.`);
      err.code = 'TRANSFER_NOT_PENDING';
      throw err;
    }

    if (transferDoc.newInstallationId !== identity.installationId) {
      const err: any = new Error('Only the requesting device can cancel this transfer.');
      err.code = 'UNAUTHORIZED_CANCEL';
      throw err;
    }

    const lockKey = transferDoc.subscriptionId || transferDoc.customerId;
    try {
      return await LockService.withLock(ctx, env,
        'transfer_lock',
        lockKey,
        15000,
        { customerId: transferDoc.customerId, transferId, lockKey },
        async () => {
          const now = Date.now();
          const batchWrites = [
            {
              collectionPath: 'device_transfers',
              documentId: transferId,
              data: {
                ...transferDoc,
                status: TransferFSM.transition(transferDoc, 'CANCEL'),
                resolvedAtEpochMs: now,
                updatedAtEpochMs: now
              }
            }
          ];

          await commitAtomicWrites(ctx, env, batchWrites);

          return {
            success: true,
            data: {
              transferId,
              status: 'CANCELLED',
              message: 'Transfer request cancelled.'
            }
          };
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const newErr: any = new Error('Transfer is currently locked by another process.');
        newErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw newErr;
      }
      throw err;
    }
  }

  static async adminForceTransfer(ctx: RequestContext, env: Env, customerId: string, newHardwareId: string, adminUid: string, bodyDetails: any): Promise<{ success: boolean; data: any }> {
    let { sub: activeSub, isTrial, trialId, subscriptionId } = await findSubscription(ctx, env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
    const now = Date.now();
    const doWork = async () => {
      if (subscriptionId) {
        if (isTrial && trialId) {
          const trial = await getDocument(ctx, env, 'hardware_trials', trialId as string);
          if (trial) activeSub = trial;
        } else {
          const sub = await getDocument(ctx, env, 'subscriptions', subscriptionId);
          if (sub) activeSub = sub;
        }
      }
      const hardwareId = isTrial ? activeSub.hardwareId : activeSub.activeInstallationId;
      
      if (isTrial) {
        const targetTrial = await getDocument(ctx, env, 'hardware_trials', newHardwareId);
        if (targetTrial && (targetTrial.status === 'EXPIRED' || targetTrial.status === 'CANCELLED' || (targetTrial.expiresAtEpochMs && targetTrial.expiresAtEpochMs > 0 && now > targetTrial.expiresAtEpochMs))) {
           const err: any = new Error('Target device has an expired Free Trial. Cannot transfer another Free Trial to an expired device.');
           err.code = 'TRIAL_ALREADY_USED';
           throw err;
        }
      }

      const batchWrites = await this._buildForceTransferMutation(ctx, env, activeSub, isTrial, hardwareId, newHardwareId, adminUid, now, bodyDetails);
      await commitAtomicWrites(ctx, env, batchWrites);
      
      await resetRateLimit(env, `transfer:${newHardwareId}`);
      await resetRateLimit(env, `transfer_hard:${newHardwareId}`);
      
      return { success: true, data: { message: 'Subscription transferred successfully' } };
    };

    const lockName = 'transfer_lock';
    const lockKey = subscriptionId || (isTrial && trialId ? `TRIAL_${trialId}` : null) || customerId;

    if (lockKey) {
      return await LockService.withLock(ctx, env, lockName, lockKey, 30000, { customerId, lockKey, action: 'TRANSFER' }, doWork);
    } else {
      return await doWork();
    }
  }

  private static async _buildForceTransferMutation(ctx: RequestContext, env: Env, activeSub: any, isTrial: boolean, hardwareId: string, newHardwareId: string, adminUid: string, now: number, bodyDetails: any): Promise<AtomicWriteOp[]> {
    const batchWrites: AtomicWriteOp[] = [];
    if (isTrial) {
      const allTrials = await queryCollection(ctx, env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: activeSub.customerId }]);
      batchWrites.push({ collectionPath: 'hardware_trials', documentId: newHardwareId, data: { ...activeSub, hardwareId: newHardwareId, updatedAtEpochMs: now } });
      for (const t of allTrials) {
        if (t.hardwareId !== newHardwareId) {
          batchWrites.push({ collectionPath: 'hardware_trials', documentId: t.hardwareId, data: { ...t, expiresAtEpochMs: 0, updatedAtEpochMs: now } });
        }
      }
    } else {
      activeSub.activeInstallationId = newHardwareId;
      activeSub.updatedAtEpochMs = now;
      batchWrites.push({ collectionPath: 'subscriptions', documentId: activeSub.subscriptionId, data: activeSub });
    }
    
    // Ensure all other installations for this customer are revoked
    const allInsts = await queryCollection(ctx, env, 'installations', [{ field: 'customerId', op: 'EQUAL', value: activeSub.customerId }]);
    for (const inst of allInsts) {
      const instDocId = inst.installationId || inst.hardwareId || inst.documentId || inst.id;
      if (instDocId !== newHardwareId && inst.status !== 'REVOKED' && inst.status !== 'BANNED') {
        batchWrites.push({
          collectionPath: 'installations',
          documentId: instDocId,
          data: {
            ...inst,
            status: InstallationFSM.transition(inst, 'REVOKE'),
            revokedAtEpochMs: now,
            revokedReason: `Admin transfer override to ${newHardwareId}`
          }
        });
      }
    }
    const targetInst = await getDocument(ctx, env, 'installations', newHardwareId);
    if (targetInst) {
      batchWrites.push({
        collectionPath: 'installations',
        documentId: newHardwareId,
        data: {
          ...targetInst,
          customerId: activeSub.customerId,
          status: InstallationFSM.transition(targetInst, 'ACTIVATE'),
          updatedAtEpochMs: now
        }
      });
    } else {
      batchWrites.push({
        collectionPath: 'installations',
        documentId: newHardwareId,
        data: {
          installationId: newHardwareId,
          customerId: activeSub.customerId,
          hardwareId: newHardwareId,
          installationUuid: newHardwareId,
          platform: 'android',
          deviceModel: 'Unknown Device',
          appVersion: '1.0.0',
          status: InstallationFSM.transition({}, 'ACTIVATE'),
          createdAtEpochMs: now,
          lastSeenAtEpochMs: now
        }
      });
    }
    batchWrites.push(buildAuditLogOp('ADMIN_MANAGE_SUBSCRIPTION', { adminUid, customerId: activeSub.customerId, action: 'TRANSFER', details: bodyDetails }));
    return batchWrites;
  }

  static async adminApproveTransfer(ctx: RequestContext, env: Env, transferId: string, adminUid: string): Promise<{ success: boolean; data: any }> {
    const transferDoc = await getDocument(ctx, env, 'device_transfers', transferId);
    if (!transferDoc) {
      const err: any = new Error(`Transfer request ${transferId} not found.`);
      err.code = 'TRANSFER_NOT_FOUND'; throw err;
    }
    if (transferDoc.status !== 'PENDING' && transferDoc.status !== 'RATE_LIMITED') {
      const err: any = new Error(`Transfer request is already ${transferDoc.status}.`);
      err.code = 'TRANSFER_NOT_PENDING'; throw err;
    }

    const { subscriptionId, customerId } = transferDoc;
    const sourceInstallationId = transferDoc.oldInstallationId || transferDoc.sourceInstallationId;
    const targetInstallationId = transferDoc.newInstallationId || transferDoc.targetInstallationId;
    const now = Date.now();

    return await LockService.withLock(ctx, env,
      'sub_lock',
      subscriptionId,
      30000,
      { customerId, subscriptionId, transferId },
      async () => {
        let subDoc: any = null;
        let isTrial = false;

        // First, check if it's a paid subscription (even if it has a TRIAL_ prefix due to an upgrade)
        subDoc = await getDocument(ctx, env, 'subscriptions', subscriptionId);

        if (!subDoc && subscriptionId && subscriptionId.startsWith('TRIAL_')) {
          isTrial = true;
          const hardwareId = subscriptionId.replace('TRIAL_', '');
          const trial = await getDocument(ctx, env, 'hardware_trials', hardwareId);
          if (trial) {
            subDoc = {
              subscriptionId,
              customerId: trial.customerId,
              activeInstallationId: trial.hardwareId,
              planId: 'FREE_TRIAL_30',
              startsAtEpochMs: trial.startedAtEpochMs,
              expiresAtEpochMs: trial.expiresAtEpochMs
            };
          }
        }

        if (!subDoc) {
          const err: any = new Error('The subscription or trial associated with this transfer no longer exists.');
          err.code = 'SUBSCRIPTION_NOT_FOUND'; throw err;
        }
        
        if (isTrial) {
          const targetTrial = await getDocument(ctx, env, 'hardware_trials', targetInstallationId);
          if (targetTrial && (targetTrial.status === 'EXPIRED' || targetTrial.status === 'CANCELLED' || (targetTrial.expiresAtEpochMs && targetTrial.expiresAtEpochMs > 0 && now > targetTrial.expiresAtEpochMs))) {
            const err: any = new Error('Target device has an expired Free Trial. Cannot transfer another Free Trial to an expired device.');
            err.code = 'TRIAL_ALREADY_USED'; throw err;
          }
        }

        const { writes, newLeaseToken } = await this._buildApprovalMutation(ctx, env, transferId, transferDoc, subDoc, isTrial, targetInstallationId, sourceInstallationId, adminUid, now);
        await commitAtomicWrites(ctx, env, writes);

        try {
          await env.APK_STORE.delete(`ratelimit:transfer:${targetInstallationId}`);
          await env.APK_STORE.delete(`ratelimit:transfer_hard:${targetInstallationId}`);
          if (transferDoc.newHardwareId && transferDoc.newHardwareId !== targetInstallationId) {
            await env.APK_STORE.delete(`ratelimit:transfer:${transferDoc.newHardwareId}`);
            await env.APK_STORE.delete(`ratelimit:transfer_hard:${transferDoc.newHardwareId}`);
          }
        } catch(e) {}

        return {
          success: true,
          data: {
            transferId,
            status: 'APPROVED',
            message: 'Transfer manually approved and old device revoked.',
            newLeaseToken
          }
        };
      }
    );
  }

  private static async _buildApprovalMutation(ctx: RequestContext, env: Env, transferId: string, transferDoc: any, subDoc: any, isTrial: boolean, targetInstallationId: string, sourceInstallationId: string, adminUid: string, now: number): Promise<{ writes: AtomicWriteOp[], newLeaseToken: string }> {
    const batchWrites: AtomicWriteOp[] = [];

    const updatedTransfer = {
      ...transferDoc,
      status: TransferFSM.transition(transferDoc, 'APPROVE'),
      approvedBy: `ADMIN_${adminUid}`,
      updatedAtEpochMs: now
    };
    batchWrites.push({ collectionPath: 'device_transfers', documentId: transferId, data: updatedTransfer });

    // Sweep ALL installations for this customer and revoke every one except the target device
    const allInsts = await queryCollection(ctx, env, 'installations', [{ field: 'customerId', op: 'EQUAL', value: subDoc.customerId }]);
    for (const inst of allInsts) {
      const instDocId = inst.installationId || inst.hardwareId;
      if (instDocId !== targetInstallationId && inst.status !== 'REVOKED' && inst.status !== 'BANNED') {
        batchWrites.push({
          collectionPath: 'installations',
          documentId: instDocId,
          data: {
            ...inst,
            status: InstallationFSM.transition(inst, 'REVOKE'),
            revokedAtEpochMs: now,
            revokedReason: `Admin approved transfer ${transferId} (Lost/Broken Phone override)`
          }
        });
      }
    }

    const targetInst = await getDocument(ctx, env, 'installations', targetInstallationId);
    if (targetInst) {
      batchWrites.push({
        collectionPath: 'installations',
        documentId: targetInstallationId,
        data: {
          ...targetInst,
          customerId: subDoc.customerId,
          status: InstallationFSM.transition(targetInst, 'ACTIVATE'),
          updatedAtEpochMs: now
        }
      });
    } else {
      batchWrites.push({
        collectionPath: 'installations',
        documentId: targetInstallationId,
        data: {
          installationId: targetInstallationId,
          customerId: subDoc.customerId,
          hardwareId: targetInstallationId,
          installationUuid: targetInstallationId,
          platform: 'android',
          deviceModel: transferDoc.deviceModel || 'Unknown Device',
          appVersion: '1.0.0',
          status: InstallationFSM.transition({}, 'ACTIVATE'),
          createdAtEpochMs: now,
          lastSeenAtEpochMs: now
        }
      });
    }

    const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
    const leasePayload = {
      subscriptionId: subDoc.subscriptionId,
      customerId: subDoc.customerId,
      activeInstallationId: targetInstallationId,
      planId: subDoc.planId || 'PRO_YEARLY',
      planName: subDoc.planName || 'Pro Annual License',
      startsAtEpochMs: subDoc.startsAtEpochMs || now,
      expiresAtEpochMs: subDoc.expiresAtEpochMs || (now + 395 * 86400 * 1000),
      maxCustomers: 10000,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      issuedAt: now
    };
    const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

    if (isTrial) {
      const sourceTrialHwId = subDoc.subscriptionId.replace('TRIAL_', '');
      const sourceTrial = await getDocument(ctx, env, 'hardware_trials', sourceTrialHwId);
      if (sourceTrial) {
        // Create new trial for target device
        batchWrites.push({
          collectionPath: 'hardware_trials',
          documentId: targetInstallationId,
          data: {
            ...sourceTrial,
            hardwareId: targetInstallationId,
            signedLeaseToken,
            leaseIssuedAtEpochMs: now,
            lastLeasePlanId: 'FREE_TRIAL_30',
            lastLeaseDeviceId: targetInstallationId,
            updatedAtEpochMs: now
          }
        });
      }
      // Sweep ALL trials for this customer and expire every one except the target device
      const allTrials = await queryCollection(ctx, env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: subDoc.customerId }]);
      for (const t of allTrials) {
        if (t.hardwareId !== targetInstallationId) {
          batchWrites.push({
            collectionPath: 'hardware_trials',
            documentId: t.hardwareId,
            data: {
              ...t,
              expiresAtEpochMs: 0,
              updatedAtEpochMs: now
            }
          });
        }
      }
    } else {
      batchWrites.push({
        collectionPath: 'subscriptions',
        documentId: subDoc.subscriptionId,
        data: {
          ...subDoc,
          activeInstallationId: targetInstallationId,
          signedLeaseToken,
          leaseIssuedAtEpochMs: now,
          lastLeasePlanId: subDoc.planId || 'PRO_YEARLY',
          lastLeaseDeviceId: targetInstallationId,
          updatedAtEpochMs: now
        }
      });
    }

    batchWrites.push(buildAuditLogOp('ADMIN_APPROVED_TRANSFER_LOST_DEVICE', {
      adminUid,
      transferId,
      subscriptionId: subDoc.subscriptionId,
      sourceInstallationId,
      targetInstallationId
    }));

    return { writes: batchWrites, newLeaseToken: signedLeaseToken };
  }

  static async adminRejectTransfer(ctx: RequestContext, env: Env, transferId: string, adminUid: string): Promise<{ success: boolean; data: any }> {
    const transferDoc = await getDocument(ctx, env, 'device_transfers', transferId);
    if (!transferDoc) {
      const err: any = new Error(`Transfer request ${transferId} not found.`);
      err.code = 'TRANSFER_NOT_FOUND'; throw err;
    }
    if (transferDoc.status !== 'PENDING' && transferDoc.status !== 'RATE_LIMITED') {
      const err: any = new Error(`Transfer request is already ${transferDoc.status}.`);
      err.code = 'TRANSFER_NOT_PENDING'; throw err;
    }

    const batchWrites = this._buildRejectionMutation(transferId, transferDoc, adminUid, Date.now());
    await commitAtomicWrites(ctx, env, batchWrites);
    return { success: true, data: { status: 'REJECTED', message: 'Transfer request rejected successfully.' } };
  }

  private static _buildRejectionMutation(transferId: string, transferDoc: any, adminUid: string, now: number): AtomicWriteOp[] {
    const updatedTransfer = {
      ...transferDoc,
      status: TransferFSM.transition(transferDoc, 'REJECT'),
      rejectedBy: `ADMIN_${adminUid}`,
      updatedAtEpochMs: now
    };
    return [
      { collectionPath: 'device_transfers', documentId: transferId, data: updatedTransfer },
      buildAuditLogOp('ADMIN_REJECTED_TRANSFER', { adminUid, transferId, subscriptionId: transferDoc.subscriptionId })
    ];
  }
}
