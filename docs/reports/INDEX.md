# Ani Games Ready — Project Reports Index

Last updated: 2026-11-27  
Repository: https://github.com/anigamesready/Billing_stardesk_custom  
Branch for this documentation update: docs/partner-commission-and-project-reports-20261127

## How to use this index

Before starting work on a subsystem:
1. Read this index.
2. Open the matching CURRENT.md report below.
3. Re-check the live repository, current branch heads, and the project skill at .agents/skills/stardesk-custom/SKILL.md.
4. Audit source files, schemas, entry points, API contracts, and tests before editing.
5. After work, update only the relevant subsystem report and add a dated note describing decisions, changed files, test evidence, blockers, and next steps.

Keep reports separate. Do not mix database, Admin, Remote, Reseller, or Partner details into one unsearchable running note. Use clear headings and searchable keywords. Preserve previous dated entries when updating a report.

## Subsystem index

| Subsystem | Current report | Scope / keywords |
|---|---|---|
| Database | [DB/CURRENT.md](DB/CURRENT.md) | Android DB, schema, migrations, indexes, coin ledger, attribution, data integrity |
| Admin | [ADMIN/CURRENT.md](ADMIN/CURRENT.md) | Admin APK, dashboard, partner management, settings, payout approvals |
| Remote | [REMOTE/CURRENT.md](REMOTE/CURRENT.md) | StarDesk Android client, PC discovery, remote session, authentication, coin balance |
| Reseller | [RESELLER/CURRENT.md](RESELLER/CURRENT.md) | Reseller app, reseller account, inventory/coin stock, sales margin, member creation |
| Partner | [PARTNER/CURRENT.md](PARTNER/CURRENT.md) | Partner portal, partner login, partner code, member attribution, commission tiers, withdrawal |

## Reporting standard

Every subsystem report must record:
- Current baseline source/artifact and exact branch/commit where known.
- Confirmed decisions separately from proposals and unresolved questions.
- Changes made, exact paths, and dates.
- Tests actually performed and their outcomes. Never mark untested work as passed.
- Known risks, blockers, and next action.
- Keywords to support repository search.

## Initial reporting snapshot — 2026-11-27

This documentation-only update does not modify application source, database schema, APKs, Admin, Remote, or Reseller functionality. The Partner work is a design and HTML UX prototype only. The main branch head observed before this documentation branch was 950c2fc9858bbcec1a2f9696f72634dd000b45e5. The mandatory StarDesk skill was re-read from main before this task.
