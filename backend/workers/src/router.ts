import { Env } from './types';
import { handleGetSystemConfig } from './routes/config';
import { handleGetPlans } from './routes/plans';
import { handleCustomerRegistration, handleUpdateFcmToken, handleCustomerLogout } from './routes/customers';
import { handleGetSubscriptionStatus } from './routes/subscriptions';
import { handleRequestTransfer, handleGetPendingTransfers, handleApproveTransfer, handleRejectTransfer, handleGetTransferStatus, handleCancelTransfer } from './routes/transfers';
import { handleCreateOrder, handleVerifyOrder } from './routes/orders';
import { handleAdminSearchCustomers, handleAdminUpdateCustomer, handleAdminApproveTransfer, handleAdminRejectTransfer, handleAdminUpdateSystemConfig, handleAdminGetAuditLogs, handleAdminGetPendingTransfers, handleAdminBanDevice, handleAdminUnbanDevice, handleAdminUpdatePlans, handleAdminManageSubscription, handleAdminUploadApkChunk } from './routes/admin';
import { handlePublicDownloadApk } from './routes/public';
import { handleMigrateLegacyKey } from './routes/migrate';
import { handleRazorpayWebhook } from './webhooks';
import { localStore } from './services/firestore';
import { authenticateRequest, authenticateAdminRequest, createErrorResponse } from './authGuard';

/**
 * Main API Gateway Router for VendSoft Cloudflare Workers Control Plane.
 * Enforces CORS and cleanly splits public endpoints from protected composite-identity endpoints.
 */
export async function routeRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  // 1. Handle CORS Preflight (`OPTIONS`) requests cleanly
  if (request.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type, x-customer-id, x-installation-id, x-hardware-id, x-installation-uuid, x-app-version, x-platform, x-idempotency-key, x-razorpay-signature, x-admin-secret, cf-access-jwt-assertion',
        'Access-Control-Max-Age': '86400'
      }
    });
  }

  // Normalize path by stripping optional `/api` prefix if present (`/api/v1/...` -> `/v1/...`)
  const normalizedPath = path.startsWith('/api/') ? path.substring(4) : path;

    // === PUBLIC CONFIG ENDPOINTS ===
    if (normalizedPath === '/v1/config/system') {
      return await handleGetSystemConfig(request, env);
    }
    
    if (normalizedPath === '/v1/plans') {
      return await handleGetPlans(request, env);
    }

    if (normalizedPath.startsWith('/v1/public/apks/') && request.method === 'GET') {
      return await handlePublicDownloadApk(request, env);
    }



  // Phase 3: Razorpay Webhook Receiver (`POST /v1/webhooks/razorpay`)
  if (normalizedPath === '/v1/webhooks/razorpay' && request.method === 'POST') {
    return handleRazorpayWebhook(request, env);
  }

  // Health check / Control plane status
  if (normalizedPath === '/' || normalizedPath === '/health' || normalizedPath === '/v1/health') {
    return new Response(JSON.stringify({ success: true, status: 'ONLINE', version: '1.0.0-FROZEN', timestamp: Date.now() }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  }

  // Local Dev Store Inspection (`GET /v1/dev/store`)
  if (normalizedPath === '/v1/dev/store' && !env.FIRESTORE_SA_KEY) {
    const storeData: Record<string, any> = {};
    for (const [key, val] of localStore.entries()) {
      storeData[key] = val;
    }
    return new Response(JSON.stringify({ success: true, count: localStore.size, documents: storeData }, null, 2), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
    });
  }

  // ---------------------------------------------------------------------------
  // ADMIN PORTAL ENDPOINTS (`Phase 4 - Security Hardening & Control Plane`)
  // ---------------------------------------------------------------------------
  if (normalizedPath.startsWith('/v1/admin/')) {
    const { adminUid, errorResponse: adminError } = await authenticateAdminRequest(request, env);
    if (adminError || !adminUid) {
      return adminError || createErrorResponse(403, 'ADMIN_UNAUTHORIZED', 'Access denied.');
    }

    if (normalizedPath === '/v1/admin/upload-apk-chunk' && request.method === 'POST') {
      return handleAdminUploadApkChunk(request, env, adminUid);
    }

    if (normalizedPath === '/v1/admin/customers' && request.method === 'GET') {
      return handleAdminSearchCustomers(request, env);
    }
    if (normalizedPath.startsWith('/v1/admin/customers/') && normalizedPath.endsWith('/subscription') && request.method === 'PUT') {
      const customerId = normalizedPath.substring('/v1/admin/customers/'.length, normalizedPath.length - '/subscription'.length);
      return handleAdminManageSubscription(request, env, adminUid, customerId);
    }
    if (normalizedPath.startsWith('/v1/admin/customers/') && request.method === 'PUT' && !normalizedPath.endsWith('/subscription')) {
      const customerId = normalizedPath.substring('/v1/admin/customers/'.length);
      return handleAdminUpdateCustomer(request, env, adminUid, customerId);
    }
    if (normalizedPath.startsWith('/v1/admin/transfers/') && normalizedPath.endsWith('/approve') && request.method === 'POST') {
      const transferId = normalizedPath.substring('/v1/admin/transfers/'.length, normalizedPath.length - '/approve'.length);
      return handleAdminApproveTransfer(request, env, adminUid, transferId);
    }
    if (normalizedPath.startsWith('/v1/admin/transfers/') && normalizedPath.endsWith('/reject') && request.method === 'POST') {
      const transferId = normalizedPath.substring('/v1/admin/transfers/'.length, normalizedPath.length - '/reject'.length);
      return handleAdminRejectTransfer(request, env, adminUid, transferId);
    }
    if (normalizedPath.startsWith('/v1/admin/devices/') && normalizedPath.endsWith('/ban') && request.method === 'PUT') {
      const hardwareId = normalizedPath.substring('/v1/admin/devices/'.length, normalizedPath.length - '/ban'.length);
      return handleAdminBanDevice(request, env, adminUid, hardwareId);
    }
    if (normalizedPath.startsWith('/v1/admin/devices/') && normalizedPath.endsWith('/unban') && request.method === 'PUT') {
      const hardwareId = normalizedPath.substring('/v1/admin/devices/'.length, normalizedPath.length - '/unban'.length);
      return handleAdminUnbanDevice(request, env, adminUid, hardwareId);
    }
    if (normalizedPath === '/v1/admin/config/system' && request.method === 'PUT') {
      return handleAdminUpdateSystemConfig(request, env, adminUid);
    }
    if (normalizedPath === '/v1/admin/audit-logs' && request.method === 'GET') {
      return handleAdminGetAuditLogs(request, env);
    }
    if (normalizedPath === '/v1/admin/transfers/pending' && request.method === 'GET') {
      return handleAdminGetPendingTransfers(request, env);
    }
    if (normalizedPath === '/v1/admin/plans' && request.method === 'POST') {
      return handleAdminUpdatePlans(request, env, adminUid);
    }

    return createErrorResponse(404, 'ADMIN_ENDPOINT_NOT_FOUND', `Admin endpoint ${normalizedPath} not found.`);
  }

  // ---------------------------------------------------------------------------
  // PROTECTED ENDPOINTS (Requires valid Firebase ID Token & Composite Headers)
  // ---------------------------------------------------------------------------
  const { identity, errorResponse } = await authenticateRequest(request, env);
  if (errorResponse || !identity) {
    return errorResponse || createErrorResponse(401, 'UNAUTHORIZED', 'Authentication failed.');
  }

  // Phase 2.1: Customer Onboarding & Composite Registration
  if (normalizedPath === '/v1/customers/register') {
    return handleCustomerRegistration(request, env, identity);
  }

  if (normalizedPath === '/v1/installations/update-fcm' && request.method === 'POST') {
    return handleUpdateFcmToken(request, env, identity);
  }

  if (normalizedPath === '/v1/customers/logout' && request.method === 'POST') {
    return handleCustomerLogout(request, env, identity);
  }

  // Phase 2.2: Authoritative Subscription Status & Signed Lease
  if (normalizedPath === '/v1/subscriptions/status' && request.method === 'GET') {
    return handleGetSubscriptionStatus(request, env, identity);
  }

  // Phase 2.2: Peer-to-Peer Device Transfers
  if (normalizedPath === '/v1/transfers/request' && request.method === 'POST') {
    return handleRequestTransfer(request, env, identity);
  }
  if (normalizedPath === '/v1/transfers/pending' && request.method === 'GET') {
    return handleGetPendingTransfers(request, env, identity);
  }
  if (normalizedPath.startsWith('/v1/transfers/') && normalizedPath.endsWith('/status') && request.method === 'GET') {
    return handleGetTransferStatus(request, env, identity, normalizedPath);
  }
  if (normalizedPath === '/v1/transfers/approve' && request.method === 'POST') {
    return handleApproveTransfer(request, env, identity);
  }
  if (normalizedPath === '/v1/transfers/reject' && request.method === 'POST') {
    return handleRejectTransfer(request, env, identity);
  }
  if (normalizedPath === '/v1/transfers/cancel' && request.method === 'POST') {
    return handleCancelTransfer(request, env, identity);
  }

  // Phase 3: Razorpay Payment Checkout & Verification
  if (normalizedPath === '/v1/orders/create' && request.method === 'POST') {
    return handleCreateOrder(request, env);
  }
  if (normalizedPath === '/v1/orders/verify' && request.method === 'POST') {
    return handleVerifyOrder(request, env);
  }

  // Phase 5: Production Migration & Legacy System Sunset
  if (normalizedPath === '/v1/migrate/legacy-key' && request.method === 'POST') {
    return handleMigrateLegacyKey(request, env, identity);
  }

  return createErrorResponse(
    404,
    'ENDPOINT_NOT_FOUND',
    `Endpoint '${normalizedPath}' does not exist on this server or has not been activated yet.`
  );
}
