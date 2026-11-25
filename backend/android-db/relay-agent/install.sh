#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PREFIX="$(printenv PREFIX || printf '/data/data/com.termux/files/usr')"
HOME="$(printenv HOME || printf '/data/data/com.termux/files/home')"
REF="$(printenv ANI_RELAY_REF || true)"
API_URL="${ANI_LOCAL_API_URL:-}"
BASE="https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[Ani Relay Agent] %s\n' "$*"; }

[ "$PREFIX" = "/data/data/com.termux/files/usr" ] || die "Jalankan dari Termux Android."
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || die "ANI_RELAY_REF wajib berisi commit SHA 40 karakter, bukan nama branch."
command -v node >/dev/null 2>&1 || die "Node.js belum terpasang."
command -v npm >/dev/null 2>&1 || die "npm belum terpasang."
command -v curl >/dev/null 2>&1 || die "curl belum tersedia."
command -v sv >/dev/null 2>&1 || die "termux-services/runit belum tersedia."

NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 20 ] || die "Node.js 20+ diperlukan; versi sekarang $(node --version)."

CONFIG_DIR="$HOME/.config/ani-games-relay-agent"
ENV_FILE="$CONFIG_DIR/agent.env"
SERVICE_DIR="$PREFIX/var/service/ani-games-relay-agent"
AGENT_DIR="$HOME/ani-games-ready-relay-agent-$REF"
SVLOGGER="$PREFIX/share/termux-services/svlogger"

[ ! -e "$SERVICE_DIR" ] || die "Service ani-games-relay-agent sudah ada. Tidak ada file service yang ditimpa."
[ ! -e "$AGENT_DIR" ] || die "Folder versi Agent sudah ada: $AGENT_DIR. Tidak ada file yang ditimpa."
[ -x "$SVLOGGER" ] || die "svlogger tidak ditemukan. Pastikan paket termux-services terpasang."

if [ -z "$API_URL" ] && [ -f "$ENV_FILE" ]; then
  API_URL="$(sed -n 's/^ANI_LOCAL_API_URL=//p' "$ENV_FILE" | tail -n 1)"
fi
API_URL="${API_URL:-http://127.0.0.1:8788}"
case "$API_URL" in
  http://127.0.0.1:*|http://localhost:*|http://[::1]:*) ;;
  *) die "API harus memakai URL HTTP loopback, bukan alamat publik." ;;
esac
curl --fail --silent --show-error --connect-timeout 3 --max-time 8 "$API_URL/health" >/dev/null \
  || die "API lokal belum merespons di $API_URL/health. API lama dan database tidak diubah."

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

TMP_AGENT="$(mktemp -d "$HOME/.ani-games-relay-agent-install.XXXXXX")"
TMP_SERVICE=""
cleanup() {
  [ -z "$TMP_AGENT" ] || [ ! -d "$TMP_AGENT" ] || rm -rf -- "$TMP_AGENT"
  [ -z "$TMP_SERVICE" ] || [ ! -d "$TMP_SERVICE" ] || rm -rf -- "$TMP_SERVICE"
}
trap cleanup EXIT

for file in agent.mjs protocol.mjs package.json protocol.test.mjs; do
  curl --fail --silent --show-error --location "$BASE/$REF/backend/android-db/relay-agent/$file" -o "$TMP_AGENT/$file"
  [ -s "$TMP_AGENT/$file" ] || die "Download $file gagal atau kosong."
done

cd "$TMP_AGENT"
npm install --omit=dev --no-audit --no-fund
npm run check
npm test

# Keep the existing secret. If no local configuration exists, ask for the exact
# already-configured Worker secret without echoing it. Never generate/rotate one.
if [ -f "$ENV_FILE" ]; then
  SECRET_COUNT="$(grep -c '^RELAY_SHARED_SECRET=' "$ENV_FILE" || true)"
  [ "$SECRET_COUNT" = "1" ] || die "agent.env ada tetapi harus berisi tepat satu RELAY_SHARED_SECRET. File lama dipertahankan."
  SECRET="$(sed -n 's/^RELAY_SHARED_SECRET=//p' "$ENV_FILE")"
elif [ -n "${ANI_RELAY_SECRET_FILE:-}" ]; then
  SECRET_FILE="$ANI_RELAY_SECRET_FILE"
  [ -f "$SECRET_FILE" ] && [ -r "$SECRET_FILE" ] || die "ANI_RELAY_SECRET_FILE tidak ditemukan atau tidak dapat dibaca."
  case "$SECRET_FILE" in
    "$HOME"/*) ;;
    *) die "File secret harus berada di dalam direktori HOME Termux." ;;
  esac
  SECRET="$(tr -d '\r\n' < "$SECRET_FILE")"
  [ -n "$SECRET" ] || die "File secret kosong. Tidak ada konfigurasi yang dibuat."
else
  [ -r /dev/tty ] || die "Tidak ada agent.env/ANI_RELAY_SECRET_FILE dan sesi bukan terminal interaktif. Jalankan installer langsung dari Termux."
  printf '\nSecret lama yang SAMA dengan nilai pada Relay Worker dan Gateway Worker diperlukan.\n' >/dev/tty
  printf 'Masukkan nilai secret lama (input disembunyikan): ' >/dev/tty
  IFS= read -r -s SECRET </dev/tty || die "Gagal membaca secret dari terminal."
  printf '\n' >/dev/tty
fi

[ "${#SECRET}" -ge 32 ] || die "Secret kosong/terlalu pendek. Tidak ada secret baru yang dibuat."
[[ "$SECRET" =~ ^[A-Za-z0-9._~+/=-]{32,512}$ ]] || die "Format secret tidak didukung. Gunakan nilai secret lama yang aman untuk file env (32-512 karakter)."

if [ ! -f "$ENV_FILE" ]; then
  ENV_TMP="$CONFIG_DIR/.agent.env.$$"
  ( umask 077; printf 'RELAY_SHARED_SECRET=%s\nANI_LOCAL_API_URL=%s\nRELAY_WS_URL=wss://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev/agent/connect\n' "$SECRET" "$API_URL" > "$ENV_TMP" )
  chmod 600 "$ENV_TMP"
  if [ -e "$ENV_FILE" ]; then
    rm -f -- "$ENV_TMP"
    die "agent.env muncul saat proses berjalan. Tidak ada file konfigurasi yang ditimpa."
  fi
  mv "$ENV_TMP" "$ENV_FILE"
else
  chmod 600 "$ENV_FILE"
fi
unset SECRET

mv "$TMP_AGENT" "$AGENT_DIR"
TMP_AGENT=""

mkdir -p "$PREFIX/var/service"
TMP_SERVICE="$(mktemp -d "$PREFIX/var/service/.ani-games-relay-agent-stage.XXXXXX")"
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
exec "$SVLOGGER"
EOF
chmod 700 "$TMP_SERVICE/run" "$TMP_SERVICE/log/run"
touch "$TMP_SERVICE/down"
mv "$TMP_SERVICE" "$SERVICE_DIR"
TMP_SERVICE=""

log "Agent files installed and syntax/protocol tests passed."
log "Service prepared in STOPPED state; it has NOT been started."
log "Existing local agent.env was preserved; no new secret was generated."
log "Cloudflare Worker secrets were not changed."
log "Existing API and PostgreSQL were not stopped, restarted, migrated, or reconfigured."
log "Start only after verifying the existing secret values match on both Workers:"
printf '  rm -f "%s/down" && sv up ani-games-relay-agent\n' "$SERVICE_DIR"
log "Check service:"
printf '  sv status ani-games-relay-agent\n'
log "Agent log:"
printf '  tail -n 50 "%s/var/log/sv/ani-games-relay-agent/current"\n' "$PREFIX"
