import { RequestContext } from './services/logger';
import { Env } from './types';
import { getDocument, setDocument, logAuditEvent } from './services/firestore';
import { PaymentService } from './services/paymentService';

/**
 * Handles POST /api/v1/webhooks/razorpay
 * Verifies Razorpay webhook signature and delegates settlement to PaymentService.
 */
export async function handleRazorpayWebhook(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
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

  // 1. Cryptographic Signature Verification (`HMAC SHA-256`) via PaymentService
  const isValid = await PaymentService.verifyWebhook(ctx, env, rawBodyText, signatureHeader);
  if (!isValid) {
    // Log unauthorized security event
    await logAuditEvent(ctx, env, 'WEBHOOK_SIGNATURE_INVALID', { header: signatureHeader });
    return new Response(JSON.stringify({ success: false, error: { code: 'INVALID_SIGNATURE', message: 'Webhook signature verification failed.' } }), {
      status: 401,
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

  // 2. Persist a minimal durable receipt before queuing (Principal Engineer Refinement)
  const receiptId = `wh_rcpt_${crypto.randomUUID()}`;
  const eventId = payload.id || crypto.randomUUID();
  
  try {
    await setDocument(ctx, env, 'webhook_receipts', receiptId, {
      receiptId,
      eventId,
      type: eventType,
      orderId: razorpayOrderId,
      payload,
      receivedAt: new Date().toISOString()
    });

    // 3. Queue lightweight settlement work (Payload is stored in the receipt)
    await env.WEBHOOK_QUEUE.send({
      receiptId,
      eventId,
      type: eventType,
      orderId: razorpayOrderId,
      signature: signatureHeader
    });

    // 4. Return 200 OK immediately. Settlement happens asynchronously in the queue consumer.
    return new Response(JSON.stringify({ success: true, processed: false, note: 'QUEUED' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  } catch (err: any) {
    ctx.logger.error('Failed to enqueue webhook or write receipt:', err);
    // If the queue or firestore is down, return 500 so Razorpay knows to retry later.
    return new Response(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    });
  }
}
