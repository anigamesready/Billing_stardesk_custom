# Ani Games Admin Android DB v0 — Preview 0.1.0

This is a separate Android application project in the repository. It does not patch or replace Admin V12.x.

## Identity
- Package: `com.anigames.billingadmin.androiddbv0`
- Namespace: `com.anigamesready.adminandroiddbv0`
- Version: `0.1.0-androiddb-v0`, code 1
- Project root: `admin-androiddb-v0/`
- Build workflow: `.github/workflows/build-admin-androiddb-v0.yml`

## Scope
- Owner login and Android DB organization/tenant check.
- Create/enable/disable the new Coin rental account.
- Issue one-time Remote activation code.
- View top-up requests; approve/reject with the Owner account.
- Inspect wallet balance, Coin lots and ledger.
- Configure per-PC GPU rate and StarDesk device mapping.
- Grant/revoke PC Host permission and issue Host Agent enrollment code.
- Native HTTPS gateway bridge and encrypted refresh token using Android Keystore.

## Isolation
All member/wallet/order/lot/ledger/Remote Host data belongs to `androiddb_v0`. Admin authentication and organization membership remain on the existing core auth tables; PC inventory references the existing `public.devices` records. This app does not call legacy rental CRUD, timer, remaining-time, or account-expiry APIs.

The app is built with a unique package ID and separate Gradle project. Its source and build are maintained only in this repository.

## Safety status
Preview/SAFE-TEST only. Do not merge into the stable Admin app. Do not apply migration 025 to the current Termux database until its backup is validated and the installer receives explicit `APPLY`. Connect and Coin session billing are intentionally not part of this preview.
