import { Env, CompositeIdentity, ApiResponse } from './types';
import { getDocument, logAuditEvent } from './services/firestore';
import { decodeBase64Url } from './cryptoEngine';
import { RequestContext } from './services/logger';

// In-memory cache for Google's public JWKS to avoid fetching on every request
let jwksCache: any = null;
let jwksCacheTime: number = 0;
const JWKS_CACHE_TTL = 3600 * 1000; // 1 hour

/**
 * AuthGuard: Evaluates the mandatory composite identity headers and verifies the short-lived Firebase ID token.
 * Enforces the Zero-Trust Client Threat Model specified in SECURITY_RULES.md & API_SPECIFICATION.md Section 1.1.
 */
export async function authenticateRequest(
  ctx: RequestContext,
  request: Request,
  env: Env
): Promise<{ identity?: CompositeIdentity; errorResponse?: Response }> {
  // 1. Check required headers
  const authHeader = request.headers.get('Authorization');
  const hardwareId = request.headers.get('x-hardware-id');
  const installationUuid = request.headers.get('x-installation-uuid');
  const appVersion = request.headers.get('x-app-version');
  const platform = request.headers.get('x-platform');
  const customerId = request.headers.get('x-customer-id') || undefined;
  const installationId = request.headers.get('x-installation-id') || request.headers.get('x-installation-uuid') || undefined;
  const idempotencyKey = request.headers.get('x-idempotency-key') || undefined;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return {
      errorResponse: createErrorResponse(401, 'UNAUTHORIZED', 'Missing or invalid Authorization Bearer token header.')
    };
  }

  if (!hardwareId || !installationUuid || !appVersion || !platform) {
    return {
      errorResponse: createErrorResponse(
        400,
        'MISSING_IDENTITY_HEADERS',
        'Request is missing mandatory composite identity headers (x-hardware-id, x-installation-uuid, x-app-version, x-platform).'
      )
    };
  }

  if (platform !== 'android' && platform !== 'windows') {
    return {
      errorResponse: createErrorResponse(
        400,
        'INVALID_PLATFORM',
        `Platform '${platform}' is not supported. Must be 'android' or 'windows'.`
      )
    };
  }

  // 1.5. Hardware Ban Check (Firestore)
  if (hardwareId) {
    try {
      const instDoc = await getDocument(ctx, env, 'installations', hardwareId);
      if (instDoc && instDoc.status === 'BANNED') {
        return {
          errorResponse: createErrorResponse(
            403,
            'DEVICE_BANNED',
            'Your device is permanently blocked due to unethical activity or Terms of Service violations.'
          )
        };
      }
    } catch (err) {
      console.warn('Failed to check device ban status:', err);
    }
  }

  // 2. Extract and cryptographically verify Firebase ID Token
  const token = authHeader.substring(7).trim();
  const uid = await verifyFirebaseTokenCryptographically(token, env.FIREBASE_PROJECT_ID);

  if (!uid) {
    return {
      errorResponse: createErrorResponse(401, 'INVALID_TOKEN', 'The provided Firebase ID token is expired, invalid, or signature verification failed.')
    };
  }

  const identity: CompositeIdentity = {
    uid,
    customerId,
    installationId,
    hardwareId,
    installationUuid,
    appVersion,
    platform: platform as 'android' | 'windows',
    idempotencyKey
  };

  return { identity };
}

export type Role = 'ADMIN' | 'SUPERVISOR' | 'SUPPORT' | 'READ_ONLY';
export type Permission = 
  | 'FULL_ACCESS' 
  | 'CUSTOMERS_READ' 
  | 'CUSTOMERS_EDIT'
  | 'DEVICES_BAN'
  | 'TRANSFERS_APPROVE'
  | 'AUDIT_VIEW'
  | 'PLANS_EDIT'
  | 'SYSTEM_CONFIG_EDIT';

const ROLE_PERMISSIONS: Record<string, Permission[]> = {
  'ADMIN': ['FULL_ACCESS'],
  'SUPERVISOR': ['CUSTOMERS_READ', 'CUSTOMERS_EDIT', 'AUDIT_VIEW', 'TRANSFERS_APPROVE'],
  'SUPPORT': ['CUSTOMERS_READ', 'AUDIT_VIEW'],
  'READ_ONLY': ['CUSTOMERS_READ']
};

export function hasPermission(role: string, permission: Permission): boolean {
  const permissions = ROLE_PERMISSIONS[role] || [];
  return permissions.includes(permission) || permissions.includes('FULL_ACCESS');
}

/**
 * Authenticates an admin request by validating the Firebase ID token
 * AND enforcing Role-Based Access Control (RBAC) via the `admin_users` Firestore collection.
 */
export async function authenticateAdminRequest(
  ctx: RequestContext,
  request: Request,
  env: Env,
  requiredPermission: Permission

): Promise<{ adminUid?: string; role?: string; errorResponse?: Response }> {
  const authHeader = request.headers.get('Authorization');

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return {
      errorResponse: createErrorResponse(401, 'ADMIN_UNAUTHORIZED', 'Missing or invalid Authorization Bearer token header.')
    };
  }

  const token = authHeader.substring(7).trim();
  const uid = await verifyFirebaseTokenCryptographically(token, env.FIREBASE_PROJECT_ID);

  if (!uid) {
    console.log(`[AUTH] Failed to extract UID from Firebase ID token.`);
    return {
      errorResponse: createErrorResponse(401, 'ADMIN_UNAUTHORIZED', 'Invalid or expired Firebase ID token.')
    };
  }

  console.log(`[AUTH] Successfully extracted Firebase UID: ${uid}`);

  // Enforce Authorization (RBAC) via Firestore
  try {
    console.log(`[AUTH] Querying Firestore path: admin_users/${uid}`);
    const adminDoc = await getDocument(ctx, env, 'admin_users', uid);
    
    if (!adminDoc) {
      console.log(`[AUTH] 403 Forbidden: Document does not exist for UID: ${uid}`);
      await logAuditEvent(ctx, env, 'UNAUTHORIZED_ADMIN_ACCESS_ATTEMPT', { uid, reason: 'NO_DOCUMENT' });
      return {
        errorResponse: createErrorResponse(403, 'ADMIN_FORBIDDEN', 'Your account is not authorized to access the admin portal.')
      };
    }

    if (!adminDoc.role) {
      console.log(`[AUTH] 403 Forbidden: Document exists but has no role field for UID: ${uid}`);
      await logAuditEvent(ctx, env, 'UNAUTHORIZED_ADMIN_ACCESS_ATTEMPT', { uid, reason: 'NO_ROLE_FIELD' });
      return {
        errorResponse: createErrorResponse(403, 'ADMIN_FORBIDDEN', 'Your account is not authorized to access the admin portal.')
      };
    }

    console.log(`[AUTH] Role found in Firestore: '${adminDoc.role}'`);

    if (!hasPermission(adminDoc.role as any, requiredPermission as any)) {
      console.log(`[AUTH] 403 Forbidden: Role '${adminDoc.role}' lacks permission '${requiredPermission}'.`);
      await logAuditEvent(ctx, env, 'UNAUTHORIZED_ADMIN_ACCESS_ATTEMPT', { uid, attemptedRole: adminDoc.role, requiredPermission, reason: 'INSUFFICIENT_ROLE' });
      return {
        errorResponse: createErrorResponse(403, 'ADMIN_FORBIDDEN', `Role '${adminDoc.role}' is not authorized for this operation. Requires permission: '${requiredPermission}'.`)
      };
    }

    console.log(`[AUTH] Authorization successful. Access granted to UID: ${uid} with role: ${adminDoc.role}`);
    return { adminUid: uid, role: adminDoc.role };
  } catch (err) {
    console.error('Failed to verify admin role in Firestore:', err);
    return {
      errorResponse: createErrorResponse(500, 'INTERNAL_SERVER_ERROR', 'Failed to verify administrator privileges.')
    };
  }
}

/**
 * Cryptographically verifies the JWT signature of a Firebase ID Token using Google's public JWKS.
 * Checks signature, project audience (`aud`), issuer (`iss`), and expiration (`exp`).
 */
async function verifyFirebaseTokenCryptographically(idToken: string, expectedProjectId: string): Promise<string | null> {
  try {
    const parts = idToken.split('.');
    if (parts.length !== 3) return null;

    const header = JSON.parse(decodeBase64Url(parts[0]) || '{}');
    const claims = JSON.parse(decodeBase64Url(parts[1]) || '{}');

    // 1. Verify standard JWT claims
    const currentEpochSeconds = Math.floor(Date.now() / 1000);
    if (!claims.exp || claims.exp <= currentEpochSeconds) return null;
    if (!claims.iat || claims.iat > currentEpochSeconds + 5) return null; // Allow 5s clock skew
    if (expectedProjectId) {
      if (claims.aud !== expectedProjectId) return null;
      if (claims.iss !== `https://securetoken.google.com/${expectedProjectId}`) return null;
    }

    // 2. Fetch Google JWKS
    if (!jwksCache || Date.now() - jwksCacheTime > JWKS_CACHE_TTL) {
      const resp = await fetch('https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com');
      if (!resp.ok) return null;
      jwksCache = await resp.json();
      jwksCacheTime = Date.now();
    }

    const keys: any[] = jwksCache.keys || [];
    const jwk = keys.find(k => k.kid === header.kid);
    if (!jwk) return null; // Key ID not found in Google's current JWKS

    // 3. Cryptographically verify signature using WebCrypto API
    const key = await crypto.subtle.importKey(
      'jwk',
      jwk,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify']
    );

    const encoder = new TextEncoder();
    const data = encoder.encode(`${parts[0]}.${parts[1]}`);
    
    // JWT signatures are base64url encoded. Convert to Uint8Array.
    const signatureStr = atob(parts[2].replace(/-/g, '+').replace(/_/g, '/'));
    const signatureBytes = new Uint8Array(signatureStr.length);
    for (let i = 0; i < signatureStr.length; i++) {
      signatureBytes[i] = signatureStr.charCodeAt(i);
    }

    const isValid = await crypto.subtle.verify(
      'RSASSA-PKCS1-v1_5',
      key,
      signatureBytes,
      data
    );

    if (!isValid) return null;

    // Return exact verified Firebase Auth UID (`sub` or `user_id`)
    const uid = claims.sub || claims.user_id;
    if (typeof uid === 'string' && uid.length > 0) {
      return uid;
    }

    return null;
  } catch (err) {
    console.error('JWT Verification Error:', err);
    return null;
  }
}


/**
 * Generates a standardized JSON error response.
 */
export function createErrorResponse(status: number, code: string, message: string, details?: Record<string, any>): Response {
  const payload: ApiResponse = {
    success: false,
    error: {
      code,
      message,
      ...(details || {})
    }
  };
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*'
    }
  });
}
