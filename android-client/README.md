# Ani Games Ready Remote — Coin x100 Session Popup Preview 0.6.8

This source is the isolated Remote Android DB v0 client for the Ani Games Ready Coin domain.

## Build identity
- Application ID: `com.anigamesready.stardeskclient`
- Package: `com.anigamesready.stardeskclient.coinx100preview`
- Version: `0.6.8-coin-session`, versionCode `14`
- Package/application ID tetap sama: `com.anigamesready.stardeskclient.coinx100preview`
- Build ini berstatus SAFE-TEST; signing harus diverifikasi sebelum upgrade in-place dari APK lain.
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
- Request reservasi dan kredensial sesi: `androiddb_v0_remote_request_session` (special authenticated API route)
- Status sesi dan saldo estimasi: `androiddb_v0_remote_session_status`

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

## Remote Play session popup — Preview 0.6.8
- PC cards now expose PLAY only when the Android DB says the PC is available, Agent and UI monitor leases are online, StarDesk pairing exists, the PC tariff is configured, the renter is active, and Coin balance is positive.
- PLAY calls `androiddb_v0_remote_request_session` with the canonical `rental_pc_id` and an idempotency key. The server reserves exactly one PC for the renter and does not deduct Coin at request time.
- Only after the authenticated reservation succeeds does the API decrypt and return Device ID, Verification Code, and the allowlisted StarDesk Invite URL. The app displays those three fields in a popup with individual Copy actions and a button to open the validated HTTPS invite link.
- Verification Code and Invite URL are not stored in WebView localStorage. The native Android app intercepts only HTTPS URLs matching `app.stardesk.net/invite/<token>` with an optional `lang` parameter; other external HTTPS navigation stays blocked.
- Popup status refresh calls `androiddb_v0_remote_session_status`. It shows REQUESTED while waiting and CONNECTED after the Windows Agent confirms a real active UI state. Coin is charged by the server-side meter only after Connected.
- Coin values in the DB/wallet use x100 internal units. The app converts units to displayed Coin by dividing by 100; top-up calculations and expiry thresholds continue using internal units.
- This is still SAFE-TEST. It requires DB migration 031 and the Windows Agent 0.2.7/monitor lease. Actual StarDesk invite-launch and Connected/Ended UI recognition still require testing on the renter Android phone and a non-production Windows PC.
- DB marks the Coin session ended and stops billing when the lifecycle ends. A verified provider-side forced disconnect is not implemented; a DB state change alone cannot guarantee that a StarDesk stream is physically closed.

## Database deployment
Migration `025_admin_androiddb_v0_coin_domain.sql` creates a separate `androiddb_v0` schema. It is additive and is not applied to the active Android DB by this source build. For an existing Termux database, the installer requires a validated backup and explicit typed `APPLY` before installing the new schema. Do not apply the migration to a different Supabase project or the old rental DB.

## Database update for existing Termux installation
For an existing isolated StarDesk Custom DB at migration 030, run the repository updater:
`backend/android-db/termux/upgrade-stardesk-coin-031.sh`.
The updater downloads the immutable source archive for a supplied 40-character commit SHA, verifies the Termux PostgreSQL cluster/database/owner role/API service, applies migration 031 only to `stardesk_custom_v0`, preserves the existing AES key, backs up the current API source, deploys the matching API, and checks health plus protected RPC routes. The SQL migration does not need to be downloaded or pasted separately.
Do not run the updater on the old Ani Games Ready Billing database, Supabase project, or another PostgreSQL cluster. Take a verified DB backup first. The script refuses metadata that is not the expected migration-030 baseline.

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


## StarDesk Agent sync
- Remote PC inventory is sourced from `androiddb_v0.rental_pcs` and the linked Windows Agent records, never from legacy `public.devices`.
- The app shows registered PCs even when the StarDesk host handoff is not yet ready.
- StarDesk Device ID may be used to open the installed StarDesk Android client in same-account Remote Access mode. The native StarDesk account must be signed in on the client and host.
- Remote Assist verification codes are one-time/session credentials. The Remote app does not display or persist the plaintext code.

## Session popup build 0.6.8
- PLAY reserves a PC using `rental_pcs.id` (`p_rental_pc_id`) and a fresh idempotency key.
- The API only returns the decrypted verification code and invite link after the renter session token and DB reservation pass.
- The popup displays Device ID, Verification Code, and the direct invite URL. It offers Copy actions, an allowlisted StarDesk launch action, and status refresh.
- The UI formats wallet lots/orders/ledger as Coin rather than raw x100 units.
