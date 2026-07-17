# VendSoft Backend Architecture Status & Freeze Notice

> [!IMPORTANT]
> **GOVERNANCE RULE**: No implementation may redesign architecture without first updating documentation and performing a documented architecture review.

---

## 1. Architecture Freeze Summary

| Metadata Field | Value |
| :--- | :--- |
| **Architecture Version** | `Version 1.0.0-FROZEN` |
| **Current Status** | **FROZEN FOR PRODUCTION IMPLEMENTATION** |
| **Date** | `July 16, 2026` |
| **Freeze Status** | **LOCKED (Permanently Frozen unless genuine implementation blocker discovered)** |
| **Implementation Status** | • **Phase 1.1 (Firebase Foundation & Anonymous Auth)**: **COMPLETED ✅**<br/>• **Phase 1.2 (Workers Control Plane Setup & Catalog/Config API)**: **COMPLETED ✅**<br/>• **Phase 2.1 (Customer Onboarding & Composite Registration)**: **COMPLETED ✅**<br/>• **Phase 2.2 (Offline Lease Engine & Peer-to-Peer Transfers)**: **COMPLETED ✅**<br/>• **Phase 3 (Razorpay Payment Checkout & Webhook Pipeline)**: **COMPLETED ✅**<br/>• **Phase 4 (Security Hardening & Admin Panel Setup)**: **COMPLETED ✅**<br/>• **Phase 5 (Production Migration & Legacy System Sunset)**: **COMPLETED ✅** |

---

## 2. Approved Architectural Pillars (`Version 1.0 Frozen`)

### 2.1 Approved Technologies
- **Client Application**: Flutter / Dart (Offline-First, Zero-Trust boundary).
- **Control Plane**: Cloudflare Workers (V8 Serverless JS/TS Isolates, sub-5ms cold starts).
- **State Database**: Google Cloud Firestore (Strictly application metadata, control plane state, and real-time polling/snapshots).
- **Authentication Engine**: Firebase Authentication (Anonymous UIDs issued on first launch without SMS friction).
- **Payment Gateway**: Razorpay (UPI, Cards, NetBanking with HMAC SHA-256 webhooks).
- **Cryptographic Engine**: Web Crypto Ed25519 / RSA local lease verification (`signedLeaseToken`).

### 2.2 Approved Database Design (9 Firestore Collections)
1. **`/system_configs/global`**: Server-controlled global configuration flags (`allowRegistrations`, `allowPayments`, `allowTransfers`, `maintenanceMode`, `minimumSupportedVersion`). Read-only for client.
2. **`/customers/{customerId}`**: Immutable customer profiles (`cus_xxxxxxxxx`). `businessName` and `mobileNumber` are editable display metadata only (`Not primary keys`).
3. **`/installations/{installationId}`**: Hardware and storage telemetry (`inst_xxxxxxxxx` / `installationUuid`).
4. **`/subscriptions/{subscriptionId}`**: Entitlement ledger (`sub_xxxxxxxxx`) enforcing `activeInstallationId`.
5. **`/device_transfers/{transferId}`**: Secure peer-to-peer and admin transfer requests (`trn_xxxxxxxxx`) with 24-hour expiration locks (`serverTimestamp() + 24 hours`).
6. **`/plans/{planId}`**: Pricing and tier catalog (`DEMO_FREE`, `PRO_MONTHLY`, `PRO_YEARLY`).
7. **`/payments/{paymentId}`**: Financial transaction tracking (`order_xxxxxxxxx`).
8. **`/audit_logs/{logId}`**: Immutable security event and manual admin action logs.
9. **`/idempotency_keys/{keyId}`**: 24-hour deduplication locks for state-changing endpoints.

### 2.3 Approved Identity Model (Composite Hybrid Anchor)
No single identifier is trusted individually. Authentication and entitlement evaluation strictly check:
- **`customerId`** (`cus_xxxxxxxxx` - Immutable business account key)
- **`installationId`** (`inst_xxxxxxxxx` - Primary installation document ID)
- **`hardwareId`** (`LicenseService().getDeviceId()` - SHA-256 of `ANDROID_ID`, preserved for backward compatibility)
- **`installationUuid`** (`FlutterSecureStorage` UUID v4 - Eliminates `UNKNOWN_DEVICE` collisions)
- **`Firebase UID`** (`uid` - Auth session JWT bearer token)

### 2.4 Approved Payment Model
- **Razorpay Server-to-Server Webhooks (`POST /webhooks/razorpay`)**: All subscription activations occur inside atomic Firestore `runTransaction` blocks triggered by authenticated HMAC SHA-256 webhooks (`order.paid`).
- **One Active Device Rule**: When a payment settles, `subscriptions.activeInstallationId` is set strictly to the `installationId` that initiated the order (`payment.installationId`).

### 2.5 Approved Device Transfer Model
- **Normal Case (`Peer-to-Peer Old Device Approval`)**: New device requests transfer (`POST /transfers/request`). Old device receives notification via **Mandatory Background/App-Foreground Polling (`GET /transfers/pending`) or Optional FCM Push Notification**. Old device approves (`POST /transfers/approve`). Worker switches `activeInstallationId` to new device and revokes old device. No admin required. System remains 100% functional even if push notifications are disabled or undelivered.
- **Lost or Broken Phone Case (`Admin Manual Recovery`)**: If old device is lost/stolen/broken and cannot approve, vendor contacts customer support. Support Lead verifies identity out-of-band and clicks **"Approve Manual Transfer"** in Admin Panel (`POST /admin/transfers/approve`). This is the **ONLY** manual recovery flow.

### 2.6 Approved Security Model
- **Zero-Trust Client Boundary**: The Flutter application and device clock are never trusted. All licensing rights require an unexpired server-signed `signedLeaseToken` bounded to `activeInstallationId`.
- **Principle of Least Privilege (`firestore.rules`)**: Flutter clients have `allow write: if false` on all critical collections (`system_configs`, `plans`, `customers`, `installations`, `subscriptions`, `device_transfers`, `payments`). Only Cloudflare Workers via Service Account credentials can write to the control plane.
- **Data Sovereignty**: User Business Data (`customers.xlsx`, ledger rows, bills, receipt images) must **NEVER** be saved in Firestore or transmitted to any cloud server (`100% local storage and local backup autonomy`).
