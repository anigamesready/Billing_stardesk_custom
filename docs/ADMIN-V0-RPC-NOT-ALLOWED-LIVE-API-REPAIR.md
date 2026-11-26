# Admin Android DB v0 — Live API repair for RPC_NOT_ALLOWED

## Root cause

The Admin v0 login flow is:

1. Native route `__admin_login` → `POST /auth/v1/token?grant_type=password`.
2. After token receipt, the UI calls `POST /rest/v1/rpc/admin_context`.
3. The UI checks the Owner context and then loads `androiddb_v0_admin_dashboard`.

The Android UI's literal RPC routes were compared to the current Node API `RPC` allowlist. All 58 calls in the Admin UI are present in the source allowlist. The source includes both `admin_context` and `androiddb_v0_admin_dashboard`. The Node API returns `RPC_NOT_ALLOWED` only when the requested name is absent from the `RPC` map. Therefore the Redmi's already-running Node process is serving an older/stale in-memory API implementation that has not been restarted on the current source. The login flow stays on the login screen because the context call is required before showing the Admin workspace; all Owner menus consequently appear locked.

The current Admin v0.2.1 APK does not need another reinstall to fix this backend allowlist mismatch. Its visible HTML badge still says v0.2.0; that is a stale hard-coded label, not the APK package metadata.

## Live repair script

File: `backend/android-db/termux/repair-admin-v0-live-api.sh`

The one-command repair is pinned to repository commit:

`df24bff5f62dd38fa5c0073995aa59f5023154f0`

Run in the existing Redmi Termux installation:

```bash
REF=df24bff5f62dd38fa5c0073995aa59f5023154f0 && curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/termux/repair-admin-v0-live-api.sh" -o "$HOME/ANI-ADMIN-V0-API-REPAIR.sh" && bash "$HOME/ANI-ADMIN-V0-API-REPAIR.sh"
```

The script is fail-closed and checks all of the following before changing anything:
- It only targets `$HOME/ani-games-db-android-stage/server`, database `ani_games_ready_stage`, PostgreSQL socket port `5432`, and API port `8788`.
- It requires the existing .env values to be present and loopback-only. It never prints credentials or tokens.
- It identifies exactly one Node process whose cwd, command, database URL, API pepper, bind address and port match the stage API. It refuses to stop another Node process.
- It checks the existing core Admin authentication wrappers and Remote Play/WoL schema before allowing the v0 migration path.
- If `androiddb_v0` is absent, it creates a custom-format database backup and cluster-role backup, verifies the archive with `pg_restore --list`, verifies SHA-256 checksums, then requires the exact operator confirmation `APPLY`.
- It applies only additive migration `025_admin_androiddb_v0_coin_domain.sql`. It does not copy legacy rental members, alter legacy rental seconds/expiry, or replace legacy rental tables.
- It verifies 14 v0 tables and all 20 v0 API signatures before updating the Node API source.
- It backs up the existing `server.mjs`, installs the pinned current API source, stops/restarts only the matching Node API process, and checks `/health`.
- It sends unauthenticated smoke requests to `admin_context` and `androiddb_v0_admin_dashboard`. Both must return the expected protected response `401 AUTH_REQUIRED`; a `404 RPC_NOT_ALLOWED` fails the repair check.
- If the new Node process fails to start or fails a smoke test, it restores the previous `server.mjs` and attempts to restart the previous API process.

## What the repair does not change

- It does not stop, restart, initialize, upgrade or delete PostgreSQL.
- It does not overwrite `.env`, regenerate DB credentials or change API pepper.
- It does not modify Cloudflare Worker configuration, Worker secrets, Gateway hostname, or Relay Agent secrets.
- It does not change the stable Admin V12.x APK.
- It does not change the StarDesk video path.

## CI evidence

- Termux installer + repair script: shell syntax, ShellCheck, safety gates, embedded Node controller syntax, release contents and Node API syntax passed in [run 45773963375](https://github.com/anigamesready/Billing_stardesk_custom/actions/runs/45773963375).
- PostgreSQL legacy/Remote Play/Owner/Coin v0 regression and core-only upgrade passed in [run 45773854909](https://github.com/anigamesready/Billing_stardesk_custom/actions/runs/45773854909).

CI used disposable PostgreSQL. It does not by itself apply migration 025 or restart the live Redmi process. The live repair script must be run on the Redmi; after it reports both protected RPC smoke tests passed, sign in with the Owner account again.
