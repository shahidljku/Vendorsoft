import { Env, CompositeIdentity, DomainMutation } from '../types';
import { getDocument, setDocument, commitAtomicWrites, queryCollection, logAuditEvent } from './firestore';
import { PaymentFSM } from './fsm/paymentFSM';
import { LockService } from './lock';
import { findSubscription, DiscoveryStrategy } from './discovery';
import { SubscriptionService } from './subscriptionService';
import { PaymentGateway, RazorpayProvider, VerifiedPayment } from './paymentGateway';

export class PaymentService {
  private static getGateway(): PaymentGateway {
    // In the future, this could return different providers based on env or config
    return new RazorpayProvider();
  }

  /**
   * Validates business rules and initiates a payment order using the configured gateway.
   * Returns a DomainMutation containing the write for the new payment record.
   */
  static async initiateOrder(
    env: Env,
    identity: CompositeIdentity,
    planId: string,
    planName: string,
    durationDays: number,
    amountInr: number,
    amountPaise: number,
    now: number
  ): Promise<{ razorpayOrderId: string; writes: any[] }> {
    const customerId = identity.customerId;
    const installationId = identity.installationId || identity.installationUuid;

    if (!installationId || !customerId) {
      const err: any = new Error('Missing installation ID or customer ID.');
      err.code = 'MISSING_IDENTITY';
      throw err;
    }

    // 1. Check global system configurations
    const sysConfig = await getDocument(env, 'system_configs', 'global');
    if (sysConfig) {
      if (sysConfig.maintenanceMode === true) {
        const err: any = new Error(sysConfig.maintenanceMessage || 'System maintenance in progress.');
        err.code = 'MAINTENANCE_MODE';
        throw err;
      }
      if (sysConfig.allowPayments === false) {
        const err: any = new Error('Online payments are currently disabled by system administrators.');
        err.code = 'PAYMENTS_DISABLED';
        throw err;
      }
    }

    // 2. Verify installation is not banned or revoked
    const instDoc = await getDocument(env, 'installations', installationId);
    if (instDoc) {
      if (instDoc.isBanned === true) {
        const err: any = new Error('This hardware installation has been banned.');
        err.code = 'INSTALLATION_BANNED';
        throw err;
      }
      if (instDoc.status === 'REVOKED') {
        const err: any = new Error('This installation has been revoked. Please request a device transfer.');
        err.code = 'INSTALLATION_REVOKED';
        throw err;
      }
    }

    // 3. Prevent Pay-to-Steal
    const subs = await queryCollection(env, 'subscriptions', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
    const activeSub = subs.find((s: any) => s.status === 'ACTIVE' && s.expiresAtEpochMs > now);
    if (activeSub && activeSub.activeInstallationId && activeSub.activeInstallationId !== installationId) {
      const err: any = new Error('You must transfer the active account to this device before you can purchase a subscription.');
      err.code = 'TRANSFER_REQUIRED';
      throw err;
    }

    const trials = await queryCollection(env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
    const activeTrial = trials.find((t: any) => t.status !== 'CANCELLED' && t.expiresAtEpochMs > now);
    if (activeTrial && activeTrial.hardwareId !== installationId && activeTrial.hardwareId !== identity.hardwareId) {
      const err: any = new Error('You must transfer your active trial to this device before you can purchase a subscription.');
      err.code = 'TRANSFER_REQUIRED';
      throw err;
    }

    // 4. Create Order via Gateway
    const gateway = this.getGateway();
    const razorpayOrderId = await gateway.createOrder(env, amountPaise, {
      customerId,
      installationId,
      planId
    });

    // 5. Build payment record mutation
    const paymentRecord = {
      paymentId: razorpayOrderId,
      razorpayOrderId,
      installationId,
      customerId,
      planId,
      planName,
      durationDays,
      amountInr,
      status: PaymentFSM.transition({}, 'INITIATE'),
      createdAtEpochMs: now
    };

    const writes = [{
      collectionPath: 'payments',
      documentId: razorpayOrderId,
      data: paymentRecord
    }];

    return { razorpayOrderId, writes };
  }

  /**
   * Pure builder for creating a settlement mutation for a verified payment.
   */
  static buildSettlement(paymentDoc: any, razorpayPaymentId: string | null, signature: string | null, now: number): DomainMutation {
    const writes = [{
      collectionPath: 'payments',
      documentId: paymentDoc.razorpayOrderId,
      data: {
        ...paymentDoc,
        status: PaymentFSM.transition(paymentDoc, 'SETTLE'),
        razorpayPaymentId: razorpayPaymentId || null,
        razorpaySignature: signature || null,
        updatedAtEpochMs: now
      }
    }];
    return { writes, result: undefined };
  }

  /**
   * Pure builder for marking a payment as requiring a refund (usually due to a conflict).
   */
  static buildRefundRequest(paymentDoc: any, now: number): DomainMutation {
    const writes = [{
      collectionPath: 'payments',
      documentId: paymentDoc.razorpayOrderId,
      data: {
        ...paymentDoc,
        status: PaymentFSM.transition(paymentDoc, 'REQUEST_REFUND'),
        updatedAtEpochMs: now
      }
    }];
    return { writes, result: undefined };
  }

  /**
   * Separated Verification Step. Verifies the authenticity of a payment via Gateway.
   * Returns a VerifiedPayment object, or throws if invalid.
   */
  static async verifyOrder(
    env: Env,
    orderId: string,
    paymentId?: string,
    signature?: string
  ): Promise<VerifiedPayment> {
    const gateway = this.getGateway();

    if (paymentId && signature) {
      const isValid = await gateway.verifyPaymentSignature(env, orderId, paymentId, signature);
      if (isValid) {
        return { orderId, paymentId, signature };
      }
    } else if (paymentId) {
      // Local dev simulation might pass paymentId without signature
      if (!env.RAZORPAY_WEBHOOK_SECRET) {
        return { orderId, paymentId };
      }
    }

    // Fallback Verification
    const fallbackPaymentId = await gateway.verifyPaymentFallback(env, orderId);
    if (fallbackPaymentId) {
      return { orderId, paymentId: fallbackPaymentId };
    }

    const err: any = new Error('Payment verification failed or payment not captured yet.');
    err.code = 'PAYMENT_NOT_CAPTURED';
    throw err;
  }

  /**
   * Verifies the authenticity of a webhook payload via Gateway.
   * Returns a boolean indicating validity.
   */
  static async verifyWebhook(env: Env, rawBody: string, signature: string): Promise<boolean> {
    const gateway = this.getGateway();
    return await gateway.verifyWebhookSignature(env, rawBody, signature);
  }

  /**
   * Orchestrates the settlement of a verified payment.
   * Locates the subscription, acquires a lock, builds mutations, commits atomically,
   * and triggers the refund saga if an ownership conflict is discovered.
   */
  static async settleOrder(
    env: Env,
    verifiedPayment: VerifiedPayment,
    paymentDoc: any
  ): Promise<{ status: 'SUCCESS' | 'REFUNDED', subscriptionId?: string, signedLeaseToken?: string, expiresAtEpochMs?: number }> {
    const now = Date.now();
    const customerId = paymentDoc.customerId;
    const installationId = paymentDoc.installationId;
    const durationDays = typeof paymentDoc.durationDays === 'number' ? paymentDoc.durationDays : 365;
    const planId = paymentDoc.planId || 'PRO_YEARLY';
    const planName = paymentDoc.planName || 'Pro Annual License';

    // 1. Deterministic Subscription Discovery
    const { subscriptionId: foundId } = await findSubscription(env, customerId, DiscoveryStrategy.PAYMENT);
    const subscriptionId = foundId || `sub_${Date.now()}_${Math.random().toString(36).substr(2, 5)}`; // Or generateShortId

    let requireRefund = false;
    let resultPayload: any = null;

    try {
      await LockService.withLock(
        env,
        'sub_lock',
        subscriptionId,
        30000,
        { customerId, subscriptionId },
        async () => {
          const ops: any[] = [];
          
          try {
            // Attempt to build provisioning. This will throw OWNERSHIP_CONFLICT if the sub is active on another device.
            const provOp = await SubscriptionService.buildProvisioning(
              env, subscriptionId, customerId, installationId, planId, planName, durationDays, now
            );
            
            // Settlement
            const settleOp = this.buildSettlement(paymentDoc, verifiedPayment.paymentId, verifiedPayment.signature || null, now);
            
            ops.push(...settleOp.writes);
            ops.push(...provOp.writes);

            await commitAtomicWrites(env, ops);

            resultPayload = {
              status: 'SUCCESS',
              subscriptionId,
              signedLeaseToken: provOp.result.signedLeaseToken,
              expiresAtEpochMs: provOp.result.newExpiresAt
            };
            
            await logAuditEvent(env, 'PAYMENT_SETTLED', { 
              razorpayOrderId: verifiedPayment.orderId, 
              razorpayPaymentId: verifiedPayment.paymentId, 
              customerId, 
              installationId, 
              planId 
            });

          } catch (domainErr: any) {
            if (domainErr.code === 'OWNERSHIP_CONFLICT') {
              requireRefund = true;
              
              // Request Refund
              const refundOp = this.buildRefundRequest(paymentDoc, now);
              ops.push(...refundOp.writes);
              await commitAtomicWrites(env, ops);
            } else {
              throw domainErr;
            }
          }
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const lockErr: any = new Error('Subscription is locked by another process.');
        lockErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw lockErr;
      }
      throw err;
    }

    if (requireRefund) {
      const currentPaymentDoc = await getDocument(env, 'payments', verifiedPayment.orderId);
      if (currentPaymentDoc) {
        await this.executeRefundSaga(env, currentPaymentDoc, verifiedPayment.paymentId);
      }
      const refundErr: any = new Error('Subscription ownership changed. Your payment has been automatically refunded.');
      refundErr.code = 'ORDER_INVALIDATED';
      throw refundErr;
    }

    return resultPayload;
  }

  /**
   * Executes the external refund network call (the Saga), completely outside any locks or transactions.
   */
  static async executeRefundSaga(env: Env, paymentDoc: any, razorpayPaymentId: string): Promise<boolean> {
    const gateway = this.getGateway();
    const success = await gateway.refundPayment(env, razorpayPaymentId);
    
    if (success) {
      // FSM: REFUND_PENDING -> REFUNDED
      await setDocument(env, 'payments', paymentDoc.razorpayOrderId, { 
        ...paymentDoc, 
        status: PaymentFSM.transition(paymentDoc, 'COMPLETE_REFUND'), 
        refundedAtEpochMs: Date.now() 
      });
      return true;
    } else {
      // Saga failed, requires retry or manual intervention. We do NOT revert FSM.
      return false;
    }
  }

  /**
   * Helper to cancel an initiated order directly (e.g. user closed modal).
   */
  static async cancelOrder(env: Env, paymentDoc: any): Promise<void> {
    if (paymentDoc.status === 'INITIATED') {
      const writes = [{
        collectionPath: 'payments',
        documentId: paymentDoc.razorpayOrderId,
        data: {
          ...paymentDoc,
          status: PaymentFSM.transition(paymentDoc, 'FAIL'),
          updatedAtEpochMs: Date.now()
        }
      }];
      await commitAtomicWrites(env, writes);
    }
  }
}
