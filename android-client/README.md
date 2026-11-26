# Ani Games Ready Remote — StarDesk Coin v0.6.4 User ID-only

This source is the isolated Remote Android DB v0 client for the Ani Games Ready Coin domain.

## Build identity
- Application ID: `com.anigamesready.stardeskclient`
- Version: `0.6.4-stardesk-userid-only`
- Version code: `10`
- Remote source: `android-client/`
- Repository: `anigamesready/Billing_stardesk_custom`

## Backend contract
The client talks only to the fixed HTTPS Android DB gateway via the native Android bridge. Both the WebView and native bridge use the dedicated `/stardesk` route, which selects the StarDesk-only Relay hub and the isolated StarDesk database. It does not expose an editable URL field.

All new Coin account and wallet operations use the separate `androiddb_v0_*` API family:
- Login User ID-only: `androiddb_v0_remote_login`
- Refresh: `androiddb_v0_remote_refresh`
- Logout: `androiddb_v0_remote_logout`
- Dashboard/PC availability: `androiddb_v0_remote_dashboard`
- Wallet lots: `androiddb_v0_remote_coin_wallet`
- History: `androiddb_v0_remote_coin_history`
- QRIS static top-up order: `androiddb_v0_remote_coin_create_topup`

Access and refresh tokens are stored using AES-GCM backed by Android Keystore. The app keeps no raw token in WebView localStorage.

## Canonical Coin account source

Remote User ID login searches only `androiddb_v0.rental_accounts.code` in the dedicated `stardesk_custom_v0` database. The matching account must have status `active`. The Remote app does not authenticate against `public.rental_accounts`, `remote_play.coin_wallets`, legacy rental timer accounts, or another database.

Create Remote members from **Rental Coin** in the separate **Admin Android DB v0** app. Its `androiddb_v0_admin_create_rental` RPC writes the same `androiddb_v0.rental_accounts` table that Remote login reads. The older Coin domain uses `public.rental_accounts` plus `remote_play.coin_*`; even when those schemas are hosted in the same PostgreSQL database, they are a different account/wallet model and are not automatically interchangeable.

Do not create duplicate accounts or copy coin balances blindly. To locate an existing ID such as `IRFAN19`, use the read-only Termux audit script `backend/android-db/termux/audit-stardesk-coin-account.sh`. It shows whether the ID exists in `androiddb_v0` or only in the older `remote_play/public` domain. Any migration of existing lots must preserve each lot's remaining coins and expiry and must be idempotent.

## Gateway DNS/TLS compatibility
The native HTTPS bridge pins TCP to the tested Cloudflare edge IPv4 addresses `104.18.13.15` and `104.18.12.15` for the fixed Gateway hostname. The HTTPS URL uses the dedicated `/stardesk` route while Host header, SNI and Android's default certificate trust/hostname verification continue to use `ani-games-db-android-stage-gateway.anigamesready.workers.dev`. No trust-all certificate callback or cleartext fallback is used.

## Coin rules
- Rp8.000 = 60 Coin.
- GPU hourly rates are configured by Owner in Admin Android DB v0.
- Coin is stored as wallet lots and each approved lot has its own expiry.
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
The PostgreSQL workflow applies the full Android DB migration chain to disposable PostgreSQL and checks:
- separate v0 rental creation and activation/login/refresh,
- top-up idempotency, approval/rejection, Coin lot and ledger,
- GPU tariff and StarDesk mapping,
- Host enrollment/heartbeat readiness,
- Admin/Remote v0 dashboard,
- runtime function grants and table isolation,
- legacy rental seconds and expiry unchanged.

A passing CI build does not confirm live Termux DB state or real-device streaming. This APK remains SAFE-TEST until live gateway/database verification and physical Android/PC acceptance tests are complete.
