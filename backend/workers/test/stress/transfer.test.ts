import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, mockLockService, TestClock } from '../setup';
import { TransferService } from '../../src/services/transferService';


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


describe('Transfer Contention & Concurrency', () => {
  let env: any;

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  it('safely serializes concurrent transfer requests and prevents duplicate requests', async () => {
    // 1. Initial State
    const customerId = 'cust_stress';
    const oldInstId = 'inst_old';
    const subId = 'sub_stress';
    const newHardwareId = 'hw_new';

    mockFirestore._db.set(`installations/${oldInstId}`, { installationId: oldInstId, customerId, status: 'ACTIVE' });
    mockFirestore._db.set(`subscriptions/${subId}`, {
      subscriptionId: subId,
      customerId,
      activeInstallationId: oldInstId,
      status: 'ACTIVE',
      expiresAtEpochMs: TestClock.now() + 86400000
    });

    // 2. We override the mockLockService to actually simulate a basic mutex lock
    let isLocked = false;
    const lockWaiters: (() => void)[] = [];
    
    mockLockService.withLock.mockImplementation(async (mockCtx, env, lockType, resourceId, timeoutMs, metadata, doWork) => {
      if (isLocked) {
        await new Promise<void>(resolve => {
          lockWaiters.push(resolve);
        });
      }
      isLocked = true;
      try {
        return await doWork();
      } finally {
        isLocked = false;
        const next = lockWaiters.shift();
        if (next) next();
      }
    });

    // 3. Fire 10 Transfer Requests Concurrently
    const requests = Array.from({ length: 10 }).map(() => {
      const identity = { hardwareId: newHardwareId, uid: 'uid_1', platform: 'android', appVersion: '1.0', installationUuid: 'inst_new' } as any;
      // Wrap in a promise that catches errors so Promise.all doesn't reject early
      return TransferService.requestTransfer(mockCtx, env, customerId, subId, undefined, identity, 'Samsung').catch(e => e);
    });

    const results = await Promise.all(requests);

    // 4. Verify Outcomes
    // EXACTLY ONE request should succeed. 
    const successes = results.filter(r => r.success === true);
    expect(successes.length).toBe(1);

    const failures = results.filter(r => r instanceof Error);
    expect(failures.length).toBe(9);
    expect(failures[0].code).toBe('ONLY_ONE_PENDING_TRANSFER_ALLOWED');

    // Only one transfer record should exist
    const transferKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('device_transfers/'));
    expect(transferKeys.length).toBe(1);
  });
});
