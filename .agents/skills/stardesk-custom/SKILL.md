---
name: stardesk-custom
description: Project-specific instructions for all development, auditing, builds, and database work in Ani Games Ready StarDesk custom. Use whenever working on the Billing_stardesk_custom repository or its Android remote/admin app.
---

# StarDesk Custom — Repository Skill

## 1. Repository authority and source-of-truth

- The ONLY authorized repository and source location for this project is https://github.com/anigamesready/Billing_stardesk_custom
- Repository: `anigamesready/Billing_stardesk_custom`; default branch: `main`.
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

- This is a StarDesk-based remote PC client customized for Ani Games Ready rental users.
- The user explicitly cancelled the dual-database concept. Do not reintroduce DB1/DB2, primary/backup database switching, dual-DB synchronization, or related UI/settings.
- Use the Android DB as the sole database system for this project.
- Remove/avoid legacy dual-DB concepts from the Admin APK UI and related menus so the interface is clean and future updates are not coupled to abandoned architecture.
- Do not add a second database or migration/sync abstraction unless the user explicitly changes this decision.
- Preserve the StarDesk remote/streaming engine. The requested customization is the Ani Games Ready UI, authentication/authorization and rental integration; do not replace or rewrite the StarDesk engine as part of UI work.
- Keep the renter flow self-service: renters can choose an available PC without needing to contact an admin or book through admin chat.
- Block remote access when the rental account has zero balance or is expired. Enforce this at the authorization/connection boundary, not only by hiding or disabling a UI button.

## 5. Approved UI/product requirements from prior discussion

- Accepted visual direction: indigo / blue-purple theme across login, dashboard, PC list, and connection screens.
- Keep the interface compact and easy to use on Android.
- Login: User ID-based login; validate against the existing rental account data.
- Dashboard: show remaining balance/time and account expiry date clearly; provide logout and refresh.
- PC list: show all relevant PCs and their availability/status, with clear states such as READY, ACTIVE, and OFFLINE. A renter can select an available PC directly.
- Connection: launch the existing StarDesk remote flow after authorization and PC selection.
- No admin-chat booking requirement and no separate booking approval flow in the renter path.
- Empty balance and expired account states must show clear reasons and prevent connection.
- Do not invent additional account fields or pricing rules. The earlier discussion indicates existing rental data already contains account/rental information, balance measured in seconds, expiry, device information, and session history; inspect the actual schema/API before implementation.

## 6. StarDesk integration constraints and verification

- The inspected StarDesk 1.6.1 APK was identified as package `com.stardesk`, Android 8+; prior inspection indicated Kotlin/Jetpack Compose and a native streaming engine. Treat these as observations of that artifact, not assumptions about future builds.
- A deep-link pattern was observed: `stardesk://external/device/control?id=...`.
- The exact mapping from Ani Games Ready PC records to StarDesk device IDs, plus the host/client account and authorization handoff, was not yet established/verified in the prior prototype discussion.
- Do not guess the device-ID mapping or claim end-to-end connection works until the mapping and launch behavior are tested on the actual StarDesk client/host setup.
- A prior UI prototype included User ID login, balance/expiry display, READY/ACTIVE/OFFLINE PC states, logout/refresh, and locked states for expired/empty-balance demo accounts. This did not establish that live Supabase/Android DB integration, APK installation, or actual StarDesk streaming connection had passed tests.
- Keep UI prototype status, backend integration status, and real remote-session status as separate verification items.

## 7. UI and functional audit requirements

- Audit the complete user flow, not just the visible screen: startup, configuration, login, navigation, actions, loading, errors, persistence, authorization, connection, and recovery.
- Test that every visible button actually performs its advertised action. A button that merely looks enabled or has no callback is a defect.
- Verify login end-to-end, including validation, request/database call, success state, failure feedback, and navigation.
- Check Android layouts across common screen sizes/densities, scrolling, keyboard visibility, safe areas, and orientation where applicable.
- Check Admin menu content for obsolete dual-DB settings and remove only the abandoned concepts; retain useful working admin features.
- Verify network/database unavailable, timeout, invalid credentials, empty data, expired account, zero balance, unavailable PC, and retry states.
- Do not claim a function is tested unless it was actually exercised or verified from source/test output.

## 8. Database and data integrity

- Treat Android DB as the only authoritative database under the current approved architecture.
- Before changing tables, inspect existing schema, keys, relationships, indexes, constraints, migrations, and all read/write call sites.
- Prepare a table/data inventory before introducing or changing schema.
- Avoid destructive schema changes and data loss. Prefer additive migrations and explicit rollback plans.
- Ensure UI actions are connected to the correct database operations; validate create/read/update/delete and error handling.
- Never invent table names, columns, credentials, endpoints, or production data. Derive them from repository source or explicitly supplied project information.
- Verify balance calculation in seconds, expiry comparison/timezone, session start/stop accounting, and concurrency so two clients cannot bypass account/device restrictions.

## 9. Build and regression verification

- Build from the newest source in this repository.
- Before testing an update, install/replace with the newly built artifact as appropriate; do not accidentally test a stale APK.
- Run available build, lint, unit, integration, and static checks. Record commands and actual results.
- Regression-test app launch, login, dashboard data, Admin navigation, DB connection, PC list refresh/status, access blocking for empty/expired accounts, and the StarDesk handoff/remote session.
- Inspect the produced APK metadata/version/package and verify it corresponds to the current source/build.
- If a build or test cannot be performed in the available environment, state that limitation plainly; do not imply success.
- Provide a concise change summary, exact artifact/repository path, test results, known limitations, and rollback reference.

## 10. Repository state observed on 2026-11-24

Default branch `main`; latest observed commit when this skill was created: `5c2a4e14dbbad696ddd30e348b48c149a8b8f36a` (2026-11-24).
Root contained:
- `StarDesk_1.6.1.apk`
- `AniGames-Admin-Online-V12.1.58-SAFE-TEST.apk`
- `Ani-Games-Ready-Remote-AndroidDB-Preview-v0.2.0.apk`
- `README.md`

These names are observations, not permanent version pins. Always re-check the live repository. At that observed state, the root listing did not expose editable application source; therefore request or add the source project to this repository before attempting source-level changes, detailed code audits, or reproducible builds.

## 11. Communication style and delivery

- Communicate in clear, direct Indonesian unless the user requests another language.
- Be transparent about what was inspected, changed, built, and tested.
- Do not send a build as final merely because compilation succeeded; report functional/regression coverage separately.
- Avoid repeated trial-and-error edits. Audit dependencies and the complete flow first, then implement and verify carefully.
