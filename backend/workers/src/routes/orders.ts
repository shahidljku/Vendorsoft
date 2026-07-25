import { Env, ApiResponse } from '../types';
import { authenticateRequest, createErrorResponse } from '../authGuard';
import { getDocument } from '../services/firestore';
import { PaymentService } from '../services/paymentService';

/**
 * Handles POST /api/v1/orders/create
 * Initiates a new Razorpay payment order for subscription upgrade/renewal.
 */
export async function handleCreateOrder(request: Request, env: Env): Promise<Response> {
  // 1. Authenticate request and verify zero-trust identity headers
  const authResult = await authenticateRequest(request, env);
  if (authResult.errorResponse) return authResult.errorResponse;
  const identity = authResult.identity!;

  let customerId = identity.customerId;
  const installationId = identity.installationId || identity.installationUuid;

  if (!installationId) {
    return createErrorResponse(400, 'MISSING_INSTALLATION_ID', 'Missing installation UUID.');
  }

  // Look up customerId from installation if not passed in header
  if (!customerId) {
    const instDoc = await getDocument(env, 'installations', installationId);
    if (instDoc && instDoc.customerId) {
      customerId = instDoc.customerId;
    }
  }

  if (!customerId) {
    return createErrorResponse(400, 'MISSING_CUSTOMER_ID', 'Unable to determine customer ID. Please register first.');
  }

  // 2. Parse payload
  let body: { planId?: string };
  try {
    body = await request.json();
  } catch {
    return createErrorResponse(400, 'INVALID_JSON', 'Request body must be valid JSON.');
  }

  const rawPlanId = typeof body.planId === 'string' ? body.planId : '';
  if (rawPlanId.length > 50) {
    return createErrorResponse(400, 'INVALID_PLAN_ID', 'planId exceeds maximum allowed length.');
  }
  const planId = rawPlanId.trim().toUpperCase();
  if (!planId) {
    return createErrorResponse(400, 'MISSING_PLAN_ID', 'planId is required (e.g. PRO_MONTHLY or PRO_YEARLY).');
  }

  // 5. Look up plan pricing (`plans/{planId}`) or fall back to standard defaults if not in Firestore yet
  let priceInr = 1499; // Default yearly
  let durationDays = 365;
  let planName = 'Pro Annual License';

  const planDoc = await getDocument(env, 'plans', planId);
  if (planDoc) {
    if (planDoc.isActive === false) {
      return createErrorResponse(400, 'PLAN_INACTIVE', `Plan '${planId}' is no longer available for purchase.`);
    }
    priceInr = typeof planDoc.priceInr === 'number' ? planDoc.priceInr : priceInr;
    durationDays = typeof planDoc.durationDays === 'number' ? planDoc.durationDays : durationDays;
    planName = typeof planDoc.name === 'string' ? planDoc.name : planName;
  } else {
    if (planId === 'PRO_MONTHLY') {
      priceInr = 149;
      durationDays = 30;
      planName = 'Pro Monthly License';
    } else if (planId === 'PRO_YEARLY') {
      priceInr = 1499;
      durationDays = 365;
      planName = 'Pro Annual License';
    } else if (planId !== 'DEMO_FREE') {
      return createErrorResponse(400, 'INVALID_PLAN_ID', `Unsupported planId: ${planId}`);
    }
  }

  const amountInr = priceInr;
  const amountPaise = priceInr * 100;
  const now = Date.now();
  // 4. Delegate to PaymentService to perform validations and order creation
  try {
    const { razorpayOrderId } = await PaymentService.initiateOrder(
      env,
      { ...identity, customerId, installationUuid: installationId } as any,
      planId,
      planName,
      durationDays,
      amountInr,
      amountPaise,
      now
    );

    const responseBody: ApiResponse = {
      success: true,
      data: {
        razorpayOrderId,
        amountPaise,
        keyId: env.RAZORPAY_KEY_ID || '',
        planId,
        amountInr
      }
    };

    return new Response(JSON.stringify(responseBody), {
      status: 201,
      headers: { 'Content-Type': 'application/json' }
    });
  } catch (err: any) {
    // Map domain errors to HTTP responses
    const status = err.code === 'MAINTENANCE_MODE' ? 503 :
                   (err.code === 'PAYMENTS_DISABLED' || err.code === 'INSTALLATION_BANNED' || err.code === 'INSTALLATION_REVOKED' || err.code === 'TRANSFER_REQUIRED') ? 403 :
                   err.code === 'RAZORPAY_GATEWAY_ERROR' ? 502 : 400;
    return createErrorResponse(status, err.code || 'UNKNOWN_ERROR', err.message);
  }
}

/**
 * Handles POST /api/v1/orders/verify
 * Client fallback verification when Razorpay webhook delivery is delayed or when checkout modal closes.
 */
export async function handleVerifyOrder(request: Request, env: Env): Promise<Response> {
  const authResult = await authenticateRequest(request, env);
  if (authResult.errorResponse) return authResult.errorResponse;
  const identity = authResult.identity!;

  let body: {
    razorpayOrderId?: string;
    razorpayPaymentId?: string;
    razorpaySignature?: string;
    errorCode?: string;
  };
  try {
    body = await request.json();
  } catch {
    return createErrorResponse(400, 'INVALID_JSON', 'Request body must be valid JSON.');
  }

  const rawOrderId = typeof body.razorpayOrderId === 'string' ? body.razorpayOrderId : '';
  if (rawOrderId.length > 100) {
    return createErrorResponse(400, 'INVALID_ORDER_ID', 'razorpayOrderId exceeds maximum allowed length.');
  }
  const orderId = rawOrderId.trim();
  if (!orderId) {
    return createErrorResponse(400, 'MISSING_ORDER_ID', 'razorpayOrderId is required.');
  }

  const paymentDoc = await getDocument(env, 'payments', orderId);
  if (!paymentDoc) {
    return createErrorResponse(404, 'ORDER_NOT_FOUND', `Order '${orderId}' was not found.`);
  }

  // 1. Handle explicit payment cancellation / error dismissal by user
  if (body.errorCode && body.errorCode === 'PAYMENT_CANCELLED') {
    await PaymentService.cancelOrder(env, paymentDoc);
    const resp: ApiResponse = { success: true, data: { status: 'FAILED', message: 'Payment marked as failed/cancelled.' } };
    return new Response(JSON.stringify(resp), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }

  // 2. If already settled by webhook, return success instantly
  if (paymentDoc.status === 'SUCCESS') {
    const resp: ApiResponse = { success: true, data: { status: 'SUCCESS', message: 'Order already settled.' } };
    return new Response(JSON.stringify(resp), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }

  // 3. Delegate to PaymentService to Verify
  try {
    const verifiedPayment = await PaymentService.verifyOrder(env, orderId, body.razorpayPaymentId, body.razorpaySignature);

    // 4. Delegate to PaymentService to Settle
    const settlementResult = await PaymentService.settleOrder(env, verifiedPayment, paymentDoc);

    const successResp: ApiResponse = {
      success: true,
      data: settlementResult
    };

    return new Response(JSON.stringify(successResp), { status: 200, headers: { 'Content-Type': 'application/json' } });
  } catch (err: any) {
    if (err.code === 'ORDER_INVALIDATED') {
      return createErrorResponse(400, 'ORDER_INVALIDATED', err.message);
    }
    if (err.code === 'PAYMENT_NOT_CAPTURED') {
      return createErrorResponse(400, 'PAYMENT_NOT_CAPTURED', err.message);
    }
    if (err.code === 'CONCURRENT_MUTATION_LOCKED') {
      return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', err.message);
    }
    
    console.error('Verify order error:', err);
    return createErrorResponse(500, 'INTERNAL_ERROR', 'An unexpected error occurred verifying the order.');
  }
}
