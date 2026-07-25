# Security Baseline v1 (Phase 8 Completion)

This document formalizes the production security posture of the VendSoft Control Plane at the conclusion of Phase 8 (Security Hardening). Any future features or deployments MUST maintain or exceed these established guardrails.

## 1. Authentication Mechanisms
*   **Public Client API**: Enforced via `authGuard.authenticateRequest`. Requires a cryptographically verified Firebase ID Token (`RSASSA-PKCS1-v1_5` via Google JWKS) AND mandatory composite identity headers (`x-hardware-id`, `x-installation-uuid`, `x-app-version`, `x-platform`).
*   **Admin API**: Enforced via `authGuard.authenticateAdminRequest`. Validates Firebase ID Token and strictly cross-references the UID against the `admin_users` Firestore collection.
*   **Zero-Trust Identity**: `hardware_ban` checks prevent compromised or abusive devices from accessing protected resources regardless of their JWT validity.

## 2. Authorization (RBAC Model v1)
*   **Strict Resource-Oriented Permissions**: Permissions are decoupled from generic roles (e.g., `CUSTOMERS_READ`, `DEVICES_BAN`, `TRANSFERS_APPROVE`).
*   **Fail-Closed Edge Enforcement**: The API Router maps HTTP Methods and paths to strict `Permission` constants *before* invoking authentication. Missing mappings default to `FULL_ACCESS`, preventing accidental exposure.
*   **Matrix**: Refer to [AUTHORIZATION_MATRIX.md](AUTHORIZATION_MATRIX.md) for the active mapping.

## 3. Rate-Limit Policies (Abuse Prevention)
Rate limits are globally centralized in Cloudflare KV via `RateLimitPolicies` and categorized by failure semantics:
*   **Mutations (Fail-Closed)**: `ORDER_CREATION` (5/min), `TRANSFER_REQUEST` (3/hour), and `ADMIN_API` (60/min) explicitly reject requests (`fail_closed`) if the underlying KV infrastructure is degraded, preventing abuse of sensitive pathways.
*   **Reads (Fail-Open)**: General `PUBLIC_API` thresholds prioritize business continuity during infrastructure degradation.

## 4. Audit Logging Behavior
*   **Asynchronous & Best-Effort**: `logAuditEvent` leverages Cloudflare Worker's `ctx.execCtx?.waitUntil()`. Audit logging executes in the background and will *never* block the main execution thread or fail a core business operation (like a customer payment).
*   **Structured Telemetry**: Secrets and PII are structurally scrubbed before emission to Datadog/Firestore.

## 5. Security Headers
*   **100% Coverage**: All Worker responses (200 OK, 404 Not Found, 500 Errors, CORS Preflights) are intercepted at the `fetch` boundary in `index.ts`.
*   **Active Headers**:
    *   `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`
    *   `X-Content-Type-Options: nosniff`
    *   `Referrer-Policy: strict-origin-when-cross-origin`
    *   `Content-Security-Policy: default-src 'none'; frame-ancestors 'none';`
    *   `Permissions-Policy: geolocation=(), camera=(), microphone=()`

## 6. Threat Model Version
*   **Current Iteration**: `Phase 8 Extended` (See [SECURITY_RULES.md](SECURITY_RULES.md)).
*   **Covered Vectors**: JWT Forgery, Privilege Escalation (Horizontal/Vertical), Brute Force, Webhook Replay, Credential Leakage, Request Floods, and Supply Chain Compromise.

## 7. Verification Status
*   **Static Analysis**: `tsc --noEmit` clean across all control plane boundaries.
*   **Regression Suite**: 41 active tests executing locally simulating all health probes, webhook replays, device transfers, and authorization guardrails.
