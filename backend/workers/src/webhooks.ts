import { Env, ApiResponse } from './types';
import { getDocument, setDocument, commitAtomicWrites, queryCollection, logAuditEvent } from './services/firestore';
import { generateShortId, generateSignedLeaseToken } from './cryptoEngine';

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

  // 3. Check transaction idempotency (`If already SUCCESS, abort write operations cleanly without double-granting`)
  if (paymentDoc.status === 'SUCCESS') {
    return new Response(JSON.stringify({ success: true, processed: true, note: 'ALREADY_PROCESSED' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  // 4. Atomic settlement
  const now = Date.now();
  const customerId = paymentDoc.customerId;
  const installationId = paymentDoc.installationId;
  const durationDays = typeof paymentDoc.durationDays === 'number' ? paymentDoc.durationDays : 365;
  const planId = paymentDoc.planId || 'PRO_YEARLY';
  const planName = paymentDoc.planName || 'Pro Annual License';

  const subs = await queryCollection(env, 'subscriptions', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
  let subDoc = subs.length > 0 ? subs[0] : null;
  const subscriptionId = subDoc ? subDoc.subscriptionId : `sub_${generateShortId()}`;

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

  const secretKey = env.LEASE_SIGNING_SECRET || env.RAZORPAY_WEBHOOK_SECRET || 'vendsoft_authoritative_worker_secret_v1';
  const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

  const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any> }> = [
    {
      collectionPath: 'payments',
      documentId: razorpayOrderId,
      data: {
        ...paymentDoc,
        status: 'SUCCESS',
        razorpayPaymentId: razorpayPaymentId || null,
        razorpaySignature: signatureHeader || null,
        updatedAtEpochMs: now
      }
    },
    {
      collectionPath: 'subscriptions',
      documentId: subscriptionId,
      data: {
        subscriptionId,
        customerId,
        activeInstallationId: installationId,
        planId,
        planName,
        status: 'ACTIVE',
        startsAtEpochMs: leasePayload.startsAtEpochMs,
        expiresAtEpochMs: newExpiresAt,
        signedLeaseToken,
        updatedAtEpochMs: now
      }
    }
  ];

  await commitAtomicWrites(env, batchWrites);
  await logAuditEvent(env, 'PAYMENT_SETTLED_WEBHOOK', { razorpayOrderId, razorpayPaymentId, customerId, installationId, planId, newExpiresAt });

  return new Response(JSON.stringify({ success: true, processed: true, subscriptionId }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' }
  });
}
