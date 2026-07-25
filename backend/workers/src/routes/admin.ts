import { RequestContext } from '../services/logger';
import { Env, ApiResponse } from '../types';
import { getDocument, setDocument, commitAtomicWrites, deleteDocument, queryCollection, logAuditEvent, getFirestoreAccessToken, buildAuditLogOp, AtomicWriteOp } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateShortId, generateSignedLeaseToken } from '../cryptoEngine';
import { LockService } from '../services/lock';
import { findSubscription, DiscoveryStrategy } from '../services/discovery';
import { SubscriptionFSM } from '../services/fsm/subscriptionFSM';
import { TransferService } from '../services/transferService';
import { InstallationFSM } from '../services/fsm/installationFSM';
import { SubscriptionService } from '../services/subscriptionService';
import { InstallationService } from '../services/installationService';

/**
 * Handles GET /api/v1/admin/customers
 * Returns 360° profile view of customers including installations and active subscriptions.
 */
export async function handleAdminSearchCustomers(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
  try {
    const url = new URL(request.url);
    const query = url.searchParams.get('query')?.toLowerCase().trim() || '';

    // Fetch all customers or query
    const allCustomers = await queryCollection(ctx, env, 'customers', []);
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
      const installations = await queryCollection(ctx, env, 'installations', [
        { field: 'customerId', op: 'EQUAL', value: customer.customerId }
      ]);
      const { sub } = await findSubscription(ctx, env, customer.customerId, DiscoveryStrategy.ADMIN_SEARCH);
      let activeSub = sub;

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
    ctx.logger.error('Error in handleAdminSearchCustomers:', err);
    return createErrorResponse(500, 'ADMIN_SEARCH_FAILED', `Failed to search customers: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/customers/:customerId
 * Safely updates customer metadata without disrupting underlying subscriptions.
 */
export async function handleAdminUpdateCustomer(ctx: RequestContext, request: Request, env: Env, adminUid: string, customerId: string): Promise<Response> {
  try {
    const body = await request.json() as Record<string, any>;
    const customer = await getDocument(ctx, env, 'customers', customerId);
    if (!customer) {
      return createErrorResponse(404, 'CUSTOMER_NOT_FOUND', `Customer ${customerId} not found.`);
    }

    const updatedData: Record<string, any> = {
      ...customer,
      updatedAtEpochMs: Date.now()
    };

    if (typeof body.businessName === 'string') updatedData.businessName = body.businessName.substring(0, 100);
    if (typeof body.ownerName === 'string') updatedData.ownerName = body.ownerName.substring(0, 100);
    if (typeof body.mobileNumber === 'string') updatedData.mobileNumber = body.mobileNumber.substring(0, 20);
    if (typeof body.city === 'string') updatedData.city = body.city.substring(0, 100);
    if (typeof body.status === 'string') updatedData.status = body.status.substring(0, 20);

    const auditOp = buildAuditLogOp('ADMIN_UPDATE_CUSTOMER_METADATA', {
      adminUid,
      customerId,
      changes: body
    });
    await commitAtomicWrites(ctx, env, [
      { collectionPath: 'customers', documentId: customerId, data: updatedData },
      auditOp
    ]);

    const responseWrapper: ApiResponse = {
      success: true,
      data: updatedData
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    ctx.logger.error('Error in handleAdminUpdateCustomer:', err);
    return createErrorResponse(500, 'ADMIN_UPDATE_FAILED', `Failed to update customer: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/admin/transfers/:transferId/approve
 * The "Lost or Broken Phone Case" override: allows support admins to approve P2P device transfers manually.
 */
export async function handleAdminApproveTransfer(ctx: RequestContext, request: Request, env: Env, adminUid: string, transferId: string): Promise<Response> {
  try {
    const result = await TransferService.adminApproveTransfer(ctx, env, transferId, adminUid);
    return new Response(JSON.stringify(result), { status: 200, headers: { 'Content-Type': 'application/json' } });
  } catch (err: any) {
    if (err.code === 'TRANSFER_NOT_FOUND') return createErrorResponse(404, err.code, err.message);
    if (err.code === 'TRANSFER_NOT_PENDING' || err.code === 'TRIAL_ALREADY_USED') return createErrorResponse(403, err.code, err.message);
    if (err.code === 'SUBSCRIPTION_NOT_FOUND') return createErrorResponse(404, err.code, err.message);
    if (err.code === 'ALREADY_EXISTS') return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', 'Subscription is currently locked by another process.');
    ctx.logger.error('Error in handleAdminApproveTransfer:', err);
    return createErrorResponse(500, 'ADMIN_TRANSFER_APPROVAL_FAILED', `Failed to approve transfer: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/admin/transfers/:transferId/reject
 * Rejects a device transfer request manually.
 */
export async function handleAdminRejectTransfer(ctx: RequestContext, request: Request, env: Env, adminUid: string, transferId: string): Promise<Response> {
  try {
    const result = await TransferService.adminRejectTransfer(ctx, env, transferId, adminUid);
    return new Response(JSON.stringify(result), { status: 200, headers: { 'Content-Type': 'application/json' } });
  } catch (err: any) {
    if (err.code === 'TRANSFER_NOT_FOUND') return createErrorResponse(404, err.code, err.message);
    if (err.code === 'TRANSFER_NOT_PENDING') return createErrorResponse(409, err.code, err.message);
    ctx.logger.error('Error in handleAdminRejectTransfer:', err);
    return createErrorResponse(500, 'ADMIN_TRANSFER_REJECTION_FAILED', `Failed to reject transfer: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/devices/:hardwareId/ban
 * Bans a device at the hardware level.
 */
export async function handleAdminBanDevice(ctx: RequestContext, request: Request, env: Env, adminUid: string, hardwareId: string): Promise<Response> {
  try {
    const auditOp = buildAuditLogOp('ADMIN_BANNED_DEVICE', { adminUid, hardwareId });
    await InstallationService.banDevice(ctx, env, hardwareId, adminUid, auditOp);
    
    return new Response(JSON.stringify({ success: true, message: 'Device banned successfully' }), {
      status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    ctx.logger.error('Error in handleAdminBanDevice:', err);
    if (err.code === 'NOT_FOUND') return createErrorResponse(404, 'NOT_FOUND', err.message);
    if (err.code === 'CONCURRENT_MUTATION_LOCKED') return createErrorResponse(409, err.code, err.message);
    return createErrorResponse(500, 'ADMIN_BAN_FAILED', `Failed to ban device: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/devices/:hardwareId/unban
 * Unbans a hardware device.
 */
export async function handleAdminUnbanDevice(ctx: RequestContext, request: Request, env: Env, adminUid: string, hardwareId: string): Promise<Response> {
  try {
    const auditOp = buildAuditLogOp('ADMIN_UNBANNED_DEVICE', { adminUid, hardwareId });
    await InstallationService.unbanDevice(ctx, env, hardwareId, adminUid, auditOp);
    
    return new Response(JSON.stringify({ success: true, message: 'Device unbanned successfully' }), {
      status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    ctx.logger.error('Error in handleAdminUnbanDevice:', err);
    if (err.code === 'NOT_FOUND') return createErrorResponse(404, 'NOT_FOUND', err.message);
    if (err.code === 'CONCURRENT_MUTATION_LOCKED') return createErrorResponse(409, err.code, err.message);
    return createErrorResponse(500, 'ADMIN_UNBAN_FAILED', `Failed to unban device: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/config/system
 * Toggles global system controls (`allowPayments`, `allowP2PTransfers`, `maintenanceMode`).
 */
export async function handleAdminUpdateSystemConfig(ctx: RequestContext, request: Request, env: Env, adminUid: string): Promise<Response> {
  try {
    const body = await request.json() as Record<string, any>;
    const existingConfig = await getDocument(ctx, env, 'system_configs', 'global') || {};

    const updatedConfig = {
      ...existingConfig,
      allowPayments: body.allowPayments !== undefined ? body.allowPayments : (existingConfig.allowPayments ?? true),
      allowP2PTransfers: body.allowP2PTransfers !== undefined ? body.allowP2PTransfers : (existingConfig.allowP2PTransfers ?? true),
      maintenanceMode: body.maintenanceMode !== undefined ? body.maintenanceMode : (existingConfig.maintenanceMode ?? false),
      enforceStrictAppVersion: body.enforceStrictAppVersion !== undefined ? body.enforceStrictAppVersion : (existingConfig.enforceStrictAppVersion ?? false),
      latestVersion: typeof body.latestAppVersion === 'string' ? body.latestAppVersion.substring(0, 50) : existingConfig.latestVersion,
      minimumSupportedVersion: typeof body.minimumAppVersion === 'string' ? body.minimumAppVersion.substring(0, 50) : existingConfig.minimumSupportedVersion,
      apkDownloadUrl: typeof body.apkDownloadUrl === 'string' ? body.apkDownloadUrl.substring(0, 500) : existingConfig.apkDownloadUrl,
      updatedAtEpochMs: Date.now(),
      updatedBy: adminUid
    };

    const auditOp = buildAuditLogOp('ADMIN_UPDATED_SYSTEM_CONFIG', {
      adminUid,
      newConfig: updatedConfig
    });
    await commitAtomicWrites(ctx, env, [
      { collectionPath: 'system_configs', documentId: 'global', data: updatedConfig },
      auditOp
    ]);

    const responseWrapper: ApiResponse = {
      success: true,
      data: updatedConfig
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    ctx.logger.error('Error in handleAdminUpdateSystemConfig:', err);
    return createErrorResponse(500, 'ADMIN_CONFIG_UPDATE_FAILED', `Failed to update config: ${err.message || err}`);
  }
}

/**
 * Handles GET /api/v1/admin/audit-logs
 * Retrieves immutable system audit logs.
 */
export async function handleAdminGetAuditLogs(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
  try {
    const logs = await queryCollection(ctx, env, 'audit_logs', []);
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
    ctx.logger.error('Error in handleAdminGetAuditLogs:', err);
    return createErrorResponse(500, 'ADMIN_LOGS_FAILED', `Failed to fetch audit logs: ${err.message || err}`);
  }
}

/**
 * Handles GET /api/v1/admin/transfers/pending
 * Retrieves all pending transfers globally for support overriding.
 */
export async function handleAdminGetPendingTransfers(ctx: RequestContext, request: Request, env: Env): Promise<Response> {
  try {
    const pendingList = await queryCollection(ctx, env, 'device_transfers', [
      { field: 'status', op: 'EQUAL', value: 'PENDING' }
    ]);
    
    // Sort by requestedAtEpochMs descending
    pendingList.sort((a: any, b: any) => (b.requestedAtEpochMs || 0) - (a.requestedAtEpochMs || 0));

    const responseWrapper: ApiResponse = {
      success: true,
      data: { transfers: pendingList }
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    ctx.logger.error('Error in handleAdminGetPendingTransfers:', err);
    return createErrorResponse(500, 'ADMIN_POLL_FAILED', `Failed to query pending transfers: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/admin/plans
 * Updates the prices of the plans.
 */
export async function handleAdminUpdatePlans(ctx: RequestContext, request: Request, env: Env, adminUid: string): Promise<Response> {
  try {
    const body = await request.json() as { plans: any[] };
    if (!body.plans || !Array.isArray(body.plans)) {
      return createErrorResponse(400, 'INVALID_PAYLOAD', 'Payload must contain a plans array.');
    }

    const batchWrites: AtomicWriteOp[] = [];
    for (const plan of body.plans) {
      if (!plan.planId) continue;
      
      const existingPlan = await getDocument(ctx, env, 'plans', plan.planId);
      const updatedPlan = {
        ...(existingPlan || {}),
        ...plan,
        isActive: true,
        updatedAtEpochMs: Date.now()
      };
      
      batchWrites.push({ collectionPath: 'plans', documentId: plan.planId, data: updatedPlan });
    }

    if (batchWrites.length > 0) {
      batchWrites.push(buildAuditLogOp('ADMIN_UPDATE_PLANS', {
        adminUid,
        action: 'Updated subscription plan prices'
      }));
      await commitAtomicWrites(ctx, env, batchWrites);
    }

    return new Response(JSON.stringify({ success: true, message: 'Plans updated successfully' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    ctx.logger.error('Error in handleAdminUpdatePlans:', err);
    return createErrorResponse(500, 'ADMIN_UPDATE_PLANS_FAILED', `Failed to update plans: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/customers/:customerId/subscription
 * Manages the subscription (Extend, Change Plan, Transfer, Remove).
 */
export async function handleAdminManageSubscription(ctx: RequestContext, request: Request, env: Env, adminUid: string, customerId: string): Promise<Response> {
  try {
    const body = await request.json() as { action: string; daysToAdd?: number; newPlanId?: string; newHardwareId?: string };
    const action = typeof body.action === 'string' ? body.action.substring(0, 20).toUpperCase() : '';
    
    if (action === 'EXTEND') {
      try {
        const auditOp = buildAuditLogOp('ADMIN_MANAGE_SUBSCRIPTION', { adminUid, customerId, action, details: body });
        const result = await SubscriptionService.extendSubscription(ctx, env, customerId, body.daysToAdd as number, auditOp);
        return new Response(JSON.stringify(result), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
      } catch (err: any) {
        if (err.code === 'MISSING_DAYS') return createErrorResponse(400, 'MISSING_DAYS', err.message);
        if (err.code === 'CONCURRENT_MUTATION_LOCKED') return createErrorResponse(409, err.code, err.message);
        throw err;
      }
    } 
    else if (action === 'CHANGE_PLAN') {
      try {
        const auditOp = buildAuditLogOp('ADMIN_MANAGE_SUBSCRIPTION', { adminUid, customerId, action, details: body });
        const result = await SubscriptionService.changePlan(ctx, env, customerId, body.newPlanId as string, auditOp);
        return new Response(JSON.stringify(result), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
      } catch (err: any) {
        if (err.code === 'MISSING_PLAN_ID') return createErrorResponse(400, 'MISSING_PLAN_ID', err.message);
        if (err.code === 'CONCURRENT_MUTATION_LOCKED') return createErrorResponse(409, err.code, err.message);
        throw err;
      }
    }
    else if (action === 'REMOVE') {
      try {
        const { sub, isTrial, trialId, subscriptionId } = await findSubscription(ctx, env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
        if (!sub) return createErrorResponse(404, 'SUBSCRIPTION_NOT_FOUND', 'No active subscription found.');

        const now = Date.now();
        const auditOp = buildAuditLogOp('ADMIN_MANAGE_SUBSCRIPTION', { adminUid, customerId, action, details: body });

        const doRemove = async () => {
          // Re-fetch inside lock
          const { sub: activeSub, isTrial: actIsTrial, trialId: actTrialId, subscriptionId: foundId } = await findSubscription(ctx, env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
          if (!activeSub) throw Object.assign(new Error('No active subscription found.'), { code: 'SUBSCRIPTION_NOT_FOUND' });

          const cancelOp = SubscriptionService.buildCancellation(activeSub, actIsTrial, actTrialId || null, now);
          const batchWrites: AtomicWriteOp[] = [...cancelOp.writes];
          
          if (cancelOp.result.hardwareIdToRevoke) {
             const oldInst = await getDocument(ctx, env, 'installations', cancelOp.result.hardwareIdToRevoke);
             const revOp = InstallationService.buildRevocation(oldInst, cancelOp.result.hardwareIdToRevoke, 'Subscription removed by Admin', now);
             batchWrites.push(...revOp.writes);
          }
          batchWrites.push(auditOp);
          await commitAtomicWrites(ctx, env, batchWrites);
          return { success: true, message: 'Subscription removed successfully' };
        };

        if (subscriptionId) {
          try {
            const result = await LockService.withLock(ctx, env, 'sub_lock', subscriptionId, 30000, { customerId, subscriptionId }, doRemove);
            return new Response(JSON.stringify(result), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
          } catch (err: any) {
            if (err.code === 'ALREADY_EXISTS') return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', 'Subscription is currently locked');
            throw err;
          }
        } else {
           const result = await doRemove();
           return new Response(JSON.stringify(result), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
        }
      } catch (err: any) {
        if (err.code === 'SUBSCRIPTION_NOT_FOUND') return createErrorResponse(404, err.code, err.message);
        if (err.code === 'CONCURRENT_MUTATION_LOCKED') return createErrorResponse(409, err.code, err.message);
        throw err;
      }
    }
    else if (action === 'TRANSFER') {
      if (!body.newHardwareId) return createErrorResponse(400, 'MISSING_HARDWARE_ID', 'newHardwareId is required for transfer.');
      try {
        const result = await TransferService.adminForceTransfer(ctx, env, customerId, body.newHardwareId as string, adminUid, body);
        return new Response(JSON.stringify(result), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
      } catch (err: any) {
        if (err.code === 'TRIAL_ALREADY_USED') return createErrorResponse(403, err.code, err.message);
        if (err.code === 'ALREADY_EXISTS') return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', 'Subscription or trial is currently locked by another process.');
        throw err;
      }
    } else {
      return createErrorResponse(400, 'INVALID_ACTION', 'Action must be one of: EXTEND, CHANGE_PLAN, TRANSFER, REMOVE');
    }
  } catch (err: any) {
    ctx.logger.error('Error in handleAdminManageSubscription:', err);
    return createErrorResponse(500, 'ADMIN_MANAGE_SUB_FAILED', `Failed to manage subscription: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/admin/upload-apk-chunk
 * Uploads an APK chunk directly into Cloudflare KV.
 */
export async function handleAdminUploadApkChunk(ctx: RequestContext, request: Request, env: Env, adminUid: string): Promise<Response> {
  try {
    const formData = await request.formData();
    const chunk = formData.get('chunk') as unknown as File;
    const version = formData.get('version') as string;
    const chunkIndexStr = formData.get('chunkIndex') as string;
    const totalChunksStr = formData.get('totalChunks') as string;
    const totalSizeStr = formData.get('totalSize') as string;

    if (!chunk || !version || !chunkIndexStr || !totalChunksStr) {
      return createErrorResponse(400, 'BAD_REQUEST', 'Missing chunk, version, chunkIndex, or totalChunks in form data.');
    }

    const chunkIndex = parseInt(chunkIndexStr, 10);
    const totalChunks = parseInt(totalChunksStr, 10);
    const totalSize = parseInt(totalSizeStr, 10);

    const chunkBuffer = await chunk.arrayBuffer();

    // Store the chunk directly into KV
    const chunkKey = `apk-${version}-chunk-${chunkIndex}`;
    await env.APK_STORE.put(chunkKey, chunkBuffer);

    let downloadUrl = null;

    // If this is the last chunk, write the metadata
    if (chunkIndex === totalChunks - 1) {
      const metaKey = `apk-${version}-meta`;
      const metadata = {
        version,
        totalChunks,
        totalSize,
        fileName: `vendorsoft-v${version}.apk`,
        contentType: 'application/vnd.android.package-archive',
        uploadedAt: Date.now()
      };
      
      await env.APK_STORE.put(metaKey, JSON.stringify(metadata));

      await logAuditEvent(ctx, env, 'ADMIN_UPLOAD_APK_KV', {
        adminUid,
        version,
        totalSize,
        totalChunks
      });
      
      // Construct the final public download URL
      const host = new URL(request.url).origin;
      downloadUrl = `${host}/v1/public/apks/${version}.apk`;
    }

    return new Response(JSON.stringify({ 
      success: true, 
      message: `Chunk ${chunkIndex + 1}/${totalChunks} uploaded successfully.`,
      downloadUrl
    }), {
      status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });

  } catch (err: any) {
    ctx.logger.error('Error in handleAdminUploadApkChunk:', err);
    return createErrorResponse(500, 'UPLOAD_FAILED', `Failed to upload APK chunk: ${err.message || err}`);
  }
}
