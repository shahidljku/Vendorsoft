import { vi } from 'vitest';

let db = new Map<string, any>();
let currentMillis = 1000000000000;
let idCounter = 1;

export function resetTestEnv() {
  db.clear();
  currentMillis = 1000000000000;
  idCounter = 1;
}

export const TestClock = {
  now: () => currentMillis,
  advanceBy: (ms: number) => { currentMillis += ms; }
};

vi.spyOn(Date, 'now').mockImplementation(() => TestClock.now());

export const TestIdGenerator = {
  next: () => `id_${idCounter++}`
};

export function getMockEnv() {
  return {
    RAZORPAY_KEY_ID: 'test_key',
    RAZORPAY_KEY_SECRET: 'test_secret',
    RAZORPAY_WEBHOOK_SECRET: 'test_webhook_secret',
    RSA_PRIVATE_KEY: 'test_rsa_key'
  } as any;
}

// Mocking firestore operations
export const mockFirestore = {
  getDocument: vi.fn(async (env, collectionPath, documentId) => {
    return db.get(`${collectionPath}/${documentId}`) || null;
  }),
  setDocument: vi.fn(async (env, collectionPath, documentId, data) => {
    db.set(`${collectionPath}/${documentId}`, data);
  }),
  commitAtomicWrites: vi.fn(async (env, writes) => {
    // Basic atomic commit simulation
    for (const write of writes) {
      if (write.requireDoesNotExist && db.has(`${write.collectionPath}/${write.documentId}`)) {
        const err: any = new Error('ALREADY_EXISTS');
        err.code = 'ALREADY_EXISTS';
        throw err;
      }
    }
    for (const write of writes) {
      if (write.data === null) {
        db.delete(`${write.collectionPath}/${write.documentId}`);
      } else {
        db.set(`${write.collectionPath}/${write.documentId}`, write.data);
      }
    }
  }),
  queryCollection: vi.fn(async (env, collectionPath, filters) => {
    const results = [];
    for (const [key, val] of db.entries()) {
      if (key.startsWith(`${collectionPath}/`)) {
        let match = true;
        for (const f of filters) {
          if (f.op === 'EQUAL' && val[f.field] !== f.value) match = false;
        }
        if (match) results.push(val);
      }
    }
    return results;
  }),
  logAuditEvent: vi.fn(async (env, event, details) => {
    db.set(`audit_logs/${TestIdGenerator.next()}`, { event, details, timestamp: TestClock.now() });
  }),
  _db: db
};

export const mockLockService = {
  withLock: vi.fn(async (env, lockType, resourceId, timeoutMs, metadata, doWork) => {
    // Basic lock mock - execute sequentially immediately. 
    // For contention tests, we will override this mock per-test.
    return await doWork();
  })
};

vi.mock('../src/services/firestore', () => ({
  getDocument: mockFirestore.getDocument,
  setDocument: mockFirestore.setDocument,
  commitAtomicWrites: mockFirestore.commitAtomicWrites,
  queryCollection: mockFirestore.queryCollection,
  logAuditEvent: mockFirestore.logAuditEvent
}));

vi.mock('../src/services/lock', () => ({
  LockService: mockLockService
}));

vi.mock('../src/cryptoEngine', () => ({
  generateShortId: () => TestIdGenerator.next(),
  generateSignedLeaseToken: vi.fn(async (payload, secret) => `test_token_${payload.subscriptionId}`)
}));

vi.mock('../src/services/paymentGateway', () => {
  return {
    RazorpayProvider: class {
      async createOrder(env: any, amountPaise: number, notes: any) {
        return `rzp_order_${TestIdGenerator.next()}`;
      }
      async verifyPaymentSignature(env: any, orderId: string, paymentId: string, signature: string) {
        return signature === 'valid_sig';
      }
      async verifyWebhookSignature(env: any, rawBody: string, signature: string) {
        return signature === 'valid_webhook_sig';
      }
      async verifyPaymentFallback(env: any, orderId: string) {
        return null;
      }
      async refundPayment(env: any, paymentId: string) {
        return true;
      }
    }
  };
});
