import { describe, it, expect, vi, beforeEach } from 'vitest';
import { getMockEnv, mockFirestore } from '../setup';
import { routeRequest } from '../../src/router';
import { getDocument } from '../../src/services/firestore';

// Mock authGuard to control integration boundaries

vi.mock('../../src/authGuard', async () => {
  const actual = await vi.importActual<any>('../../src/authGuard');
  return {
    ...actual,
    authenticateAdminRequest: vi.fn(async (ctx, req, env) => {
      const auth = req.headers.get('Authorization');
      if (auth === 'Bearer valid_mock_token') {
        return { adminUid: 'test_admin_uid', role: 'ADMIN' };
      }
      return { errorResponse: new Response('Forbidden', { status: 403 }) };
    })
  };
});

describe('Phase 5C Health Diagnostics Integration', () => {
  let mockEnv: any;

  beforeEach(() => {
    mockEnv = getMockEnv();
    // Explicitly add WORKER_VERSION to mockEnv for tests
    mockEnv.WORKER_VERSION = '1.0.0-TEST';
    // Add FIRESTORE_SA_KEY which is missing from global getMockEnv
    mockEnv.FIRESTORE_SA_KEY = 'mock-sa-key';
    // Mock the KV store for the admin rate limiter in the router
    mockEnv.APK_STORE = {
      get: vi.fn().mockResolvedValue(null),
      put: vi.fn().mockResolvedValue(undefined)
    };
    vi.clearAllMocks();
  });

  describe('Public /v1/health', () => {
    it('returns a shallow 200 OK and explicitly avoids leaking diagnostic information', async () => {
      const request = new Request('https://api.vendsoft.com/v1/health');
      const response = await routeRequest(request, mockEnv);
      
      expect(response.status).toBe(200);
      
      const payload = await response.json() as any;
      
      // Asserts correct shallow payload
      expect(payload).toEqual({ status: 'ok' });
      
      // Asserts absolute absence of sensitive/diagnostic leakage
      expect(payload.version).toBeUndefined();
      expect(payload.checks).toBeUndefined();
      expect(payload.telemetry).toBeUndefined();
      expect(payload.firestore).toBeUndefined();
      expect(payload.FIRESTORE_SA_KEY).toBeUndefined();
    });
  });

  describe('Admin /v1/admin/diagnostics', () => {
    const makeAdminRequest = (urlStr: string) => {
      return new Request(urlStr, {
        headers: {
          'Authorization': 'Bearer valid_mock_token'
        }
      });
    };

    it('denies access without authentication', async () => {
      const request = new Request('https://api.vendsoft.com/v1/admin/diagnostics');
      const response = await routeRequest(request, mockEnv);
      
      expect(response.status).toBe(403);
    });

    it('returns healthy status when all configuration is present', async () => {
      // getMockEnv provides all required keys by default
      const request = makeAdminRequest('https://api.vendsoft.com/v1/admin/diagnostics');
      const response = await routeRequest(request, mockEnv);
      
      expect(response.status).toBe(200);
      const payload = await response.json() as any;
      
      expect(payload.status).toBe('healthy');
      expect(payload.version).toBe('1.0.0-TEST');
      expect(payload.checks.configuration).toBe('healthy');
      expect(payload.checks.firestore).toBe('configured');
      expect(payload.checks.razorpay).toBe('configured');
      expect(payload.checks.rsa).toBe('configured');
      expect(payload.telemetry.enabled).toBe(true);
      expect(payload.telemetry.registryVersion).toBe(1);
    });

    it('returns unhealthy status (503) and degrades components if config is missing', async () => {
      // Tamper with environment to simulate critical configuration loss
      delete mockEnv.FIRESTORE_SA_KEY;

      const request = makeAdminRequest('https://api.vendsoft.com/v1/admin/diagnostics');
      const response = await routeRequest(request, mockEnv);
      
      expect(response.status).toBe(503);
      const payload = await response.json() as any;
      
      expect(payload.status).toBe('unhealthy');
      expect(payload.checks.configuration).toBe('unhealthy');
      expect(payload.checks.firestore).toBe('missing'); // specifically flags firestore
      expect(payload.checks.razorpay).toBe('configured'); // leaves others alone
    });

    it('executes active firestore probe only when requested via ?probe=firestore', async () => {
      mockFirestore.getDocument.mockResolvedValueOnce(null); // simulates successful network ping

      const request = makeAdminRequest('https://api.vendsoft.com/v1/admin/diagnostics?probe=firestore');
      const response = await routeRequest(request, mockEnv);
      
      expect(response.status).toBe(200);
      const payload = await response.json() as any;
      
      expect(payload.status).toBe('healthy');
      expect(payload.checks['probe.firestore']).toBe('healthy');
      expect(mockFirestore.getDocument).toHaveBeenCalledTimes(1);
    });

    it('returns degraded status if active firestore probe throws an error', async () => {
      mockFirestore.getDocument.mockRejectedValueOnce(new Error('Network failure')); // simulates outage

      const request = makeAdminRequest('https://api.vendsoft.com/v1/admin/diagnostics?probe=firestore');
      const response = await routeRequest(request, mockEnv);
      
      // Still 200 OK because the worker is up, but the status is degraded
      expect(response.status).toBe(200);
      const payload = await response.json() as any;
      
      expect(payload.status).toBe('degraded');
      expect(payload.checks['probe.firestore']).toBe('unhealthy');
    });
  });
});
