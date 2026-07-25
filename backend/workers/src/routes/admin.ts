import { Env, ApiResponse } from '../types';
import { getDocument, setDocument, commitAtomicWrites, deleteDocument, queryCollection, logAuditEvent, getFirestoreAccessToken } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateSignedLeaseToken } from '../cryptoEngine';
import { LockService } from '../services/lock';
import { findSubscription, DiscoveryStrategy } from '../services/discovery';

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
      const { sub } = await findSubscription(env, customer.customerId, DiscoveryStrategy.ADMIN_SEARCH);
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

    if (typeof body.businessName === 'string') updatedData.businessName = body.businessName.substring(0, 100);
    if (typeof body.ownerName === 'string') updatedData.ownerName = body.ownerName.substring(0, 100);
    if (typeof body.mobileNumber === 'string') updatedData.mobileNumber = body.mobileNumber.substring(0, 20);
    if (typeof body.city === 'string') updatedData.city = body.city.substring(0, 100);
    if (typeof body.status === 'string') updatedData.status = body.status.substring(0, 20);

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
    try {
      return await LockService.withLock(
        env,
        'sub_lock',
        subscriptionId,
        30000,
        { customerId, subscriptionId, transferId },
        async () => {
          // 2. Fetch Authoritative Subscription or Trial BEFORE applying partial updates
          let subDoc: any = null;
          let isTrial = false;
          if (subscriptionId && subscriptionId.startsWith('TRIAL_')) {
            isTrial = true;
            const hardwareId = subscriptionId.replace('TRIAL_', '');
            const trial = await getDocument(env, 'hardware_trials', hardwareId);
            if (trial) {
              subDoc = {
                subscriptionId,
                customerId: trial.customerId,
                activeInstallationId: trial.hardwareId,
                planId: 'FREE_TRIAL_30',
                startsAtEpochMs: trial.startedAtEpochMs,
                expiresAtEpochMs: trial.expiresAtEpochMs
              };
            }
          } else {
            subDoc = await getDocument(env, 'subscriptions', subscriptionId);
          }

          if (!subDoc) {
            return createErrorResponse(404, 'SUBSCRIPTION_NOT_FOUND', 'The subscription or trial associated with this transfer no longer exists.');
          }

          // 2. Prepare Atomic Batch
          const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any> }> = [];

          // Mark transfer as APPROVED by admin
          const updatedTransfer = {
            ...transferDoc,
            status: 'APPROVED',
            approvedBy: `ADMIN_${adminUid}`,
            updatedAtEpochMs: now
          };
          batchWrites.push({ collectionPath: 'device_transfers', documentId: transferId, data: updatedTransfer });

          // 3. Revoke old device installation status
          if (sourceInstallationId && sourceInstallationId !== targetInstallationId) {
            const sourceInst = await getDocument(env, 'installations', sourceInstallationId);
            if (sourceInst) {
              batchWrites.push({
                collectionPath: 'installations',
                documentId: sourceInstallationId,
                data: {
                  ...sourceInst,
                  status: 'REVOKED',
                  revokedAtEpochMs: now,
                  revokedReason: `Admin approved transfer ${transferId} (Lost/Broken Phone override)`
                }
              });
            }
          }

          // 4. Activate target device installation status
          const targetInst = await getDocument(env, 'installations', targetInstallationId);
          if (targetInst) {
            batchWrites.push({
              collectionPath: 'installations',
              documentId: targetInstallationId,
              data: {
                ...targetInst,
                status: 'ACTIVE',
                updatedAtEpochMs: now
              }
            });
          } else {
            batchWrites.push({
              collectionPath: 'installations',
              documentId: targetInstallationId,
              data: {
                installationId: targetInstallationId,
                customerId,
                hardwareId: targetInstallationId,
                installationUuid: targetInstallationId,
                platform: 'android',
                deviceModel: transferDoc.deviceModel || 'Unknown Device',
                appVersion: '1.0.0',
                status: 'ACTIVE',
                createdAtEpochMs: now,
                lastSeenAtEpochMs: now
              }
            });
          }

          // 5. Update authoritative subscription activeInstallationId and GENERATE TOKEN FIRST
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

          if (isTrial) {
            const hardwareId = subscriptionId.replace('TRIAL_', '');
            const trial = await getDocument(env, 'hardware_trials', hardwareId);
            if (trial) {
              // Pillar 5: Check if target device already used a trial
              const targetTrial = await getDocument(env, 'hardware_trials', targetInstallationId);
              if (targetTrial) {
                return createErrorResponse(403, 'TRIAL_ALREADY_USED', 'Target device has already used a trial. Admin cannot force transfer a trial to a device that has already used one.');
              }

              // Write new device
              batchWrites.push({
                collectionPath: 'hardware_trials',
                documentId: targetInstallationId,
                data: {
                  ...trial,
                  hardwareId: targetInstallationId
                }
              });
              // Pillar 5: Preserve old device history (mark as expired, DO NOT DELETE)
              batchWrites.push({
                collectionPath: 'hardware_trials',
                documentId: hardwareId,
                data: {
                  ...trial,
                  expiresAtEpochMs: 0
                }
              });
            }
          } else {
            batchWrites.push({
              collectionPath: 'subscriptions',
              documentId: subDoc.subscriptionId,
              data: {
                ...subDoc,
                activeInstallationId: targetInstallationId,
                signedLeaseToken, // Admin issues a new token forcefully
                updatedAtEpochMs: now
              }
            });
          }

          // Single Atomic Commit
          await commitAtomicWrites(env, batchWrites);

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
              message: 'Transfer manually approved and old device revoked.',
              newLeaseToken: signedLeaseToken
            }
          };

          return new Response(JSON.stringify(responseWrapper), { status: 200, headers: { 'Content-Type': 'application/json' } });
        }
      );
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', 'Subscription is currently locked by another process.');
      }
      throw err;
    }
  } catch (err: any) {
    console.error('Error in handleAdminApproveTransfer:', err);
    return createErrorResponse(500, 'ADMIN_TRANSFER_APPROVAL_FAILED', `Failed to approve transfer: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/admin/transfers/:transferId/reject
 * Rejects a device transfer request manually.
 */
export async function handleAdminRejectTransfer(request: Request, env: Env, adminUid: string, transferId: string): Promise<Response> {
  try {
    const transferDoc = await getDocument(env, 'device_transfers', transferId);
    if (!transferDoc) {
      return createErrorResponse(404, 'TRANSFER_NOT_FOUND', `Transfer request ${transferId} not found.`);
    }

    if (transferDoc.status !== 'PENDING') {
      return createErrorResponse(409, 'TRANSFER_NOT_PENDING', `Transfer request is already ${transferDoc.status}.`);
    }

    const now = Date.now();
    const updatedTransfer = {
      ...transferDoc,
      status: 'REJECTED',
      rejectedBy: `ADMIN_${adminUid}`,
      updatedAtEpochMs: now
    };
    await setDocument(env, 'device_transfers', transferId, updatedTransfer);

    await logAuditEvent(env, 'ADMIN_REJECTED_TRANSFER', {
      adminUid,
      transferId
    });

    const responseWrapper: ApiResponse = {
      success: true,
      data: {
        transferId,
        status: 'REJECTED'
      }
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminRejectTransfer:', err);
    return createErrorResponse(500, 'ADMIN_TRANSFER_REJECTION_FAILED', `Failed to reject transfer: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/devices/:hardwareId/ban
 * Bans a device at the hardware level.
 */
export async function handleAdminBanDevice(request: Request, env: Env, adminUid: string, hardwareId: string): Promise<Response> {
  try {
    const instDoc = await getDocument(env, 'installations', hardwareId) || {};
    
    const updatedInst = {
      ...instDoc,
      status: 'BANNED',
      bannedAtEpochMs: Date.now(),
      bannedBy: adminUid
    };
    
    await setDocument(env, 'installations', hardwareId, updatedInst);
    
    await logAuditEvent(env, 'ADMIN_BANNED_DEVICE', { adminUid, hardwareId });

    return new Response(JSON.stringify({ success: true, message: 'Device banned successfully' }), {
      status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminBanDevice:', err);
    return createErrorResponse(500, 'ADMIN_BAN_FAILED', `Failed to ban device: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/devices/:hardwareId/unban
 * Unbans a hardware device.
 */
export async function handleAdminUnbanDevice(request: Request, env: Env, adminUid: string, hardwareId: string): Promise<Response> {
  try {
    const instDoc = await getDocument(env, 'installations', hardwareId) || {};
    
    const updatedInst = {
      ...instDoc,
      status: 'ACTIVE',
      unbannedAtEpochMs: Date.now(),
      unbannedBy: adminUid
    };
    
    await setDocument(env, 'installations', hardwareId, updatedInst);
    
    await logAuditEvent(env, 'ADMIN_UNBANNED_DEVICE', { adminUid, hardwareId });

    return new Response(JSON.stringify({ success: true, message: 'Device unbanned successfully' }), {
      status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminUnbanDevice:', err);
    return createErrorResponse(500, 'ADMIN_UNBAN_FAILED', `Failed to unban device: ${err.message || err}`);
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
      latestVersion: typeof body.latestAppVersion === 'string' ? body.latestAppVersion.substring(0, 50) : existingConfig.latestVersion,
      minimumSupportedVersion: typeof body.minimumAppVersion === 'string' ? body.minimumAppVersion.substring(0, 50) : existingConfig.minimumSupportedVersion,
      apkDownloadUrl: typeof body.apkDownloadUrl === 'string' ? body.apkDownloadUrl.substring(0, 500) : existingConfig.apkDownloadUrl,
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

/**
 * Handles GET /api/v1/admin/transfers/pending
 * Retrieves all pending transfers globally for support overriding.
 */
export async function handleAdminGetPendingTransfers(request: Request, env: Env): Promise<Response> {
  try {
    const pendingList = await queryCollection(env, 'device_transfers', [
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
    console.error('Error in handleAdminGetPendingTransfers:', err);
    return createErrorResponse(500, 'ADMIN_POLL_FAILED', `Failed to query pending transfers: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/admin/plans
 * Updates the prices of the plans.
 */
export async function handleAdminUpdatePlans(request: Request, env: Env, adminUid: string): Promise<Response> {
  try {
    const body = await request.json() as { plans: any[] };
    if (!body.plans || !Array.isArray(body.plans)) {
      return createErrorResponse(400, 'INVALID_PAYLOAD', 'Payload must contain a plans array.');
    }

    for (const plan of body.plans) {
      if (!plan.planId) continue;
      
      const existingPlan = await getDocument(env, 'plans', plan.planId);
      const updatedPlan = {
        ...(existingPlan || {}),
        ...plan,
        isActive: true,
        updatedAtEpochMs: Date.now()
      };
      
      await setDocument(env, 'plans', plan.planId, updatedPlan);
    }

    await logAuditEvent(env, 'ADMIN_UPDATE_PLANS', {
      adminUid,
      action: 'Updated subscription plan prices'
    });

    return new Response(JSON.stringify({ success: true, message: 'Plans updated successfully' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    console.error('Error in handleAdminUpdatePlans:', err);
    return createErrorResponse(500, 'ADMIN_UPDATE_PLANS_FAILED', `Failed to update plans: ${err.message || err}`);
  }
}

/**
 * Handles PUT /api/v1/admin/customers/:customerId/subscription
 * Manages the subscription (Extend, Change Plan, Transfer, Remove).
 */
export async function handleAdminManageSubscription(request: Request, env: Env, adminUid: string, customerId: string): Promise<Response> {
  try {
    const body = await request.json() as { action: string; daysToAdd?: number; newPlanId?: string; newHardwareId?: string };
    
    // Find active subscription or trial
    // Find active subscription or trial
    let { sub: activeSub, isTrial, trialId, subscriptionId } = await findSubscription(env, customerId, DiscoveryStrategy.ADMIN_MANAGE);
    
    const now = Date.now();
    const action = typeof body.action === 'string' ? body.action.substring(0, 20).toUpperCase() : '';
    
    const doWork = async () => {
      if (subscriptionId) {
        // Re-fetch now that we hold the lock (Authoritative Read)
        if (isTrial) {
          const trial = await getDocument(env, 'hardware_trials', trialId as string);
          if (trial) activeSub = trial;
        } else {
          const sub = await getDocument(env, 'subscriptions', subscriptionId);
          if (sub) activeSub = sub;
        }
      }

      if (action === 'EXTEND') {
        if (typeof body.daysToAdd !== 'number') return createErrorResponse(400, 'MISSING_DAYS', 'daysToAdd must be a number.');
        const newExpiresAt = (activeSub?.expiresAtEpochMs || now) + (body.daysToAdd * 86400 * 1000);
        
        if (!activeSub) {
           // Create a new subscription if none exists
           let hwId = null;
           const installs = await queryCollection(env, 'installations', [
              { field: 'customerId', op: 'EQUAL', value: customerId }
           ]);
           if (installs.length > 0) {
              installs.sort((a: any, b: any) => (b.lastSeenAtEpochMs || 0) - (a.lastSeenAtEpochMs || 0));
              hwId = installs[0].hardwareId || installs[0].installationId;
           }
           
           const newSubId = `SUB_${crypto.randomUUID()}`;
           activeSub = {
             subscriptionId: newSubId,
             customerId,
             activeInstallationId: hwId,
             planId: 'FREE_TRIAL_30',
             status: 'ACTIVE',
             startsAtEpochMs: now,
             expiresAtEpochMs: newExpiresAt,
             createdAtEpochMs: now,
             updatedAtEpochMs: now
           };
           await setDocument(env, 'subscriptions', newSubId, activeSub);
        } else {
          activeSub.expiresAtEpochMs = newExpiresAt;
          activeSub.status = 'ACTIVE';
          activeSub.updatedAtEpochMs = now;
          
          if (isTrial) {
            await setDocument(env, 'hardware_trials', trialId as string, activeSub);
          } else {
            await setDocument(env, 'subscriptions', activeSub.subscriptionId, activeSub);
          }
        }

      } else if (action === 'CHANGE_PLAN') {
        if (!body.newPlanId) return createErrorResponse(400, 'MISSING_PLAN_ID', 'newPlanId is required.');
        
        const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any> }> = [];
        
        if (isTrial || !activeSub) {
          let hwId = activeSub?.hardwareId || activeSub?.activeInstallationId;
          if (!hwId) {
            const installs = await queryCollection(env, 'installations', [
               { field: 'customerId', op: 'EQUAL', value: customerId }
            ]);
            if (installs.length > 0) {
               installs.sort((a: any, b: any) => (b.lastSeenAtEpochMs || 0) - (a.lastSeenAtEpochMs || 0));
               hwId = installs[0].hardwareId || installs[0].installationId;
            }
          }
          
          let planDays = 30;
          if (body.newPlanId.includes('YEAR')) planDays = 365;
          
          let baseDate = new Date();
          baseDate.setDate(baseDate.getDate() + planDays);
          
          const newSubId = `SUB_${crypto.randomUUID()}`;
          const newSub = {
            subscriptionId: newSubId,
            customerId,
            activeInstallationId: hwId,
            planId: body.newPlanId,
            status: 'ACTIVE',
            startsAtEpochMs: now,
            expiresAtEpochMs: baseDate.getTime(),
            createdAtEpochMs: now,
            updatedAtEpochMs: now
          };
          batchWrites.push({ collectionPath: 'subscriptions', documentId: newSubId, data: newSub });
          
          if (isTrial && trialId) {
            const oldTrial = await getDocument(env, 'hardware_trials', trialId);
            if (oldTrial) {
               batchWrites.push({
                 collectionPath: 'hardware_trials', 
                 documentId: trialId, 
                 data: { ...oldTrial, expiresAtEpochMs: 0 }
               });
            }
          }
        } else {
          activeSub.planId = body.newPlanId;
          activeSub.updatedAtEpochMs = now;
          batchWrites.push({ collectionPath: 'subscriptions', documentId: activeSub.subscriptionId, data: activeSub });
        }
        
        await commitAtomicWrites(env, batchWrites);

      } else if (action === 'TRANSFER') {
        if (!body.newHardwareId) return createErrorResponse(400, 'MISSING_HARDWARE_ID', 'newHardwareId is required for transfer.');
        
        const hardwareId = isTrial ? activeSub.hardwareId : activeSub.activeInstallationId;
        const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any> }> = [];
        
        if (isTrial) {
          const targetTrial = await getDocument(env, 'hardware_trials', body.newHardwareId);
          if (targetTrial) {
             return createErrorResponse(403, 'TRIAL_ALREADY_USED', 'Target device has already used a trial.');
          }

          batchWrites.push({
            collectionPath: 'hardware_trials',
            documentId: body.newHardwareId,
            data: { ...activeSub, hardwareId: body.newHardwareId }
          });
          batchWrites.push({
            collectionPath: 'hardware_trials',
            documentId: hardwareId,
            data: { ...activeSub, expiresAtEpochMs: 0 }
          });
        } else {
          activeSub.activeInstallationId = body.newHardwareId;
          activeSub.updatedAtEpochMs = now;
          batchWrites.push({
            collectionPath: 'subscriptions',
            documentId: activeSub.subscriptionId,
            data: activeSub
          });
        }
        
        if (hardwareId && hardwareId !== body.newHardwareId) {
          const sourceInst = await getDocument(env, 'installations', hardwareId);
          if (sourceInst) {
            batchWrites.push({
              collectionPath: 'installations',
              documentId: hardwareId,
              data: {
                ...sourceInst,
                status: 'REVOKED',
                revokedAtEpochMs: now,
                revokedReason: `Admin transfer override to ${body.newHardwareId}`
              }
            });
          }
        }
        
        await commitAtomicWrites(env, batchWrites);

      } else if (action === 'REMOVE') {
        const hardwareId = isTrial ? activeSub.hardwareId : activeSub.activeInstallationId;
        if (isTrial) {
          activeSub.status = 'CANCELLED';
          await setDocument(env, 'hardware_trials', trialId as string, activeSub);
        } else {
          activeSub.status = 'CANCELLED';
          activeSub.updatedAtEpochMs = now;
          await setDocument(env, 'subscriptions', activeSub.subscriptionId, activeSub);
        }
        
        if (hardwareId) {
          const sourceInst = await getDocument(env, 'installations', hardwareId);
          if (sourceInst) {
            await setDocument(env, 'installations', hardwareId, {
              ...sourceInst,
              status: 'REVOKED',
              revokedAtEpochMs: now,
              revokedReason: 'Subscription removed by Admin'
            });
          }
        }
      } else {
        return createErrorResponse(400, 'INVALID_ACTION', 'Action must be one of: EXTEND, CHANGE_PLAN, TRANSFER, REMOVE');
      }

      await logAuditEvent(env, 'ADMIN_MANAGE_SUBSCRIPTION', {
        adminUid,
        customerId,
        action,
        details: body
      });

      return new Response(JSON.stringify({ success: true, message: `Subscription successfully processed for action: ${action}` }), {
        status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
      });
    };

    if (subscriptionId) {
      try {
        return await LockService.withLock(
          env,
          'sub_lock',
          subscriptionId,
          30000,
          { customerId, subscriptionId },
          doWork
        );
      } catch (err: any) {
        if (err.code === 'ALREADY_EXISTS') {
          return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', 'Subscription is currently locked by another process.');
        }
        throw err;
      }
    } else {
      return await doWork();
    }
  } catch (err: any) {
    console.error('Error in handleAdminManageSubscription:', err);
    return createErrorResponse(500, 'ADMIN_MANAGE_SUB_FAILED', `Failed to manage subscription: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/admin/upload-apk-chunk
 * Uploads an APK chunk directly into Cloudflare KV.
 */
export async function handleAdminUploadApkChunk(request: Request, env: Env, adminUid: string): Promise<Response> {
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

      await logAuditEvent(env, 'ADMIN_UPLOAD_APK_KV', {
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
    console.error('Error in handleAdminUploadApkChunk:', err);
    return createErrorResponse(500, 'UPLOAD_FAILED', `Failed to upload APK chunk: ${err.message || err}`);
  }
}
