# Android DB Backend — Termux

## Pinned one-command installation

Use the exact 40-character commit SHA supplied with the release. Do not replace it with a moving branch name.

```bash
REF=<40-character-commit-sha>
curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/termux/install.sh" | ANI_DB_REF="$REF" bash
```

The installer verifies it is running inside Termux, checks the existing PostgreSQL cluster before installing packages, fetches the repository archive at the same immutable commit, validates it, installs the Node API, and creates supervised PostgreSQL/API services. Existing `server/.env` and PostgreSQL data are not overwritten.

## Database layout and separation

The active Android DB retains its original core business and authentication tables for Admin/Owner, organization membership and PC inventory.

The new **Admin Android DB v0** Coin business domain is separate in schema `androiddb_v0`. Its 14 tables are:
- `rental_accounts`, `client_credentials`, `client_sessions`
- `coin_wallets`, `coin_topup_orders`, `coin_lots`, `coin_ledger`
- `pc_coin_rates`, `stardesk_device_links`
- `host_permissions`, `host_enrollments`, `host_registrations`
- `sessions`, `audit_events`

The v0 rental account has only active/disabled/deleted state. It does not use the legacy rental timer balance or legacy account expiry. Coin expiry belongs to each wallet lot. The v0 functions do not deduct `public.rental_accounts.remaining_seconds` or reuse the legacy Remote Play settlement.

The v0 domain references existing organization/Owner authentication and `public.devices` for the PC inventory identity only. Member identity, activation, sessions, wallet, lots, ledger, top-ups, rates, StarDesk mapping, Host Agent and audit records belong to `androiddb_v0`.

## Ordered migrations

- New empty database: `000`, `002`–`023`, then `025_admin_androiddb_v0_coin_domain.sql`. Historical catalog snapshot `001` is never replayed.
- Existing core-only database: preserve migrations `000`–`012`; apply the additive Remote Play/Coin/WoL/API read migrations required by the installer, then migration `025` for the separate v0 schema. Core migrations are never replayed.
- Migration `023_admin_coin_management_read_api.sql` adds the existing Admin Coin read functions; it is distinct from the new v0 RPC family in migration `025`.
- Migration `025_admin_androiddb_v0_coin_domain.sql` adds 14 v0 tables and 20 v0 API functions. It is additive; it does not drop, truncate, rename or replace legacy rental/device tables.

The Node API has its own explicit RPC allowlist in `backend/android-db/server/server.mjs`. A SQL function and GRANT alone are not enough: the RPC name must also be allowlisted by the Node server. The installer checks the v0 API source and the local database signatures before reporting readiness.

## Existing database upgrade safety

The installer fails closed on an unrecognized PostgreSQL data directory, a major-version mismatch, an existing cluster not supervised by runit, an incomplete legacy Remote Play add-on, or a partially installed v0 schema.

For an existing database where v0 is not installed:
1. The installer validates the existing core and old add-on signatures.
2. It creates a custom-format database backup and cluster-role backup.
3. It verifies the database dump with `pg_restore --list`, records SHA-256 checksums, and stores the backup under `~/ani-games-ready-backups/`.
4. It asks for the exact typed confirmation `APPLY`.
5. Only after that confirmation does it apply migration 025.

The installer checks all 14 v0 tables and all 20 v0 API signatures. A partial schema/function set stops for manual audit rather than guessing how to repair it. No migration is automatically run from this documentation; the installer is an explicit operator action.

Do not apply migration 025 manually to the older Supabase project or a different database. This v0 deployment belongs to the Android DB Termux database only. Do not migrate legacy rental members into the Coin domain without a separately approved migration plan.

## Coin baseline

- Conversion: Rp8.000 = 60 Coin.
- GTX 1050: Rp6.000/hour = 45 Coin/hour.
- GTX 1660: Rp6.000/hour = 45 Coin/hour.
- RTX 3060: Rp7.000/hour = 52,5 Coin/hour.
- RTX 5060: Rp8.000/hour = 60 Coin/hour.
- Static QRIS creates a pending order. The Owner must verify payment and approve it before a Coin lot is credited.
- Lot validity follows the approved expiry tier. The rental account itself does not have an old-style expiry date.

## API runtime and Cloudflare boundary

The PostgreSQL API role inherits only `ani_api_runtime`; the Node process does not connect as PostgreSQL superuser. API credentials are stored in `server/.env` with mode 600. The local Node API binds to loopback (127.0.0.1) on port 8788 only.

The public HTTPS gateway and WebSocket relay are separate Cloudflare Workers, configured to route to the private Android DB relay. Worker presence and service bindings do not prove the Redmi relay is connected or the PostgreSQL database is healthy. Use the endpoint and logs below on the actual Redmi to verify runtime health.

## Service controls

```bash
sv status postgres
sv status ani-games-ready-api
sv down ani-games-ready-api && sv up ani-games-ready-api
cat "$PREFIX/var/log/sv/ani-games-ready-api/current"
curl -fsS http://127.0.0.1:8788/health
```

Local health endpoint: `http://127.0.0.1:8788/health`

First Owner setup page (only when initial Owner setup is still required): `http://127.0.0.1:8788/setup`

Blynk auth token is requested as an optional hidden prompt on first install. On a reinstall, existing .env values are preserved.

## Start after Android reboot

`termux-services` supervises enabled processes when its service daemon is running. The installer creates `~/.termux/boot/99-ani-games-ready-services`; to start services automatically after Android reboots, separately install the Termux:Boot companion app from the same trusted Termux distribution, open it once, and allow background execution/battery use. Android vendor battery-management policies can still stop background apps; this is not a hardware-level always-on guarantee.

## Existing system backup and rollback

Before installing migration 025 on a live database, confirm the backup files under `~/ani-games-ready-backups/` are present and valid. Keep these files private because they contain business data and PostgreSQL role metadata. Do not restore blindly over a newer live database; rollback should be planned with service stopped and database snapshot verified.
