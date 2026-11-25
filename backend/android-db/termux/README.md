# Android DB Backend — Termux

## Pinned one-command installation

Use the exact 40-character commit SHA supplied with the release. Do not replace it with a moving branch name.

```bash
REF=<40-character-commit-sha>
curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/termux/install.sh" | ANI_DB_REF="$REF" bash
```

The installer checks that it is running inside Termux, installs PostgreSQL + Node.js LTS + npm + `termux-services`, downloads the repository archive at the same immutable commit, validates the archive, installs the API, and creates supervised PostgreSQL/API services.

## Database safety rules

- Existing `server/.env` is preserved; it is never overwritten by the archive.
- The standard Termux PostgreSQL data directory is inspected before `initdb`. A non-empty unrecognized directory or a running server outside runit causes a safe stop. The installer does not initialize over it.
- When an existing PostgreSQL cluster is found, the installer compares its `PG_VERSION` with the installed server major version before package installation. It does not request a PostgreSQL package upgrade over an existing cluster. A version mismatch stops the installer; `pg_upgrade` is never run automatically.
- A new empty database receives the ordered migrations `000`, `002`–`024`. The historical catalog snapshot `001` is never replayed.
- An existing core-only Android DB is accepted only when the required rental, device, session, audit, admin and token contracts match. If the `remote_play` schema is completely absent, the installer first makes a full database and role backup, verifies it, requires the exact `APPLY` confirmation, then applies additive migrations `013`–`019` in order before coin/WoL. It never replays core migrations `000`–`012`. If `remote_play` already exists but key `013`–`019` contracts are incomplete, the installer stops rather than guessing how to repair a partial schema.
- When the existing DB needs coin/WoL addon migrations, it first creates a custom-format `pg_dump`, backs up cluster roles, verifies the dump with `pg_restore --list`, records SHA-256 checksums, and then asks for the exact confirmation word `APPLY`.
- Migration `022` uses a locked scale registry. Version-1 coin balances, lots, orders, ledger quantities, and PC rates are multiplied by 100 once. Reruns at scale 100 do not multiply again. Rupiah values, rental seconds, and rental status are not scaled.
- Migration `023` adds the two Owner-only Admin Coin read APIs used by Admin v12.1.61. Migration `024` fixes the server-side Coin start gate so disabled/deleted/inactive/expired accounts and accounts with a missing/past expiry are denied even when the wallet contains coins.
- The installer checks the presence of both Admin Coin read RPCs and the expiry-guard function comment/version. Existing upgrades keep the same verified backup + explicit `APPLY` confirmation before applying the additive migrations.
- No `DROP`, `TRUNCATE`, or destructive replacement of core rental/device tables is part of the installer.

The API login role inherits only `ani_api_runtime`; the Node process does not connect as PostgreSQL superuser. Generated credentials are stored in `server/.env` with mode 600. The API binds to loopback (127.0.0.1) only; use a separately reviewed HTTPS tunnel for remote access.

## Service controls

```bash
sv status postgres
sv status ani-games-ready-api
sv down ani-games-ready-api && sv up ani-games-ready-api
cat "$PREFIX/var/log/sv/ani-games-ready-api/current"
```

Local health endpoint: `http://127.0.0.1:8787/health`

First Owner setup page: `http://127.0.0.1:8787/setup`

Blynk auth token is requested as an optional hidden prompt on first install. On a re-install, existing .env values are kept.

## Start after Android reboot

`termux-services` supervises enabled processes when Termux's service daemon is running. The installer creates `~/.termux/boot/99-ani-games-ready-services`; to start services automatically after Android reboots, separately install the Termux:Boot companion app from the same trusted Termux distribution, open it once, and allow background execution/battery use. Android vendor battery-management policies can still stop background apps; this is not a hardware-level always-on guarantee.

To target a non-default database on a fresh PostgreSQL cluster, set `ANI_DB_NAME` before running the installer. On an existing cluster without `.env`, automatic discovery is allowed only when exactly one database matches the Android rental + device + core Admin signature; multiple or missing matches stop the installer without creating another business database.

## Existing database upgrade

An existing core-only Android DB (migrations `000`–`012`) can be upgraded when its rental, device, session, audit, Admin and runtime-role signatures match. The installer first creates and validates a full database dump plus cluster-role backup, then requires the exact `APPLY` confirmation. Only after approval does it apply additive migrations `013`–`024` in order; core migrations `000`–`012` are never replayed. If `remote_play` exists but required functions/tables are incomplete, or addon tables are partially installed, the installer stops for manual audit rather than guessing.

Backups are stored under `~/ani-games-ready-backups/`. Keep these files private; they contain business data and PostgreSQL role metadata.
