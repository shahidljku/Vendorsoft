# Cloudflare Workers API Specification Blueprint (Version 1.0 Frozen)

## 1. Global API Conventions & Authentication Architecture

All backend control plane operations for VendSoft are exposed via RESTful endpoints hosted on **Cloudflare Workers** (`https://api.vendsoft.app/v1/...`).

### 1.1 Authentication & Composite Identity Header Requirements
Unless explicitly marked as **Public** (`/webhooks/razorpay`, `/config/system`), every HTTP request sent from the Flutter application must include the following mandatory headers enforcing the **Composite Identity Model**:

| Header Name | Required | Example Value | Description |
| :--- | :--- | :--- | :--- |
| `Authorization` | Yes | `Bearer eyJhbGciOiJSUzI1Ni...` | Short-lived **Firebase ID Token** (`uid`) obtained via `FirebaseAuth.instance.currentUser?.getIdToken()`. |
| `x-customer-id` | Conditional | `cus_89A2B3C4D5` | Immutable Cloudflare-assigned customer primary key (`cus_xxxxxxxxx`). Required after initial onboarding. |
| `x-installation-id`| Conditional| `inst_44E5F6A7B8` | Unique installation document identifier assigned by Cloudflare (`inst_xxxxxxxxx`). Required after initial onboarding. |
| `x-hardware-id` | Yes | `E8A9B2C3D4E5F6A7` | Deterministic 16-character SHA-256 hardware hash (`LicenseService().getDeviceId()`). |
| `x-installation-uuid`| Yes | `f47ac10b-58cc-4372-a567-0e02b2c3d479` | UUID v4 generated once and stored inside `FlutterSecureStorage`. Eliminates `UNKNOWN_DEVICE` collisions. |
| `x-app-version` | Yes | `1.0.0+1` | Semantic version string of the client runtime. |
| `x-platform` | Yes | `android` \| `windows` | Operating system identifier. |
| `x-idempotency-key` | Conditional | `c8b9d0e1-2345-6789-abcd-ef0123456789` | UUID v4 required on state-changing endpoints (`POST /customers/register`, `/orders/create`, `/transfers/request`, `/transfers/approve`). |
| `Content-Type` | Yes | `application/json` | All request bodies and response payloads are strictly JSON. |

---

## 2. Endpoint Specifications

### 2.1 Retrieve Global System Configuration (Public / Read-Only)
`GET /api/v1/config/system`

#### Purpose
Called by the Flutter app on startup and resume to read the server-controlled configuration object (`system_configs/global`). Enforces version checks, maintenance mode locks, and feature switches. **The Flutter app must only read these values and never modify them.**

#### Success Response (`200 OK`)
```json
{
  "success": true,
  "data": {
    "minimumSupportedVersion": "1.0.0+1",
    "latestVersion": "1.0.2+3",
    "maintenanceMode": false,
    "maintenanceMessage": "VendSoft servers are undergoing scheduled maintenance. Offline billing continues normally.",
    "allowRegistrations": true,
    "allowPayments": true,
    "allowTransfers": true,
    "updatedAtEpochMs": 1752672000000
  }
}
```

---

### 2.2 Customer Onboarding & Initial Registration
`POST /api/v1/customers/register`

#### Purpose
Called once on first app launch when a new vendor opens the app (`allowRegistrations` must be `true`). Collects business/owner display details, creates the immutable `customers` profile (`cus_xxxxxxxxx`), registers the initial composite `installations` record (`inst_xxxxxxxxx`), and issues a 30-day `DEMO_FREE` subscription where `activeInstallationId = inst_xxxxxxxxx`.

#### Request Headers & Payload
*Headers*: `Authorization: Bearer <ID_TOKEN>`, `x-hardware-id`, `x-installation-uuid`, `x-idempotency-key`.
```json
{
  "businessName": "Sharma Newspaper Agency",
  "ownerName": "Rajesh Sharma",
  "mobileNumber": "+919876543210",
  "city": "Lucknow",
  "platform": "android",
  "appVersion": "1.0.0+1",
  "deviceModel": "Samsung SM-M315F"
}
```

#### Success Response (`201 Created`)
```json
{
  "success": true,
  "data": {
    "customerId": "cus_89A2B3C4D5",
    "installationId": "inst_44E5F6A7B8",
    "subscriptionId": "sub_77F8E9A0B1",
    "planId": "DEMO_FREE",
    "activeInstallationId": "inst_44E5F6A7B8",
    "status": "ACTIVE",
    "expiresAtEpochMs": 1755264000000,
    "signedLeaseToken": "eyJhbGciOiJSUzI1NiIs..."
  }
}
```

---

### 2.3 Retrieve Authoritative Subscription Status & Signed Lease
`GET /api/v1/subscriptions/status`

#### Purpose
Fetches the current authoritative entitlement status for the requesting installation. Enforces the **One Active Device Rule**: queries `subscriptions` where `customerId == x-customer-id` AND `activeInstallationId == x-installation-id` AND `status == "ACTIVE"`. If valid, returns the RSA/Ed25519 `signedLeaseToken`.

#### Success Response (`200 OK`)
```json
{
  "success": true,
  "data": {
    "customerId": "cus_89A2B3C4D5",
    "installationId": "inst_44E5F6A7B8",
    "activeInstallationId": "inst_44E5F6A7B8",
    "hasActiveSubscription": true,
    "planId": "PRO_YEARLY",
    "planName": "Pro Annual License",
    "startsAtEpochMs": 1752672000000,
    "expiresAtEpochMs": 1784208000000,
    "maxCustomers": 10000,
    "allowWhatsAppAutoSend": true,
    "allowThermalPrinting": true,
    "signedLeaseToken": "eyJhbGciOiJSUzI1NiIs..."
  }
}
```

#### Error Responses (`403 Forbidden` - Device Superseded / Not Active)
If another device took over this subscription via transfer:
```json
{
  "success": false,
  "error": {
    "code": "INSTALLATION_SUPERSEDED",
    "message": "Another device is currently the active installation for this subscription. Please request a device transfer to activate this phone.",
    "activeInstallationId": "inst_99X8Y7Z6W5"
  }
}
```

---

### 2.4 Initiate Payment Order (`POST /api/v1/orders/create`) & Verify
- **`POST /api/v1/orders/create`**: Validates `allowPayments == true`, queries `plans/PRO_YEARLY` price, and creates Razorpay order.
- **`POST /api/v1/orders/verify`**: Client fallback verification via Razorpay REST API (`GET /v1/orders/{id}/payments`).
- **`POST /api/v1/webhooks/razorpay`**: Public endpoint verifying `x-razorpay-signature` HMAC SHA-256. Inside `runTransaction`, marks payment `SUCCESS`, creates/extends `subscriptions`, and sets `activeInstallationId = payment.installationId`.

---

### 2.5 Peer-to-Peer Device Transfer Endpoints (Optional Push / Mandatory Polling)

#### 2.5.1 Request Device Transfer (`POST /api/v1/transfers/request`)
Called when a vendor installs the app on a new phone and enters their existing `customerId` or `mobileNumber` to claim their active subscription (`sub_xxxxxxxxx`). Validates `allowTransfers == true`.

*Request Payload*:
```json
{
  "customerId": "cus_89A2B3C4D5",
  "subscriptionId": "sub_77F8E9A0B1"
}
```

*Validation & Safety Enforcement*:
1. Checks `subscriptions/sub_77F8E9A0B1`. If `activeInstallationId == x-installation-id` (already active), returns `200 OK`.
2. Checks `device_transfers` where `subscriptionId == sub_77F8E9A0B1` AND `status == "PENDING"`. If a pending request already exists, rejects with `409 Conflict` (`ONLY_ONE_PENDING_TRANSFER_ALLOWED`).
3. Creates a new transfer document in `device_transfers`:
   ```json
   {
     "transferId": "trn_12A3B4C5D6",
     "subscriptionId": "sub_77F8E9A0B1",
     "customerId": "cus_89A2B3C4D5",
     "oldInstallationId": "inst_44E5F6A7B8",
     "newInstallationId": "inst_NEW_PHONE_99",
     "status": "PENDING",
     "expiresAt": "serverTimestamp() + 24 hours"
   }
   ```
4. **Optional Push Delivery Attempt**: The Worker attempts to send an FCM data message to `inst_44E5F6A7B8`. **Transfer approval does NOT depend on whether this push succeeds or fails.**

*Success Response (`202 Accepted`)*:
```json
{
  "success": true,
  "data": {
    "transferId": "trn_12A3B4C5D6",
    "status": "PENDING",
    "message": "Transfer request sent to your old device. Please open VendSoft on your old device and tap 'Approve' to complete activation."
  }
}
```

---

#### 2.5.2 Poll Pending Transfer Requests (`GET /api/v1/transfers/pending`)
The **Mandatory Synchronization Path**. Called automatically by the active old device (`x-installation-id == oldInstallationId`) upon app foregrounding (`didChangeAppLifecycleState`) or periodic background sync to detect incoming transfer requests without relying on FCM.

*Success Response (`200 OK`)*:
```json
{
  "success": true,
  "data": {
    "pendingTransfers": [
      {
        "transferId": "trn_12A3B4C5D6",
        "newInstallationId": "inst_NEW_PHONE_99",
        "deviceModel": "Samsung Galaxy S24",
        "requestedAtEpochMs": 1752672000000,
        "expiresAtEpochMs": 1752758400000
      }
    ]
  }
}
```

---

#### 2.5.3 Approve Peer Transfer (`POST /api/v1/transfers/approve`)
Called when the user taps **"Approve Transfer"** on their old active device.

*Request Headers & Payload*: `x-installation-id: <OLD_INSTALLATION_ID>`, `x-idempotency-key`.
```json
{
  "transferId": "trn_12A3B4C5D6"
}
```

*Atomic Execution (`runTransaction`)*:
1. Verifies `transferDoc.status == "PENDING"` and `expiresAt > serverTimestamp()`.
2. Verifies `x-installation-id == transferDoc.oldInstallationId`.
3. Updates `subscriptions/{subId}.activeInstallationId = transferDoc.newInstallationId`.
4. Updates `installations/{oldInstallationId}.status = "REVOKED"`.
5. Updates `installations/{newInstallationId}.status = "ACTIVE"`.
6. Updates `device_transfers/{transferId}.status = "APPROVED"`, `approvedBy = "PEER_OLD_DEVICE"`, `completedAt = serverTimestamp()`.
7. Logs `TRANSFER_APPROVED_PEER` in `audit_logs`.

*Success Response (`200 OK`)*:
```json
{
  "success": true,
  "data": {
    "transferId": "trn_12A3B4C5D6",
    "status": "APPROVED",
    "message": "Transfer approved. This device has now been deactivated."
  }
}
```

---

#### 2.5.4 Reject Peer Transfer (`POST /api/v1/transfers/reject`)
Called if the user taps **"Reject"** on their old device when an unrecognized phone attempts to claim their license. Marks `status = "REJECTED"`, preserving the old device's active rights and logging an audit alert.

---

### 2.6 Support Admin Control Plane Endpoints (`Phase 4`)
Exposed under `https://api.vendsoft.app/v1/admin/...` and protected strictly by `x-admin-secret`, `cf-access-jwt-assertion`, or Firebase Admin Bearer token (`authenticateAdminRequest`).

#### 2.6.1 Customer 360° Search (`GET /api/v1/admin/customers?query={query}`)
Searches vendor profiles by `businessName`, `ownerName`, `customerId`, or `mobileNumber`. Returns profiles along with subscription active status and device installation counts.

#### 2.6.2 Profile Metadata Editor (`PUT /api/v1/admin/customers/{customerId}`)
Allows support admins to modify `businessName`, `ownerName`, `mobileNumber`, and `city` without altering subscription expirations or hardware device bindings. Logs `ADMIN_UPDATE_CUSTOMER_METADATA` to `audit_logs`.

#### 2.6.3 The Lost or Broken Phone Override (`POST /api/v1/admin/transfers/{transferId}/approve`)
Allows support admins to manually approve pending device transfer requests when the source phone is lost, damaged in water, or stolen (`Lost or Broken Phone Case`). Atomically revokes `oldInstallationId`, activates `newInstallationId`, and issues a new base64url signed lease token. Logs `ADMIN_APPROVED_TRANSFER_LOST_DEVICE` to `audit_logs`.

#### 2.6.4 Global Edge Switch Configuration (`PUT /api/v1/admin/config/system`)
Updates `system_configs/global` toggles (`allowPayments`, `allowP2PTransfers`, `maintenanceMode`, `enforceStrictAppVersion`). Logs `ADMIN_UPDATED_SYSTEM_CONFIG` to `audit_logs`.

#### 2.6.5 Immutable Audit Log Trail (`GET /api/v1/admin/audit-logs`)
Retrieves chronological, immutable audit records (`PAYMENT_SETTLED_WEBHOOK`, `TRANSFER_APPROVED_PEER`, `MIGRATED_LEGACY_RSA_LICENSE`, `ADMIN_*`).

---

### 2.7 Legacy RSA License Sunset & Grace Migration (`Phase 5`)
`POST /api/v1/migrate/legacy-key`

#### Purpose
Enables automated transition of legacy RSA `offline_license_key` strings (`v0.9.x` Base64 JSON format) into modern composite Cloudflare Worker leases (`v1.0.0+`) without double-charging vendors or altering original expiration dates.

#### Request Headers & Payload
*Headers*: `Authorization: Bearer <ID_TOKEN>`, `x-hardware-id`, `x-installation-uuid`, `x-platform`, `x-app-version`.
```json
{
  "legacyLicenseKey": "eyJwYXlsb2FkIjoiZXlKa1pYWnBZMl...Base64 RSA string"
}
```

#### Execution & Verification Flow
1. Decodes Base64 JSON (`payload` and `signature`).
2. Verifies RSASSA-PKCS1-v1_5 SHA-256 signature against authoritative developer `RSA_PUBLIC_KEY_PEM` using Web Crypto API (`crypto.subtle`).
3. Enforces that `payload.deviceId` matches the requesting `hardwareId` / `installationId`.
4. Computes `legacyKeyHash = SHA-256(legacyLicenseKey)` and checks `subscriptions` collection. If already migrated on a prior launch, returns `status: "ALREADY_MIGRATED"` and existing `signedLeaseToken` idempotently.
5. On first migration, executes atomic writes (`commitAtomicWrites()`) creating `customers/cus_...`, `installations/inst_...`, and `subscriptions/sub_...` (`planId: 'LEGACY_MIGRATED'`).
6. Issues a fresh base64url HMAC-SHA256 `signedLeaseToken` and records `MIGRATED_LEGACY_RSA_LICENSE` in `audit_logs`.

#### Success Response (`201 Created` / `200 OK`)
```json
{
  "success": true,
  "data": {
    "migrated": true,
    "status": "SUCCESS",
    "customerId": "cus_XNLX3ZD9F8",
    "subscriptionId": "sub_WYEP0KDEOQ",
    "activeInstallationId": "inst_legacy_p5_device",
    "planId": "LEGACY_MIGRATED",
    "expiresAtEpochMs": 1830297599000,
    "signedLeaseToken": "eyJzdWJzY3JpcHRpb25JZCI6InN1Yl9XWUV...signed_jwt"
  }
}
```
