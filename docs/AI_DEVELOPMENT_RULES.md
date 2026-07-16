# Permanent AI Development & Engineering Governance Rules (`Revision v1.0`)

This document defines the mandatory, unshakeable engineering rules for any AI agent, software architect, or developer contributing to the VendSoft codebase. These rules take precedence over general coding style suggestions and must be strictly obeyed during every implementation phase.

---

## 1. Core Codebase Integrity & Stability Rules

### Rule 1: Never Rewrite Stable Code Unnecessarily
If an existing service, helper, or screen is currently working, tested, and production-ready (`LicenseService`, `TrialService`, `ClockGuardService`, `ExcelService`, `PrintService`), **DO NOT** refactor, restructure, or optimize it unless explicitly required to fulfill a specific new requirement. Unnecessary code churn introduces regression bugs into stable offline workflows.

### Rule 2: Extend Before Replacing (`The Strangler Fig Mandate`)
When introducing a new system (such as online Cloudflare Worker licensing or Razorpay checkout), **always extend existing structures first rather than deleting legacy implementations**. New cloud capabilities must wrap or run alongside legacy offline checks (`offline_license_key`). Legacy verification code must remain intact as a fail-safe fallback until migration is 100% verified across the entire production user base.

### Rule 3: Maintain 100% Backward Compatibility
Every architectural addition must preserve compatibility with historical data formats, offline license strings (`getDeviceId()`), and local file layouts (`/storage/emulated/0/VendSoft/customers.xlsx`). A user upgrading from a 2-year-old build to the latest release must experience zero data loss and zero license invalidation.

---

## 2. Phased Execution & Scope Control Rules

### Rule 4: One Architectural Change Per Phase
Never attempt to implement multiple major architectural pillars (such as Firebase onboarding + Razorpay webhooks + Admin transfer approvals) in a single commit or single phase. Every phase must be self-contained, individually testable, and strictly focused on a single architectural objective.

### Rule 5: Never Modify Unrelated Files
When working on a specific task (e.g., updating `main_layout.dart` for onboarding profile collection), **do not touch unrelated files** (such as `receipts_tab.dart`, `sending_screen.dart`, or `whatsapp_service.dart`). Keep pull requests and edits laser-focused on the immediate task boundary.

### Rule 6: Every Critical Phase Must Include Rollback Planning
Before writing code that alters state, storage, or external API communication, an explicit **Rollback Plan** must be established and documented. If a new cloud synchronization loop or database write fails in production, the application must be able to gracefully degrade to local/offline execution without locking the user out or crashing.

---

## 3. Verification & Quality Assurance Rules

### Rule 7: `flutter analyze` Must Pass After Every Implementation Phase
Static analysis is non-negotiable. After modifying or creating any Dart/Flutter source file, `flutter analyze` must be executed and must report **0 issues (`No issues found!`)** before the turn or phase is marked completed. Warnings, lint errors, or type mismatches must be resolved immediately.

### Rule 8: Existing User Workflows Must Not Break
The core daily utility of VendSoft—loading customers from Excel, adding bill entries, generating thermal ESC/POS receipts, and auto-sending WhatsApp invoices—must continue operating with exact behavioral parity (`0ms latency`, `offline-first`). Cloud checks, telemetry heartbeats, or background registration must never block the UI main thread or interrupt active user operations.

---

## 4. Security, Reliability & Architectural Governance Rules

### Rule 9: Security is Always Preferred Over Convenience
If a design choice offers convenience at the expense of security (such as trusting client timestamps, allowing automated device transfers without old device approval, or accepting Business Name/Mobile Number as sole proof of ownership), **choose security without exception**. Never trust the Flutter client application (`Zero-Trust Threat Model`).

### Rule 10: Reliability is Always Preferred Over Speed
In a production billing environment serving thousands of newspaper distributors, correctness, idempotency, and transactional safety (`runTransaction`) are vastly superior to execution shortcuts. Always verify external API responses (`Razorpay Webhooks`), enforce strict locking (`x-idempotency-key`), and handle edge cases (such as network drops right after UPI debit) defensively.

### Rule 11: Documentation Must Be Updated Whenever Architecture Changes
The `docs/` folder (`SYSTEM_ARCHITECTURE.md`, `FIRESTORE_SCHEMA.md`, `API_SPECIFICATION.md`, `SECURITY_RULES.md`, `PAYMENT_FLOW.md`, `ADMIN_PANEL.md`, `IMPLEMENTATION_PLAN.md`, `ARCHITECTURE_DECISIONS.md`) is the **Single Source of Truth**. If an implementation phase requires adjusting a data field, API header, or state transition, the master documentation blueprints inside `docs/` must be updated immediately to maintain 100% internal consistency across the entire project suite.
