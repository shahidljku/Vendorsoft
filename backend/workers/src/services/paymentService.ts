import { RequestContext } from './logger';
import { Env, CompositeIdentity, DomainMutation } from '../types';
import { getDocument, setDocument, commitAtomicWrites, queryCollection, logAuditEvent } from './firestore';
import { PaymentFSM } from './fsm/paymentFSM';
import { LockService } from './lock';
import { findSubscription, DiscoveryStrategy } from './discovery';
import { SubscriptionService } from './subscriptionService';
import { InstallationService } from './installationService';
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
  static async initiateOrder(ctx: RequestContext, env: Env,
    identity: CompositeIdentity,
    planId: string,
    planName: string,
    durationDays: number,
    amountInr: number,
    amountPaise: number,
    now: number,
    instDoc?: any
  ): Promise<{ razorpayOrderId: string; writes: any[] }> {
    const customerId = identity.customerId;
    const installationId = identity.installationId || identity.installationUuid;

    if (!installationId || !customerId) {
      const err: any = new Error('Missing installation ID or customer ID.');
      err.code = 'MISSING_IDENTITY';
      throw err;
    }

    // 1. Check global system configurations
    const sysConfig = await getDocument(ctx, env, 'system_configs', 'global');
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

    // 2. Validate installation state (Use provided instDoc or fetch if missing)
    if (!instDoc) {
      instDoc = await getDocument(ctx, env, 'installations', installationId);
    }
    
    if (instDoc) {
      if (instDoc.isBanned === true || instDoc.status === 'BANNED') {
        const err: any = new Error('This hardware installation has been banned.');
        err.code = 'INSTALLATION_BANNED';
        throw err;
      }
      if (instDoc.customerId && instDoc.customerId !== customerId) {
        // Check if the other customer actually has an active paid subscription on THIS specific device
        const { sub: otherSub, isTrial } = await findSubscription(ctx, env, instDoc.customerId, DiscoveryStrategy.PAYMENT);
        const otherActiveId = isTrial ? otherSub?.hardwareId : otherSub?.activeInstallationId;

        if (
          otherSub &&
          otherSub.status === 'ACTIVE' &&
          otherSub.expiresAtEpochMs > now &&
          otherSub.planId !== 'FREE_TRIAL_30' &&
          (otherActiveId === installationId || otherActiveId === identity.hardwareId)
        ) {
          const err: any = new Error('This device is registered to another active subscriber.');
          err.code = 'DEVICE_CONFLICT';
          throw err;
        }
        // Device is being upgraded or used by current customer, update installation customer binding
        instDoc.customerId = customerId;
        await setDocument(ctx, env, 'installations', installationId, {
          ...instDoc,
          customerId: customerId,
          lastSeenAtEpochMs: Date.now()
        });
      }
    }

    // 3. Prevent Pay-to-Steal
    const { sub: activeSub, isTrial } = await findSubscription(ctx, env, customerId, DiscoveryStrategy.PAYMENT);
    
    if (activeSub && activeSub.status === 'ACTIVE' && activeSub.expiresAtEpochMs > now) {
      const activeId = isTrial ? activeSub.hardwareId : activeSub.activeInstallationId;
      if (activeId && activeId !== installationId && activeId !== identity.hardwareId) {
        const err: any = new Error('You must transfer the active account to this device before you can purchase a subscription.');
        err.code = 'TRANSFER_REQUIRED';
        throw err;
      }
    }

    // 4. Create Order via Gateway & Persist in Firestore within Order Lock (AUD-002)
    try {
      return await LockService.withLock(ctx, env, 'order_lock', customerId, 15000, { installationId, planId }, async () => {
        const gateway = this.getGateway();
        let razorpayOrderId: string;
        try {
          razorpayOrderId = await gateway.createOrder(ctx, env, amountPaise, {
            customerId,
            installationId,
            planId
          });
        } catch (gwErr) {
          throw gwErr;
        }

        const paymentRecord = {
          paymentId: razorpayOrderId,
          razorpayOrderId,
          installationId,
          customerId,
          planId,
          planName,
          durationDays,
          amountInr,
          idempotencyKey: identity.idempotencyKey || null,
          status: PaymentFSM.transition({}, 'INITIATE'),
          createdAtEpochMs: now,
          clientIdentity: identity
        };

        const writes = [{
          collectionPath: 'payments',
          documentId: razorpayOrderId,
          data: paymentRecord
        }];

        try {
          await commitAtomicWrites(ctx, env, writes);
        } catch (dbErr) {
          for (let attempt = 1; attempt <= 3; attempt++) {
            try {
              await commitAtomicWrites(ctx, env, [{
                collectionPath: 'payments',
                documentId: razorpayOrderId,
                data: null as any
              }]);
              break;
            } catch (compErr) {
              if (attempt === 3) {
                await logAuditEvent(ctx, env, 'CRITICAL_ORPHAN_ORDER', {
                  razorpayOrderId,
                  customerId,
                  installationId,
                  planId,
                  error: String(compErr)
                });
              } else {
                await new Promise(r => setTimeout(r, 200));
              }
            }
          }
          throw dbErr;
        }

        return { razorpayOrderId, writes };
      });
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const lockErr: any = new Error('A payment order is already in progress for this customer.');
        lockErr.code = 'CONCURRENT_ORDER_IN_PROGRESS';
        throw lockErr;
      }
      throw err;
    }
  }

  /**
   * Pure builder for creating a settlement mutation for a verified payment.
   */
  static buildSettlement(paymentDoc: any, subscriptionId: string, razorpayPaymentId: string | null, signature: string | null, now: number): DomainMutation {
    const writes = [{
      collectionPath: 'payments',
      documentId: paymentDoc.razorpayOrderId,
      data: {
        ...paymentDoc,
        status: PaymentFSM.transition(paymentDoc, 'SETTLE'),
        subscriptionId,
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
  static async verifyOrder(ctx: RequestContext, env: Env,
    orderId: string,
    paymentId?: string,
    signature?: string
  ): Promise<VerifiedPayment> {
    const gateway = this.getGateway();

    if (paymentId && signature) {
      const isValid = await gateway.verifyPaymentSignature(ctx, env, orderId, paymentId, signature);
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
    const fallbackPaymentId = await gateway.verifyPaymentFallback(ctx, env, orderId);
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
  static async verifyWebhook(ctx: RequestContext, env: Env, rawBody: string, signature: string): Promise<boolean> {
    const gateway = this.getGateway();
    return await gateway.verifyWebhookSignature(ctx, env, rawBody, signature);
  }

  /**
   * Orchestrates the settlement of a verified payment.
   * Locates the subscription, acquires a lock, builds mutations, commits atomically,
   * and triggers the refund saga if an ownership conflict is discovered.
   */
  static async settleOrder(ctx: RequestContext, env: Env,
    verifiedPayment: VerifiedPayment,
    razorpayOrderId: string
  ): Promise<{ status: 'SUCCESS' | 'REFUNDED' | 'UNKNOWN' | 'ALREADY_PROCESSED' | 'REFUND_ERROR', subscriptionId?: string, signedLeaseToken?: string, expiresAtEpochMs?: number, error?: any, statusCode?: number }> {
    return ctx.telemetry.measure('payment.saga.duration', { orderId: razorpayOrderId }, async () => {
    const now = Date.now();
    let resultPayload: any = null;
    let requireRefund = false;
    const orderLockKey = razorpayOrderId;

    try {
      await LockService.withLock(ctx, env,
        'webhook_lock',
        orderLockKey,
        30000,
        { orderLockKey },
        async () => {
          const currentPayment = await getDocument(ctx, env, 'payments', razorpayOrderId);
          if (!currentPayment) {
            resultPayload = { status: 'UNKNOWN' };
            return;
          }

          if (currentPayment.status === 'SUCCESS' || currentPayment.status === 'REFUNDED') {
            resultPayload = { status: 'ALREADY_PROCESSED' };
            return;
          }

          if (currentPayment.status === 'REFUND_PENDING') {
            try {
              const refundSuccess = await PaymentService.executeRefundSaga(ctx, env, currentPayment, verifiedPayment.paymentId);
              if (!refundSuccess) {
                resultPayload = { status: 'REFUND_ERROR', error: 'RAZORPAY_REFUND_ERROR', statusCode: 502 };
                return;
              }
              resultPayload = { status: 'REFUNDED' };
              return;
            } catch (err: any) {
              if (err.code === 'CONCURRENT_REFUND_IN_PROGRESS' || err.code === 'ALREADY_EXISTS') {
                resultPayload = { status: 'REFUND_ERROR', error: { code: 'CONCURRENT_REFUND_IN_PROGRESS', message: 'Refund is currently in progress by another process' }, statusCode: 409 };
                return;
              }
              if (err.code === 'GATEWAY_REFUND_FAILED') {
                resultPayload = { status: 'REFUND_ERROR', error: { code: 'GATEWAY_REFUND_FAILED', message: err.message }, statusCode: 502 };
                return;
              }
              throw err;
            }
          }

          if (currentPayment.status !== 'INITIATED') {
            resultPayload = { status: 'ALREADY_PROCESSED' };
            return;
          }

          const customerId = currentPayment.customerId;
          const installationId = currentPayment.installationId;
          const durationDays = typeof currentPayment.durationDays === 'number' ? currentPayment.durationDays : 395;
          const planId = currentPayment.planId || 'PRO_YEARLY';
          const planName = currentPayment.planName || 'Pro Annual License';

          // 1. Deterministic Subscription Discovery (Moved INSIDE lock to prevent TOCTOU - AUD-003)
          const { subscriptionId: foundId, sub: foundSub } = await findSubscription(ctx, env, customerId, DiscoveryStrategy.PAYMENT);
          const subscriptionId = foundId || `sub_${Date.now()}_${Math.random().toString(36).substr(2, 5)}`;

          const doSettlement = async () => {
            const ops: any[] = [];
            
            try {

              // Capture the predecessor installation BEFORE any mutation occurs
              let oldInstallationId = null;
              let targetSubDoc = foundSub;
              
              if (subscriptionId.startsWith('TRIAL_')) {
                if (foundSub) {
                  oldInstallationId = foundSub.hardwareId;
                  targetSubDoc = {
                    subscriptionId,
                    customerId: foundSub.customerId,
                    activeInstallationId: foundSub.hardwareId,
                    planId: 'FREE_TRIAL_30',
                    status: (foundSub.status === 'CANCELLED' || foundSub.expiresAtEpochMs <= now) ? 'CANCELLED' : 'ACTIVE',
                    expiresAtEpochMs: foundSub.status === 'CANCELLED' ? 0 : foundSub.expiresAtEpochMs,
                    startsAtEpochMs: foundSub.startsAtEpochMs
                  };
                }
              } else {
                if (targetSubDoc) oldInstallationId = targetSubDoc.activeInstallationId;
              }

              const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
              // Attempt to build provisioning. This will throw OWNERSHIP_CONFLICT if the sub is active on another device.
              const provOp = await SubscriptionService.buildProvisioning(
                targetSubDoc, secretKey, subscriptionId, customerId, installationId, planId, planName, durationDays, now
              );
              
              // Settlement
              const settleOp = this.buildSettlement(currentPayment, subscriptionId, verifiedPayment.paymentId, verifiedPayment.signature || null, now);
              
              ops.push(...settleOp.writes);
              ops.push(...provOp.writes);

              // Activate new installation if clientIdentity was captured during order initiation
              const identity = currentPayment.clientIdentity;
              if (identity) {
                const actOp = InstallationService.buildActivation(
                  installationId, customerId, identity.hardwareId, identity, identity.deviceModel, identity.fcmToken || null, now
                );
                ops.push(...actOp.writes);
              }

              // Conditionally revoke old installation if ownership changed and it isn't identical (renewal)
              if (oldInstallationId && oldInstallationId !== installationId) {
                const oldInst = await getDocument(ctx, env, 'installations', oldInstallationId);
                if (oldInst && oldInst.status === 'ACTIVE') {
                  const revOp = InstallationService.buildRevocation(oldInst, oldInstallationId, 'Superseded by new payment', now);
                  ops.push(...revOp.writes);
                }
              }

              await commitAtomicWrites(ctx, env, ops);

              resultPayload = {
                status: 'SUCCESS',
                subscriptionId,
                signedLeaseToken: provOp.result.signedLeaseToken,
                expiresAtEpochMs: provOp.result.newExpiresAt
              };
              
              await logAuditEvent(ctx, env, 'PAYMENT_SETTLED', { 
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
                const refundOp = this.buildRefundRequest(currentPayment, now);
                ops.push(...refundOp.writes);
                await commitAtomicWrites(ctx, env, ops);
              } else {
                throw domainErr;
              }
            }
          };

          if (foundId) {
            const nestedLockType = foundId.startsWith('TRIAL_') ? 'transfer_lock' : 'sub_lock';
            await LockService.withLock(ctx, env, nestedLockType, foundId, 30000, { customerId, subscriptionId: foundId }, doSettlement);
          } else {
            await doSettlement();
          }
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const lockErr: any = new Error('Order or subscription is locked by another process.');
        lockErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw lockErr;
      }
      throw err;
    }

    if (requireRefund) {
      const currentPaymentDoc = await getDocument(ctx, env, 'payments', verifiedPayment.orderId);
      if (currentPaymentDoc) {
        await this.executeRefundSaga(ctx, env, currentPaymentDoc, verifiedPayment.paymentId);
      }
      const refundErr: any = new Error('Subscription ownership changed. Your payment has been automatically refunded.');
      refundErr.code = 'ORDER_INVALIDATED';
      throw refundErr;
    }

    return resultPayload;
    }); // End of payment.saga.duration telemetry wrapper
  }

  /**
   * Executes the external refund network call (the Saga), completely outside any locks or transactions.
   */
  static async executeRefundSaga(ctx: RequestContext, env: Env, paymentDoc: any, razorpayPaymentId: string): Promise<boolean> {
    return ctx.telemetry.measure('payment.refund.duration', { razorpayPaymentId }, async () => {
    try {
      return await LockService.withLock(ctx, env, 'refund_lock', paymentDoc.razorpayOrderId, 15000, { razorpayPaymentId }, async () => {
        const latestPayDoc = await getDocument(ctx, env, 'payments', paymentDoc.razorpayOrderId) || paymentDoc;
        if (latestPayDoc.status === 'REFUNDED') {
          return true;
        }
        const gateway = this.getGateway();
        const success = await gateway.refundPayment(ctx, env, razorpayPaymentId);
        
        if (success) {
          await setDocument(ctx, env, 'payments', paymentDoc.razorpayOrderId, { 
            ...latestPayDoc, 
            status: PaymentFSM.transition(latestPayDoc, 'COMPLETE_REFUND'), 
            refundedAtEpochMs: Date.now() 
          });
          return true;
        } else {
          const err: any = new Error('Gateway refund failed.');
          err.code = 'GATEWAY_REFUND_FAILED';
          throw err;
        }
      });
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const lockErr: any = new Error('A refund is already in progress for this payment.');
        lockErr.code = 'CONCURRENT_REFUND_IN_PROGRESS';
        throw lockErr;
      }
      throw err;
    }
    }); // End of payment.refund.duration telemetry wrapper
  }

  /**
   * Helper to cancel an initiated order directly (e.g. user closed modal).
   */
  static async cancelOrder(ctx: RequestContext, env: Env, paymentDoc: any): Promise<void> {
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
      await commitAtomicWrites(ctx, env, writes);
    }
  }
}
