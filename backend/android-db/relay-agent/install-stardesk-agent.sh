#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

PREFIX="$(printenv PREFIX || printf '/data/data/com.termux/files/usr')"
HOME="$(printenv HOME || printf '/data/data/com.termux/files/home')"
REF="$(printenv ANI_RELAY_REF || true)"
API_URL="${ANI_LOCAL_API_URL:-http://127.0.0.1:8789}"
RELAY_URL="wss://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev/agent/connect/stardesk"
BASE="https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom"
SECRET_FILE="${ANI_RELAY_SECRET_FILE:-$HOME/ani-games-db-android-stage/relay-worker-shared-secret.txt}"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log(){ printf '[Ani StarDesk Relay Agent] %s\n' "$*"; }
secret_is_valid(){
  local value="$1" safe
  [ "${#value}" -ge 32 ] && [ "${#value}" -le 512 ] || return 1
  safe="$(LC_ALL=C printf '%s' "$value" | LC_ALL=C tr -cd 'A-Za-z0-9._~+/=-')"
  [ "$safe" = "$value" ]
}

[ "$PREFIX" = "/data/data/com.termux/files/usr" ] || die "Jalankan dari Termux Android."
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || die "ANI_RELAY_REF wajib commit SHA 40 karakter."
for bin in node npm curl sv; do command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."; done
[ -x "$PREFIX/share/termux-services/svlogger" ] || die "svlogger tidak ditemukan."
[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -ge 20 ] || die "Node.js 20+ diperlukan."

CONFIG_DIR="$HOME/.config/ani-games-stardesk-relay-agent"
ENV_FILE="$CONFIG_DIR/agent.env"
SERVICE_NAME="ani-games-stardesk-relay-agent"
SERVICE_DIR="$PREFIX/var/service/$SERVICE_NAME"
AGENT_DIR="$HOME/ani-games-stardesk-relay-agent-$REF"
[ ! -e "$SERVICE_DIR" ] || die "Service $SERVICE_NAME sudah ada; tidak akan menimpa."
[ ! -e "$AGENT_DIR" ] || die "Folder Agent sudah ada; tidak akan menimpa."
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

# Confirm the dedicated local API is healthy before touching relay files.
HEALTH="$(curl --fail --silent --show-error --connect-timeout 3 --max-time 8 "$API_URL/health")" || die "StarDesk API belum merespons di $API_URL/health."
printf '%s' "$HEALTH" | node --input-type=module -e '
let s=""; for await (const x of process.stdin) s+=x;
const d=JSON.parse(s);
if(d.api!=="online"||d.database!=="online") { process.stderr.write("STAR_DESK_API_NOT_HEALTHY\n"); process.exit(1); }
' || die "StarDesk API/database belum healthy."

TMP="$(mktemp -d "$HOME/.ani-stardesk-relay-install.XXXXXX")"
TMP_SERVICE=""
cleanup(){
  [ -z "$TMP" ] || [ ! -d "$TMP" ] || rm -rf -- "$TMP"
  [ -z "$TMP_SERVICE" ] || [ ! -d "$TMP_SERVICE" ] || rm -rf -- "$TMP_SERVICE"
}
trap cleanup EXIT

for file in agent.mjs protocol.mjs package.json protocol.test.mjs; do
  curl --fail --silent --show-error --location "$BASE/$REF/backend/android-db/relay-agent/$file" -o "$TMP/$file"
  [ -s "$TMP/$file" ] || die "Download $file kosong."
done
cd "$TMP"
npm install --omit=dev --no-audit --no-fund
npm run check
npm test

SECRET=""
if [ -f "$ENV_FILE" ]; then
  [ "$(grep -c '^RELAY_SHARED_SECRET=' "$ENV_FILE" || true)" = "1" ] || die "agent.env lama tidak valid."
  SECRET="$(sed -n 's/^RELAY_SHARED_SECRET=//p' "$ENV_FILE")"
elif [ -f "$SECRET_FILE" ]; then
  SECRET="$(tr -d '\r\n' < "$SECRET_FILE")"
elif [ -f "$HOME/.config/ani-games-relay-agent/agent.env" ]; then
  SECRET="$(sed -n 's/^RELAY_SHARED_SECRET=//p' "$HOME/.config/ani-games-relay-agent/agent.env")"
else
  [ -r /dev/tty ] || die "File secret Relay lama tidak ditemukan. Tidak akan membuat/merotasi secret."
  printf 'Masukkan secret lama Relay yang sama (input disembunyikan): ' >/dev/tty
  IFS= read -r -s SECRET </dev/tty || die "Gagal membaca secret Relay."
  printf '\n' >/dev/tty
fi
secret_is_valid "$SECRET" || die "Secret lama tidak valid. Tidak ada secret baru dibuat."

mkdir -p "$AGENT_DIR"
chmod 700 "$AGENT_DIR"
cp "$TMP/agent.mjs" "$TMP/protocol.mjs" "$TMP/package.json" "$TMP/protocol.test.mjs" "$AGENT_DIR/"
cp -R "$TMP/node_modules" "$AGENT_DIR/"
cat > "$ENV_FILE.tmp" <<EOF
RELAY_SHARED_SECRET=$SECRET
ANI_LOCAL_API_URL=$API_URL
RELAY_WS_URL=$RELAY_URL
EOF
chmod 600 "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
unset SECRET

mkdir -p "$PREFIX/var/service"
TMP_SERVICE="$(mktemp -d "$PREFIX/var/service/.ani-stardesk-relay.XXXXXX")"
mkdir -p "$TMP_SERVICE/log"
cat > "$TMP_SERVICE/run" <<EOF
#!$PREFIX/bin/sh
set -eu
cd "$AGENT_DIR"
set -a
. "$ENV_FILE"
set +a
exec "$PREFIX/bin/node" "$AGENT_DIR/agent.mjs"
EOF
cat > "$TMP_SERVICE/log/run" <<EOF
#!$PREFIX/bin/sh
exec "$PREFIX/share/termux-services/svlogger"
EOF
chmod 700 "$TMP_SERVICE/run" "$TMP_SERVICE/log/run"
touch "$TMP_SERVICE/down"
mv "$TMP_SERVICE" "$SERVICE_DIR"
TMP_SERVICE=""

log "Agent StarDesk tersimpan sebagai service terpisah; Agent lama tidak diubah."
log "Secret Relay lama dipakai ulang secara lokal; tidak ada secret Cloudflare dibuat/dirotasi."
log "Menjalankan hanya $SERVICE_NAME..."
rm -f "$SERVICE_DIR/down"
sv up "$SERVICE_NAME" >/dev/null 2>&1 || die "Service baru belum bisa dijalankan; file tetap terpasang pada kondisi aman."
for _ in $(seq 1 20); do
  if sv status "$SERVICE_NAME" 2>&1 | grep -q '^run:'; then
    if grep -q '"event":"connected"' "$PREFIX/var/log/sv/$SERVICE_NAME/current" 2>/dev/null; then break; fi
  fi
  sleep 1
done
sv status "$SERVICE_NAME" || true
log "Log Agent: $PREFIX/var/log/sv/$SERVICE_NAME/current"
log "API target: 127.0.0.1:8789"
log "Relay hub: redmi-stardesk-custom (terpisah dari hub lama)."
