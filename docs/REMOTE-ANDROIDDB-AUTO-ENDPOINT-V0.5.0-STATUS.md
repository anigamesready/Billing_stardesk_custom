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

- Latest Android build CI run [45586112399](https://github.com/anigamesready/Billing_stardesk_custom/actions/runs/45586112399) at source commit `9d8e9eec79f9cd682f7a9c87be6ce06b92504a06`: **passed**. This build includes the local account-expiry access gate. Static endpoint/UI checks, JavaScript syntax, Gradle clean build, package metadata, APK signature and ZIP integrity all passed.
- APK package: `com.anigamesready.stardeskclient`; versionCode `5`; versionName `0.5.0-androiddb-auto-endpoint-preview`.
- APK SHA-256: `3d0186560627223f0e8117c6a5fa3cbf9b6473966e50063c91bb4b22509b1b5e`.
- Debug signing certificate SHA-256: `cad87dc29e53b09a7aa1db83e3a06edf506f3f0c05f5c6db3f5b2eb807851a1e`.
- Full PostgreSQL regression run [45585609068](https://github.com/anigamesready/Billing_stardesk_custom/actions/runs/45585609068): **passed**. This covered the core billing regression suite, Remote Play login/pairing/Owner permissions/watchdog, authenticated stream billing clock, coin wallet/top-up/lot expiry/GPU rates/StarDesk mapping, one-time x100 migration reruns, and upgrade from core-only Android DB on disposable PostgreSQL.
- No active Android DB migration was applied.
- No Windows Desktop 1.6.0 installer or source was inspected or changed.
- No real Android device installation or actual StarDesk remote streaming acceptance test was performed.
- The gateway URL is fixed in the app, but the live relay-agent/API/database health probe could not be externally confirmed during this task. On device, the app will fail closed until its own HTTPS health probe reports all dependencies online.

Status: **SAFE-TEST / Preview only — not production-approved.**
