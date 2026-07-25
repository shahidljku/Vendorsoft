import { Env, CompositeIdentity } from '../types';
import { getDocument, setDocument, queryCollection, commitAtomicWrites, sendFcmNotification } from './firestore';
import { generateShortId } from '../cryptoEngine';
import { LockService } from './lock';
import { findSubscription, DiscoveryStrategy } from './discovery';
import { TransferFSM } from './fsm/transferFSM';
import { SubscriptionService } from './subscriptionService';
import { InstallationService } from './installationService';

export class TransferService {
  /**
   * Initiates a Peer-to-Peer device transfer claim.
   */
  static async requestTransfer(env: Env, customerId: string | undefined, subscriptionId: string | undefined, mobileNumber: string | undefined, identity: CompositeIdentity, deviceModel: string): Promise<{ success: boolean; data: any }> {
    const now = Date.now();

    // Lookup customer by mobile number if customerId is not directly provided
    if (!customerId && !subscriptionId && mobileNumber) {
      const customers = await queryCollection(env, 'customers', [
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
            const trialHistory = await getDocument(env, 'hardware_trials', identity.hardwareId);
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

          await setDocument(env, 'device_transfers', transferId, transferData);

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
  static async approveTransfer(env: Env, transferId: string, identity: CompositeIdentity, idempotencyKey?: string): Promise<{ success: boolean; data: any }> {
    const transferDoc = await getDocument(env, 'device_transfers', transferId);
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

    try {
      return await LockService.withLock(
        env,
        'sub_lock',
        transferDoc.subscriptionId,
        30000,
        { customerId: identity.customerId, transferId },
        async () => {
          let newHardwareId = transferDoc.newHardwareId;
          if (!newHardwareId) {
            newHardwareId = transferDoc.newInstallationId;
            try {
              const newInst = await getDocument(env, 'installations', transferDoc.newInstallationId);
              if (newInst && newInst.hardwareId) {
                newHardwareId = newInst.hardwareId;
              }
            } catch(e) {}
          }

          const ops = [];
          
          const ownershipOp = await SubscriptionService.buildTransferOwnership(
            env, transferDoc.subscriptionId, transferDoc.customerId, transferDoc.oldInstallationId, transferDoc.newInstallationId, newHardwareId, now
          );
          ops.push(...ownershipOp.writes);
          
          const revocationOp = await InstallationService.buildRevocation(env, transferDoc.oldInstallationId, 'Transfer approved', now);
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

          await commitAtomicWrites(env, ops);

          return {
            success: true,
            data: responseData
          };
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const newErr: any = new Error('Subscription is currently locked by another process.');
        newErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw newErr;
      }
      throw err;
    }
  }

  /**
   * Rejects transfer claim, preserving old device's rights.
   */
  static async rejectTransfer(env: Env, transferId: string, identity: CompositeIdentity, idempotencyKey?: string): Promise<{ success: boolean; data: any }> {
    const transferDoc = await getDocument(env, 'device_transfers', transferId);
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

    await commitAtomicWrites(env, batchWrites);

    return {
      success: true,
      data: responseData
    };
  }

  /**
   * Cancels a transfer claim from the requesting device (new device).
   */
  static async cancelTransfer(env: Env, transferId: string, identity: CompositeIdentity): Promise<{ success: boolean; data: any }> {
    const transferDoc = await getDocument(env, 'device_transfers', transferId);
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

    await commitAtomicWrites(env, batchWrites);

    return {
      success: true,
      data: {
        transferId,
        status: 'CANCELLED',
        message: 'Transfer request cancelled.'
      }
    };
  }
}
