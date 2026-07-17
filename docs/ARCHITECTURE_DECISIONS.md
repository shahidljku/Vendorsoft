# Architecture Decision Records (ADR) Blueprint (`Revision v1.0`)

This document records every major architectural decision finalized for the VendSoft backend control plane and licensing architecture. Each decision serves as a permanent architectural mandate outlining the exact problem, alternatives considered, final decision, reasoning, and future implications.

---

## ADR-001: Why Offline-First Architecture is Mandatory

### Problem
Newspaper delivery vendors and distribution agencies operate early in the morning (4:00 AM – 7:00 AM) in basements, rural distribution hubs, and moving vehicles where cellular data connectivity (`4G/LTE/Wi-Fi`) is intermittent, slow, or completely non-existent. A cloud-dependent billing system that requires a synchronous server response to load customer spreadsheets, calculate monthly bills, or print thermal receipts would halt daily business operations during network outages.

### Alternatives Considered
1. **Always-Online Cloud SaaS (Firebase Realtime Database / Supabase as Primary Store)**: All customer rows read/written directly over network.
2. **Synchronous Online Licensing Check on Every App Launch**: App pings cloud server on startup; if offline or timed out, locks billing tabs.

### Final Decision
VendSoft is strictly designed as an **Offline-First Application**. Day-to-day business data processing occurs 100% locally via SQLite/Excel. Subscription rights are enforced offline via cryptographically signed lease tokens (`signedLeaseToken` signed via Ed25519/RSA) cached locally and verified against an embedded public key.

### Reasoning
Ensures **0ms UI latency**, **zero business disruption during internet outages**, and **zero cloud database read/write costs** for high-frequency daily billing operations. Even if the device is offline for 25 consecutive days, as long as `expiresAt > localTrustedClock`, the vendor operates without friction.

### Future Implications
Requires the client app to maintain a robust offline clock drift protection mechanism (`ClockGuardService`) to prevent users from setting their system clock backwards while offline to extend subscription validity.

---

## ADR-002: Why Cloudflare Workers Rule the Control Plane

### Problem
VendSoft requires a secure, high-availability serverless API gateway to validate Firebase anonymous tokens, enforce the One Active Device Rule, communicate with Razorpay, verify webhooks, and digitally sign Ed25519/RSA lease tokens without incurring high DevOps overhead or fixed server infrastructure costs.

### Alternatives Considered
1. **AWS Lambda + API Gateway + DynamoDB**: Industry standard but complex IAM roles, VPC configurations, cold starts (200ms–1s+), and high baseline NAT/Load Balancer costs.
2. **Node.js / Express VPS (DigitalOcean / AWS EC2)**: Requires manual OS security patching, SSH key management, Nginx reverse proxy tuning, SSL certificate rotation (Certbot), and horizontal scaling during traffic spikes.
3. **Cloud Functions for Firebase**: Tight integration with Firestore but slower cold starts on Node.js runtimes compared to V8 isolates and higher per-invocation pricing at scale.

### Final Decision
Deploy all backend control plane logic exclusively on **Cloudflare Workers** (`https://api.vendsoft.app/v1/...`).

### Reasoning
Cloudflare Workers run on V8 isolates, delivering **sub-5 millisecond cold starts globally**. They provide built-in DDoS protection, native Web Crypto API support (`crypto.subtle`) for ultra-fast Ed25519/RSA signing, and extraordinary cost efficiency (`100,000 free requests/day`, `$0.30 per million requests` thereafter). They eliminate server maintenance entirely.

### Future Implications
Workers have a maximum execution time limit (`30s CPU time` / request limit). Therefore, Workers must remain strictly focused on lightweight control plane validation, JWT math, and Firestore REST API transactions, avoiding heavy data processing tasks.

---

## ADR-003: Why Google Cloud Firestore is Used for Application State

### Problem
We need an authoritative state database accessible via REST by Cloudflare Workers and read-only via client SDKs to store `installations`, `customers`, `subscriptions`, `device_transfers`, `payments`, and `audit_logs` with strong ACID transactional guarantees.

### Alternatives Considered
1. **PostgreSQL / Supabase**: Excellent relational integrity, but WebSocket real-time persistent connections consume excess mobile battery and memory compared to Firebase's lightweight gRPC transport.
2. **MongoDB Atlas**: Good document flexibility, but lacks out-of-the-box real-time client synchronization and integrated anonymous device authentication.

### Final Decision
Use **Google Cloud Firestore** exclusively for **Control Plane Metadata & State**.

### Reasoning
Firestore provides out-of-the-box real-time synchronization (`onSnapshot`), allowing an old device to receive instant peer-to-peer transfer notification pop-ups. Its transactional `runTransaction` API guarantees atomic updates between `payments` and `subscriptions` during webhook processing, preventing double-granting under concurrent race conditions.

### Future Implications
To prevent unbounded read/write billing, end-user customer business data (`customers.xlsx`, ledger rows) is strictly banned from Firestore (`See ADR-004`).

---

## ADR-004: Why User Business Data Remains 100% Local

### Problem
A single vendor managing 5,000 newspaper subscribers updating daily delivery status creates `5,000 x 30 = 150,000` write operations per month. With 1,000 vendors, storing business data on the server would generate **150 million writes/month ($270+/month in pure write costs)** plus billions of reads, destroying the application's economic viability while making offline work impossible.

### Alternatives Considered
1. **Hybrid Cloud Sync**: Sync local SQLite/Excel to cloud storage on every save.
2. **Pure Cloud Database**: Store every newspaper bill and customer address directly inside Firestore collections.

### Final Decision
**User Business Data (newspaper customers, bills, Excel spreadsheets, reports, collections, receipts, PDFs, and images) MUST NEVER be stored in or transmitted to Firebase or any cloud server.** It remains 100% local inside device storage (`/storage/emulated/0/VendSoft/`) and user-managed local backups.

### Reasoning
Guarantees **$0 cloud storage and read/write billing costs for business data**, **complete data privacy for agency owners**, and **absolute operational autonomy** during internet blackouts.

### Future Implications
If a vendor loses or breaks their phone without configuring local file backups (`VendSoft/backups`), their historical billing spreadsheets cannot be recovered from the cloud. The app must proactively educate vendors on maintaining local USB/Google Drive file backups (`BackupService`).

---

## ADR-005: Why an Immutable `customerId` (`cus_xxxxxxxxx`) Exists

### Problem
If `Mobile Number` or `Business Name` is used as the primary key for a customer account in Firestore, changing a vendor's phone number or agency name would break all foreign key relationships across historical `installations`, `subscriptions`, and `payments` records, or allow account hijacking via phone number recycling.

### Alternatives Considered
1. **Mobile Number as Primary Key (`+919876543210`)**: Simple to search, but Indian telecom operators re-issue deactivated SIM cards/phone numbers after 90 days. If a vendor changes their SIM, the new owner of that phone number could hijack the vendor's paid subscription.
2. **Firebase Auth `uid` as Customer Primary Key**: Anonymous UIDs can be lost if app storage is cleared, requiring a separate business entity anchor.

### Final Decision
Cloudflare Workers generate an immutable, supreme business primary key (`customerId = cus_xxxxxxxxx`) during initial onboarding (`POST /customers/register`).

### Reasoning
An immutable `customerId` permanently anchors the vendor's business entity. All historical `subscriptions` and `payments` tie strictly to `cus_xxxxxxxxx`. This guarantees that if a vendor changes their agency name, updates their phone number, or upgrades their hardware, their underlying subscription ledger remains intact and mathematically isolated from telecom SIM recycling.

### Future Implications
Every API request modifying subscriptions or device status must carry or resolve against `customerId` (`cus_xxxxxxxxx`).

---

## ADR-006: Why Business Name is NOT an Identifier

### Problem
Vendor agency names are not globally unique (`"Sharma Newspaper Agency"` might exist in 50 different cities across India) and are frequently altered (`"Sharma News Agency"` -> `"Sharma & Sons News Depot"`). Using `Business Name` as an identifier causes database collisions and administrative confusion.

### Alternatives Considered
1. **Composite Key (`Business Name + City`)**: Still prone to typos and non-uniqueness.

### Final Decision
`Business Name` is strictly **display and contact information only**. It is **NEVER** used as a primary key, foreign key, or unique identifier.

### Reasoning
Allows vendors to freely correct typos or rebrand their newspaper distribution agency without affecting their subscription validity, invoice history, or Cloudflare identity resolution.

### Future Implications
Support Admins searching the Admin Panel by `Business Name` must be presented with a list of matching `customerId` (`cus_xxxxxxxxx`) records and must verify the exact account using `mobileNumber` or `city` before performing administrative actions.

---

## ADR-007: Why Mobile Number is Editable & Not the Primary Key

### Problem
In India, vendors frequently switch mobile numbers, upgrade SIMs, or use dual-SIM phones where the primary business contact number changes over time. If the mobile number were locked as the immutable primary key, a lost SIM or telecom number change would permanently lock the vendor out of their paid subscription.

### Alternatives Considered
1. **Locked Mobile Number**: Require vendors to purchase a brand new subscription if they change their phone number. (Rejected: Causes severe customer dissatisfaction and churn).

### Final Decision
`mobileNumber` is stored as an **editable contact field** inside `customers/cus_xxxxxxxxx`. It is **NOT** the primary key.

### Reasoning
Allows Support Admins (or self-service profile settings in future updates) to cleanly update a vendor's contact number (`+919876543210` -> `+919988776655`) inside `/customers/cus_xxxxxxxxx` instantly without disrupting active subscriptions, cryptographic leases, or device transfer history.

### Future Implications
Because `mobileNumber` is editable and telecom operators recycle numbers, `mobileNumber` alone is **NEVER** accepted as proof of ownership during device transfers (`See ADR-010`).

---

## ADR-008: Why Old Licensing Remains Untouched During Migration

### Problem
VendSoft currently has active production users who unlocked the app using offline RSA public/private key verification (`offline_license_key`). If the new update removes or breaks `LicenseService.verifyLicenseKey()` before the cloud architecture is 100% rolled out and tested, thousands of paid vendors will wake up locked out of their billing software, causing catastrophic business damage and app store review backlash.

### Alternatives Considered
1. **Hard Sunset / Forced Cloud Activation**: On update, delete `offline_license_key` and force all vendors to connect to the internet to get a `signedLeaseToken`. (Rejected: Breaks offline-first guarantee and locks out offline vendors).

### Final Decision
The existing `TrialService`, `LicenseService`, and `ClockGuardService` implementations and local storage structures (`offline_license_key`, `_cachedLicenseKey`) remain **completely untouched and fully functional** during the entire migration lifecycle.

### Reasoning
Enforces the **Strangler Fig Pattern**. On app launch, `LicenseService` checks legacy offline RSA keys first. If valid, the app unlocks transparently. Meanwhile, `FirebaseInstallationService` registers the composite identity in the background and retrieves the cloud `signedLeaseToken`. Once cached, the cloud lease takes over seamlessly without breaking any existing user workflow.

### Future Implications
Legacy RSA verification code (`verifyLicenseKey()`) remains embedded inside `LicenseService.dart` indefinitely as an unshakeable offline fail-safe.

---

## ADR-009: Why Only One Active Device Per Subscription is Permitted

### Problem
If a single subscription (`PRO_YEARLY` for `1499 INR`) could be activated concurrently across multiple physical devices (`installations`), a single vendor could share their activation key with 50 different newspaper agencies across their city, destroying the software's revenue model.

### Alternatives Considered
1. **Simultaneous Multi-Device Concurrency (e.g., 3 active phones per license)**: Complex to track online/offline concurrency without continuous polling, which violates offline-first autonomy.

### Final Decision
Enforce the **One Active Device Rule**: Each subscription (`sub_xxxxxxxxx`) may only have **ONE ACTIVE INSTALLATION** at any given second. Firestore maintains `activeInstallationId` inside `/subscriptions/sub_xxxxxxxxx`. Every license check (`GET /subscriptions/status`) resolves exclusively against `activeInstallationId`.

### Reasoning
Provides a crystal-clear, mathematically enforceable boundary. If a vendor installs the app on Device B (`inst_B`), Device B cannot activate until `activeInstallationId` is explicitly switched from Device A (`inst_A`) to Device B (`inst_B`), at which exact moment Device A's subscription status transitions to `REVOKED`/`SUPERSEDED`.

### Future Implications
Requires a seamless, zero-friction device transfer mechanism so legitimate vendors who buy a new phone can switch `activeInstallationId` without calling support (`See ADR-010`).

---

## ADR-010: Why Device Transfer Requires Old Device Approval (`Peer-to-Peer`)

### Problem
When a vendor buys a new phone (`inst_NEW`), they need to transfer their active subscription from their old phone (`inst_OLD`). If `Business Name` + `Mobile Number` or simple OTP entry allowed instant transfer, attackers or malicious competitors could easily hijack subscriptions by spoofing phone numbers or intercepting SMS messages.

### Alternatives Considered
1. **Automated 3 Transfers Per Year (Previous Architecture)**: Allowed any device submitting the phone number/OTP to take over the license up to 3 times a year. (Rejected: Vulnerable to SIM recycling and social engineering).
2. **Mandatory Support Call for Every New Phone**: Forces every user buying a new phone to wait for business hours to call customer support. (Rejected: Poor user experience).

### Final Decision
Implement a **Peer-to-Peer Old Device Approval Architecture**:
- **Normal Case**: New device initiates transfer (`POST /transfers/request`). Old device receives notification (`GET /transfers/pending`). **User taps "Approve" on OLD device** (`POST /transfers/approve`). Cloudflare switches `activeInstallationId` and revokes old device. No admin required.
- **Lost or Broken Phone Case**: If old device cannot approve, transfer remains `PENDING`. Vendor contacts support. **Admin manually verifies identity and approves via Admin Panel (`POST /admin/transfers/approve`).** This is the **ONLY** manual recovery flow.

### Reasoning
Eliminates SMS costs, prevents unauthorized account takeover via SIM recycling, and gives the vendor complete self-service control when upgrading phones, while keeping a secure human-verified emergency path for lost/broken hardware.

### Future Implications
Transfers must be strictly safeguarded: **only 1 pending transfer allowed at a time**, expiring after **24 hours (`serverTimestamp() + 24 hours`)**, with every request, approval, rejection, activation, and revocation recorded immutably in `audit_logs`.

---

## ADR-011: Why Paid SMS OTP is Completely Removed

### Problem
Integrating paid SMS OTP gateways (Twilio / Msg91 / MSG91 / Firebase Phone Auth SMS) introduces significant recurring operational costs (`0.15–0.25 INR per SMS`), DLT registration compliance hurdles in India, and high failure rates during telecom congestion or spam filtering. Furthermore, SMS OTP is inherently vulnerable to SIM swapping attacks.

### Alternatives Considered
1. **Firebase Phone Authentication (Mandatory SMS OTP)**: High per-verification cost after free tier and DLT template friction.
2. **WhatsApp OTP Verification**: Cheaper but still incurs per-message template costs.

### Final Decision
**REMOVE any recommendation that Firebase Phone Authentication becomes mandatory. REMOVE mandatory SMS OTP architecture entirely.** Authentication and identity verification rely strictly on **Firebase Anonymous Authentication (`signInAnonymously`) + Composite Hardware/UUID Anchoring + Peer-to-Peer Old Device Approval**.

### Reasoning
Achieves **$0 authentication and verification cost**, **instant zero-friction onboarding** on first launch, and **superior cryptographic security** against SIM-swapping attacks by requiring physical Old Device approval or human Admin verification for device transfers.

### Future Implications
Because no SMS OTP exists, customer identity during lost-phone manual recovery (`Lost or Broken Phone Case`) must be verified by Support Admins via out-of-band billing proof (Razorpay invoice IDs, UPI transaction references, or bank debit screenshots).

---

## ADR-012: Why a Composite Hybrid Device Identity Model is Used

### Problem
Relying on a single device identifier creates catastrophic edge-case vulnerabilities:
- Pure `ANDROID_ID` (`LicenseService().getDeviceId()`) collides to `'UNKNOWN_DEVICE'` on Windows desktop builds or custom privacy ROMs, causing multiple vendors to share the same ID (`BD7D...`).
- Pure `Firebase UID` (`uid`) is lost if the vendor clears app storage (`Clear Data`) or uninstalls/reinstalls on the same phone.
- Pure `installationUuid` (`FlutterSecureStorage`) is lost if storage is wiped without OS cloud backup.

### Alternatives Considered
1. **Single Hardware Anchor (`ANDROID_ID`)**: Fails on desktop and custom ROMs.
2. **Single Storage Anchor (`UUID`)**: Fails on clear storage.

### Final Decision
Implement a **Composite Hybrid Identity Model** consisting of five layers: `customerId` (`cus_xxxxxxxxx`), `installationId` (`inst_xxxxxxxxx`), `hardwareId` (`getDeviceId()`), `installationUuid` (`FlutterSecureStorage`), and `Firebase UID` (`uid`).

### Reasoning
No single identifier is trusted individually. If `ANDROID_ID` returns `'UNKNOWN_DEVICE'`, `installationUuid` ensures uniqueness in Firestore. If the vendor clears app storage and loses `installationUuid`, `getDeviceId()` (`hardwareId`) and `mobileNumber` allow the backend (`AuthGuard` / `registerInstallationIfNeeded`) to cleanly recognize the returning hardware and restore their active session without double-charging or locking out their account.

### Future Implications
All Worker control plane endpoints must accept and evaluate composite headers (`x-customer-id`, `x-installation-id`, `x-hardware-id`, `x-installation-uuid`, `Authorization: Bearer <ID_TOKEN>`).

---

## ADR-013: Why Cloudflare Workers are the ONLY Trusted Backend

### Problem
If the Flutter client application directly updated Firestore documents (`subscriptions.status = "ACTIVE"`) or processed payment webhooks locally, attackers could easily decompile the APK (`jadx`) and write fake subscription records directly to the cloud database, granting themselves lifetime free access.

### Alternatives Considered
1. **Client-Side Razorpay Payment Verification + Direct Firestore SDK Write**: Client pays via Razorpay, gets success callback, and writes `status: ACTIVE` to Firestore using client SDK. (Rejected: Completely untrusted and trivial to exploit).

### Final Decision
**Only Cloudflare Workers are allowed to modify `subscriptions`, `plans`, `payments`, `device_transfers`, `installations.status`, activations, expiry dates, bans, and transfers.** The Flutter application and end-users have **0% write permissions** to these collections in `firestore.rules`.

### Reasoning
Enforces an impenetrable **Zero-Trust Security Boundary**. Cloudflare Workers execute in secure server-side V8 isolates using Google Cloud Service Account credentials. They verify Razorpay webhook HMAC SHA-256 signatures (`x-razorpay-signature`) and execute atomic Firestore transactions (`runTransaction`) completely out of reach of client-side APK memory patching or clock manipulation.

### Future Implications
Every new feature requiring state modification or entitlement changes must be implemented as a secure REST endpoint on Cloudflare Workers, never via direct Firestore client SDK writes.

---

## ADR-014: Asymmetric Cryptography for Offline Validation

### Problem
In the initial `v1.0.0` architecture, the Cloudflare Worker generated the `signedLeaseToken` using a Symmetric HMAC-SHA256 signature (`env.LEASE_SIGNING_SECRET`). However, a Flutter client application cannot mathematically verify an HMAC signature while offline without embedding the symmetric secret directly into the APK source code. If embedded, a malicious actor could decompile the APK, extract the secret, and generate mathematically valid, forged lease tokens granting themselves lifetime access without paying.

### Alternatives Considered
1. **Symmetric HMAC Validation**: Embed the secret in the app. (Rejected: Fatal security flaw, guaranteed to be extracted via decompilation).
2. **Server-Side Only Validation**: Force the app to connect to Cloudflare to verify the token. (Rejected: Violates the strict Offline-First mandate of `ADR-001`).

### Final Decision
The `signedLeaseToken` must be generated by Cloudflare Workers exclusively using an **RSA Asymmetric Private Key** (`env.RSA_PRIVATE_KEY` / `RSASSA-PKCS1-v1_5`). The Flutter client application (`LicenseService.dart`) must cryptographically verify the signature against an embedded **RSA Public Key** before parsing the token's expiration date or unlocking the app.

### Reasoning
Asymmetric cryptography guarantees that the Flutter app can mathematically prove the token was issued by the authoritative Cloudflare Worker without ever knowing the Private Key. Even if the APK is fully decompiled, the attacker only obtains the Public Key, which cannot be used to forge new signatures. This completely eliminates offline license spoofing.

### Future Implications
The authoritative `private.pem` must be kept highly secure and injected into Cloudflare Workers via Wrangler Secrets (`npx wrangler secret put RSA_PRIVATE_KEY`). It must never be committed to the repository.
