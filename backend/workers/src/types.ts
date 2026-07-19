/**
 * Environment bindings and secrets injected by Cloudflare Workers runtime.
 */
export interface Env {
  GCP_PROJECT_ID: string;
  FIREBASE_PROJECT_ID: string;
  ENVIRONMENT: string;
  
  // Secrets (Injected via `wrangler secret put`)
  FIRESTORE_SA_KEY?: string; // Service Account JSON string
  RAZORPAY_KEY_ID?: string;
  RAZORPAY_KEY_SECRET?: string;
  RAZORPAY_WEBHOOK_SECRET?: string;
  RSA_PRIVATE_KEY?: string;
  ADMIN_SECRET?: string;
  ALLOW_MOCK_KEYS?: string;
}

/**
 * Composite Identity extracted and verified from incoming HTTP request headers.
 * See API_SPECIFICATION.md Section 1.1 & SYSTEM_ARCHITECTURE.md Section 5.
 */
export interface CompositeIdentity {
  uid: string; // Verified short-lived Firebase ID Token UID
  customerId?: string; // Immutable 'cus_xxxxxxxxx' (Optional before registration)
  installationId?: string; // 'inst_xxxxxxxxx' (Optional before registration)
  hardwareId: string; // Deterministic 16-char SHA-256 hash (`LicenseService().getDeviceId()`)
  installationUuid: string; // Persistent UUID v4 stored in FlutterSecureStorage
  appVersion: string; // Client semantic build version (e.g., '1.0.0+1')
  platform: 'android' | 'windows'; // Operating system
  idempotencyKey?: string; // UUID v4 required on state-changing endpoints
}

/**
 * Standard API Response payload structure.
 * See API_SPECIFICATION.md Section 2.
 */
export interface ApiResponse<T = any> {
  success: boolean;
  data?: T;
  error?: {
    code: string;
    message: string;
    [key: string]: any;
  };
}

/**
 * System Configurations global document structure stored inside `system_configs/global`.
 * See SYSTEM_ARCHITECTURE.md Section 3.1 & FIRESTORE_SCHEMA.md Section 3.1.
 */
export interface SystemConfigDocument {
  minimumSupportedVersion: string;
  latestVersion: string;
  maintenanceMode: boolean;
  maintenanceMessage: string;
  allowRegistrations: boolean;
  allowPayments: boolean;
  allowTransfers: boolean;
  enforceStrictAppVersion?: boolean;
  apkDownloadUrl?: string;
  updatedAtEpochMs: number;
}
