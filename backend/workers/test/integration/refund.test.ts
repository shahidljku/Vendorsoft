import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, TestClock } from '../setup';
import { handleRazorpayWebhook } from '../../src/webhooks';

describe('Refund Saga Integration', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('safely triggers refund saga and marks payment REFUNDED upon device ownership conflict', async () => {
    // 1. Initial State: Another device already owns the active subscription
    const customerId = 'cust_999';
    const oldInstallationId = 'inst_OLD';
    const newInstallationId = 'inst_NEW';
    const subscriptionId = 'sub_999';
    
    mockFirestore._db.set(`installations/${oldInstallationId}`, { installationId: oldInstallationId, customerId, status: 'ACTIVE' });
    mockFirestore._db.set(`installations/${newInstallationId}`, { installationId: newInstallationId, customerId, status: 'ACTIVE' });
    
    mockFirestore._db.set(`subscriptions/${subscriptionId}`, {
      subscriptionId,
      customerId,
      activeInstallationId: oldInstallationId, // Owned by OLD device
      status: 'ACTIVE',
      expiresAtEpochMs: TestClock.now() + 86400000 // Active for 1 more day
    });

    // 2. An order is created for the NEW device
    const razorpayOrderId = 'order_conflict';
    mockFirestore._db.set(`payments/${razorpayOrderId}`, {
      paymentId: razorpayOrderId,
      razorpayOrderId,
      installationId: newInstallationId,
      customerId,
      planId: 'PRO_YEARLY',
      status: 'INITIATED',
      createdAtEpochMs: TestClock.now()
    });

    // 3. Webhook Delivery
    const webhookPayload = {
      event: 'payment.captured',
      payload: { payment: { entity: { id: 'pay_conflict', order_id: razorpayOrderId } } }
    };
    
    const request = new Request('https://api.vendsoft.com/webhooks/razorpay', {
      method: 'POST',
      headers: { 'x-razorpay-signature': 'valid_webhook_sig', 'Content-Type': 'application/json' },
      body: JSON.stringify(webhookPayload)
    });

    const response = await handleRazorpayWebhook(request, env);
    expect(response.status).toBe(200); // We return 200 to acknowledge webhook handling

    // 4. Verify Outcomes
    // A) The payment should be marked as completely REFUNDED because the saga executed successfully.
    const payment = mockFirestore._db.get(`payments/${razorpayOrderId}`);
    expect(payment.status).toBe('REFUNDED');
    expect(payment.refundedAtEpochMs).toBeDefined();

    // B) The subscription should STILL be owned by the old installation!
    const sub = mockFirestore._db.get(`subscriptions/${subscriptionId}`);
    expect(sub.activeInstallationId).toBe(oldInstallationId);
  });
});
