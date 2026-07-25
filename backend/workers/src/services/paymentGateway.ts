import { Env } from '../types';
import { generateShortId } from '../cryptoEngine';

export interface VerifiedPayment {
  orderId: string;
  paymentId: string;
  signature?: string;
}

export interface PaymentGateway {
  createOrder(env: Env, amountPaise: number, notes: Record<string, string>): Promise<string>;
  verifyPaymentSignature(env: Env, orderId: string, paymentId: string, signature: string): Promise<boolean>;
  verifyWebhookSignature(env: Env, rawBody: string, signature: string): Promise<boolean>;
  verifyPaymentFallback(env: Env, orderId: string): Promise<string | null>;
  refundPayment(env: Env, paymentId: string): Promise<boolean>;
}

export class RazorpayProvider implements PaymentGateway {
  async createOrder(env: Env, amountPaise: number, notes: Record<string, string>): Promise<string> {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      // Return dummy order ID for local dev
      return `order_${generateShortId()}`;
    }

    const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
    const rzpResp = await fetch('https://api.razorpay.com/v1/orders', {
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
      })
    });

    if (!rzpResp.ok) {
      const errText = await rzpResp.text();
      console.error('Razorpay order creation failed:', errText);
      const err: any = new Error(`Payment gateway error (${rzpResp.status})`);
      err.code = 'RAZORPAY_GATEWAY_ERROR';
      throw err;
    }

    const rzpData: any = await rzpResp.json();
    return rzpData.id || `order_${generateShortId()}`;
  }

  async verifyPaymentSignature(env: Env, orderId: string, paymentId: string, signature: string): Promise<boolean> {
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
      console.error('Signature verification error:', err);
      return false;
    }
  }

  async verifyWebhookSignature(env: Env, rawBody: string, signature: string): Promise<boolean> {
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
      console.error('Webhook signature verification error:', err);
      return false;
    }
  }

  async verifyPaymentFallback(env: Env, orderId: string): Promise<string | null> {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      return `pay_${generateShortId()}`; // Local dev simulation
    }

    try {
      const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
      const rzpResp = await fetch(`https://api.razorpay.com/v1/orders/${orderId}/payments`, {
        method: 'GET',
        headers: { 'Authorization': authHeader }
      });
      
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
      console.error('Razorpay fallback verification check error:', err);
    }
    return null;
  }

  async refundPayment(env: Env, paymentId: string): Promise<boolean> {
    if (!env.RAZORPAY_KEY_ID || !env.RAZORPAY_KEY_SECRET) {
      return true; // Local dev simulation
    }

    try {
      const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
      const refundResp = await fetch(`https://api.razorpay.com/v1/payments/${paymentId}/refund`, {
        method: 'POST',
        headers: { 'Authorization': authHeader, 'Content-Type': 'application/json' },
        body: JSON.stringify({ speed: 'normal' })
      });

      if (refundResp.ok || refundResp.status === 400) {
        return true;
      } else {
        console.error('Razorpay Refund API Error:', await refundResp.text());
        return false;
      }
    } catch (err) {
      console.error('Razorpay refund exception:', err);
      return false;
    }
  }
}
