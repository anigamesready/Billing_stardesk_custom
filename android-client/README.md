# Ani Games Ready Remote — Coin x100 User ID-only Preview 0.6.6

This source is the isolated Remote Android DB v0 client for the Ani Games Ready Coin domain.

## Build identity
- Application ID: `com.anigamesready.stardeskclient`
- Package: `com.anigamesready.stardeskclient.coinx100preview`
- Version: `0.6.6-userid-only-login`, versionCode `12`
- Install mode: updates Remote Coin x100 Preview 0.6.5 in place; package is unchanged
- Version code: `12`
- Remote source: `android-client/`
- Repository: `anigamesready/Billing_stardesk_custom`

## Backend contract
The client talks only to the fixed HTTPS Android DB gateway via the native Android bridge. Both the WebView and native bridge use the dedicated `/stardesk` route, which selects the StarDesk-only Relay hub and the isolated StarDesk database. It does not expose an editable URL field.

All new Coin account and wallet operations use the separate `androiddb_v0_*` API family:
- Login: `androiddb_v0_remote_login` with only the rental User ID and the Android-generated installation ID.
- Refresh: `androiddb_v0_remote_refresh`
- Logout: `androiddb_v0_remote_logout`
- Dashboard/PC availability: `androiddb_v0_remote_dashboard`
- Wallet lots: `androiddb_v0_remote_coin_wallet`
- History: `androiddb_v0_remote_coin_history`
- QRIS static top-up order: `androiddb_v0_remote_coin_create_topup`

Access and refresh tokens are stored using AES-GCM backed by Android Keystore. The app keeps no raw token in WebView localStorage.


## Renter login

- The renter enters only the registered rental User ID. There is no Admin-issued activation code, no Admin approval step and no second verification screen.
- The Android app supplies its installation ID automatically; it is not displayed as another login field.
- The server validates that the rental exists and is active, rate-limits failed attempts, and keeps one active Remote installation/session per rental ID. A new login replaces the previous active installation.
- Owner can still enable/disable a rental account; disabling it revokes its active Remote sessions. This is account-status control, not per-login approval.
- User ID-only login deliberately uses the User ID as the renter's only entered credential. Anyone who learns a User ID may be able to claim that account's single active Remote session; do not treat a User ID as a secret password.

## Gateway DNS/TLS compatibility
The native HTTPS bridge pins TCP to the tested Cloudflare edge IPv4 addresses `104.18.13.15` and `104.18.12.15` for the fixed Gateway hostname. The HTTPS URL uses the dedicated `/stardesk` route while Host header, SNI and Android's default certificate trust/hostname verification continue to use `ani-games-db-android-stage-gateway.anigamesready.workers.dev`. No trust-all certificate callback or cleartext fallback is used.

## Coin rules
- Rp8.000 = 6,000 Coin (x100 denomination).
- Rp5.000 = 3,750 Coin; Rp10.000 = 7,500; Rp15.000 = 11,250; Rp20.000 = 15,000.
- Hourly rates: GTX 1050 / GTX 1660 = 4,500 Coin; RTX 3060 = 5,250; RTX 5060 = 6,000. Rupiah prices do not change.
- GPU hourly rates are configured by Owner in Admin Android DB v0.
- Coin is stored as wallet lots in x100 units and each approved lot has its own expiry. Existing Android DB v0 balances, orders, lots, ledger and GPU rates are converted by migration 026 exactly once.
- The account itself has no legacy rental time balance or account expiry.
- QRIS is static. The client creates a pending order; Owner must verify the transfer and approve it before any Coin is credited.
- Top-up creation and approval have database idempotency protections.

## Not enabled
- PC selection currently displays availability/status only.
- Connect/stream start is intentionally disabled.
- Production Windows Host Agent is not yet built and accepted on a real StarDesk PC.
- No Coin session reserve/debit/settle lifecycle is exposed yet.
- No old rental seconds/timer settlement is reused.
- The public StarDesk integration interface has not yet provided verified start/stop streaming callbacks; process detection alone is not proof of a real stream.

## Database deployment
Migration `025_admin_androiddb_v0_coin_domain.sql` creates a separate `androiddb_v0` schema. It is additive and is not applied to the active Android DB by this source build. For an existing Termux database, the installer requires a validated backup and explicit typed `APPLY` before installing the new schema. Do not apply the migration to a different Supabase project or the old rental DB.

## Tests
Migration `027_androiddb_v0_remote_userid_only_login.sql` removes the Admin-issued Remote activation function, the old three-argument login RPC and the activation-code table. It exposes only `androiddb_v0_remote_login(text,text)` and removes activation status from Admin dashboard data. The PostgreSQL workflow applies the full Android DB migration chain to disposable PostgreSQL and checks:
- separate v0 rental creation and User ID-only login/refresh,
- top-up idempotency, approval/rejection, Coin lot and ledger,
- GPU tariff and StarDesk mapping,
- Host enrollment/heartbeat readiness,
- Admin/Remote v0 dashboard,
- runtime function grants and table isolation,
- legacy rental seconds and expiry unchanged.

A passing CI build does not confirm live Termux DB state or real-device streaming. This APK remains SAFE-TEST until live gateway/database verification and physical Android/PC acceptance tests are complete.
