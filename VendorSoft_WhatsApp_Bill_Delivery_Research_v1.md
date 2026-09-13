# VendorSoft WhatsApp Bill Delivery Research v1
**Baseline Research Record & Architectural Blueprint**
**Date**: September 2026
**Target Application**: VendorSoft Android (`com.vendorsoft.app` / `e:\image_sender`)

---

## 1. Business Requirements & Operational Context

VendorSoft is an Android billing application used by retail and route distribution vendors.

### The Real-World Workflow
At the close of each billing cycle (typically month-end), the vendor generates individual customer bills:
* **Customer A** $\to$ **Bill A** $\to$ **Customer A's WhatsApp**
* **Customer B** $\to$ **Bill B** $\to$ **Customer B's WhatsApp**
* **Customer C** $\to$ **Bill C** $\to$ **Customer C's WhatsApp**

Key Business Realities:
1. **Legitimate Transactional Utility**: Every message is an individual accounting invoice delivered to an established commercial customer. This is not cold marketing, unsolicited advertising, or bulk broadcast spam.
2. **Local Address Book**: The vendor already has 100% of these customer phone numbers saved in the local device address book.
3. **Primary Invariant**: **A customer's bill must never be sent to another customer.** Cross-sending invoices violates commercial confidentiality and breaks vendor-client trust.
4. **Current Crisis**: A recent update attempting to eliminate miss-clicks (which occurred due to coordinate jitter) and increase dispatch speed switched the click method to `AccessibilityNodeInfo.ACTION_CLICK` and reduced dwell times. Immediately afterward, WhatsApp began restricting/banning the vendor's account daily.
5. **Timeline & Scope**: The developer has university exams and cannot execute an official WhatsApp Business Cloud API integration right now. A robust, conservative, and reliable stopgap is needed for the Android application to keep the vendor operational for the next few weeks without account bans, miss-clicks, or customer cross-deliveries.

---

## 2. Research Audit: Classification of Previous Claims

Every assertion from the initial research has been evaluated under strict engineering standards:

### A. Android Framework Facts

| Statement / Claim | Classification | Evidence / Source |
| :--- | :--- | :--- |
| `AccessibilityNodeInfo.ACTION_CLICK` invokes the node's `OnClickListener` directly via IPC without generating input events. | **VERIFIED** | AOSP `View.java`, `performAccessibilityActionInternal()`. Direct callback invocation; bypasses the hardware touch pipeline. |
| `AccessibilityService.dispatchGesture()` injects `MotionEvent` structures (`ACTION_DOWN`, `ACTION_UP`) into the system touch pipeline. | **VERIFIED** | AOSP `MotionEventInjector.java` & `AccessibilityService.java`. Injects events with `source = InputDevice.SOURCE_TOUCHSCREEN`. |
| `AccessibilityWindowInfo` and `TYPE_WINDOW_STATE_CHANGED` report window changes and activity transitions. | **VERIFIED** | Android API documentation. Informs when `MediaComposerActivity` or `Conversation` gains/loses window focus. |
| `dispatchGesture()` makes automation completely invisible to target applications. | **FALSE / CONTRADICTED** | Target apps can detect active accessibility services via `AccessibilityManager.isEnabled()` and inspect `FLAG_INJECTED_FROM_ACCESSIBILITY` in system policy. |
| Bounding box randomization ("jitter") across a circular button prevents miss-clicks. | **FALSE / CONTRADICTED** | Circular FABs inscribed in square bounding boxes have dead space in the corners. Randomizing across the rectangle increases miss-click probability. Centroid targeting is mathematically superior. |

### B. WhatsApp-Specific Claims

| Statement / Claim | Classification | Evidence / Source |
| :--- | :--- | :--- |
| WhatsApp's backend grants automated messaging exemptions for billing invoices. | **FALSE / CONTRADICTED** | [WhatsApp Business Terms of Service](https://www.whatsapp.com/legal/business-terms/) Section 1 strictly prohibits unauthorized automated interactions regardless of message content. |
| The vendor saving customer contacts in his phone prevents WhatsApp spam flagging. | **FALSE / CONTRADICTED** | The "Report / Block" prompt on the recipient's phone depends on whether the *recipient* has saved the *vendor*, not vice versa. Outbound network velocity triggers backend abuse filters independently of sender contact labels. |
| WhatsApp explicitly detects and labels `ACTION_CLICK` as a synthetic bot click. | **PLAUSIBLE BUT UNPROVEN** | `ACTION_CLICK` skips `onTouchEvent()`. However, WhatsApp's proprietary native C++ client code is obfuscated. There is no public reverse-engineering proof confirming direct `ACTION_CLICK` inspection. |
| Rapid foreground/background cycling ($\approx 50\text{ms}$) creates an overt machine anomaly. | **STRONGLY SUPPORTED** | Pulling WhatsApp to foreground, firing a click, and immediately executing `FLAG_ACTIVITY_REORDER_TO_FRONT` to snatch focus back within 1.2 seconds interrupts media compression and socket setup. Doing this 30 times in tight succession is an anomalous signature. |
| Specific coordinate jitter ($\pm 5\text{px}$) prevents account restrictions. | **SPECULATION** | Zero evidence exists that Meta uses client-side touch spatial clustering algorithms to restrict accounts. |
| There is a known "safe" delay (e.g., 6.5s) or "safe" batch size that guarantees no bans. | **FALSE / CONTRADICTED** | Meta publishes no safe threshold for unofficial automation. All unofficial automation is subject to heuristic enforcement. |
| `com.whatsapp:id/send_container` is a Send button. | **FALSE / CONTRADICTED** | Decompiled layout dumps and AOSP accessibility trees prove `send_container` is a `ViewGroup` spanning the entire screen bottom ($\approx 1080\text{px}$). Targeting it clicks caption inputs or dead space. |

---

## 3. Independent Audit of Proposed Architecture Components

| Component | 1. Problem Solved | 2. Real in VendorSoft? | 3. How Would It Fail? | 4. Simpler Alternative | 5. Keep / Reject? |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **A. BillTransaction / Identity Lock** | Cross-sending bills; race conditions between async callbacks and queue index. | **YES (Critical)**. Customer A receiving Customer B's bill is fatal. | Bad state deserialization or index mismatch. | Pass immutable `BillTransaction` object directly through intent and callbacks. | **KEEP (Essential)** |
| **B. Multi-Criteria Send-Button Scoring** | Targeting wrong UI elements (e.g., `send_container`, caption button). | **YES**. Miss-clicks broke previous releases. | Over-engineered scoring weight drift. | 4 Hard Boolean Gates (size $\le 78\text{dp}$, aspect ratio diff $\le 0.25$, bottom-right quadrant, leaf node). | **KEEP (Simplified)** |
| **C. 2-Frame Button Stability Detection** | Clicking button while entrance animation is still moving, causing clicks to miss. | **YES**. FAB slides up from bottom of screen. | Button animates longer than observation timeout. | Record bounds at $t_0$, wait $150\text{ms}$, record bounds at $t_1$. Compare $\Delta \le 2\text{px}$. | **KEEP (Essential)** |
| **D. Event-Driven State Machine** | Racing WhatsApp lifecycle; blindly sleeping arbitrary seconds. | **YES**. Focus-snatching races media upload. | Target app changes activity names after update. | Listen to `TYPE_WINDOW_STATE_CHANGED` (`MediaComposer` $\to$ `Conversation`) with a safety timeout. | **KEEP (Essential)** |
| **E. Safety Circuit Breaker** | Cascading failures; continuing to spam WhatsApp after account warning or crash. | **YES**. Account bans happen when app blindly repeats failing operations. | False positive trips on slow phones. | Trip on: restriction dialog, 2 consecutive failures, or unexpected activity loop. | **KEEP (Essential)** |
| **F. Vendor-Controlled Batches** | Unchecked bulk velocity; inability for vendor to review progress. | **YES**. Vendor needs operational control. | Vendor clicks "Send All" carelessly. | UI buttons: `Send Next 5`, `Send Next 10`, `Send Next 20`, `Send All`. Post-batch summary modal. | **KEEP (Essential)** |
| **G. Manual Fallback** | Automation failure leaves vendor stranded. | **YES**. Some customers have edge-case issues. | Vendor forgets to press send in manual mode. | Button "Send Manually" opens chat + image without auto-clicking. | **KEEP (Essential)** |
| **H. Persistent Queue / Idempotency** | Duplicate sends on app crash, force-close, or OS process death. | **YES**. Duplicate billing confuses customers. | Database schema migration bugs. | Atomic local JSON ledger (`transactions.json`) with states: `PENDING`, `STAGED`, `IN_FLIGHT`, `CONFIRMED`, `FAILED`, `UNCERTAIN`. | **KEEP (Essential)** |

---

## 4. Operational State Machine Design

The automated send flow progresses through observable UI and lifecycle events rather than blind sleeps:

```text
       [ PENDING ]
            │  (Pre-flight validation: file readable, 10-digit phone, not already confirmed)
            ▼
        [ STAGED ]
            │  (Persist to ledger, generate Transaction ID, bind Customer + Bill)
            ▼
       [ IN_FLIGHT ]
            │  (Launch WhatsApp Intent with jid & image URI)
            ▼
 [ WAIT_FOR_COMPOSER ] ───(Timeout > 10s)───► [ FAILED: COMPOSER_TIMEOUT ]
            │
            ▼  (Observed: MediaComposerActivity visible)
 [ DISCOVER_SEND_BUTTON ] ───(Not found after 3s)───► [ FAILED: BUTTON_NOT_FOUND ]
            │
            ▼  (Candidate passes 4 Hard Gates)
  [ VERIFY_STABILITY ] ───(Movement detected)───► Re-observe up to 800ms
            │
            ▼  (Position delta <= 2px across 150ms)
    [ DISPATCH_GESTURE ]
            │  (110ms touchscreen stroke at exact centroid)
            ▼
   [ WAIT_FOR_EXIT ] ───(No transition in 8s)───► [ UNCERTAIN: TRANSITION_TIMEOUT ]
            │
            ▼  (Observed: MediaComposerActivity exits -> Conversation appears)
  [ POST_SEND_DWELL ]
            │  (Hold focus in WhatsApp for 1,500ms to allow socket setup & compression)
            ▼
   [ VERIFY_RESULT ]
    ├── Activity == Conversation ──────► [ CONFIRMED ]
    ├── Restriction Dialog Detected ───► [ CIRCUIT_BREAKER_TRIGGERED ]
    └── Timeout / Unexpected Screen ───► [ UNCERTAIN ]
            │
            ▼
 [ RETURN_TO_VENDORSOFT ]
            │  (Reorder VendorSoft to front)
            ▼
 [ UPDATE_LEDGER & UI ]
```

---

## 5. Send-Button Targeting: 4 Hard Boolean Gates

To permanently eliminate both miss-clicks and dependency on brittle, single-resource IDs:

### Gate 1: Dimensional Bounding
* Maximum width: $\le 78\text{dp}$
* Maximum height: $\le 78\text{dp}$
* Minimum width & height: $\ge 40\text{dp}$
* **Purpose**: Immediately rejects `send_container`, caption input bars, and fullscreen preview overlays.

### Gate 2: Aspect Ratio Symmetry
* $\frac{|\text{width} - \text{height}|}{\max(\text{width}, \text{height})} \le 0.25$
* **Purpose**: Circular Floating Action Buttons (FABs) are square bounding boxes. Reject rectangular banners.

### Gate 3: Spatial Quadrant
* $X_{\text{center}} > 0.55 \times \text{ScreenWidth}$
* $Y_{\text{center}} > 0.65 \times \text{ScreenHeight}$
* **Purpose**: In WhatsApp's media preview, the Send FAB is always located in the lower-right quadrant.

### Gate 4: Actionable Leaf Node
* Node must be clickable OR have 0 children (leaf). If a leaf matches, traverse ancestors up to 3 levels for `isClickable`.
* **Centroid Targeting**: Tap at $(C_x, C_y) = (\text{rect.centerX()}, \text{rect.centerY()})$ with 0 random jitter.

---

## 6. Motion Stability Check (Anti-Animation-Race)

1. Find candidate button at time $t_0$, record bounds $R_0 = (x_0, y_0, w_0, h_0)$.
2. Wait an observation delta $\Delta t = 150\text{ms}$.
3. Query active node tree again at time $t_1$, record bounds $R_1 = (x_1, y_1, w_1, h_1)$.
4. Compute displacement:
   $$\Delta_{\text{pos}} = |x_1 - x_0| + |y_1 - y_0|$$
5. If $\Delta_{\text{pos}} \le 2\text{px}$ and $R_1$ satisfies the 4 Gates: **Button is stationary. Proceed to tap.**
6. If $\Delta_{\text{pos}} > 2\text{px}$: Button is animating. Re-check every $100\text{ms}$ up to a maximum safety threshold of $800\text{ms}$. If still moving after $800\text{ms}$, abort to `FAILED: UNSTABLE_UI`.

---

## 7. Timing & Lifecycle Synchronization

* **Eliminate arbitrary fast switches**: Replace the 50ms focus snatch with an event-driven sequence:
  1. Wait for `MediaComposerActivity` to exit.
  2. Confirm entrance into `Conversation` activity.
  3. Dwell $1,500\text{ms}$ in foreground while WhatsApp commits the media file to its local SQLite database and initializes the network socket.
  4. Bring VendorSoft to front.
* **Calm Settling Interval**: Between customer dispatches, enforce a $4.0\text{s}–6.0\text{s}$ settling window to allow background GC and system threads to quiet down.

---

## 8. Safety Circuit Breaker

The system halts execution immediately upon detecting abnormal conditions:
1. **Restriction / Ban Alert**: Any window or dialog containing text matching: `"banned"`, `"restricted"`, `"temporarily unavailable"`, `"terms of service"`, `"review"`, `"verification"`.
2. **Consecutive Failures**: If 2 transactions fail in succession.
3. **Repeated Uncertainties**: If 2 transactions result in `UNCERTAIN`.
4. **Recipient Mismatch**: If chat destination does not match target contact.

When tripped:
* Automatically set `autoSendEnabled = false`.
* Cancel all pending queue actions.
* Persist current transaction state as blocked.
* Display full diagnostic alert to the vendor with manual recovery options.

---

## 9. Customer-to-Bill Protection Model

To guarantee Customer A never receives Customer B's bill:
1. **Immutable Binding**:
   $$\text{BillTransaction} = \langle \text{TransactionUUID}, \text{CustomerId}, \text{CustomerPhone}, \text{BillId}, \text{BillingPeriod}, \text{ImagePath}, \text{ImageSHA256}, \text{Status} \rangle$$
2. **Pre-flight Checks**:
   * Verify file exists on disk and is readable.
   * Verify clean phone number has exactly 10 digits.
   * Verify this `(CustomerId, BillId, BillingPeriod)` is not already `CONFIRMED` in the ledger.
3. **Decoupled Callbacks**:
   * Callbacks and broadcasts must include `TransactionUUID`.
   * If a broadcast returns for a transaction ID that does not match the active `IN_FLIGHT` job, it is discarded.

---

## 10. Persistent Queue & Idempotency Rules

* **Ledger File**: Atomic JSON file (`bill_ledger.json`) stored in private app storage.
* **States**:
  * `PENDING`: Not started.
  * `STAGED`: Verified, ready for dispatch.
  * `IN_FLIGHT`: WhatsApp intent issued. Only 1 job may be `IN_FLIGHT` at any time.
  * `CONFIRMED`: Verified sent. Never automatically re-sent.
  * `FAILED`: Terminal error before or during send. Retryable only via explicit vendor action.
  * `UNCERTAIN`: State unclear (e.g. timeout during upload). Locked. Never automatically re-sent.
* **Crash Recovery**: On app restart, any job left `IN_FLIGHT` transitions to `UNCERTAIN`. It is never re-dispatched automatically.

---

## 11. Vendor Workflow Controls

1. **Batch Sizing Options**:
   * `Send Next 5`
   * `Send Next 10`
   * `Send Next 20`
   * `Send All Pending`
2. **Post-Batch Review Modal**:
   * Displays breakdown: `X Confirmed`, `Y Failed`, `Z Uncertain`.
   * Requires explicit vendor button press to initiate the next batch.
3. **Manual Fallback**:
   * Every bill item has a "Send Manually" option.
   * Opens WhatsApp chat with attached image but leaves `autoSendEnabled = false`.

---

## 12. Implementation Plan & Order (v1)

1. **Phase 1: Data Model & Ledger**: Implement `BillTransaction` and `TransactionLedger` in Dart.
2. **Phase 2: Android Accessibility Engine**: Clean up `ImageSenderAccessibilityService.kt` (remove `send_container`, implement 4 Hard Gates, 2-frame stability check, centroid tap, $1.5\text{s}$ post-send dwell).
3. **Phase 3: Lifecycle Bridge**: Update `MainActivity.kt` to transmit transaction IDs and handle `UNCERTAIN` / `CIRCUIT_BREAKER` broadcasts.
4. **Phase 4: Queue Controller**: Refactor `sending_screen.dart` to use the immutable transaction model and circuit breaker.
5. **Phase 5: Vendor UI Controls**: Add batch sizing and manual fallback in `bills_tab.dart`.
6. **Phase 6: Device Verification**: Execute test matrix on physical hardware.
