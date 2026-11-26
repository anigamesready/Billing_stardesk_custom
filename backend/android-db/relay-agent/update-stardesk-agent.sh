#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

PREFIX="$(printenv PREFIX || printf '/data/data/com.termux/files/usr')"
HOME="$(printenv HOME || printf '/data/data/com.termux/files/home')"
REF="$(printenv ANI_RELAY_REF || true)"
BASE="https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom"
API_URL="http://127.0.0.1:8789"
RELAY_URL="wss://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev/agent/connect/stardesk"
CONFIG_DIR="$HOME/.config/ani-games-stardesk-relay-agent"
ENV_FILE="$CONFIG_DIR/agent.env"
SERVICE_NAME="ani-games-stardesk-relay-agent"
SERVICE_DIR="$PREFIX/var/service/$SERVICE_NAME"
LOG_FILE="$PREFIX/var/log/sv/$SERVICE_NAME/current"
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log(){ printf '[Ani StarDesk Relay Agent Update] %s\n' "$*"; }

[ "$PREFIX" = "/data/data/com.termux/files/usr" ] || die "Jalankan dari Termux Android."
[[ "$REF" =~ ^[0-9a-f]{40}$ ]] || die "ANI_RELAY_REF wajib SHA commit 40 karakter."
for bin in node npm curl sv; do command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."; done
[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -ge 20 ] || die "Node.js 20+ diperlukan."
[ -d "$SERVICE_DIR" ] && [ -x "$SERVICE_DIR/run" ] || die "Service StarDesk Relay Agent belum ditemukan."
[ -f "$ENV_FILE" ] || die "Konfigurasi Agent tidak ditemukan."
[ "$(grep -c '^RELAY_SHARED_SECRET=' "$ENV_FILE" || true)" = "1" ] || die "Baris secret Relay tidak valid; tidak ada secret yang ditampilkan."
grep -Fxq "ANI_LOCAL_API_URL=$API_URL" "$ENV_FILE" || die "Agent tidak mengarah ke API StarDesk khusus."
grep -Fxq "RELAY_WS_URL=$RELAY_URL" "$ENV_FILE" || die "Agent tidak mengarah ke Relay hub StarDesk khusus."
grep -Fq '. "'$ENV_FILE'"' "$SERVICE_DIR/run" || die "Service tidak memakai konfigurasi Agent StarDesk yang diharapkan."

CURRENT_AGENT_DIR="$(sed -n 's/^cd "\(.*\)"$/\1/p' "$SERVICE_DIR/run" | head -n 1)"
case "$CURRENT_AGENT_DIR" in
  "$HOME"/ani-games-stardesk-relay-agent-*) ;;
  *) die "Target folder service tidak cocok; update dibatalkan." ;;
esac
[ -s "$CURRENT_AGENT_DIR/agent.mjs" ] && [ -d "$CURRENT_AGENT_DIR/node_modules/ws" ] || die "Instalasi Agent saat ini tidak lengkap."
[ -d "$CONFIG_DIR" ] || die "Folder konfigurasi tidak ditemukan."

HEALTH="$(curl --fail --silent --show-error --connect-timeout 3 --max-time 8 "$API_URL/health")" || die "API StarDesk 8789 tidak merespons."
printf '%s' "$HEALTH" | node --input-type=module -e '
let s=""; for await (const x of process.stdin) s+=x;
const d=JSON.parse(s);
if(d.api!=="online"||d.database!=="online") { process.stderr.write("STAR_DESK_API_NOT_HEALTHY\n"); process.exit(1); }
' || die "API/database StarDesk belum healthy."

TMP="$(mktemp -d "$HOME/.ani-stardesk-relay-update.XXXXXX")"
NEW_AGENT_DIR="$HOME/ani-games-stardesk-relay-agent-$REF"
BACKUP_RUN="$CONFIG_DIR/run.backup.$(date +%Y%m%d%H%M%S)"
LOG_OFFSET=0
cleanup(){ [ ! -d "$TMP" ] || rm -rf -- "$TMP"; }
trap cleanup EXIT
[ ! -e "$NEW_AGENT_DIR" ] || die "Folder versi target sudah ada; tidak akan ditimpa."

for file in agent.mjs protocol.mjs reconnect.mjs package.json protocol.test.mjs; do
  curl --fail --silent --show-error --location "$BASE/$REF/backend/android-db/relay-agent/$file" -o "$TMP/$file"
  [ -s "$TMP/$file" ] || die "Download $file kosong."
done
cd "$TMP"
npm install --omit=dev --no-audit --no-fund
npm run check
npm test

mkdir -m 700 "$NEW_AGENT_DIR"
cp "$TMP/agent.mjs" "$TMP/protocol.mjs" "$TMP/reconnect.mjs" "$TMP/package.json" "$TMP/protocol.test.mjs" "$NEW_AGENT_DIR/"
cp -R "$TMP/node_modules" "$NEW_AGENT_DIR/"
chmod -R go-rwx "$NEW_AGENT_DIR"

# Prepare the replacement before taking the dedicated service offline.
NEW_RUN="$SERVICE_DIR/run.new"
cat > "$NEW_RUN" <<EOF
#!$PREFIX/bin/sh
set -eu
cd "$NEW_AGENT_DIR"
set -a
. "$ENV_FILE"
set +a
exec "$PREFIX/bin/node" "$NEW_AGENT_DIR/agent.mjs"
EOF
chmod 700 "$NEW_RUN"
cp -p "$SERVICE_DIR/run" "$BACKUP_RUN"
if [ -f "$LOG_FILE" ]; then LOG_OFFSET="$(wc -c < "$LOG_FILE" | tr -d ' ')"; fi

log "Pembaruan lolos syntax dan seluruh tes protokol; menghentikan hanya $SERVICE_NAME."
sv down "$SERVICE_NAME" >/dev/null 2>&1 || die "Service StarDesk Relay tidak bisa dihentikan dengan aman; source lama dipertahankan."
DOWN_OK=0
for _ in $(seq 1 15); do
  if sv status "$SERVICE_NAME" 2>&1 | grep -q '^down:'; then DOWN_OK=1; break; fi
  sleep 1
done
[ "$DOWN_OK" = "1" ] || die "Service StarDesk belum berstatus down; file run lama tetap tersedia di backup."

mv -f "$NEW_RUN" "$SERVICE_DIR/run"
rm -f "$SERVICE_DIR/down"
if ! sv up "$SERVICE_NAME" >/dev/null 2>&1; then
  log "Start Agent baru gagal; mengembalikan run script sebelumnya."
  sv down "$SERVICE_NAME" >/dev/null 2>&1 || true
  cp -p "$BACKUP_RUN" "$SERVICE_DIR/run.rollback"
  mv -f "$SERVICE_DIR/run.rollback" "$SERVICE_DIR/run"
  rm -f "$SERVICE_DIR/down"
  sv up "$SERVICE_NAME" >/dev/null 2>&1 || true
  die "Update dibatalkan dan run script lama dipulihkan. Periksa status service."
fi

RUN_OK=0
for _ in $(seq 1 20); do
  if sv status "$SERVICE_NAME" 2>&1 | grep -q '^run:'; then RUN_OK=1; break; fi
  sleep 1
done
if [ "$RUN_OK" != "1" ]; then
  log "Agent baru tidak bertahan hidup; rollback run script."
  sv down "$SERVICE_NAME" >/dev/null 2>&1 || true
  cp -p "$BACKUP_RUN" "$SERVICE_DIR/run.rollback"
  mv -f "$SERVICE_DIR/run.rollback" "$SERVICE_DIR/run"
  rm -f "$SERVICE_DIR/down"
  sv up "$SERVICE_NAME" >/dev/null 2>&1 || true
  die "Update di-rollback; service lama dicoba dijalankan kembali."
fi

log "Agent StarDesk diperbarui. Folder versi lama dan backup run disimpan untuk rollback."
log "Status service:"
sv status "$SERVICE_NAME" || true
if [ -f "$LOG_FILE" ]; then
  log "Log terbaru (tanpa konfigurasi/secret):"
  tail -n 12 "$LOG_FILE"
fi
log "Verifikasi koneksi dilakukan lewat endpoint Relay health setelah service stabil."
