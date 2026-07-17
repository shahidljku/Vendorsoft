# AI Continuation Guide & Project Handover (`Version 1.0 Frozen`)

This document is the **authoritative starting point** for any future AI assistant, developer, or DevOps engineer continuing work on **VendSoft**.

> [!IMPORTANT]
> **MANDATORY GOVERNANCE RULE**: All 5 phases (`Phase 1.1` through `Phase 5`) of the Phased Backend Architecture Roadmap are **100% COMPLETED, VERIFIED, AND FROZEN**. 
> **Do NOT assume, hallucinate, duplicate, rewrite, or redesign any part of the existing codebase or backend architecture.**

---

## 1. Single Source of Truth Hierarchy

Before modifying any file, writing code, or making architectural suggestions, you MUST review the following documentation files in order:
1. `docs/PROJECT_HANDOVER.md` (This file — Current complete status and verification commands)
2. `docs/ARCHITECTURE_STATUS.md` (Formal freeze notice and completed phase milestones)
3. `docs/IMPLEMENTATION_PLAN.md` (Detailed phase objectives and completed checklists)
4. `docs/SYSTEM_ARCHITECTURE.md` (Master component topology and offline-first boundary rules)
5. `docs/FIRESTORE_SCHEMA.md` (Complete schemas for all 9 Firestore collections)
6. `docs/API_SPECIFICATION.md` (REST payload specifications, headers, and endpoints across `/v1/*` and `/v1/admin/*`)
7. `docs/SECURITY_RULES.md` (Zero Trust composite identity rules and Firestore security policies)
8. `docs/ARCHITECTURE_DECISIONS.md` (Rationale behind key engineering decisions)
9. `docs/PROGRESS_LOG.md` (Chronological runtime proof and actual E2E test verification logs)
10. `docs/FUTURE_BACKLOG.md` (Evaluated post-v1.0 feature ideas — **do NOT implement unless explicitly asked**)

---

## 2. Completed Roadmap Summary (`v1.0 100% Complete`)

| Phase | Description | Status | Verification Script / Proof |
| :--- | :--- | :--- | :--- |
| **Phase 1.1** | Firebase Foundation & Anonymous Device Registration | **COMPLETED ✅** | `lib/services/firebase_installation_service.dart` |
| **Phase 1.2** | Cloudflare Workers Control Plane Setup & Catalog API | **COMPLETED ✅** | `backend/workers/verify_phase_1.ps1` |
| **Phase 2.1** | Customer Onboarding & Composite Identity Registration | **COMPLETED ✅** | `backend/workers/verify_phase_2.ps1` |
| **Phase 2.2** | Offline Lease Engine (`signedLeaseToken`) & P2P Transfers | **COMPLETED ✅** | `backend/workers/verify_phase_2.ps1` |
| **Phase 3** | Razorpay Payment Checkout & Webhook Pipeline (`runTransaction`) | **COMPLETED ✅** | `backend/workers/verify_phase_3.ps1` |
| **Phase 4** | Security Hardening, Audit Trails & Admin Web Portal | **COMPLETED ✅** | `backend/workers/verify_phase_4.ps1` |
| **Phase 5** | Legacy RSA License Sunset & Graceful Migration Engine | **COMPLETED ✅** | `backend/workers/verify_phase_5.ps1` |

---

## 3. Codebase Structure & Key File Locations

```text
e:\image_sender\
├── backend/
│   ├── admin-portal/              # Dark-themed Admin Web Dashboard (Phase 4)
│   │   ├── index.html             # Single-Page Application UI
│   │   ├── style.css              # Glassmorphism design system
│   │   └── app.js                 # API controller (Dual target: Local 8788 or Production Edge)
│   └── workers/                   # Cloudflare Workers Serverless Control Plane (api.vendsoft.app)
│       ├── src/
│       │   ├── index.ts           # Worker entry point & unhandled exception boundary
│       │   ├── router.ts          # API Gateway router (/v1/* and /v1/admin/*)
│       │   ├── authGuard.ts       # Composite Identity & Admin Zero Trust authenticator
│       │   ├── cryptoEngine.ts    # Web Crypto RSA-SHA256 & HMAC-SHA256 lease signing
│       │   ├── webhooks.ts        # Razorpay HMAC SHA-256 webhook handler
│       │   ├── types.ts           # Env bindings, CompositeIdentity & config definitions
│       │   ├── routes/
│       │   │   ├── config.ts      # GET /v1/config/system
│       │   │   ├── customers.ts   # POST /v1/customers/register
│       │   │   ├── subscriptions.ts # GET /v1/subscriptions/status
│       │   │   ├── transfers.ts   # P2P device transfers (/request, /pending, /approve, /reject)
│       │   │   ├── orders.ts      # POST /v1/orders/create & /verify
│       │   │   ├── admin.ts       # Control plane endpoints (/customers, /transfers/approve, /config, /audit-logs)
│       │   │   └── migrate.ts     # POST /v1/migrate/legacy-key (Phase 5 legacy claiming)
│       │   └── services/
│       │       └── firestore.ts   # Local dev in-memory datastore & production REST Service Account connector
│       ├── wrangler.toml          # Worker runtime configuration & secrets mapping
│       ├── verify_phase_1.ps1     # Automated E2E verification for Phase 1.2
│       ├── verify_phase_2.ps1     # Automated E2E verification for Phase 2.1 & 2.2
│       ├── verify_phase_3.ps1     # Automated E2E verification for Phase 3
│       ├── verify_phase_4.ps1     # Automated E2E verification for Phase 4
│       └── verify_phase_5.ps1     # Automated E2E verification for Phase 5
├── docs/                          # Authoritative project documentation suite
├── firestore.indexes.json         # Deployed composite indexes for Cloud Firestore
├── firestore.rules                # Deployed Principle of Least Privilege security rules
└── lib/                           # Flutter Client Application (Offline-First)
    ├── main.dart                  # Application entry point & service initialization
    ├── screens/
    │   ├── activation_screen.dart # Activation UI with dynamic Razorpay checkout & legacy claiming
    │   └── onboarding_screen.dart # First-launch customer registration modal
    └── services/
        ├── firebase_installation_service.dart # Anonymous identity registration
        ├── license_service.dart    # Hybrid RSA + base64url signed lease verification & Phase 5 migration
        ├── onboarding_service.dart # POST /v1/customers/register client wrapper
        ├── payment_service.dart    # Razorpay checkout & order creation wrapper
        └── transfer_service.dart   # Peer-to-Peer transfer request & polling wrapper
```

---

## 4. Verification & Testing Commands (How to Prove Correctness)

Before modifying anything, always run these verification gates to verify the clean baseline state:

### 1. TypeScript Control Plane Type Check
```powershell
cd e:\image_sender\backend\workers
npm run typecheck
```
*Expected output*: `tsc --noEmit` completes cleanly with **0 errors**.

### 2. Flutter Client Static Analysis
```powershell
cd e:\image_sender
flutter analyze
```
*Expected output*: `No issues found!` across all Dart files.

### 3. Local Serverless Runtime Verification (Miniflare Emulator)
To execute automated end-to-end tests against the Cloudflare Worker without touching production:
1. Start the local Miniflare dev server in one terminal:
   ```powershell
   cd e:\image_sender\backend\workers
   npx wrangler dev --port 8788
   ```
2. Run the automated Phase verification scripts in another terminal:
   ```powershell
   cd e:\image_sender\backend\workers
   powershell -ExecutionPolicy Bypass -File verify_phase_4.ps1
   powershell -ExecutionPolicy Bypass -File verify_phase_5.ps1
   ```
*Expected output*: Both scripts complete successfully (`Status=SUCCESS`, exact document structures confirmed, idempotency proven, and immutable audit logs verified).

---

## 5. Non-Negotiable Architectural Mandates for Next Agent

1. **Never Break Offline Autonomy**: The Flutter app must always be able to launch and operate fully offline in remote areas (`LicenseService.isLicensed()` checking `_signedLeaseTokenPref` and falling back to legacy RSA `_licenseKeyPref`).
2. **Never Touch User Business Data**: Excel files (`customers.xlsx`), SQLite ledgers, monthly bills, and receipt images reside strictly on the user's local device storage. Never attempt to sync or upload them to Firestore or any server.
3. **Never Remove Legacy RSA Verification**: `verifyLicenseKey()` inside `license_service.dart` is a permanent offline fail-safe. Do not delete or refactor it out.
4. **Log Everything in `PROGRESS_LOG.md`**: Any task performed must be documented with actual runtime verification proofs inside `docs/PROGRESS_LOG.md` before completion.
5. **Ask Before Assuming**: If the user's request is underspecified or conflicts with frozen documentation, stop and ask the user for clarification rather than making assumptions.
