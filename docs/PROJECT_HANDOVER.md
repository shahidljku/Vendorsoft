# VendSoft Project Handover & Continuation Guide

> **Last Updated**: July 18, 2026
> **Architecture Version**: v1.1.0 (Phase 6 Complete)
> **Production Status**: LIVE on Cloudflare Workers

---

## 1. Project Overview

**VendSoft** is an offline-first mobile billing and route management application built for Indian newspaper vendors and distribution agencies. It automates:

- **Customer management** via local Excel spreadsheets (`customers.xlsx`)
- **WhatsApp bill dispatch** in batched safety intervals
- **58mm/80mm Bluetooth thermal receipt printing** for morning delivery routes
- **Hardware-locked licensing** with 30-day free trials and paid monthly/yearly plans

### Technology Stack

| Layer | Technology | Notes |
|---|---|---|
| **Mobile App** | Flutter / Dart (Android) | Offline-first, zero cloud dependency for business data |
| **Backend API** | Cloudflare Workers (TypeScript) | Serverless, sub-5ms cold starts |
| **Database** | Google Cloud Firestore | Control plane metadata only — never user business data |
| **Auth** | Firebase Authentication | Anonymous UIDs, no SMS/email required |
| **Payments** | Razorpay | UPI, Cards, NetBanking with HMAC SHA-256 webhooks |
| **Cryptography** | RSA PKCS#1 v1.5 / Web Crypto | Offline lease token verification |
| **Admin Portal** | Static HTML/JS/CSS on Cloudflare Pages | https://vendsoft-admin.pages.dev |

---

## 2. Documentation Index (Read in This Order)

| # | File | Purpose |
|---|---|---|
| 1 | `docs/PROJECT_HANDOVER.md` | **This file** — Master status & continuation guide |
| 2 | `docs/ARCHITECTURE_STATUS.md` | Formal freeze notice, phase milestones, approved pillars |
| 3 | `docs/SYSTEM_ARCHITECTURE.md` | Component topology, offline-first boundary rules |
| 4 | `docs/FIRESTORE_SCHEMA.md` | Complete schemas for all 10 Firestore collections |
| 5 | `docs/API_SPECIFICATION.md` | REST endpoint specs, headers, payloads |
| 6 | `docs/SECURITY_RULES.md` | Zero Trust identity model, Firestore security policies |
| 7 | `docs/ADMIN_PANEL.md` | Admin Portal capabilities, plan pricing, remote access |
| 8 | `docs/ARCHITECTURE_DECISIONS.md` | Rationale behind key engineering decisions |
| 9 | `docs/PAYMENT_FLOW.md` | Razorpay checkout & webhook pipeline |
| 10 | `docs/PROGRESS_LOG.md` | Chronological session logs with E2E verification proofs |
| 11 | `docs/FUTURE_BACKLOG.md` | Deferred post-v1.0 feature ideas |
| 12 | `docs/AI_DEVELOPMENT_RULES.md` | Rules for AI agents working on this codebase |
| 13 | `docs/PROJECT_KNOWLEDGE_TRANSFER_AND_HANDOVER.md` | Legacy deep knowledge transfer |

---

## 3. Completed Implementation Phases

### Phase 1.1 — Firebase Foundation & Anonymous Auth ✅
- Firebase project `vendorpro-491c4` configured
- Anonymous sign-in on first launch (no SMS/email friction)
- `FlutterSecureStorage` UUID v4 generation for installation tracking

### Phase 1.2 — Workers Control Plane & Catalog API ✅
- Cloudflare Worker deployed at `https://vendsoft-api-worker.vendorproapk.workers.dev`
- `GET /api/v1/config/system` — global config flags (maintenance mode, feature switches)
- `GET /api/v1/plans` — dynamic plan catalog

### Phase 2.1 — Customer Onboarding & Composite Registration ✅
- `POST /api/v1/customers/register` — creates `cus_xxx`, `inst_xxx`, `sub_xxx` atomically
- Composite identity model: `hardwareId` + `installationUuid` + `Firebase UID` + `appVersion`
- Idempotency key deduplication (24-hour locks)
- 30-day `FREE_TRIAL_30` subscription auto-issued on registration

### Phase 2.2 — Offline Lease Engine & P2P Transfers ✅
- `signedLeaseToken` — RSA-signed JWT containing subscription entitlements
- Offline verification via embedded RSA public key in `license_service.dart`
- P2P transfer flow: new device requests → old device polls & approves → subscription migrates
- Transfer endpoints: `POST /transfers/request`, `GET /transfers/pending`, `POST /transfers/approve`, `POST /transfers/reject`

### Phase 3 — Razorpay Payment Checkout & Webhooks ✅
- `POST /api/v1/orders/create` — creates Razorpay order
- `POST /api/v1/webhooks/razorpay` — HMAC SHA-256 verified webhook
- Atomic subscription activation inside Firestore transaction on `order.paid`

### Phase 4 — Security Hardening & Admin Panel ✅
- Admin Portal with customer search, device management, transfer approvals
- Hardware device banning/unbanning
- Audit log trail for all admin actions
- System config toggles (maintenance, registrations, payments, transfers)
- `x-admin-secret` authentication for admin API endpoints

### Phase 5 — Legacy RSA License Sunset ✅
- `POST /api/v1/migrate/legacy-key` — migrates v0.9.x RSA license keys to composite leases
- Preserves original expiration dates, never double-charges
- `LEGACY_MIGRATED` plan ID for tracking

### Phase 6 — Anti-Abuse Enforcement, Device Transfers & Admin Pricing ✅
- **Phone number uniqueness**: Same number cannot register on two devices simultaneously
- **Hardware trial lock**: `hardware_trials/{hardwareId}` prevents trial abuse via reinstalls
- **Samsung Dual Apps protection**: Different `Android ID` per clone = different trial
- **Transfer from registration screen**: `TRANSFER_REQUIRED` error → in-app transfer dialog (no login needed)
- **Admin plan pricing manager**: View/edit plan prices, features, visibility from admin portal
- **Admin transfer approvals**: Lost/broken phone manual recovery via admin portal
- **New security screens**: Device banned, maintenance mode, account deactivated, offline locked
- **Remote config polling**: App checks server config on startup/resume

---

## 4. Codebase Structure

```
e:\image_sender\
├── lib/                              # Flutter app source
│   ├── main.dart                     # Entry point, state routing (ban/maintenance/etc)
│   ├── screens/
│   │   ├── onboarding_screen.dart    # 4-page onboarding + registration
│   │   ├── activation_screen.dart    # Plan selection after trial expires
│   │   ├── main_layout.dart          # Primary app shell, transfer polling
│   │   ├── settings_tab.dart         # Settings, diagnostics, license mgmt
│   │   ├── device_banned_screen.dart  # Hardware block UI
│   │   ├── maintenance_screen.dart   # Server maintenance UI
│   │   ├── account_deactivated_screen.dart
│   │   └── offline_locked_screen.dart
│   ├── services/
│   │   ├── license_service.dart      # Hardware fingerprint, RSA verification, lease storage
│   │   ├── registration_service.dart # POST /customers/register + TransferRequiredException
│   │   ├── transfer_service.dart     # P2P transfer client (request/poll/approve/reject)
│   │   ├── config_service.dart       # Remote config polling
│   │   ├── trial_service.dart        # Trial expiration helpers
│   │   ├── settings_service.dart     # SharedPreferences wrapper
│   │   ├── payment_service.dart      # Razorpay order creation
│   │   └── print_service.dart        # Bluetooth thermal printing
│   └── widgets/
│       └── subscription_dialog.dart  # Razorpay checkout UI
│
├── backend/
│   ├── workers/
│   │   └── src/
│   │       ├── router.ts             # URL routing for all endpoints
│   │       ├── authGuard.ts          # Firebase JWT + admin secret verification
│   │       ├── cryptoEngine.ts       # RSA signing, HMAC, Web Crypto utilities
│   │       ├── types.ts              # TypeScript interfaces (Env, CompositeIdentity, etc)
│   │       ├── webhooks.ts           # Razorpay webhook handler
│   │       ├── routes/
│   │       │   ├── customers.ts      # Registration + uniqueness enforcement
│   │       │   ├── subscriptions.ts  # Subscription status check + trial issuance
│   │       │   ├── transfers.ts      # P2P device transfer endpoints
│   │       │   ├── plans.ts          # Plan catalog endpoint
│   │       │   ├── admin.ts          # Admin CRUD + transfer approvals
│   │       │   ├── orders.ts         # Razorpay order creation
│   │       │   └── migrate.ts        # Legacy RSA license migration
│   │       └── services/
│   │           └── firestore.ts      # Firestore REST API helpers
│   │
│   └── admin-portal/
│       ├── index.html                # Admin Portal UI (deployed to Cloudflare Pages)
│       └── app.js                    # Admin Portal client logic
│
├── docs/                             # All project documentation (this folder)
├── firestore.rules                   # Firestore security rules
├── firestore.indexes.json            # Composite index definitions
└── pubspec.yaml                      # Flutter dependencies
```

---

## 5. Firestore Collections (10 Total)

| Collection | Document ID | Purpose |
|---|---|---|
| `system_configs` | `global` | Feature flags, maintenance mode, version requirements |
| `customers` | `cus_xxxxxxxxx` | Vendor profiles (business name, owner, mobile) |
| `installations` | Hardware ID or `inst_xxx` | Device registrations with hardware fingerprints |
| `subscriptions` | `TRIAL_xxx` or `sub_xxx` | Entitlement ledger with `activeInstallationId` |
| `device_transfers` | `trn_xxxxxxxxx` | P2P and admin transfer requests |
| `plans` | `PRO_MONTHLY`, `PRO_YEARLY`, etc | Pricing catalog |
| `payments` | `order_xxxxxxxxx` | Razorpay transaction tracking |
| `audit_logs` | Auto-generated | Security events and admin actions |
| `idempotency_keys` | UUID | 24-hour deduplication locks |
| `hardware_trials` | Hardware ID | Per-device 30-day trial tracking |

---

## 6. Key API Endpoints

### Public
| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/api/v1/config/system` | Global config flags |
| `GET` | `/api/v1/plans` | Plan catalog |
| `POST` | `/api/v1/webhooks/razorpay` | Payment webhook |

### Authenticated (Firebase JWT + Hardware ID)
| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/api/v1/customers/register` | New vendor registration |
| `GET` | `/api/v1/subscriptions/status` | License status check |
| `POST` | `/api/v1/orders/create` | Create Razorpay order |
| `POST` | `/api/v1/transfers/request` | Request device transfer |
| `GET` | `/api/v1/transfers/pending` | Poll pending transfers |
| `POST` | `/api/v1/transfers/approve` | Approve transfer (old device) |
| `POST` | `/api/v1/transfers/reject` | Reject transfer |
| `POST` | `/api/v1/migrate/legacy-key` | Migrate v0.9.x RSA key |

### Admin (x-admin-secret header)
| Method | Endpoint | Purpose |
|---|---|---|
| `GET` | `/api/v1/admin/customers` | List/search customers |
| `PUT` | `/api/v1/admin/customers/:id` | Edit customer profile/status |
| `PUT` | `/api/v1/admin/devices/:id/ban` | Ban hardware device |
| `PUT` | `/api/v1/admin/devices/:id/unban` | Unban hardware device |
| `GET` | `/api/v1/admin/transfers/pending` | List pending transfers |
| `POST` | `/api/v1/admin/transfers/:id/approve` | Admin approve transfer |
| `POST` | `/api/v1/admin/transfers/:id/reject` | Admin reject transfer |
| `GET` | `/api/v1/admin/config` | Get system configs |
| `PUT` | `/api/v1/admin/config` | Update system configs |
| `GET` | `/api/v1/admin/audit-logs` | List audit events |

---

## 7. Security Architecture

### Composite Identity Model
No single identifier is trusted alone. Every request validates:
- **Firebase UID** (from JWT `Authorization` header)
- **Hardware ID** (SHA-256 of Android ID — `x-hardware-id`)
- **Installation UUID** (FlutterSecureStorage UUID — `x-installation-uuid`)
- **App Version** (`x-app-version`)

### Offline License Verification
The `signedLeaseToken` is an RSA-signed Base64 JSON containing:
- `subscriptionId`, `customerId`, `activeInstallationId`
- `planId`, `planName`, `startsAtEpochMs`, `expiresAtEpochMs`
- `maxCustomers`, `allowWhatsAppAutoSend`, `allowThermalPrinting`

The Flutter app verifies the signature against an embedded RSA public key before trusting the payload. No network required for daily operation.

### Anti-Abuse Layers
1. **Phone number uniqueness** — one active account per mobile number
2. **Hardware trial lock** — one 30-day trial per physical device (survives reinstalls)
3. **Samsung Dual Apps** — different `Android ID` = different device = separate trial
4. **Device banning** — admin can block specific hardware IDs
5. **Account deactivation** — admin can suspend vendor accounts

---

## 8. Deployment & Access

### Production URLs
| Service | URL |
|---|---|
| **API Worker** | https://vendsoft-api-worker.vendorproapk.workers.dev |
| **Admin Portal** | https://vendsoft-admin.pages.dev |
| **GitHub Repo** | https://github.com/shahidljku/VendorPro |

### Deployment Commands
```powershell
# Deploy Cloudflare Worker (backend API)
cd e:\image_sender\backend\workers
npm run deploy

# Deploy Admin Portal (Cloudflare Pages)
cd e:\image_sender\backend\admin-portal
npx wrangler pages deploy . --project-name vendsoft-admin

# Flutter build
cd e:\image_sender
flutter build apk --release
```

### Environment Variables (Cloudflare Worker Secrets)
| Variable | Purpose |
|---|---|
| `GCP_PROJECT_ID` | Firebase/Firestore project ID (`vendorpro-491c4`) |
| `FIREBASE_PROJECT_ID` | Same as above |
| `RSA_PRIVATE_KEY` | RSA private key for signing lease tokens |
| `RAZORPAY_KEY_ID` | Razorpay API key |
| `RAZORPAY_KEY_SECRET` | Razorpay secret for webhook HMAC verification |
| `ENVIRONMENT` | `production` |

---

## 9. Known Issues & Bugs Fixed (July 18, 2026)

| Issue | Root Cause | Fix Applied |
|---|---|---|
| `Failed to verify account uniqueness` | `queryCollection` was used in `customers.ts` but never imported | Added missing import on line 2 |
| `signedLeaseToken cryptographic verification failed` | RSA public key fetch from server was timing out | Public key embedded directly in `license_service.dart` |
| `PERMISSION_DENIED` on Firestore | App was trying to read `installations` collection directly | All Firestore writes go through Workers only; app uses REST API |
| Transfer button useless in settings | User must be logged in to reach settings, defeating the purpose | Transfer trigger moved to registration screen (`onboarding_screen.dart`) |
| Samsung Dual Apps bypass trial | Dual Apps create separate `Android ID` values | Each `Android ID` hash is treated as a separate device |
| `hardware_trials` document ID mismatch | Document was keyed by `installationId` instead of `hardwareId` | Fixed to use `hardwareId` as document ID |

---

## 10. Remaining / Planned Work

### Immediate Priority
- [ ] **Admin Portal remote hosting**: Deployed to Cloudflare Pages at `https://vendsoft-admin.pages.dev` — verify it works on mobile browser
- [ ] **Plan pricing from admin**: Admin sets monthly/yearly prices → reflected in app activation screen
- [ ] **End-to-end transfer test**: Full manual test of new device → old device approval → license migration

### Short-Term Backlog
- [ ] **Google Sign-In**: Allow vendors to bind accounts to Google for cross-device recovery
- [ ] **FCM Push Notifications**: Push transfer approval notifications to old device instead of polling
- [ ] **Cloudflare Access**: Add SSO/2FA to admin portal for production security
- [ ] **Automated recurring billing**: Razorpay e-Mandate for annual auto-renewal

### Long-Term Backlog (see `FUTURE_BACKLOG.md`)
- [ ] Encrypted cloud backups (Google Drive / Cloudflare R2)
- [ ] Multi-device seat management for large agencies
- [ ] Referral/affiliate reward program
- [ ] Lifetime license plan
- [ ] Geo-distribution heatmaps in admin panel
- [ ] WhatsApp Business API renewal reminders

---

## 11. Non-Negotiable Architectural Rules

1. **Never break offline autonomy**: The app must always work fully offline for billing, printing, and WhatsApp dispatch. Network is only needed for registration, license checks, and payments.
2. **Never touch user business data**: Excel files, SQLite ledgers, bills, and receipt images stay strictly on the device. Never sync to Firestore or any server.
3. **Never remove legacy RSA verification**: `verifyLicenseKey()` in `license_service.dart` is a permanent offline fail-safe.
4. **Always verify `signedLeaseToken`**: RSA signature must be mathematically verified before trusting the payload.
5. **Log everything in `PROGRESS_LOG.md`**: Document all changes with runtime verification proofs.
6. **Ask before assuming**: If a request is ambiguous, stop and clarify with the user.

---

## 12. Verification Commands

```powershell
# TypeScript type check (must pass with 0 errors)
cd e:\image_sender\backend\workers
npm run typecheck

# Flutter static analysis (must show "No issues found!")
cd e:\image_sender
flutter analyze

# Deploy to production
cd e:\image_sender\backend\workers
npm run deploy

# Git push
cd e:\image_sender
git add -A && git commit -m "description" && git push origin main
```
