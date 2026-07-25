# Admin Portal Authorization Matrix

This document acts as the single source of truth for Role-Based Access Control (RBAC) boundaries within the Admin API (`/v1/admin/*`). 
All requests are evaluated by `authenticateAdminRequest` which mathematically enforces these permissions against the Firebase `uid` mapped in the `admin_users` collection.

## Permission Model

Permissions are resource-oriented, separating resources from capabilities.

*   `CUSTOMERS_READ`: Can view customer profiles, installations, active subscriptions, and pending transfers.
*   `CUSTOMERS_EDIT`: Can modify customer metadata and manage their subscription states.
*   `DEVICES_BAN`: Can permanently ban or unban physical hardware units from connecting to the platform.
*   `TRANSFERS_APPROVE`: Can forcefully approve or reject pending device transfer requests.
*   `AUDIT_VIEW`: Can view the global audit log.
*   `PLANS_EDIT`: Can update system subscription plans and pricing.
*   `SYSTEM_CONFIG_EDIT`: Can alter global platform configurations (e.g., enable maintenance mode, disable payments).
*   `FULL_ACCESS`: Can perform all actions and access diagnostics or raw APK uploads.

## Role Mappings

| Role | Permissions Granted |
| :--- | :--- |
| **ADMIN** | `FULL_ACCESS` |
| **SUPERVISOR** | `CUSTOMERS_READ`, `CUSTOMERS_EDIT`, `AUDIT_VIEW`, `TRANSFERS_APPROVE` |
| **SUPPORT** | `CUSTOMERS_READ`, `AUDIT_VIEW` |
| **READ_ONLY** | `CUSTOMERS_READ` |

---

## Route to Permission Matrix

| Endpoint | Method | Required Permission | Reason |
| :--- | :--- | :--- | :--- |
| `/v1/admin/auth/verify` | GET | `CUSTOMERS_READ` | Basic login check to verify valid token and fetch user role. |
| `/v1/admin/customers` | GET | `CUSTOMERS_READ` | Support lookup for global customer search. |
| `/v1/admin/customers/:id` | PUT | `CUSTOMERS_EDIT` | Safely update customer profile metadata. |
| `/v1/admin/customers/:id/subscription` | PUT | `CUSTOMERS_EDIT` | Directly manipulate a customer's active subscription (grace periods, revocations). |
| `/v1/admin/transfers/pending` | GET | `CUSTOMERS_READ` | Support view of the transfer request queue. |
| `/v1/admin/transfers/:id/approve` | POST | `TRANSFERS_APPROVE` | Admin intervention to bypass old device transfer approvals. |
| `/v1/admin/transfers/:id/reject` | POST | `TRANSFERS_APPROVE` | Terminating suspicious transfer requests. |
| `/v1/admin/devices/:id/ban` | PUT | `DEVICES_BAN` | High-risk security action to permanently lock out hardware. |
| `/v1/admin/devices/:id/unban` | PUT | `DEVICES_BAN` | Restoring access to a hardware unit. |
| `/v1/admin/audit-logs` | GET | `AUDIT_VIEW` | Viewing the immutable system audit trail. |
| `/v1/admin/config/system` | PUT | `SYSTEM_CONFIG_EDIT` | High-risk operation for platform-wide toggles. |
| `/v1/admin/plans` | POST | `PLANS_EDIT` | Altering billing and checkout configurations. |
| `/v1/admin/diagnostics` | GET | `FULL_ACCESS` | Exposes internal isolate memory, DB health, and configuration state. |
| `/v1/admin/upload-apk-chunk` | POST | `FULL_ACCESS` | Distributing new client binaries to the platform. |

*Note: Any route not explicitly defined in this matrix automatically defaults to the safest boundary (`FULL_ACCESS`) via the router's secure default resolution.*
