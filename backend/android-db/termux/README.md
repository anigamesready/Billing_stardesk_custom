# StarDesk Custom v0 — Android / Termux

## Isolation boundary

This installer is only for the StarDesk Custom project in `anigamesready/Billing_stardesk_custom`.

StarDesk uses a **new, independent PostgreSQL database and application runtime**. The PostgreSQL server process may be shared with the already-running Termux cluster, but no application data or API credentials are shared.

| Component | StarDesk Custom |
|---|---|
| Database | `stardesk_custom_v0` |
| Database owner | `stardesk_v0_owner` (NOLOGIN) |
| API login | `stardesk_v0_login` |
| API runtime | `stardesk_v0_runtime` (NOLOGIN) |
| Local application folder | `$HOME/ani-games-stardesk-custom-v0` |
| Local API port | `8789` |
| API runit service | `stardesk-custom-v0-api` |
| Relay Agent service | `ani-games-stardesk-relay-agent` |
| Gateway prefix | `/stardesk` |
| Relay Durable Object hub | `redmi-stardesk-custom` |

The old Ani Games Ready installation keeps its own database, API port `8788`, API service `ani-games-ready-api`, relay service, relay hub, credentials, sessions and rental data. The StarDesk installer must not change or restart any of them.

There is no import, copy, synchronization, fallback, or dual-write between the legacy rental timer and StarDesk Coin. StarDesk has its own account, activation, wallet, Coin lots/expiry, ledger, top-up, PC rate, Host enrollment, and Remote Play session data.

## Quick DB control menu (Termux)

The menu inspects both databases side by side without merging them. The legacy system is **read-only/status-only**; only the two StarDesk services can be started or restarted. It never restarts PostgreSQL, the old Ani Games API, or the old relay.

Download from the exact StarDesk commit SHA:

```bash
REF=<40-character-commit-sha>
curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/termux/stardesk-db-control.sh" -o "$HOME/STAR-DESK-DB-CONTROL.sh" &&
chmod 700 "$HOME/STAR-DESK-DB-CONTROL.sh" &&
bash "$HOME/STAR-DESK-DB-CONTROL.sh"
```

Menu options include read-only status for both DB/API pairs, Gateway-to-Relay health probe, read-only-default psql access to either database, StarDesk-only API/Relay restarts, and StarDesk service logs. There is no database switch, data copy, migration, deletion, or PostgreSQL lifecycle control.


## Install StarDesk database and API

Use the exact 40-character commit SHA supplied for the StarDesk test build. Do not use a branch name or a SHA from another repository.

```bash
REF=<40-character-commit-sha>
curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/termux/install-stardesk-custom-v0.sh" -o "$HOME/stardesk-setup/install-db.sh"
ANI_STARDESK_SOURCE_REF="$REF" bash "$HOME/stardesk-setup/install-db.sh"
```

The `ANI_STARDESK_SOURCE_REF` value is mandatory. It makes the installer download the API source and migration files from the **same immutable commit** as the installer script. The installer stops if this pin is missing or malformed.

### PostgreSQL safety checks

The installer only uses an already-running PostgreSQL cluster. It checks that:

- the Termux data directory and `PG_VERSION` exist;
- PostgreSQL answers on the Termux socket and port;
- the responding server's `SHOW data_directory` resolves to the expected Termux data directory;
- the active server major version matches the cluster's `PG_VERSION`;
- a local PostgreSQL superuser connection is available.

It does not execute `initdb`, `pg_ctl`, `sv up postgres`, `sv down postgres`, package upgrades, or any PostgreSQL restart. If the database server is not already healthy, installation stops. Do not try to force it through or run the legacy installer.

The installer fails closed if the StarDesk database, any StarDesk role, application folder, dedicated service folder, or port `8789` already exists. An existing partial installation requires a separate audit; it is never overwritten.

Once preflight passes, the installer creates only `stardesk_custom_v0`, its dedicated owner/runtime/login roles, its source folder, and the API service on port `8789`. It does not copy any records from the old rental database. API credentials and the one-time Owner bootstrap token are kept in `server/.env` with mode `600`; secret values are never printed.

## Update an existing StarDesk v0 database to Remote User ID-only login

Do **not** rerun the initial installer against an existing installation. Use the dedicated updater instead. It verifies the database name/owner, three StarDesk roles, local API port 8789, API service/process, active PostgreSQL data directory and cluster version. It requires a pinned commit SHA.

Download the updater from the exact same commit before running it:

```bash
REF=<40-character-commit-sha>
curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/termux/update-stardesk-custom-v0-userid-login.sh" -o "$HOME/update-stardesk-custom-v0-userid-login.sh"
chmod 700 "$HOME/update-stardesk-custom-v0-userid-login.sh"
ANI_STARDESK_SOURCE_REF="$REF" bash "$HOME/update-stardesk-custom-v0-userid-login.sh"
```

The updater first makes and checksum-verifies a full custom-format database dump, cluster-role backup, and API source backup. It then requires the exact confirmation word APPLY. It applies migration 026 only to stardesk_custom_v0, updates only server.mjs in the StarDesk API directory, and restarts only stardesk-custom-v0-api. It checks the new two-parameter RPC route and health response after restart. It does not restart PostgreSQL, the StarDesk Relay Agent, the legacy Ani Games API/relay, or change the legacy database. If API verification fails, the old StarDesk API source is restored and only the StarDesk API service is restarted.

## Install the dedicated Relay Agent

Run this only after the dedicated API health endpoint reports both API and database online:

```bash
curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/relay-agent/install-stardesk-agent.sh" -o "$HOME/stardesk-setup/install-relay.sh"
ANI_RELAY_REF="$REF" bash "$HOME/stardesk-setup/install-relay.sh"
```

The new Agent uses the existing Relay shared secret locally; it must not create or rotate a secret. It uses API port `8789`, route `/agent/connect/stardesk`, service `ani-games-stardesk-relay-agent`, and hub `redmi-stardesk-custom`. The old Agent and old hub remain unchanged.

## Verify local installation

These are read-only checks:

```bash
sv status postgres
sv status stardesk-custom-v0-api
sv status ani-games-stardesk-relay-agent
curl -fsS http://127.0.0.1:8789/health
```

Expected health response must indicate both `api: online` and `database: online`. If `postgres` is not shown as runit-managed but PostgreSQL is already responding, the installer validates the active server's data directory and version before deciding whether it can safely use that existing process. It never starts or restarts it.

First Owner setup page, only while Owner bootstrap remains available:

`http://127.0.0.1:8789/setup`

Create a new StarDesk Owner. It is not automatically copied from the old system. Then install the StarDesk Admin APK and log in using this new Owner account.

## Database and Coin domain

A fresh StarDesk database receives migrations `000`, `002`–`023`, `025_admin_androiddb_v0_coin_domain.sql`, and `026_androiddb_v0_userid_only_remote_login.sql`. Historical catalog snapshot `001` is not replayed.

The dedicated `androiddb_v0` schema contains 14 tables:
- `rental_accounts`, `client_credentials`, `client_sessions`
- `coin_wallets`, `coin_topup_orders`, `coin_lots`, `coin_ledger`
- `pc_coin_rates`, `stardesk_device_links`
- `host_permissions`, `host_enrollments`, `host_registrations`
- `sessions`, `audit_events`

It also provides 20 Admin, Host and Remote RPC functions. The API server has a separate RPC allowlist; a SQL function and a GRANT alone do not prove that the corresponding HTTP RPC is available.

Coin baseline:
- Conversion: Rp8.000 = 60 Coin.
- GTX 1050: Rp6.000/hour = 45 Coin/hour.
- GTX 1660: Rp6.000/hour = 45 Coin/hour.
- RTX 3060: Rp7.000/hour = 52,5 Coin/hour.
- RTX 5060: Rp8.000/hour = 60 Coin/hour.
- Static QRIS creates a pending order. The Owner must verify and approve it before a Coin lot is credited.
- Expiry belongs to each Coin lot. The StarDesk rental account does not reuse the old rental timer's remaining-seconds balance or expiry.

## Existing Ani Games Ready installer — do not use for StarDesk

`backend/android-db/termux/install.sh`, `repair-admin-v0-live-api.sh`, and `audit-admin-v0-live-db.sh` belong to the **existing** Ani Games Ready Android DB/API workflow. They target the legacy stage database and/or port `8788`. They are not StarDesk installers.

Do not run those scripts to install, repair or migrate StarDesk. Do not point the StarDesk APK at the legacy URL or database. StarDesk deployment and builds remain confined to this repository's dedicated feature branch and workflows until the user approves a release.
