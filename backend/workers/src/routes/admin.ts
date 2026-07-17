import { Env, ApiResponse } from '../types';
import { getDocument, setDocument, queryCollection, logAuditEvent } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateSignedLeaseToken } from '../cryptoEngine';

/**
 * Handles GET /api/v1/admin/customers
 * Returns 360° profile view of customers including installations and active subscriptions.
 */
export async function handleAdminSearchCustomers(request: Request, env: Env): Promise<Response> {
  try {
    const url = new URL(request.url);
    const query = url.searchParams.get('query')?.toLowerCase().trim() || '';

    // Fetch all customers or query
    const allCustomers = await queryCollection(env, 'customers', []);
    const filteredCustomers = allCustomers.filter((c: any) => {
      if (!query) return true;
      return (
        (c.customerId && c.customerId.toLowerCase().includes(query)) ||
        (c.businessName && c.businessName.toLowerCase().includes(query)) ||
        (c.mobileNumber && c.mobileNumber.toLowerCase().includes(query)) ||
        (c.ownerName && c.ownerName.toLowerCase().includes(query))
      );
    });

    const detailedCustomers = [];
    for (const customer of filteredCustomers.slice(0, 50)) {
      const installations = await queryCollection(env, 'installations', [
        { field: 'customerId', op: 'EQUAL', value: customer.customerId }
      ]);
      const subscriptions = await queryCollection(env, 'subscriptions', [
        { field: 'customerId', op: 'EQUAL', value: customer.customerId }
      ]);
      const activeSub = subscriptions.find((s: any) => s.status === 'ACTIVE') || subscriptions[0] || null;

      detailedCustomers.push({
        ...customer,
        installationsCount: installations.length,
        installations,
        activeSubscription: activeSub
      });
    }

    const responseWrapper: ApiResponse = {
      success: true,
      data: {
        count: detailedCustomers.length,
        customers: detailedCustomers
      }
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminSearchCustomers:', err);
    return createErrorResponse(500, 'ADMIN_SEARCH_FAILED', `Failed to search customers: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/customers/:customerId
 * Safely updates customer metadata without disrupting underlying subscriptions.
 */
export async function handleAdminUpdateCustomer(request: Request, env: Env, adminUid: string, customerId: string): Promise<Response> {
  try {
    const body = await request.json() as Record<string, any>;
    const customer = await getDocument(env, 'customers', customerId);
    if (!customer) {
      return createErrorResponse(404, 'CUSTOMER_NOT_FOUND', `Customer ${customerId} not found.`);
    }

    const updatedData: Record<string, any> = {
      ...customer,
      updatedAtEpochMs: Date.now()
    };

    if (body.businessName !== undefined) updatedData.businessName = body.businessName;
    if (body.ownerName !== undefined) updatedData.ownerName = body.ownerName;
    if (body.mobileNumber !== undefined) updatedData.mobileNumber = body.mobileNumber;
    if (body.city !== undefined) updatedData.city = body.city;

    await setDocument(env, 'customers', customerId, updatedData);
    await logAuditEvent(env, 'ADMIN_UPDATE_CUSTOMER_METADATA', {
      adminUid,
      customerId,
      changes: body
    });

    const responseWrapper: ApiResponse = {
      success: true,
      data: updatedData
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminUpdateCustomer:', err);
    return createErrorResponse(500, 'ADMIN_UPDATE_FAILED', `Failed to update customer: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/admin/transfers/:transferId/approve
 * The "Lost or Broken Phone Case" override: allows support admins to approve P2P device transfers manually.
 */
export async function handleAdminApproveTransfer(request: Request, env: Env, adminUid: string, transferId: string): Promise<Response> {
  try {
    const transferDoc = await getDocument(env, 'device_transfers', transferId);
    if (!transferDoc) {
      return createErrorResponse(404, 'TRANSFER_NOT_FOUND', `Transfer request ${transferId} not found.`);
    }

    if (transferDoc.status !== 'PENDING') {
      return createErrorResponse(409, 'TRANSFER_NOT_PENDING', `Transfer request is already ${transferDoc.status}.`);
    }

    const { subscriptionId, customerId } = transferDoc;
    const sourceInstallationId = transferDoc.oldInstallationId || transferDoc.sourceInstallationId;
    const targetInstallationId = transferDoc.newInstallationId || transferDoc.targetInstallationId;
    const now = Date.now();

    // 1. Mark transfer as APPROVED by admin
    const updatedTransfer = {
      ...transferDoc,
      status: 'APPROVED',
      approvedBy: `ADMIN_${adminUid}`,
      updatedAtEpochMs: now
    };
    await setDocument(env, 'device_transfers', transferId, updatedTransfer);

    // 2. Revoke old device installation status
    if (sourceInstallationId && sourceInstallationId !== targetInstallationId) {
      const sourceInst = await getDocument(env, 'installations', sourceInstallationId);
      if (sourceInst) {
        await setDocument(env, 'installations', sourceInstallationId, {
          ...sourceInst,
          status: 'REVOKED',
          revokedAtEpochMs: now,
          revokedReason: `Admin approved transfer ${transferId} (Lost/Broken Phone override)`
        });
      }
    }

    // 3. Activate target device installation status
    const targetInst = await getDocument(env, 'installations', targetInstallationId);
    if (targetInst) {
      await setDocument(env, 'installations', targetInstallationId, {
        ...targetInst,
        status: 'ACTIVE',
        updatedAtEpochMs: now
      });
    } else {
      await setDocument(env, 'installations', targetInstallationId, {
        installationId: targetInstallationId,
        customerId,
        hardwareId: targetInstallationId,
        installationUuid: targetInstallationId,
        platform: 'android',
        appVersion: '1.0.0',
        status: 'ACTIVE',
        createdAtEpochMs: now,
        lastSeenAtEpochMs: now
      });
    }

    // 4. Update authoritative subscription activeInstallationId
    const subDoc = await getDocument(env, 'subscriptions', subscriptionId);
    if (!subDoc) {
      return createErrorResponse(404, 'SUBSCRIPTION_NOT_FOUND', `Subscription ${subscriptionId} not found.`);
    }

    const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
    const leasePayload = {
      subscriptionId: subDoc.subscriptionId,
      customerId: subDoc.customerId,
      activeInstallationId: targetInstallationId,
      planId: subDoc.planId || 'PRO_YEARLY',
      planName: subDoc.planName || 'Pro Annual License',
      startsAtEpochMs: subDoc.startsAtEpochMs || now,
      expiresAtEpochMs: subDoc.expiresAtEpochMs || (now + 365 * 86400 * 1000),
      maxCustomers: 10000,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      issuedAt: now
    };
    const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

    const updatedSub = {
      ...subDoc,
      activeInstallationId: targetInstallationId,
      signedLeaseToken,
      updatedAtEpochMs: now
    };
    await setDocument(env, 'subscriptions', subscriptionId, updatedSub);

    // 5. Log audit trail
    await logAuditEvent(env, 'ADMIN_APPROVED_TRANSFER_LOST_DEVICE', {
      adminUid,
      transferId,
      subscriptionId,
      sourceInstallationId,
      targetInstallationId
    });

    const responseWrapper: ApiResponse = {
      success: true,
      data: {
        transferId,
        status: 'APPROVED',
        activeInstallationId: targetInstallationId,
        signedLeaseToken
      }
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminApproveTransfer:', err);
    return createErrorResponse(500, 'ADMIN_TRANSFER_APPROVAL_FAILED', `Failed to approve transfer: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/config/system
 * Toggles global system controls (`allowPayments`, `allowP2PTransfers`, `maintenanceMode`).
 */
export async function handleAdminUpdateSystemConfig(request: Request, env: Env, adminUid: string): Promise<Response> {
  try {
    const body = await request.json() as Record<string, any>;
    const existingConfig = await getDocument(env, 'system_configs', 'global') || {};

    const updatedConfig = {
      ...existingConfig,
      allowPayments: body.allowPayments !== undefined ? body.allowPayments : (existingConfig.allowPayments ?? true),
      allowP2PTransfers: body.allowP2PTransfers !== undefined ? body.allowP2PTransfers : (existingConfig.allowP2PTransfers ?? true),
      maintenanceMode: body.maintenanceMode !== undefined ? body.maintenanceMode : (existingConfig.maintenanceMode ?? false),
      enforceStrictAppVersion: body.enforceStrictAppVersion !== undefined ? body.enforceStrictAppVersion : (existingConfig.enforceStrictAppVersion ?? false),
      updatedAtEpochMs: Date.now(),
      updatedBy: adminUid
    };

    await setDocument(env, 'system_configs', 'global', updatedConfig);
    await logAuditEvent(env, 'ADMIN_UPDATED_SYSTEM_CONFIG', {
      adminUid,
      newConfig: updatedConfig
    });

    const responseWrapper: ApiResponse = {
      success: true,
      data: updatedConfig
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminUpdateSystemConfig:', err);
    return createErrorResponse(500, 'ADMIN_CONFIG_UPDATE_FAILED', `Failed to update config: ${err.message || err}`);
  }
}

/**
 * Handles GET /api/v1/admin/audit-logs
 * Retrieves immutable system audit logs.
 */
export async function handleAdminGetAuditLogs(request: Request, env: Env): Promise<Response> {
  try {
    const logs = await queryCollection(env, 'audit_logs', []);
    logs.sort((a: any, b: any) => (b.createdAtEpochMs || 0) - (a.createdAtEpochMs || 0));

    const responseWrapper: ApiResponse = {
      success: true,
      data: {
        count: logs.length,
        logs: logs.slice(0, 100)
      }
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminGetAuditLogs:', err);
    return createErrorResponse(500, 'ADMIN_LOGS_FAILED', `Failed to fetch audit logs: ${err.message || err}`);
  }
}
