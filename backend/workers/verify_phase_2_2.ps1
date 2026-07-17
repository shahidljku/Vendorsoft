$ErrorActionPreference = "Stop"
$baseUrl = "http://127.0.0.1:8788/api/v1"
$devStoreUrl = "http://127.0.0.1:8788/v1/dev/store"

Write-Host "=== STEP 1: Register Device A (inst_OLD_PHONE) ==="
$regHeaders = @{
    "Authorization" = "Bearer test_local_token_jwt"
    "x-hardware-id" = "hw_old_phone_111"
    "x-installation-uuid" = "inst_OLD_PHONE"
    "x-app-version" = "1.0.0"
    "x-platform" = "android"
    "Content-Type" = "application/json"
}
$regBody = @{
    businessName = "Gupta Logistics & News"
    ownerName = "Amit Gupta"
    mobileNumber = "+919811223344"
    city = "Delhi"
    deviceModel = "Samsung Galaxy M51"
} | ConvertTo-Json

$regResp = Invoke-WebRequest -Uri "$baseUrl/customers/register" -Method POST -Headers $regHeaders -Body $regBody
$regJson = $regResp.Content | ConvertFrom-Json
$customerId = $regJson.data.customerId
$subscriptionId = $regJson.data.subscriptionId
Write-Host "Registered Customer ID: $customerId | Subscription ID: $subscriptionId | Status: $($regResp.StatusCode)"

Write-Host "`n=== STEP 2: Verify GET /subscriptions/status from Device A ==="
$statusResp = Invoke-WebRequest -Uri "$baseUrl/subscriptions/status" -Method GET -Headers $regHeaders
$statusJson = $statusResp.Content | ConvertFrom-Json
Write-Host "Device A Status Code: $($statusResp.StatusCode) | Active Installation: $($statusJson.data.activeInstallationId) | Has Token: $($statusJson.data.signedLeaseToken.Length -gt 20)"

Write-Host "`n=== STEP 3: Enforce One Active Device Rule (Query from Device B) ==="
$headersDeviceB = @{
    "Authorization" = "Bearer test_local_token_jwt"
    "x-hardware-id" = "hw_new_phone_222"
    "x-installation-uuid" = "inst_NEW_PHONE"
    "x-app-version" = "1.0.0"
    "x-platform" = "android"
    "Content-Type" = "application/json"
}
try {
    $supersededResp = Invoke-WebRequest -Uri "$baseUrl/subscriptions/status?customerId=$customerId" -Method GET -Headers $headersDeviceB
} catch {
    $errResp = $_.Exception.Response
    $stream = $errResp.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream)
    $errText = $reader.ReadToEnd()
    $errJson = $errText | ConvertFrom-Json
    Write-Host "Device B Query Status Code: $($errResp.StatusCode) | Error Code: $($errJson.error.code) | Active Device Reported: $($errJson.error.activeInstallationId)"
}

Write-Host "`n=== STEP 4: Request Device Transfer from Device B ==="
$transReqBody = @{
    customerId = $customerId
    subscriptionId = $subscriptionId
    deviceModel = "iPhone 15 Pro"
} | ConvertTo-Json
$transReqResp = Invoke-WebRequest -Uri "$baseUrl/transfers/request" -Method POST -Headers $headersDeviceB -Body $transReqBody
$transReqJson = $transReqResp.Content | ConvertFrom-Json
$transferId = $transReqJson.data.transferId
Write-Host "Transfer Request Status Code: $($transReqResp.StatusCode) | Transfer ID: $transferId | Status: $($transReqJson.data.status)"

Write-Host "`n=== STEP 5: Poll Pending Transfers from Device A (Mandatory Polling Sync) ==="
$pollResp = Invoke-WebRequest -Uri "$baseUrl/transfers/pending" -Method GET -Headers $regHeaders
$pollJson = $pollResp.Content | ConvertFrom-Json
Write-Host "Poll Status Code: $($pollResp.StatusCode) | Pending Count: $($pollJson.data.pendingTransfers.Count) | Requested By: $($pollJson.data.pendingTransfers[0].newInstallationId) ($($pollJson.data.pendingTransfers[0].deviceModel))"

Write-Host "`n=== STEP 6: Approve Transfer from Device A ==="
$appBody = @{ transferId = $transferId } | ConvertTo-Json
$appResp = Invoke-WebRequest -Uri "$baseUrl/transfers/approve" -Method POST -Headers $regHeaders -Body $appBody
$appJson = $appResp.Content | ConvertFrom-Json
Write-Host "Approval Status Code: $($appResp.StatusCode) | Transfer Status: $($appJson.data.status) | Message: $($appJson.data.message)"

Write-Host "`n=== STEP 7: Verify Atomic Shift (Device B Active, Device A Superseded) ==="
$statusRespDeviceB = Invoke-WebRequest -Uri "$baseUrl/subscriptions/status?customerId=$customerId" -Method GET -Headers $headersDeviceB
$statusJsonB = $statusRespDeviceB.Content | ConvertFrom-Json
Write-Host "Device B New Status Code: $($statusRespDeviceB.StatusCode) | New Active Installation: $($statusJsonB.data.activeInstallationId) | Has Signed Lease Token: $($statusJsonB.data.signedLeaseToken.Length -gt 20)"

try {
    $checkOldResp = Invoke-WebRequest -Uri "$baseUrl/subscriptions/status?customerId=$customerId" -Method GET -Headers $regHeaders
} catch {
    $errRespOld = $_.Exception.Response
    $streamOld = $errRespOld.GetResponseStream()
    $readerOld = New-Object System.IO.StreamReader($streamOld)
    $errTextOld = $readerOld.ReadToEnd()
    $errJsonOld = $errTextOld | ConvertFrom-Json
    Write-Host "Device A Query After Transfer: Status Code $($errRespOld.StatusCode) | Error Code: $($errJsonOld.error.code) | Active Device Now: $($errJsonOld.error.activeInstallationId)"
}

Write-Host "`n=== STEP 8: Inspect Stored Firestore Documents ==="
$storeResp = Invoke-WebRequest -Uri $devStoreUrl -Method GET
$storeJson = $storeResp.Content | ConvertFrom-Json
Write-Host "Total Stored Documents: $($storeJson.count)"
Write-Host "Old Installation Status (inst_OLD_PHONE): $($storeJson.documents.'installations/inst_OLD_PHONE'.status)"
Write-Host "New Installation Status (inst_NEW_PHONE): $($storeJson.documents.'installations/inst_NEW_PHONE'.status)"
Write-Host "Transfer Document Status ($transferId): $($storeJson.documents."device_transfers/$transferId".status)"
Write-Host "Subscription Active Installation ($subscriptionId): $($storeJson.documents."subscriptions/$subscriptionId".activeInstallationId)"
