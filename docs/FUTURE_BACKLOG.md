# VendSoft Future Product & Architectural Backlog (`Version 1.0 Postponed Features`)

> [!CAUTION]
> **GOVERNANCE MANDATE**: No item in this document may be implemented before Version 1.0 is complete across all phases (`Phase 1.1` through `Phase 5`) unless explicitly approved by the project owner in writing. This backlog represents features that were evaluated, documented, and intentionally deferred to keep the Version 1.0 core control plane lightweight, ultra-reliable, and strictly focused on offline-first billing autonomy.

---

## 1. Authentication & Identity Enhancements
- **Google Sign-In (`OAuth 2.0`)**: Allowing vendors to bind their `customerId` to a Google account for cross-platform cloud recovery.
- **WhatsApp Sign-In / Passwordless Verification**: Using official WhatsApp Business API to deliver instant 1-click login links.
- **Optional SMS OTP Verification**: Re-introducing optional paid SMS OTP strictly for enterprise users willing to pay for dedicated telecom verification.
- **Biometric App Lock (`TouchID / FaceID`)**: Requiring fingerprint or facial recognition on app launch before viewing financial reporting or customer spreadsheets.

---

## 2. Payments & Billing Innovations
- **Dynamic Coupon & Promo Code Engine**: Allowing vendors to enter discount codes (`FESTIVAL500`, `NEWYEAR20`) during checkout, validated and discounted by Cloudflare Workers.
- **Referral & Affiliate Reward Program**: Granting existing vendors `+30 days` of free subscription extension for every new agency they successfully refer that completes a `PRO_YEARLY` purchase (`referralCode` tracking).
- **Lifetime License Plan (`PRO_LIFETIME`)**: A one-time high-ticket purchase tier with perpetual validity (`durationDays: 36500`).
- **Premium Plus Tier (`PRO_ENTERPRISE`)**: Advanced tier unlocking multi-branch management, custom thermal receipt logos, and priority WhatsApp API routing.
- **Automated Recurring Billing (Razorpay e-Mandate / UPI Autopay)**: Automatically debiting annual renewal fees without requiring manual checkout clicks.

---

## 3. Cloud Synchronization & Data Capabilities
- **Encrypted Cloud Backup (`Google Drive / Cloudflare R2`)**: Allowing vendors to opt into automated end-to-end encrypted daily backups of their local `/storage/emulated/0/VendSoft/customers.xlsx` and SQLite database to cloud object storage.
- **Real-Time Cloud Data Sync (`Multi-Device Seat Management`)**: Enabling large newspaper distribution agencies to purchase 5 or 10 active delivery boy seats sharing a synchronized cloud customer route database.
- **Automated PDF Report Dispatch**: Cloudflare Workers generating monthly GST tax summaries and emailing them directly to the agency owner's accountant.

---

## 4. Admin Panel Enterprise Features
- **Enterprise Role-Based Access Control (RBAC)**: Fine-grained permissions (`Super Admin`, `Regional Support Lead`, `Billing Analyst`, `Read-Only Auditor`) with action-based approval hierarchies.
- **Geo-Distribution & Live Activity Heatmaps**: Visualizing active newspaper delivery routes across Indian cities (`Lucknow`, `Patna`, `Jaipur`, `Delhi`) using clustered map markers.
- **Automated Fraud Scoring Engine**: Machine learning anomaly detector flagging suspicious device rotations, repeated clock rollbacks, or abnormal checkout failure patterns.

---

## 5. Reporting & Advanced Analytics
- **Cohort Retention & Churn Dashboards**: Tracking exact renewal conversion rates of `DEMO_FREE` vendors at Day 7, Day 14, and Day 30.
- **Exportable Accounting Integrations**: One-click direct synchronization with Indian accounting software (`Tally Prime`, `Zoho Books`, `ClearTax`).

---

## 6. Notifications & Messaging Infrastructure
- **Push Notification Campaigns (`FCM Broadcasts`)**: Sending targeted promotional push notifications or system maintenance alerts to segmented customer tiers.
- **Automated WhatsApp Renewal Bot**: Integrating Cloudflare Workers with WhatsApp Cloud API to automatically dispatch personalized payment reminders 7 days and 1 day prior to `expiresAt`.

---

## 7. Remote Configuration & Edge Integrations
- **Advanced A/B Testing Engine**: Experimenting with different pricing tiers (`1299 INR` vs `1499 INR`) or checkout UI layouts via dynamic edge flags.
- **Third-Party Thermal POS Hardware Auto-Discovery**: Built-in BLE/Network auto-configuration profiles for over 50 specific models of Chinese and Indian ESC/POS thermal receipt printers (`Epson`, `TVS`, `Rugtek`, `Everycom`).
