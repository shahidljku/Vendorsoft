# AI Continuation Guide & Project Handover (`Version 1.0 Frozen`)

> [!IMPORTANT]
> **DEFINITIVE MASTER KNOWLEDGE TRANSFER DOCUMENT**
> For the complete, exhaustive knowledge transfer containing all architectural reasoning, memory transfer, historical gotchas, verification commands, and non-negotiable rules, you **MUST read [docs/PROJECT_KNOWLEDGE_TRANSFER_AND_HANDOVER.md](file:///e:/image_sender/docs/PROJECT_KNOWLEDGE_TRANSFER_AND_HANDOVER.md) first before doing anything else.**

---

## 1. Single Source of Truth Hierarchy

Before modifying any file, writing code, or making architectural suggestions, you MUST review the following documentation files in order:
1. `docs/PROJECT_KNOWLEDGE_TRANSFER_AND_HANDOVER.md` (Master Knowledge Transfer — Read First!)
2. `docs/PROJECT_HANDOVER.md` (This file — Quick reference & status)
3. `docs/ARCHITECTURE_STATUS.md` (Formal freeze notice and completed phase milestones)
4. `docs/IMPLEMENTATION_PLAN.md` (Detailed phase objectives and completed checklists)
5. `docs/SYSTEM_ARCHITECTURE.md` (Master component topology and offline-first boundary rules)
6. `docs/FIRESTORE_SCHEMA.md` (Complete schemas for all 9 Firestore collections)
7. `docs/API_SPECIFICATION.md` (REST payload specifications, headers, and endpoints across `/v1/*` and `/v1/admin/*`)
8. `docs/SECURITY_RULES.md` (Zero Trust composite identity rules and Firestore security policies)
9. `docs/ARCHITECTURE_DECISIONS.md` (Rationale behind key engineering decisions)
10. `docs/PROGRESS_LOG.md` (Chronological runtime proof and actual E2E test verification logs)
11. `docs/FUTURE_BACKLOG.md` (Evaluated post-v1.0 feature ideas — **do NOT implement unless explicitly asked**)

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

See `docs/PROJECT_KNOWLEDGE_TRANSFER_AND_HANDOVER.md Section 2` for the full annotated file tree.

---

## 4. Verification & Testing Commands (How to Prove Correctness)

### 1. TypeScript Control Plane Type Check
```powershell
cd e:\image_sender\backend\workers
npm run typecheck
```
*Expected output*: `tsc --noEmit` completes cleanly with **0 errors**.

### 2. Flutter Client Static Analysis
```powershell
cd e:\image_sender
flutter analyze lib/services/
```
*Expected output*: `No issues found!` across all Dart files.

### 3. Local Serverless Runtime Verification (Miniflare Emulator)
```powershell
cd e:\image_sender\backend\workers
npx wrangler dev --port 8788
# In a second terminal:
powershell -ExecutionPolicy Bypass -File verify_phase_4.ps1
powershell -ExecutionPolicy Bypass -File verify_phase_5.ps1
```

---

## 5. Non-Negotiable Architectural Mandates for Next Agent

1. **Never Break Offline Autonomy**: The Flutter app must always be able to launch and operate fully offline in remote areas (`LicenseService.isLicensed()` checking `_signedLeaseTokenPref` and falling back to legacy RSA `_licenseKeyPref`).
2. **Never Touch User Business Data**: Excel files (`customers.xlsx`), SQLite ledgers, monthly bills, and receipt images reside strictly on the user's local device storage. Never attempt to sync or upload them to Firestore or any server.
3. **Never Remove Legacy RSA Verification**: `verifyLicenseKey()` inside `license_service.dart` is a permanent offline fail-safe. Do not delete or refactor it out.
4. **Log Everything in `PROGRESS_LOG.md`**: Any task performed must be documented with actual runtime verification proofs inside `docs/PROGRESS_LOG.md` before completion.
5. **Ask Before Assuming**: If the user's request is underspecified or conflicts with frozen documentation, stop and ask the user for clarification rather than making assumptions.
