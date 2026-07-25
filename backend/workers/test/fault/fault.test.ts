import { describe, it, expect, beforeEach, vi } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, TestClock } from '../setup';
import { PaymentService } from '../../src/services/paymentService';
import { handleRazorpayWebhook } from '../../src/webhooks';


const mockCtx = {
  traceId: 'test-trace',
  logger: {
    trace: () => {},
    debug: () => {},
    info: () => {},
    warn: () => {},
    error: () => {}
  },
  telemetry: {
    measure: async (name, tags, fn) => fn()
  }
} as any;


describe('Fault Injection & Partial Writes', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('rolls back completely if commitAtomicWrites fails', async () => {
    // 1. Initial State
    const customerId = 'cust_fault';
    const installationId = 'inst_fault';
    const razorpayOrderId = 'order_fault';

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

    // 2. Inject Fault in Atomic Commit
    mockFirestore.commitAtomicWrites.mockRejectedValueOnce(new Error('FIRESTORE_UNAVAILABLE'));

    // 3. Webhook Delivery
    const webhookPayload = {
      event: 'payment.captured',
      payload: { payment: { entity: { id: 'pay_fault', order_id: razorpayOrderId } } }
    };
    
    const request = new Request('https://api.vendsoft.com/webhooks/razorpay', {
      method: 'POST',
      headers: { 'x-razorpay-signature': 'valid_webhook_sig', 'Content-Type': 'application/json' },
      body: JSON.stringify(webhookPayload)
    });

    const response = await handleRazorpayWebhook(mockCtx, request, env);
    expect(response.status).toBe(200); // Webhook always enqueues and returns 200. Queue handles retries.

    // 4. Verify OUTCOMES (No Partial Writes)
    // A) Payment should STILL be INITIATED, not SUCCESS
    const payment = mockFirestore._db.get(`payments/${razorpayOrderId}`);
    expect(payment.status).toBe('INITIATED');
    expect(payment.razorpayPaymentId).toBeUndefined();

    // B) No subscription should have been created in the database
    // The webhook creates a subscription with an ID starting with `sub_`
    let subCreated = false;
    for (const key of mockFirestore._db.keys()) {
      if (key.startsWith('subscriptions/sub_')) subCreated = true;
    }
    expect(subCreated).toBe(false);

    // Restore
    mockFirestore.commitAtomicWrites.mockRestore();
  });
});
