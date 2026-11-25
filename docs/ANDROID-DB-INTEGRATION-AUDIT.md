# Android DB Integration Audit — Remote Play + Coin Wallet

Audit source date: 2026-11-24. This is a source/contract audit, not a live Redmi host inspection.

## Source lineage checked
- Remote client repository: `anigamesready/Billing_stardesk_custom`; isolated preview branch created from `stardesk-client-v1` commit `064620ebb5c7b1e72e7b28a71621fcb7a327a643`.
- Android DB API source: `anigamesready/PC-Billing`, pinned commit `bd11d9b4e53ece362715a772f210c7e3b13adba1`; relevant file `db-android-core/server/server.mjs`.
- Current Android DB API uses local Node + PostgreSQL and the allowlisted `/rest/v1/rpc/<name>` interface (also supports `/functions/v1/ani-games-api/<name>`). This is the intended API boundary.
- Existing Remote Play SQL migrations in this source lineage: `013_remote_play.sql`, `014_remote_play_pairing.sql`, `015_remote_play_admin_controls.sql`, `016_remote_play_cloudflare_mesh.sql`, `017_remote_play_dashboard_cooldown.sql`, `018_remote_play_server_watchdog.sql`, `019_remote_play_session_connected.sql`.

## Existing API controls mapped
- Remote client: `remote_play_login`, `remote_play_refresh`, `remote_play_logout`, `remote_play_dashboard`, `remote_play_request_session`, `remote_play_session_heartbeat`, `remote_play_session_connected`, `remote_play_end_session`, `remote_play_pairing_prepare`.
- Host: `remote_play_host_enroll`, `remote_play_host_heartbeat`, `remote_play_host_next_command`, `remote_play_host_ack`, `remote_play_host_pairing_poll`, `remote_play_host_pairing_complete`.
- Admin: `admin_remote_play_set_host_permission`, `admin_remote_play_set_rental_permission`, `admin_remote_play_issue_client_credential`, `admin_remote_play_issue_host_enrollment`, `admin_remote_play_sessions`, `admin_remote_play_dashboard`.
- Client login currently requires rental code + activation code + client install ID. User ID alone is not sufficient for a secure first activation; proposed UX is first-time activation provisioned/approved in Admin, then store a revocable client token securely for later User ID-only re-entry. This needs explicit API/UX implementation and test.

## Critical coupling found
Existing `private.remote_play_settle_session` settles Remote Play by deducting `public.rental_accounts.remaining_seconds`. That is the legacy rental-time charging path. Coin billing MUST NOT call this unchanged for coin-wallet sessions or it will deduct both time and coins / incorrectly expire rental time. Coin support needs an explicit billing mode or a separate coin-billing settlement function, with an atomic link to the existing host-control session and one idempotent ledger settlement.

## Planned additive API work
- Wallet read + valid coin lot balance.
- Top-up order creation with fixed price/coin snapshot; static QRIS display is client-side; WhatsApp only requests proof/review.
- Owner/Admin-only approve/reject endpoint; approval atomically changes order state, creates coin lot, adds ledger record and wallet balance once.
- Coin session start must lock wallet and PC/rate, verify current positive non-expired balance and host-ready state; session uses an idempotency key.
- Heartbeat/accounting uses server time, not client clock; charge at sub-minute precision in a numeric ledger; insufficient balance initiates stop command and settles once.
- Disconnect, app-kill, host offline and watchdog paths must settle idempotently and safely.
- Existing normal PC Billing rental sessions and normal remote-play rental-time mode remain untouched unless an explicit coin-wallet mode is selected.
- All RPCs go through server allowlist; validate family token, org scope, account ownership and rate limits. Never expose activation secret or host token to client UI.

## Live-device limitation
The source archive `ANI-GAMES-DB-ANDROID-FULL-AUDIT.tgz` from 2026-11-23 reflects an earlier staging snapshot where the staged API listened on loopback port 8788 and returned `remote_access_enabled:false`; it is stale evidence and does not prove the current Redmi state. Current running Node PID, .env port, installed schema versions, tunnel/WSS status and health response were not queried from the phone. Therefore no claim is made that the current Redmi service accepts remote clients today.

## Dual-DB removal scope
- New Remote client preview contains no Supabase URL/key or DB1/DB2 route logic.
- Admin APK itself is a separate product source/build chain. Its currently inspected V12.1.50 DB Android workflow still applies legacy dual-DB patch scripts, so its next clean build requires a separate isolated source/build cleanup and regression audit. Do not modify Admin baseline from this Remote client branch.
- No Supabase schema, Edge Function, production database, or live Android DB was changed by this audit.

## Safety/regression gates before activation
1. Verify installed Android DB API SHA/version and active port from current Redmi runtime.
2. Verify backup/restore on a disposable local PostgreSQL DB.
3. Confirm Remote Play migrations 013–019 exist and test all existing host/client/Admin RPCs.
4. Add coin SQL in additive migrations on a fresh isolated staging DB only.
5. Test top-up duplicate approval, rejected payment, exact coin decimals, expiry tiers, FIFO lot consumption, insufficient balance, pause/disconnect/reconnect, host watchdog, app force-close, and simultaneous PC selection.
6. Re-run existing PC Billing, Admin, Reseller auth/rental/command/report regression suite.
7. Only enable coin billing after the separate DB and API build passes; retain existing rental-time billing as unchanged fallback.
