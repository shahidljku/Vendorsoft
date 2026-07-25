# VendSoft Production Deployment Checklist

This operational checklist MUST be completed prior to and immediately following every deployment to the `production` environment.

## Pre-Deployment (Staging Verification)

- [ ] **Quality Gate Passed**: The `deploy_staging` GitHub Action completed successfully (TypeScript, Vitest, Lint, Formatting all clean).
- [ ] **Staging Smoke Tests Passed**: Automated functional smoke tests passed against the staging environment.
- [ ] **Data Migrations**: If applicable, the necessary Firestore offline migration was executed against Staging (`npx ts-node tools/migrations/runner.ts --env staging`) and verified.
- [ ] **Secrets Verification**: Ensure any new infrastructure secrets required by this release have been injected into Cloudflare Production via `wrangler secret put`.
- [ ] **Rollback Contingency**: Verify that the previous Stable tag (e.g., `v1.0.0`) is documented and ready for `wrangler rollback` if the deployment fails.

## Execution

- [ ] **Trigger Release**: Create and publish a GitHub Release with a Semantic Version tag (e.g., `v1.1.0`).
- [ ] **Monitor Pipeline**: Observe the `deploy_production.yml` GitHub Action execution.

## Post-Deployment (Production Verification)

- [ ] **Health Probe**: Verify `GET /v1/health` returns HTTP 200 `{"status":"ok"}`.
- [ ] **Semantic Traceability**: Verify `GET /v1/admin/diagnostics` exposes the correct `WORKER_VERSION` and `GIT_COMMIT` corresponding to the release tag.
- [ ] **Infrastructure Diagnostics**: Verify `GET /v1/admin/diagnostics` reports `status: "healthy"` across all Level 1 and Level 2 probes.
- [ ] **Production Smoke Test**: The automated functional smoke test executed by the deployment pipeline succeeded, confirming Razorpay and Firestore bindings are operational.
- [ ] **Production Migration**: If applicable, execute the corresponding data migration against Production (`npx ts-node tools/migrations/runner.ts --env production`).

## Sign-Off

If any Post-Deployment verification step fails, IMMEDIATELY halt investigation and execute the Rollback procedure defined in `docs/RUNBOOK.md`.

*Release Version:* _____________
*Deployer Name:* _____________
*Date/Time:* _____________
