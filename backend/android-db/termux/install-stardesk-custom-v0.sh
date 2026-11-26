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
export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log"
POSTGRES_SERVICE_STATUS="service directory missing"
if [ -d "$PREFIX/var/service/postgres" ]; then
  POSTGRES_SERVICE_STATUS="$("$PREFIX/bin/sv" status postgres 2>&1 || true)"
fi
if [[ "$POSTGRES_SERVICE_STATUS" == run:* ]]; then
  log "PostgreSQL service runit aktif."
else
  log "Service runit postgres tidak berstatus run ($POSTGRES_SERVICE_STATUS). Mengecek hanya proses PostgreSQL yang sudah berjalan; tidak akan menyalakan atau me-restart service."
fi
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL existing belum siap pada socket Termux/port $DB_PORT. Installer tidak akan menjalankan atau me-restart PostgreSQL."
NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
[ "$NODE_MAJOR" -ge 20 ] || die "Node.js 20+ diperlukan."

for candidate in "$OS_DB_USER" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null | grep -qx t; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Superuser PostgreSQL lokal tidak ditemukan."

# Verify that the responding server is the Termux cluster selected above.
# Never point this installer at another local/remote PostgreSQL instance.
EXPECTED_PGDATA="$(readlink -f "$PGDATA")"
SERVER_PGDATA="$(psql_admin -d postgres -Atqc "SHOW data_directory")"
ACTUAL_PGDATA="$(readlink -f "$SERVER_PGDATA")"
[ -n "$EXPECTED_PGDATA" ] && [ "$EXPECTED_PGDATA" = "$ACTUAL_PGDATA" ] || die "Cluster target tidak cocok. PGDATA Termux=$EXPECTED_PGDATA, server merespons dari=$ACTUAL_PGDATA. Tidak ada database yang dibuat."
CLUSTER_MAJOR="$(cut -d. -f1 "$PGDATA/PG_VERSION")"
SERVER_MAJOR="$(psql_admin -d postgres -Atqc "SELECT current_setting('server_version_num')::int / 10000")"
[ "$CLUSTER_MAJOR" = "$SERVER_MAJOR" ] || die "Major version PostgreSQL tidak cocok (data=$CLUSTER_MAJOR, server=$SERVER_MAJOR). Tidak ada perubahan."

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
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_STARDESK_SOURCE_REF wajib diisi dengan SHA commit 40 karakter yang sama dengan versi installer yang diunduh."
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
  026_androiddb_v0_coin_x100.sql
  027_androiddb_v0_remote_userid_only_login.sql
)
for file in "${MIGRATION_FILES[@]}"; do
  [ -s "$SOURCE_ROOT/backend/android-db/migrations/$file" ] || die "Migrasi source hilang: $file"
done
grep -q "androiddb_v0_remote_login" "$SOURCE_ROOT/backend/android-db/server/server.mjs" || die "API Remote Coin v0 tidak ditemukan."
grep -q "androiddb_v0_admin_dashboard" "$SOURCE_ROOT/backend/android-db/server/server.mjs" || die "RPC Admin Coin v0 tidak ditemukan."

mkdir -p "$SERVER_DIR" "$MIGRATIONS_DIR"
cp -R "$SOURCE_ROOT/backend/android-db/server/." "$SERVER_DIR/"
# Brand the isolated API identity and make the local Owner setup page unambiguous.
sed -i \
  -e 's/Ani Games Ready Local Server/StarDesk Custom Local API/g' \
  -e 's/Setup Admin Ani Games Ready/Setup StarDesk Custom Owner/g' \
  -e 's/Database lokal Ani Games Ready. Blynk\/WoL tidak disentuh./Database khusus StarDesk Custom. Database Ani Games Ready lama tidak disentuh./g' \
  -e 's/ani-games-ready-local-api/stardesk-custom-v0-api/g' \
  "$SERVER_DIR/server.mjs"
for file in "${MIGRATION_FILES[@]}"; do
  # The transformed runtime role is unique to this StarDesk database.
  sed "s/ani_api_runtime/$RUNTIME_ROLE/g" \
    "$SOURCE_ROOT/backend/android-db/migrations/$file" > "$MIGRATIONS_DIR/$file"
done
chmod 700 "$APP_DIR" "$SERVER_DIR" "$MIGRATIONS_DIR"

log "Membuat role dan database baru $DB_NAME. Tidak ada data rental lama yang disalin."
# CREATE DATABASE cannot run inside a multi-statement transaction. Keep role,
# database creation and permission tightening as separate PostgreSQL commands.
psql_admin -d postgres -c "CREATE ROLE $DB_OWNER_ROLE NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS" >/dev/null
createdb -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -O "$DB_OWNER_ROLE" "$DB_NAME"
psql_admin -d postgres -c "REVOKE CONNECT ON DATABASE $DB_NAME FROM PUBLIC" >/dev/null

apply_file(){
  file="$1"
  [ -s "$MIGRATIONS_DIR/$file" ] || die "File migrasi hilang: $file"
  log "Menerapkan $file hanya pada $DB_NAME"
  if [ "$file" = "000_prerequisites.sql" ]; then
    # Extension and cluster-level NOLOGIN role creation require the local DB
    # administrator; application objects are reassigned to the isolated owner
    # immediately afterward, before later migrations create any functions.
    psql_admin -d "$DB_NAME" -f "$MIGRATIONS_DIR/$file" >/dev/null
    psql_admin -d "$DB_NAME" <<SQL >/dev/null
ALTER DATABASE $DB_NAME OWNER TO $DB_OWNER_ROLE;
ALTER SCHEMA public OWNER TO $DB_OWNER_ROLE;
ALTER SCHEMA api OWNER TO $DB_OWNER_ROLE;
ALTER SCHEMA auth OWNER TO $DB_OWNER_ROLE;
ALTER SCHEMA private OWNER TO $DB_OWNER_ROLE;
ALTER SCHEMA reporting_private OWNER TO $DB_OWNER_ROLE;
GRANT USAGE ON SCHEMA extensions TO $DB_OWNER_ROLE;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA extensions TO $DB_OWNER_ROLE;
ALTER TABLE auth.users OWNER TO $DB_OWNER_ROLE;
SQL
  else
    # SECURITY DEFINER business routines must be owned by this non-login DB
    # owner, never by the local PostgreSQL superuser.
    if [ "$file" = "005_runtime_privileges.sql" ]; then
      # This migration changes the cluster-level NOLOGIN role; run it with the
      # local DB administrator, then set default privileges for StarDesk owner.
      psql_admin -d "$DB_NAME" -f "$MIGRATIONS_DIR/$file" >/dev/null
      psql_admin -d "$DB_NAME" <<SQL >/dev/null
ALTER DEFAULT PRIVILEGES FOR ROLE $DB_OWNER_ROLE IN SCHEMA api REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE $DB_OWNER_ROLE IN SCHEMA api GRANT EXECUTE ON FUNCTIONS TO $RUNTIME_ROLE;
SQL
    else
      # SECURITY DEFINER business routines must be owned by this non-login DB
      # owner, never by the local PostgreSQL superuser.
      { printf 'SET ROLE %s;\n' "$DB_OWNER_ROLE"; cat "$MIGRATIONS_DIR/$file"; } | psql_admin -d "$DB_NAME" >/dev/null
    fi
  fi
}
for file in "${MIGRATION_FILES[@]}"; do apply_file "$file"; done

API_DB_PASSWORD="$(openssl rand -hex 32)"
API_PEPPER="$(openssl rand -hex 32)"
BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
# The database stores only the hash. The plaintext token stays in the mode-600
# local API environment and is never printed or uploaded.
psql_admin -d "$DB_NAME" -v bootstrap_token="$BOOTSTRAP_TOKEN" <<SQL >/dev/null
SET ROLE $DB_OWNER_ROLE;
INSERT INTO private.admin_bootstrap_control(singleton,token_hash)
VALUES(true, encode(extensions.digest(:'bootstrap_token','sha256'),'hex'));
SQL
psql_admin -d postgres -v api_user="$API_DB_USER" -v api_password="$API_DB_PASSWORD" -v db_name="$DB_NAME" <<'SQL' >/dev/null
CREATE ROLE :"api_user" LOGIN PASSWORD :'api_password'
  INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT stardesk_v0_runtime TO :"api_user";
GRANT CONNECT ON DATABASE :"db_name" TO :"api_user";
SQL
psql_admin -d "$DB_NAME" <<SQL >/dev/null
SET ROLE $DB_OWNER_ROLE;
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
