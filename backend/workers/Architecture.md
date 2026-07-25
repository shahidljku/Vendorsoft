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

## 6. Architectural Invariants

1. **At most one ACTIVE installation per subscription.** Enforced by orchestrators and `activeInstallationId` tracking.
2. **A trial can only ever be consumed once per hardware device.** Enforced by `hardware_trials` uniqueness.
3. **No direct HTTP Responses from Domain Services.** Services return Domain Models. Routes map them to HTTP Responses.
4. **No side effects inside locks.** External APIs (refunds, emails) must be called outside the `LockService.withLock` closure to prevent locking up the database during slow network requests.
