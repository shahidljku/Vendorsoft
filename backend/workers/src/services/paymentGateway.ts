import { RequestContext } from './logger';
import { Env } from '../types';
import { generateShortId } from '../cryptoEngine';
import { 
  executeWithTimeout, 
  withRetry, 
  getCircuitBreaker, 
  ResiliencePolicies,
  LatencyWarningBudgets
} from './resilience';

export interface VerifiedPayment {
  orderId: string;
  paymentId: string;
  signature?: string;
}

export interface PaymentGateway {
  createOrder(ctx: RequestContext, env: Env, amountPaise: number, notes: Record<string, string>): Promise<string>;
  verifyPaymentSignature(ctx: RequestContext, env: Env, orderId: string, paymentId: string, signature: string): Promise<boolean>;
  verifyWebhookSignature(ctx: RequestContext, env: Env, rawBody: string, signature: string): Promise<boolean>;
  verifyPaymentFallback(ctx: RequestContext, env: Env, orderId: string): Promise<string | null>;
  refundPayment(ctx: RequestContext, env: Env, paymentId: string): Promise<boolean>;
}

const isTransientRazorpayError = (err: any) => {
  const str = String(err);
  if (str.includes('TimeoutError')) return true;
  if (str.match(/error \((500|502|503|504)\)/)) return true;
  if (str.includes('fetch') || str.includes('network') || str.includes('ECONNRESET')) return true;
  return false;
};

export class RazorpayProvider implements PaymentGateway {
  async createOrder(ctx: RequestContext, env: Env, amountPaise: number, notes: Record<string, string>): Promise<string> {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      // Return dummy order ID for local dev
      return `order_${generateShortId()}`;
    }

    return ctx.telemetry.measure('razorpay.createOrder', { amount: String(amountPaise) }, async () => {
      return getCircuitBreaker('razorpay', ResiliencePolicies.razorpayMutation.circuitBreaker).execute(ctx, async () => {
        return withRetry(ResiliencePolicies.razorpayMutation.retry, async () => {
          const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
          const rzpResp = await executeWithTimeout(
            ResiliencePolicies.razorpayMutation.timeoutMs,
            (signal) => fetch('https://api.razorpay.com/v1/orders', {
              method: 'POST',
              headers: {
                'Authorization': authHeader,
                'Content-Type': 'application/json'
              },
              body: JSON.stringify({
                amount: amountPaise,
                currency: 'INR',
                receipt: `rcpt_${generateShortId()}`,
                notes
              }),
              signal
            })
          );

          if (!rzpResp.ok) {
            const errText = await rzpResp.text();
            ctx.logger.error('Razorpay order creation failed:', errText);
            const err: any = new Error(`Payment gateway error (${rzpResp.status})`);
            err.code = 'RAZORPAY_GATEWAY_ERROR';
            throw err;
          }

          const rzpData: any = await rzpResp.json();
          return rzpData.id || `order_${generateShortId()}`;
        }, isTransientRazorpayError);
      });
    }, LatencyWarningBudgets.razorpay);
  }

  async verifyPaymentSignature(ctx: RequestContext, env: Env, orderId: string, paymentId: string, signature: string): Promise<boolean> {
    if (!env.RAZORPAY_WEBHOOK_SECRET) {
      return true; // Local dev simulation
    }
    
    try {
      const cryptoSecret = env.RAZORPAY_WEBHOOK_SECRET;
      const msg = `${orderId}|${paymentId}`;
      const enc = new TextEncoder();
      const key = await crypto.subtle.importKey('raw', enc.encode(cryptoSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
      const signatureBytes = await crypto.subtle.sign('HMAC', key, enc.encode(msg));
      const hexSignature = Array.from(new Uint8Array(signatureBytes)).map((b) => b.toString(16).padStart(2, '0')).join('');
      return hexSignature === signature;
    } catch (err) {
      ctx.logger.error('Signature verification error:', err);
      return false;
    }
  }

  async verifyWebhookSignature(ctx: RequestContext, env: Env, rawBody: string, signature: string): Promise<boolean> {
    if (!env.RAZORPAY_WEBHOOK_SECRET) {
      return true; // Local dev simulation
    }

    try {
      const cryptoSecret = env.RAZORPAY_WEBHOOK_SECRET;
      const enc = new TextEncoder();
      const key = await crypto.subtle.importKey('raw', enc.encode(cryptoSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
      const signatureBytes = await crypto.subtle.sign('HMAC', key, enc.encode(rawBody));
      const hexSignature = Array.from(new Uint8Array(signatureBytes)).map((b) => b.toString(16).padStart(2, '0')).join('');
      return hexSignature === signature;
    } catch (err) {
      ctx.logger.error('Webhook signature verification error:', err);
      return false;
    }
  }

  async verifyPaymentFallback(ctx: RequestContext, env: Env, orderId: string): Promise<string | null> {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      return `pay_${generateShortId()}`; // Local dev simulation
    }

    return ctx.telemetry.measure('razorpay.verifyFallback', { orderId }, async () => {
      return getCircuitBreaker('razorpay', ResiliencePolicies.razorpayRead.circuitBreaker).execute(ctx, async () => {
        return withRetry(ResiliencePolicies.razorpayRead.retry, async () => {
          try {
            const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
            const rzpResp = await executeWithTimeout(
              ResiliencePolicies.razorpayRead.timeoutMs,
              (signal) => fetch(`https://api.razorpay.com/v1/orders/${orderId}/payments`, {
                method: 'GET',
                headers: { 'Authorization': authHeader },
                signal
              })
            );
            
            if (rzpResp.ok) {
              const rzpData: any = await rzpResp.json();
              const items = rzpData.items || [];
              for (const item of items) {
                if (item.status === 'captured') {
                  return item.id;
                }
              }
            }
          } catch (err) {
            ctx.logger.error('Razorpay fallback verification check error:', err);
            throw err;
          }
          return null;
        }, isTransientRazorpayError);
      });
    }, LatencyWarningBudgets.razorpay).catch(() => null);
  }

  async refundPayment(ctx: RequestContext, env: Env, paymentId: string): Promise<boolean> {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      return true; // Local dev simulation
    }

    return ctx.telemetry.measure('razorpay.refund', { paymentId }, async () => {
      return getCircuitBreaker('razorpay', ResiliencePolicies.razorpayMutation.circuitBreaker).execute(ctx, async () => {
        return withRetry(ResiliencePolicies.razorpayMutation.retry, async () => {
          try {
            const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
            const refundResp = await executeWithTimeout(
              ResiliencePolicies.razorpayMutation.timeoutMs,
              (signal) => fetch(`https://api.razorpay.com/v1/payments/${paymentId}/refund`, {
                method: 'POST',
                headers: { 'Authorization': authHeader, 'Content-Type': 'application/json' },
                body: JSON.stringify({ speed: 'normal' }),
                signal
              })
            );

            if (refundResp.ok || refundResp.status === 400) {
              return true;
            } else {
              ctx.logger.error('Razorpay Refund API Error:', await refundResp.text());
              throw new Error(`Refund error: ${refundResp.status}`);
            }
          } catch (err) {
            ctx.logger.error('Razorpay refund exception:', err);
            throw err;
          }
        }, isTransientRazorpayError);
      });
    }, LatencyWarningBudgets.razorpay).catch(() => false);
  }
}
