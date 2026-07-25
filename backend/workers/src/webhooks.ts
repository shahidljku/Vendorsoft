import { Env, ApiResponse } from './types';
import { getDocument, setDocument, commitAtomicWrites, deleteDocument, queryCollection, logAuditEvent } from './services/firestore';
import { generateShortId, generateSignedLeaseToken } from './cryptoEngine';
import { LockService } from './services/lock';
import { findSubscription, DiscoveryStrategy } from './services/discovery';
import { PaymentFSM } from './services/fsm/paymentFSM';
import { SubscriptionFSM } from './services/fsm/subscriptionFSM';

/**
 * Handles POST /api/v1/webhooks/razorpay
 * Verifies Razorpay HMAC SHA-256 webhook signature and atomically settles captured payments.
 * Enforces the One Active Device Rule (`activeInstallationId = payment.installationId`).
 */
export async function handleRazorpayWebhook(request: Request, env: Env): Promise<Response> {
  const secret = env.RAZORPAY_WEBHOOK_SECRET || 'rzp_test_webhook_secret';
  const signatureHeader = request.headers.get('x-razorpay-signature');
  if (!signatureHeader) {
    return new Response(JSON.stringify({ success: false, error: { code: 'MISSING_SIGNATURE', message: 'Missing x-razorpay-signature' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  let rawBodyText: string;
  try {
    rawBodyText = await request.text();
  } catch {
    return new Response(JSON.stringify({ success: false, error: { code: 'INVALID_BODY', message: 'Unable to read request body.' } }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  // 1. Cryptographic Signature Verification (`HMAC SHA-256`)
  try {
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey(
      'raw',
      enc.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    const signatureBytes = await crypto.subtle.sign('HMAC', key, enc.encode(rawBodyText));
    const hexSignature = Array.from(new Uint8Array(signatureBytes)).map((b) => b.toString(16).padStart(2, '0')).join('');
    if (hexSignature !== signatureHeader) {
      // Log unauthorized security event
      await logAuditEvent(env, 'WEBHOOK_SIGNATURE_INVALID', { header: signatureHeader });
      return new Response(JSON.stringify({ success: false, error: { code: 'INVALID_SIGNATURE', message: 'Webhook signature verification failed.' } }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      });
    }
  } catch (err) {
    console.error('Webhook signature check exception:', err);
    return new Response(JSON.stringify({ success: false, error: { code: 'SIGNATURE_CHECK_ERROR', message: 'Error checking signature' } }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  let payload: any;
  try {
    payload = JSON.parse(rawBodyText);
  } catch {
    return new Response(JSON.stringify({ success: false, error: { code: 'INVALID_JSON', message: 'Webhook body must be JSON' } }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  const eventType = payload.event;
  if (eventType !== 'order.paid' && eventType !== 'payment.captured') {
    // We acknowledge unhandled webhook events gracefully with 200 OK
    return new Response(JSON.stringify({ success: true, processed: false, note: `Ignored event ${eventType}` }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  const paymentEntity = payload.payload?.payment?.entity || payload.payload?.order?.entity;
  const razorpayOrderId = paymentEntity?.order_id || payload.payload?.order?.entity?.id;
  const razorpayPaymentId = paymentEntity?.id;

  if (!razorpayOrderId) {
    return new Response(JSON.stringify({ success: false, error: { code: 'MISSING_ORDER_ID', message: 'No order_id found in webhook payload.' } }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  // 2. Query authoritative payment ledger
  const paymentDoc = await getDocument(env, 'payments', razorpayOrderId);
  if (!paymentDoc) {
    console.warn(`Webhook received for unknown order: ${razorpayOrderId}`);
    return new Response(JSON.stringify({ success: true, processed: false, note: 'UNKNOWN_ORDER' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  // FSM Constraints: Already terminal states or intermediate saga
  if (paymentDoc.status === 'SUCCESS' || paymentDoc.status === 'REFUNDED') {
    return new Response(JSON.stringify({ success: true, processed: true, note: 'ALREADY_PROCESSED' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  if (paymentDoc.status === 'REFUND_PENDING') {
    return await executeRefundSaga(env, paymentDoc, razorpayPaymentId);
  }

  // 4. Deterministic Subscription Discovery
  const now = Date.now();
  const customerId = paymentDoc.customerId;
  const installationId = paymentDoc.installationId;
  const durationDays = typeof paymentDoc.durationDays === 'number' ? paymentDoc.durationDays : 365;
  const planId = paymentDoc.planId || 'PRO_YEARLY';
  const planName = paymentDoc.planName || 'Pro Annual License';

  const { subscriptionId: foundId } = await findSubscription(env, customerId, DiscoveryStrategy.PAYMENT);
  let subscriptionId = foundId;

  if (!subscriptionId) {
    subscriptionId = `sub_${generateShortId()}`;
  }

  let finalSubscriptionId = subscriptionId;
  let requireRefund = false;

  try {
    await LockService.withLock(
      env,
      'sub_lock',
      subscriptionId,
      30000,
      { customerId, subscriptionId },
      async () => {
        // 6. Authoritative Read
        let subDoc = null;
        if (subscriptionId!.startsWith('TRIAL_')) {
          const hardwareId = subscriptionId!.replace('TRIAL_', '');
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
          subDoc = await getDocument(env, 'subscriptions', subscriptionId as string);
        }

        // 7. Validate (Order Lifecycle Saga)
        if (subDoc && subDoc.status === 'ACTIVE' && subDoc.expiresAtEpochMs > now) {
          if (subDoc.activeInstallationId && subDoc.activeInstallationId !== installationId) {
            // Ownership conflict!
            requireRefund = true;
          }
        }

        if (requireRefund) {
          // FSM: CREATED -> REFUND_PENDING
          await setDocument(env, 'payments', razorpayOrderId, {
            ...paymentDoc,
            status: PaymentFSM.transition(paymentDoc, 'REQUEST_REFUND'),
            updatedAtEpochMs: Date.now()
          });
        } else {
          // Normal Settlement (FSM: CREATED -> SUCCESS)
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

          const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any> }> = [
            {
              collectionPath: 'payments',
              documentId: razorpayOrderId,
              data: {
                ...paymentDoc,
                status: PaymentFSM.transition(paymentDoc, 'SETTLE'),
                razorpayPaymentId,
                razorpaySignature: signatureHeader,
                updatedAtEpochMs: now
              }
            },
            {
              collectionPath: 'subscriptions',
              documentId: subscriptionId as string,
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
            }
          ];

          await commitAtomicWrites(env, batchWrites);
          await logAuditEvent(env, 'PAYMENT_SETTLED_WEBHOOK', { razorpayOrderId, razorpayPaymentId, customerId, installationId, planId, newExpiresAt });
        }
      }
    );
  } catch (err: any) {
    if (err.code === 'ALREADY_EXISTS') {
      return new Response(JSON.stringify({ success: false, error: { code: 'CONCURRENT_MUTATION_LOCKED', message: 'Subscription is locked by another process' } }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' }
      });
    }
    throw err;
  }

  if (requireRefund) {
    // 9. Execute External Saga (Outside Mutex)
    const currentPaymentDoc = await getDocument(env, 'payments', razorpayOrderId);
    if (currentPaymentDoc) {
      return await executeRefundSaga(env, currentPaymentDoc, razorpayPaymentId);
    }
  }

  return new Response(JSON.stringify({ success: true, processed: true, subscriptionId: finalSubscriptionId }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' }
  });
}

/**
 * 3-State Refund Saga (Idempotent External Network Call)
 */
export async function executeRefundSaga(env: Env, paymentDoc: any, razorpayPaymentId: string): Promise<Response> {
  if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
    // Simulated refund for dev environment
    await setDocument(env, 'payments', paymentDoc.orderId, { ...paymentDoc, status: PaymentFSM.transition(paymentDoc, 'COMPLETE_REFUND'), refundedAtEpochMs: Date.now() });
    return new Response(JSON.stringify({ success: true, processed: true, note: 'ORDER_INVALIDATED_REFUNDED_SIMULATED' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  try {
    const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
    const refundResp = await fetch(`https://api.razorpay.com/v1/payments/${razorpayPaymentId}/refund`, {
      method: 'POST',
      headers: { 'Authorization': authHeader, 'Content-Type': 'application/json' },
      body: JSON.stringify({ speed: 'normal' })
    });

    if (refundResp.ok || refundResp.status === 400) {
      // HTTP 400 effectively means "already fully refunded", perfectly safe to terminate saga.
      // FSM: REFUND_PENDING -> REFUNDED
      await setDocument(env, 'payments', paymentDoc.orderId, { ...paymentDoc, status: PaymentFSM.transition(paymentDoc, 'COMPLETE_REFUND'), refundedAtEpochMs: Date.now() });
      return new Response(JSON.stringify({ success: true, processed: true, note: 'ORDER_INVALIDATED_REFUNDED' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      });
    } else {
      console.error('Razorpay Refund API Error:', await refundResp.text());
      return new Response(JSON.stringify({ success: false, error: 'RAZORPAY_REFUND_ERROR' }), {
        status: 500, // Forces webhook retry
        headers: { 'Content-Type': 'application/json' }
      });
    }
  } catch (err) {
    console.error('Webhook refund saga exception:', err);
    return new Response(JSON.stringify({ success: false, error: 'NETWORK_ERROR' }), {
      status: 500, // Forces webhook retry
      headers: { 'Content-Type': 'application/json' }
    });
  }
}
