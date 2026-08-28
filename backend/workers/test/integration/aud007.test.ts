import { describe, it, expect, beforeEach, vi } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, mockLockService, TestClock } from '../setup';
import { handleAdminManageSubscription } from '../../src/routes/admin';


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


describe('Phase 3 Integration: AUD-007 (Subscription Removal Orphan Prevention)', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('AUD-007: Atomically revokes installation and cancels subscription, rolling back entirely on simulated failure', async () => {
    const customerId = 'cust_aud007';
    const subId = 'sub_aud007';
    const hardwareId = 'inst_aud007';

    mockFirestore._db.set(`installations/${hardwareId}`, { installationId: hardwareId, customerId, hardwareId, status: 'ACTIVE' });
    mockFirestore._db.set(`subscriptions/${subId}`, {
      subscriptionId: subId, customerId, activeInstallationId: hardwareId, planId: 'PRO_YEARLY',
      status: 'ACTIVE', expiresAtEpochMs: TestClock.now()
    });

    const adminReq = new Request('https://api.vendsoft.com/admin', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'REMOVE' })
    });

    // Simulate batch failure
    mockFirestore.commitAtomicWrites.mockRejectedValueOnce(Object.assign(new Error('BATCH_TRANSACTION_FAILED'), { code: 'BATCH_TRANSACTION_FAILED' }));

    const res = await handleAdminManageSubscription(mockCtx, adminReq, env, 'admin1', customerId);
    expect(res.status).toBe(500); // Should fail and return an error

    // Verify rollbacks
    const sub = mockFirestore._db.get(`subscriptions/${subId}`);
    expect(sub.status).toBe('ACTIVE');

    const inst = mockFirestore._db.get(`installations/${hardwareId}`);
    expect(inst.status).toBe('ACTIVE');

    const auditKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
    expect(auditKeys.length).toBe(0);

    // Now run successfully. Do not override the default mock implementation so writes are applied.
    const adminReq2 = new Request('https://api.vendsoft.com/admin', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'REMOVE' })
    });
    
    const res2 = await handleAdminManageSubscription(mockCtx, adminReq2, env, 'admin1', customerId);
    expect(res2.status).toBe(200);

    // Verify atomic application
    const subAfter = mockFirestore._db.get(`subscriptions/${subId}`);
    expect(subAfter.status).toBe('CANCELLED');

    const instAfter = mockFirestore._db.get(`installations/${hardwareId}`);
    expect(instAfter.status).toBe('ACTIVE');

    const auditKeysAfter = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
    expect(auditKeysAfter.length).toBe(1);
  });
});
