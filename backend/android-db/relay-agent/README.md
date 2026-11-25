# Ani Games Relay Agent — Termux

Cloudflare Gateway and Relay can be online while the Redmi API remains unreachable. The WebSocket Relay requires a persistent agent connection at /agent/connect. This service supplies that connection and forwards only approved API routes to the existing loopback API.

## Safety

- Runs as a separate ani-games-relay-agent Termux service.
- Connects outward to the pinned StarDesk WebSocket Relay Worker over wss://.
- Forwards requests only to a loopback API URL (default http://127.0.0.1:8788).
- Does not expose PostgreSQL or the API to a public interface.
- Does not restart, stop, migrate, or reconfigure PostgreSQL or the existing API.
- Stores its configuration in a separate mode-600 file.
- Installer deliberately prepares the service in a stopped state until the Cloudflare secret is synchronized.

## Install from Termux

Use the exact immutable commit SHA for this release, never a moving branch name:

\`\`\`bash
REF=<40-character-commit-sha>
curl -fsSL "https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$REF/backend/android-db/relay-agent/install.sh" | ANI_RELAY_REF="$REF" bash
\`\`\`

The installer checks Node.js 20+, confirms the existing local API health endpoint, downloads only the Relay Agent files, installs the isolated ws dependency, and prepares a stopped runit service.

If the existing API uses a different loopback port, set ANI_LOCAL_API_URL on the installer and use the same URL on both sides of the pipe.

## Synchronize the secret

Cloudflare Worker secrets are write-only; existing values cannot be read back. On first install, the script generates a new random secret and stores it privately in ~/.config/ani-games-relay-agent/agent.env.

1. In Termux, run the exact sed command printed by the installer. Copy its output privately.
2. In Cloudflare Dashboard, open Workers & Pages → ani-games-db-android-stage-ws-relay → Settings → Variables and Secrets.
3. Set its Secret named RELAY_SHARED_SECRET to that exact value.
4. Open Worker ani-games-db-android-stage-gateway → Settings → Variables and Secrets; set Secret EDGE_PROXY_SECRET to the SAME exact value. Save both Worker changes.
5. Never send the secret in chat, screenshots, or logs.

If the operator already has the matching secret, do not rotate it again.

## Start and verify

After the Worker secret is saved:

\`\`\`bash
rm -f "$PREFIX/var/service/ani-games-relay-agent/down"
sv up ani-games-relay-agent
sv status ani-games-relay-agent
tail -n 50 "$PREFIX/var/log/sv/ani-games-relay-agent/current"
\`\`\`

Then test the public endpoints:

\`\`\`bash
BASE="https://ani-games-db-android-stage-gateway.anigamesready.workers.dev"
curl -i --connect-timeout 10 --max-time 20 "$BASE/_ani_gateway/health"
curl -i --connect-timeout 10 --max-time 20 "$BASE/health"
\`\`\`

Expected gateway health after success: HTTP 200 and gateway: online, relay: online, agent_connected: true, api: online, database: online.

Do not apply a database migration as part of this connectivity repair.

## Stop / logs

\`\`\`bash
sv down ani-games-relay-agent
sv status ani-games-relay-agent
tail -n 100 "$PREFIX/var/log/sv/ani-games-relay-agent/current"
\`\`\`

These commands target only the new Relay Agent. Do not use them on postgres or ani-games-ready-api.

The installer does not edit existing Termux:Boot entries. Add automatic startup separately only after the manual connection test passes.
