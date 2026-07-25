import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore } from '../setup';


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

import { 
  handleAdminUpdateCustomer,
  handleAdminBanDevice,
  handleAdminUnbanDevice,
  handleAdminUpdateSystemConfig,
  handleAdminUpdatePlans,
  handleAdminManageSubscription
} from '../../src/routes/admin';

describe('Phase 1 Integration: Atomic Audit Logging (AUD-005) & Plan Catalog Batching (AUD-006)', () => {
  let env: any;
  const adminUid = 'admin_super_123';

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
  });

  describe('AUD-005: Systemic Admin Audit Atomicity', () => {
    it('normally commits customer metadata update and audit log in a single atomic batch (WF-015)', async () => {
      const customerId = 'cust_101';
      mockFirestore._db.set(`customers/${customerId}`, {
        customerId,
        businessName: 'Old Business',
        status: 'ACTIVE'
      });

      const req = new Request('https://api.vendsoft.com/v1/admin/customers/cust_101', {
        method: 'PUT',
        body: JSON.stringify({ businessName: 'New Business' })
      });

      const res = await handleAdminUpdateCustomer(mockCtx, req, env, adminUid, customerId);
      expect(res.status).toBe(200);
      const body = await res.json() as any;
      expect(body.success).toBe(true);
      expect(body.data.businessName).toBe('New Business');

      // Verify atomic commit was used
      expect(mockFirestore.commitAtomicWrites).toHaveBeenCalled();
      const writes = mockFirestore.commitAtomicWrites.mock.calls[0][2];
      expect(writes).toHaveLength(2); // 1 business doc + 1 audit doc
      expect(writes[0].collectionPath).toBe('customers');
      expect(writes[1].collectionPath).toBe('audit_logs');
      expect(writes[1].data.action).toBe('ADMIN_UPDATE_CUSTOMER_METADATA');

      // Verify database state
      expect(mockFirestore._db.get(`customers/${customerId}`).businessName).toBe('New Business');
      const auditKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
      expect(auditKeys).toHaveLength(1);
    });

    it('rolls back completely on simulated commit failure without leaving orphaned audit or business records (WF-015)', async () => {
      const customerId = 'cust_102';
      mockFirestore._db.set(`customers/${customerId}`, {
        customerId,
        businessName: 'Safe Business',
        status: 'ACTIVE'
      });

      // Simulate transient Firestore commit failure
      mockFirestore.commitAtomicWrites.mockRejectedValueOnce(new Error('FIRESTORE_UNAVAILABLE'));

      const req = new Request('https://api.vendsoft.com/v1/admin/customers/cust_102', {
        method: 'PUT',
        body: JSON.stringify({ businessName: 'Corrupted Business' })
      });

      const res = await handleAdminUpdateCustomer(mockCtx, req, env, adminUid, customerId);
      expect(res.status).toBe(500);

      // Verify database state remained unchanged
      expect(mockFirestore._db.get(`customers/${customerId}`).businessName).toBe('Safe Business');
      const auditKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
      expect(auditKeys).toHaveLength(0); // No audit log written on aborted commit
    });

    it('atomically commits device ban and audit log, and rolls back on failure (WF-018 / WF-019)', async () => {
      const hardwareId = 'hw_ban_test';
      mockFirestore._db.set(`installations/${hardwareId}`, {
        hardwareId,
        status: 'ACTIVE',
        customerId: 'cust_999'
      });

      // 1. Normal Ban
      const banReq = new Request(`https://api.vendsoft.com/v1/admin/devices/${hardwareId}/ban`, { method: 'PUT' });
      const banRes = await handleAdminBanDevice(mockCtx, banReq, env, adminUid, hardwareId);
      expect(banRes.status).toBe(200);
      expect(mockFirestore._db.get(`installations/${hardwareId}`).status).toBe('BANNED');
      
      let auditKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
      expect(auditKeys).toHaveLength(1);
      expect(mockFirestore._db.get(auditKeys[0]).action).toBe('ADMIN_BANNED_DEVICE');

      // 2. Simulated Failure on Unban
      mockFirestore.commitAtomicWrites.mockRejectedValueOnce(new Error('CONCURRENCY_REJECTED'));
      const unbanReq = new Request(`https://api.vendsoft.com/v1/admin/devices/${hardwareId}/unban`, { method: 'PUT' });
      const unbanRes = await handleAdminUnbanDevice(mockCtx, unbanReq, env, adminUid, hardwareId);
      expect(unbanRes.status).toBe(500);
      expect(mockFirestore._db.get(`installations/${hardwareId}`).status).toBe('BANNED'); // Still banned!
      
      auditKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
      expect(auditKeys).toHaveLength(1); // Still only the 1 original ban audit log
    });

    it('atomically commits system config update and audit log (WF-020)', async () => {
      mockFirestore._db.set('system_configs/global', {
        allowPayments: true,
        maintenanceMode: false
      });

      const req = new Request('https://api.vendsoft.com/v1/admin/system/config', {
        method: 'PUT',
        body: JSON.stringify({ maintenanceMode: true })
      });

      const res = await handleAdminUpdateSystemConfig(mockCtx, req, env, adminUid);
      expect(res.status).toBe(200);
      expect(mockFirestore._db.get('system_configs/global').maintenanceMode).toBe(true);

      const auditKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
      expect(auditKeys).toHaveLength(1);
      expect(mockFirestore._db.get(auditKeys[0]).action).toBe('ADMIN_UPDATED_SYSTEM_CONFIG');
    });
  });

  describe('AUD-006: Plan Catalog Batching', () => {
    it('normally updates multiple plans and audit log in a single unified commitAtomicWrites batch (WF-021)', async () => {
      mockFirestore._db.set('plans/PRO_MONTHLY', { planId: 'PRO_MONTHLY', price: 199 });
      mockFirestore._db.set('plans/PRO_YEARLY', { planId: 'PRO_YEARLY', price: 1999 });
      mockFirestore._db.set('plans/ENTERPRISE', { planId: 'ENTERPRISE', price: 4999 });

      const req = new Request('https://api.vendsoft.com/v1/admin/plans', {
        method: 'POST',
        body: JSON.stringify({
          plans: [
            { planId: 'PRO_MONTHLY', price: 249 },
            { planId: 'PRO_YEARLY', price: 2499 },
            { planId: 'ENTERPRISE', price: 5999 }
          ]
        })
      });

      const res = await handleAdminUpdatePlans(mockCtx, req, env, adminUid);
      expect(res.status).toBe(200);

      // Verify commitAtomicWrites called once with 4 ops (3 plans + 1 audit log)
      expect(mockFirestore.commitAtomicWrites).toHaveBeenCalledTimes(1);
      const batchWrites = mockFirestore.commitAtomicWrites.mock.calls[0][2];
      expect(batchWrites).toHaveLength(4);

      expect(mockFirestore._db.get('plans/PRO_MONTHLY').price).toBe(249);
      expect(mockFirestore._db.get('plans/PRO_YEARLY').price).toBe(2499);
      expect(mockFirestore._db.get('plans/ENTERPRISE').price).toBe(5999);

      const auditKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
      expect(auditKeys).toHaveLength(1);
      expect(mockFirestore._db.get(auditKeys[0]).action).toBe('ADMIN_UPDATE_PLANS');
    });

    it('guarantees all-or-nothing rollback when updating catalog plans under simulated commit rejection (WF-021)', async () => {
      mockFirestore._db.set('plans/PRO_MONTHLY', { planId: 'PRO_MONTHLY', price: 199 });
      mockFirestore._db.set('plans/PRO_YEARLY', { planId: 'PRO_YEARLY', price: 1999 });
      mockFirestore._db.set('plans/ENTERPRISE', { planId: 'ENTERPRISE', price: 4999 });

      // Simulate atomic batch rejection
      mockFirestore.commitAtomicWrites.mockRejectedValueOnce(new Error('BATCH_TRANSACTION_FAILED'));

      const req = new Request('https://api.vendsoft.com/v1/admin/plans', {
        method: 'POST',
        body: JSON.stringify({
          plans: [
            { planId: 'PRO_MONTHLY', price: 999 },
            { planId: 'PRO_YEARLY', price: 9999 },
            { planId: 'ENTERPRISE', price: 99999 }
          ]
        })
      });

      const res = await handleAdminUpdatePlans(mockCtx, req, env, adminUid);
      expect(res.status).toBe(500);

      // Verify 100% rollback (zero plans modified)
      expect(mockFirestore._db.get('plans/PRO_MONTHLY').price).toBe(199);
      expect(mockFirestore._db.get('plans/PRO_YEARLY').price).toBe(1999);
      expect(mockFirestore._db.get('plans/ENTERPRISE').price).toBe(4999);

      // Verify zero audit logs generated
      const auditKeys = Array.from(mockFirestore._db.keys()).filter(k => k.startsWith('audit_logs/'));
      expect(auditKeys).toHaveLength(0);
    });
  });
});
