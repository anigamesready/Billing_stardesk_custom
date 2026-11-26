# StarDesk Custom Admin — Coin x100 User ID-only Preview 0.2.7

A standalone Android Owner/Admin app built only from this repository. Package identity remains separate from Admin V12.x. This preview is intended for functional review, not production deployment.

## Identity

- Package: `com.anigames.billingadmin.coinx100preview`
- App label: `Ani Games Admin Coin x100 0.2.7`
- Install mode: side-by-side with the previous `com.anigames.billingadmin.coinpreview` (Admin 0.2.5) app
- Namespace: `com.anigamesready.adminandroiddbv0`
- Version: `0.2.7-userid-only-remote-login`, versionCode `9`
- Source root: `admin-androiddb-v0/`
- Admin UI: `app/src/main/assets/index.html`

## Admin navigation

- **Ringkasan** — Coin summary, Host Agent readiness, top-up queue, and PC heartbeat overview. It no longer requests or displays old timer-rental counts.
- **Pairing PC** — creates a one-time PC Billing enrollment code using the existing `create_enrollment` RPC. Host Agent enrollment is a separate action scoped to a selected registered PC; it uses `androiddb_v0_admin_issue_host_enrollment`.
- **PC Aktif** — lists devices by the current `admin_devices` heartbeat state and separates online from offline PCs.
- **Windows Control** — refresh/restart Billing, logout Billing, pause/resume/stop an active Billing session, Windows logoff, restart and shutdown. Pause/resume/stop now include the selected active `session_id`. A command is only shown as successful after the PC reports terminal `completed` status through the command ACK route; queued or acknowledged commands remain pending.
- **User Billing Control** — retains the existing Admin/Reseller account management and reseller creation screens.
- **Chat ke Windows** — visible but deliberately disabled. The reference Admin issues `show_admin_message`, while the PC client receiver for that command was not present in the verifiable bundled PC source. Sending it from this Admin would risk a command that queues but never displays. Enable only after a PC-side receiver is added and tested with a completed ACK.
- **FREE TEST 10 MENIT** — Free Test policy and PC selection are separated from general settings. The Admin waits for the PC's command ACK before displaying success. Compatibility of the actual PC client with the `start_trial` command still needs a real-PC test.
- **WoL Android Relay** — retains Relay enrollment, probe, WoL command status and Blynk momentary pulse controls.
- **Data User Coin** — creates and lists Coin member accounts, active/disabled status, current Remote login status, balances and wallet details (lots, ledger and orders).
- **PC Host & Tarif** — GPU class/hourly tariff, StarDesk device mapping, Host permission and Host Agent readiness/enrollment.
- **Top-up** — approve/reject pending top-ups and inspect wallet details.
- **Pengaturan** — stop/pause policy and Owner password change only. Organization Theme controls were removed.


### Remote renter authentication

The renter enters only the registered rental User ID in Remote. Admin no longer issues or verifies a Remote activation code, and this Admin app has no **Kode Remote** action. The app-generated installation ID is handled automatically by Remote. Owner retains only account-level enable/disable control. The database upgrade in migration `027_androiddb_v0_remote_userid_only_login.sql` drops the Admin activation function/table and the old login signature.

## Coin domain

The visible Admin rental/member workflow uses only the `androiddb_v0` Coin domain and the x100 denomination from migration `026_androiddb_v0_coin_x100.sql`:

- `coin_unit_config.coin_scale` is `100`; each previous v0 Coin amount is multiplied once, guarded by the scale row.
- Rp8,000 converts to 6,000 AniCoin. Rp5,000=3,750; Rp10,000=7,500; Rp15,000=11,250; Rp20,000=15,000.
- GPU rates: GTX1050/GTX1660=4,500 AniCoin/hour; RTX3060=5,250; RTX5060=6,000. The Rupiah prices stay Rp6,000/Rp6,000/Rp7,000/Rp8,000.

- One member wallet balance is shared across supported PCs.
- Coin expiry belongs to each top-up lot, not to an account timer.
- Top-up approval creates a Coin lot and ledger entry; repeated approval is idempotent.
- PC tariff is configured by GPU class and mapped StarDesk device.
- Host Agent readiness requires permission, tariff, StarDesk mapping and a recent Host Agent heartbeat; a PC Billing heartbeat alone does not make a PC StarDesk-ready.

The current Coin Admin scope provides account creation/listing, enable/disable, User ID-only Remote login status, wallet/lots/ledger, top-up approval/rejection and per-PC tariff/mapping. The Admin source does not yet expose rental member edit/delete operations because matching `androiddb_v0` RPCs are not in the current migration contract.

**Coin session charging/settlement is not claimed as enabled by this Admin UI.** Wallet/lot/ledger and pricing administration do not by themselves prove reservation, per-minute debit, expiry settlement, refund or concurrency-safe session accounting. Those require their own backend implementation and integration tests.

## Data and isolation

- StarDesk custom uses its own database `stardesk_custom_v0`, API login, local API port `8789`, Cloudflare `/stardesk` route and service identity.
- This Admin UI no longer calls the old timer rental CRUD APIs and does not show the old timer rental list or old timer rental permission controls.
- Existing legacy timer tables, APIs and historical data are **not deleted** by this UI change. They remain untouched for data preservation and rollback; there is no cross-database copy, fallback, dual-write or synchronization.
- The original Ani Games Ready installation (`ani_games_ready_stage`, local API `8788`) and its services are not changed by this branch.
- No live database migration or destructive SQL is included in this UI-only update.

## Verification status

Static source checks on the feature branch:
- 46 distinct HTML click handlers were matched to declared JavaScript functions.
- Admin UI contains 40 literal RPC calls, each of which must match the Android DB server allowlist in CI.
- Old timer rental list/CRUD, old timer count, Theme editor/save function and old timer-based Remote permission controls are removed from the visible Admin source.
- Windows pause/resume/stop now resolve the active session and include `session_id`.
- Windows Control and Free Test poll command status and do not display success without PC `completed` ACK.
- Chat remains disabled until the PC-side `show_admin_message` receiver is verified.
- The build workflow checks JavaScript syntax, click handlers, backend RPC allowlists, no old timer/Theme UI, isolated gateway/TLS behavior, Android package/version and APK signature.

A successful CI build is not the same as a real Android/PC runtime test. Before production use, install this new APK on the target Android device and test Owner login, each menu/action, actual PC enrollment/heartbeat, Windows commands on an online PC, Free Test on a supported PC client, WoL Relay, Coin account/top-up/wallet reads and writes, network/offline errors, and the StarDesk Host connection flow. Record the Android version and actual PC Billing/Host Agent versions. Until those tests pass, this remains a **preview candidate**, not a production-ready release.

## Build and rollback

- Build workflow: `.github/workflows/build-admin-androiddb-v0.yml`
- Expected output: `Ani-Games-Admin-Coin-x100-UserID-Only-0.2.7.apk`
- Previous Admin 0.2.4 build remains an artifact/reference. No PR merge or production replacement is authorized by this change.
