# StarDesk Custom Admin — Agent & Manual Tariff Preview 0.2.9

A standalone Android Owner/Admin app built from this repository. The APK keeps the isolated package identity `com.anigames.billingadmin.coinx100preview` and can remain installed beside the separate Admin V12.x app. This is a preview candidate, not a production release.

## Identity

- Package: `com.anigames.billingadmin.coinx100preview`
- App label: `Ani Games Admin Coin x100 + Agent Preview 0.2.9`
- Namespace: `com.anigamesready.adminandroiddbv0`
- Version: `0.2.9-agent-manual-pricing`, versionCode `11`
- UI source: `app/src/main/assets/index.html`

## Navigation

The first row now contains only four frequently used destinations: Ringkasan, PC Host, Agent PC, and Top-up. The `☰ Menu` button opens a right-side drawer containing the full module list: Pairing PC Billing, PC Aktif, Windows Control, FREE TEST 10 MENIT, WoL Android Relay, Data User Coin, Laporan, User Billing Control, Chat ke Windows, and Pengaturan. All existing section IDs and actions remain in place.

## Manual per-PC tariffs

GPU names are free text; the Admin no longer calculates the rate from a fixed GPU model.

For a new Windows Agent pairing, Owner enters:
- Pair code (8 digits), rental PC name and GPU/PC description.
- Hourly Rupiah amount.
- Hourly AniCoin amount (up to two decimal places).

The Agent PC list allows the Owner to edit the same four fields. PC Host & Tarif also accepts its GPU description, Rupiah/hour and AniCoin/hour independently for each PC.

The price parser accepts plain Rupiah input (8000) and Indonesian grouped input (8.000 or Rp 8.000); AniCoin accepts decimal commas or points. Regression tests execute these cases to prevent the previous double-escaped digit-regex bug. The database keeps AniCoin at x100 precision (for example, 52.5 AniCoin is stored as 5,250 units). Rupiah and Coin rates are validated as positive values with a bounded maximum. A manual tariff setting only configures pricing; it does not prove that streaming is ready or enable Coin session debit/settlement.

## RPC_NOT_ALLOWED repair

The previous screenshot's error is consistent with the running StarDesk Custom Node API still serving an older in-memory RPC allowlist. APK changes alone cannot add missing RPC handlers to that live process.

Migration `028_manual_pc_tariffs.sql` adds the manual tariff schema/routines. The StarDesk Termux upgrade script now:
- Targets only database `stardesk_custom_v0`, API port `8789` and service `stardesk-custom-v0-api`.
- Applies isolated migrations 027 and 028 and copies the API source pinned to a commit.
- Restarts only the StarDesk Custom API service.
- Calls the Agent list, manual pair/update and Host manual-rate RPCs without credentials and expects `401 AUTH_REQUIRED`. This proves each route exists; a `404 RPC_NOT_ALLOWED` fails the check.
- Restores the previous `server.mjs` and restarts the same service if health or RPC preflight fails. Applied migrations are additive and remain available for retry.

The upgrade script has **not** been run against the live Termux installation by this source change. Do not install the new APK for live use until the pinned backend upgrade completes successfully.

## Isolation and safety

StarDesk Custom uses its own `stardesk_custom_v0` database, runtime role, API port 8789 and Cloudflare `/stardesk` path. The legacy Ani Games Ready database/API on port 8788, existing Billing services, rental timer tables, old relay and stable Admin V12.x are not changed by this branch. No branch merge or live DB mutation is authorized by this change.

The status shown for a Windows Agent is its heartbeat only. It is not evidence that the StarDesk Host is ready for streaming. Coin debit/settlement remains disabled until host session start/stop callbacks and concurrency-safe accounting exist.

## Verification gate

CI checks backend RPC definitions, manual tariff validation and x100 unit conversion, Admin JavaScript syntax, drawer menu coverage, Termux installer/upgrade shell syntax, Android package metadata, APK signing and ZIP integrity. These automated checks do not replace live tests.

Before production use, verify on the target Redmi and a spare Windows PC: run the pinned Termux upgrade, sign in as Owner, open every drawer entry, list and pair an Agent, edit tariffs and re-read them, confirm PC Host settings, test heartbeat and allowlisted Windows commands, and verify API/relay offline behavior. Keep this APK as a preview candidate until these real-device tests pass.
