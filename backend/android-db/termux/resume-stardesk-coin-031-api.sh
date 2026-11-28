#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# Resume ONLY the API deployment after migration 031 already ran.
# Never executes SQL migration files.
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
SOURCE_REF="${ANI_STARDESK_SOURCE_REF:-2c888125835d138564cf7c460ee05a2c4f4946b4}"
OS_DB_USER="$(id -un)"
PG_ADMIN_USER=""

log(){ printf '[STAR-DESK-COIN-031-API-RESUME] %s\n' "$*"; }
die(){ printf '[STAR-DESK-COIN-031-API-RESUME] STOP: %s\n' "$*" >&2; exit 1; }
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

[ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || die "Khusus Termux Android."
[ -r /dev/tty ] || die "Jalankan dari terminal interaktif Termux."
for bin in psql node curl tar readlink date sv grep chmod find seq sleep cp mv mktemp; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."
done
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "SOURCE_REF harus SHA 40 karakter."
[ -f "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL Termux tidak ditemukan."
[ -s "$SERVER_DIR/server.mjs" ] && [ -s "$ENV_FILE" ] || die "API StarDesk existing tidak ditemukan."
[ -d "$SERVICE_DIR" ] || die "Service StarDesk Custom tidak ditemukan."
grep -q '^PORT=8789$' "$ENV_FILE" || die "API bukan port 8789."

export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log"
"$PREFIX/bin/sv" status "$SERVICE_NAME" 2>&1 | grep -q '^run:' || die "Service StarDesk harus sedang run sebelum recovery."

for candidate in "$OS_DB_USER" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null | grep -qx t; then
    PG_ADMIN_USER="$candidate"; break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Superuser PostgreSQL lokal tidak ditemukan."
EXPECTED_PGDATA="$(readlink -f "$PGDATA")"
SERVER_PGDATA="$(psql_admin -d postgres -Atqc "SHOW data_directory")"
ACTUAL_PGDATA="$(readlink -f "$SERVER_PGDATA")"
[ "$EXPECTED_PGDATA" = "$ACTUAL_PGDATA" ] || die "Cluster PostgreSQL aktif tidak cocok."

DB_OWNER="$(psql_admin -d postgres -Atqc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB_NAME'")"
[ "$DB_OWNER" = "$DB_OWNER_ROLE" ] || die "Database owner tidak cocok."
META="$(psql_admin -d "$DB_NAME" -Atqc "SELECT schema_version||'|'||runtime_role||'|'||api_login_role FROM private.stardesk_custom_install_meta WHERE singleton")"
case "$META" in
  "androiddb_v0_030_agent_remote_sync|$RUNTIME_ROLE|$API_DB_USER"|"androiddb_v0_031_stardesk_coin_sessions|$RUNTIME_ROLE|$API_DB_USER") ;;
  *) die "Metadata DB tidak dikenali: $META" ;;
esac

# Prove migration 031 objects exist before deploying its API. No DDL/DML migration is run here.
SCHEMA_OK="$(psql_admin -d "$DB_NAME" -Atqc "SELECT
  (to_regclass('androiddb_v0.coin_rental_sessions') IS NOT NULL)
  AND (to_regclass('androiddb_v0.coin_session_billing_events') IS NOT NULL)
  AND (to_regprocedure('api.androiddb_v0_remote_request_session(text,uuid,text)') IS NOT NULL)
  AND (to_regprocedure('api.androiddb_v0_remote_session_status(text)') IS NOT NULL)
  AND (to_regprocedure('api.androiddb_v0_agent_ui_monitor_heartbeat(text)') IS NOT NULL)
  AND (to_regprocedure('api.androiddb_v0_agent_stardesk_session_event(text,text,uuid)') IS NOT NULL)
  AND (to_regprocedure('api.androiddb_v0_agent_stardesk_session_tick(text,uuid)') IS NOT NULL)
  AND (to_regprocedure('api.androiddb_v0_agent_sync_stardesk_pairing(text,text,text,text,text,text,text,text,text)') IS NOT NULL)")"
[ "$SCHEMA_OK" = "t" ] || die "Objek SQL 031 belum lengkap. API tidak akan diubah; kirim output audit."
log "Objek SQL 031 terdeteksi lengkap. Tidak menjalankan migrasi SQL."

TMP_DIR="$(mktemp -d "$PREFIX/tmp/stardesk-coin-031-api.XXXXXX")"
cleanup(){ [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE="$TMP_DIR/source.tar.gz"
log "Mengambil source API immutable $SOURCE_REF..."
curl --fail --location --silent --show-error "https://codeload.github.com/anigamesready/Billing_stardesk_custom/tar.gz/$SOURCE_REF" -o "$ARCHIVE"
tar -tzf "$ARCHIVE" >/dev/null
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
SOURCE_ROOT="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
NEW_SERVER="$SOURCE_ROOT/backend/android-db/server/server.mjs"
[ -s "$NEW_SERVER" ] || die "Source API baru tidak ditemukan."
for rpc in androiddb_v0_agent_sync_stardesk_pairing androiddb_v0_agent_ui_monitor_heartbeat androiddb_v0_agent_stardesk_session_event androiddb_v0_agent_stardesk_session_tick androiddb_v0_remote_request_session androiddb_v0_remote_session_status androiddb_v0_remote_dashboard; do
  grep -q "$rpc" "$NEW_SERVER" || die "RPC API hilang: $rpc"
done
node --check "$NEW_SERVER" || die "Syntax source API baru gagal."

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$APP_DIR/backups"
mkdir -p "$BACKUP_DIR"
cp "$SERVER_DIR/server.mjs" "$BACKUP_DIR/server.mjs.before-coin-031-api-resume.$STAMP"
cp "$NEW_SERVER" "$SERVER_DIR/server.mjs.new"
# Apply product branding with Node, avoiding sed delimiter/escape differences on Android.
node --input-type=module - "$SERVER_DIR/server.mjs.new" <<'NODE'
import fs from 'node:fs';
const file=process.argv[2];
let s=fs.readFileSync(file,'utf8');
const replacements=[
  ['Ani Games Ready Local Server','StarDesk Custom Local API'],
  ['Setup Admin Ani Games Ready','Setup StarDesk Custom Owner'],
  ['Database lokal Ani Games Ready. Blynk/WoL tidak disentuh.','Database khusus StarDesk Custom. Database Ani Games Ready lama tidak disentuh.'],
  ['ani-games-ready-local-api','stardesk-custom-v0-api']
];
for (const [from,to] of replacements) s=s.split(from).join(to);
fs.writeFileSync(file,s,{mode:0o600});
NODE
node --check --input-type=module < "$SERVER_DIR/server.mjs.new" || die "Syntax API hasil patch gagal; API lama tetap aktif."

mv "$SERVER_DIR/server.mjs.new" "$SERVER_DIR/server.mjs"
log "Restart service $SERVICE_NAME..."
"$PREFIX/bin/sv" restart "$SERVICE_NAME" >/dev/null 2>&1 || true

HEALTH=0
for _ in $(seq 1 30); do
  if curl --fail --silent --connect-timeout 2 --max-time 5 "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1 && "$PREFIX/bin/sv" status "$SERVICE_NAME" 2>&1 | grep -q '^run:'; then
    HEALTH=1; break
  fi
  sleep 1
done
rpc_route_check(){
  local rpc="$1" body="$TMP_DIR/rpc-$rpc.json" status
  status="$(curl --silent --connect-timeout 2 --max-time 6 -o "$body" -w '%{http_code}' -X POST -H 'content-type: application/json' --data '{}' "http://127.0.0.1:$API_PORT/rest/v1/rpc/$rpc" 2>/dev/null || true)"
  [ "$status" = "401" ] && grep -q 'AUTH_REQUIRED' "$body"
}
if [ "$HEALTH" = "1" ]; then
  for rpc in androiddb_v0_agent_sync_stardesk_pairing androiddb_v0_agent_ui_monitor_heartbeat androiddb_v0_agent_stardesk_session_event androiddb_v0_agent_stardesk_session_tick androiddb_v0_remote_request_session androiddb_v0_remote_dashboard; do
    if ! rpc_route_check "$rpc"; then HEALTH=0; log "RPC preflight gagal: $rpc"; break; fi
  done
fi
if [ "$HEALTH" != "1" ]; then
  log "Preflight gagal; mengembalikan API server.mjs sebelumnya."
  cp "$BACKUP_DIR/server.mjs.before-coin-031-api-resume.$STAMP" "$SERVER_DIR/server.mjs"
  "$PREFIX/bin/sv" restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  die "API baru gagal; API lama dipulihkan. Database tidak disentuh."
fi

psql_admin -d "$DB_NAME" -v source_ref="$SOURCE_REF" <<SQL >/dev/null
UPDATE private.stardesk_custom_install_meta
SET schema_version='androiddb_v0_031_stardesk_coin_sessions',source_ref=:'source_ref'
WHERE singleton AND runtime_role='$RUNTIME_ROLE' AND api_login_role='$API_DB_USER';
SQL
chmod 600 "$ENV_FILE"
log "BERHASIL: API Coin 031 terpasang, health + RPC preflight lolos. Migrasi database tidak dijalankan ulang."
log "Backup API lama: $BACKUP_DIR/server.mjs.before-coin-031-api-resume.$STAMP"
