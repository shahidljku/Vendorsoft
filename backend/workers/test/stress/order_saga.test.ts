import { describe, it, expect, beforeEach, vi } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, TestClock } from '../setup';
import { handleCreateOrder } from '../../src/routes/orders';
import { IdempotencyFSM } from '../../src/services/idempotencyService';


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


vi.mock('../../src/authGuard', () => ({
  authenticateRequest: vi.fn(async (ctx: any, request: any) => {
    const customerId = request.headers.get('x-customer-id') || 'cust_test';
    const installationId = request.headers.get('x-installation-id') || 'inst_test';
    const idempotencyKey = request.headers.get('x-idempotency-key') || undefined;
    return {
      identity: {
        uid: 'user_123',
        customerId,
        installationId,
        hardwareId: 'hw_test',
        installationUuid: installationId,
        appVersion: '1.0',
        platform: 'android',
        idempotencyKey
      }
    };
  }),
  createErrorResponse: (status: number, code: string, message: string) => {
    return new Response(JSON.stringify({ success: false, error: { code, message } }), {
      status,
      headers: { 'Content-Type': 'application/json' }
    });
  }
}));

describe('Pillar 3: Idempotency & Order Creation Saga', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  describe('IdempotencyFSM Invariants', () => {
    it('enforces legal transitions and rejects illegal transitions', () => {
      expect(IdempotencyFSM.transition('NONE', 'INITIATING')).toBe('INITIATING');
      expect(IdempotencyFSM.transition('INITIATING', 'ORDER_CREATED')).toBe('ORDER_CREATED');
      expect(IdempotencyFSM.transition('ORDER_CREATED', 'ORDER_CREATED')).toBe('ORDER_CREATED');
      expect(IdempotencyFSM.transition('INITIATING', 'FAILED')).toBe('FAILED');
      expect(IdempotencyFSM.transition('FAILED', 'INITIATING')).toBe('INITIATING');

      expect(() => IdempotencyFSM.transition('ORDER_CREATED', 'INITIATING')).toThrowError(/Illegal idempotency transition/);
      expect(() => IdempotencyFSM.transition('NONE', 'ORDER_CREATED')).toThrowError(/Illegal idempotency transition/);
    });
  });

  describe('Order Creation Idempotency & Concurrency', () => {
    it('serializes concurrent order creation requests and returns identical responses without duplicate orders', async () => {
      const idempotencyKey = 'key_concurrent_stress_1';
      
      const makeRequest = () => new Request('https://api.vendsoft.com/api/v1/orders/create', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer test_token',
          'x-customer-id': 'cust_stress',
          'x-installation-id': 'inst_stress',
          'x-idempotency-key': idempotencyKey,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ planId: 'PRO_YEARLY' })
      });

      // Phase 1: Fire 5 concurrent requests with exact same idempotency key while order is initiating
      const initialResponses = await Promise.all([
        handleCreateOrder(mockCtx, makeRequest(), env),
        handleCreateOrder(mockCtx, makeRequest(), env),
        handleCreateOrder(mockCtx, makeRequest(), env),
        handleCreateOrder(mockCtx, makeRequest(), env),
        handleCreateOrder(mockCtx, makeRequest(), env)
      ]);

      // Exactly 1 request must win the lease and return 201; concurrent contenders return 409 ORDER_IN_PROGRESS
      const successResponses = initialResponses.filter(r => r.status === 201);
      const conflictResponses = initialResponses.filter(r => r.status === 409);
      expect(successResponses.length).toBe(1);
      expect(conflictResponses.length).toBe(4);

      const winBody = await successResponses[0].json() as any;
      const firstOrderId = winBody.data.razorpayOrderId;
      expect(firstOrderId).toBeDefined();

      // Verify database state: exactly 1 payment document and 1 idempotency record created
      const paymentKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('payments/'));
      expect(paymentKeys.length).toBe(1);

      const idempotencyDoc = mockFirestore._db.get(`idempotency_keys/${idempotencyKey}`);
      expect(idempotencyDoc).toBeDefined();
      expect(idempotencyDoc.status).toBe('ORDER_CREATED');

      // Phase 2: Fire 5 MORE requests now that order is ORDER_CREATED (Replay Protection)
      const replayResponses = await Promise.all([
        handleCreateOrder(mockCtx, makeRequest(), env),
        handleCreateOrder(mockCtx, makeRequest(), env),
        handleCreateOrder(mockCtx, makeRequest(), env),
        handleCreateOrder(mockCtx, makeRequest(), env),
        handleCreateOrder(mockCtx, makeRequest(), env)
      ]);

      // All replay requests must return 201 with the exact same razorpayOrderId
      for (const res of replayResponses) {
        expect(res.status).toBe(201);
        const body = await res.json() as any;
        expect(body.data.razorpayOrderId).toBe(firstOrderId);
      }

      // No additional orders created
      const finalPaymentKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('payments/'));
      expect(finalPaymentKeys.length).toBe(1);
    });
  });

  describe('Active Saga Contention', () => {
    it('returns 409 ORDER_IN_PROGRESS when another worker holds an active lease', async () => {
      const idempotencyKey = 'key_active_contention';
      const now = TestClock.now();

      // Pre-populate active lease in INITIATING state expiring in 15 seconds
      mockFirestore._db.set(`idempotency_keys/${idempotencyKey}`, {
        keyId: idempotencyKey,
        status: 'INITIATING',
        ownerToken: 'worker_active_1',
        ownerLeaseExpiresAtEpochMs: now + 15000,
        createdAtEpochMs: now,
        updatedAtEpochMs: now
      });

      const request = new Request('https://api.vendsoft.com/api/v1/orders/create', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer test_token',
          'x-customer-id': 'cust_contention',
          'x-installation-id': 'inst_contention',
          'x-idempotency-key': idempotencyKey,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ planId: 'PRO_YEARLY' })
      });

      const response = await handleCreateOrder(mockCtx, request, env);
      expect(response.status).toBe(409);
      const body = await response.json() as any;
      expect(body.error.code).toBe('ORDER_IN_PROGRESS');
    });
  });

  describe('Gateway Success Crash Recovery', () => {
    it('recovers authoritative order from payments collection when worker crashed after gateway success', async () => {
      const idempotencyKey = 'key_crash_recovery_1';
      const now = TestClock.now();
      const crashedOrderId = 'rzp_order_crashed_after_success';

      // 1. Simulate Worker A acquiring lease and crashing after writing payments collection
      mockFirestore._db.set(`idempotency_keys/${idempotencyKey}`, {
        keyId: idempotencyKey,
        status: 'INITIATING',
        ownerToken: 'worker_crashed_A',
        ownerLeaseExpiresAtEpochMs: now - 1000, // Lease EXPIRED 1s ago
        createdAtEpochMs: now - 20000,
        updatedAtEpochMs: now - 20000
      });

      mockFirestore._db.set(`payments/${crashedOrderId}`, {
        paymentId: crashedOrderId,
        razorpayOrderId: crashedOrderId,
        installationId: 'inst_recovery',
        customerId: 'cust_recovery',
        planId: 'PRO_YEARLY',
        amountInr: 1499,
        amountPaise: 149900,
        idempotencyKey, // Written during initiateOrder
        status: 'INITIATE',
        createdAtEpochMs: now - 18000
      });

      // 2. Worker B attempts order creation with same idempotencyKey
      const request = new Request('https://api.vendsoft.com/api/v1/orders/create', {
        method: 'POST',
        headers: {
          'Authorization': 'Bearer test_token',
          'x-customer-id': 'cust_recovery',
          'x-installation-id': 'inst_recovery',
          'x-idempotency-key': idempotencyKey,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ planId: 'PRO_YEARLY' })
      });

      const response = await handleCreateOrder(mockCtx, request, env);
      expect(response.status).toBe(201);
      const body = await response.json() as any;

      // Must return the existing crashedOrderId without generating a new Razorpay order
      expect(body.data.razorpayOrderId).toBe(crashedOrderId);

      // Verify idempotency record transitioned to ORDER_CREATED
      const idempotencyDoc = mockFirestore._db.get(`idempotency_keys/${idempotencyKey}`);
      expect(idempotencyDoc.status).toBe('ORDER_CREATED');
      const savedPayload = JSON.parse(idempotencyDoc.responsePayload);
      expect(savedPayload.razorpayOrderId).toBe(crashedOrderId);
    });
  });
});
