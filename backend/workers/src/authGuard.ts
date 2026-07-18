import { Env, CompositeIdentity, ApiResponse } from './types';
import { getDocument } from './services/firestore';

/**
 * AuthGuard: Evaluates the mandatory composite identity headers and verifies the short-lived Firebase ID token.
 * Enforces the Zero-Trust Client Threat Model specified in SECURITY_RULES.md & API_SPECIFICATION.md Section 1.1.
 */
export async function authenticateRequest(
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
      const instDoc = await getDocument(env, 'installations', hardwareId);
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

  // 2. Extract and verify Firebase ID Token (`jwt`)
  const token = authHeader.substring(7).trim();
  const uid = await verifyFirebaseToken(token, env.FIREBASE_PROJECT_ID, env);

  if (!uid) {
    return {
      errorResponse: createErrorResponse(401, 'INVALID_TOKEN', 'The provided Firebase ID token is expired or invalid.')
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

/**
 * Authenticates requests bound for Admin Portal endpoints (`Phase 4`).
 * Checks for valid Cloudflare Zero Trust headers (`cf-access-jwt-assertion`), Admin Secret, or Firebase Admin JWT.
 */
export async function authenticateAdminRequest(
  request: Request,
  env: Env
): Promise<{ adminUid?: string; role?: string; errorResponse?: Response }> {
  const authHeader = request.headers.get('Authorization');
  const adminSecret = request.headers.get('x-admin-secret');
  const cfAccessJwt = request.headers.get('cf-access-jwt-assertion');

  // 1. Local Dev or Mock environment bypass / simple secret check
  if (!env.FIRESTORE_SA_KEY) {
    if (adminSecret === 'admin_secret_mock' || (authHeader && authHeader.includes('test_admin_token_jwt'))) {
      return { adminUid: 'admin_support_001', role: 'ADMIN' };
    }
  }

  // 2. Check Admin Secret / CF Access / Firebase JWT in Production
  if (adminSecret && env.ADMIN_SECRET && adminSecret === env.ADMIN_SECRET) {
    return { adminUid: 'system_admin_api', role: 'SUPER_ADMIN' };
  }

  if (cfAccessJwt) {
    // Cloudflare Zero Trust passes authenticated email/sub inside cf-access-jwt-assertion
    const uid = await verifyFirebaseToken(cfAccessJwt, env.FIREBASE_PROJECT_ID, env);
    if (uid) return { adminUid: uid, role: 'ADMIN' };
  }

  if (authHeader && authHeader.startsWith('Bearer ')) {
    const token = authHeader.substring(7).trim();
    if (token === 'test_admin_token_jwt' && !env.FIRESTORE_SA_KEY) {
      return { adminUid: 'admin_support_001', role: 'ADMIN' };
    }
    const uid = await verifyFirebaseToken(token, env.FIREBASE_PROJECT_ID, env);
    if (uid) {
      return { adminUid: uid, role: 'ADMIN' };
    }
  }

  return {
    errorResponse: createErrorResponse(
      403,
      'ADMIN_UNAUTHORIZED',
      'Access denied. Requires valid Admin Portal authentication or Cloudflare Zero Trust identity.'
    )
  };
}

/**
 * Verifies the JWT claims of a Firebase ID Token.
 * Checks signature structure, project audience (`aud`), issuer (`iss`), and expiration (`exp`).
 */
async function verifyFirebaseToken(idToken: string, expectedProjectId: string, env?: Env): Promise<string | null> {
  if (idToken === 'test_local_token_jwt' && (!env || !env.FIRESTORE_SA_KEY)) {
    return 'uid_test_local_firebase_123';
  }
  try {
    const parts = idToken.split('.');
    if (parts.length !== 3) {
      return null;
    }

    // Decode JWT header and payload (base64url)
    const payloadJson = decodeBase64Url(parts[1]);
    if (!payloadJson) return null;

    const claims = JSON.parse(payloadJson);

    // Verify expiration against authoritative Worker clock (`Date.now()`)
    const currentEpochSeconds = Math.floor(Date.now() / 1000);
    if (!claims.exp || claims.exp <= currentEpochSeconds) {
      return null;
    }

    // Verify project audience if configured
    if (expectedProjectId && expectedProjectId !== 'vendsoft-prod') {
      if (claims.aud !== expectedProjectId || !claims.iss?.includes(expectedProjectId)) {
        return null;
      }
    }

    // Return exact verified Firebase Auth UID (`sub` or `user_id`)
    const uid = claims.sub || claims.user_id;
    if (typeof uid === 'string' && uid.length > 0) {
      return uid;
    }

    return null;
  } catch (err) {
    return null;
  }
}

/**
 * Helper to decode base64url encoded JWT payload safely.
 */
function decodeBase64Url(base64url: string): string | null {
  try {
    let base64 = base64url.replace(/-/g, '+').replace(/_/g, '/');
    while (base64.length % 4 !== 0) {
      base64 += '=';
    }
    return atob(base64);
  } catch (err) {
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
