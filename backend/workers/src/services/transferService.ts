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

export class TransferService {
  /**
   * Initiates a Peer-to-Peer device transfer claim.
   */
  static async requestTransfer(ctx: RequestContext, env: Env, customerId: string | undefined, subscriptionId: string | undefined, mobileNumber: string | undefined, identity: CompositeIdentity, deviceModel: string): Promise<{ success: boolean; data: any }> {
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
      if (subscriptionId.startsWith('TRIAL_')) {
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
      } else {
        sub = await getDocument(ctx, env, 'subscriptions', subscriptionId);
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
          if (recentTransfers.length >= 5) {
            const err: any = new Error('Too many transfer attempts. Please try again tomorrow to protect the account owner from spam.');
            err.code = 'TOO_MANY_REQUESTS';
            throw err;
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
            if (trialHistory) {
              const err: any = new Error('This device has already used a 30-Day Free Trial. Please purchase a Pro Plan to use this device.');
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
            status: TransferFSM.transition({}, 'REQUEST'),
            requestedAtEpochMs: now,
            expiresAtEpochMs
          };

          await setDocument(ctx, env, 'device_transfers', transferId, transferData);

          const oldInstallationId = sub.activeInstallationId;
          if (oldInstallationId) {
            try {
              const oldInstallation = await getDocument(ctx, env, 'installations', oldInstallationId);
              if (oldInstallation && oldInstallation.fcmToken) {
                await sendFcmNotification(ctx, env,
                  oldInstallation.fcmToken,
                  'Device Transfer Request',
                  'Another device is trying to claim your active VendSoft license.',
                  { transferId }
                );
              }
            } catch (fcmErr) {
              ctx.logger.error('FCM Notification error:', fcmErr);
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
          
          const oldInst = await getDocument(ctx, env, 'installations', transferDoc.oldInstallationId);
          const revocationOp = InstallationService.buildRevocation(oldInst, transferDoc.oldInstallationId, 'Transfer approved', now);
          ops.push(...revocationOp.writes);
          
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
        if (targetTrial) {
           const err: any = new Error('Target device has already used a trial.');
           err.code = 'TRIAL_ALREADY_USED';
           throw err;
        }
      }

      const batchWrites = await this._buildForceTransferMutation(ctx, env, activeSub, isTrial, hardwareId, newHardwareId, adminUid, now, bodyDetails);
      await commitAtomicWrites(ctx, env, batchWrites);
      
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
      batchWrites.push({ collectionPath: 'hardware_trials', documentId: newHardwareId, data: { ...activeSub, hardwareId: newHardwareId, updatedAtEpochMs: now } });
      batchWrites.push({ collectionPath: 'hardware_trials', documentId: hardwareId, data: { ...activeSub, expiresAtEpochMs: 0, updatedAtEpochMs: now } });
    } else {
      activeSub.activeInstallationId = newHardwareId;
      activeSub.updatedAtEpochMs = now;
      batchWrites.push({ collectionPath: 'subscriptions', documentId: activeSub.subscriptionId, data: activeSub });
    }
    
    if (hardwareId && hardwareId !== newHardwareId) {
      const sourceInst = await getDocument(ctx, env, 'installations', hardwareId);
      if (sourceInst) {
        batchWrites.push({
          collectionPath: 'installations',
          documentId: hardwareId,
          data: {
            ...sourceInst,
            status: InstallationFSM.transition(sourceInst, 'REVOKE'),
            revokedAtEpochMs: now,
            revokedReason: `Admin transfer override to ${newHardwareId}`
          }
        });
      }
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
    if (transferDoc.status !== 'PENDING') {
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
        if (subscriptionId && subscriptionId.startsWith('TRIAL_')) {
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
        } else {
          subDoc = await getDocument(ctx, env, 'subscriptions', subscriptionId);
        }

        if (!subDoc) {
          const err: any = new Error('The subscription or trial associated with this transfer no longer exists.');
          err.code = 'SUBSCRIPTION_NOT_FOUND'; throw err;
        }
        
        if (isTrial) {
          const targetTrial = await getDocument(ctx, env, 'hardware_trials', targetInstallationId);
          if (targetTrial) {
            const err: any = new Error('Target device has already used a trial. Admin cannot force transfer a trial to a device that has already used one.');
            err.code = 'TRIAL_ALREADY_USED'; throw err;
          }
        }

        const { writes, newLeaseToken } = await this._buildApprovalMutation(ctx, env, transferId, transferDoc, subDoc, isTrial, targetInstallationId, sourceInstallationId, adminUid, now);
        await commitAtomicWrites(ctx, env, writes);

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

    if (sourceInstallationId && sourceInstallationId !== targetInstallationId) {
      const sourceInst = await getDocument(ctx, env, 'installations', sourceInstallationId);
      if (sourceInst) {
        batchWrites.push({
          collectionPath: 'installations',
          documentId: sourceInstallationId,
          data: {
            ...sourceInst,
            status: InstallationFSM.transition(sourceInst, 'REVOKE'),
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
      expiresAtEpochMs: subDoc.expiresAtEpochMs || (now + 365 * 86400 * 1000),
      maxCustomers: 10000,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      issuedAt: now
    };
    const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

    if (isTrial) {
      const hardwareId = subDoc.subscriptionId.replace('TRIAL_', '');
      const trial = await getDocument(ctx, env, 'hardware_trials', hardwareId);
      if (trial) {
        batchWrites.push({
          collectionPath: 'hardware_trials',
          documentId: targetInstallationId,
          data: {
            ...trial,
            hardwareId: targetInstallationId,
            signedLeaseToken,
            leaseIssuedAtEpochMs: now,
            lastLeasePlanId: 'FREE_TRIAL_30',
            lastLeaseDeviceId: targetInstallationId,
            updatedAtEpochMs: now
          }
        });
        batchWrites.push({
          collectionPath: 'hardware_trials',
          documentId: hardwareId,
          data: {
            ...trial,
            expiresAtEpochMs: 0
          }
        });
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
    if (transferDoc.status !== 'PENDING') {
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
