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
- A new empty database receives the ordered migrations `000`, `002`–`022`. The historical catalog snapshot `001` is never replayed.
- An existing database must already have the core tables and Remote Play migrations `013`–`019). The installer refuses to guess or replay these core/settlement functions.
- When the existing DB needs coin/WoL addon migrations, it first creates a custom-format `pg_dump`, backs up cluster roles, verifies the dump with `pg_restore --list`, records SHA-256 checksums, and then asks for the exact confirmation word `APPLY`.
- Migration `022` uses a locked scale registry. Version-1 coin balances, lots, orders, ledger quantities, and PC rates are multiplied by 100 once. Reruns at scale 100 do not multiply again. Rupiah values, rental seconds, and rental status are not scaled.
- No `DROP`, `TRUNCATE`, or destructive replacement of core rental/device tables is part of the installer.

The API login role inherits only `ani_api_runtime`; the Node process does not connect as PostgreSQL superuser. Generated credentials are stored in `server/.env` with mode 600. The API binds to loopback (127.0.0.1) only; use a separately reviewed HTTPS tunnel for remote access.

## Service controls

```bash
sv status postgres
sv status ani-games-ready-api
sv restart ani-games-ready-api
cat "$PREFIX/var/log/sv/ani-games-ready-api/current"
```

Local health endpoint: `http://127.0.0.1:8787/health`

First Owner setup page: `http://127.0.0.1:8787/setup`

Blynk auth token is requested as an optional hidden prompt on first install. On a re-install, existing .env values are kept.

## Start after Android reboot

`termux-services` supervises enabled processes when Termux's service daemon is running. The installer creates `~/.termux/boot/99-ani-games-ready-services`; to start services automatically after Android reboots, separately install the Termux:Boot companion app from the same trusted Termux distribution, open it once, and allow background execution/battery use. Android vendor battery-management policies can still stop background apps; this is not a hardware-level always-on guarantee.

## Existing database limitation

An existing core DB that has not yet received Remote Play schema `013`–`019` is intentionally not upgraded automatically. The installer stops before any schema write so that the exact live schema can be audited and backed up first. It does not apply the full clean-install migration chain to an existing business database.

Backups are stored under `~/ani-games-ready-backups/`. Keep these files private; they contain business data and PostgreSQL role metadata.
