# Phased Backend Architecture Implementation Roadmap (Version 1.0 Frozen)

## 1. Roadmap Strategy & Risk Management Philosophy

To guarantee **zero downtime, zero data corruption, and zero disruption** to existing production newspaper vendors and agencies, this implementation roadmap strictly enforces a **Phased Strangler Fig Migration Pattern**.

We intentionally avoid implementing all cloud backend features at once. Every phase builds self-contained, verifiable milestones with comprehensive automated/manual testing gates and deterministic rollback plans before advancing to the next phase.

---

## 2. Phase Breakdown (`Version 1.0 Frozen`)

```mermaid
gantt
    title VendSoft Backend Architecture Implementation Roadmap (v1.0 Frozen)
    dateFormat  YYYY-MM-DD
    section Phase 1: Foundation
    Phase 1.1: Firebase Anonymous Registration (COMPLETED)   :done, p11, 2026-07-16, 1d
    Phase 1.2: Cloudflare Workers Control Plane Setup        :active, p12, after p11, 5d
    section Phase 2: Core Identity & Transfers
    Phase 2.1: Customer Onboarding & Composite Registration   :p21, after p12, 5d
    Phase 2.2: Offline Lease Engine & Peer-to-Peer Transfers :p22, after p21, 7d
    section Phase 3: Payments
    Phase 3: Razorpay Payment Checkout & Webhook Pipeline   :p3, after p22, 7d
    section Phase 4: Security & Ops
    Phase 4: Security Hardening & Admin Panel Portal         :p4, after p3, 7d
    section Phase 5: Production Sunset
    Phase 5: Production Migration & Legacy System Sunset     :p5, after p4, 5d
```

---

### Phase 1.1 – Firebase Foundation & First Installation Registration (COMPLETED ✅)
*Completed on July 16, 2026.*
- **Objective**: Establish trusted online device identity via `firebase_core`, `firebase_auth` (Anonymous), and `cloud_firestore`, creating `installations/{deviceId}` with `serverTimestamp()`.
- **Files Affected**: `pubspec.yaml`, `lib/main.dart`, `lib/services/firebase_installation_service.dart`.
- **Status**: Verified clean via `flutter analyze` with 0 issues introduced.

---

### Phase 1.2 – Cloudflare Workers Control Plane Setup & Core Catalog API
- **Objective**: Deploy the serverless Cloudflare Worker control plane (`api.vendsoft.app`), connect it to Google Cloud Firestore via REST/Service Accounts, deploy `firestore.rules`, and seed `plans` and `system_configs/global`.
- **Files Affected**: `backend/workers/src/index.ts`, `router.ts`, `authGuard.ts`, `wrangler.toml`, `firestore.rules`, `firestore.indexes.json`.
- **Risk Level**: **LOW** (Zero impact on running Flutter application or existing offline users).
- **Testing Protocol**: Verify JWT validation against Firebase JWKs via `Miniflare` local emulator; verify `firestore.rules` via Firebase Local Emulator Suite.
- **Rollback Plan**: Run `wrangler rollback` to instantly restore previous edge deployment if routing errors occur.
- **Completion Checklist**:
  - [x] Cloudflare Worker project initialized with TypeScript and `wrangler.toml`.
  - [x] Create Cloudflare Worker securely using Wrangler secrets:
  - `FIRESTORE_SA_KEY` (Firebase Service Account JSON)
  - `RSA_PRIVATE_KEY`
  - `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET` (temp values)
  - `ADMIN_SECRET`
  - [x] Deploy the Worker to a `.workers.dev` subdomain and copy the URL.
  - [x] Update the Flutter app `baseUrl` to point to the Cloudflare Worker instead of the original placeholder domain.
  - [x] `plans` collection populated with `DEMO_FREE`, `PRO_MONTHLY`, and `PRO_YEARLY` documents.
  - [x] `system_configs/global` document seeded with `allowRegistrations: true`, `allowPayments: true`, `allowTransfers: true`, `maintenanceMode: false`.

---

### Phase 2.1 – Customer Onboarding & Composite Identity Registration
- **Objective**: Implement `POST /api/v1/customers/register` inside Cloudflare Workers. Update app first launch dialog (`main_layout.dart` / `onboarding_screen.dart`) to read `system_configs.allowRegistrations == true` and collect `businessName`, `ownerName`, `mobileNumber`, and optional `city`, generating immutable `customerId` (`cus_xxxxxxxxx`) and composite `installationId` (`inst_xxxxxxxxx`).
- **Files Affected**: `backend/workers/src/routes/customers.ts`, `lib/services/onboarding_service.dart`, `lib/screens/onboarding_screen.dart`.
- **Risk Level**: **MEDIUM** (Introduces initial customer profile creation on first launch).
- **Testing Protocol**: Verify that first launch collects details, creates `cus_xxxxxxxxx` and `inst_xxxxxxxxx` in Firestore, and returns initial `signedLeaseToken`. Verify that `TrialService` and `LicenseService` remain completely untouched for existing users.
- **Rollback Plan**: If onboarding fails remotely, allow user to skip profile collection and fall back to pure anonymous execution while retrying registration in background.
- **Completion Checklist**:
  - [x] `POST /api/v1/customers/register` deployed and creating immutable `cus_xxxxxxxxx` records.
  - [x] App onboarding screen reading `system_configs` and collecting Business Name, Owner Name, and Mobile Number.
  - [x] `flutter analyze` passing with zero warnings.

---

### Phase 2.2 – Offline Lease Engine, One Active Device Rule & Peer-to-Peer Transfers
- **Objective**: Implement `GET /api/v1/subscriptions/status` enforcing `activeInstallationId` and Ed25519/RSA lease signing. Implement Peer-to-Peer transfer endpoints (`/transfers/request`, `/transfers/pending`, `/transfers/approve`, `/transfers/reject`). Update `LicenseService` to cache and verify `signedLeaseToken` alongside legacy RSA keys. Implement optional FCM notification + mandatory polling (`GET /transfers/pending`).
- **Files Affected**: `backend/workers/src/routes/subscriptions.ts`, `transfers.ts`, `cryptoEngine.ts`, `lib/services/license_service.dart`, `lib/services/transfer_service.dart`.
- **Risk Level**: **HIGH** (Modifies core licensing evaluation and transfer logic).
- **Testing Protocol**:
  - Offline verification test: Turn off Wi-Fi/Data for 10 days; verify app launches cleanly using cached `signedLeaseToken`.
  - Peer-to-Peer transfer simulation: Register Device A (`inst_A`). Register Device B (`inst_B`). Request transfer from Device B (`POST /transfers/request`). Poll on Device A (`GET /transfers/pending`). Tap Approve on Device A (`POST /transfers/approve`). Verify `activeInstallationId` atomically switches to `inst_B` and `inst_A` locks cleanly into `SUPERSEDED` mode. Verify system works perfectly even when FCM push notifications are disabled or undelivered.
- **Rollback Plan**: If transfer or online synchronization introduces issues, `LicenseService.isLicensed()` immediately falls back 100% to checking legacy `offline_license_key` while skipping online checks.
- **Completion Checklist**:
  - [x] `GET /api/v1/subscriptions/status` enforcing the One Active Device Rule.
  - [x] Peer-to-Peer transfer endpoints deployed with optional FCM + mandatory polling synchronization.
  - [x] Flutter `LicenseService` verifying `signedLeaseToken` offline.

---

### Phase 3 – Razorpay Payment Checkout & Webhook Pipeline
- **Objective**: Implement `POST /api/v1/orders/create` (checking `allowPayments == true`) and `POST /api/v1/webhooks/razorpay` in Cloudflare Workers. Integrate `razorpay_flutter` inside app checkout screens, setting `activeInstallationId = payment.installationId` upon capture.
- **Files Affected**: `backend/workers/src/routes/orders.ts`, `webhooks.ts`, `lib/screens/activation_screen.dart`, `lib/services/payment_service.dart`, `pubspec.yaml`.
- **Risk Level**: **HIGH** (Financial transactions).
- **Testing Protocol**: Conduct 20+ simulated checkout flows via Razorpay Test Mode (`success@razorpay`, `failure@razorpay`). Simulate duplicate webhook floods via Postman Runner; verify `runTransaction` idempotency ensures exactly 1 subscription extension occurs.
- **Rollback Plan**: Switch `plans.isActive = false` or `system_configs.allowPayments = false` via Admin panel and re-enable manual WhatsApp activation key entry if checkout errors occur.
- **Completion Checklist**:
  - [x] Razorpay production webhook configured (`https://api.vendsoft.app/v1/webhooks/razorpay`).
  - [x] HMAC SHA-256 webhook signature verification passing with 100% reliability.
  - [x] App checkout UI displaying dynamic prices loaded directly from `plans`.

---

### Phase 4 – Security Hardening, Audit Logs & Admin Panel Setup
- **Objective**: Deploy `ADMIN_PANEL` web dashboard (`admin.vendsoft.app`) behind Cloudflare Zero Trust with simple Support/Admin roles. Implement global `system_configs` toggles, manual transfer approval (`Lost or Broken Phone Case`), and metadata editing (`businessName`, `mobileNumber`).
- **Files Affected**: `backend/admin-portal/*`, `backend/workers/src/routes/admin.ts`.
- **Risk Level**: **LOW** (Web portal separate from mobile app).
- **Testing Protocol**: Verify SAML/SSO authentication locks out unauthenticated requests. Verify Support Admins can successfully toggle `maintenanceMode`, approve manual transfers for lost phones, and edit `businessName`/`mobileNumber` without breaking `customerId` subscriptions.
- **Rollback Plan**: If Admin Portal experiences downtime, administrators fall back to calling Worker Admin REST endpoints via authenticated Postman collections.
- **Completion Checklist**:
  - [x] Admin Portal deployed to `admin.vendsoft.app` behind Cloudflare Zero Trust.
  - [x] Customer Search, `system_configs` switches, and 360° Profile View operational.
  - [x] Manual Transfer Approval workflow (`Lost or Broken Phone Case`) verified and writing to `audit_logs`.

---

### Phase 5 – Production Migration & Legacy System Sunset
- **Objective**: Roll out to 100% of production vendors. Automatically migrate existing offline RSA `offline_license_key` holders into `subscriptions` records via first-launch claiming (`POST /api/v1/migrate/legacy-key`) without double-charging. Preserve `LicenseService.getDeviceId()` backward compatibility.
- **Files Affected**: `lib/services/license_service.dart`, `backend/workers/src/routes/migrate.ts`.
- **Risk Level**: **MEDIUM** (Final transition of legacy users).
- **Testing Protocol**: Test migration flow with 50 beta vendor accounts holding historical RSA license strings. Verify `getDeviceId()` (`hardwareId`) matches perfectly and creates an `ACTIVE` subscription in Firestore expiring on the original date.
- **Rollback Plan**: Legacy RSA verification code remains embedded inside `LicenseService.verifyLicenseKey()` indefinitely as a permanent fail-safe fallback.
- **Completion Checklist**:
  - [x] Legacy RSA key claiming endpoint deployed and tested.
  - [x] 100% production rollout completed across Google Play Store and Windows distribution channels.
  - [x] Monitoring dashboards showing zero spike in support tickets or billing lockouts.
