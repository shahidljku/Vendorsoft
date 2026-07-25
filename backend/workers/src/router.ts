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
import { handleGetHealth, handleAdminDiagnostics } from './routes/health';
import { LoggerService, TelemetryService, RequestContext } from './services/logger';
import { localStore } from './services/firestore';
import { authenticateRequest, authenticateAdminRequest, createErrorResponse, Permission } from './authGuard';
import { RateLimitPolicies } from './services/resilience/policies';
import { checkRateLimit } from './services/resilience/rateLimiter';



/**
 * Main API Gateway Router for VendSoft Cloudflare Workers Control Plane.
 * Enforces CORS and cleanly splits public endpoints from protected composite-identity endpoints.
 */
export async function routeRequest(request: Request, env: Env, execCtx?: ExecutionContext): Promise<Response> {
  const traceId = request.headers.get('x-trace-id') || crypto.randomUUID();
  const logger = new LoggerService(traceId);
  const telemetry = new TelemetryService(traceId);
  const ctx: RequestContext = { traceId, logger, telemetry, execCtx };
  ctx.logger.info(`Incoming ${request.method} ${request.url}`);

  const url = new URL(request.url);
  const path = url.pathname;

  return ctx.telemetry.measure('http.request.duration', { method: request.method, path }, async () => {

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
      return await handleGetSystemConfig(ctx, request, env);
    }
    
    if (normalizedPath === '/v1/plans') {
      return await handleGetPlans(ctx, request, env);
    }

    if (normalizedPath.startsWith('/v1/public/apks/') && request.method === 'GET') {
      return await handlePublicDownloadApk(ctx, request, env);
    }



  // Phase 3: Razorpay Webhook Receiver (`POST /v1/webhooks/razorpay`)
  if (normalizedPath === '/v1/webhooks/razorpay' && request.method === 'POST') {
    return handleRazorpayWebhook(ctx, request, env);
  }

  // Phase 5C: Health & Diagnostics
  if (normalizedPath === '/' || normalizedPath === '/health' || normalizedPath === '/v1/health') {
    return await handleGetHealth(ctx, request, env);
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

    // 2. Resolve Required Permission
    let requiredPermission: Permission = 'FULL_ACCESS'; // Secure default
    
    if (normalizedPath === '/v1/admin/customers' && request.method === 'GET') requiredPermission = 'CUSTOMERS_READ';
    else if (normalizedPath.startsWith('/v1/admin/customers/') && request.method === 'PUT') requiredPermission = 'CUSTOMERS_EDIT';
    else if (normalizedPath.startsWith('/v1/admin/devices/') && (normalizedPath.endsWith('/ban') || normalizedPath.endsWith('/unban'))) requiredPermission = 'DEVICES_BAN';
    else if (normalizedPath.startsWith('/v1/admin/transfers/') && (normalizedPath.endsWith('/approve') || normalizedPath.endsWith('/reject'))) requiredPermission = 'TRANSFERS_APPROVE';
    else if (normalizedPath === '/v1/admin/transfers/pending' && request.method === 'GET') requiredPermission = 'CUSTOMERS_READ';
    else if (normalizedPath === '/v1/admin/config/system' && request.method === 'PUT') requiredPermission = 'SYSTEM_CONFIG_EDIT';
    else if (normalizedPath === '/v1/admin/plans' && request.method === 'POST') requiredPermission = 'PLANS_EDIT';
    else if (normalizedPath === '/v1/admin/audit-logs' && request.method === 'GET') requiredPermission = 'AUDIT_VIEW';
    else if (normalizedPath === '/v1/admin/diagnostics' && request.method === 'GET') requiredPermission = 'FULL_ACCESS';
    else if (normalizedPath === '/v1/admin/upload-apk-chunk' && request.method === 'POST') requiredPermission = 'FULL_ACCESS';
    else if (normalizedPath === '/v1/admin/auth/verify' && request.method === 'GET') requiredPermission = 'CUSTOMERS_READ';

    // 3. Authenticate
    const { adminUid, role, errorResponse: adminError } = await authenticateAdminRequest(ctx, request, env, requiredPermission);
    if (adminError || !adminUid) {
      const resp = adminError || createErrorResponse(403, 'ADMIN_UNAUTHORIZED', 'Access denied.');
      // Patch the CORS header on the error response
      const newHeaders = new Headers(resp.headers);
      newHeaders.set('Access-Control-Allow-Origin', allowedOrigin);
      return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: newHeaders });
    }

    // 3. Simple Rate Limiting (Cloudflare KV for global persistence)
    const rlAllowed = await checkRateLimit(env, RateLimitPolicies.ADMIN_API, `admin:${adminUid}`);
    if (!rlAllowed) {
      return new Response(JSON.stringify({ success: false, error: { code: 'TOO_MANY_REQUESTS', message: 'Rate limit exceeded. Try again later.' } }), {
        status: 429,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': allowedOrigin }
      });
    }

    let adminResponse: Response | null = null;

    if (normalizedPath === '/v1/admin/diagnostics' && request.method === 'GET') {
      adminResponse = await handleAdminDiagnostics(ctx, request, env);
    } else if (normalizedPath === '/v1/admin/upload-apk-chunk' && request.method === 'POST') {
      adminResponse = await handleAdminUploadApkChunk(ctx, request, env, adminUid);
    } else if (normalizedPath === '/v1/admin/customers' && request.method === 'GET') {
      adminResponse = await handleAdminSearchCustomers(ctx, request, env);
    } else if (normalizedPath.startsWith('/v1/admin/customers/') && normalizedPath.endsWith('/subscription') && request.method === 'PUT') {
      const customerId = normalizedPath.substring('/v1/admin/customers/'.length, normalizedPath.length - '/subscription'.length);
      adminResponse = await handleAdminManageSubscription(ctx, request, env, adminUid, customerId);
    } else if (normalizedPath.startsWith('/v1/admin/customers/') && request.method === 'PUT' && !normalizedPath.endsWith('/subscription')) {
      const customerId = normalizedPath.substring('/v1/admin/customers/'.length);
      adminResponse = await handleAdminUpdateCustomer(ctx, request, env, adminUid, customerId);
    } else if (normalizedPath.startsWith('/v1/admin/transfers/') && normalizedPath.endsWith('/approve') && request.method === 'POST') {
      const transferId = normalizedPath.substring('/v1/admin/transfers/'.length, normalizedPath.length - '/approve'.length);
      adminResponse = await handleAdminApproveTransfer(ctx, request, env, adminUid, transferId);
    } else if (normalizedPath.startsWith('/v1/admin/transfers/') && normalizedPath.endsWith('/reject') && request.method === 'POST') {
      const transferId = normalizedPath.substring('/v1/admin/transfers/'.length, normalizedPath.length - '/reject'.length);
      adminResponse = await handleAdminRejectTransfer(ctx, request, env, adminUid, transferId);
    } else if (normalizedPath.startsWith('/v1/admin/devices/') && normalizedPath.endsWith('/ban') && request.method === 'PUT') {
      const hardwareId = normalizedPath.substring('/v1/admin/devices/'.length, normalizedPath.length - '/ban'.length);
      adminResponse = await handleAdminBanDevice(ctx, request, env, adminUid, hardwareId);
    } else if (normalizedPath.startsWith('/v1/admin/devices/') && normalizedPath.endsWith('/unban') && request.method === 'PUT') {
      const hardwareId = normalizedPath.substring('/v1/admin/devices/'.length, normalizedPath.length - '/unban'.length);
      adminResponse = await handleAdminUnbanDevice(ctx, request, env, adminUid, hardwareId);
    } else if (normalizedPath === '/v1/admin/config/system' && request.method === 'PUT') {
      adminResponse = await handleAdminUpdateSystemConfig(ctx, request, env, adminUid);
    } else if (normalizedPath === '/v1/admin/audit-logs' && request.method === 'GET') {
      adminResponse = await handleAdminGetAuditLogs(ctx, request, env);
    } else if (normalizedPath === '/v1/admin/transfers/pending' && request.method === 'GET') {
      adminResponse = await handleAdminGetPendingTransfers(ctx, request, env);
    } else if (normalizedPath === '/v1/admin/plans' && request.method === 'POST') {
      adminResponse = await handleAdminUpdatePlans(ctx, request, env, adminUid);
    } else if (normalizedPath === '/v1/admin/auth/verify' && request.method === 'GET') {
      // The authenticateAdminRequest already verified the token and role.
      // We log SUCCESSFUL_LOGIN here, once per frontend initialization.
      const { logAuditEvent } = await import('./services/firestore');
      await logAuditEvent(ctx, env, 'SUCCESSFUL_LOGIN', { adminUid, role });
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
  const { identity, errorResponse } = await authenticateRequest(ctx, request, env);
  if (errorResponse || !identity) {
    return errorResponse || createErrorResponse(401, 'UNAUTHORIZED', 'Authentication failed.');
  }

  // Phase 2.1: Customer Onboarding & Composite Registration
  if (normalizedPath === '/v1/customers/register') {
    return handleCustomerRegistration(ctx, request, env, identity);
  }

  if (normalizedPath === '/v1/installations/update-fcm' && request.method === 'POST') {
    return handleUpdateFcmToken(ctx, request, env, identity);
  }

  if (normalizedPath === '/v1/customers/logout' && request.method === 'POST') {
    return handleCustomerLogout(ctx, request, env, identity);
  }

  // Phase 2.2: Authoritative Subscription Status & Signed Lease
  if (normalizedPath === '/v1/subscriptions/status' && request.method === 'GET') {
    return handleGetSubscriptionStatus(ctx, request, env, identity);
  }

  // Phase 2.2: Peer-to-Peer Device Transfers
  if (normalizedPath === '/v1/transfers/request' && request.method === 'POST') {
    const rlAllowed = await checkRateLimit(env, RateLimitPolicies.TRANSFER_REQUEST, `transfer:${identity.installationId || identity.hardwareId}`);
    if (!rlAllowed) return createErrorResponse(429, 'TOO_MANY_REQUESTS', 'Transfer request rate limit exceeded.');
    return handleRequestTransfer(ctx, request, env, identity);
  }
  if (normalizedPath === '/v1/transfers/pending' && request.method === 'GET') {
    return handleGetPendingTransfers(ctx, request, env, identity);
  }
  if (normalizedPath.startsWith('/v1/transfers/') && normalizedPath.endsWith('/status') && request.method === 'GET') {
    return handleGetTransferStatus(ctx, request, env, identity, normalizedPath);
  }
  if (normalizedPath === '/v1/transfers/approve' && request.method === 'POST') {
    return handleApproveTransfer(ctx, request, env, identity);
  }
  if (normalizedPath === '/v1/transfers/reject' && request.method === 'POST') {
    return handleRejectTransfer(ctx, request, env, identity);
  }
  if (normalizedPath === '/v1/transfers/cancel' && request.method === 'POST') {
    return handleCancelTransfer(ctx, request, env, identity);
  }

  // Phase 3: Razorpay Payment Checkout & Verification
  if (normalizedPath.startsWith('/v1/orders/create') && request.method === 'POST') {
    const rlAllowed = await checkRateLimit(env, RateLimitPolicies.ORDER_CREATION, `order:${identity.customerId || identity.hardwareId}`);
    if (!rlAllowed) return createErrorResponse(429, 'TOO_MANY_REQUESTS', 'Order creation rate limit exceeded.');
    return handleCreateOrder(ctx, request, env);
  }
  if (normalizedPath.startsWith('/v1/orders/verify') && request.method === 'POST') {
    return handleVerifyOrder(ctx, request, env);
  }

  // Phase 5: Production Migration & Legacy System Sunset
  if (normalizedPath === '/v1/migrate/legacy-key' && request.method === 'POST') {
    return handleMigrateLegacyKey(ctx, request, env, identity);
  }

  return createErrorResponse(
    404,
    'ENDPOINT_NOT_FOUND',
    `Endpoint '${normalizedPath}' does not exist on this server or has not been activated yet.`
  );
  }); // End of telemetry.measure wrapper
}
