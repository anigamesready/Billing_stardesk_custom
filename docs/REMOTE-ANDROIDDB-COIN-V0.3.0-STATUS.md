# StarDesk Remote Android DB Coin v0.3.0 — status & deployment notes

Status date: 2026-11-25
Working branch: `feature/remote-androiddb-live-coin-20261125`
Stable `main` is intentionally unchanged.

## Scope completed in source

- Android Remote client uses the local Android DB API over HTTPS. The client does not call Supabase cloud.
- First activation uses rental code + one-time activation code issued by the existing Owner Remote Play RPC; subsequent login rotates a refresh token.
- Access and refresh tokens are encrypted with Android Keystore AES-GCM. They are not written to WebView localStorage.
- Client reads wallet balance/lots, rental profile, online PC list, configured rates, and history through Android DB RPCs.
- QRIS top-up creates an idempotent pending order in Android DB. Owner approval creates a new coin lot and ledger entry; rejection does not credit coins.
- Coin data lives in separate `remote_play.coin_*` tables. No existing rental balance/session columns or legacy settlement functions are modified.
- Owner RPCs exist for pending order list/approve/reject, per-device GPU rate, and explicit StarDesk device ID mapping.

## Build and test evidence

- Android APK build: GitHub Actions run `45470090281` passed at source commit `09f2b3d7bc7eb41bd9c38f0e63e56a554ce87d95`. Package `com.anigamesready.stardeskclient`, versionCode `3`, versionName `0.3.0-androiddb-coin-preview`. APK SHA-256: `cae25f6e02967dbacecf6d66537ef9a186e0afe492d236c8ccd6c0066993ccb8`.
- PostgreSQL regression: GitHub Actions run `45470216342` passed at source commit `e0abf8620afa0c91a727b6343d5c4631342baf0e`. It creates a fresh disposable PostgreSQL 16 database, applies migrations 000 and 002–020 (the catalog snapshot 001 is excluded), then runs tests 001–015.
- Test 015 verifies wallet creation, QRIS order idempotency, Owner approval/rejection, coin-lot expiry and ledger entries, rate configuration, StarDesk ID mapping, runtime table privileges, and that the old rental account's time balance/status remain unchanged.
- These tests are disposable CI only. They do not prove a live device install, live HTTPS tunnel, live QRIS payment, or StarDesk PC streaming operation.

## Android DB migration order

Use the already-established Android DB schema as the baseline. Apply migrations 013–019 for the existing Remote Play control plane, then migration 020 for the coin wallet. Migration 020 is additive: it creates new namespaced tables/functions only and does not update or drop existing business tables/functions.

Do not run migrations against the active database until a fresh backup/snapshot is available, the intended Android DB is confirmed, and the resulting API is smoke-tested. The CI database is not production.

## API server and Android client configuration

The ported Node API uses PostgreSQL and the Android DB API process. The existing local configuration binds the API on loopback `127.0.0.1:8787`; an Android phone outside that host cannot reach loopback directly.

Configure a trusted HTTPS tunnel or gateway to the API, then enter that HTTPS base URL in the Android app. The app enforces HTTPS, does not allow cleartext traffic, and sends RPC requests through the Android native bridge. Do not put database passwords, admin tokens, or service-role secrets in the app.

The API's `/rest/v1/rpc/*` and `/auth/v1/*` paths are local compatibility routes on this Node API; they are not a Supabase cloud endpoint. There is no `supabase.co` host, Supabase client, or Supabase key in this Android client/API branch.

## Coin policy currently encoded

- Conversion: Rp8,000 = 60 coins; fractional coins are retained to 8 decimal places.
- PC rates: GTX 1050 Rp6,000 / 45 coins per hour; GTX 1660 Rp6,000 / 45 coins per hour; RTX 3060 Rp7,000 / 52.5 coins per hour; RTX 5060 Rp8,000 / 60 coins per hour.
- Each approved top-up creates a separate lot. Existing lot expiry is not extended by a new top-up.
- Top-up lot lifetime is snapshotted from the valid wallet balance plus the new top-up: under 300 = 3 days; under 600 = 7; under 900 = 10; under 1,200 = 14; under 1,500 = 17; under 1,800 = 21; under 2,100 = 24; under 2,400 = 28; otherwise 30 days.
- QRIS is static. Creating an order does not verify payment automatically. Owner must confirm payment and approve the pending order.

## Explicitly not enabled yet

- Selecting a PC and launching StarDesk is disabled in the Android UI.
- Coin deduction for a streaming session is not enabled. The existing Remote Play settlement function deducts legacy rental seconds; reusing it for coins would risk double-charging and is forbidden.
- Before enabling Connect, implement a separate coin-session lifecycle/settlement and watchdog, prove actual StarDesk stream-start/stop callbacks, confirm that the Owner-mapped StarDesk device ID is correct, and test start, disconnect, stop, zero balance, expiry, crash, and reconnect on real PCs.
- The Admin V12.1.58 SAFE-TEST binary remains the baseline. Its editable matching source is not present in this repository, so this branch does not replace or modify that Admin APK. Owner coin RPCs are available in backend but still need an approved Admin UI path.

## StarDesk Desktop installer

User-supplied `StarDesk-1.6.0-13j6BjxC.exe` is a 122 MB Nullsoft/NSIS Windows installer, SHA-256 `902512568bac4bd8aec788c97f5ff831ec97a086e67d1bf85c20ab5fe5a2673f`. The installer payload/source has not been extracted or audited in this environment. No claim is made that Desktop 1.6.0 is already integrated.
