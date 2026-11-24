# Ani Games Ready Remote — StarDesk Client

This isolated branch contains the first Android client build for the StarDesk-based rental launcher.

## Design
- Dark indigo / purple / electric-blue theme.
- Login using Ani Games Ready rental User ID only.
- Rental time and expiry summary.
- Live PC catalogue sourced from Ani Games Ready, not from the StarDesk admin device list.
- PC states: READY, ACTIVE, OFFLINE.
- Expired, disabled, or zero-time rental accounts are allowed to view their status but cannot start a session.
- StarDesk remains the remote streaming engine. The Android shell opens the StarDesk app by deep link when a verified connection mapping is available.

## Stage 1 boundaries
The first APK is a catalogue and rental-access client. Connect actions are intentionally disabled because the current Windows hosts do not yet have verified StarDesk Remote Assist mappings/credentials registered in Ani Games Ready. The app must not fabricate a connection or expose host verification credentials in the PC list response.

Official StarDesk documentation distinguishes Remote Access (same StarDesk account on host and client) from Remote Support (different accounts, host shares Device ID and Verification Code). A client account must be signed into StarDesk to use its engine. See:
- https://www.stardesk.net/id/help/step-2.html
- https://www.stardesk.net/id/help/step-3.html

## Supabase
Production project: `wzkjpycjizexxcxrfdvr` (Billing Ani Games Ready).

Edge Function: `stardesk-client-api`
- `POST /login` — validates rental User ID and creates a 30-day opaque client session.
- `POST /catalog` — validates the session, returns current rental gate and the owner organisation's PC catalogue.
- `POST /logout` — revokes the client session.

Only the public publishable key is embedded in the client. The service-role key stays in the Edge Function environment. Session tokens are stored as SHA-256 hashes in `public.stardesk_client_sessions`, which has RLS enabled and no client-role grants.

The catalogue marks a PC offline if its heartbeat is older than 45 seconds and active if a billing or remote-play session is in progress. Archived duplicate devices are filtered out.

## Build
GitHub Actions builds a debug-signed installable APK on pushes to this branch. Artifact name: `Ani-Games-Ready-Remote-debug`.

## Next stage
1. Provision StarDesk Remote Assist or another supported StarDesk host access method for each PC.
2. Securely map StarDesk Device ID and short-lived/rotating verification data to the Ani Games PC record.
3. Add a server-authorized connect reservation, session heartbeats, time deduction and expiry stop path.
4. Enable the Connect button only after these are verified end-to-end.
