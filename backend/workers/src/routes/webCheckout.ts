import { RequestContext } from '../services/logger';
import { Env } from '../types';
import { createErrorResponse } from '../authGuard';
import { RazorpayProvider } from '../services/paymentGateway';
import { generateShortId } from '../cryptoEngine';

interface ApiResponse {
  success: boolean;
  data?: any;
  error?: {
    code: string;
    message: string;
  };
}

export async function handleWebCheckoutCreateOrder(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
  let body: { amount?: number; currency?: string };
  try {
    body = await request.json();
  } catch {
    return createErrorResponse(400, 'INVALID_JSON', 'Request body must be valid JSON.');
  }

  if (!body.amount || typeof body.amount !== 'number' || body.amount < 100) {
    return createErrorResponse(400, 'INVALID_AMOUNT', 'Amount must be at least 100 paise.');
  }

  try {
    const gateway = new RazorpayProvider();
    const orderId = await gateway.createOrder(ctx, env, body.amount, { source: 'web_checkout' });

    const resp: ApiResponse = {
      success: true,
      data: {
        order_id: orderId,
        amount: body.amount,
        currency: body.currency || 'INR',
        key_id: env.RAZORPAY_KEY_ID // Safe to send public key to frontend
      }
    };
    return new Response(JSON.stringify(resp), { 
      status: 200, 
      headers: { 
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      } 
    });
  } catch (err: any) {
    ctx.logger.error('Web Checkout Create Order Error:', err);
    return createErrorResponse(500, 'PAYMENT_GATEWAY_ERROR', 'Failed to create order with Razorpay.');
  }
}

export async function handleWebCheckoutVerifyOrder(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
  let body: {
    razorpay_order_id?: string;
    razorpay_payment_id?: string;
    razorpay_signature?: string;
  };
  try {
    body = await request.json();
  } catch {
    return createErrorResponse(400, 'INVALID_JSON', 'Request body must be valid JSON.');
  }

  if (!body.razorpay_order_id || !body.razorpay_payment_id || !body.razorpay_signature) {
    return createErrorResponse(400, 'MISSING_FIELDS', 'Missing required Razorpay fields for verification.');
  }

  try {
    const gateway = new RazorpayProvider();
    const isValid = await gateway.verifyPaymentSignature(ctx, env, body.razorpay_order_id, body.razorpay_payment_id, body.razorpay_signature);

    if (!isValid) {
      return createErrorResponse(400, 'INVALID_SIGNATURE', 'Payment signature verification failed.');
    }

    // Since this is just a standard web checkout without app integration, we just return success
    // If you had a database table for web orders, you would mark it paid here.
    const resp: ApiResponse = {
      success: true,
      data: {
        status: 'SUCCESS',
        message: 'Payment verified successfully.'
      }
    };
    return new Response(JSON.stringify(resp), { 
      status: 200, 
      headers: { 
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      } 
    });
  } catch (err: any) {
    ctx.logger.error('Web Checkout Verify Order Error:', err);
    return createErrorResponse(500, 'INTERNAL_ERROR', 'An unexpected error occurred verifying the order.');
  }
}
