# Remote — Current Report

Last updated: 2026-11-27  
Status: Tracking snapshot; no Remote source, APK, or live remote session was changed in this task.

## Selected baseline and project direction

- User-selected comparison artifact recorded in the project skill: Ani-Games-Ready-Remote-AndroidDB-Preview-v0.2.0.apk. It is a preview/demo artifact, not production-approved.
- Preserve the StarDesk streaming engine. The custom work is intended to provide Ani Games Ready UI, authentication/authorization, rental/coin integration, and device discovery without casually replacing the remote engine.
- Remote authorization must block expired accounts and accounts with zero usable balance at the connection boundary, not only hide a UI button.
- Main branch was observed at 950c2fc9858bbcec1a2f9696f72634dd000b45e5 before this reporting branch. At the time of this report, repository metadata showed related branches including stardesk-androiddb-preview-v2 and feature/remote-agent-sync-auto-discovery-20261127 (head a329ee67cc433ee830cbef17f3c1cdc7d4957278). Recheck live branch heads before choosing source.

## Partner and coin integration boundary

- Partner attribution belongs to the DB/member-creation and coin-top-up event flow, not to the StarDesk streaming engine.
- The Remote client should not be trusted to calculate or award Partner commission locally.
- If a Remote-originated action can create a member or initiate a coin top-up, the server must identify the authenticated actor and emit the authoritative event. Commission logic must remain centralized and idempotent.
- Do not put Partner commission secrets, Admin credentials, or writable commission percentages in the client APK.

## Known baseline limitations carried forward

The project skill's 2026-11-24 audit described the selected v0.2.0 artifact as a preview with example data, no proven live Android DB integration, no proven live PC/device status, and no verified real StarDesk handoff/session. These findings must be rechecked against newer source/artifacts before making current release claims.

## Work log

### 2026-11-27 — Partner design intake
- Recorded the boundary between Partner/coin logic and the Remote streaming client.
- No Remote source, APK, device test, or remote session was changed or claimed as tested.

Keywords: Remote Android, StarDesk, streaming, remote session, device discovery, coin balance, authorization, expiry, Partner attribution.
