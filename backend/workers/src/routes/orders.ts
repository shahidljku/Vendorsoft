import { RequestContext } from '../services/logger';
import { Env, ApiResponse } from '../types';
import { authenticateRequest, createErrorResponse } from '../authGuard';
import { getDocument, queryCollection } from '../services/firestore';
import { PaymentService } from '../services/paymentService';
import { IdempotencyService } from '../services/idempotencyService';

/**
 * Handles POST /api/v1/orders/create
 * Initiates a new Razorpay payment order for subscription upgrade/renewal.
 */
export async function handleCreateOrder(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
  // 1. Authenticate request and verify zero-trust identity headers
  const authResult = await authenticateRequest(ctx, request, env);
  if (authResult.errorResponse) return authResult.errorResponse;
  const identity = authResult.identity!;

  let customerId = identity.customerId;
  const installationId = identity.installationId || identity.installationUuid;

  if (!installationId) {
    return createErrorResponse(400, 'MISSING_INSTALLATION_ID', 'Missing installation UUID.');
  }

  let instDoc: any = await getDocument(ctx, env, 'installations', installationId);

  // If customerId is not a 'cus_...' ID, resolve it to canonical customerId
  if (customerId && !customerId.startsWith('cus_')) {
    try {
      const cleanMobile = customerId.replace(/\D/g, '');
      if (cleanMobile.length === 10) {
        const custs = await queryCollection(ctx, env, 'customers', [
          { field: 'mobileNumber', op: 'EQUAL', value: cleanMobile }
        ]);
        if (custs && custs.length > 0 && custs[0].customerId) {
          customerId = custs[0].customerId;
        }
      }
    } catch (e) {
      console.warn('Customer resolution by mobile warning:', e);
    }
  }

  // Fallback to installation's registered customerId if still missing or not a cus_ ID
  if (!customerId || !customerId.startsWith('cus_')) {
    if (instDoc && instDoc.customerId && instDoc.customerId.startsWith('cus_')) {
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
  let priceInr = planId === 'PRO_MONTHLY' ? 149 : 1499;
  if (planId === 'PRO_MONTHLY_SOFT') priceInr = 799;
  if (planId === 'PRO_YEARLY_SOFT') priceInr = 9599;

  let durationDays = (planId === 'PRO_MONTHLY' || planId === 'PRO_MONTHLY_SOFT') ? 30 : (planId === 'PRO_YEARLY_SOFT' ? 395 : (planId === 'PRO_YEARLY' ? 395 : 365));
  let planName = (planId === 'PRO_MONTHLY' || planId === 'PRO_MONTHLY_SOFT') ? 'Pro Monthly License' : 'Pro Annual License';

  const planDoc = await getDocument(ctx, env, 'plans', planId);
  if (planDoc) {
    if (planDoc.isActive === false) {
      return createErrorResponse(400, 'PLAN_INACTIVE', `Plan '${planId}' is no longer available for purchase.`);
    }
    if (typeof planDoc.amountPaise === 'number') {
      priceInr = Math.floor(planDoc.amountPaise / 100);
    } else if (typeof planDoc.priceInr === 'number') {
      priceInr = planDoc.priceInr;
    }
    durationDays = (typeof planDoc.durationDays === 'number' && (planId !== 'PRO_YEARLY' || planDoc.durationDays !== 365)) ? planDoc.durationDays : durationDays;
    planName = typeof planDoc.name === 'string' ? planDoc.name : planName;
    if (planDoc.planName && !planDoc.name) {
      planName = planDoc.planName;
    }
  } else {
    if (planId !== 'PRO_MONTHLY' && planId !== 'PRO_YEARLY' && planId !== 'DEMO_FREE' && planId !== 'PRO_MONTHLY_SOFT' && planId !== 'PRO_YEARLY_SOFT') {
      return createErrorResponse(400, 'INVALID_PLAN_ID', `Unsupported planId: ${planId}`);
    }
  }

  const amountInr = priceInr;
  const amountPaise = priceInr * 100;
  const now = Date.now();
  // 4. Delegate to PaymentService to perform validations and order creation via Idempotency Saga
  try {
    const resultData = await IdempotencyService.executeOrderSaga(
      ctx,
      env,
      identity.idempotencyKey,
      now,
      async () => {
        const { razorpayOrderId } = await PaymentService.initiateOrder(ctx, env,
          { ...identity, customerId, installationUuid: installationId } as any,
          planId,
          planName,
          durationDays,
          amountInr,
          amountPaise,
          now,
          instDoc
        );
        return {
          razorpayOrderId,
          amountPaise,
          keyId: env.RAZORPAY_KEY_ID || '',
          planId,
          amountInr
        };
      }
    );

    const responseBody: ApiResponse = {
      success: true,
      data: resultData
    };

    return new Response(JSON.stringify(responseBody), {
      status: 201,
      headers: { 'Content-Type': 'application/json' }
    });
  } catch (err: any) {
    // Map domain errors to HTTP responses
    if (err.code === 'ORDER_IN_PROGRESS') {
      return createErrorResponse(409, 'ORDER_IN_PROGRESS', err.message);
    }
    if (err.code === 'LEASE_SUPERSEDED') {
      return createErrorResponse(409, 'LEASE_SUPERSEDED', err.message);
    }
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
export async function handleVerifyOrder(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
  const authResult = await authenticateRequest(ctx, request, env);
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

  const paymentDoc = await getDocument(ctx, env, 'payments', orderId);
  if (!paymentDoc) {
    return createErrorResponse(404, 'ORDER_NOT_FOUND', `Order '${orderId}' was not found.`);
  }

  // 1. Handle explicit payment cancellation / error dismissal by user
  if (body.errorCode && body.errorCode === 'PAYMENT_CANCELLED') {
    await PaymentService.cancelOrder(ctx, env, paymentDoc);
    const resp: ApiResponse = { success: true, data: { status: 'FAILED', message: 'Payment marked as failed/cancelled.' } };
    return new Response(JSON.stringify(resp), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }

  // 2. If already settled by webhook, return success instantly
  if (paymentDoc.status === 'SUCCESS') {
    let leaseToken = undefined;
    if (paymentDoc.subscriptionId) {
      const subDoc = await getDocument(ctx, env, 'subscriptions', paymentDoc.subscriptionId);
      if (subDoc && subDoc.signedLeaseToken) {
        leaseToken = subDoc.signedLeaseToken;
      }
    }
    const resp: ApiResponse = { 
      success: true, 
      data: { 
        status: 'SUCCESS', 
        message: 'Order already settled.',
        signedLeaseToken: leaseToken 
      } 
    };
    return new Response(JSON.stringify(resp), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }

  // 3. Delegate to PaymentService to Verify
  try {
    const verifiedPayment = await PaymentService.verifyOrder(ctx, env, orderId, body.razorpayPaymentId, body.razorpaySignature);

    // 4. Delegate to PaymentService to Settle
    const settlementResult = await PaymentService.settleOrder(ctx, env, verifiedPayment, paymentDoc);

    if (settlementResult.status === 'ALREADY_PROCESSED') {
      let leaseToken = undefined;
      const latestPaymentDoc = await getDocument(ctx, env, 'payments', orderId);
      if (latestPaymentDoc && latestPaymentDoc.subscriptionId) {
        const subDoc = await getDocument(ctx, env, 'subscriptions', latestPaymentDoc.subscriptionId);
        if (subDoc && subDoc.signedLeaseToken) {
          leaseToken = subDoc.signedLeaseToken;
        }
      }
      settlementResult.signedLeaseToken = leaseToken;
    }

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
    
    ctx.logger.error('Verify order error:', err);
    return createErrorResponse(500, 'INTERNAL_ERROR', 'An unexpected error occurred verifying the order.');
  }
}
