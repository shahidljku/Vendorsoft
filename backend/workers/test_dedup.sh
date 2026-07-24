#!/bin/bash

BASE_URL="https://vendsoft-api-worker.vendorproapk.workers.dev/api/v1"
HARDWARE_ID="AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899"
TIMESTAMP=$(date +%s000)
NONCE="abcd1234efgh5678"

echo "--- ATTEMPT 1 (Should be 201) ---"
curl.exe -s -i -X POST "$BASE_URL/customers/register" \
  -H "Authorization: Bearer test_local_token_mock_user_1" \
  -H "Content-Type: application/json" \
  -H "x-hardware-id: $HARDWARE_ID" \
  -H "x-timestamp: $TIMESTAMP" \
  -H "x-registration-nonce: $NONCE" \
  -H "x-app-version: 1.0.0" \
  -d '{"mobileNumber":"1234567890", "businessName":"Test Business 1", "ownerName":"Test Owner 1"}'

echo -e "\n\n--- ATTEMPT 2 (Should be 409 Conflict) ---"
curl.exe -s -i -X POST "$BASE_URL/customers/register" \
  -H "Authorization: Bearer test_local_token_mock_user_2" \
  -H "Content-Type: application/json" \
  -H "x-hardware-id: $HARDWARE_ID" \
  -H "x-timestamp: $TIMESTAMP" \
  -H "x-registration-nonce: ${NONCE}2" \
  -H "x-app-version: 1.0.0" \
  -d '{"mobileNumber":"0987654321", "businessName":"Test Business 2", "ownerName":"Test Owner 2"}'
