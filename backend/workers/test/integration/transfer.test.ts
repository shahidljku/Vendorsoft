import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, TestClock } from '../setup';
import { TransferService } from '../../src/services/transferService';

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
    const { data: result } = await TransferService.approveTransfer(env, transferId, identity);

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
});
