import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, mockLockService, TestClock } from '../setup';
import { PaymentService } from '../../src/services/paymentService';
import { handleRazorpayWebhook } from '../../src/webhooks';

describe('Performance Baselines', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('measures payment settlement performance under simulated network latency', async () => {
    // 1. Setup
    const customerId = 'cust_perf';
    const installationId = 'inst_perf';
    const razorpayOrderId = 'order_perf';

    mockFirestore._db.set(`installations/${installationId}`, { installationId, customerId, status: 'ACTIVE' });
    mockFirestore._db.set(`payments/${razorpayOrderId}`, {
      paymentId: razorpayOrderId,
      razorpayOrderId,
      installationId,
      customerId,
      planId: 'PRO_YEARLY',
      status: 'INITIATED',
      createdAtEpochMs: TestClock.now()
    });

    const webhookPayload = {
      event: 'payment.captured',
      payload: { payment: { entity: { id: 'pay_perf', order_id: razorpayOrderId } } }
    };

    const request = new Request('https://api.vendsoft.com/webhooks/razorpay', {
      method: 'POST',
      headers: { 'x-razorpay-signature': 'valid_webhook_sig', 'Content-Type': 'application/json' },
      body: JSON.stringify(webhookPayload)
    });

    // 2. Measure
    const start = process.hrtime.bigint();
    
    await handleRazorpayWebhook(request, env);
    
    const end = process.hrtime.bigint();
    const durationMs = Number(end - start) / 1e6;

    // 3. Verify
    // For our simulated environment, it should be very fast (under 100ms)
    console.log(`Payment Settlement completed in ${durationMs.toFixed(2)} ms`);
    expect(durationMs).toBeLessThan(100);
  });
});
