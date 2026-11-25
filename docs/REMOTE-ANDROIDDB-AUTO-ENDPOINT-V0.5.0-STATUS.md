# Android Remote — automatic endpoint and wallet UI v0.5.0

Date: 2026-11-25  
Branch: `feature/remote-auto-url-coin-ui-20261125`  
Base source: `feature/androiddb-termux-coin-x100-20261125` at `6de816b231a5954c96ed23c16b164b4fb9f81c7c`

## Changes in this branch

- Removed the renter-facing manual HTTPS URL input from the login screen.
- Pinned the Android client to the project HTTPS gateway:
  `https://ani-games-db-android-stage-gateway.anigamesready.workers.dev`.
- Added a native health check against `/_ani_gateway/health`. Login is enabled only if Cloudflare gateway, relay agent, local API, and Android DB report healthy.
- Added an explicit retry control when the relay/API/database is unavailable. The base endpoint cannot be changed from the WebView or by the renter.
- Kept HTTPS-only transport, disabled redirects, bounded health responses, and pinned RPC calls to the single configured gateway.
- Corrected visible top-up coin labels to match migration 022's x100 unit scale: Rp5,000 = 3,750; Rp10,000 = 7,500; Rp15,000 = 11,250; Rp20,000 = 15,000 coins.
- Added the account expiry date to the dashboard.
- Updated package metadata to versionCode 5 / versionName `0.5.0-androiddb-auto-endpoint-preview`.
- Added CI assertions for the hidden endpoint field, native gateway health probe, package version, and correct coin labels.

## Important online dependency

The Cloudflare Worker scripts and workers.dev subdomain were confirmed present and enabled in the connected Cloudflare account. The fixed URL itself was not reachable through the available external HTTP verification channel during this task, so current relay-agent/API/database health remains **unverified**. The app fails closed: login remains disabled and displays an offline state until the health endpoint reports the complete path healthy.

## Not enabled — intentionally

PC Connect and coin session settlement remain locked. Current repository source does not contain a verified StarDesk host-agent streaming callback implementation or a proven Android client callback for actual stream start/disconnect. Existing `remote_play` settlement deducts legacy rental seconds and must not be reused for coin sessions. A queued host start acknowledgement is not sufficient proof that streaming has actually started.

Before enabling Connect, a real start/stop/heartbeat/watchdog protocol must be connected to the StarDesk runtime and tested on real host/client devices, with an isolated coin ledger settlement that never mutates legacy rental seconds. Verify disconnect, crash, reconnect, zero balance, expiry, concurrency, and idempotent settlement.

## Verification status

- Source-level checks were updated in `.github/workflows/build-stardesk-client.yml`.
- Android APK build runs were triggered by GitHub Actions after source updates; check the branch's Actions runs for the final build and artifact.
- Full PostgreSQL regression workflow now includes this feature branch and is triggered by the workflow change. It tests the existing core billing APIs, Remote Play pairing, watchdog, stream billing-clock behavior, coin wallet, x100 conversion, rates, and legacy rental isolation on disposable PostgreSQL.
- No active Android DB migration was applied.
- No Windows Desktop 1.6.0 installer or source was inspected or changed.
- No real Android device installation or actual StarDesk remote streaming acceptance test was performed.

Status: **SAFE-TEST / Preview only — not production-approved.**
