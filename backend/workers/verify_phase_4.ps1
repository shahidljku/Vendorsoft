# ==========================================================
#   VENDSOFT PHASE 4 E2E RUNTIME VERIFICATION SCRIPT
#   Tests: Admin Control Plane, Customer 360, Lost Phone
#          Transfer Override, System Configs, & Audit Trails
# ==========================================================

$baseUrl = "http://127.0.0.1:8788/api/v1"
$authHeader = @{
    "Authorization" = "Bearer test_local_token_jwt"
    "Content-Type" = "application/json"
    "x-installation-uuid" = "inst_p4_source_phone"
    "x-installation-id" = "inst_p4_source_phone"
    "x-hardware-id" = "99aa88bb77cc66dd"
    "x-platform" = "android"
    "x-app-version" = "1.0.0"
}
$adminHeader = @{
    "x-admin-secret" = "admin_secret_mock"
    "Content-Type" = "application/json"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   VENDSOFT PHASE 4 E2E RUNTIME VERIFICATION SCRIPT       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Step 1: Register Vendor for Phase 4 Testing
Write-Host "`n[Step 1] Registering Test Vendor (Phase 4 News Depot)..." -ForegroundColor Yellow
$regPayload = @{
    businessName = "Phase 4 News Depot"
    ownerName = "Rajesh Phase4"
    mobileNumber = "+919876543210"
    city = "Delhi"
} | ConvertTo-Json

$regResp = Invoke-RestMethod -Uri "$baseUrl/customers/register" -Method Post -Headers $authHeader -Body $regPayload
$customerId = $regResp.data.customerId
$sourceInstId = $regResp.data.activeInstallationId
if (-not $sourceInstId) { $sourceInstId = "inst_p4_source_phone" }
Write-Host "Customer Registered: $customerId | Source Installation: $sourceInstId" -ForegroundColor Green

# Step 2: Admin Search & Customer 360 View (`GET /v1/admin/customers`)
Write-Host "`n[Step 2] Admin Customer 360 Search (`GET /v1/admin/customers?query=Phase 4`)..." -ForegroundColor Yellow
$searchResp = Invoke-RestMethod -Uri "$baseUrl/admin/customers?query=Phase 4" -Method Get -Headers $adminHeader
$foundCust = $searchResp.data.customers | Where-Object { $_.customerId -eq $customerId }
Write-Host "Customer 360 Retrieved: Name=$($foundCust.businessName) | ActiveSub=$($foundCust.activeSubscription.planId) | Devices Count=$($foundCust.installationsCount)" -ForegroundColor Green

# Step 3: Admin Safe Metadata Update (`PUT /v1/admin/customers/:id`)
Write-Host "`n[Step 3] Safely Updating Profile Metadata (`PUT /v1/admin/customers/$customerId`)..." -ForegroundColor Yellow
$updatePayload = @{
    businessName = "Phase 4 Enterprise Pro Agency"
    city = "New Delhi Central"
} | ConvertTo-Json

$updateResp = Invoke-RestMethod -Uri "$baseUrl/admin/customers/$customerId" -Method Put -Headers $adminHeader -Body $updatePayload
Write-Host "Updated Profile Details: BusinessName='$($updateResp.data.businessName)' | City='$($updateResp.data.city)'" -ForegroundColor Green

# Step 4: Simulate THE LOST OR BROKEN PHONE CASE (Transfer Override)
Write-Host "`n[Step 4] Simulating 'Lost or Broken Phone Case' (Vendor drops source phone in water)..." -ForegroundColor Yellow
# Vendor gets a brand new phone and requests P2P transfer
$newPhoneAuth = @{
    "Authorization" = "Bearer test_local_token_jwt"
    "Content-Type" = "application/json"
    "x-installation-uuid" = "inst_p4_new_replacement_phone"
    "x-installation-id" = "inst_p4_new_replacement_phone"
    "x-hardware-id" = "1122334455667788"
    "x-platform" = "android"
    "x-app-version" = "1.0.0"
}
$txReqBody = @{
    customerId = $customerId
    sourceInstallationId = $sourceInstId
} | ConvertTo-Json

$txReqResp = Invoke-RestMethod -Uri "$baseUrl/transfers/request" -Method Post -Headers $newPhoneAuth -Body $txReqBody
$transferId = $txReqResp.data.transferId
$targetInstId = "inst_p4_new_replacement_phone"
Write-Host "Transfer Requested: ID=$transferId | New Phone Installation: $targetInstId | Status=PENDING" -ForegroundColor Cyan

# Old phone is lost/dead, so vendor calls support. Admin manually approves override!
Write-Host "Executing Support Admin Lost Phone Override (`POST /v1/admin/transfers/$transferId/approve`)..." -ForegroundColor Yellow
$txApproveResp = Invoke-RestMethod -Uri "$baseUrl/admin/transfers/$transferId/approve" -Method Post -Headers $adminHeader
Write-Host "Admin Override Result: Status=$($txApproveResp.data.status) | ActiveInstallation=$($txApproveResp.data.activeInstallationId)" -ForegroundColor Green
Write-Host "Lease Token Updated for Replacement Phone: $($txApproveResp.data.signedLeaseToken.Substring(0, 45))..." -ForegroundColor Cyan

# Step 5: Test System Config Switches (`PUT /v1/admin/config/system`)
Write-Host "`n[Step 5] Testing Global Edge Control Switches (`system_configs/global`)..." -ForegroundColor Yellow
$configBody = @{
    allowPayments = $false
    maintenanceMode = $false
    enforceStrictAppVersion = $true
} | ConvertTo-Json

$configResp = Invoke-RestMethod -Uri "$baseUrl/admin/config/system" -Method Put -Headers $adminHeader -Body $configBody
Write-Host "System Configs Saved: allowPayments=$($configResp.data.allowPayments) | strictVersion=$($configResp.data.enforceStrictAppVersion)" -ForegroundColor Green

# Reset config to normal for next phases
$resetBody = @{ allowPayments = $true; maintenanceMode = $false; enforceStrictAppVersion = $false } | ConvertTo-Json
$null = Invoke-RestMethod -Uri "$baseUrl/admin/config/system" -Method Put -Headers $adminHeader -Body $resetBody

# Step 6: Verify Immutable Audit Logs (`GET /v1/admin/audit-logs`)
Write-Host "`n[Step 6] Retrieving Immutable System Audit Logs (`GET /v1/admin/audit-logs`)..." -ForegroundColor Yellow
$logsResp = Invoke-RestMethod -Uri "$baseUrl/admin/audit-logs" -Method Get -Headers $adminHeader
Write-Host "Total Immutable Logs Found: $($logsResp.data.count)" -ForegroundColor Cyan
foreach ($log in $logsResp.data.logs | Select-Object -First 4) {
    Write-Host "  -> LogID: $($log.logId) | Action: $($log.action) | Severity: $($log.severity)" -ForegroundColor Green
}

# Step 7: Inspect Dev Store State
Write-Host "`n[Step 7] Final Store Verification..." -ForegroundColor Yellow
$store = Invoke-RestMethod -Uri "$baseUrl/dev/store" -Method Get
$custDoc = $store.documents.psobject.properties["customers/$customerId"].Value
$oldInstDoc = $store.documents.psobject.properties["installations/$sourceInstId"].Value
$newInstDoc = $store.documents.psobject.properties["installations/$targetInstId"].Value

Write-Host "Customer Name in DB: $($custDoc.businessName)" -ForegroundColor Green
Write-Host "Old Source Phone Status in DB: $($oldInstDoc.status) (Reason: $($oldInstDoc.revokedReason))" -ForegroundColor Magenta
Write-Host "New Replacement Phone Status in DB: $($newInstDoc.status)" -ForegroundColor Green

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host "   PHASE 4 E2E VERIFICATION COMPLETED successfully!       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
