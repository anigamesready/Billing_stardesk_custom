# StarDesk Custom — Windows Agent & StarDesk Pairing Specification

Status: approved product direction for phased implementation; protocol-dependent items remain unverified until tested against the actual Windows Agent and StarDesk host/client.

## Product terminology

### Windows Agent

A lightweight Windows companion service installed on every rentable PC. It is the authoritative identity and control channel for that Windows machine. It starts automatically with Windows, runs in the background without requiring the rental UI to be open, maintains an authenticated connection to StarDesk Custom, reports its own liveness, and receives only explicitly permitted Windows-control or message commands.

The Agent does not require the old PC Billing application and must not depend on its executable, pairing token, heartbeat, timer, or database records.

### StarDesk Device

The actual StarDesk host/device identity that exposes the PC for streaming. It has its own StarDesk Device ID and StarDesk custom pairing code. This is not the Windows Agent ID and must never be inferred from a Windows hostname, IP address, PC Billing client ID, or Agent pairing token.

### AniCoin Remote Session

A renter's authorized connection to a StarDesk Device. The session and Coin billing clock must be based on a verified StarDesk connection/session state, not merely an Agent heartbeat or a running StarDesk process.

## Pairing model: two independent pairings

| Pairing | Purpose | Initiated from | Required identity |
|---|---|---|---|
| Windows Agent pairing | Register and authorize a Windows PC for heartbeat, Windows control and Admin messaging | Windows Agent app | Agent-generated device identity and one-time pairing challenge |
| StarDesk pairing | Link the actual StarDesk streaming host/device for Remote access | Admin Owner / StarDesk pairing panel | StarDesk Device ID plus StarDesk custom code |

The two pairings are linked to one rentable PC record only after each has been verified. A PC can be Agent-paired but not yet StarDesk-paired; it must remain unavailable for Remote until both required states are valid.

## 1. Windows Agent lifecycle

### First-time setup

1. Install the Windows Agent on the target PC.
2. On first launch, the Agent creates a unique Agent Device ID and starts an enrollment request. The Agent UI shows a short-lived pairing challenge and a clear pending state.
3. The pending Agent appears in the Owner Admin under **Agent PC** with device name, generated ID, first-seen time and pending status.
4. Owner confirms the pending Agent in Admin. This approval is required so an unknown PC cannot register itself as a trusted rental machine.
5. The service receives a scoped Agent credential, stores it using Windows DPAPI / Windows Credential Manager, and begins its authenticated heartbeat/command channel.
6. The Agent UI reports **Paired** and **Online** only after the server confirms the credential and receives a valid heartbeat.

The exact enrollment transport, challenge format, token rotation and Windows installation technology are implementation details to be finalized in source and security tests. The pairing interaction is initiated in the Agent app; Owner approval in Admin is the trust checkpoint.

### Background operation

- Install/register the Agent as a Windows Service with automatic startup.
- Run under the least-privileged Windows service identity that still allows the approved controls.
- Reconnect with bounded exponential backoff after network loss.
- Send heartbeat and version/status telemetry to the dedicated Agent API.
- Receive commands from a server-side queue; acknowledge accepted, started, completed, failed or expired states.
- Store no Owner password, renter activation code, StarDesk custom code, or database password in Agent files/logs.
- Support safe update, service recovery, and explicit unpair/revoke flows.
- A stale heartbeat changes Agent status to Offline. Agent process liveness is not proof that StarDesk is connected.

### Windows functions in Admin

The Owner Admin menu **Agent PC** will provide:
- Edit Agent display name (does not change the Agent Device ID or StarDesk Device ID).
- View Agent status, version, last heartbeat and current Windows state where reported.
- Restart Windows.
- Shut down Windows.
- Log off the current Windows user.
- Send a message to the Agent PC.
- Inspect command/message delivery and final acknowledgement.

Dangerous commands require explicit confirmation, are authorized per organization/device, and are written to an audit log. No arbitrary shell/PowerShell command execution is exposed through the Admin UI.

### Agent messaging

Admin sends a bounded text message to the selected Agent Device ID. The Agent receives it through its authenticated command channel, displays it in the Windows notification/message surface, and sends an acknowledgement. Admin must distinguish **queued**, **delivered**, **displayed/acknowledged**, **failed**, and **expired**; it must never claim that a message was shown merely because the server queued it.

## 2. StarDesk pairing and Remote access

### Owner pairing

1. Owner opens **Pairing StarDesk** in Admin.
2. Owner selects the corresponding Agent PC / rentable PC record.
3. Owner enters the actual StarDesk Device ID and its StarDesk custom code.
4. The backend validates the pair against the supported StarDesk host/device pairing interface.
5. After successful validation, the backend stores the sensitive custom code encrypted using a server-side key. It is never returned to ordinary Admin list responses, Remote clients, Agent logs or analytics.
6. Admin shows only non-secret metadata: StarDesk Device ID, linked Agent PC, verification status, last validation time and whether the pairing is enabled.

The Device ID and custom code remain two distinct values. A successful Agent pairing does not create a StarDesk pairing automatically.

### Remote renter experience

- Renter signs into the Ani Games Ready Remote app with the rental User ID and its existing activation flow.
- Remote fetches only StarDesk Devices that are enabled, healthy, available and authorized for that rental.
- When a renter selects a PC, the backend validates the rental account, balance, lot expiry, Agent state, StarDesk pairing and device availability.
- Backend issues a short-lived, one-time connection ticket or other supported StarDesk authorization handoff. Remote does not ask the renter to type the StarDesk custom code again.
- The client uses the verified StarDesk launch/handoff path. Secrets remain server-side; tickets are short-lived and scoped to one renter, one device and one connection attempt.

Do not implement or claim automatic login until the actual StarDesk client/host contract, custom-code meaning, authentication exchange and deep-link parameters have been verified. The observed `stardesk://external/device/control?id=...` pattern is only a launch-path observation; it does not prove that the Device ID alone authorizes a session.

## 3. Linking Agent and StarDesk identities

The backend maintains separate identifiers and states:
- `agent_device_id`: generated identity of the Windows Agent installation.
- `stardesk_device_id`: actual StarDesk host/device identifier.
- `rental_pc_id`: StarDesk Custom's internal rentable-PC record.
- Optional Agent display name and StarDesk display name are separate fields.

A verified link connects the Agent Device ID, StarDesk Device ID and rental PC record. Changing an Agent display name must not rotate StarDesk credentials. Re-pairing StarDesk must not create a new Agent identity.

The new Agent API/schema is independent of `public.devices` rows created by the old PC Billing app. No old PC Billing pairing token, heartbeat, API or timer table is used as a fallback.

## 4. Status model

Admin and Remote must display distinct states instead of a single ambiguous Online/Offline badge:

- **Agent Pending** — Agent enrollment requested, awaiting Owner approval.
- **Agent Paired / Online** — credential is valid and recent Agent heartbeat exists.
- **Agent Offline** — heartbeat stale or connection lost.
- **StarDesk Not Paired** — no verified StarDesk Device ID/custom-code pair.
- **StarDesk Paired** — host identity and custom-code pair were validated.
- **StarDesk Host Unavailable** — pairing exists but host is not accepting sessions.
- **Remote Ready** — rental authorized, active Coin balance exists, Coin lots remain valid, Agent is online, StarDesk host is available, and no conflicting session exists.
- **Remote In Use** — an authenticated StarDesk session is active.
- **Remote Session Ended** — StarDesk confirms the session ended and settlement is complete.

Agent heartbeat alone must never produce Remote Ready or start billing.

## 5. StarDesk-driven session timer and Coin billing

The Coin session state machine must be driven by verified StarDesk session events:
- Create a pending session when Remote requests a connection.
- Do not debit while waiting for host approval, while connecting, or while StarDesk is idle.
- Start the billing clock only when the StarDesk integration confirms the stream/session is connected.
- Pause/stop/settle only from a verified StarDesk session-ended/disconnected event or an authoritative server watchdog after the host has been confirmed unreachable.
- Compute usage from server timestamps, not the Agent's local clock.
- Reserve/debit Coin atomically using the linked PC's GPU rate and FIFO unexpired Coin lots.
- Prevent two concurrent sessions from spending the same wallet balance or renting the same PC.
- Show the renter the current PC, GPU rate, session state, estimated Coin burn and remaining usable balance.
- Record all reserves, debits, expired lots, refunds and settlements in the ledger.

The exact StarDesk connected/disconnected event source and reconnect grace policy must be validated before enabling this timer. A running process, Agent heartbeat or Remote app screen state is not an adequate timer signal.

## 6. Suggested data boundaries

The next schema design should add a dedicated Agent domain under `androiddb_v0`, for example:
- `agent_devices`: Agent identity, display name, org, status, version, heartbeat and revocation.
- `agent_enrollment_requests`: one-time challenge hash, expiry, request metadata and approval state.
- `agent_commands`: approved Windows commands and Admin messages, target Agent, payload, status, expiry and acknowledgement timestamps.
- `stardesk_pairings`: Agent/rental-PC link, StarDesk Device ID, encrypted custom code, validation state, key version and rotation metadata.
- `sessions` / `coin_wallets` / `coin_lots` / `coin_ledger`: authoritative Remote session and Coin accounting records.

Names and column definitions are proposals, not deployed schema. Before creating tables, inspect all current constraints, write paths, uniqueness, row-level access and API privilege boundaries. Do not add a second database.

## 7. Phased delivery plan

1. **Coin x100 denomination** — convert Android DB v0 balances, orders, lots, ledger, session reserves/debits and GPU rates once; update Admin/Remote calculators and labels; test idempotency and unchanged Rupiah values.
2. **Independent Windows Agent foundation** — Agent-generated enrollment challenge, Owner approval, separate Agent identity/token, auto-start Windows Service, heartbeat and safe revocation.
3. **Admin Agent PC controls** — editable Agent display name, restart/shutdown/logoff, message delivery, command acknowledgements and audit trail.
4. **StarDesk pairing** — validate Device ID/custom-code protocol with the real StarDesk host/client, store encrypted custom code server-side, expose only short-lived access tickets to Remote.
5. **StarDesk session lifecycle + Coin settlement** — use verified stream-connected/ended events for the server-side clock, FIFO lot debit and concurrency-safe settlement.
6. **Release gate** — clean install/upgrade on Android and Windows, pair real Agent and StarDesk host, test all controls/messages, test auto-login handoff and complete live Coin start/stop/expiry/settlement, then publish only after evidence is recorded.

## 8. Known verification boundaries

- Current Remote login and Owner Admin login are already implemented in their existing preview apps.
- Current Host Agent registration/heartbeat and StarDesk mapping are still tied to the old `public.devices` / PC Billing record model; this is not the independent Agent model specified above.
- The old Admin's Chat-to-Windows action has no verified receiving handler in the inspected PC source and is intentionally disabled until the new Agent message receiver exists.
- The actual StarDesk custom-code contract, credential exchange, device lookup and session event API have not yet been verified. No fabricated endpoint, code format or success state may be used.
- This specification does not apply a live migration, alter Cloudflare, modify legacy Ani Games Ready services, or replace either existing APK.
