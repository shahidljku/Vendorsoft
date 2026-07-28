import { RequestContext } from '../services/logger';
import { Env, CompositeIdentity } from '../types';
import { getDocument, queryCollection } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { TransferService } from '../services/transferService';

/**
 * Handles POST /api/v1/transfers/request
 * Initiates a Peer-to-Peer device transfer claim.
 * See API_SPECIFICATION.md Section 2.5.1 & FIRESTORE_SCHEMA.md Section 3.7.
 */
export async function handleRequestTransfer(ctx: RequestContext, request: Request, env: Env, identity: CompositeIdentity, isRateLimited: boolean = false): Promise<Response> {
  try {
    const config = await getDocument(ctx, env, 'system_configs', 'global');
    if (config && (config.allowTransfers === false || config.maintenanceMode === true)) {
      return createErrorResponse(
        config.maintenanceMode ? 503 : 403,
        config.maintenanceMode ? 'MAINTENANCE_MODE' : 'TRANSFERS_DISABLED',
        'Device transfers are currently disabled or system is under maintenance.'
      );
    }

    const body = await request.json() as any;
    if (typeof body.customerId === 'string' && body.customerId.length > 100) return createErrorResponse(400, 'INVALID_CUSTOMER_ID', 'customerId exceeds maximum allowed length.');
    if (typeof body.subscriptionId === 'string' && body.subscriptionId.length > 100) return createErrorResponse(400, 'INVALID_SUBSCRIPTION_ID', 'subscriptionId exceeds maximum allowed length.');
    if (typeof body.mobileNumber === 'string' && body.mobileNumber.length > 20) return createErrorResponse(400, 'INVALID_MOBILE_NUMBER', 'mobileNumber exceeds maximum allowed length.');

    let customerId = typeof body.customerId === 'string' ? body.customerId : (identity.customerId || undefined);
    const subscriptionId = typeof body.subscriptionId === 'string' ? body.subscriptionId : undefined;
    const mobileNumber = typeof body.mobileNumber === 'string' ? body.mobileNumber : undefined;

    if (!customerId && !subscriptionId && !mobileNumber) {
      return createErrorResponse(400, 'MISSING_PARAMETERS', 'Must provide customerId, subscriptionId, or mobileNumber.');
    }

    const deviceModel = (body.deviceModel || 'Unknown New Device').substring(0, 100);

    const result = await TransferService.requestTransfer(ctx, env, customerId, subscriptionId, mobileNumber, identity, deviceModel, isRateLimited);
    
    if (isRateLimited) {
      return createErrorResponse(429, 'TOO_MANY_REQUESTS', 'Transfer request rate limit exceeded.');
    }

    return new Response(JSON.stringify(result), {
      status: result.data.transferId === 'trn_already_active' ? 200 : 202,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });

  } catch (err: any) {
    ctx.logger.error('Error in POST /api/v1/transfers/request:', err);
    if (err.code === 'NO_CUSTOMER_FOUND' || err.code === 'NO_ACTIVE_SUBSCRIPTION') return createErrorResponse(404, err.code, err.message);
    if (err.code === 'TOO_MANY_REQUESTS') return createErrorResponse(429, err.code, err.message);
    if (err.code === 'ONLY_ONE_PENDING_TRANSFER_ALLOWED') return createErrorResponse(409, err.code, err.message, err.details);
    if (err.code === 'TRIAL_ALREADY_USED') return createErrorResponse(403, err.code, err.message);
    return createErrorResponse(500, 'TRANSFER_REQUEST_FAILED', `Failed to initiate transfer: ${err.message || err}`);
  }
}

/**
 * Handles GET /api/v1/transfers/pending
 * Mandatory polling endpoint called by old device upon foregrounding/sync to detect pending claims.
 * See API_SPECIFICATION.md Section 2.5.2.
 */
export async function handleGetPendingTransfers(ctx: RequestContext, request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    if (!identity.installationId) {
      return createErrorResponse(400, 'MISSING_INSTALLATION_ID', 'Header x-installation-uuid is required.');
    }

    let validOldIds = [identity.installationId];
    if (identity.hardwareId) validOldIds.push(identity.hardwareId);
    
    try {
      const instDocs = await queryCollection(ctx, env, 'installations', [{ field: 'hardwareId', op: 'EQUAL', value: identity.hardwareId }]);
      if (instDocs && instDocs.length > 0) {
        for (const d of instDocs) {
          if (d.installationId) validOldIds.push(d.installationId);
          if (d.documentId) validOldIds.push(d.documentId);
          if (d.id) validOldIds.push(d.id);
        }
      }
    } catch(e) {}
    
    validOldIds = [...new Set(validOldIds)].filter(Boolean);
    
    const pendingList: any[] = [];
    for (const id of validOldIds) {
      const rawPendingList = await queryCollection(ctx, env, 'device_transfers', [
        { field: 'oldInstallationId', op: 'EQUAL', value: id }
      ]);
      for (const t of rawPendingList) {
        if ((t.status === 'PENDING' || t.status === 'RATE_LIMITED') && !pendingList.find(existing => existing.transferId === t.transferId)) {
          pendingList.push(t);
        }
      }
    }

    const now = Date.now();
    const activePending = pendingList.filter((t) => t.expiresAtEpochMs > now).map((t) => ({
      transferId: t.transferId,
      newInstallationId: t.newInstallationId,
      deviceModel: t.deviceModel || 'Unknown Device',
      requestedAtEpochMs: t.requestedAtEpochMs,
      expiresAtEpochMs: t.expiresAtEpochMs
    }));

    return new Response(JSON.stringify({
      success: true,
      data: { pendingTransfers: activePending }
    }), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
  } catch (err: any) {
    ctx.logger.error('Error in GET /api/v1/transfers/pending:', err);
    return createErrorResponse(500, 'TRANSFER_POLL_FAILED', `Failed to query pending transfers: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/transfers/approve
 * Atomically approves transfer, reassigns activeInstallationId, revokes old device, and generates signedLeaseToken.
 * See API_SPECIFICATION.md Section 2.5.3.
 */
export async function handleApproveTransfer(ctx: RequestContext, request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    const body = await request.json() as any;
    const transferId = body.transferId;
    const idempotencyKey = identity.idempotencyKey;

    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Parameter transferId is required.');
    }

    if (idempotencyKey) {
      const existingIdem = await getDocument(ctx, env, 'idempotency_keys', idempotencyKey);
      if (existingIdem && existingIdem.expiresAtEpochMs > Date.now() && existingIdem.responsePayload) {
        let cachedData: any;
        try { cachedData = JSON.parse(existingIdem.responsePayload); } catch (e) { cachedData = existingIdem.responsePayload; }
        return new Response(JSON.stringify({ success: true, data: cachedData }), {
          status: 200,
          headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
        });
      }
    }

    const result = await TransferService.approveTransfer(ctx, env, transferId, identity, idempotencyKey);

    return new Response(JSON.stringify(result), {
      status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  } catch (err: any) {
    ctx.logger.error('Error in POST /api/v1/transfers/approve:', err);
    if (err.code === 'TRANSFER_NOT_PENDING') return createErrorResponse(400, err.code, err.message);
    if (err.code === 'UNAUTHORIZED_APPROVAL') return createErrorResponse(403, err.code, err.message);
    if (err.code === 'SUBSCRIPTION_NOT_FOUND') return createErrorResponse(404, err.code, err.message);
    if (err.code === 'TRANSFER_ALREADY_PROCESSED') return createErrorResponse(409, err.code, err.message);
    if (err.code === 'TRIAL_ALREADY_USED') return createErrorResponse(403, err.code, err.message);
    if (err.code === 'CONCURRENT_MUTATION_LOCKED' || err.code === 'ALREADY_EXISTS') return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', err.message);
    return createErrorResponse(500, 'TRANSFER_APPROVAL_FAILED', `Failed to approve transfer: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/transfers/reject
 * Rejects transfer claim, preserving old device's rights.
 * See API_SPECIFICATION.md Section 2.5.4.
 */
export async function handleRejectTransfer(ctx: RequestContext, request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    const body = await request.json() as any;
    const transferId = body.transferId;
    const idempotencyKey = identity.idempotencyKey;

    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Parameter transferId is required.');
    }

    if (idempotencyKey) {
      const existingIdem = await getDocument(ctx, env, 'idempotency_keys', idempotencyKey);
      if (existingIdem && existingIdem.expiresAtEpochMs > Date.now() && existingIdem.responsePayload) {
        let cachedData: any;
        try { cachedData = JSON.parse(existingIdem.responsePayload); } catch (e) { cachedData = existingIdem.responsePayload; }
        return new Response(JSON.stringify({ success: true, data: cachedData }), {
          status: 200,
          headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
        });
      }
    }

    const result = await TransferService.rejectTransfer(ctx, env, transferId, identity, idempotencyKey);

    return new Response(JSON.stringify(result), {
      status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });

  } catch (err: any) {
    ctx.logger.error('Error in POST /api/v1/transfers/reject:', err);
    if (err.code === 'TRANSFER_NOT_PENDING') return createErrorResponse(400, err.code, err.message);
    if (err.code === 'UNAUTHORIZED_REJECTION') return createErrorResponse(403, err.code, err.message);
    if (err.code === 'TRANSFER_ALREADY_PROCESSED') return createErrorResponse(409, err.code, err.message);
    if (err.code === 'CONCURRENT_MUTATION_LOCKED' || err.code === 'ALREADY_EXISTS') return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', err.message);
    return createErrorResponse(500, 'TRANSFER_REJECTION_FAILED', `Failed to reject transfer: ${err.message || err}`);
  }
}

/**
 * Handles GET /api/v1/transfers/:transferId/status
 * Allows the requesting device to poll for the status of a transfer.
 */
export async function handleGetTransferStatus(ctx: RequestContext, request: Request, env: Env, identity: CompositeIdentity, path: string): Promise<Response> {
  try {
    const transferId = path.substring('/v1/transfers/'.length, path.length - '/status'.length);
    
    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Transfer ID is required in URL path.');
    }

    const transferDoc = await getDocument(ctx, env, 'device_transfers', transferId);
    
    if (!transferDoc) {
      return createErrorResponse(404, 'TRANSFER_NOT_FOUND', 'The requested transfer was not found.');
    }

    // Security: Only allow if the requester is either the old or new installation
    if (transferDoc.oldInstallationId !== identity.installationId && 
        transferDoc.oldInstallationId !== identity.hardwareId && 
        transferDoc.newInstallationId !== identity.installationId) {
      return createErrorResponse(403, 'UNAUTHORIZED_ACCESS', 'You are not authorized to view this transfer status.');
    }

    return new Response(JSON.stringify({
      success: true,
      data: {
        transferId: transferDoc.transferId,
        status: transferDoc.status,
        expiresAtEpochMs: transferDoc.expiresAtEpochMs,
        resolvedAtEpochMs: transferDoc.resolvedAtEpochMs || null,
        completedAtEpochMs: transferDoc.completedAtEpochMs || null
      }
    }), { status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } });
    
  } catch (err: any) {
    ctx.logger.error('Error in GET /api/v1/transfers/status:', err);
    return createErrorResponse(500, 'TRANSFER_STATUS_FAILED', `Failed to get transfer status: ${err.message || err}`);
  }
}

/**
 * Handles POST /api/v1/transfers/cancel
 * Cancels a transfer claim from the requesting device (new device).
 */
export async function handleCancelTransfer(ctx: RequestContext, request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    const body = await request.json() as any;
    const transferId = body.transferId;
    
    if (!transferId) {
      return createErrorResponse(400, 'MISSING_TRANSFER_ID', 'Parameter transferId is required.');
    }

    const result = await TransferService.cancelTransfer(ctx, env, transferId, identity);

    return new Response(JSON.stringify(result), {
      status: 200, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });

  } catch (err: any) {
    ctx.logger.error('Error in POST /api/v1/transfers/cancel:', err);
    if (err.code === 'TRANSFER_NOT_FOUND') return createErrorResponse(404, err.code, err.message);
    if (err.code === 'TRANSFER_NOT_PENDING') return createErrorResponse(409, err.code, err.message);
    if (err.code === 'UNAUTHORIZED_CANCEL') return createErrorResponse(403, err.code, err.message);
    if (err.code === 'CONCURRENT_MUTATION_LOCKED' || err.code === 'ALREADY_EXISTS') return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', err.message);
    return createErrorResponse(500, 'TRANSFER_CANCELLATION_FAILED', `Failed to cancel transfer: ${err.message || err}`);
  }
}
