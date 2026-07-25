# Resilience Policy Registry
**Version:** 1

This registry defines the explicit resilience policies (timeouts, retries, and circuit breaker constraints) applied across all external infrastructure boundaries in the VendorPro backend.

Changing these values is an architectural decision that must be validated against system latency budgets.

| Policy Identifier | Target System | Operation Semantics | Timeout (ms) | Retry Strategy | Circuit Breaker Realm |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `firestoreRead` | Google Firestore | Idempotent Read | 3000 | 3x Exponential Backoff | `firestore` |
| `firestoreIdempotentWrite` | Google Firestore | Idempotent Write | 3000 | 3x Exponential Backoff | `firestore` |
| `firestoreNonIdempotentWrite`| Google Firestore | Non-Idempotent Write | 5000 | **No Retries** | `firestore` |
| `razorpayRead` | Razorpay API | Idempotent Read | 3000 | 3x Exponential Backoff | `razorpay` |
| `razorpayMutation` | Razorpay API | Non-Idempotent Write | 5000 | **No Retries** | `razorpay` |

## Enforcement
These policies are enforced centrally by the `ResiliencePolicies` constant in `src/services/resilience/policies.ts`. No Domain Service or Orchestrator is permitted to bypass these wrappers or instantiate ad-hoc `fetch()` configurations.
