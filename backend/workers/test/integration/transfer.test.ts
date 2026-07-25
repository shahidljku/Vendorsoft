import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, mockLockService, TestClock } from '../setup';
import { TransferService } from '../../src/services/transferService';
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


describe('Transfer Integration & Outcomes', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('successfully transfers a subscription from an old installation to a new one', async () => {
    // 1. Setup initial state
    const customerId = 'cust_555';
    const oldInstId = 'inst_old_555';
    const newInstId = 'inst_new_555';
    const subId = 'sub_555';
    
    mockFirestore._db.set(`installations/${oldInstId}`, { installationId: oldInstId, customerId, status: 'ACTIVE' });
    mockFirestore._db.set(`installations/${newInstId}`, { installationId: newInstId, customerId, status: 'ACTIVE' });
    
    mockFirestore._db.set(`subscriptions/${subId}`, {
      subscriptionId: subId,
      customerId,
      activeInstallationId: oldInstId,
      status: 'ACTIVE',
      expiresAtEpochMs: TestClock.now() + 86400000 // Valid
    });

    // We need an APPROVED transfer record to process
    const transferId = 'transfer_123';
    mockFirestore._db.set(`device_transfers/${transferId}`, {
      transferId,
      customerId,
      subscriptionId: subId,
      oldInstallationId: oldInstId,
      newInstallationId: newInstId,
      status: 'PENDING',
      expiresAtEpochMs: TestClock.now() + 3600000
    });

    // 2. Execute Transfer Workflow
    const identity = { hardwareId: 'hw_1', uid: 'uid_1', installationId: oldInstId, platform: 'android', appVersion: '1.0' } as any;
    const { data: result } = await TransferService.approveTransfer(mockCtx, env, transferId, identity);

    // 3. Verify Outcomes
    expect(result.status).toBe('APPROVED');

    // A) Subscription should now point to NEW installation
    const sub = mockFirestore._db.get(`subscriptions/${subId}`);
    expect(sub.activeInstallationId).toBe(newInstId);
    expect(sub.signedLeaseToken).toBe(`test_token_${subId}`);

    // B) Old installation should be REVOKED
    const oldInst = mockFirestore._db.get(`installations/${oldInstId}`);
    expect(oldInst.status).toBe('REVOKED');

    // C) Transfer record should be marked APPROVED
    const transfer = mockFirestore._db.get(`device_transfers/${transferId}`);
    expect(transfer.status).toBe('APPROVED');

    // D) Commit was atomic
    expect(mockFirestore.commitAtomicWrites).toHaveBeenCalled();
  });

  it('AUD-008: Standalone Trial Transfer Locking - enforces transfer_lock on admin trial transfer and prevents concurrent transfer collision', async () => {
    // 1. Setup initial state with only a standalone hardware trial (no subscription doc)
    const customerId = 'cust_trial_only';
    const oldInstId = 'hw_old_trial';
    const newInstId = 'hw_new_trial';
    
    mockFirestore._db.set(`installations/${oldInstId}`, { installationId: oldInstId, hardwareId: oldInstId, customerId, status: 'ACTIVE' });
    mockFirestore._db.set(`hardware_trials/${oldInstId}`, {
      hardwareId: oldInstId,
      customerId,
      status: 'ACTIVE',
      expiresAtEpochMs: TestClock.now() + 86400000
    });

    // 2. Simulate LockService ALREADY_EXISTS when transfer_lock is requested on TRIAL_hw_old_trial
    mockLockService.withLock.mockImplementationOnce(async (mockCtx: any, env: any, lockType: string, resourceId: string, timeoutMs: number, metadata: any, doWork: any) => {
      expect(lockType).toBe('transfer_lock');
      expect(resourceId).toBe(`TRIAL_${oldInstId}`);
      const err: any = new Error('Lock collision');
      err.code = 'ALREADY_EXISTS';
      throw err;
    });

    const req = new Request(`https://api.vendsoft.com/v1/admin/customers/${customerId}/manage-subscription`, {
      method: 'POST',
      body: JSON.stringify({ action: 'TRANSFER', newHardwareId: newInstId })
    });

    // 3. Execute admin transfer on standalone trial under lock contention
    const res = await handleAdminManageSubscription(mockCtx, req, env, 'admin_uid', customerId);
    
    // 4. Verify 409 CONCURRENT_MUTATION_LOCKED is returned instead of uncoordinated write
    expect(res.status).toBe(409);
    const body = await res.json() as any;
    expect(body.error.code).toBe('CONCURRENT_MUTATION_LOCKED');
  });
});
