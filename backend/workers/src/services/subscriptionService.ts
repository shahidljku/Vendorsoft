import { getDocument, setDocument, commitAtomicWrites, queryCollection, logAuditEvent, AtomicWriteOp } from './firestore';
import { RequestContext } from './logger';
import { Env } from '../types';
import { findSubscription, DiscoveryStrategy } from './discovery';
import { LockService } from './lock';
import { SubscriptionFSM } from './fsm/subscriptionFSM';
import { generateSignedLeaseToken } from '../cryptoEngine';
import { DomainMutation } from '../types';

export class SubscriptionService {
  /**
   * Extends the expiration date of the current active subscription or trial.
   */
  static async extendSubscription(ctx: RequestContext, env: Env, customerId: string, daysToAdd: number, auditOp?: AtomicWriteOp): Promise<{ success: boolean; message: string }> {
    if (typeof daysToAdd !== 'number' || Number.isNaN(daysToAdd)) {
      const err: any = new Error('daysToAdd must be a valid number.');
      err.code = 'MISSING_DAYS';
      throw err;
    }

    let { sub: activeSub, isTrial, trialId, subscriptionId } = await findSubscription(ctx, env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
    const now = Date.now();

    const doWork = async () => {
      if (subscriptionId) {
        if (isTrial && trialId) {
          const trial = await getDocument(ctx, env, 'hardware_trials', trialId);
          if (trial) activeSub = trial;
        } else {
          const sub = await getDocument(ctx, env, 'subscriptions', subscriptionId);
          if (sub) activeSub = sub;
        }
      }

      let baseTime = now;
      if (activeSub && activeSub.status !== 'CANCELLED' && activeSub.expiresAtEpochMs && activeSub.expiresAtEpochMs > now) {
        baseTime = activeSub.expiresAtEpochMs;
      }
      const newExpiresAt = baseTime + (daysToAdd * 86400 * 1000);

      if (!activeSub) {
        let hwId = null;
        const installs = await queryCollection(ctx, env, 'installations', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
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
        const writes: AtomicWriteOp[] = [
          { collectionPath: 'subscriptions', documentId: newSubId, data: activeSub }
        ];
        if (auditOp) writes.push(auditOp);
        await commitAtomicWrites(ctx, env, writes);
      } else {
        activeSub.expiresAtEpochMs = newExpiresAt;
        activeSub.status = SubscriptionFSM.transition(activeSub, 'ACTIVATE');
        activeSub.updatedAtEpochMs = now;
        
        const writes: AtomicWriteOp[] = [];
        if (isTrial && trialId) {
          writes.push({ collectionPath: 'hardware_trials', documentId: trialId, data: activeSub });
        } else {
          writes.push({ collectionPath: 'subscriptions', documentId: activeSub.subscriptionId, data: activeSub });
        }
        if (auditOp) writes.push(auditOp);
        await commitAtomicWrites(ctx, env, writes);
      }

      return { success: true, message: 'Subscription extended successfully' };
    };

    if (subscriptionId) {
      try {
        return await LockService.withLock(ctx, env, 'sub_lock', subscriptionId, 30000, { customerId, subscriptionId }, doWork);
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
  static async changePlan(ctx: RequestContext, env: Env, customerId: string, newPlanId: string, auditOp?: AtomicWriteOp): Promise<{ success: boolean; message: string }> {
    if (!newPlanId) {
      const err: any = new Error('newPlanId is required.');
      err.code = 'MISSING_PLAN_ID';
      throw err;
    }

    let { sub: activeSub, isTrial, trialId, subscriptionId } = await findSubscription(ctx, env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
    const now = Date.now();

    const doWork = async () => {
      if (subscriptionId) {
        if (isTrial && trialId) {
          const trial = await getDocument(ctx, env, 'hardware_trials', trialId);
          if (trial) activeSub = trial;
        } else {
          const sub = await getDocument(ctx, env, 'subscriptions', subscriptionId);
          if (sub) activeSub = sub;
        }
      }

      const batchWrites: Array<AtomicWriteOp> = [];
      
      if (isTrial || !activeSub) {
        let hwId = activeSub?.hardwareId || activeSub?.activeInstallationId;
        if (!hwId) {
          const installs = await queryCollection(ctx, env, 'installations', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
          if (installs.length > 0) {
            installs.sort((a: any, b: any) => (b.lastSeenAtEpochMs || 0) - (a.lastSeenAtEpochMs || 0));
            hwId = installs[0].hardwareId || installs[0].installationId;
          }
        }
        
        let planDays = 30;
        if (newPlanId.includes('YEAR')) planDays = 395;
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
          const oldTrial = await getDocument(ctx, env, 'hardware_trials', trialId);
          if (oldTrial) {
            batchWrites.push({ collectionPath: 'hardware_trials', documentId: trialId, data: { ...oldTrial, expiresAtEpochMs: 0 } });
          }
        }
      } else {
        activeSub.planId = newPlanId;
        
        let planDays = 0;
        if (newPlanId === 'PRO_MONTHLY') planDays = 30;
        if (newPlanId === 'PRO_YEARLY') planDays = 395;
        
        if (planDays > 0) {
          const baseTime = (activeSub.status !== 'CANCELLED' && activeSub.expiresAtEpochMs && activeSub.expiresAtEpochMs > now) ? activeSub.expiresAtEpochMs : now;
          activeSub.expiresAtEpochMs = baseTime + (planDays * 86400000);
        }

        activeSub.updatedAtEpochMs = now;
        batchWrites.push({ collectionPath: 'subscriptions', documentId: activeSub.subscriptionId, data: activeSub });
      }
      
      if (auditOp) batchWrites.push(auditOp);
      await commitAtomicWrites(ctx, env, batchWrites);
      return { success: true, message: 'Subscription plan changed successfully' };
    };

    if (subscriptionId) {
      try {
        return await LockService.withLock(ctx, env, 'sub_lock', subscriptionId, 30000, { customerId, subscriptionId }, doWork);
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
   * Builds the atomic mutations required to cancel an active subscription or trial.
   * Returns a DomainMutation containing the writes.
   */
  static buildCancellation(
    activeSub: any,
    isTrial: boolean,
    trialId: string | null,
    now: number
  ): DomainMutation<{ hardwareIdToRevoke: string | null }> {
    const hardwareIdToRevoke = null;
    const writes: AtomicWriteOp[] = [];

    const updatedSub = {
      ...activeSub,
      status: SubscriptionFSM.transition(activeSub, 'CANCEL'),
      expiresAtEpochMs: 0,
      updatedAtEpochMs: now
    };

    if (isTrial && trialId) {
      writes.push({ collectionPath: 'hardware_trials', documentId: trialId, data: updatedSub });
    } else if (activeSub.subscriptionId) {
      writes.push({ collectionPath: 'subscriptions', documentId: activeSub.subscriptionId, data: updatedSub });
    }

    return {
      writes,
      result: { hardwareIdToRevoke }
    };
  }

  /**
   * Builds the atomic mutations required to transfer ownership of a subscription.
   * Returns a DomainMutation containing the writes and the newly generated signedLeaseToken.
   */
  static async buildTransferOwnership(
    subDoc: any | null,
    isTrial: boolean,
    targetHardwareTrial: any | null,
    secretKey: string,
    subscriptionId: string, 
    customerId: string, 
    oldInstallationId: string, 
    newInstallationId: string, 
    newHardwareId: string,
    now: number
  ): Promise<DomainMutation<{ signedLeaseToken: string }>> {
    let sub = subDoc;

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
      if (targetHardwareTrial && (targetHardwareTrial.status === 'EXPIRED' || targetHardwareTrial.status === 'CANCELLED' || (targetHardwareTrial.expiresAtEpochMs && targetHardwareTrial.expiresAtEpochMs > 0 && Date.now() > targetHardwareTrial.expiresAtEpochMs))) {
        const err: any = new Error('The receiving device has an expired Free Trial. Transfer aborted.');
        err.code = 'TRIAL_ALREADY_USED';
        throw err;
      }
    }


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
          trialUsed: true,
          signedLeaseToken,
          leaseIssuedAtEpochMs: now,
          lastLeasePlanId: sub.planId || 'FREE_TRIAL_30',
          lastLeaseDeviceId: newHardwareId,
          updatedAtEpochMs: now
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
          leaseIssuedAtEpochMs: now,
          lastLeasePlanId: sub.planId,
          lastLeaseDeviceId: newInstallationId,
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
    subDoc: any | null,
    secretKey: string,
    subscriptionId: string,
    customerId: string,
    installationId: string,
    planId: string,
    planName: string,
    durationDays: number,
    now: number
  ): Promise<DomainMutation<{ signedLeaseToken: string, newExpiresAt: number }>> {

    if (subDoc && subDoc.status === 'ACTIVE' && subDoc.expiresAtEpochMs > now) {
      if (subDoc.activeInstallationId && subDoc.activeInstallationId !== installationId) {
        const err: any = new Error('Ownership conflict: Subscription belongs to another installation.');
        err.code = 'OWNERSHIP_CONFLICT';
        throw err;
      }
    }

    let baseTime = now;
    if (subDoc && subDoc.status !== 'CANCELLED' && typeof subDoc.expiresAtEpochMs === 'number' && subDoc.expiresAtEpochMs > now) {
      baseTime = subDoc.expiresAtEpochMs;
    }
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
        leaseIssuedAtEpochMs: now,
        lastLeasePlanId: planId,
        lastLeaseDeviceId: installationId,
        updatedAtEpochMs: now
      }
    }];

    return { writes, result: { signedLeaseToken, newExpiresAt } };
  }
}
