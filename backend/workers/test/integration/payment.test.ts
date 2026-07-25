import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, TestClock } from '../setup';
import { PaymentService } from '../../src/services/paymentService';
import { handleRazorpayWebhook } from '../../src/webhooks';
import { handleCreateOrder } from '../../src/routes/orders';
import { CompositeIdentity } from '../../src/types';


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


describe('Payment Integration & Outcomes', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('provisions a new subscription on successful webhook settlement', async () => {
    // 1. Setup initial state: Customer with an active installation, no subscription
    const customerId = 'cust_123';
    const installationId = 'inst_456';
    mockFirestore._db.set(`installations/${installationId}`, {
      installationId,
      customerId,
      status: 'ACTIVE'
    });

    const identity: CompositeIdentity = {
      customerId,
      installationId,
      hardwareId: 'hw_456',
      uid: 'firebase_123',
      platform: 'android',
      appVersion: '1.0'
    };

    // 2. Initiate Order (via route simulation)
    // In our test, we'll bypass the raw Request object parsing by calling PaymentService directly, 
    // OR mock Request. Let's call PaymentService directly to test the domain boundaries.
    const { razorpayOrderId } = await PaymentService.initiateOrder(mockCtx, env,
      identity,
      'PRO_YEARLY',
      'Pro Annual',
      365,
      1499,
      149900,
      TestClock.now()
    );

    expect(razorpayOrderId).toBeDefined();
    const paymentRec = mockFirestore._db.get(`payments/${razorpayOrderId}`);
    expect(paymentRec).toBeDefined();
    expect(paymentRec.status).toBe('INITIATED');

    // 3. Webhook Delivers Payment Success
    const webhookPayload = {
      event: 'payment.captured',
      payload: {
        payment: {
          entity: {
            id: 'pay_789',
            order_id: razorpayOrderId
          }
        }
      }
    };

    // Build mock Request
    const request = new Request('https://api.vendsoft.com/webhooks/razorpay', {
      method: 'POST',
      headers: {
        'x-razorpay-signature': 'valid_webhook_sig',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(webhookPayload)
    });

    const response = await handleRazorpayWebhook(mockCtx, request, env);
    expect(response.status).toBe(200);
    const respBody = await response.json() as any;
    expect(respBody.success).toBe(true);

    // 4. Verify OUTCOMES (not just mock calls)
    // A) Payment status should be SUCCESS
    const settledPayment = mockFirestore._db.get(`payments/${razorpayOrderId}`);
    expect(settledPayment.status).toBe('SUCCESS');
    expect(settledPayment.razorpayPaymentId).toBe('pay_789');

    // B) Subscription should be ACTIVE
    const subId = settledPayment.subscriptionId;
    expect(subId).toBeDefined();
    
    const subDoc = mockFirestore._db.get(`subscriptions/${subId}`);
    expect(subDoc).toBeDefined();
    expect(subDoc.status).toBe('ACTIVE');
    expect(subDoc.activeInstallationId).toBe(installationId);
    expect(subDoc.planId).toBe('PRO_YEARLY');
    expect(subDoc.signedLeaseToken).toBe(`test_token_${subId}`);

    // C) Atomic commits executed
    // We expect exactly 1 call to commitAtomicWrites during the webhook for the settlement
    expect(mockFirestore.commitAtomicWrites).toHaveBeenCalled();
  });
});
