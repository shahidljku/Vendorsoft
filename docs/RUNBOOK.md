# VendSoft Cloudflare Workers Runbook

This runbook defines the operational procedures for managing incidents, rollbacks, and secret rotations for the VendSoft Control Plane.

## 1. Rollback Strategy

Rollbacks are procedural, not discretionary. If any of the following triggers are met during or immediately after a deployment, the on-call engineer MUST initiate a rollback.

### 1.1 Rollback Triggers
*   **Deployment Failure**: The GitHub Actions `deploy_production` workflow fails.
*   **Diagnostics Unhealthy**: `GET /v1/admin/diagnostics` returns a `503` or reports a critical internal component (e.g., Firestore probe) as degraded.
*   **Smoke Tests Fail**: The post-deployment synthetic transaction (e.g., synthetic Razorpay order creation) fails.
*   **Error Rate Exceeds Threshold**: HTTP 5xx responses exceed 1% of total traffic over a 5-minute window post-deployment.
*   **Latency Regression**: P95 latency for `POST /v1/orders/create` exceeds the `150ms` budget by more than 2x for 5 consecutive minutes.

### 1.2 Execution
To roll back the Cloudflare Worker to the previous stable state:
1. Identify the previous stable GitHub Release tag (e.g., `v1.0.0`).
2. Run locally or via CI:
   ```bash
   npx wrangler rollback --env production
   ```
   *(Cloudflare Workers natively supports instant rollbacks to previous uploads)*
3. Verify `/v1/admin/diagnostics` reflects the rolled-back `WORKER_VERSION`.

---

## 2. Secrets Management & Rotation

The VendSoft API relies on critical infrastructure secrets injected via `wrangler secret put`.

### 2.1 Rotation Cadence
*   **Firestore Service Account (`FIRESTORE_SA_KEY`)**: Rotated every 90 days via GCP IAM.
*   **Razorpay Keys (`RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`)**: Rotated every 180 days via the Razorpay Dashboard.
*   **Razorpay Webhook Secret (`RAZORPAY_WEBHOOK_SECRET`)**: Rotated annually.
*   **JWT Signing Key (`RSA_PRIVATE_KEY`)**: Rotated annually.

### 2.2 Rotation Procedure
1. Generate the new secret in the provider dashboard (GCP / Razorpay).
2. Upload the new secret to Cloudflare:
   ```bash
   npx wrangler secret put FIRESTORE_SA_KEY --env production
   ```
3. Cloudflare Workers will automatically restart and inject the new binding.
4. **Verification**: Immediately execute the Functional Smoke Test (`npm run test:smoke`) to verify the new secret authorizes successfully against the external provider.
5. **Deactivation**: Wait 24 hours (to ensure no in-flight asynchronous operations rely on the old secret), then delete/revoke the old key from the provider dashboard.

### 2.3 Emergency Rotation
If a secret is suspected of being compromised, immediately invoke the Rotation Procedure (2.2), followed *immediately* by Deactivation (Step 5). Notify all active clients of potential disruption during the rotation window.

---

## 3. Incident Response

If an alert fires but a rollback is NOT triggered (e.g., a localized bug):
1. **Assess Impact**: Check the Datadog / Cloudflare Telemetry dashboards.
2. **Review Diagnostics**: Hit `GET /v1/admin/diagnostics` to verify infrastructure connectivity.
3. **Check KV Rate Limits**: If legitimate users are blocked, ensure `APK_STORE` is not experiencing an outage forcing fail-closed behavior on mutation endpoints.
