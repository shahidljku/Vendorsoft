# System Architecture & Transaction Model

## Overview
The VendorPro backend is built on Cloudflare Workers and Google Cloud Firestore. It uses a strict Domain-Driven Design (DDD) layered architecture to enforce consistency, atomic bounds, and predictability.

This document serves as the canonical reference for the system architecture. **No new feature is allowed to bypass the established architecture.**

## 1. Layered Architecture
The system is divided into strict layers:

```text
[ Webhooks / Routes ]  --- Controller Layer (Thin)
         │
         ▼
[ Domain Services ]    --- Orchestration & Business Logic (Fat)
         │
         ▼
[ FSMs & Builders ]    --- Pure Functions & State Definitions
         │
         ▼
[ Infrastructure ]     --- Firestore, Locking, Cryptography
```

### Dependency Rules
- **Top-Down Only**: Routes may call Services. Services may call Infrastructure. Infrastructure may **never** call Services.
- **No Circular Services**: Orchestrators (`TransferService`, `PaymentService`) may call Pure Builders (`SubscriptionService`, `InstallationService`). Builders may **not** call Orchestrators.

---

## 2. Core Components

### Routes & Controllers
**Responsibility**: HTTP parsing, payload validation, identity extraction, and response formatting.
- Must **not** contain business logic.
- Must **not** query Firestore directly for domain decisions.
- Delegates to the appropriate Domain Service.

### Orchestrators (e.g., `PaymentService`, `TransferService`)
**Responsibility**: Workflow coordination.
- Fetch initial state.
- Acquire distributed locks via `LockService`.
- **Re-read state inside the lock** to prevent concurrency bugs.
- Call Domain Builders to gather writes.
- Execute exactly **one** atomic commit.
- Execute side-effects (e.g., refunds) **outside** the lock.

### Domain Builders (e.g., `SubscriptionService`, `InstallationService`)
**Responsibility**: Pure domain mutations.
- Enforce business rules and FSM transitions.
- Do **not** execute Firestore writes directly.
- Always return a standard `DomainMutation<T>` payload:
  ```typescript
  interface DomainMutation<T = void> {
    writes: BatchOperation[];
    result: T;
  }
  ```

### Finite State Machines (FSMs)
**Responsibility**: State transition authority.
- Static, pure functions that dictate legal transitions.
- Prevent invalid state changes (e.g., cannot transition a payment to `REFUND_PENDING` unless it is `INITIATED` or `SUCCESS`).

---

## 3. Concurrency & Locking Model

The system uses a distributed mutual exclusion lock (`LockService.withLock`) backed by Firestore transactions.

### The Lock Pattern
```typescript
await LockService.withLock(env, 'sub_lock', subscriptionId, 30000, metadata, async () => {
    // 1. RE-READ STATE INSIDE THE LOCK
    const currentDoc = await getDocument(...);
    
    // 2. Validate current state
    if (currentDoc.status !== 'EXPECTED') return shortCircuit();
    
    // 3. Build mutations
    const op = DomainBuilder.buildSomething(...);
    
    // 4. Commit atomically
    await commitAtomicWrites(env, op.writes);
});
```
**CRITICAL**: You must always re-read the target document inside the lock closure to prevent double-execution in highly concurrent environments (like simultaneous duplicate webhooks).

### Global Lock Acquisition Order
To prevent deadlocks when multiple locks must be acquired simultaneously, all orchestrators **must** acquire locks in the following strict hierarchy (top-down):

1. **`webhook_lock`** (Key: `orderId` or `paymentId`) - Highest level lock protecting external webhook entry points and preventing duplicate event processing.
2. **`order_lock`** (Key: `customerId`) - Protects initial order creation and gateway initiation per customer.
3. **`sub_lock`** (Key: `subscriptionId`) - Protects the core subscription state from concurrent admin mutations, renewals, or transfers.
4. **`transfer_lock`** (Key: `subscriptionId` or `customerId`) - Protects peer-to-peer and standalone trial device transfer operations.

**Rule**: You may acquire a lock lower in the hierarchy while holding a higher lock (e.g., acquiring `sub_lock` while holding `webhook_lock`), but you must **never** attempt to acquire a higher lock while holding a lower lock.

---

## 4. Transaction & Mutation Model

We never perform partial writes. All state changes related to a single business action must succeed or fail together.

### `commitAtomicWrites`
- Accepts an array of `BatchOperation`.
- Uses a single Firestore `WriteBatch`.
- Supports pre-condition checks (`requireDoesNotExist`).
- Enforces a hard boundary: if the process crashes mid-execution, zero state changes occur.

---

## 5. Saga & Retry Model (Eventual Consistency)

For multi-system interactions (e.g., Razorpay refunds), we use a Saga pattern with explicit failure states.

### Example: Refund Saga
1. **Detect Conflict**: `PaymentService` detects a device ownership conflict.
2. **Mark Pending**: Inside the lock, the payment transitions to `REFUND_PENDING`.
3. **Commit**: `commitAtomicWrites` saves the `REFUND_PENDING` state.
4. **Side Effect**: Outside the lock, the `RazorpayProvider` refund API is called.
5. **Finalize**: If successful, payment transitions to `REFUNDED`.
6. **Recovery**: If the worker crashes at step 4, the payment remains `REFUND_PENDING`. When Razorpay retries the webhook delivery, the system sees `REFUND_PENDING`, skips provisioning, and resumes from step 4.

---

## 6. Expired Account Payment Mobility

The flow for recovering an expired account on a new device strictly separates read-only authentication from state-mutating ownership transfer.

```text
Expired Login
    ↓
Stateless authentication
    ↓
Expired lease issued
    ↓
Payment screen
    ↓
Order created (clientIdentity persisted)
    ↓
Webhook verified
    ↓
Atomic Settlement
        ├─ buildProvisioning()
        ├─ buildActivation()
        └─ conditional buildRevocation()
    ↓
commitAtomicWrites()
```

**Invariant:** Expired login must never mutate ownership. Ownership transitions occur only during atomic settlement, transfer approval, initial registration, or explicit administrative migration.

---

## 7. Core Architectural Invariants (Baseline v3.0)

These foundational invariants must be strictly preserved across all future feature development, refactoring, and system extensions.

### 7.1 Canonical State Principle
Firestore documents are the canonical source of truth.
Generated artifacts (lease tokens, JWTs, signatures, cached payloads, etc.) are **derived** from canonical state.
* Business decisions must always be made from canonical state.
* Generated artifacts must never be parsed to reconstruct canonical state, except for authentication or migration purposes.

### 7.2 Atomic Mutation Rule
If a business event changes multiple domain objects, all affected domain objects must transition together inside a single atomic commit.
* Examples: payment settlement, ownership transfer, installation activation, installation revocation.
* No business workflow may leave partially-applied ownership state.

### 7.3 Read-Only Routes
Authentication, Status, Lookup, Discovery, and Validation endpoints **must never mutate ownership**. State changes require an explicit business event.

### 7.4 Canonical Writers
Only the following workflows may modify `activeInstallationId`:
* Registration
* Trial Creation
* Transfer Approval
* Payment Settlement
* Explicit Admin Migration

### 7.5 Performance Invariants
High-frequency endpoints (e.g., `/subscriptions/status`) must not perform:
* RSA signing
* JSON parsing of generated artifacts (`atob`, `JSON.parse`)
* Unnecessary Firestore writes
...unless cache invalidation genuinely requires a fresh token. Cache decisions are driven solely by canonical Firestore state (`leaseIssuedAtEpochMs`, `lastLeasePlanId`, `lastLeaseDeviceId`).

### 7.6 Domain Event Table
| Event | May mutate state? | Requires Lock? | Atomic? |
| :--- | :--- | :--- | :--- |
| Login | No | No | No |
| Trial Registration | Yes | Yes | Yes |
| Subscription Payment | Yes | Yes | Yes |
| Transfer Approval | Yes | Yes | Yes |
| Subscription Status Poll | Usually No | No | No |
| Admin Migration | Yes | Yes | Yes |

### 7.7 Additional Rules
* **Single Active Installation**: At most one ACTIVE installation per subscription. Enforced by orchestrators and `activeInstallationId` tracking.
* **Single Trial Consumption**: A trial can only ever be consumed once per hardware device. Enforced by `hardware_trials` uniqueness.
* **Domain Service Isolation**: No direct HTTP Responses from Domain Services. Services return Domain Models (`DomainMutation<T>`).
* **Lock Service Cleanliness**: No side effects inside locks. External APIs (refunds, emails, webhooks) must be called outside the `LockService.withLock` closure to prevent locking up the database during slow network requests.

### 7.8 Idempotency & Replay Protection
Every externally initiated business event must have a stable canonical identity. All state mutations must serialize on that canonical identity.
* Mutating workflows must never execute duplicate domain operations for the same business event.
* Webhook settlement must serialize on the canonical business event identity (`razorpayOrderId` or `paymentId`), not an ephemeral or random ID.
* Replay of a completed event must immediately return a success outcome derived from authoritative canonical state without re-executing business mutations.

### 7.9 Stable Business Identity
Every state-mutating workflow must identify a single immutable business event before any mutation or locking occurs.
* The business identity is the underlying payment/order, not the ephemeral webhook delivery event or network request ID.
* External gateway calls must never occur unless the executing worker currently owns the active saga lease in `idempotency_keys/{keyId}` (`ownerToken` verification).
* If a worker crashes after a successful gateway call, recovery must discover the authoritative domain record in Firestore and finalize the saga without re-calling the gateway.

---

## 8. Pillar Registry

The following architectural milestones track the implementation of core system invariants.

### Baseline v3.0 (Pillars 1-3)

✓ **Pillar 1: Ownership Lifecycle**
* Ownership transitions
* Payment mobility
* Atomic activation/revocation
* Transfer correctness

✓ **Pillar 2: Lease Lifecycle**
* Lease generation
* Cache invalidation
* Canonical metadata
* Performance optimization

✓ **Pillar 3: Idempotency & Replay Protection**
* Canonical business identity locking
* Explicit saga lease ownership (`ownerToken`)
* Gateway crash recovery via canonical ledger
* Idempotent replay protection

### Pending (Future Baselines)

□ **Pillar 4**
...

---

## 9. Architecture Change Policy

Any change that violates or modifies a Core Architectural Invariant requires:
1. A forensic audit.
2. Documented rationale.
3. Updated `Architecture.md` (bumping the Baseline semantic version).
4. Regression verification.

No implementation may silently redefine an architectural invariant.

---

## 10. Invariant Checklist

Every major feature or pull request should satisfy this checklist:

* [ ] Ownership invariant preserved
* [ ] Lease invariant preserved
* [ ] Read-only routes remain read-only
* [ ] No additional ownership writers introduced
* [ ] Atomic mutation boundary preserved
* [ ] Lock re-read performed
* [ ] No side effects inside locks
* [ ] Hot-path performance invariant preserved
* [ ] Canonical state remains the source of truth
* [ ] Canonical business identity locking preserved
* [ ] No external gateway call without active saga lease

---

## 11. Pillar Implementation Workflow

To ensure architectural integrity, all future pillars must follow this evidence-driven process:

1. **Define** the desired invariant.
2. **Threat Model**: Answer what attack/failure is being prevented, what assets are protected, and what assumptions are being tested.
3. **Perform** a repository-wide forensic audit.
4. **Identify** all writers/readers affected.
5. **Identify** concurrency implications.
6. **Design** the minimal architectural change.
7. **Implement**.
8. **Re-audit** to prove the invariant holds.
9. **Update** `Architecture.md` (and semantic version baseline).
10. **Mark** the pillar complete.

