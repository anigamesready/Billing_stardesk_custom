#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

PREFIX="$(printenv PREFIX 2>/dev/null || true)"
[ -n "$PREFIX" ] && [ -x "$PREFIX/bin/pkg" ] || { echo "Khusus Termux Android." >&2; exit 1; }

DB_NAME="stardesk_custom_v0"
DB_PORT="5432"
API_PORT="8789"
OWNER_ROLE="stardesk_v0_owner"
RUNTIME_ROLE="stardesk_v0_runtime"
API_LOGIN_ROLE="stardesk_v0_login"
APP_DIR="$HOME/ani-games-stardesk-custom-v0"
SERVER_DIR="$APP_DIR/server"
ENV_FILE="$SERVER_DIR/.env"
SERVICE_NAME="stardesk-custom-v0-api"
SERVICE_DIR="$PREFIX/var/service/$SERVICE_NAME"
BACKUP_ROOT="$HOME/ani-games-stardesk-backups"
REPO="anigamesready/Billing_stardesk_custom"
PG_ADMIN_USER=""

log(){ printf '[STAR-DESK-USERID-UPDATE] %s\n' "$*"; }
die(){ printf '[STAR-DESK-USERID-UPDATE] STOP: %s\n' "$*" >&2; exit 1; }
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

[ -r /dev/tty ] || die "Jalankan dari terminal Termux interaktif."
for bin in node psql pg_isready pg_dump pg_dumpall pg_restore curl sha256sum readlink sv; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."
done
[ -s "$SERVER_DIR/server.mjs" ] && [ -s "$ENV_FILE" ] || die "API StarDesk v0 tidak ditemukan."
[ -x "$SERVICE_DIR/run" ] || die "Service StarDesk $SERVICE_NAME tidak ditemukan."

# Load the existing dedicated API configuration; never create or rotate credentials.
set -a
. "$ENV_FILE"
set +a
DATABASE_URL="$(printenv DATABASE_URL 2>/dev/null || true)"
ANI_API_PEPPER="$(printenv ANI_API_PEPPER 2>/dev/null || true)"
PORT="$(printenv PORT 2>/dev/null || true)"
ANI_BIND="$(printenv ANI_BIND 2>/dev/null || true)"
[ "$PORT" = "$API_PORT" ] || die "PORT pada .env bukan 8789."
[ "$ANI_BIND" = "127.0.0.1" ] || die "ANI_BIND harus 127.0.0.1."
[ -n "$ANI_API_PEPPER" ] || die "ANI_API_PEPPER tidak ada."

node --input-type=module - "$DATABASE_URL" "$DB_NAME" "$DB_PORT" <<'NODE'
import { URL } from "node:url";
const u = new URL(process.argv[2]);
const db = decodeURIComponent(u.pathname.replace(/^\//, ""));
if (!["127.0.0.1","localhost","::1"].includes(u.hostname) ||
    (u.port || "5432") !== process.argv[4] ||
    db !== process.argv[3] ||
    !["postgres:","postgresql:"].includes(u.protocol)) {
  process.stderr.write("DATABASE_TARGET_NOT_STARDESK_CUSTOM_V0\n");
  process.exit(2);
}
NODE

# Use only the PostgreSQL cluster already running in this Termux environment.
PGDATA="$PREFIX/var/lib/postgresql"
if [ -f "$HOME/.postgres/postgresql.conf" ]; then PGDATA="$HOME/.postgres"; fi
[ -s "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL Termux tidak ditemukan."
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL belum aktif. Updater tidak akan menyalakannya."
EXPECTED_PGDATA="$(readlink -f "$PGDATA")"
OS_DB_USER="$(id -un)"
for candidate in "$OS_DB_USER" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null | grep -qx t; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Superuser PostgreSQL lokal tidak ditemukan."
SERVER_PGDATA="$(psql_admin -d postgres -Atqc "SHOW data_directory")"
[ "$EXPECTED_PGDATA" = "$(readlink -f "$SERVER_PGDATA")" ] || die "Cluster aktif bukan PGDATA Termux yang diharapkan."
CLUSTER_MAJOR="$(cut -d. -f1 "$PGDATA/PG_VERSION")"
SERVER_MAJOR="$(psql_admin -d postgres -Atqc "SELECT current_setting('server_version_num')::int / 10000")"
[ "$CLUSTER_MAJOR" = "$SERVER_MAJOR" ] || die "Major PostgreSQL tidak cocok."

DB_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
OWNER_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$OWNER_ROLE' AND NOT rolcanlogin")"
RUNTIME_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$RUNTIME_ROLE' AND NOT rolcanlogin")"
LOGIN_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$API_LOGIN_ROLE' AND rolcanlogin")"
[ "$DB_EXISTS" = "1" ] && [ "$OWNER_EXISTS" = "1" ] && [ "$RUNTIME_EXISTS" = "1" ] && [ "$LOGIN_EXISTS" = "1" ] || die "Database/role StarDesk v0 tidak cocok."
[ "$(psql_admin -d postgres -Atqc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB_NAME'")" = "$OWNER_ROLE" ] || die "Owner database StarDesk tidak cocok."
sv status "$SERVICE_NAME" 2>&1 | grep -q '^run:' || die "Service API StarDesk belum berjalan."

# Confirm exactly one running API process from the dedicated folder and .env.
API_PID="$(node --input-type=module - "$SERVER_DIR" "$DATABASE_URL" "$ANI_API_PEPPER" "$API_PORT" <<'NODE'
import fs from "node:fs";
const dir=fs.realpathSync(process.argv[2]);
const expected={DATABASE_URL:process.argv[3],ANI_API_PEPPER:process.argv[4],PORT:process.argv[5]};
const found=[];
for(const name of fs.readdirSync("/proc")){
  if(!/^[0-9]+$/.test(name)) continue;
  try{
    const base="/proc/"+name;
    if(fs.realpathSync(base+"/cwd")!==dir) continue;
    const argv=fs.readFileSync(base+"/cmdline").toString().split("\0").filter(Boolean);
    if(!argv.some(x=>x.split("/").at(-1)==="server.mjs")) continue;
    const env=Object.fromEntries(fs.readFileSync(base+"/environ").toString().split("\0").filter(Boolean).map(x=>{const i=x.indexOf("=");return[x.slice(0,i),x.slice(i+1)];}));
    if(env.DATABASE_URL!==expected.DATABASE_URL || env.ANI_API_PEPPER!==expected.ANI_API_PEPPER ||
       env.PORT!==expected.PORT || env.ANI_BIND!=="127.0.0.1"){
      process.stderr.write("STAR_DESK_API_PROCESS_ENV_MISMATCH\n");process.exit(3);
    }
    found.push(name);
  }catch{}
}
if(found.length!==1){process.stderr.write("EXPECTED_ONE_STAR_DESK_API_PROCESS_FOUND_"+found.length+"\n");process.exit(4);}
process.stdout.write(found[0]);
NODE
)" || die "Proses API StarDesk tidak dapat diidentifikasi dengan pasti."
[ -n "$API_PID" ] || die "PID API StarDesk tidak ditemukan."

curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "http://127.0.0.1:$API_PORT/health" > "$PREFIX/tmp/stardesk-userid-health-before.json" || die "Health API StarDesk gagal."
node --input-type=module - "$PREFIX/tmp/stardesk-userid-health-before.json" <<'NODE'
import fs from "node:fs";
const h=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
if(h.api!=="online"||h.database!=="online") process.exit(2);
NODE

V0_STATE="$(psql_admin -d "$DB_NAME" -At -F '|' -c "
SELECT
 (to_regnamespace('androiddb_v0') IS NOT NULL)::int,
 (SELECT count(*) FROM unnest(ARRAY[
  to_regclass('androiddb_v0.rental_accounts'),to_regclass('androiddb_v0.client_credentials'),
  to_regclass('androiddb_v0.client_sessions'),to_regclass('androiddb_v0.coin_wallets'),
  to_regclass('androiddb_v0.coin_topup_orders'),to_regclass('androiddb_v0.coin_lots'),
  to_regclass('androiddb_v0.coin_ledger'),to_regclass('androiddb_v0.pc_coin_rates'),
  to_regclass('androiddb_v0.stardesk_device_links'),to_regclass('androiddb_v0.host_permissions'),
  to_regclass('androiddb_v0.host_enrollments'),to_regclass('androiddb_v0.host_registrations'),
  to_regclass('androiddb_v0.sessions'),to_regclass('androiddb_v0.audit_events')
 ]) AS u(name) WHERE u.name IS NOT NULL),
 to_regprocedure('api.androiddb_v0_remote_login(text,text,text)') IS NOT NULL,
 to_regclass('private.stardesk_custom_install_meta') IS NOT NULL
")"
IFS='|' read -r V0_SCHEMA V0_TABLES LEGACY_LOGIN INSTALL_META <<< "$V0_STATE"
[ "$V0_SCHEMA" = "1" ] && [ "$V0_TABLES" = "14" ] && [ "$LEGACY_LOGIN" = "t" ] && [ "$INSTALL_META" = "t" ] || die "Signature StarDesk v0 harus lengkap: schema, 14 tabel, login lama, dan metadata."

SOURCE_REF="$(printenv ANI_STARDESK_SOURCE_REF 2>/dev/null || true)"
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_STARDESK_SOURCE_REF harus SHA commit 40 karakter."
TMP_DIR="$(mktemp -d "$PREFIX/tmp/stardesk-userid-update.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT
curl --fail --location --silent --show-error "https://raw.githubusercontent.com/$REPO/$SOURCE_REF/backend/android-db/migrations/026_androiddb_v0_userid_only_remote_login.sql" -o "$TMP_DIR/026.sql"
curl --fail --location --silent --show-error "https://raw.githubusercontent.com/$REPO/$SOURCE_REF/backend/android-db/server/server.mjs" -o "$TMP_DIR/server.mjs"
[ -s "$TMP_DIR/026.sql" ] && [ -s "$TMP_DIR/server.mjs" ] || die "Source update tidak lengkap."
grep -q "api.androiddb_v0_remote_login(text,text)" "$TMP_DIR/026.sql" || die "Migrasi User ID-only tidak cocok."
grep -q 'SELECT api.androiddb_v0_remote_login($1::text,$2::text) AS result' "$TMP_DIR/server.mjs" || die "Source API belum memakai RPC dua parameter."
grep -q 'callRateLimit(key,5)' "$TMP_DIR/server.mjs" || die "Rate limit login tidak ditemukan."
node --check --input-type=module < "$TMP_DIR/server.mjs" || die "Syntax API baru tidak valid."
sha256sum "$TMP_DIR/026.sql" "$TMP_DIR/server.mjs" > "$TMP_DIR/SOURCE-SHA256SUMS.txt"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$HOME/ani-games-stardesk-backups/$DB_NAME-userid-only-$STAMP"
API_BACKUP_DIR="$BACKUP_DIR/api"
mkdir -p "$API_BACKUP_DIR"
chmod 700 "$HOME/ani-games-stardesk-backups" "$BACKUP_DIR" "$API_BACKUP_DIR"
log "Membuat backup database StarDesk + role cluster..."
pg_dump -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -d "$DB_NAME" -Fc -f "$BACKUP_DIR/database.dump"
pg_dumpall -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" --globals-only -f "$BACKUP_DIR/cluster-roles.sql"
pg_restore --list "$BACKUP_DIR/database.dump" > "$BACKUP_DIR/restore-list.txt"
[ -s "$BACKUP_DIR/restore-list.txt" ] && [ -s "$BACKUP_DIR/cluster-roles.sql" ] || die "Backup tidak lengkap."
cp -p "$SERVER_DIR/server.mjs" "$API_BACKUP_DIR/server.mjs"
chmod 600 "$BACKUP_DIR/database.dump" "$BACKUP_DIR/cluster-roles.sql" "$BACKUP_DIR/restore-list.txt" "$API_BACKUP_DIR/server.mjs"
sha256sum "$BACKUP_DIR/database.dump" "$BACKUP_DIR/cluster-roles.sql" "$BACKUP_DIR/restore-list.txt" "$API_BACKUP_DIR/server.mjs" > "$BACKUP_DIR/SHA256SUMS.txt"
(cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS.txt >/dev/null) || die "Checksum backup gagal."

printf '\nTarget: %s\nAPI: 127.0.0.1:%s (%s)\nMigration: 026 User ID-only login\nBackup: %s\n' "$DB_NAME" "$API_PORT" "$SERVICE_NAME" "$BACKUP_DIR"
printf 'Database/API Ani Games lama tidak disentuh.\nKetik APPLY untuk menerapkan perubahan StarDesk: '
read -r CONFIRM < /dev/tty
[ "$CONFIRM" = "APPLY" ] || die "Dibatalkan. Tidak ada perubahan."

log "Menerapkan migrasi additive 026 sebagai pemilik database StarDesk..."
{
  printf 'SET ROLE %s;\n' "$OWNER_ROLE"
  sed "s/ani_api_runtime/$RUNTIME_ROLE/g" "$TMP_DIR/026.sql"
} | psql_admin -d "$DB_NAME"

psql_admin -d "$DB_NAME" -v source_ref="$SOURCE_REF" <<'SQL' >/dev/null
SET ROLE stardesk_v0_owner;
UPDATE private.stardesk_custom_install_meta
SET schema_version='androiddb_v0_026', source_ref=:'source_ref'
WHERE singleton IS TRUE;
SQL

POST_STATE="$(psql_admin -d "$DB_NAME" -At -F '|' -c "
SELECT
 to_regprocedure('api.androiddb_v0_remote_login(text,text)') IS NOT NULL,
 has_function_privilege('stardesk_v0_runtime','api.androiddb_v0_remote_login(text,text)','EXECUTE'),
 (SELECT pg_get_userbyid(proowner)='stardesk_v0_owner' FROM pg_proc WHERE oid='api.androiddb_v0_remote_login(text,text)'::regprocedure),
 (SELECT schema_version='androiddb_v0_026' FROM private.stardesk_custom_install_meta WHERE singleton IS TRUE),
 has_table_privilege('stardesk_v0_runtime','androiddb_v0.rental_accounts','SELECT') IS FALSE,
 has_table_privilege('stardesk_v0_runtime','androiddb_v0.client_sessions','SELECT') IS FALSE
")"
[ "$POST_STATE" = "t|t|t|t|t|t" ] || die "Verifikasi migrasi 026 gagal: $POST_STATE"

log "Memasang source API StarDesk yang sudah memakai RPC dua parameter..."
cp "$TMP_DIR/server.mjs" "$SERVER_DIR/server.mjs.new"
chmod 600 "$SERVER_DIR/server.mjs.new"
node --check --input-type=module < "$SERVER_DIR/server.mjs.new" || die "Syntax API baru gagal."
mv -f "$SERVER_DIR/server.mjs.new" "$SERVER_DIR/server.mjs"

rollback_api(){
  log "Memulihkan source API lama; hanya service StarDesk yang akan di-restart."
  cp -p "$API_BACKUP_DIR/server.mjs" "$SERVER_DIR/server.mjs"
  sv restart "$SERVICE_NAME" >/dev/null 2>&1 || sv up "$SERVICE_NAME" >/dev/null 2>&1 || true
}
log "Restart hanya API StarDesk..."
if ! sv restart "$SERVICE_NAME"; then rollback_api; die "Restart gagal; source API lama dipulihkan."
fi

HEALTH=0
for _ in $(seq 1 30); do
  if curl --fail --silent --connect-timeout 2 --max-time 5 "http://127.0.0.1:$API_PORT/health" > "$TMP_DIR/health.json" 2>/dev/null &&
     node --input-type=module - "$TMP_DIR/health.json" <<'NODE'
import fs from "node:fs";
const h=JSON.parse(fs.readFileSync(process.argv[2],"utf8"));
if(h.api!=="online"||h.database!=="online") process.exit(2);
NODE
  then HEALTH=1; break; fi
  sleep 1
done
if [ "$HEALTH" != "1" ]; then rollback_api; die "API StarDesk tidak sehat setelah update. Source lama dipulihkan."
fi

set +e
node --input-type=module - "$API_PORT" <<'NODE'
const port=Number(process.argv[2]);
const url="http://127.0.0.1:"+port+"/rest/v1/rpc/androiddb_v0_remote_login";
const r=await fetch(url,{
  method:"POST",headers:{"content-type":"application/json"},
  body:JSON.stringify({p_rental_code:"STAR-DESK-UPDATE-PROBE-NOT-REAL",p_client_install_id:"stardesk-update-probe-0001"}),
  signal:AbortSignal.timeout(5000)
});
const d=await r.json().catch(()=>({}));
if(r.status!==401 || d.error!=="ANDROIDDB_V0_INVALID_CREDENTIALS"){
  process.stderr.write("STAR_DESK_USER_ID_RPC_PROBE_FAILED:"+r.status+":"+String(d.error||d.message||"")+"\n");
  process.exit(2);
}
NODE
PROBE_STATUS=$?
set -e
if [ "$PROBE_STATUS" != "0" ]; then rollback_api; die "Route User ID-only belum lolos probe. Source API lama dipulihkan."
fi

sv status "$SERVICE_NAME" || true
log "UPDATE BERHASIL: $DB_NAME + API 8789 memakai User ID-only."
log "Backup database/roles dan source API: $BACKUP_DIR"
log "Database, API, relay, dan service Ani Games Ready lama tidak disentuh."
