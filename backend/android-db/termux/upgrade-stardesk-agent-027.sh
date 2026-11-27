#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# Additive Agent 027 + manual tariff 028 upgrade for an EXISTING isolated StarDesk Custom installation.
# Never touches legacy Ani Games Ready DB/API/service.
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

log(){ printf '[STAR-DESK-AGENT-028] %s\n' "$*"; }
die(){ printf '[STAR-DESK-AGENT-028] STOP: %s\n' "$*" >&2; exit 1; }
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

[ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || die "Khusus Termux Android."
[ -r /dev/tty ] || die "Jalankan dari terminal interaktif Termux."
for bin in psql pg_isready node npm curl tar sha256sum readlink date sed sv; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia. Script tidak memasang atau memperbarui paket."
done
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_STARDESK_SOURCE_REF wajib SHA commit 40 karakter."
[ -f "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL Termux existing tidak ditemukan. Tidak ada perubahan."
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL existing belum siap. Script tidak menyalakan atau me-restart PostgreSQL."
[ -s "$SERVER_DIR/server.mjs" ] && [ -s "$SERVER_DIR/.env" ] || die "Installasi StarDesk Custom existing tidak ditemukan."
[ -d "$SERVICE_DIR" ] || die "Service StarDesk Custom khusus tidak ditemukan."
export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log"
"$PREFIX/bin/sv" status "$SERVICE_NAME" 2>&1 | grep -q '^run:' || die "Service $SERVICE_NAME tidak sedang run. Tidak ada perubahan."
grep -q '^PORT=8789$' "$ENV_FILE" || die "Port API tidak cocok dengan port khusus StarDesk Custom 8789."

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
[ -n "$EXPECTED_PGDATA" ] && [ "$EXPECTED_PGDATA" = "$ACTUAL_PGDATA" ] || die "Cluster aktif tidak sama dengan PGDATA Termux yang diharapkan."
DB_OWNER="$(psql_admin -d postgres -Atqc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB_NAME'")"
[ "$DB_OWNER" = "$DB_OWNER_ROLE" ] || die "Database $DB_NAME tidak dimiliki $DB_OWNER_ROLE. Upgrade dibatalkan."
ROLE_CHECK="$(psql_admin -d postgres -Atqc "SELECT count(*) FROM pg_roles WHERE rolname IN ('$DB_OWNER_ROLE','$RUNTIME_ROLE','$API_DB_USER')")"
[ "$ROLE_CHECK" = "3" ] || die "Role isolated StarDesk tidak lengkap."
META="$(psql_admin -d "$DB_NAME" -Atqc "SELECT schema_version||'|'||runtime_role||'|'||api_login_role FROM private.stardesk_custom_install_meta WHERE singleton")"
[ -n "$META" ] || die "Metadata install StarDesk Custom tidak ditemukan."
[[ "$META" == androiddb_v0_025\|stardesk_v0_runtime\|stardesk_v0_login || "$META" == androiddb_v0_026\|stardesk_v0_runtime\|stardesk_v0_login || "$META" == androiddb_v0_027_agent\|stardesk_v0_runtime\|stardesk_v0_login || "$META" == androiddb_v0_028_manual_rates\|stardesk_v0_runtime\|stardesk_v0_login ]] || die "Metadata database tidak cocok: $META"

TMP_DIR="$(mktemp -d "$PREFIX/tmp/stardesk-admin-028.XXXXXX")"
cleanup(){ [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE="$TMP_DIR/source.tar.gz"
log "Mengambil source yang dipin ke $SOURCE_REF..."
curl --fail --location --silent --show-error \
  "https://codeload.github.com/anigamesready/Billing_stardesk_custom/tar.gz/$SOURCE_REF" -o "$ARCHIVE"
tar -tzf "$ARCHIVE" >/dev/null
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
SOURCE_ROOT="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
MIGRATION_AGENT="$SOURCE_ROOT/backend/android-db/migrations/027_windows_agent_domain.sql"
MIGRATION_RATES="$SOURCE_ROOT/backend/android-db/migrations/028_manual_pc_tariffs.sql"
NEW_SERVER="$SOURCE_ROOT/backend/android-db/server/server.mjs"
[ -s "$MIGRATION_AGENT" ] && [ -s "$MIGRATION_RATES" ] && [ -s "$NEW_SERVER" ] || die "Source migrasi Agent / tarif manual tidak lengkap."
for rpc in androiddb_v0_admin_agent_list androiddb_v0_admin_agent_pair_manual androiddb_v0_admin_agent_update_pc_manual androiddb_v0_admin_set_device_custom_rate; do
  grep -q "$rpc" "$NEW_SERVER" || die "RPC baru tidak ditemukan pada source API: $rpc"
done
node --check "$NEW_SERVER" || die "Syntax API baru gagal. Database belum diubah."

sed "s/ani_api_runtime/$RUNTIME_ROLE/g" "$MIGRATION_AGENT" > "$TMP_DIR/027_windows_agent_domain.sql"
sed "s/ani_api_runtime/$RUNTIME_ROLE/g" "$MIGRATION_RATES" > "$TMP_DIR/028_manual_pc_tariffs.sql"
log "Memastikan schema Agent 027 dan tarif manual 028 pada database khusus $DB_NAME..."
{ printf 'SET ROLE %s;\n' "$DB_OWNER_ROLE"; cat "$TMP_DIR/027_windows_agent_domain.sql"; cat "$TMP_DIR/028_manual_pc_tariffs.sql"; } \
  | psql_admin -d "$DB_NAME" >/dev/null

BACKUP_DIR="$APP_DIR/backups"
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$SERVER_DIR/server.mjs" "$BACKUP_DIR/server.mjs.before-agent-027.$STAMP"
cp "$NEW_SERVER" "$SERVER_DIR/server.mjs.new"
sed -i \
  -e 's/Ani Games Ready Local Server/StarDesk Custom Local API/g' \
  -e 's/Setup Admin Ani Games Ready/Setup StarDesk Custom Owner/g' \
  -e 's/Database lokal Ani Games Ready. Blynk\/WoL tidak disentuh./Database khusus StarDesk Custom. Database Ani Games Ready lama tidak disentuh./g' \
  -e 's/ani-games-ready-local-api/stardesk-custom-v0-api/g' \
  "$SERVER_DIR/server.mjs.new"
node --check "$SERVER_DIR/server.mjs.new" || die "API baru gagal diperiksa. API lama tetap aktif."
mv "$SERVER_DIR/server.mjs.new" "$SERVER_DIR/server.mjs"

log "Restart hanya service $SERVICE_NAME pada port $API_PORT..."
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
  local rpc="$1" body="$TMP_DIR/rpc-${rpc}.json" status
  status="$(curl --silent --show-error --connect-timeout 2 --max-time 5 \
    -o "$body" -w '%{http_code}' -X POST \
    -H 'content-type: application/json' --data '{}' \
    "http://127.0.0.1:$API_PORT/rest/v1/rpc/$rpc" 2>/dev/null || true)"
  [ "$status" = "401" ] && grep -q 'AUTH_REQUIRED' "$body"
}
if [ "$HEALTH" = "1" ]; then
  log "API health OK; memeriksa allowlist RPC versi 028..."
  for rpc in androiddb_v0_admin_agent_list androiddb_v0_admin_agent_pair_manual androiddb_v0_admin_agent_update_pc_manual androiddb_v0_admin_set_device_custom_rate; do
    if ! rpc_route_check "$rpc"; then
      HEALTH=0
      log "RPC $rpc tidak lolos preflight (harus 401 AUTH_REQUIRED, bukan 404 RPC_NOT_ALLOWED)."
      break
    fi
  done
fi
if [ "$HEALTH" != 1 ]; then
  log "API atau preflight RPC gagal; memulihkan server.mjs lama."
  cp "$BACKUP_DIR/server.mjs.before-agent-027.$STAMP" "$SERVER_DIR/server.mjs"
  "$PREFIX/bin/sv" restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  die "Upgrade API 028 gagal. Migrasi 027/028 bersifat aditif dan tetap tersimpan; server.mjs lama dipulihkan. Database lama, API 8788, dan service Billing tidak disentuh."
fi

psql_admin -d "$DB_NAME" -v source_ref="$SOURCE_REF" <<SQL >/dev/null
UPDATE private.stardesk_custom_install_meta
SET schema_version='androiddb_v0_028_manual_rates',source_ref=:'source_ref'
WHERE singleton AND runtime_role='$RUNTIME_ROLE' AND api_login_role='$API_DB_USER';
SQL

log "Upgrade StarDesk Agent + tarif manual 028 berhasil; API dan seluruh RPC baru lolos preflight."
log "Target hanya $DB_NAME, API port $API_PORT, service $SERVICE_NAME. Legacy DB/API/relay/Billing tidak disentuh."
