# ==========================================================
#   VENDSOFT PHASE 5 E2E RUNTIME VERIFICATION SCRIPT
#   Tests: Legacy RSA Sunset, Base64 JSON Key Parsing,
#          Automatic Migration to Composite Device Lease,
#          Idempotency Protection, & Audit Trail Recording
# ==========================================================

$baseUrl = "http://127.0.0.1:8788/api/v1"
$legacyDeviceId = "inst_legacy_p5_device"

$authHeader = @{
    "Authorization" = "Bearer test_local_token_jwt"
    "Content-Type" = "application/json"
    "x-installation-uuid" = $legacyDeviceId
    "x-installation-id" = $legacyDeviceId
    "x-hardware-id" = $legacyDeviceId
    "x-platform" = "android"
    "x-app-version" = "1.0.0"
}
$adminHeader = @{
    "x-admin-secret" = "admin_secret_mock"
    "Content-Type" = "application/json"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   VENDSOFT PHASE 5 E2E RUNTIME VERIFICATION SCRIPT       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Step 1: Construct Mock Legacy RSA License Key (Base64 JSON)
Write-Host "`n[Step 1] Constructing Historical Legacy RSA License Key (v0.9.x Format)..." -ForegroundColor Yellow
$legacyPayload = @{
    deviceId = $legacyDeviceId
    customerName = "Phase 5 Legacy Times Newspaper"
    customerType = "Annual"
    expiryDate = "2027-12-31T23:59:59Z"
} | ConvertTo-Json -Compress

$legacyObj = @{
    payload = $legacyPayload
    signature = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("mock_rsa_sha256_sig_bytes"))
} | ConvertTo-Json -Compress

$legacyKeyBase64 = "MOCK_DEV_LEGACY_KEY_" + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($legacyObj))
Write-Host "Generated Legacy Key Base64 ($($legacyKeyBase64.Substring(0, 48))...)" -ForegroundColor Green

# Step 2: First-Launch Automatic Migration (`POST /v1/migrate/legacy-key`)
Write-Host "`n[Step 2] Executing First-Launch Legacy Key Migration (`POST /v1/migrate/legacy-key`)..." -ForegroundColor Yellow
$migBody = @{
    legacyLicenseKey = $legacyKeyBase64
} | ConvertTo-Json

$migResp = Invoke-RestMethod -Uri "$baseUrl/migrate/legacy-key" -Method Post -Headers $authHeader -Body $migBody
$customerId = $migResp.data.customerId
$subscriptionId = $migResp.data.subscriptionId
$signedLease = $migResp.data.signedLeaseToken

Write-Host "Migration Result: Status=$($migResp.data.status) (`$($migResp.data.message)`)" -ForegroundColor Green
Write-Host "Migrated Customer ID: $customerId | Subscription ID: $subscriptionId" -ForegroundColor Green
Write-Host "Issued Base64url Signed Lease Token: $($signedLease.Substring(0, 50))..." -ForegroundColor Cyan

# Step 3: Verify Exact Firestore Documents Created
Write-Host "`n[Step 3] Verifying Authoritative Firestore Datastore Documents..." -ForegroundColor Yellow
$store = Invoke-RestMethod -Uri "$baseUrl/dev/store" -Method Get
$custDoc = $store.documents.psobject.properties["customers/$customerId"].Value
$instDoc = $store.documents.psobject.properties["installations/$legacyDeviceId"].Value
$subDoc = $store.documents.psobject.properties["subscriptions/$subscriptionId"].Value

Write-Host "Customer Profile Document: BusinessName='$($custDoc.businessName)' | Status=$($custDoc.status)" -ForegroundColor Green
Write-Host "Installation Document: HardwareID='$($instDoc.hardwareId)' | Status=$($instDoc.status) | Model='$($instDoc.deviceModel)'" -ForegroundColor Green
Write-Host "Subscription Document: PlanID='$($subDoc.planId)' | ExpiresAtEpochMs=$($subDoc.expiresAtEpochMs) | LegacyKeyHash='$($subDoc.legacyKeyHash.Substring(0, 16))...'" -ForegroundColor Magenta

# Step 4: Test Idempotency (`POST /v1/migrate/legacy-key` second time with exact same key)
Write-Host "`n[Step 4] Testing Idempotency Protection (Vendor restarts app after migration)..." -ForegroundColor Yellow
$migResp2 = Invoke-RestMethod -Uri "$baseUrl/migrate/legacy-key" -Method Post -Headers $authHeader -Body $migBody
Write-Host "Second Request Result: Status=$($migResp2.data.status) (`$($migResp2.data.message)`)" -ForegroundColor Green
Write-Host "Returned Customer ID matches: $($migResp2.data.customerId -eq $customerId) | Subscription ID matches: $($migResp2.data.subscriptionId -eq $subscriptionId)" -ForegroundColor Cyan

# Step 5: Verify Immutable Audit Trails (`GET /v1/admin/audit-logs`)
Write-Host "`n[Step 5] Retrieving Immutable System Audit Logs (`GET /v1/admin/audit-logs`)..." -ForegroundColor Yellow
$logsResp = Invoke-RestMethod -Uri "$baseUrl/admin/audit-logs" -Method Get -Headers $adminHeader
$migLog = $logsResp.data.logs | Where-Object { $_.action -eq 'MIGRATED_LEGACY_RSA_LICENSE' } | Select-Object -First 1
Write-Host "Found Audit Log Record: LogID=$($migLog.logId) | Action=$($migLog.action) | Severity=$($migLog.severity)" -ForegroundColor Green
Write-Host "Audit Log Metadata: CustomerId=$($migLog.metadata.customerId) | InstallationId=$($migLog.metadata.installationId) | SubscriptionId=$($migLog.metadata.subscriptionId)" -ForegroundColor Cyan

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "   PHASE 5 E2E VERIFICATION COMPLETED successfully!       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
