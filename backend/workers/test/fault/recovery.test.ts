import { describe, it, expect, beforeEach, vi } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, TestClock } from '../setup';
import { handleRazorpayWebhook } from '../../src/webhooks';

describe('Recovery & Retry Testing', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('recovers from a crashed refund saga on retry', async () => {
    // 1. Initial State: Payment is stuck in REFUND_PENDING
    const razorpayOrderId = 'order_stuck';
    
    mockFirestore._db.set(`payments/${razorpayOrderId}`, {
      paymentId: razorpayOrderId,
      razorpayOrderId,
      status: 'REFUND_PENDING',
      updatedAtEpochMs: TestClock.now()
    });

    // We simulate Razorpay API succeeding this time (by default mock returns true for refund)
    
    // 2. Webhook Delivery (Retry)
    const webhookPayload = {
      event: 'payment.captured',
      payload: { payment: { entity: { id: 'pay_stuck', order_id: razorpayOrderId } } }
    };
    
    const request = new Request('https://api.vendsoft.com/webhooks/razorpay', {
      method: 'POST',
      headers: { 'x-razorpay-signature': 'valid_webhook_sig', 'Content-Type': 'application/json' },
      body: JSON.stringify(webhookPayload)
    });

    const response = await handleRazorpayWebhook(request, env);
    expect(response.status).toBe(200);

    // 3. Verify Outcome
    // The system should recognize it was in REFUND_PENDING, execute the refund, and transition to REFUNDED.
    const payment = mockFirestore._db.get(`payments/${razorpayOrderId}`);
    expect(payment.status).toBe('REFUNDED');
    expect(payment.refundedAtEpochMs).toBeDefined();
  });
});
