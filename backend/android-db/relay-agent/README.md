# Ani Games Relay Agent — Termux

Cloudflare Gateway and Relay can be online while the Redmi API remains unreachable. The WebSocket Relay requires a persistent agent connection at `/agent/connect`. This service supplies that connection and forwards only approved API routes to the existing loopback API.

## Safety

- Runs as a separate `ani-games-relay-agent` Termux service.
- Connects outward to the pinned StarDesk WebSocket Relay Worker over WSS.
- Forwards requests only to a loopback API URL (default `http://127.0.0.1:8788`).
- Does not expose PostgreSQL or the API to a public interface.
- Does not restart, stop, migrate, or reconfigure PostgreSQL or the existing API.
- Stores its configuration in a separate mode-600 file.
- Prepares the new service in a stopped state; it never starts it automatically.
- **Never generates or rotates a Cloudflare secret.** Existing Worker values are reused.

## Install from Termux

Use the exact immutable commit SHA for this release, never a moving branch name:

```bash
REF=<40-character-commit-sha>
curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/relay-agent/install.sh" | ANI_RELAY_REF="$REF" bash
```

The installer checks Node.js 20+, verifies the existing local API health endpoint, downloads all four required source/test files, installs the isolated `ws` dependency, and runs syntax plus protocol tests.

If the existing API uses a different loopback port, set `ANI_LOCAL_API_URL` before running the installer and use the same local URL on the Agent.

## Reuse the existing secret — do not rotate

The relay protocol uses one shared existing value in these three places:

- Relay Worker secret key: `RELAY_SHARED_SECRET`
- Gateway Worker secret key: `EDGE_PROXY_SECRET`
- Termux Agent local config: `RELAY_SHARED_SECRET`

The Gateway forwards its configured `EDGE_PROXY_SECRET` to the Relay, which compares it to `RELAY_SHARED_SECRET`; the Agent also signs its WebSocket token with that same existing value. The two Cloudflare values must therefore already be identical.

Cloudflare Worker secret values are write-only and cannot be fetched back from the Dashboard/API. The installer therefore:

- preserves an existing local `~/.config/ani-games-relay-agent/agent.env` without changing its secret;
- when that local file is absent, asks for the **existing** value through a hidden terminal prompt and stores it with file permission 600;
- refuses to continue if the value is missing/invalid;
- never generates a replacement and never edits either Worker.

Paste the existing value directly into the Termux hidden prompt, not into ChatGPT or a screenshot. If the original value is not available anywhere locally or in your own password manager/notes, stop here; do not rotate either Worker as part of this repair.

## Start and verify

After installation, first confirm in Cloudflare that both existing secret keys are still present and already contain the same original value. Do not edit them.

Then start only the new Agent service:

```bash
sv status ani-games-relay-agent
rm -f "$PREFIX/var/service/ani-games-relay-agent/down"
sv up ani-games-relay-agent
sv status ani-games-relay-agent
tail -n 50 "$PREFIX/var/log/sv/ani-games-relay-agent/current"
```

Test the public endpoints:

```bash
BASE="https://ani-games-db-android-stage-gateway.anigamesready.workers.dev"
curl -i --connect-timeout 10 --max-time 20 "$BASE/_ani_gateway/health"
curl -i --connect-timeout 10 --max-time 20 "$BASE/health"
```

Expected gateway health after success: HTTP 200 and `gateway: online`, `relay: online`, `agent_connected: true`, `api: online`, `database: online`.

Do not apply a database migration as part of this connectivity repair.

## Stop / logs

```bash
sv down ani-games-relay-agent
sv status ani-games-relay-agent
tail -n 100 "$PREFIX/var/log/sv/ani-games-relay-agent/current"
```

These commands target only the new Relay Agent. Do not use them on `postgres` or the existing API service.

The installer does not edit existing Termux:Boot entries. Add automatic startup separately only after the manual connection test passes.
