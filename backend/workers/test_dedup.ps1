$baseUrl = "https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1"
$hardwareId = "AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899"
$timestamp = [Math]::Floor([decimal](Get-Date (Get-Date).ToUniversalTime() -UFormat %s) * 1000).ToString()
$nonce = [guid]::NewGuid().ToString().Replace("-", "")

$headers = @{
    "Authorization" = "Bearer test_local_token_mock_user_1"
    "Content-Type" = "application/json"
    "x-hardware-id" = $hardwareId
    "x-timestamp" = $timestamp
    "x-registration-nonce" = $nonce
    "x-app-version" = "1.0.0"
}

$body1 = @{
    mobileNumber = "1234567890"
    businessName = "Test Business 1"
    ownerName = "Test Owner 1"
} | ConvertTo-Json

Write-Host "--- ATTEMPT 1 (Should be 201) ---"
try {
    $resp1 = Invoke-WebRequest -Uri "$baseUrl/customers/register" -Method POST -Headers $headers -Body $body1 -SkipHttpErrorCheck
    Write-Host "Status: $($resp1.StatusCode)"
    Write-Host "Body: $($resp1.Content)"
} catch {
    Write-Host "Error: $_"
}

$headers2 = @{
    "Authorization" = "Bearer test_local_token_mock_user_2"
    "Content-Type" = "application/json"
    "x-hardware-id" = $hardwareId
    "x-timestamp" = $timestamp
    "x-registration-nonce" = $nonce
    "x-app-version" = "1.0.0"
}

$body2 = @{
    mobileNumber = "0987654321"
    businessName = "Test Business 2"
    ownerName = "Test Owner 2"
} | ConvertTo-Json

Write-Host "--- ATTEMPT 2 (Should be 409 Conflict) ---"
try {
    $resp2 = Invoke-WebRequest -Uri "$baseUrl/customers/register" -Method POST -Headers $headers2 -Body $body2 -SkipHttpErrorCheck
    Write-Host "Status: $($resp2.StatusCode)"
    Write-Host "Body: $($resp2.Content)"
} catch {
    Write-Host "Error: $_"
}
