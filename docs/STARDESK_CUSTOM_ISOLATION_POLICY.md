# StarDesk Custom — Isolation Override

Status: user-approved direction as of 2026-11-26.
Applies only to StarDesk Custom work in this repository and supersedes the contradictory database paragraph in the current main-branch skill when doing this project.

## Non-negotiable isolation boundary

StarDesk Custom is a separate product instance from the existing Ani Games Ready rental-timer installation. The two systems must not share application data, rental records, coin wallets, session records, or mutable runtime state.

- Keep all StarDesk source changes, build workflows, and APK artifacts in `anigamesready/Billing_stardesk_custom`. Never build StarDesk releases from another Ani Games Ready repository.
- Keep the existing Ani Games Ready database, API environment, port 8788, service `ani-games-ready-api`, relay service, relay hub, and their data untouched.
- StarDesk Custom gets a new database (`stardesk_custom_v0`), DB-specific owner/runtime/login roles, local API folder, API port 8789, and runit service (`stardesk-custom-v0-api`).
- A PostgreSQL server process/data cluster may be reused, but the database, ownership, login role, runtime role, schemas, tables, sessions, wallet, and credentials must be separate. Do not grant the StarDesk login membership in the legacy runtime role.
- No automatic import, copy, sync, dual-write, fallback, or table-level sharing between the old rental timer and StarDesk Coin system.
- StarDesk Gateway traffic must use the dedicated `/stardesk` route and the dedicated relay Durable Object hub `redmi-stardesk-custom`; the legacy route/hub remains unchanged.
- The StarDesk Android Admin and Remote APKs use their own package IDs, versioning, build workflows, and artifacts. Do not overwrite or replace existing stable Ani Games APKs.

## Change and deployment discipline

1. Read the complete repository skill from `main` before each StarDesk task. Apply this override when the older single-database paragraph conflicts with the user's 2026-11-26 instruction.
2. Work in a feature branch. No merge to `main`, PR merge, release replacement, Cloudflare deployment, or live DB mutation without the user's explicit approval where required.
3. Make installers first-install-only and fail closed on database, role, folder, service, or port collisions. Never silently drop, rename, truncate, or migrate the legacy database.
4. Verify the target database and effective login role before running any migration. Use a namespaced NOLOGIN runtime role and a dedicated LOGIN role with only the required function grants.
5. Verify the old API/DB/service remain healthy and unchanged after StarDesk setup. Never stop/restart PostgreSQL or the old API as part of StarDesk setup.
6. Building an APK is not proof of live DB integration. Require real device installation, Owner login, UI click-through, CRUD, wallet/top-up/expiry checks, Host enrollment, and a real StarDesk session before labeling a release production-ready.

## Current intended identifiers

| Component | StarDesk Custom |
|---|---|
| Database | `stardesk_custom_v0` |
| Database owner role | `stardesk_v0_owner` |
| API login role | `stardesk_v0_login` |
| API runtime role | `stardesk_v0_runtime` |
| Local API directory | `$HOME/ani-games-stardesk-custom-v0/server` |
| Local API port | `8789` |
| Runit service | `stardesk-custom-v0-api` |
| Relay Agent service | `ani-games-stardesk-relay-agent` |
| Relay hub | `redmi-stardesk-custom` |
| Gateway prefix | `/stardesk` |

These names are project identifiers; confirm they are unused on the target Termux installation before creating them.
