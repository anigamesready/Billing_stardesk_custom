# Ani Games Ready — mandatory source verification and delivery rules

Date recorded: 26 November 2026
Applies to work in `anigamesready/Billing_stardesk_custom` and linked Ani Games Ready projects.

## Source discovery comes first
1. Before asking the user for a ZIP, APK, HTML or source file, search the current authoritative GitHub repository, branches, commits, workflows and artifacts. If the project was installed from GitHub Actions/repository, identify and inspect that exact workflow/source branch yourself.
2. A display name, APK filename, screenshot or prior assistant summary is not proof of source identity. Verify repository path, branch, full commit SHA, package ID, versionCode/versionName, workflow run and artifact provenance.
3. Read the repository's current complete StarDesk skill from `main` and the project-specific docs before every edit. Do not assume an old branch or previous chat summary is current.

## Before changing source
1. Trace the whole affected flow from UI to native bridge, HTTP/Gateway/Relay, Node route, SQL RPC, database permissions and build workflow. Read callers and callees, not just the matching string.
2. Compare current and proposed source. Record every dependent API signature and migration, including existing database upgrade behavior.
3. Make the smallest coherent change in an isolated branch. Preserve stable/master branches and existing user data. Never remove a security check to silence an auth error.
4. For a database change, inspect the live schema/source contract; prepare additive SQL and a rollback/backup plan. Existing database upgrades require a validated backup and explicit approval. Do not apply schema to a live DB from CI.

## Required verification before delivery
1. Run JavaScript syntax checks, SQL migration tests, API/permission tests, gateway/relay tests, build and package identity checks appropriate to the change. Regression-test the existing features touched by that flow.
2. Inspect CI logs after each failed run, fix the actual failing source or test, and rerun. Never stop at the first compile or static-check pass.
3. Verify the exact final branch head SHA is the SHA that built the artifact. Check package ID, version, certificate/signature, file integrity and SHA-256.
4. Do not describe a function as “working/normal/fixed” unless the function was actually exercised end-to-end. A source inspection, static assertion, SQL test on disposable PostgreSQL, or APK build must be labelled as exactly that—not a live-device test.
5. Before a production claim, require a clean install/upgrade on a real Android device, click-through of visible actions, live server/database authentication and read/write tests, offline/error cases, and a real StarDesk host/client session where applicable.
6. If a critical part cannot be exercised because live Redmi/Termux/PC access or relay-agent source is absent, stop short of production delivery. State the exact blocker and provide only a clearly labelled test candidate if that still helps.

## Communication and user handling
- Do not ask the user to upload source that is already available in the connected repository.
- Never ask the user to repeat project details already in the repository/history.
- Keep stable releases separate from test candidates. Do not send a guessed, stale, or unverified APK as a final working build.
- Report exact files, branch, full SHA, tests passed/failed/blocked, untested risks, artifact identity and rollback reference.
- When a user reports a regression, acknowledge it, reproduce from current source, and verify the complete flow before proposing another build.
