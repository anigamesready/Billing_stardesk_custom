# Admin Android DB v0 — isolated Coin domain

Date: 25 November 2026

## Design decision

The Admin Android DB v0 system is a separate product line in this repository. Admin V12.x and the existing PC billing remain the legacy/stable line. The new v0 app has a distinct Android Gradle project, APK package ID, HTML interface, version namespace, Node API routes and database schema.

- Admin package: `com.anigames.billingadmin.androiddbv0`
- Admin version: `0.1.0-androiddb-v0`, code 1
- Remote package: `com.anigamesready.stardeskclient`
- Remote version: `0.6.0-androiddb-v0-coin`, code 6
- Backend schema: `androiddb_v0`
- Source repository: `anigamesready/Billing_stardesk_custom`
- Work branch: `feature/admin-androiddb-v0-isolated-20261125`
- Stable `main` was not edited.

## Data separation

| Domain | v0 table | Purpose |
|---|---|---|
| Rental account | `androiddb_v0.rental_accounts` | New Coin-only member identity; active/disabled/deleted only |
| Activation | `androiddb_v0.client_credentials` | One-time activation code hash and lifecycle |
| Remote login | `androiddb_v0.client_sessions` | Access/refresh token hash, installation ID, revocation |
| Wallet | `androiddb_v0.coin_wallets` | Aggregate Coin balance |
| Top-up | `androiddb_v0.coin_topup_orders` | Static QRIS pending/approved/rejected/expired orders |
| Lot | `androiddb_v0.coin_lots` | Coin amount, remaining amount, per-lot expiry |
| Ledger | `androiddb_v0.coin_ledger` | Credit/debit/expiry/audit references |
| PC rate | `androiddb_v0.pc_coin_rates` | GPU class and hourly rupiah/Coin rate |
| StarDesk mapping | `androiddb_v0.stardesk_device_links` | Explicit PC Billing ID → StarDesk Device ID |
| Host permission | `androiddb_v0.host_permissions` | Owner permission for Host Agent |
| Host enrollment | `androiddb_v0.host_enrollments` | One-time expiring enrollment code hash |
| Host registration | `androiddb_v0.host_registrations` | Agent token hash and StarDesk readiness heartbeat |
| Coin session | `androiddb_v0.sessions` | Reserved separate v0 lifecycle; no production connect/settle RPC yet |
| Audit | `androiddb_v0.audit_events` | Owner, client, host and system audit trail |

The v0 rental account does not contain or query the legacy timer balance or legacy account-expiry fields. Core Admin authentication, organization membership, and PC inventory stay on their existing tables; the v0 data domain owns rental identity, activation, wallet, lots, ledger, top-ups, rates, StarDesk mapping, Host Agent and v0 session rows.

## API allowlist contract

The Node Android DB API has an explicit RPC allowlist. Migration SQL grants are not sufficient by themselves: each public RPC must also be in `backend/android-db/server/server.mjs`. The v0 family includes:
- Owner: `androiddb_v0_admin_dashboard`, `androiddb_v0_admin_create_rental`, `androiddb_v0_admin_set_rental_status`, `androiddb_v0_admin_issue_activation`, `androiddb_v0_admin_wallet`
- Owner top-up/rate/mapping/host: `androiddb_v0_admin_approve_topup`, `androiddb_v0_admin_reject_topup`, `androiddb_v0_admin_set_device_rate`, `androiddb_v0_admin_link_stardesk_device`, `androiddb_v0_admin_set_host_permission`, `androiddb_v0_admin_issue_host_enrollment`
- Remote client: `androiddb_v0_remote_login`, `androiddb_v0_remote_refresh`, `androiddb_v0_remote_logout`, `androiddb_v0_remote_dashboard`, `androiddb_v0_remote_coin_wallet`, `androiddb_v0_remote_coin_history`, `androiddb_v0_remote_coin_create_topup`
- Host Agent: `androiddb_v0_host_enroll`, `androiddb_v0_host_heartbeat`

Tables have RLS enabled, direct API-role table access is revoked, and only specific RPC EXECUTE rights are granted.

## Coin tariff baseline

| GPU | Rupiah/hour | Coin/hour |
|---|---:|---:|
| GTX 1050 | Rp6.000 | 45 |
| GTX 1660 | Rp6.000 | 45 |
| RTX 3060 | Rp7.000 | 52,5 |
| RTX 5060 | Rp8.000 | 60 |

Conversion baseline: Rp8.000 = 60 Coin. Lot validity is based on the total valid balance tier at order creation; approving the order creates one lot with its own expiry date. Rejecting an order does not create a lot or credit a wallet. Top-up creation and approval are idempotent.

## PC readiness rules

The Remote dashboard reports a PC as available only when:
- rental account is active and Coin balance is positive,
- no other open v0 session exists for the rental or PC,
- Owner Host permission is active,
- GPU rate is configured,
- StarDesk Device ID mapping is active,
- Host Agent has a recent heartbeat and reports StarDesk ready.

PC Billing online/offline is displayed separately and is not treated as proof that StarDesk streaming is ready.

## Known blockers / do-not-enable list

The Coin session table exists, but no production session reserve/start/connected/stop/settlement RPC has been exposed yet. The following must remain disabled until evidence exists:
1. Remote Connect / stream-start.
2. Coin reservation or debit at stream start.
3. Coin settlement/refund at stream stop, crash or watchdog expiry.
4. Any code that deducts legacy `remaining_seconds`.

The Windows Host Agent is not yet a production, real-PC-tested implementation. The StarDesk Desktop interface for authenticated stream-connected and stream-disconnected callbacks has not been established by the current audit. A running process or Billing heartbeat is not enough to assert that a Remote Assist stream exists.

## Migration and active database boundary

Migration `025_admin_androiddb_v0_coin_domain.sql` is additive. The Termux installer:
- checks for the migration file and v0 API source,
- detects all expected v0 tables and RPC signatures,
- stops on a partial/inconsistent schema,
- requires backup and typed `APPLY` on an existing DB before applying the v0 migration,
- checks v0 readiness in the local API health path.

The active Android DB was not directly reachable in the audit environment. CI verifies a disposable PostgreSQL database only. Therefore the presence of schema 025, its 14 tables, 20 v0 API functions, the current API server version and relay connectivity on the live Redmi are still unverified. Do not run the migration manually on a different Supabase project and do not claim live deployment from CI.

## Regression proof

Workflow `Test Remote Play and Sunshine pairing on PostgreSQL` run 45616600311 succeeded on the isolated branch. It also tests that reusing a top-up idempotency key with a different rupiah amount is rejected. Existing core-only database upgrade path passed. It applied the full migration chain to disposable PostgreSQL and passed the legacy tests plus the new v0 test:
- create v0 rental without creating a legacy rental,
- activation/login/refresh rotation,
- top-up idempotency, approve/reject, lots and ledger,
- per-PC rate and StarDesk mapping,
- Host permission/enrollment/heartbeat,
- Remote dashboard readiness and Admin dashboard/wallet,
- disable/revoke behavior,
- legacy rental timer and expiry row unchanged,
- no direct runtime table reads and least-privilege RPC grants,
- Node gateway syntax and API source check.

This is SQL/API contract testing, not proof of the active database or physical Android/PC streaming.


## 26 November 2026 — User ID-only Remote and Admin session recovery candidate

This section supersedes the version numbers and activation workflow above for the isolated candidate branch `fix/admin-session-refresh-remote-userid-only-20261126`. The stable `main` branch and previously issued APKs are not changed.

### Candidate source versions

| Component | Candidate version | Package / schema | Status |
|---|---|---|---|
| Admin Android DB v0 | 0.2.2, versionCode 4 | `com.anigames.billingadmin.androiddbv0` | Source changes committed; automated build/regression running |
| Remote Android DB v0 | 0.6.2, versionCode 8 | `com.anigamesready.stardeskclient` | Source changes committed; automated build/regression running |
| Node Android DB API | User-ID-only login contract | `api.androiddb_v0_remote_login(text,text)` | Source + migration 026 committed |
| Termux installer | Upgrade-aware | Migrations 025 then 026 | Source updated; never applies an existing-DB migration silently |

### Remote login contract (migration 026)

The Remote app now uses exactly one login field: the rental User ID. There is no activation-code input, activation-code request, or Admin approval step in the new client login path.

The Node API rate-limits failed login attempts by client IP and normalized rental code. The SQL function validates the active v0 rental account, creates a 12-hour access token and 30-day rotating refresh token, and keeps one active device session per rental by rotating the existing session row. A second device using the same User ID invalidates the previous access and refresh tokens. The app stores refresh token and the last User ID in Android Keystore-backed encrypted preferences; its local Keluar action does not revoke the registered device session. Switching to another User ID best-effort revokes the old access token before clearing its local credentials.

**Security trade-off:** User-ID-only access means an easily guessed or shared rental ID can be claimed by another person. Keep rental IDs sufficiently random and private. The server rate-limits failed attempts and permits only one active session per rental, but this is not equivalent to password or second-factor authentication.

The old `androiddb_v0.client_credentials` table and Admin issuance RPC are retained for historical/data compatibility. The new v0.6.2 client does not call them. The new login function drops the old three-argument RPC overload; the installer detects the old/new signature and requires a validated backup plus explicit typed `APPLY` before upgrading an existing database. It does not delete rental, wallet, lot, ledger, or top-up data.

### Admin 0.2.2 session recovery

The Admin UI uses a single shared refresh promise so simultaneous menu loads cannot race to rotate the same refresh token. On `AUTH_REQUIRED` / `ADMIN_SESSION_EXPIRED`, a request refreshes the session once and retries that request once. Permanent refresh/session errors clear the stored refresh token; transient network errors do not erase it. The app waits for the Admin dashboard to load before showing the authenticated screen. The old Owner-side “Kode Remote” activation action is removed from the v0 Admin UI; its database compatibility RPC is not deleted.

### Gateway and Redmi relay boundary

An automated regression test sends a placeholder `Authorization: Bearer` value through the Cloudflare Gateway and WebSocket Relay worker proxy envelope, then checks that the value is preserved in the RelayHub request. This verifies the Worker source path only.

The repository currently does not contain the persistent local WebSocket relay-agent program that runs on the Redmi/Termux device and forwards RelayHub envelopes to the local Node API. Therefore a passing Worker test cannot prove that the live Redmi agent forwards the Authorization header, and it cannot prove that the screenshot's `AUTH_REQUIRED` is resolved on the active server. Do not claim live Admin access is fixed until the installed Redmi agent version, active gateway/relay health, and an authenticated Admin rental-list RPC have been checked end-to-end.

### Verification and deployment boundary

- CI uses disposable PostgreSQL databases for fresh-install and core-only upgrade tests. It does not connect to or modify the user's live Redmi database.
- The new User-ID-only migration must not be applied to the user's active database until the installer has created and validated a fresh backup and the user explicitly enters `APPLY`.
- Admin and Remote APKs must be built from this repository branch and checked for version/package, signature and ZIP/APK integrity.
- A green GitHub build is only a candidate build. It is not evidence of real-device login, live API authentication, PC session lifecycle, StarDesk connection, or a successful production deployment.
- Remote PC Connect and Coin debit/settlement remain locked: the project still lacks a production, device-tested start/connected/stop/settlement contract.

