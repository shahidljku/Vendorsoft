# Security Specification & Threat Mitigation Blueprint (Version 1.0 Frozen)

## 1. Threat Model & Defense-in-Depth Analysis

VendSoft operates on Android devices controlled by end users under a **Zero-Trust Client Threat Model**. Version 1.0 eliminates insecure/costly paid SMS OTP verification in favor of a robust **Composite Identity & Peer-to-Peer Transfer Security Architecture**, governed globally by server-side `system_configs`.

### 1.1 Threat Matrix & Architectural Countermeasures

| Threat / Attack Vector | Attack Mechanics | Architectural Countermeasure | Severity |
| :--- | :--- | :--- | :--- |
| **APK Decompilation & Binary Patching** | Attackers use `jadx` / `Frida` to patch `LicenseService.isLicensed() => true` locally. | **Server-Side Signed Leases**: Cloud updates, reports, and sync endpoints validate the Ed25519/RSA `signedLeaseToken` against `subscriptions.activeInstallationId`. Patched clients without a server-signed token are blocked at the Worker boundary. | **CRITICAL** |
| **System Clock Rollback / Freeze** | Users roll back Android system date right before expiration. | **Dual-Layer Clock Guard**: Local `ClockGuardService` records high monotonic watermarks in `FlutterSecureStorage`. Cloudflare Workers completely ignore client timestamp headers, using strictly `Date.now()` and `FieldValue.serverTimestamp()`. | **HIGH** |
| **Social Engineering & SMS Interception** | Attackers attempt to intercept SMS OTPs or spoof `Mobile Number` / `Business Name` to hijack a competitor's paid subscription. | **Zero SMS OTP + Peer-to-Peer Transfer Lock**: `Business Name` and `Mobile Number` are display/contact fields only and **never constitute proof of ownership**. Even if an attacker knows a vendor's mobile number, a transfer request (`POST /transfers/request`) does NOT activate the new device. **Only explicit cryptographic authorization from the OLD DEVICE (`Old Device Approval`) OR human verification by an Admin (`Admin Manual Approval`) can transfer `activeInstallationId`.** | **CRITICAL** |
| **Transfer Spam & Zombie Locks** | Malicious actors flood `/transfers/request` to lock up a legitimate vendor's active subscription with pending transfer collisions. | **Transfer Safety Enforcement**: Cloudflare Workers enforce that **only ONE pending transfer is allowed per subscription** at a time. If a pending transfer is unclaimed, it expires precisely after **24 hours (`serverTimestamp() + 24 hours`)**, unlocking the request queue. | **HIGH** |
| **Replay & Duplicate Webhook Flooding** | Network retries or attacker replay loops send identical `order.paid` webhooks to double-extend annual subscriptions. | **HMAC Signatures & Transaction Idempotency**: Workers compute HMAC SHA-256 signatures against `x-razorpay-signature` and verify `created_at` age (`<10m`). Inside `runTransaction`, if `payments[orderId].status == "SUCCESS"`, the transaction aborts write operations cleanly without double-granting. | **HIGH** |
| **Client Spoofing of Global Configuration** | Attackers attempt to write to `/system_configs/global` to turn off `maintenanceMode` or bypass minimum version checks. | **Impenetrable Read-Only Rules**: `system_configs` has `allow write: if false;` across all client SDK access. Only Cloudflare Workers via Service Accounts can alter global switches. | **CRITICAL** |


---

### 1.4 Security Patch: Offline Lease Cryptography
In the initial `v1.0.0` implementation, the `signedLeaseToken` was signed using symmetric HMAC-SHA256, and the Flutter app did not verify the signature offline. This was a critical vulnerability (CVSS 10.0).

**MANDATE:** All offline `signedLeaseToken` payloads MUST be cryptographically signed by Cloudflare Workers using the authoritative **RSA Private Key** (`RSASSA-PKCS1-v1_5`). The Flutter client application MUST mathematically verify the signature against the embedded **RSA Public Key** before parsing the token's expiration date or granting UI access. The Worker must NEVER use HMAC symmetric signing for offline tokens.

---


## 2. Cloud Firestore Security Rules Strategy

Because Cloudflare Workers act as the primary authoritative control plane using **Service Account / Admin REST credentials** (bypassing rules), Firestore Security Rules strictly enforce **Principle of Least Privilege (PoLP)** for client SDKs.

### 2.1 Complete `firestore.rules` Specification (`Version 1.0 Frozen`)

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    // Common Helper Functions
    function isAuthenticated() {
      return request.auth != null && request.auth.uid != null;
    }

    function isOwnerOfInstallation(installationId) {
      return isAuthenticated() && 
             exists(/databases/$(database)/documents/installations/$(installationId)) &&
             get(/databases/$(database)/documents/installations/$(installationId)).data.firebaseUid == request.auth.uid;
    }

    // -------------------------------------------------------------------------
    // 1. SYSTEM_CONFIGS COLLECTION: Publicly readable; strictly admin-writable
    // -------------------------------------------------------------------------
    match /system_configs/{configId} {
      allow read: if true; // Allows app startup check before authentication
      allow write: if false; // Only Cloudflare Workers (Service Account) can modify
    }

    // -------------------------------------------------------------------------
    // 2. PLANS COLLECTION: Publicly readable catalog; strictly admin-writable
    // -------------------------------------------------------------------------
    match /plans/{planId} {
      allow read: if isAuthenticated() && resource.data.isActive == true;
      allow write: if false; // Only Cloudflare Workers (Service Account) can modify
    }

    // -------------------------------------------------------------------------
    // 3. CUSTOMERS COLLECTION: Read-only by verified customer account owner
    // -------------------------------------------------------------------------
    match /customers/{customerId} {
      allow read: if isAuthenticated() && (
        exists(/databases/$(database)/documents/installations/$(request.headers['x-installation-id'])) &&
        get(/databases/$(database)/documents/installations/$(request.headers['x-installation-id'])).data.customerId == customerId
      );
      allow write: if false; // Only Cloudflare Workers can modify
    }

    // -------------------------------------------------------------------------
    // 4. INSTALLATIONS COLLECTION: Read-only by bound session UID
    // -------------------------------------------------------------------------
    match /installations/{installationId} {
      allow read: if isAuthenticated() && resource.data.firebaseUid == request.auth.uid;
      allow write: if false; // Only Cloudflare Workers can modify after initial onboarding
    }

    // -------------------------------------------------------------------------
    // 5. SUBSCRIPTIONS COLLECTION: Read-only by authorized active installation
    // -------------------------------------------------------------------------
    match /subscriptions/{subscriptionId} {
      allow read: if isAuthenticated() && (
        resource.data.activeInstallationId == request.headers['x-installation-id'] ||
        isOwnerOfInstallation(resource.data.activeInstallationId)
      );
      allow write: if false; // Only Cloudflare Workers can modify
    }

    // -------------------------------------------------------------------------
    // 6. DEVICE_TRANSFERS COLLECTION: Read-only by participating installations
    // -------------------------------------------------------------------------
    match /device_transfers/{transferId} {
      // Allow old installation (polling for approvals) OR new installation (polling status) to read
      allow read: if isAuthenticated() && (
        isOwnerOfInstallation(resource.data.oldInstallationId) ||
        isOwnerOfInstallation(resource.data.newInstallationId)
      );
      allow write: if false; // Only Cloudflare Workers can modify via /transfers/approve or /request
    }

    // -------------------------------------------------------------------------
    // 7. PAYMENTS COLLECTION: Read-only by initiating installation
    // -------------------------------------------------------------------------
    match /payments/{paymentId} {
      allow read: if isAuthenticated() && isOwnerOfInstallation(resource.data.installationId);
      allow write: if false; // Only Cloudflare Workers can modify
    }

    // -------------------------------------------------------------------------
    // 8. AUDIT_LOGS & IDEMPOTENCY_KEYS: Complete Client Lockout
    // -------------------------------------------------------------------------
    match /audit_logs/{logId} {
      allow read, write: if false; // Strictly Worker / Admin access only
    }

    match /idempotency_keys/{keyId} {
      allow read, write: if false; // Strictly Worker access only
    }
  }
}
```

---

## 3. Cryptographic & Identity Security Strategy

### 3.1 Composite Identity Anchors (`Version 1.0 Frozen`)
No single identifier is trusted individually. When a request arrives at the Worker API Gateway, `AuthGuard` evaluates four distinct layers simultaneously alongside global `system_configs`:
1. **`Firebase UID`**: Confirms that the JWT bearer token (`Authorization: Bearer <ID_TOKEN>`) is unexpired and properly signed by Google Auth servers.
2. **`installationUuid` (`FlutterSecureStorage`)**: Confirms the specific app instance on the device, eliminating desktop and `UNKNOWN_DEVICE` hash collisions.
3. **`hardwareId` (`LicenseService().getDeviceId()`)**: Confirms physical hardware consistency (`SHA-256 of ANDROID_ID`), matching legacy RSA offline license keys.
4. **`customerId` (`cus_xxxxxxxxx`)**: Confirms that the installation is properly bound to an active, non-banned customer profile in Firestore.

---

## 4. Device Transfer Safety & Audit Mandates

To ensure full accountability during device migrations or lost phone replacements, every state transition across the `device_transfers` pipeline must generate an immutable, timestamped record in `audit_logs`:

| Transfer Action | Audit Event Code | Logged Metadata Payload | Security Alert Condition |
| :--- | :--- | :--- | :--- |
| **Initiation** | `TRANSFER_REQUESTED` | `{ transferId, subscriptionId, oldInstallationId, newInstallationId, customerId }` | If $> 3$ transfer requests within 7 days across same `customerId`, flag for human review. |
| **Peer Approval** | `TRANSFER_APPROVED_PEER`| `{ transferId, approvedBy: "PEER_OLD_DEVICE", oldInstallationId, newInstallationId }` | Normal transition; old device revoked. |
| **Admin Approval** | `TRANSFER_APPROVED_ADMIN`| `{ transferId, approvedBy: "ADMIN_MANUAL", adminId, justificationNotes }` | Requires mandatory admin notes justifying why peer approval was bypassed (lost/broken phone). |
| **Peer Rejection** | `TRANSFER_REJECTED` | `{ transferId, rejectedBy: "PEER_OLD_DEVICE", oldInstallationId, newInstallationId }` | If old device rejects, log potential unauthorized account takeover attempt against `newInstallationId`. |
| **Expiration** | `TRANSFER_EXPIRED` | `{ transferId, expiredAtEpochMs }` | Auto-logged when 24-hour TTL passes without action. |
| **Revocation** | `INSTALLATION_REVOKED` | `{ installationId, revokedBy: "TRANSFER_COMPLETED" \| "ADMIN_BAN" }` | Records exact timestamp when an installation lost its `activeInstallationId` status. |
