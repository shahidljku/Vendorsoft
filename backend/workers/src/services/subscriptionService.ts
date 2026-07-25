import { Env } from '../types';
import { getDocument, setDocument, commitAtomicWrites, queryCollection, logAuditEvent } from './firestore';
import { findSubscription, DiscoveryStrategy } from './discovery';
import { LockService } from './lock';
import { SubscriptionFSM } from './fsm/subscriptionFSM';
import { generateSignedLeaseToken } from '../cryptoEngine';
import { DomainMutation } from '../types';

export class SubscriptionService {
  /**
   * Extends the expiration date of the current active subscription or trial.
   */
  static async extendSubscription(env: Env, customerId: string, daysToAdd: number): Promise<{ success: boolean; message: string }> {
    if (typeof daysToAdd !== 'number') {
      const err: any = new Error('daysToAdd must be a number.');
      err.code = 'MISSING_DAYS';
      throw err;
    }

    let { sub: activeSub, isTrial, trialId, subscriptionId } = await findSubscription(env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
    const now = Date.now();

    const doWork = async () => {
      if (subscriptionId) {
        if (isTrial && trialId) {
          const trial = await getDocument(env, 'hardware_trials', trialId);
          if (trial) activeSub = trial;
        } else {
          const sub = await getDocument(env, 'subscriptions', subscriptionId);
          if (sub) activeSub = sub;
        }
      }

      const newExpiresAt = (activeSub?.expiresAtEpochMs || now) + (daysToAdd * 86400 * 1000);

      if (!activeSub) {
        let hwId = null;
        const installs = await queryCollection(env, 'installations', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
        if (installs.length > 0) {
          installs.sort((a: any, b: any) => (b.lastSeenAtEpochMs || 0) - (a.lastSeenAtEpochMs || 0));
          hwId = installs[0].hardwareId || installs[0].installationId;
        }

        const newSubId = `SUB_${crypto.randomUUID()}`;
        activeSub = {
          subscriptionId: newSubId,
          customerId,
          activeInstallationId: hwId,
          planId: 'FREE_TRIAL_30',
          status: SubscriptionFSM.transition({}, 'ACTIVATE'),
          startsAtEpochMs: now,
          expiresAtEpochMs: newExpiresAt,
          createdAtEpochMs: now,
          updatedAtEpochMs: now
        };
        await setDocument(env, 'subscriptions', newSubId, activeSub);
      } else {
        activeSub.expiresAtEpochMs = newExpiresAt;
        activeSub.status = SubscriptionFSM.transition(activeSub, 'ACTIVATE');
        activeSub.updatedAtEpochMs = now;
        
        if (isTrial && trialId) {
          await setDocument(env, 'hardware_trials', trialId, activeSub);
        } else {
          await setDocument(env, 'subscriptions', activeSub.subscriptionId, activeSub);
        }
      }

      return { success: true, message: 'Subscription extended successfully' };
    };

    if (subscriptionId) {
      try {
        return await LockService.withLock(env, 'sub_lock', subscriptionId, 30000, { customerId, subscriptionId }, doWork);
      } catch (err: any) {
        if (err.code === 'ALREADY_EXISTS') {
          const newErr: any = new Error('Subscription is currently locked by another process.');
          newErr.code = 'CONCURRENT_MUTATION_LOCKED';
          throw newErr;
        }
        throw err;
      }
    } else {
      return await doWork();
    }
  }

  /**
   * Changes the plan of the current subscription, generating a new subscription record if needed.
   */
  static async changePlan(env: Env, customerId: string, newPlanId: string): Promise<{ success: boolean; message: string }> {
    if (!newPlanId) {
      const err: any = new Error('newPlanId is required.');
      err.code = 'MISSING_PLAN_ID';
      throw err;
    }

    let { sub: activeSub, isTrial, trialId, subscriptionId } = await findSubscription(env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
    const now = Date.now();

    const doWork = async () => {
      if (subscriptionId) {
        if (isTrial && trialId) {
          const trial = await getDocument(env, 'hardware_trials', trialId);
          if (trial) activeSub = trial;
        } else {
          const sub = await getDocument(env, 'subscriptions', subscriptionId);
          if (sub) activeSub = sub;
        }
      }

      const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any> }> = [];
      
      if (isTrial || !activeSub) {
        let hwId = activeSub?.hardwareId || activeSub?.activeInstallationId;
        if (!hwId) {
          const installs = await queryCollection(env, 'installations', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
          if (installs.length > 0) {
            installs.sort((a: any, b: any) => (b.lastSeenAtEpochMs || 0) - (a.lastSeenAtEpochMs || 0));
            hwId = installs[0].hardwareId || installs[0].installationId;
          }
        }
        
        let planDays = 30;
        if (newPlanId.includes('YEAR')) planDays = 365;
        let baseDate = new Date();
        baseDate.setDate(baseDate.getDate() + planDays);
        
        const newSubId = `SUB_${crypto.randomUUID()}`;
        const newSub = {
          subscriptionId: newSubId,
          customerId,
          activeInstallationId: hwId,
          planId: newPlanId,
          status: SubscriptionFSM.transition({}, 'ACTIVATE'),
          startsAtEpochMs: now,
          expiresAtEpochMs: baseDate.getTime(),
          createdAtEpochMs: now,
          updatedAtEpochMs: now
        };
        batchWrites.push({ collectionPath: 'subscriptions', documentId: newSubId, data: newSub });
        
        if (isTrial && trialId) {
          const oldTrial = await getDocument(env, 'hardware_trials', trialId);
          if (oldTrial) {
            batchWrites.push({ collectionPath: 'hardware_trials', documentId: trialId, data: { ...oldTrial, expiresAtEpochMs: 0 } });
          }
        }
      } else {
        activeSub.planId = newPlanId;
        activeSub.updatedAtEpochMs = now;
        batchWrites.push({ collectionPath: 'subscriptions', documentId: activeSub.subscriptionId, data: activeSub });
      }
      
      await commitAtomicWrites(env, batchWrites);
      return { success: true, message: 'Subscription plan changed successfully' };
    };

    if (subscriptionId) {
      try {
        return await LockService.withLock(env, 'sub_lock', subscriptionId, 30000, { customerId, subscriptionId }, doWork);
      } catch (err: any) {
        if (err.code === 'ALREADY_EXISTS') {
          const newErr: any = new Error('Subscription is currently locked by another process.');
          newErr.code = 'CONCURRENT_MUTATION_LOCKED';
          throw newErr;
        }
        throw err;
      }
    } else {
      return await doWork();
    }
  }

  /**
   * Cancels the active subscription or trial. Note that revocation of devices is 
   * an InstallationService responsibility and is left to be orchestrated inline by the route for now.
   */
  static async cancelSubscription(env: Env, customerId: string): Promise<{ success: boolean; hardwareIdToRevoke: string | null }> {
    let { sub: activeSub, isTrial, trialId, subscriptionId } = await findSubscription(env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
    const now = Date.now();

    const doWork = async () => {
      if (!activeSub) {
        const err: any = new Error('No active subscription found.');
        err.code = 'SUBSCRIPTION_NOT_FOUND';
        throw err;
      }

      if (subscriptionId) {
        if (isTrial && trialId) {
          const trial = await getDocument(env, 'hardware_trials', trialId);
          if (trial) activeSub = trial;
        } else {
          const sub = await getDocument(env, 'subscriptions', subscriptionId);
          if (sub) activeSub = sub;
        }
      }

      const hardwareIdToRevoke = isTrial ? activeSub.hardwareId : activeSub.activeInstallationId;
      
      if (isTrial && trialId) {
        activeSub.status = SubscriptionFSM.transition(activeSub, 'CANCEL');
        await setDocument(env, 'hardware_trials', trialId, activeSub);
      } else if (activeSub.subscriptionId) {
        activeSub.status = SubscriptionFSM.transition(activeSub, 'CANCEL');
        activeSub.updatedAtEpochMs = now;
        await setDocument(env, 'subscriptions', activeSub.subscriptionId, activeSub);
      }

      return { success: true, hardwareIdToRevoke };
    };

    if (subscriptionId) {
      try {
        return await LockService.withLock(env, 'sub_lock', subscriptionId, 30000, { customerId, subscriptionId }, doWork);
      } catch (err: any) {
        if (err.code === 'ALREADY_EXISTS') {
          const newErr: any = new Error('Subscription is currently locked by another process.');
          newErr.code = 'CONCURRENT_MUTATION_LOCKED';
          throw newErr;
        }
        throw err;
      }
    } else {
      return await doWork();
    }
  }

  /**
   * Builds the atomic mutations required to transfer ownership of a subscription.
   * Returns a DomainMutation containing the writes and the newly generated signedLeaseToken.
   */
  static async buildTransferOwnership(
    env: Env, 
    subscriptionId: string, 
    customerId: string, 
    oldInstallationId: string, 
    newInstallationId: string, 
    newHardwareId: string,
    now: number
  ): Promise<DomainMutation<{ signedLeaseToken: string }>> {
    let sub: any = null;
    let isTrial = false;
    
    if (subscriptionId.startsWith('TRIAL_')) {
      isTrial = true;
      const hardwareId = subscriptionId.replace('TRIAL_', '');
      const trial = await getDocument(env, 'hardware_trials', hardwareId);
      if (trial) {
        sub = {
          subscriptionId,
          customerId: trial.customerId,
          activeInstallationId: trial.hardwareId,
          planId: 'FREE_TRIAL_30',
          startsAtEpochMs: trial.startedAtEpochMs,
          expiresAtEpochMs: trial.expiresAtEpochMs
        };
      }
    } else {
      sub = await getDocument(env, 'subscriptions', subscriptionId);
    }

    if (!sub) {
      const err: any = new Error('The subscription or trial associated with this transfer no longer exists.');
      err.code = 'SUBSCRIPTION_NOT_FOUND';
      throw err;
    }

    if (sub.activeInstallationId !== oldInstallationId) {
      const err: any = new Error('This subscription has already been transferred to a different device.');
      err.code = 'TRANSFER_ALREADY_PROCESSED';
      throw err;
    }

    if (isTrial) {
      const trialHistory = await getDocument(env, 'hardware_trials', newHardwareId);
      if (trialHistory) {
        const err: any = new Error('The receiving device has already used a Free Trial. Transfer aborted.');
        err.code = 'TRIAL_ALREADY_USED';
        throw err;
      }
    }

    const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
    const leasePayload = {
      subscriptionId: sub.subscriptionId,
      customerId: sub.customerId,
      activeInstallationId: newInstallationId,
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

    const writes: any[] = [];
    if (isTrial) {
      writes.push({
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
      writes.push({
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
      writes.push({
        collectionPath: 'subscriptions',
        documentId: sub.subscriptionId,
        data: {
          ...sub,
          activeInstallationId: newInstallationId,
          signedLeaseToken,
          updatedAtEpochMs: now
        }
      });
    }

    return { writes, result: { signedLeaseToken } };
  }

  /**
   * Builds the atomic mutations required to provision or renew a subscription.
   * Returns a DomainMutation containing the writes, the newly generated signedLeaseToken, and the new expiry.
   */
  static async buildProvisioning(
    env: Env,
    subscriptionId: string,
    customerId: string,
    installationId: string,
    planId: string,
    planName: string,
    durationDays: number,
    now: number
  ): Promise<DomainMutation<{ signedLeaseToken: string, newExpiresAt: number }>> {
    let subDoc: any = null;
    let isTrial = false;

    if (subscriptionId.startsWith('TRIAL_')) {
      isTrial = true;
      const hardwareId = subscriptionId.replace('TRIAL_', '');
      const trial = await getDocument(env, 'hardware_trials', hardwareId);
      if (trial) {
        subDoc = {
          subscriptionId,
          customerId: trial.customerId,
          activeInstallationId: trial.hardwareId,
          planId: 'FREE_TRIAL_30',
          status: trial.expiresAtEpochMs > now ? 'ACTIVE' : 'EXPIRED',
          expiresAtEpochMs: trial.expiresAtEpochMs,
          startsAtEpochMs: trial.startsAtEpochMs
        };
      }
    } else {
      subDoc = await getDocument(env, 'subscriptions', subscriptionId);
    }

    if (subDoc && subDoc.status === 'ACTIVE' && subDoc.expiresAtEpochMs > now) {
      if (subDoc.activeInstallationId && subDoc.activeInstallationId !== installationId) {
        const err: any = new Error('Ownership conflict: Subscription belongs to another installation.');
        err.code = 'OWNERSHIP_CONFLICT';
        throw err;
      }
    }

    let currentExpiresAt = subDoc && typeof subDoc.expiresAtEpochMs === 'number' ? subDoc.expiresAtEpochMs : now;
    const baseTime = currentExpiresAt > now ? currentExpiresAt : now;
    const newExpiresAt = baseTime + (durationDays * 86400000);

    const leasePayload = {
      subscriptionId,
      customerId,
      activeInstallationId: installationId,
      planId,
      planName,
      startsAtEpochMs: subDoc && subDoc.startsAtEpochMs ? subDoc.startsAtEpochMs : now,
      expiresAtEpochMs: newExpiresAt,
      maxCustomers: planId === 'PRO_YEARLY' ? 10000 : 1000,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      issuedAt: now
    };

    const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
    const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

    const writes = [{
      collectionPath: 'subscriptions',
      documentId: subscriptionId,
      data: {
        subscriptionId,
        customerId,
        activeInstallationId: installationId,
        planId,
        planName,
        status: SubscriptionFSM.transition({}, 'ACTIVATE'),
        startsAtEpochMs: leasePayload.startsAtEpochMs,
        expiresAtEpochMs: newExpiresAt,
        signedLeaseToken,
        updatedAtEpochMs: now
      }
    }];

    return { writes, result: { signedLeaseToken, newExpiresAt } };
  }
}
