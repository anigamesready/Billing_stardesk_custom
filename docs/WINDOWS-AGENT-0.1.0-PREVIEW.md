# Ani Games Ready — StarDesk Windows Agent 0.1.0 Preview

## Scope

The Agent is a separate Windows Service plus system-tray UI. Its identity, enrollment, heartbeat and command queue use the isolated androiddb_v0 schema inside the dedicated stardesk_custom_v0 database. Agent PCs are stored in androiddb_v0.rental_pcs; this model does not reuse the legacy PC Billing public.devices table, rental timer, or legacy sessions.

## Pairing

1. The Windows service generates a device UUID, secret token and 8-digit one-time pairing code.
2. The secret token is protected with Windows DPAPI in the LocalSystem service profile. Only its hash is sent to the API.
3. Owner enters the code in Admin Android DB v0 > Agent PC, assigns the display name and GPU class, then approves pairing.
4. The Agent confirms pairing on its next heartbeat. The pairing token never appears in the Admin UI.

## Agent PC commands

The API accepts only message, logoff, restart, and shutdown. The Windows service executes fixed Windows binaries / WTS APIs, not arbitrary shell or PowerShell text. Restart and shutdown use a 10-second grace period and do not pass /f. Logoff calls WTSLogoffSession without force.

For message, msg.exe acceptance is recorded. Actual display to a user cannot be proven by the service, so the UI reports that limitation.

## AniCoin display

- GTX 1050: Rp6,000 / hour, 4,500 stored units = 45 AniCoin
- GTX 1660: Rp6,000 / hour, 4,500 stored units = 45 AniCoin
- RTX 3060: Rp7,000 / hour, 5,250 stored units = 52.5 AniCoin
- RTX 5060: Rp8,000 / hour, 6,000 stored units = 60 AniCoin

No Coin reservation, debit, refund, or settlement is implemented by the Windows Agent heartbeat or commands.

## Important limits

Agent ONLINE means only that its own heartbeat is recent. It does not mean StarDesk host streaming is paired or ready. No StarDesk Device ID discovery, private protocol, auto-login, remote stream start/stop, or real session connected/disconnected callbacks are implemented in this preview. Remote readiness and Coin charging therefore remain disabled.

This source does not modify the existing Ani Games Ready PC Billing app, timer schema, legacy API, or vendor StarDesk 1.6.0 installer. The uploaded vendor installer is a separate binary and was not used as editable source.

## Build

The build-stardesk-agent-preview.yml GitHub Actions workflow builds:
- A self-contained Windows x64 ZIP bundle containing the Service, tray UI, install/uninstall scripts and README.
- The isolated Admin Android DB v0 preview APK version 0.2.7 with Agent PC controls.

Install only on a spare/test PC first. Test pairing and non-disruptive message commands before trying Logoff, Restart or Shutdown.
