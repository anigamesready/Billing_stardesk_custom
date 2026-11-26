#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# Dedicated StarDesk Custom database + API.
# Shares only the PostgreSQL server process with the old system. It does not
# connect to, migrate, or copy data from ani_games_ready_stage.
APP_DIR="$HOME/ani-games-stardesk-custom"
SERVER_DIR="$APP_DIR/server"
MIGRATIONS_DIR="$APP_DIR/migrations"
ENV_FILE="$SERVER_DIR/.env"
LOG_DIR="$APP_DIR/logs"
PID_FILE="$APP_DIR/api.pid"
DB_NAME="ani_games_stardesk_custom"
DB_PORT="5432"
API_PORT="8789"
OLD_DB_NAME="ani_games_ready_stage"
SOURCE_REF="61ab358ff9d6b7fbd77d542823d3437ee02b2941"
REPO="anigamesready/Billing_stardesk_custom"
BACKUP_ROOT="$HOME/ani-games-ready-backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

log(){ printf '[ANI-STARDESK-ISOLATED] %s\n' "$*"; }
die(){ printf '[ANI-STARDESK-ISOLATED] STOP: %s\n' "$*" >&2; exit 1; }

[ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || die "Khusus Termux Android."
for bin in psql createdb pg_dumpall curl node npm openssl sha256sum pg_isready nohup; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."
done
[ ! -e "$APP_DIR" ] || die "Folder $APP_DIR sudah ada. Installer tidak akan menimpa instalasi/backup sebelumnya."
[ -r /dev/tty ] || die "Jalankan langsung dari Termux interaktif."

PG_ADMIN_USER=""
for candidate in "$(id -un)" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT 1" >/dev/null 2>&1; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Superuser PostgreSQL lokal tidak ditemukan. Tidak ada database yang dibuat."
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

READY=0
for _ in $(seq 1 20); do
  if pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
[ "$READY" = 1 ] || die "PostgreSQL lama belum siap."
OLD_DB_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$OLD_DB_NAME'")"
[ "$OLD_DB_EXISTS" = "1" ] || die "Database lama stage yang sedang berjalan tidak ditemukan; hentikan untuk audit target PostgreSQL."
NEW_DB_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
[ -z "$NEW_DB_EXISTS" ] || die "Database $DB_NAME sudah ada. Tidak ada migrasi/overwrite otomatis."
SUPERUSER="$(psql_admin -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user")"
[ "$SUPERUSER" = "t" ] || die "Koneksi PostgreSQL lokal bukan superuser; tidak akan membuat role/database parsial."
for role in ani_stardesk_api_runtime ani_stardesk_api_login; do
  ROLE_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$role'")"
  [ -z "$ROLE_EXISTS" ] || die "Role khusus $role sudah ada. Tidak akan memakai ulang role dari instalasi parsial."
done

# Verify the old database is not selected as the new target and record its
# database OID for a before/after non-modification check.
OLD_DB_OID_BEFORE="$(psql_admin -d postgres -Atqc "SELECT oid FROM pg_database WHERE datname='$OLD_DB_NAME'")"
OLD_CONN_BEFORE="$(psql_admin -d "$OLD_DB_NAME" -Atqc "SELECT current_database() || '|' || current_user")"

mkdir -p "$BACKUP_ROOT/$DB_NAME-$STAMP"
chmod 700 "$BACKUP_ROOT" "$BACKUP_ROOT/$DB_NAME-$STAMP"
GLOBAL_BACKUP="$BACKUP_ROOT/$DB_NAME-$STAMP/cluster-roles-before.sql"
pg_dumpall -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" --globals-only -f "$GLOBAL_BACKUP"
[ -s "$GLOBAL_BACKUP" ] || die "Backup global role cluster kosong."
chmod 600 "$GLOBAL_BACKUP"
sha256sum "$GLOBAL_BACKUP" > "$BACKUP_ROOT/$DB_NAME-$STAMP/SHA256SUMS.txt"
(cd "$BACKUP_ROOT/$DB_NAME-$STAMP" && sha256sum -c SHA256SUMS.txt >/dev/null) || die "Checksum backup role cluster gagal."

TMP_DIR="$(mktemp -d "$HOME/.ani-stardesk-isolated.XXXXXX")"
chmod 700 "$TMP_DIR"
cleanup(){ rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log "Mengunduh source API dan 25 migration dari commit terpin..."
MIGRATIONS=(
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
  024_remote_coin_expiry_guard.sql
  025_admin_androiddb_v0_coin_domain.sql
)
for file in "${MIGRATIONS[@]}"; do
  curl -fsSL "https://raw.githubusercontent.com/$REPO/$SOURCE_REF/backend/android-db/migrations/$file" -o "$TMP_DIR/$file"
  [ -s "$TMP_DIR/$file" ] || die "Migration $file kosong/tidak terunduh."
done
curl -fsSL "https://raw.githubusercontent.com/$REPO/$SOURCE_REF/backend/android-db/server/server.mjs" -o "$TMP_DIR/server.mjs"
curl -fsSL "https://raw.githubusercontent.com/$REPO/$SOURCE_REF/backend/android-db/server/package.json" -o "$TMP_DIR/package.json"
[ -s "$TMP_DIR/server.mjs" ] && [ -s "$TMP_DIR/package.json" ] || die "Source API tidak lengkap."
node --check "$TMP_DIR/server.mjs" || die "Syntax source API gagal."
grep -q 'admin_context: { auth: "admin"' "$TMP_DIR/server.mjs" || die "RPC admin_context tidak ada di source API."
grep -q 'androiddb_v0_admin_dashboard: { auth: "admin"' "$TMP_DIR/server.mjs" || die "RPC Coin v0 dashboard tidak ada di source API."
sha256sum "$TMP_DIR"/*.sql "$TMP_DIR/server.mjs" "$TMP_DIR/package.json" > "$TMP_DIR/SOURCE-SHA256SUMS.txt"

# Create one dedicated API runtime group and one dedicated LOGIN role only.
# The old system roles ani_api_runtime / ani_api_login are not reused or altered.
API_DB_USER="ani_stardesk_api_login"
API_DB_PASSWORD="$(openssl rand -hex 32)"
API_PEPPER="$(openssl rand -hex 32)"
BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
BLYNK_TOKEN=""
printf '\nToken Blynk untuk sistem StarDesk ini (opsional; input disembunyikan, kosongkan bila tidak dipakai): ' >/dev/tty
IFS= read -r -s BLYNK_TOKEN </dev/tty || die "Gagal membaca token Blynk."
printf '\n' >/dev/tty
if [ -n "$BLYNK_TOKEN" ]; then
  [[ "$BLYNK_TOKEN" =~ ^[A-Za-z0-9._-]{16,512}$ ]] || die "Token Blynk harus satu baris ASCII aman; tidak disimpan."
fi

log "Membuat database baru $DB_NAME; database lama $OLD_DB_NAME tidak dipilih."
createdb -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -O "$PG_ADMIN_USER" --encoding=UTF8 --template=template0 "$DB_NAME"
DB_CREATED="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
[ "$DB_CREATED" = "1" ] || die "Database baru gagal dibuat."
psql_admin -d postgres <<SQL >/dev/null
REVOKE ALL ON DATABASE "$DB_NAME" FROM PUBLIC;
GRANT CONNECT ON DATABASE "$DB_NAME" TO "$PG_ADMIN_USER";
SQL

log "Memasang migration hanya di database baru; role API dipisahkan."
for file in "${MIGRATIONS[@]}"; do
  sed 's/ani_api_runtime/ani_stardesk_api_runtime/g; s/ani_api_login/ani_stardesk_api_login/g' "$TMP_DIR/$file" > "$TMP_DIR/transformed.sql"
  psql_admin -d "$DB_NAME" -f "$TMP_DIR/transformed.sql" >/dev/null
  log "OK $file"
done

# The bootstrap table is created by migration 006. Seed exactly one hash in
# this new DB; this omission in the previous installer prevented first Owner setup.
psql_admin -d "$DB_NAME" -v bootstrap_token="$BOOTSTRAP_TOKEN" <<'SQL' >/dev/null
INSERT INTO private.admin_bootstrap_control(singleton, token_hash)
VALUES (true, encode(extensions.digest(:'bootstrap_token', 'sha256'), 'hex'))
ON CONFLICT (singleton) DO NOTHING;
SQL

psql_admin -d postgres -v api_user="$API_DB_USER" -v api_password="$API_DB_PASSWORD" -v db_name="$DB_NAME" <<'SQL' >/dev/null
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_stardesk_api_login') THEN
    RAISE EXCEPTION 'DEDICATED_API_LOGIN_ROLE_ALREADY_EXISTS';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_stardesk_api_runtime' AND NOT rolcanlogin) THEN
    RAISE EXCEPTION 'DEDICATED_API_RUNTIME_ROLE_MISSING';
  END IF;
END
$$;
CREATE ROLE :"api_user" LOGIN PASSWORD :'api_password'
  INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT ani_stardesk_api_runtime TO :"api_user";
GRANT CONNECT ON DATABASE :"db_name" TO :"api_user";
SQL

mkdir -p "$SERVER_DIR" "$MIGRATIONS_DIR" "$LOG_DIR"
chmod 700 "$APP_DIR" "$SERVER_DIR" "$MIGRATIONS_DIR" "$LOG_DIR"
cp "$TMP_DIR/server.mjs" "$SERVER_DIR/server.mjs"
cp "$TMP_DIR/package.json" "$SERVER_DIR/package.json"
cp "$TMP_DIR"/*.sql "$MIGRATIONS_DIR/"
cp "$TMP_DIR/SOURCE-SHA256SUMS.txt" "$APP_DIR/SOURCE-SHA256SUMS.txt"
(
  cd "$SERVER_DIR"
  npm install --omit=dev --no-audit --no-fund
  npm run check
)

cat > "$ENV_FILE" <<EOF
DATABASE_URL=postgresql://$API_DB_USER:$API_DB_PASSWORD@127.0.0.1:$DB_PORT/$DB_NAME?sslmode=disable
ANI_BIND=127.0.0.1
PORT=$API_PORT
ANI_API_PEPPER=$API_PEPPER
ANI_ADMIN_BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN
ANI_ALLOWED_ORIGINS=
BLYNK_AUTH_TOKEN=$BLYNK_TOKEN
BLYNK_POWER_PIN=V0
EOF
chmod 600 "$ENV_FILE"
unset API_DB_PASSWORD API_PEPPER BOOTSTRAP_TOKEN BLYNK_TOKEN

cat > "$APP_DIR/start-api.sh" <<'START'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077
APP_DIR="$HOME/ani-games-stardesk-custom"
SERVER_DIR="$APP_DIR/server"
ENV_FILE="$SERVER_DIR/.env"
LOG_FILE="$APP_DIR/logs/api.log"
PID_FILE="$APP_DIR/api.pid"
[ -s "$ENV_FILE" ] && [ -s "$SERVER_DIR/server.mjs" ] || { echo "StarDesk API belum terpasang." >&2; exit 1; }
if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
    CMD="$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)"
    [[ "$CMD" == *"$SERVER_DIR/server.mjs"* ]] || { echo "PID file bukan proses StarDesk API; stop aman." >&2; exit 1; }
    curl -fsS "http://127.0.0.1:8789/health"
    exit 0
  fi
  rm -f "$PID_FILE"
fi
set -a
. "$ENV_FILE"
set +a
cd "$SERVER_DIR"
nohup "$PREFIX/bin/node" "$SERVER_DIR/server.mjs" >> "$LOG_FILE" 2>&1 < /dev/null &
PID=$!
printf '%s\n' "$PID" > "$PID_FILE"
for _ in $(seq 1 25); do
  if curl -fsS "http://127.0.0.1:8789/health" >/dev/null 2>&1; then
    echo "StarDesk Custom API online di 127.0.0.1:8789"
    exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 1
done
echo "StarDesk API gagal sehat. Log: $LOG_FILE" >&2
tail -n 40 "$LOG_FILE" >&2 || true
exit 1
START
cat > "$APP_DIR/stop-api.sh" <<'STOP'
#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
APP_DIR="$HOME/ani-games-stardesk-custom"
SERVER_DIR="$APP_DIR/server"
PID_FILE="$APP_DIR/api.pid"
[ -f "$PID_FILE" ] || { echo "StarDesk API tidak memiliki PID file."; exit 0; }
PID="$(cat "$PID_FILE")"
[[ "$PID" =~ ^[0-9]+$ ]] || { echo "PID tidak valid; tidak dihentikan." >&2; exit 1; }
kill -0 "$PID" 2>/dev/null || { rm -f "$PID_FILE"; echo "StarDesk API sudah berhenti."; exit 0; }
CMD="$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)"
[[ "$CMD" == *"$SERVER_DIR/server.mjs"* ]] || { echo "PID bukan proses StarDesk API; tidak dihentikan." >&2; exit 1; }
kill -TERM "$PID"
for _ in $(seq 1 15); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
kill -0 "$PID" 2>/dev/null && { echo "API belum berhenti; tidak ada proses lain disentuh." >&2; exit 1; }
rm -f "$PID_FILE"
echo "StarDesk Custom API dihentikan."
STOP
chmod 700 "$APP_DIR/start-api.sh" "$APP_DIR/stop-api.sh"

log "Memulai API baru pada port $API_PORT; API lama port 8788 tetap berjalan."
"$APP_DIR/start-api.sh" >/dev/null

printf '\nOwner database StarDesk baru dibuat terpisah dari Owner sistem lama.\n'
printf 'Untuk memakai kredensial yang sama, masukkan username dan password Owner lama di sini.\n'
printf 'Username Owner: '
IFS= read -r OWNER_USERNAME </dev/tty
[ "${#OWNER_USERNAME}" -ge 3 ] && [ "${#OWNER_USERNAME}" -le 120 ] || die "Username Owner tidak valid."
printf 'Password Owner (minimal 12 karakter, input disembunyikan): ' >/dev/tty
IFS= read -r -s OWNER_PASSWORD </dev/tty
printf '\n' >/dev/tty
[ "${#OWNER_PASSWORD}" -ge 12 ] || die "Password Owner minimal 12 karakter."
printf 'Nama organisasi/rental StarDesk: '
IFS= read -r OWNER_ORG </dev/tty
[ "${#OWNER_ORG}" -ge 2 ] && [ "${#OWNER_ORG}" -le 120 ] || die "Nama organisasi tidak valid."

set -a
. "$ENV_FILE"
set +a
export OWNER_USERNAME OWNER_PASSWORD OWNER_ORG ANI_ADMIN_BOOTSTRAP_TOKEN
node --input-type=module <<'NODE'
const url='http://127.0.0.1:8789/api/admin/bootstrap';
const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({
  username:process.env.OWNER_USERNAME,password:process.env.OWNER_PASSWORD,org_name:process.env.OWNER_ORG
})});
const d=await r.json().catch(()=>({}));
if(!r.ok||d.ok!==true) {
  process.stderr.write('OWNER_BOOTSTRAP_FAILED:' + String(d.error||r.status) + '\n');
  process.exit(1);
}
process.stdout.write('OWNER_BOOTSTRAP_OK role=' + String(d.role||'') + '\n');
NODE
unset OWNER_USERNAME OWNER_PASSWORD OWNER_ORG ANI_ADMIN_BOOTSTRAP_TOKEN
# Bootstrap is one-time; remove its token from the runtime environment and restart.
ENV_TMP="$ENV_FILE.tmp"
grep -v '^ANI_ADMIN_BOOTSTRAP_TOKEN=' "$ENV_FILE" > "$ENV_TMP"
chmod 600 "$ENV_TMP"
mv "$ENV_TMP" "$ENV_FILE"
"$APP_DIR/stop-api.sh" >/dev/null
"$APP_DIR/start-api.sh" >/dev/null

log "Memverifikasi login Owner dan kedua RPC sebelum selesai..."
set -a
. "$ENV_FILE"
set +a
export OWNER_USERNAME OWNER_PASSWORD
node --input-type=module <<'NODE'
const base='http://127.0.0.1:8789';
const login=await fetch(base+'/auth/v1/token?grant_type=password',{
 method:'POST',headers:{'content-type':'application/json'},
 body:JSON.stringify({username:process.env.OWNER_USERNAME,password:process.env.OWNER_PASSWORD})
});
const session=await login.json().catch(()=>({}));
if(!login.ok||!session.access_token)throw new Error('OWNER_LOGIN_SMOKE_FAILED');
const token=session.access_token;
const call=async (name,body={})=>{
 const r=await fetch(base+'/rest/v1/rpc/'+name,{
  method:'POST',headers:{'content-type':'application/json',authorization:'Bearer '+token},
  body:JSON.stringify(body)
 });
 const data=await r.json().catch(()=>({}));
 if(!r.ok)throw new Error(name+'_SMOKE_FAILED_'+r.status+'_'+String(data.message||data.error||''));
 return data;
};
const context=await call('admin_context');
if(!context || !(context.orgs?.length>0))throw new Error('OWNER_CONTEXT_EMPTY');
const dashboard=await call('androiddb_v0_admin_dashboard',{p_limit:100});
if(!dashboard || dashboard.ok!==true)throw new Error('COIN_V0_DASHBOARD_SMOKE_FAILED');
await fetch(base+'/auth/v1/logout',{method:'POST',headers:{authorization:'Bearer '+token}});
process.stdout.write(JSON.stringify({
 owner_login:'ok',owner_context:'ok',admin_context:'ok',
 coin_v0_dashboard:'ok',database:'ani_games_stardesk_custom',api_port:8789
})+'\n');
NODE
unset OWNER_USERNAME OWNER_PASSWORD

# Confirm the old system DB identity remains present and unmodified by this installer.
OLD_DB_OID_AFTER="$(psql_admin -d postgres -Atqc "SELECT oid FROM pg_database WHERE datname='$OLD_DB_NAME'")"
OLD_CONN_AFTER="$(psql_admin -d "$OLD_DB_NAME" -Atqc "SELECT current_database() || '|' || current_user")"
[ "$OLD_DB_OID_BEFORE" = "$OLD_DB_OID_AFTER" ] || die "Database lama berubah identitas OID; hentikan dan audit."
[ "$OLD_CONN_BEFORE" = "$OLD_CONN_AFTER" ] || die "Koneksi metadata DB lama berubah; hentikan dan audit."

log "SELESAI: DB StarDesk terisolasi, API 8789, Owner login, admin_context dan Coin v0 dashboard lulus."
log "DB lama $OLD_DB_NAME tidak disentuh; API lama 8788 tetap berjalan."
log "API config: $ENV_FILE (izin 600); log: $LOG_DIR/api.log"
log "Start: $APP_DIR/start-api.sh | Stop: $APP_DIR/stop-api.sh"
log "Database baru ini berbagi proses PostgreSQL yang sama tetapi database, roles API, dan data sepenuhnya terpisah."
