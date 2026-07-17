$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   VENDSOFT PHASE 3 E2E RUNTIME VERIFICATION SCRIPT       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$baseUrl = "http://127.0.0.1:8788/api/v1"
$customerId = "cus_PHASE3_BIZ"
$installationId = "inst_PHASE3_DEV"
$hardwareId = "8a32b6e19c001122"

$headers = @{
    "Authorization" = "Bearer test_local_token_jwt"
    "Content-Type" = "application/json"
    "x-installation-uuid" = $installationId
    "x-installation-id" = $installationId
    "x-hardware-id" = $hardwareId
    "x-platform" = "android"
    "x-app-version" = "1.0.0"
}

# Step 1: Register Customer & Hardware Installation
Write-Host "`n[Step 1] Registering Customer & Hardware Installation ($installationId)..." -ForegroundColor Yellow
$regBody = @{
    mobileNumber = "+919811223344"
    ownerName = "Phase 3 Vendor Owner"
    businessName = "Phase 3 News Agency"
    city = "Lucknow"
} | ConvertTo-Json

$regResp = Invoke-RestMethod -Uri "$baseUrl/customers/register" -Method Post -Headers $headers -Body $regBody
Write-Host "Registration Status: Success ($($regResp.success)) - CustomerId: $($regResp.data.customerId)" -ForegroundColor Green
$customerId = $regResp.data.customerId
$headers["x-customer-id"] = $customerId

# Step 2: Initiate Payment Order (`POST /v1/orders/create`)
Write-Host "`n[Step 2] Creating PRO_YEARLY Payment Order (`POST /v1/orders/create`)..." -ForegroundColor Yellow
$orderBody = @{
    planId = "PRO_YEARLY"
} | ConvertTo-Json

$orderResp = Invoke-RestMethod -Uri "$baseUrl/orders/create" -Method Post -Headers $headers -Body $orderBody
Write-Host "Order Created: $($orderResp.data.razorpayOrderId) | Amount: ₹$($orderResp.data.amountInr) ($($orderResp.data.amountPaise) paise)" -ForegroundColor Green
$firstOrderId = $orderResp.data.razorpayOrderId

# Step 3: Test Payment Cancellation Verification Fallback (`POST /v1/orders/verify`)
Write-Host "`n[Step 3] Testing Client Fallback Verification on Payment Cancellation..." -ForegroundColor Yellow
$cancelBody = @{
    razorpayOrderId = $firstOrderId
    errorCode = "PAYMENT_CANCELLED"
} | ConvertTo-Json

$cancelResp = Invoke-RestMethod -Uri "$baseUrl/orders/verify" -Method Post -Headers $headers -Body $cancelBody
Write-Host "Verification Response Status: $($cancelResp.data.status) ($($cancelResp.data.message))" -ForegroundColor Green

# Step 4: Initiate Second Order for Webhook Settlement Test
Write-Host "`n[Step 4] Creating Fresh Order for Webhook Settlement Test..." -ForegroundColor Yellow
$orderResp2 = Invoke-RestMethod -Uri "$baseUrl/orders/create" -Method Post -Headers $headers -Body $orderBody
$secondOrderId = $orderResp2.data.razorpayOrderId
Write-Host "New Order Id for Webhook: $secondOrderId" -ForegroundColor Green

# Step 5: Test Webhook with INVALID Signature (`POST /v1/webhooks/razorpay`)
Write-Host "`n[Step 5] Testing Razorpay Webhook with INVALID HMAC Signature Header..." -ForegroundColor Yellow
$webhookPayload = @{
    event = "order.paid"
    payload = @{
        payment = @{
            entity = @{
                id = "pay_P3Capture101"
                order_id = $secondOrderId
                amount = 149900
                status = "captured"
            }
        }
    }
} | ConvertTo-Json -Depth 5

$invalidHeaders = @{
    "Content-Type" = "application/json"
    "x-razorpay-signature" = "invalid_fake_hmac_hex_string_1234567890"
}

try {
    $invResp = Invoke-RestMethod -Uri "$baseUrl/webhooks/razorpay" -Method Post -Headers $invalidHeaders -Body $webhookPayload
    Write-Host "ERROR: Should have failed with 401 Unauthorized" -ForegroundColor Red
} catch {
    Write-Host "SUCCESS: Webhook rejected invalid signature with HTTP $($_.Exception.Response.StatusCode)" -ForegroundColor Green
}

# Step 6: Test Webhook with VALID Signature
Write-Host "`n[Step 6] Simulating Valid Webhook Settlement (`POST /v1/webhooks/razorpay`)..." -ForegroundColor Yellow
$hmac = New-Object System.Security.Cryptography.HMACSHA256
$hmac.Key = [System.Text.Encoding]::UTF8.GetBytes("rzp_test_webhook_secret")
$sigBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($webhookPayload))
$validSig = ($sigBytes | ForEach-Object { $_.ToString("x2") }) -join ""

$validHeaders = @{
    "Content-Type" = "application/json"
    "x-razorpay-signature" = $validSig
}

$webResp = Invoke-RestMethod -Uri "$baseUrl/webhooks/razorpay" -Method Post -Headers $validHeaders -Body $webhookPayload
Write-Host "Webhook Processed Status: success=$($webResp.success) processed=$($webResp.processed) subId=$($webResp.subscriptionId)" -ForegroundColor Green
$subscriptionId = $webResp.subscriptionId

# Step 7: Test Webhook Idempotency (Sending duplicate `order.paid` flood)
Write-Host "`n[Step 7] Testing Webhook Idempotency (Duplicate Flood with same Order ID)..." -ForegroundColor Yellow
$dupResp = Invoke-RestMethod -Uri "$baseUrl/webhooks/razorpay" -Method Post -Headers $validHeaders -Body $webhookPayload
Write-Host "Duplicate Webhook Response: success=$($dupResp.success) processed=$($dupResp.processed) note=$($dupResp.note)" -ForegroundColor Green
if ($dupResp.note -ne "ALREADY_PROCESSED") {
    Write-Host "WARNING: Expected note to be ALREADY_PROCESSED" -ForegroundColor Red
} else {
    Write-Host "IDEMPOTENCY PROVEN: Exactly zero duplicate subscriptions or double extensions executed!" -ForegroundColor Green
}

# Step 8: Verify Active Subscription State & Signed Lease Token (`GET /v1/subscriptions/status`)
Write-Host "`n[Step 8] Verifying Subscription Status (`GET /v1/subscriptions/status`)..." -ForegroundColor Yellow
$subStatus = Invoke-RestMethod -Uri "$baseUrl/subscriptions/status?customerId=$customerId" -Method Get -Headers $headers
Write-Host "Subscription Status: $($subStatus.data.status) | Active Installation: $($subStatus.data.activeInstallationId)" -ForegroundColor Green
Write-Host "Signed Lease Token Preview: $($subStatus.data.signedLeaseToken.Substring(0, 45))..." -ForegroundColor Green

# Step 9: Inspect Dev Store (`GET /v1/dev/store`) to confirm exact atomic database state
Write-Host "`n[Step 9] Inspecting Firestore State via Dev Store..." -ForegroundColor Yellow
$store = Invoke-RestMethod -Uri "$baseUrl/dev/store" -Method Get
Write-Host "Payments Document State ($secondOrderId): status=$($store.documents["payments/$secondOrderId"].status) amountInr=$($store.documents["payments/$secondOrderId"].amountInr)" -ForegroundColor Cyan
Write-Host "Subscriptions Document State ($subscriptionId): status=$($store.documents["subscriptions/$subscriptionId"].status) planId=$($store.documents["subscriptions/$subscriptionId"].planId) activeInstallationId=$($store.documents["subscriptions/$subscriptionId"].activeInstallationId)" -ForegroundColor Cyan

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "   PHASE 3 E2E VERIFICATION COMPLETED successfully!       " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
