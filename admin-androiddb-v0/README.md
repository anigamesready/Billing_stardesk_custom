# Ani Games Admin Android DB v0 — Preview 0.2.1

A standalone Android Owner/Admin app in this repository. It does not patch, replace, or share the package identity of Admin V12.x.

## Identity
- Package: `com.anigames.billingadmin.androiddbv0`
- Namespace: `com.anigamesready.adminandroiddbv0`
- Version: `0.2.1-full-db`, versionCode 3
- Project root: `admin-androiddb-v0/`

## Android DB integration
The app uses the dedicated StarDesk route on the Android DB HTTPS Gateway and a separate PostgreSQL database (`stardesk_custom_v0`) through its own local API on port `8789`. Owner login, sessions, rental timer domain, Coin wallet, top-ups, Host records and Remote records belong only to StarDesk Custom. It does not use the Ani Games Ready legacy database/API (`ani_games_ready_stage`, port `8788`), does not import or sync its records, and does not connect directly to SQL tables from Android.

The UI contains:
- Core Owner overview and organization selection.
- Legacy rental timer account CRUD, kept in the existing core rental schema and its normal RPC rules.
- PC inventory, device state, rename/disconnect, active sessions, command queue/status, free test and recovery/enrollment.
- Reports: compact, monthly, detailed paged usage, rental period breakdown and Admin activity.
- Billing policies, organization theme and Owner password change.
- Billing Admin/Reseller user management and reseller creation.
- Remote Host permissions/enrollment, Remote overview, WoL relay/probe/command status and Blynk momentary power pulse.
- Independent Coin-rental v0 account, activation, wallet, top-up approval/rejection, lots/ledger, GPU rates, StarDesk mapping and Host Agent enrollment.

## Data separation
StarDesk Custom and the existing Ani Games Ready rental-timer system are two separate installations with different PostgreSQL databases, database roles, API credentials, local API ports, service names and app build identities. StarDesk uses `stardesk_custom_v0` / API `8789`; the old Ani Games Ready installation retains `ani_games_ready_stage` / API `8788`. There is no DB selector that changes an app between them, no data copy, synchronization, fallback or dual-write.

Inside the StarDesk database, its own Admin/Owner core tables provide organization and PC administration while the `androiddb_v0` schema keeps Coin wallet/lots/ledger/top-ups and Coin rental records separate from StarDesk's timer-style rental records. None of these StarDesk tables or credentials are shared with the old Ani Games Ready database. The Android app uses only token-bound RPCs and never reads tables directly.

## Gateway DNS/TLS compatibility
The native HTTPS bridge pins TCP to the tested Cloudflare edge IPv4 addresses `104.18.13.15` and `104.18.12.15` for the fixed Gateway hostname. The HTTPS URL, Host header, SNI and default Android certificate trust/hostname verification continue to use `ani-games-db-android-stage-gateway.anigamesready.workers.dev`. No trust-all certificate callback or cleartext fallback is used. This is specifically for resolver environments that returned an unrelated AWS certificate for the Gateway hostname.

## Safety and release status
This is a debug preview, not a production/release-signed APK. Do not merge into the stable Admin app. Live Redmi DB migration state is not inferred from CI: migration 025 must be independently verified against the live database. On an existing PostgreSQL cluster, migration 025 is gated by a validated database/roles backup and explicit `APPLY`. Do not restart or reinitialize a running PostgreSQL service to install this preview.

Remote video transport and Coin session billing are not enabled by this Admin integration scope.
