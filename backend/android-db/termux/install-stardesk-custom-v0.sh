#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# Isolated first-install installer for StarDesk Custom v0.
# The PostgreSQL cluster may be shared, but DB, roles, API files and service are new.
# Never reads, overwrites, migrates, restarts or deletes the legacy Ani Games Ready API/DB.
APP_DIR="$HOME/ani-games-stardesk-custom-v0"
SERVER_DIR="$APP_DIR/server"
MIGRATIONS_DIR="$APP_DIR/migrations"
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
if [ -f "$HOME/.postgres/postgresql.conf" ]; then PGDATA="$HOME/.postgres"; fi
OS_DB_USER="$(id -un)"
PG_ADMIN_USER=""

log(){ printf '[STAR-DESK-CUSTOM-V0] %s\n' "$*"; }
die(){ printf '[STAR-DESK-CUSTOM-V0] STOP: %s\n' "$*" >&2; exit 1; }
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

[ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || die "Khusus Termux Android."
[ -r /dev/tty ] || die "Jalankan dari terminal interaktif Termux."
for bin in psql pg_isready createdb node npm curl openssl sv sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia. Script tidak memasang atau memperbarui paket."
done
[ -x "$PREFIX/share/termux-services/svlogger" ] || die "svlogger Termux tidak ditemukan."
[ -f "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL existing tidak ditemukan. Tidak akan initdb atau membuat cluster baru."
[ -d "$PREFIX/var/service/postgres" ] || die "Service PostgreSQL Termux tidak ditemukan."
export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log"
"$PREFIX/bin/sv" status postgres 2>&1 | grep -q '^run:' || die "PostgreSQL harus sudah berjalan melalui service yang ada; script tidak akan restart/adopsi proses."
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL lokal belum siap."
NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 20 ] || die "Node.js 20+ diperlukan."

for candidate in "$OS_DB_USER" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null | grep -qx t; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Superuser PostgreSQL lokal tidak ditemukan."

# Fail closed on any collision. No upgrade or overwrite path is included.
DB_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
OWNER_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$DB_OWNER_ROLE'")"
RUNTIME_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$RUNTIME_ROLE'")"
LOGIN_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$API_DB_USER'")"
[ "$DB_EXISTS" != "1" ] || die "Database $DB_NAME sudah ada. Perlu audit khusus; tidak ada perubahan."
[ "$OWNER_EXISTS" != "1" ] && [ "$RUNTIME_EXISTS" != "1" ] && [ "$LOGIN_EXISTS" != "1" ] || die "Role StarDesk sudah ada. Perlu audit khusus; tidak ada perubahan."
[ ! -e "$APP_DIR" ] || die "Folder $APP_DIR sudah ada. Tidak akan menimpa source/config."
[ ! -e "$SERVICE_DIR" ] || die "Service $SERVICE_NAME sudah ada. Tidak akan menimpa service."
if (echo >"/dev/tcp/127.0.0.1/$API_PORT") >/dev/null 2>&1; then
  die "Port $API_PORT sudah dipakai service lain. Tidak ada perubahan."
fi

SOURCE_REF="${ANI_STARDESK_SOURCE_REF:-}"
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_STARDESK_SOURCE_REF wajib SHA commit 40 karakter yang dipin."
TMP_DIR="$(mktemp -d "$PREFIX/tmp/stardesk-v0-install.XXXXXX")"
cleanup(){ [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE="$TMP_DIR/source.tar.gz"
log "Mengambil source StarDesk Custom terpin ($SOURCE_REF)..."
curl --fail --location --silent --show-error \
  "https://codeload.github.com/anigamesready/Billing_stardesk_custom/tar.gz/$SOURCE_REF" \
  -o "$ARCHIVE"
tar -tzf "$ARCHIVE" >/dev/null
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
SOURCE_ROOT="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$SOURCE_ROOT" ] || die "Arsip source kosong."
[ -s "$SOURCE_ROOT/backend/android-db/server/server.mjs" ] || die "Node API source tidak ditemukan."
[ -s "$SOURCE_ROOT/backend/android-db/server/package.json" ] || die "Node API package.json tidak ditemukan."

MIGRATION_FILES=(
  000_prerequisites.sql
  002_core_business_schema.sql
  003_pc_device_api_functions.sql
  004_billing_reseller_api.sql
  005_runtime_privileges.sql
  006_admin_local_auth_and_rpc.sql
  007_billing_control_commands.sql
  008_local_business_triggers.sql
  009_admin_business_routines.sql
  010_billing_reseller_refresh_and_devices.sql
  011_billing_control_android_rpcs.sql
  012_billing_stop_pause_policy.sql
  013_remote_play.sql
  014_remote_play_pairing.sql
  015_remote_play_admin_controls.sql
  016_remote_play_cloudflare_mesh.sql
  017_remote_play_dashboard_cooldown.sql
  018_remote_play_server_watchdog.sql
  019_remote_play_session_connected.sql
  020_remote_coin_wallet.sql
  021_android_wol_relay.sql
  022_coin_unit_scale_100.sql
  023_admin_coin_management_read_api.sql
  025_admin_androiddb_v0_coin_domain.sql
)
for file in "${MIGRATION_FILES[@]}"; do
  [ -s "$SOURCE_ROOT/backend/android-db/migrations/$file" ] || die "Migrasi source hilang: $file"
done
grep -q "androiddb_v0_remote_login" "$SOURCE_ROOT/backend/android-db/server/server.mjs" || die "API Remote Coin v0 tidak ditemukan."
grep -q "androiddb_v0_admin_dashboard" "$SOURCE_ROOT/backend/android-db/server/server.mjs" || die "RPC Admin Coin v0 tidak ditemukan."

mkdir -p "$SERVER_DIR" "$MIGRATIONS_DIR"
cp -R "$SOURCE_ROOT/backend/android-db/server/." "$SERVER_DIR/"
for file in "${MIGRATION_FILES[@]}"; do
  # The transformed runtime role is unique to this StarDesk database.
  sed "s/ani_api_runtime/$RUNTIME_ROLE/g" \
    "$SOURCE_ROOT/backend/android-db/migrations/$file" > "$MIGRATIONS_DIR/$file"
done
chmod 700 "$APP_DIR" "$SERVER_DIR" "$MIGRATIONS_DIR"

log "Membuat role dan database baru $DB_NAME. Tidak ada data rental lama yang disalin."
psql_admin -d postgres <<SQL >/dev/null
CREATE ROLE $DB_OWNER_ROLE NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE DATABASE $DB_NAME OWNER $DB_OWNER_ROLE;
REVOKE CONNECT ON DATABASE $DB_NAME FROM PUBLIC;
SQL

apply_file(){
  file="$1"
  [ -s "$MIGRATIONS_DIR/$file" ] || die "File migrasi hilang: $file"
  log "Menerapkan $file hanya pada $DB_NAME"
  psql_admin -d "$DB_NAME" -f "$MIGRATIONS_DIR/$file" >/dev/null
}
for file in "${MIGRATION_FILES[@]}"; do apply_file "$file"; done

API_DB_PASSWORD="$(openssl rand -hex 32)"
API_PEPPER="$(openssl rand -hex 32)"
BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
psql_admin -d postgres -v api_user="$API_DB_USER" -v api_password="$API_DB_PASSWORD" -v db_name="$DB_NAME" <<'SQL' >/dev/null
CREATE ROLE :"api_user" LOGIN PASSWORD :'api_password'
  INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT stardesk_v0_runtime TO :"api_user";
GRANT CONNECT ON DATABASE :"db_name" TO :"api_user";
SQL
psql_admin -d "$DB_NAME" <<SQL >/dev/null
CREATE TABLE private.stardesk_custom_install_meta (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  schema_version text NOT NULL,
  runtime_role text NOT NULL,
  api_login_role text NOT NULL,
  source_ref text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO private.stardesk_custom_install_meta(singleton,schema_version,runtime_role,api_login_role,source_ref)
VALUES(true,'androiddb_v0_025','$RUNTIME_ROLE','$API_DB_USER','$SOURCE_REF');
REVOKE ALL ON private.stardesk_custom_install_meta FROM PUBLIC;
SQL

cat > "$ENV_FILE" <<EOF
DATABASE_URL=postgresql://$API_DB_USER:$API_DB_PASSWORD@127.0.0.1:$DB_PORT/$DB_NAME?sslmode=disable
ANI_BIND=127.0.0.1
PORT=$API_PORT
ANI_API_PEPPER=$API_PEPPER
ANI_ADMIN_BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN
ANI_ALLOWED_ORIGINS=
BLYNK_AUTH_TOKEN=
BLYNK_POWER_PIN=V0
EOF
chmod 600 "$ENV_FILE"
unset API_DB_PASSWORD API_PEPPER BOOTSTRAP_TOKEN

log "Memasang dependency dan memvalidasi koneksi memakai login StarDesk sendiri..."
cd "$SERVER_DIR"
npm install --omit=dev --no-audit --no-fund
npm run check
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
node --input-type=module <<'NODE'
import pg from "pg";
const pool = new pg.Pool({connectionString:process.env.DATABASE_URL,max:1,connectionTimeoutMillis:5000});
try {
  const sql = "SELECT current_database() AS db, current_user AS login_role, " +
    "(SELECT rolcanlogin FROM pg_roles WHERE rolname=current_user) AS can_login, " +
    "to_regnamespace('androiddb_v0') IS NOT NULL AS coin_schema, " +
    "to_regprocedure('api.androiddb_v0_admin_dashboard(text,integer)') IS NOT NULL AS admin_rpc, " +
    "to_regprocedure('api.androiddb_v0_remote_login(text,text,text)') IS NOT NULL AS remote_rpc";
  const r = await pool.query(sql);
  const x = r.rows[0];
  if (x.db !== "stardesk_custom_v0" || x.login_role !== "stardesk_v0_login" ||
      x.can_login !== true || !x.coin_schema || !x.admin_rpc || !x.remote_rpc) {
    throw new Error("STAR_DESK_DATABASE_ISOLATION_CHECK_FAILED");
  }
} finally { await pool.end(); }
NODE

# Create and start only the new StarDesk API runit service.
mkdir -p "$SERVICE_DIR/log"
touch "$SERVICE_DIR/down"
cat > "$SERVICE_DIR/run" <<EOF
#!$PREFIX/bin/sh
set -eu
cd "$SERVER_DIR"
set -a
. "$ENV_FILE"
set +a
exec "$PREFIX/bin/node" "$SERVER_DIR/server.mjs"
EOF
cat > "$SERVICE_DIR/log/run" <<EOF
#!$PREFIX/bin/sh
exec "$PREFIX/share/termux-services/svlogger"
EOF
chmod 700 "$SERVICE_DIR/run" "$SERVICE_DIR/log/run"
rm -f "$SERVICE_DIR/down"
"$PREFIX/bin/sv" up "$SERVICE_NAME" >/dev/null 2>&1 || die "Service $SERVICE_NAME gagal dimulai."

HEALTH=0
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1 \
    && "$PREFIX/bin/sv" status "$SERVICE_NAME" 2>&1 | grep -q '^run:'; then
    HEALTH=1
    break
  fi
  sleep 1
done
[ "$HEALTH" = 1 ] || die "API StarDesk belum sehat. Log: $PREFIX/var/log/sv/$SERVICE_NAME/current"

log "DB StarDesk terpisah siap; API lokal: http://127.0.0.1:$API_PORT/health"
log "Database: $DB_NAME | Login role: $API_DB_USER | Runtime role: $RUNTIME_ROLE"
log "Owner pertama: buka http://127.0.0.1:$API_PORT/setup dari browser Redmi."
log "Rahasia hanya disimpan di $ENV_FILE (izin 600); jangan dibagikan."
log "DB Ani Games Ready lama, API 8788, service lama, dan .env lama tidak disentuh."
