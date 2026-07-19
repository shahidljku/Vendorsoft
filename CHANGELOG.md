# Changelog

All notable changes to the VendSoft project will be documented in this file.

## [Unreleased] - Implementation Phase Complete (v1.0.0)

### Backend
- **Device Transfers:** Modified the `admin/transfer-device` endpoint to clear `deviceId`, `modelName`, `hardwareId`, `licenseKey`, and `pushToken` on the target customer document, forcing a clean reactivation state for the new device while preserving account ownership (Fixes Issue 3).

### Frontend
- **Lifecycle & Navigation:**
  - Standardized the app's startup flow to automatically intercept transferring/banned users and redirect them to the proper screen (`UpdateRequiredScreen`, `DeviceTransferredScreen`, etc.).
  - Banned the legacy practice of re-registering via the old generic registration flow when transferring a device. The frontend now natively recognizes and auto-authenticates the previous mobile number when migrating via the `ActivationScreen` (Fixes Issue 4 & 6).
- **Authentication & Logout:** 
  - Added an explicit **"Logout"** option in the Hamburger Drawer (`main_layout.dart`), which hits the backend logout endpoint, wipes FCM tokens from Firestore, clears `SharedPreference` local credentials, and redirects to `ActivationScreen` (Fixes Issue 5).
  - Ensured complete isolation between sessions by invoking `ExcelService().clearData()` on logout, guaranteeing no data leaks (like cached Excel queues) when switching accounts (Fixes Issue 7).
- **State Management:**
  - Hardened the core WhatsApp auto-dispatch loop (`ReceiptsTab`) against out-of-bounds `IndexErrors` and violent UI flicker. Eliminated dangerous `WidgetsBinding.instance.addPostFrameCallback()` mutations on the global Excel provider. The presentation array sizes are now strictly locked during `_isSending`, guaranteeing deterministic batch execution (Fixes Issue 1 & 2).
- **UI & Experience Improvements (UX):**
  - Refactored `BillsTab` search. Removed redundant keyword parsing (`unpaid`, `failed`, etc.) from the text field, explicitly binding the field to numeric Bill Numbers via `TextInputType.number` and `FilteringTextInputFormatter.digitsOnly` (Fixes Issue 8).
  - Fixed standard A4 PDF layout alignment in `ReportsTab`. Re-aligned the "Amount" column to strictly align right using `pw.Alignment.centerRight` and widened the "Name of Customer" flex proportion to avoid severe text wrapping (Fixes Issue 11).
  - Explicitly documented the Android OS requirement for `Location` permissions inside the onboarding permission prompt (`_PermissionInfoRow`), warning older device owners that Location is necessary for Bluetooth thermal printer discovery (Fixes Issue 13).
  - Added an intelligent Plan Expiration banner to `DashboardTab`. Subscriptions expiring within 7 days display a warning banner. Fully expired plans flip the banner to a red critical alert (Fixes Issue 15).

### Bug Fixes
- UI Flicker during background automation (`ReceiptsTab`).
- Index slipping returning submitted receipts to pending (`ReceiptsTab`).
- Transfer device leaving stale hardware IDs in the database (`admin.ts`).
- Transfer device auto-login bypassing security hooks (`activation_screen.dart`).
- Data leaks across user accounts missing deep memory wipe (`ExcelService`).

### Known Limitations
- The Android permissions flow uses aggressive prompt strategies during the onboarding phase, which is intentional for full thermal-printer/Bluetooth support across API levels, but requires the user to proactively hit "Allow" repeatedly on older devices.
- `SettingsService` currently relies on Shared Preferences. Extensive state clears on logout assume local file configurations safely reset, but any future persistent cache files might need auditing if new caching mechanisms are introduced.
