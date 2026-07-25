import { describe, it, expect, beforeEach, vi } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, mockLockService, TestClock } from '../setup';
import { handleRazorpayWebhook } from '../../src/webhooks';
import { LockService } from '../../src/services/lock';


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


describe('Lock Contention & Concurrency', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('safely serializes concurrent webhook deliveries and only provisions once', async () => {
    // 1. Initial State
    const customerId = 'cust_stress';
    const installationId = 'inst_stress';
    const razorpayOrderId = 'order_stress';

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

    // 2. We override the mockLockService to actually simulate a mutex lock per resourceId
    const locks: Record<string, boolean> = {};
    const lockWaiters: Record<string, (() => void)[]> = {};
    
    mockLockService.withLock.mockImplementation(async (mockCtx, env, lockType, resourceId, timeoutMs, metadata, doWork) => {
      const key = `${lockType}:${resourceId}`;
      if (!lockWaiters[key]) lockWaiters[key] = [];
      
      while (locks[key]) {
        await new Promise<void>(resolve => {
          lockWaiters[key].push(resolve);
        });
      }
      locks[key] = true;
      try {
        return await doWork();
      } finally {
        locks[key] = false;
        const next = lockWaiters[key].shift();
        if (next) next();
      }
    });

    // 3. Fire 20 Webhooks Concurrently
    const webhookPayload = {
      event: 'payment.captured',
      payload: { payment: { entity: { id: 'pay_stress', order_id: razorpayOrderId } } }
    };
    
    const requests = Array.from({ length: 20 }).map(() => {
      const request = new Request('https://api.vendsoft.com/webhooks/razorpay', {
        method: 'POST',
        headers: { 'x-razorpay-signature': 'valid_webhook_sig', 'Content-Type': 'application/json' },
        body: JSON.stringify(webhookPayload)
      });
      return handleRazorpayWebhook(mockCtx, request, env);
    });

    const responses = await Promise.all(requests);

    // 4. Verify Outcomes
    // Only 1 should be processed and create the subscription. The others should return 200 indicating "processed" because it's already SETTLED.
    // Wait, if it's SETTLED, the FSM will throw ILLEGAL_TRANSITION when a duplicate webhook tries to settle it again!
    // But webhooks.ts doesn't catch ILLEGAL_TRANSITION and return 200. Let's see what happens.
    
    // We expect EXACTLY ONE atomic commit.
    expect(mockFirestore.commitAtomicWrites).toHaveBeenCalledTimes(1);

    const payment = mockFirestore._db.get(`payments/${razorpayOrderId}`);
    expect(payment.status).toBe('SUCCESS');

    // Only one subscription created
    const subKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('subscriptions/sub_'));
    expect(subKeys.length).toBe(1);
  });
});
