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
  
  // KV Namespaces & Queues
  APK_STORE: KVNamespace;
  WEBHOOK_QUEUE: Queue<any>;
  
  // Release Engineering Metadata
  WORKER_VERSION?: string;
  GIT_COMMIT?: string;
  BUILD_TIMESTAMP?: string;
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
  deviceModel?: string; // Hardware device model (e.g. SM-G998B)
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
  pricing?: {
    monthly: string;
    yearly: string;
  };
  updatedAtEpochMs: number;
}

/**
 * Represents a single atomic Firestore write operation.
 */
export interface BatchOperation {
  collectionPath: string;
  documentId: string;
  data: Record<string, any>;
  requireDoesNotExist?: boolean;
}

/**
 * Standardizes the output of builder methods that prepare data for atomic commits.
 */
export interface DomainMutation<T = void> {
  writes: BatchOperation[];
  result: T;
}
