import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, mockLockService, TestClock } from '../setup';
import { handleRazorpayWebhook } from '../../src/webhooks';
import { handleAdminManageSubscription, handleAdminApproveTransfer } from '../../src/routes/admin';


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


describe('Phase 3 Integration: AUD-003 (Payment Settlement TOCTOU)', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
    
    // Simulate actual mutex locking
    const locks: Record<string, boolean> = {};
    const lockWaiters: Record<string, (() => void)[]> = {};
    mockLockService.withLock.mockImplementation(async (mockCtx, env, lockType, resourceId, timeoutMs, metadata, doWork) => {
      const key = `${lockType}:${resourceId}`;
      if (!lockWaiters[key]) lockWaiters[key] = [];
      while (locks[key]) {
        await new Promise<void>(resolve => lockWaiters[key].push(resolve));
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
  });

  it('AUD-003: Safely resolves concurrent webhook settlement vs admin extension', async () => {
    const customerId = 'cust_aud003';
    const razorpayOrderId = 'order_aud003';
    const subId = 'sub_aud003';

    mockFirestore._db.set(`installations/inst1`, { installationId: 'inst1', customerId, status: 'ACTIVE' });
    mockFirestore._db.set(`subscriptions/${subId}`, {
      subscriptionId: subId, customerId, activeInstallationId: 'inst1', planId: 'PRO_YEARLY',
      status: 'ACTIVE', expiresAtEpochMs: TestClock.now()
    });
    mockFirestore._db.set(`payments/${razorpayOrderId}`, {
      paymentId: razorpayOrderId, razorpayOrderId, installationId: 'inst1',
      customerId, planId: 'PRO_YEARLY', status: 'INITIATED', createdAtEpochMs: TestClock.now()
    });

    const webhookPayload = { event: 'payment.captured', payload: { payment: { entity: { id: 'pay1', order_id: razorpayOrderId } } } };
    
    const webhookReq = new Request('https://api.vendsoft.com/webhooks/razorpay', {
      method: 'POST',
      headers: { 'x-razorpay-signature': 'valid_webhook_sig', 'Content-Type': 'application/json' },
      body: JSON.stringify(webhookPayload)
    });

    const adminReq = new Request('https://api.vendsoft.com/admin', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'EXTEND', daysToAdd: 30 })
    });

    // Run concurrently
    const [webhookRes, adminRes] = await Promise.all([
      handleRazorpayWebhook(mockCtx, webhookReq, env),
      handleAdminManageSubscription(mockCtx, adminReq, env, 'admin1', customerId)
    ]);

    expect(webhookRes.status).toBe(200);
    expect(adminRes.status).toBe(200);
    
    // Both mutations should apply to the same canonical subscription
    const finalSub = mockFirestore._db.get(`subscriptions/${subId}`);
    // Original was TestClock.now(). Admin adds 30 days. Webhook adds 365 days. Total 395 days.
    const expectedTime = TestClock.now() + (395 * 86400 * 1000);
    expect(finalSub.expiresAtEpochMs).toBe(expectedTime);
  });
});
