#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# StarDesk Custom 031: invite URL encryption, Agent-owned Coin session engine and meter APIs.
# This updater only touches stardesk_custom_v0 / API 8789 / stardesk-custom-v0-api.
APP_DIR="$HOME/ani-games-stardesk-custom-v0"
SERVER_DIR="$APP_DIR/server"
ENV_FILE="$SERVER_DIR/.env"
DB_NAME="stardesk_custom_v0"
DB_PORT="5432"
API_PORT="8789"
DB_OWNER_ROLE="stardesk_v0_owner"
RUNTIME_ROLE="stardesk_v0_runtime"
API_DB_USER="stardesk_v0_login"
SERVICE_NAME="stardesk-custom-v0-api"
SERVICE_DIR="$PREFIX/var/service/$SERVICE_NAME"
PGDATA="$PREFIX/var/lib/postgresql"
[ ! -f "$HOME/.postgres/postgresql.conf" ] || PGDATA="$HOME/.postgres"
OS_DB_USER="$(id -un)"
PG_ADMIN_USER=""
SOURCE_REF="${ANI_STARDESK_SOURCE_REF:-}"

log(){ printf '[STAR-DESK-COIN-031] %s\\n' "$*"; }
die(){ printf '[STAR-DESK-COIN-031] STOP: %s\\n' "$*" >&2; exit 1; }
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

[ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || die "Khusus Termux Android."
[ -r /dev/tty ] || die "Jalankan dari terminal interaktif Termux."
for bin in psql pg_isready node curl tar readlink date sed sv grep chmod find seq sleep; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."
done
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_STARDESK_SOURCE_REF wajib SHA commit 40 karakter."
[ -f "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL Termux existing tidak ditemukan."
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL existing belum siap."
[ -s "$SERVER_DIR/server.mjs" ] && [ -s "$ENV_FILE" ] || die "Installasi StarDesk Custom existing tidak ditemukan."
[ -d "$SERVICE_DIR" ] || die "Service StarDesk Custom khusus tidak ditemukan."

export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log"
"$PREFIX/bin/sv" status "$SERVICE_NAME" 2>&1 | grep -q '^run:' || die "Service $SERVICE_NAME tidak sedang run."
grep -q '^PORT=8789$' "$ENV_FILE" || die "API port bukan 8789."

for candidate in "$OS_DB_USER" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null | grep -qx t; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Superuser PostgreSQL lokal tidak ditemukan."

EXPECTED_PGDATA="$(readlink -f "$PGDATA")"
SERVER_PGDATA="$(psql_admin -d postgres -Atqc "SHOW data_directory")"
ACTUAL_PGDATA="$(readlink -f "$SERVER_PGDATA")"
[ -n "$EXPECTED_PGDATA" ] && [ "$EXPECTED_PGDATA" = "$ACTUAL_PGDATA" ] || die "Cluster aktif bukan PGDATA Termux yang diharapkan."

DB_OWNER="$(psql_admin -d postgres -Atqc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB_NAME'")"
[ "$DB_OWNER" = "$DB_OWNER_ROLE" ] || die "Database bukan milik $DB_OWNER_ROLE."
ROLE_CHECK="$(psql_admin -d postgres -Atqc "SELECT count(*) FROM pg_roles WHERE rolname IN ('$DB_OWNER_ROLE','$RUNTIME_ROLE','$API_DB_USER')")"
[ "$ROLE_CHECK" = "3" ] || die "Role StarDesk Custom tidak lengkap."
META="$(psql_admin -d "$DB_NAME" -Atqc "SELECT schema_version||'|'||runtime_role||'|'||api_login_role FROM private.stardesk_custom_install_meta WHERE singleton")"
case "$META" in
  "androiddb_v0_030_agent_remote_sync|$RUNTIME_ROLE|$API_DB_USER") ;;
  "androiddb_v0_031_stardesk_coin_sessions|$RUNTIME_ROLE|$API_DB_USER")
    die "Migration 031 sudah tercatat; tidak akan menjalankan ulang updater." ;;
  *) die "Metadata bukan baseline 030 yang diharapkan: $META" ;;
esac

KEY_VALUE="$(sed -n 's/^ANI_STARDESK_PAIRING_KEY=//p' "$ENV_FILE" | tail -n 1)"
[ -n "$KEY_VALUE" ] || die "Key AES-256-GCM 030 tidak ada. Jangan membuat key baru karena ciphertext lama mungkin tidak dapat didekripsi."
printf '%s' "$KEY_VALUE" | node -e "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{const b=Buffer.from(s,'base64');process.exit(b.length===32&&b.toString('base64')===s?0:1)})" || die "Key AES-256-GCM existing tidak valid."
unset KEY_VALUE

TMP_DIR="$(mktemp -d "$PREFIX/tmp/stardesk-coin-031.XXXXXX")"
cleanup(){ [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE="$TMP_DIR/source.tar.gz"
log "Mengambil source immutable $SOURCE_REF..."
curl --fail --location --silent --show-error \
  "https://codeload.github.com/anigamesready/Billing_stardesk_custom/tar.gz/$SOURCE_REF" -o "$ARCHIVE"
tar -tzf "$ARCHIVE" >/dev/null
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
SOURCE_ROOT="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
MIGRATION="$SOURCE_ROOT/backend/android-db/migrations/031_stardesk_invite_coin_sessions.sql"
NEW_SERVER="$SOURCE_ROOT/backend/android-db/server/server.mjs"
[ -s "$MIGRATION" ] && [ -s "$NEW_SERVER" ] || die "Migration 031/API source tidak lengkap."
for rpc in androiddb_v0_agent_sync_stardesk_pairing androiddb_v0_agent_ui_monitor_heartbeat androiddb_v0_agent_stardesk_session_event androiddb_v0_agent_stardesk_session_tick androiddb_v0_remote_request_session androiddb_v0_remote_session_status androiddb_v0_remote_dashboard; do
  grep -q "$rpc" "$NEW_SERVER" || die "RPC baru tidak ditemukan: $rpc"
done
node --check "$NEW_SERVER" || die "Syntax API gagal sebelum database diubah."

log "Menerapkan migrasi additive 031 pada $DB_NAME..."
{ printf 'SET ROLE %s;\n' "$DB_OWNER_ROLE"; cat "$MIGRATION"; } | psql_admin -d "$DB_NAME" >/dev/null

BACKUP_DIR="$APP_DIR/backups"
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$SERVER_DIR/server.mjs" "$BACKUP_DIR/server.mjs.before-coin-031.$STAMP"
cp "$NEW_SERVER" "$SERVER_DIR/server.mjs.new"
sed -i \
  -e 's/Ani Games Ready Local Server/StarDesk Custom Local API/g' \
  -e 's/Setup Admin Ani Games Ready/Setup StarDesk Custom Owner/g' \
  -e 's/Database lokal Ani Games Ready. Blynk\\/WoL tidak disentuh./Database khusus StarDesk Custom. Database Ani Games Ready lama tidak disentuh./g' \
  -e 's/ani-games-ready-local-api/stardesk-custom-v0-api/g' \
  "$SERVER_DIR/server.mjs.new"
node --check --input-type=module < "$SERVER_DIR/server.mjs.new" || die "API baru gagal diperiksa; API lama tetap aktif."

mv "$SERVER_DIR/server.mjs.new" "$SERVER_DIR/server.mjs"
log "Restart hanya service $SERVICE_NAME..."
"$PREFIX/bin/sv" restart "$SERVICE_NAME" >/dev/null 2>&1 || true

HEALTH=0
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1 \
    && "$PREFIX/bin/sv" status "$SERVICE_NAME" 2>&1 | grep -q '^run:'; then
    HEALTH=1
    break
  fi
  sleep 1
done

rpc_route_check(){
  local rpc="$1" body="$TMP_DIR/rpc-$rpc.json" status
  status="$(curl --silent --show-error --connect-timeout 2 --max-time 6 \
    -o "$body" -w '%{http_code}' -X POST \
    -H 'content-type: application/json' --data '{}' \
    "http://127.0.0.1:$API_PORT/rest/v1/rpc/$rpc" 2>/dev/null || true)"
  [ "$status" = "401" ] && grep -q 'AUTH_REQUIRED' "$body"
}
if [ "$HEALTH" = "1" ]; then
  for rpc in androiddb_v0_agent_sync_stardesk_pairing androiddb_v0_agent_ui_monitor_heartbeat androiddb_v0_agent_stardesk_session_event androiddb_v0_agent_stardesk_session_tick androiddb_v0_remote_request_session androiddb_v0_remote_dashboard; do
    if ! rpc_route_check "$rpc"; then
      HEALTH=0
      log "RPC $rpc gagal preflight (harus HTTP 401 AUTH_REQUIRED)."
      break
    fi
  done
fi

if [ "$HEALTH" != 1 ]; then
  log "Preflight gagal; memulihkan API server.mjs lama."
  cp "$BACKUP_DIR/server.mjs.before-coin-031.$STAMP" "$SERVER_DIR/server.mjs"
  "$PREFIX/bin/sv" restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  die "API gagal. Migration 031 additive tetap tercatat di database; API lama dipulihkan. Perlu investigasi, jangan menjalankan ulang tanpa audit."
fi

psql_admin -d "$DB_NAME" -v source_ref="$SOURCE_REF" <<SQL >/dev/null
UPDATE private.stardesk_custom_install_meta
SET schema_version='androiddb_v0_031_stardesk_coin_sessions',source_ref=:'source_ref'
WHERE singleton AND runtime_role='$RUNTIME_ROLE' AND api_login_role='$API_DB_USER';
SQL

chmod 600 "$ENV_FILE"
log "Migration 031 + API berhasil diperbarui. Health check dan seluruh RPC protected lolos preflight."
log "Tiga data disimpan terenkripsi; tidak ada perubahan ke Billing legacy, relay, atau database lain."
log "Coin meter memakai tarif PC dan server clock. Agent disconnected lebih dari 45 detik akan mengakhiri sesi setelah grace period dan mencegah tagihan tanpa batas."
