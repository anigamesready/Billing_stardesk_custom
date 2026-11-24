---
name: stardesk-custom
description: Project-specific instructions for all development, auditing, builds, and database work in Ani Games Ready StarDesk custom. Use whenever working on the Billing_stardesk_custom repository or its Android remote/admin app.
---

# StarDesk Custom — Repository Skill

## 1. Repository authority and source-of-truth

- The ONLY authorized repository and source location for this project is https://github.com/anigamesready/Billing_stardesk_custom
- Repository: `anigamesready/Billing_stardesk_custom`
- Default branch: `main`
- Before every task, inspect the latest repository state, default branch, recent commits, and relevant files.
- Use only files from this repository for StarDesk custom work. Never borrow, merge, or substitute source, APKs, configuration, database definitions, or assets from another Ani Games Ready repository or unrelated project.
- If the required source file is not present in this repository, do not silently use another repository. Explain what is missing and request/add the correct source to this repository.
- A binary APK is a build artifact, not a substitute for the original editable project source. Do not claim a full source audit or make source-level fixes from an APK alone.

## 2. Mandatory workflow before editing

1. Inspect the whole relevant project structure and current working flow before changing anything.
2. Identify dependencies, entry points, data flow, API contracts, database schema, permissions, and possible command/function conflicts.
3. Read existing implementation and tests before proposing changes.
4. Make the smallest change that satisfies the request. Preserve working behavior and existing stable functionality.
5. If requirements conflict or are ambiguous, consult the project history and ask one focused clarification rather than guessing.
6. Keep unrelated changes out of the patch.

## 3. Branching and preservation

- Never overwrite or damage the stable/master baseline as a shortcut.
- Make substantial or risky work in a separate feature branch or isolated folder/build.
- Preserve the previous known-good APK/build as a rollback point.
- Do not replace a stable artifact until the candidate has passed the relevant checks and the user has approved deployment/replacement.
- Use the newest commit and artifacts in this repository, never an older guessed build or artifact from another project.

## 4. Current product direction and explicit architecture decisions

- The StarDesk custom project is a distinct Ani Games Ready remote application/customization effort.
- The user explicitly cancelled the dual-database concept. Do not reintroduce DB1/DB2, primary/backup database switching, dual-DB synchronization, or related UI/settings.
- Use the Android DB as the sole database system for this project.
- Remove/avoid legacy dual-DB concepts from the Admin APK UI and related menus so the interface is clean and future updates are not coupled to abandoned architecture.
- Do not add a second database or migration/sync abstraction unless the user explicitly changes this decision.
- Keep the StarDesk base application and Ani Games Ready custom functionality clearly separated where needed; do not break the underlying remote-control workflow while customizing the app.

## 5. UI and functional audit requirements

- Audit the complete user flow, not just the visible screen: startup, configuration, login, navigation, actions, loading, errors, persistence, and recovery.
- Test that every visible button actually performs its advertised action. A button that merely looks enabled or has no callback is a defect.
- Verify login end-to-end, including validation, request/database call, success state, failure feedback, and navigation.
- Check Android layouts across common screen sizes/densities, scrolling, keyboard visibility, safe areas, and orientation where applicable.
- Check Admin menu content for obsolete dual-DB settings and remove only the abandoned concepts; retain useful working admin features.
- Verify network/database unavailable, timeout, invalid credentials, empty data, and retry states.
- Do not claim a function is tested unless it was actually exercised or verified from source/test output.

## 6. Database and data integrity

- Treat Android DB as the only authoritative database under the current approved architecture.
- Before changing tables, inspect existing schema, keys, relationships, indexes, constraints, migrations, and all read/write call sites.
- Prepare a table/data inventory before introducing or changing schema.
- Avoid destructive schema changes and data loss. Prefer additive migrations and explicit rollback plans.
- Ensure UI actions are connected to the correct database operations; validate create/read/update/delete and error handling.
- Never invent table names, columns, credentials, endpoints, or production data. Derive them from repository source or explicitly supplied project information.

## 7. Build and regression verification

- Build from the newest source in this repository.
- Before testing an update, install/replace with the newly built artifact as appropriate; do not accidentally test a stale APK.
- Run available build, lint, unit, integration, and static checks. Record commands and actual results.
- Regression-test previously working flows alongside the new feature, especially app launch, login, Admin navigation, DB connection, and remote session basics.
- Inspect the produced APK metadata/version/package and verify it corresponds to the current source/build.
- If a build or test cannot be performed in the available environment, state that limitation plainly; do not imply success.
- Provide a concise change summary, exact artifact/repository path, test results, known limitations, and rollback reference.

## 8. Repository state observed on 2026-11-24

Default branch `main`; recent commit at the time of skill creation: `5c2a4e14dbbad696ddd30e348b48c149a8b8f36a` (2026-11-24).
Root currently contains these uploaded artifacts:
- `StarDesk_1.6.1.apk`
- `AniGames-Admin-Online-V12.1.58-SAFE-TEST.apk`
- `Ani-Games-Ready-Remote-AndroidDB-Preview-v0.2.0.apk`
- `README.md`

These names are an observation, not a permanent version pin. Always re-check the live repository. At this observed state, the root listing does not expose editable application source; therefore request or add the source project to this repository before attempting source-level changes, detailed code audits, or reproducible builds.

## 9. Communication style and delivery

- Communicate in clear, direct Indonesian unless the user requests another language.
- Be transparent about what was inspected, changed, built, and tested.
- Do not send a build as final merely because compilation succeeded; report functional/regression coverage separately.
- Avoid repeated trial-and-error edits. Audit dependencies and the complete flow first, then implement and verify carefully.
