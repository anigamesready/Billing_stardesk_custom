# Ani Games Admin Android DB v0 — Preview 0.2.1

A standalone Android Owner/Admin app in this repository. It does not patch, replace, or share the package identity of Admin V12.x.

## Identity
- Package: `com.anigames.billingadmin.androiddbv0`
- Namespace: `com.anigamesready.adminandroiddbv0`
- Version: `0.2.1-full-db`, versionCode 3
- Project root: `admin-androiddb-v0/`

## Android DB integration
The app uses the existing Android DB HTTPS Gateway and the existing Owner/Admin login/session. All business data is read or changed through the explicit token-bound RPC functions already exposed by `backend/android-db/server/server.mjs`. The app does not connect to Supabase or execute SQL against table endpoints.

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
One Android PostgreSQL database remains the single source of truth. The legacy timer rental domain continues using the existing core tables and APIs. The AniCoin-only domain remains isolated under schema `androiddb_v0` and must not debit or alter legacy rental seconds or expiry. PC inventory and Owner authentication remain shared core resources. No DB1/DB2 selector or second database is introduced.

The `androiddb_v0` module uses its dedicated RPCs. Legacy rental CRUD, PC controls, reports, settings, users, WoL and Remote administration use the existing token-bound core Admin RPCs. The Android app never reads tables directly.

## Gateway DNS/TLS compatibility
The native HTTPS bridge pins TCP to the tested Cloudflare edge IPv4 addresses `104.18.13.15` and `104.18.12.15` for the fixed Gateway hostname. The HTTPS URL, Host header, SNI and default Android certificate trust/hostname verification continue to use `ani-games-db-android-stage-gateway.anigamesready.workers.dev`. No trust-all certificate callback or cleartext fallback is used. This is specifically for resolver environments that returned an unrelated AWS certificate for the Gateway hostname.

## Safety and release status
This is a debug preview, not a production/release-signed APK. Do not merge into the stable Admin app. Live Redmi DB migration state is not inferred from CI: migration 025 must be independently verified against the live database. On an existing PostgreSQL cluster, migration 025 is gated by a validated database/roles backup and explicit `APPLY`. Do not restart or reinitialize a running PostgreSQL service to install this preview.

Remote video transport and Coin session billing are not enabled by this Admin integration scope.
