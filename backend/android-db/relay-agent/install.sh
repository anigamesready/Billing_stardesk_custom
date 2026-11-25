#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PREFIX="$(printenv PREFIX || printf '/data/data/com.termux/files/usr')"
HOME="$(printenv HOME || printf '/data/data/com.termux/files/home')"
REF="$(printenv ANI_RELAY_REF || true)"
API_URL="$(printenv ANI_LOCAL_API_URL || printf 'http://127.0.0.1:8788')"
BASE="https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[Ani Relay Agent] %s\n' "$*"; }

[ "$PREFIX" = "/data/data/com.termux/files/usr" ] || die "Jalankan dari Termux Android."
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || die "ANI_RELAY_REF wajib berisi commit SHA 40 karakter, bukan nama branch."
command -v node >/dev/null 2>&1 || die "Node.js belum terpasang."
command -v npm >/dev/null 2>&1 || die "npm belum terpasang."
command -v curl >/dev/null 2>&1 || die "curl belum tersedia."
command -v openssl >/dev/null 2>&1 || die "openssl belum tersedia."
command -v sv >/dev/null 2>&1 || die "termux-services/runit belum tersedia."

NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 20 ] || die "Node.js 20+ diperlukan; versi sekarang $(node --version)."
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*|http://[::1]:*) ;;
  *) die "API harus memakai URL HTTP loopback, bukan alamat publik." ;;
esac
curl --fail --silent --show-error --connect-timeout 3 --max-time 8 "$API_URL/health" >/dev/null \
  || die "API lokal belum merespons di $API_URL/health. API lama dan database tidak diubah."

AGENT_DIR="$HOME/ani-games-ready-relay-agent"
CONFIG_DIR="$HOME/.config/ani-games-relay-agent"
ENV_FILE="$CONFIG_DIR/agent.env"
SERVICE_DIR="$PREFIX/var/service/ani-games-relay-agent"
STAGE_DIR="$HOME/.ani-games-relay-agent-service-staging"

[ ! -e "$SERVICE_DIR" ] || die "Service ani-games-relay-agent sudah ada. Tidak ada file service yang ditimpa."
mkdir -p "$AGENT_DIR" "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

for file in agent.mjs protocol.mjs package.json; do
  curl --fail --silent --show-error --location "$BASE/$REF/backend/android-db/relay-agent/$file" -o "$AGENT_DIR/$file"
  [ -s "$AGENT_DIR/$file" ] || die "Download $file gagal atau kosong."
done
cd "$AGENT_DIR"
npm install --omit=dev --no-audit --no-fund
npm run check

if [ ! -f "$ENV_FILE" ]; then
  SECRET="$(openssl rand -hex 32)"
  cat > "$ENV_FILE" <<EOF
RELAY_SHARED_SECRET=$SECRET
RELAY_WS_URL=wss://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev/agent/connect
ANI_LOCAL_API_URL=$API_URL
EOF
  chmod 600 "$ENV_FILE"
else
  chmod 600 "$ENV_FILE"
  SECRET="$(sed -n 's/^RELAY_SHARED_SECRET=//p' "$ENV_FILE" | tail -n 1)"
  SECRET_LEN="$(printf '%s' "$SECRET" | wc -c | tr -d ' ')"
  [ "$SECRET_LEN" -ge 32 ] || die "agent.env sudah ada tetapi RELAY_SHARED_SECRET tidak valid; file lama dipertahankan."
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/log"
cat > "$STAGE_DIR/run" <<EOF
#!$PREFIX/bin/sh
set -eu
cd "$AGENT_DIR"
set -a
. "$ENV_FILE"
set +a
exec "$PREFIX/bin/node" "$AGENT_DIR/agent.mjs"
EOF
cat > "$STAGE_DIR/log/run" <<EOF
#!$PREFIX/bin/sh
exec "$PREFIX/share/termux-services/svlogger"
EOF
chmod 700 "$STAGE_DIR/run" "$STAGE_DIR/log/run"
touch "$STAGE_DIR/down"
mv "$STAGE_DIR" "$SERVICE_DIR"

log "Agent files installed. Service intentionally remains STOPPED."
log "Existing API and PostgreSQL were not changed."
log "Private configuration: $ENV_FILE"
log "Run this command in Termux to display the secret privately (never send it in chat):"
printf "  sed -n 's/^RELAY_SHARED_SECRET=//p' '%s'\n" "$ENV_FILE"
log "Save that value as Secret RELAY_SHARED_SECRET on Worker ani-games-db-android-stage-ws-relay."
log "After saving the Worker secret, start the agent with:"
printf "  rm -f '%s/down' && sv up ani-games-relay-agent\n" "$SERVICE_DIR"
log "Agent log:"
printf "  tail -n 50 '%s/var/log/sv/ani-games-relay-agent/current'\n" "$PREFIX"
