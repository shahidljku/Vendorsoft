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

// Simple in-memory rate limiter for Admin API (per Worker isolate)
const adminRateLimitMap = new Map<string, { count: number, resetTime: number }>();
const ADMIN_RATE_LIMIT_MAX = 60; // 60 requests
const ADMIN_RATE_LIMIT_WINDOW = 60000; // per 1 minute

/**
 * Main API Gateway Router for VendSoft Cloudflare Workers Control Plane.
 * Enforces CORS and cleanly splits public endpoints from protected composite-identity endpoints.
 */
export async function routeRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const path = url.pathname;

  // 1. Handle CORS Preflight (`OPTIONS`) requests cleanly
  if (request.method === 'OPTIONS') {
    let allowedOrigin = '*';
    if (path.includes('/api/v1/admin/') || path.includes('/v1/admin/')) {
      const origin = request.headers.get('Origin') || '';
      if (origin === 'https://vendsoft-admin.pages.dev' || origin.startsWith('http://127.0.0.1:') || origin.startsWith('http://localhost:')) {
        allowedOrigin = origin;
      } else {
        allowedOrigin = 'https://vendsoft-admin.pages.dev'; // Default secure origin
      }
    }
    
    return new Response(null, {
      status: 204,
      headers: {
        'Access-Control-Allow-Origin': allowedOrigin,
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



  // ---------------------------------------------------------------------------
  // ADMIN PORTAL ENDPOINTS (`Phase 4 - Security Hardening & Control Plane`)
  // ---------------------------------------------------------------------------
  if (normalizedPath.startsWith('/v1/admin/')) {
    // 1. Secure CORS for Admin Endpoints
    const origin = request.headers.get('Origin') || '';
    let allowedOrigin = 'https://vendsoft-admin.pages.dev';
    if (origin === 'https://vendsoft-admin.pages.dev' || origin.startsWith('http://127.0.0.1:') || origin.startsWith('http://localhost:')) {
      allowedOrigin = origin;
    }

    if (origin && origin !== allowedOrigin) {
      return new Response(JSON.stringify({ success: false, error: { code: 'CORS_ERROR', message: 'Origin not allowed' } }), {
        status: 403,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': allowedOrigin }
      });
    }

    // 2. Authenticate
    const { adminUid, role, errorResponse: adminError } = await authenticateAdminRequest(request, env);
    if (adminError || !adminUid) {
      const resp = adminError || createErrorResponse(403, 'ADMIN_UNAUTHORIZED', 'Access denied.');
      // Patch the CORS header on the error response
      const newHeaders = new Headers(resp.headers);
      newHeaders.set('Access-Control-Allow-Origin', allowedOrigin);
      return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: newHeaders });
    }

    // 3. Simple Rate Limiting (Cloudflare KV for global persistence)
    const now = Date.now();
    const rlKey = `ratelimit:${adminUid}`;
    let rlCount = 0;
    try {
      const rlStr = await env.APK_STORE.get(rlKey);
      if (rlStr) {
        rlCount = parseInt(rlStr, 10);
      }
      if (rlCount > ADMIN_RATE_LIMIT_MAX) {
        return new Response(JSON.stringify({ success: false, error: { code: 'TOO_MANY_REQUESTS', message: 'Rate limit exceeded. Try again later.' } }), {
          status: 429,
          headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': allowedOrigin }
        });
      }
      await env.APK_STORE.put(rlKey, (rlCount + 1).toString(), { expirationTtl: 60 }); // 60 seconds TTL
    } catch (err) {
      console.error('KV Rate Limit Error:', err);
    }

    let adminResponse: Response | null = null;

    if (normalizedPath === '/v1/admin/upload-apk-chunk' && request.method === 'POST') {
      adminResponse = await handleAdminUploadApkChunk(request, env, adminUid);
    } else if (normalizedPath === '/v1/admin/customers' && request.method === 'GET') {
      adminResponse = await handleAdminSearchCustomers(request, env);
    } else if (normalizedPath.startsWith('/v1/admin/customers/') && normalizedPath.endsWith('/subscription') && request.method === 'PUT') {
      const customerId = normalizedPath.substring('/v1/admin/customers/'.length, normalizedPath.length - '/subscription'.length);
      adminResponse = await handleAdminManageSubscription(request, env, adminUid, customerId);
    } else if (normalizedPath.startsWith('/v1/admin/customers/') && request.method === 'PUT' && !normalizedPath.endsWith('/subscription')) {
      const customerId = normalizedPath.substring('/v1/admin/customers/'.length);
      adminResponse = await handleAdminUpdateCustomer(request, env, adminUid, customerId);
    } else if (normalizedPath.startsWith('/v1/admin/transfers/') && normalizedPath.endsWith('/approve') && request.method === 'POST') {
      const transferId = normalizedPath.substring('/v1/admin/transfers/'.length, normalizedPath.length - '/approve'.length);
      adminResponse = await handleAdminApproveTransfer(request, env, adminUid, transferId);
    } else if (normalizedPath.startsWith('/v1/admin/transfers/') && normalizedPath.endsWith('/reject') && request.method === 'POST') {
      const transferId = normalizedPath.substring('/v1/admin/transfers/'.length, normalizedPath.length - '/reject'.length);
      adminResponse = await handleAdminRejectTransfer(request, env, adminUid, transferId);
    } else if (normalizedPath.startsWith('/v1/admin/devices/') && normalizedPath.endsWith('/ban') && request.method === 'PUT') {
      const hardwareId = normalizedPath.substring('/v1/admin/devices/'.length, normalizedPath.length - '/ban'.length);
      adminResponse = await handleAdminBanDevice(request, env, adminUid, hardwareId);
    } else if (normalizedPath.startsWith('/v1/admin/devices/') && normalizedPath.endsWith('/unban') && request.method === 'PUT') {
      const hardwareId = normalizedPath.substring('/v1/admin/devices/'.length, normalizedPath.length - '/unban'.length);
      adminResponse = await handleAdminUnbanDevice(request, env, adminUid, hardwareId);
    } else if (normalizedPath === '/v1/admin/config/system' && request.method === 'PUT') {
      adminResponse = await handleAdminUpdateSystemConfig(request, env, adminUid);
    } else if (normalizedPath === '/v1/admin/audit-logs' && request.method === 'GET') {
      adminResponse = await handleAdminGetAuditLogs(request, env);
    } else if (normalizedPath === '/v1/admin/transfers/pending' && request.method === 'GET') {
      adminResponse = await handleAdminGetPendingTransfers(request, env);
    } else if (normalizedPath === '/v1/admin/plans' && request.method === 'POST') {
      adminResponse = await handleAdminUpdatePlans(request, env, adminUid);
    } else if (normalizedPath === '/v1/admin/auth/verify' && request.method === 'GET') {
      // The authenticateAdminRequest already verified the token and role.
      // We log SUCCESSFUL_LOGIN here, once per frontend initialization.
      const { logAuditEvent } = await import('./services/firestore');
      await logAuditEvent(env, 'SUCCESSFUL_LOGIN', { adminUid, role });
      const payload = { success: true, data: { authorized: true, uid: adminUid, role: role } };
      adminResponse = new Response(JSON.stringify(payload), {
        status: 200,
        headers: {
          'Content-Type': 'application/json'
        }
      });
    }

    if (!adminResponse) {
      adminResponse = createErrorResponse(404, 'ADMIN_ENDPOINT_NOT_FOUND', `Admin endpoint ${normalizedPath} not found.`);
    }

    // Rewrite headers to enforce secure CORS
    const secureHeaders = new Headers(adminResponse.headers);
    secureHeaders.set('Access-Control-Allow-Origin', allowedOrigin);
    return new Response(adminResponse.body, { status: adminResponse.status, statusText: adminResponse.statusText, headers: secureHeaders });
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
