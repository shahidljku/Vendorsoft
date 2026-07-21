import { Env, ApiResponse } from '../types';
import { getDocument, setDocument, deleteDocument, queryCollection, logAuditEvent, getFirestoreAccessToken } from '../services/firestore';
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
      let activeSub = subscriptions.find((s: any) => s.status === 'ACTIVE') || subscriptions[0] || null;
      
      if (!activeSub) {
        const trials = await queryCollection(env, 'hardware_trials', [
          { field: 'customerId', op: 'EQUAL', value: customer.customerId }
        ]);
        if (trials.length > 0) {
          trials.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
          const trial = trials[0];
          activeSub = {
            subscriptionId: `TRIAL_${trial.hardwareId}`,
            planId: 'FREE_TRIAL_30',
            status: trial.status === 'CANCELLED' ? 'CANCELLED' : (Date.now() > trial.expiresAtEpochMs ? 'EXPIRED' : 'ACTIVE'),
            expiresAtEpochMs: trial.expiresAtEpochMs
          };
        }
      }

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
    if (body.status !== undefined) updatedData.status = body.status;

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

    // 1. Fetch Authoritative Subscription or Trial BEFORE applying partial updates
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
      return createErrorResponse(404, 'SUBSCRIPTION_NOT_FOUND', `Subscription ${subscriptionId} not found.`);
    }

    // 2. Mark transfer as APPROVED by admin
    const updatedTransfer = {
      ...transferDoc,
      status: 'APPROVED',
      approvedBy: `ADMIN_${adminUid}`,
      updatedAtEpochMs: now
    };
    await setDocument(env, 'device_transfers', transferId, updatedTransfer);

    // 3. Revoke old device installation status
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

    // 4. Activate target device installation status
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
        deviceModel: transferDoc.deviceModel || 'Unknown Device',
        appVersion: '1.0.0',
        status: 'ACTIVE',
        createdAtEpochMs: now,
        lastSeenAtEpochMs: now
      });
    }

    // 5. Update authoritative subscription activeInstallationId
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
      // Trials do not have a document in `subscriptions`. They are in `hardware_trials`.
      // We update the trial active installation? Hardware trials are bound to hardware.
      // A transfer actually moves the trial to a new device.
      // To properly transfer a trial, we would create a new trial document or convert it.
      // But typically, transferring a trial isn't fully supported, or we just issue the token.
      // We should update the trial's hardwareId to the new one.
      const hardwareId = subscriptionId.replace('TRIAL_', '');
      const trial = await getDocument(env, 'hardware_trials', hardwareId);
      if (trial) {
        await setDocument(env, 'hardware_trials', targetInstallationId, {
          ...trial,
          hardwareId: targetInstallationId
        });
        // We MUST delete the old trial so it doesn't conflict during account recovery
        await deleteDocument(env, 'hardware_trials', hardwareId);
      }
    } else {
      const updatedSub = {
        ...subDoc,
        activeInstallationId: targetInstallationId,
        signedLeaseToken,
        updatedAtEpochMs: now
      };
      await setDocument(env, 'subscriptions', subscriptionId, updatedSub);
    }

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
      latestVersion: body.latestAppVersion !== undefined ? body.latestAppVersion : existingConfig.latestVersion,
      minimumSupportedVersion: body.minimumAppVersion !== undefined ? body.minimumAppVersion : existingConfig.minimumSupportedVersion,
      apkDownloadUrl: body.apkDownloadUrl !== undefined ? body.apkDownloadUrl : existingConfig.apkDownloadUrl,
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
    const subscriptions = await queryCollection(env, 'subscriptions', [
      { field: 'customerId', op: 'EQUAL', value: customerId }
    ]);
    let activeSub = subscriptions.find((s: any) => s.status === 'ACTIVE') || subscriptions[0] || null;
    let isTrial = false;
    let trialId = '';
    
    if (!activeSub) {
      // Check for hardware trial
      const existingTrials = await queryCollection(env, 'hardware_trials', [
        { field: 'customerId', op: 'EQUAL', value: customerId }
      ]);
      if (existingTrials.length > 0) {
        activeSub = existingTrials[0];
        isTrial = true;
        trialId = activeSub.hardwareId || activeSub.installationId;
      }
    }

    const now = Date.now();
    const action = body.action?.toUpperCase();

    if (!activeSub && action !== 'CHANGE_PLAN' && action !== 'EXTEND') {
      return createErrorResponse(404, 'SUBSCRIPTION_NOT_FOUND', `No active subscription or trial found for customer ${customerId}.`);
    }

    if (action === 'EXTEND') {
      const days = body.daysToAdd || 0;
      if (days <= 0) return createErrorResponse(400, 'INVALID_DAYS', 'daysToAdd must be greater than 0.');
      
      let baseDate = new Date();
      if (activeSub && activeSub.status !== 'CANCELLED' && activeSub.expiresAtEpochMs && activeSub.expiresAtEpochMs > now) {
        baseDate = new Date(activeSub.expiresAtEpochMs);
      }
      
      if (days === 30 || days === 31) {
        baseDate.setMonth(baseDate.getMonth() + 1);
      } else if (days === 365 || days === 366) {
        baseDate.setFullYear(baseDate.getFullYear() + 1);
      } else {
        baseDate.setDate(baseDate.getDate() + days);
      }
      const newExpiresAt = baseDate.getTime();
      
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
          planId: 'FREE_TRIAL_30', // default fallback plan
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
          await setDocument(env, 'hardware_trials', trialId, activeSub);
        } else {
          await setDocument(env, 'subscriptions', activeSub.subscriptionId, activeSub);
        }
      }

    } else if (action === 'CHANGE_PLAN') {
      if (!body.newPlanId) return createErrorResponse(400, 'MISSING_PLAN_ID', 'newPlanId is required.');
      
      if (isTrial || !activeSub) {
        // Upgrade from trial (or nothing) to PRO
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
        
        let planDays = 30; // default
        if (body.newPlanId.includes('YEAR')) planDays = 365;
        if (body.newPlanId === 'FREE_TRIAL_30') planDays = 30;
        
        let baseDate = new Date();
        if (planDays === 30) {
          baseDate.setMonth(baseDate.getMonth() + 1);
        } else if (planDays === 365) {
          baseDate.setFullYear(baseDate.getFullYear() + 1);
        } else {
          baseDate.setDate(baseDate.getDate() + planDays);
        }
        
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
        await setDocument(env, 'subscriptions', newSubId, newSub);
        if (isTrial && trialId) {
          await deleteDocument(env, 'hardware_trials', trialId);
        }
        activeSub = newSub;
        isTrial = false;
      } else {
        // Determine days based on plan
        let planDays = 30; // default
        if (body.newPlanId.includes('YEAR')) planDays = 365;
        if (body.newPlanId === 'FREE_TRIAL_30') planDays = 30;
        
        let baseDate = new Date();
        if (activeSub.status !== 'CANCELLED' && activeSub.expiresAtEpochMs && activeSub.expiresAtEpochMs > now) {
          baseDate = new Date(activeSub.expiresAtEpochMs);
        }
        if (planDays === 30) {
          baseDate.setMonth(baseDate.getMonth() + 1);
        } else if (planDays === 365) {
          baseDate.setFullYear(baseDate.getFullYear() + 1);
        } else {
          baseDate.setDate(baseDate.getDate() + planDays);
        }
        
        activeSub.planId = body.newPlanId;
        activeSub.status = 'ACTIVE';
        activeSub.expiresAtEpochMs = baseDate.getTime();
        activeSub.updatedAtEpochMs = now;
        await setDocument(env, 'subscriptions', activeSub.subscriptionId, activeSub);
      }

    } else if (action === 'TRANSFER') {
      if (!body.newHardwareId) return createErrorResponse(400, 'MISSING_HARDWARE_ID', 'newHardwareId is required.');
      const oldHardwareId = isTrial ? activeSub.hardwareId : activeSub.activeInstallationId;
      
      if (isTrial) {
        activeSub.hardwareId = body.newHardwareId;
        await setDocument(env, 'hardware_trials', body.newHardwareId, activeSub);
        await deleteDocument(env, 'hardware_trials', trialId);
      } else {
        activeSub.activeInstallationId = body.newHardwareId;
        activeSub.updatedAtEpochMs = now;
        await setDocument(env, 'subscriptions', activeSub.subscriptionId, activeSub);
        
        // Fix Issue 4: Approve any pending P2P transfers for this subscription
        const pendingTransfers = await queryCollection(env, 'device_transfers', [
          { field: 'subscriptionId', op: 'EQUAL', value: activeSub.subscriptionId }
        ]);
        for (const pt of pendingTransfers) {
          if (pt.status === 'PENDING') {
            await setDocument(env, 'device_transfers', pt.transferId, {
              ...pt,
              status: 'APPROVED',
              approvedBy: `ADMIN_${adminUid}`,
              updatedAtEpochMs: now
            });
          }
        }
      }
      
      // Revoke old installation
      if (oldHardwareId) {
        const sourceInst = await getDocument(env, 'installations', oldHardwareId);
        if (sourceInst) {
          await setDocument(env, 'installations', oldHardwareId, {
            ...sourceInst,
            status: 'REVOKED',
            revokedAtEpochMs: now,
            revokedReason: `Admin transfer override to ${body.newHardwareId}`
          });
        }
      }

    } else if (action === 'REMOVE') {
      const hardwareId = isTrial ? activeSub.hardwareId : activeSub.activeInstallationId;
      if (isTrial) {
        activeSub.status = 'CANCELLED';
        await setDocument(env, 'hardware_trials', trialId, activeSub);
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
    const chunk = formData.get('chunk') as File;
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
