# Runtime Receipt Bug Investigation (PAUSED)

## 1. Original Bug Description
1. A receipt is visible in Pending.
2. User swipes it and marks it as Submitted/Paid.
3. The receipt immediately disappears from Pending.
4. The receipt immediately appears in Submitted.
5. Everything appears correct.
6. A few seconds later, WITHOUT ANY USER ACTION, the receipt disappears from Submitted.
7. The same receipt returns to Pending.

The user never tapped anything, never left the screen, and never received a WhatsApp error. 

## 2. Reproduction Steps
1. Navigate to the Receipts tab.
2. Swipe a receipt from left to right (DismissDirection.startToEnd) to mark it as "Sent" (Submitted).
3. Observe the receipt move from the "Pending" list to the "Submitted" list.
4. Wait a few seconds without touching the screen.
5. Observe the receipt unexpectedly return to the "Pending" list.

## 3. Affected Devices
- **Affected:** Specific Android devices (models not yet specified).
- **Not Affected:** Standard development emulators, some other Android devices.

## 4. Hypotheses Investigated
1. **Async SAF Write Failure / Rollback:** The `saveCustomers()` disk write fails, causing a state rollback.
2. **Background Process State Overwrite:** A background listener (like `LicenseService`, `CooldownService`, or `ConfigService`) triggers a reload, overwriting the in-memory state with stale disk state.
3. **ReceiptsTab UI State / ListenableBuilder Bug:** The UI builds incorrectly or `_computeQueues()` filters the lists incorrectly based on the current `receiptStatus`.
4. **Dart Object Reference Bug:** The modified `Customer` object `c` in `_pendingReceipts` does not actually mutate the object within `allCustomers`.
5. **Activity Recreation (Leading Hypothesis):** The Android OS kills and recreates the app's Activity (e.g., due to memory constraints or system UI/SAF permission dialogs opening), causing `initState()` to run, which triggers a forceful reload of the Excel data from disk, overwriting the in-memory changes.

## 5. Hypotheses Eliminated
- **Async SAF Write Failure / Rollback:** `saveCustomers()` does not implement a rollback on failure. If the SAF write fails, the in-memory state remains `"Sent"`.
- **Background Process State Overwrite:** All background polling triggers (`RESTORED`, `REVOKED`) call `_loadSettings(isLifecycleReload: true)`. This parameter activates a guard `(!isLifecycleReload || _excelService.allCustomers.isEmpty)` which blocks `loadFromUri()` from executing, preserving the in-memory state.
- **ReceiptsTab UI State / ListenableBuilder Bug:** `_computeQueues()` correctly creates new lists referencing the objects in `allCustomers`.
- **Dart Object Reference Bug:** Dart objects are passed by reference. Mutating `c.receiptStatus` successfully mutates the instance within `allCustomers`.
- **Background File Watcher:** No native file observers (`FileObserver`, `EventChannel`) exist to automatically pull data if the file is modified externally.

## 6. Current Leading Hypothesis
**Android Activity Recreation.** 
The only automated Dart execution path that can forcefully replace `allCustomers` with stale disk data is `_loadSettings(false)`. The only place this is called automatically is within the `initState()` of `_ImageSenderAppState`. This implies the Android OS is destroying and recreating the Activity while the user is interacting with it (or immediately after), causing a fresh load from disk.

## 7. Why it is NOT yet considered proven
The leading hypothesis relies on the assumption that Activity Recreation is occurring on the specific affected devices. Without runtime evidence (logs from the actual device showing `initState()` firing when it shouldn't), this remains an inference. The user correctly demanded concrete proof that this lifecycle event actually happened during the exact moment the bug occurred.

## 8. Files Analyzed
- `lib/main.dart` (Lifecycle, `_loadSettings`)
- `lib/services/excel_service.dart` (`loadFromUri`, `_parseExcelBytes`, `saveCustomers`, `_executeSave`)
- `lib/screens/receipts_tab.dart` (Swipe handler, `_computeQueues`, UI rebuilds)
- `lib/models/customer.dart` (Data model, `toJson`, `isPaid`)
- `lib/services/backup_service.dart` (Database restore operations)
- `lib/services/file_access_service.dart` (SAF integration)
- `lib/services/license_service.dart` (Background polling)

## 9. Relevant Functions
- `_ImageSenderAppState.initState()`
- `_ImageSenderAppState.didChangeAppLifecycleState()`
- `_ImageSenderAppState._loadSettings()`
- `ExcelService.loadFromUri()`
- `ExcelService._parseExcelBytes()`
- `ExcelService.saveCustomers()`
- `ReceiptsTab.confirmDismiss()` (Swipe handler)
- `ReceiptsTab._computeQueues()`

## 10. Diagnostic Logs (Previously Added & Removed)
To capture the execution path, the following diagnostic logs were temporarily injected (and subsequently removed to pause the investigation):
- Method entry/exit logs for lifecycle methods (`main`, `initState`, `dispose`, `didChangeAppLifecycleState`, `build`).
- Method entry/exit logs for data flow (`loadFromUri`, `_parseExcelBytes`, `saveCustomers`, `notifyListeners`, `_computeQueues`).
- Guard condition evaluations in `_loadSettings()`.
- StackTraces for `loadFromUri()`.
- Object Identity Hashes (`identityHashCode`) for `allCustomers` and the swiped `Customer` object.
- List lengths for `allCustomers`, `_pendingReceipts`, and `_submittedReceipts`.
- Object state values (`receiptStatus`, `paymentStatus`) before and after mutation.

## 11. Log Insertion Points (Reference for Future Re-instrumentation)
- `lib/utils/diagnostic_logger.dart`: Custom logger class.
- `lib/main.dart`: `main()`, `initState()`, `dispose()`, `didChangeAppLifecycleState()`, `_loadSettings()`, `build()`.
- `lib/services/excel_service.dart`: `loadFromUri()`, `_parseExcelBytes()`, `saveCustomers()`, `notifyListeners()`.
- `lib/screens/receipts_tab.dart`: `initState()`, `dispose()`, `didChangeAppLifecycleState()`, `didUpdateWidget()`, `build()`, `_computeQueues()`, inside `confirmDismiss` startToEnd condition.

## 12. Instructions for Collecting Logs
When the affected device is available:
1. Re-apply the diagnostic instrumentation (see points 10 & 11).
2. Connect the affected device to the development machine via USB or Wireless Debugging.
3. Ensure USB Debugging is enabled in the device's Developer Options.
4. Run the app in debug mode or capture logcat from a release build.
5. Reproduce the bug on the device.
6. Save the console output to a text file.

## 13. Exact ADB / Flutter Commands to Capture Logs
If running via Flutter:
```bash
flutter run
# (Output will stream to the terminal. Copy/paste or pipe to a file: flutter run > bug_logs.txt)
```

If capturing from an already installed app via ADB:
```bash
adb logcat -c  # Clear existing logs
adb logcat | grep DIAGNOSTIC > receipt_bug_logs.txt
# (Assuming the diagnostic logger prefixes logs with [DIAGNOSTIC])
```

## 14. Step-by-Step Runtime Testing Procedure
1. Start log capture.
2. Open the app and navigate to the Receipts tab.
3. Note the current time.
4. Swipe a receipt from Pending to Submitted.
5. Watch the screen. **Do not touch anything.**
6. Note the exact time the receipt disappears from Submitted and returns to Pending.
7. Stop log capture.

## 15. How to interpret the logs
- **Did Activity Recreation occur?** Look for `main()` or `_ImageSenderAppState.initState()` in the logs immediately after the swipe. If present, the Activity was recreated. Look at `didChangeAppLifecycleState` logs for `paused` / `resumed`.
- **Was `allCustomers` replaced?** Look for `ExcelService._parseExcelBytes() COMPLETED`. Compare the `identityHashCode(allCustomers)` before and after this log. If the hash changes, the list was replaced.
- **Was the `Customer` object replaced?** Compare the `identityHashCode(customer)` from the `confirmDismiss` swipe log against the hash in the `_computeQueues()` log when it reverts. If the hashes differ, the object was replaced.
- **Did `loadFromUri` execute?** Check the logs for `ExcelService.loadFromUri() called` and inspect the captured StackTrace to see who called it.
- **Did `_loadSettings` execute?** Check for `_loadSettings() evaluating loadFromUri`. Check if `GUARD PASSED` or `GUARD BLOCKED` is logged.
- **Did `notifyListeners` cause the rebuild?** Check if `ExcelService.notifyListeners() called` immediately precedes `ReceiptsTabState.build()` and `_computeQueues() STARTED`.

## 16. Unanswered Questions
- What exact function executes immediately before the receipt returns to Pending?
- If Activity Recreation is not occurring, what external or native trigger is causing `loadFromUri` to bypass the guard?
- Is there a silent crash/restart happening on the specific affected devices that isn't visible to the user?

## 17. Checklist for Completing the Investigation
- [ ] Re-add diagnostic instrumentation.
- [ ] Connect affected device and capture runtime logs during bug reproduction.
- [ ] Analyze logs to pinpoint the exact execution sequence.
- [ ] Identify the root cause function.
- [ ] Propose and implement a targeted fix.
- [ ] Verify the fix on the affected device.
- [ ] Remove all diagnostic instrumentation permanently.

## 18. IMPORTANT REMINDER
**NO FIX HAS BEEN IMPLEMENTED.** The investigation is currently paused because the root cause has not yet been proven with runtime evidence. Do not implement any speculative fixes until the logs from the affected device have been captured and analyzed.
