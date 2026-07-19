import { Env, ApiResponse, SystemConfigDocument } from '../types';
import { getDocument } from '../services/firestore';
import { createErrorResponse } from '../authGuard';

/**
 * Default safe fallback System Configuration object when Firestore is unseeded or offline during initialization.
 * Exactly matches SYSTEM_ARCHITECTURE.md Section 3.1 & API_SPECIFICATION.md Section 2.1.
 */
const DEFAULT_SYSTEM_CONFIG: SystemConfigDocument = {
  minimumSupportedVersion: '1.0.0+1',
  latestVersion: '1.0.2+3',
  maintenanceMode: false,
  maintenanceMessage: 'VendSoft servers are undergoing scheduled maintenance. Offline billing continues normally.',
  allowRegistrations: true,
  allowPayments: true,
  allowTransfers: true,
  updatedAtEpochMs: 1752672000000
};

/**
 * Handles GET /api/v1/config/system
 * Public endpoint returning the authoritative global system configuration object (`system_configs/global`).
 */
export async function handleGetSystemConfig(request: Request, env: Env): Promise<Response> {
  if (request.method !== 'GET') {
    return createErrorResponse(405, 'METHOD_NOT_ALLOWED', 'Only GET method is permitted on /api/v1/config/system.');
  }

  try {
    const firestoreDoc = await getDocument(env, 'system_configs', 'global');
    
    // Merge Firestore document with default fallback values to ensure strict interface compliance
    const configData: SystemConfigDocument = firestoreDoc
      ? {
          minimumSupportedVersion: firestoreDoc.minimumSupportedVersion || DEFAULT_SYSTEM_CONFIG.minimumSupportedVersion,
          latestVersion: firestoreDoc.latestVersion || DEFAULT_SYSTEM_CONFIG.latestVersion,
          maintenanceMode: typeof firestoreDoc.maintenanceMode === 'boolean' ? firestoreDoc.maintenanceMode : DEFAULT_SYSTEM_CONFIG.maintenanceMode,
          maintenanceMessage: firestoreDoc.maintenanceMessage || DEFAULT_SYSTEM_CONFIG.maintenanceMessage,
          allowRegistrations: typeof firestoreDoc.allowRegistrations === 'boolean' ? firestoreDoc.allowRegistrations : DEFAULT_SYSTEM_CONFIG.allowRegistrations,
          allowPayments: typeof firestoreDoc.allowPayments === 'boolean' ? firestoreDoc.allowPayments : DEFAULT_SYSTEM_CONFIG.allowPayments,
          allowTransfers: typeof firestoreDoc.allowTransfers === 'boolean' ? firestoreDoc.allowTransfers : DEFAULT_SYSTEM_CONFIG.allowTransfers,
          enforceStrictAppVersion: firestoreDoc.enforceStrictAppVersion,
          apkDownloadUrl: firestoreDoc.apkDownloadUrl,
          updatedAtEpochMs: firestoreDoc.updatedAtEpochMs || DEFAULT_SYSTEM_CONFIG.updatedAtEpochMs
        }
      : DEFAULT_SYSTEM_CONFIG;

    const responsePayload: ApiResponse<SystemConfigDocument> = {
      success: true,
      data: configData
    };

    return new Response(JSON.stringify(responsePayload), {
      status: 200,
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': 'public, max-age=60', // Cache for 60 seconds at edge/client
        'Access-Control-Allow-Origin': '*'
      }
    });
  } catch (err: any) {
    console.error('Failed to retrieve system_configs/global:', err);
    // Even if Firestore throws an error (e.g., Service Account not set up yet), return safe default
    // to prevent blocking mobile app startup checks while logging the alert.
    const responsePayload: ApiResponse<SystemConfigDocument> = {
      success: true,
      data: DEFAULT_SYSTEM_CONFIG
    };
    return new Response(JSON.stringify(responsePayload), {
      status: 200,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      }
    });
  }
}
