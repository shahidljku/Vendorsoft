import { Env } from './types';
import { getDocument, logAuditEvent } from './services/firestore';
import { PaymentService } from './services/paymentService';

/**
 * Handles POST /api/v1/webhooks/razorpay
 * Verifies Razorpay webhook signature and delegates settlement to PaymentService.
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

  // 1. Cryptographic Signature Verification (`HMAC SHA-256`) via PaymentService
  const isValid = await PaymentService.verifyWebhook(env, rawBodyText, signatureHeader);
  if (!isValid) {
    // Log unauthorized security event
    await logAuditEvent(env, 'WEBHOOK_SIGNATURE_INVALID', { header: signatureHeader });
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
    const refundSuccess = await PaymentService.executeRefundSaga(env, paymentDoc, razorpayPaymentId);
    if (!refundSuccess) {
      return new Response(JSON.stringify({ success: false, error: 'RAZORPAY_REFUND_ERROR' }), {
        status: 500, // Forces webhook retry
        headers: { 'Content-Type': 'application/json' }
      });
    }
    return new Response(JSON.stringify({ success: true, processed: true, note: 'ORDER_INVALIDATED_REFUNDED' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  }

  // 4. Delegate to PaymentService to Settle
  try {
    const settlementResult = await PaymentService.settleOrder(
      env,
      { orderId: razorpayOrderId, paymentId: razorpayPaymentId, signature: signatureHeader },
      paymentDoc
    );

    return new Response(JSON.stringify({ success: true, processed: true, subscriptionId: settlementResult.subscriptionId }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' }
    });
  } catch (err: any) {
    if (err.code === 'ORDER_INVALIDATED') {
      return new Response(JSON.stringify({ success: true, processed: true, note: 'ORDER_INVALIDATED_AND_REFUNDED' }), {
        status: 200, // Processed and correctly resolved via refund
        headers: { 'Content-Type': 'application/json' }
      });
    }
    if (err.code === 'CONCURRENT_MUTATION_LOCKED') {
      return new Response(JSON.stringify({ success: false, error: { code: 'CONCURRENT_MUTATION_LOCKED', message: 'Subscription is locked by another process' } }), {
        status: 409,
        headers: { 'Content-Type': 'application/json' }
      });
    }
    console.error('Webhook settlement error:', err);
    return new Response(JSON.stringify({ success: false, error: 'INTERNAL_ERROR' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    });
  }
}
