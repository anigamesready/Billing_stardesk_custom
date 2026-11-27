#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# Additive Remote User ID + Windows Agent inventory + encrypted StarDesk identity sync.
# Touches only stardesk_custom_v0 / port 8789 / stardesk-custom-v0-api.
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

log(){ printf '[STAR-DESK-REMOTE-SYNC-030] %s\n' "$*"; }
die(){ printf '[STAR-DESK-REMOTE-SYNC-030] STOP: %s\n' "$*" >&2; exit 1; }
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

[ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || die "Khusus Termux Android."
[ -r /dev/tty ] || die "Jalankan dari terminal interaktif Termux."
for bin in psql pg_isready node npm curl tar sha256sum readlink date sed sv grep; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia. Script tidak memasang atau memperbarui paket."
done
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_STARDESK_SOURCE_REF wajib SHA commit 40 karakter."
[ -f "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL Termux existing tidak ditemukan."
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL existing belum siap; tidak ada restart otomatis."
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
[ -n "$EXPECTED_PGDATA" ] && [ "$EXPECTED_PGDATA" = "$ACTUAL_PGDATA" ] || die "Cluster aktif tidak sama dengan PGDATA Termux yang diharapkan."

DB_OWNER="$(psql_admin -d postgres -Atqc "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname='$DB_NAME'")"
[ "$DB_OWNER" = "$DB_OWNER_ROLE" ] || die "Database $DB_NAME tidak dimiliki $DB_OWNER_ROLE."
ROLE_CHECK="$(psql_admin -d postgres -Atqc "SELECT count(*) FROM pg_roles WHERE rolname IN ('$DB_OWNER_ROLE','$RUNTIME_ROLE','$API_DB_USER')")"
[ "$ROLE_CHECK" = "3" ] || die "Role StarDesk isolated tidak lengkap."
META="$(psql_admin -d "$DB_NAME" -Atqc "SELECT schema_version||'|'||runtime_role||'|'||api_login_role FROM private.stardesk_custom_install_meta WHERE singleton")"
case "$META" in
  "androiddb_v0_028_manual_rates|$RUNTIME_ROLE|$API_DB_USER"|"androiddb_v0_030_agent_remote_sync|$RUNTIME_ROLE|$API_DB_USER") ;;
  *) die "Metadata tidak cocok untuk upgrade: $META" ;;
esac

TMP_DIR="$(mktemp -d "$PREFIX/tmp/stardesk-remote-sync-030.XXXXXX")"
cleanup(){ [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE="$TMP_DIR/source.tar.gz"
log "Mengambil source immutable $SOURCE_REF..."
curl --fail --location --silent --show-error \
  "https://codeload.github.com/anigamesready/Billing_stardesk_custom/tar.gz/$SOURCE_REF" -o "$ARCHIVE"
tar -tzf "$ARCHIVE" >/dev/null
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
SOURCE_ROOT="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
MIGRATION_LOGIN="$SOURCE_ROOT/backend/android-db/migrations/029_androiddb_v0_remote_userid_agent_inventory.sql"
MIGRATION_SYNC="$SOURCE_ROOT/backend/android-db/migrations/030_agent_remote_pc_sync.sql"
NEW_SERVER="$SOURCE_ROOT/backend/android-db/server/server.mjs"
[ -s "$MIGRATION_LOGIN" ] && [ -s "$MIGRATION_SYNC" ] && [ -s "$NEW_SERVER" ] || die "Source migration/API 029/030 tidak lengkap."
for rpc in androiddb_v0_agent_sync_stardesk_pairing androiddb_v0_admin_agent_list androiddb_v0_remote_dashboard androiddb_v0_remote_login; do
  grep -q "$rpc" "$NEW_SERVER" || die "RPC tidak ditemukan pada source API: $rpc"
done
grep -q "ANI_STARDESK_PAIRING_KEY" "$NEW_SERVER" || die "Encryption key tidak direferensikan oleh API."
node --check "$NEW_SERVER" || die "Syntax source API gagal sebelum database diubah."

log "Menerapkan migrasi 029 dan 030 hanya pada $DB_NAME..."
for file in "$MIGRATION_LOGIN" "$MIGRATION_SYNC"; do
  { printf 'SET ROLE %s;\n' "$DB_OWNER_ROLE"; cat "$file"; } | psql_admin -d "$DB_NAME" >/dev/null
done

BACKUP_DIR="$APP_DIR/backups"
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$SERVER_DIR/server.mjs" "$BACKUP_DIR/server.mjs.before-remote-sync-030.$STAMP"
cp "$NEW_SERVER" "$SERVER_DIR/server.mjs.new"
sed -i \
  -e 's/Ani Games Ready Local Server/StarDesk Custom Local API/g' \
  -e 's/Setup Admin Ani Games Ready/Setup StarDesk Custom Owner/g' \
  -e 's/Database lokal Ani Games Ready. Blynk\/WoL tidak disentuh./Database khusus StarDesk Custom. Database Ani Games Ready lama tidak disentuh./g' \
  -e 's/ani-games-ready-local-api/stardesk-custom-v0-api/g' \
  "$SERVER_DIR/server.mjs.new"
node --check --input-type=module < "$SERVER_DIR/server.mjs.new" || die "API baru gagal diperiksa; API lama tetap aktif."

# Create a dedicated random AES-256-GCM key only when the .env has none.
# The key remains on this Redmi and is never printed or stored in the DB.
if grep -q '^ANI_STARDESK_PAIRING_KEY=' "$ENV_FILE"; then
  KEY_VALUE="$(sed -n 's/^ANI_STARDESK_PAIRING_KEY=//p' "$ENV_FILE" | tail -n 1)"
  [ -n "$KEY_VALUE" ] || die "Key enkripsi lama kosong. Tidak akan mengganti key agar ciphertext yang sudah ada tetap dapat dibuka."
  printf '%s' "$KEY_VALUE" | node -e "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{const b=Buffer.from(s,'base64');process.exit(b.length===32&&b.toString('base64')===s?0:1)})" || die "Key enkripsi yang tersimpan bukan Base64 256-bit valid."
  unset KEY_VALUE
else
  KEY="$(node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('base64'))")"
  [ "${#KEY}" -ge 40 ] || die "Pembuatan key enkripsi gagal."
  cp "$ENV_FILE" "$BACKUP_DIR/.env.before-remote-sync-030.$STAMP"
  printf '\nANI_STARDESK_PAIRING_KEY=%s\n' "$KEY" >> "$ENV_FILE"
  unset KEY
fi
chmod 600 "$ENV_FILE"

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
  local rpc="$1" body="$TMP_DIR/rpc-$rpc.json" status
  status="$(curl --silent --show-error --connect-timeout 2 --max-time 6 \
    -o "$body" -w '%{http_code}' -X POST \
    -H 'content-type: application/json' --data '{}' \
    "http://127.0.0.1:$API_PORT/rest/v1/rpc/$rpc" 2>/dev/null || true)"
  [ "$status" = "401" ] && grep -q 'AUTH_REQUIRED' "$body"
}
if [ "$HEALTH" = "1" ]; then
  for rpc in androiddb_v0_admin_agent_list androiddb_v0_agent_sync_stardesk_pairing androiddb_v0_remote_dashboard androiddb_v0_remote_coin_wallet androiddb_v0_remote_coin_history; do
    if ! rpc_route_check "$rpc"; then
      HEALTH=0
      log "RPC $rpc gagal preflight (harus HTTP 401 AUTH_REQUIRED)."
      break
    fi
  done
fi
if [ "$HEALTH" != 1 ]; then
  log "API/preflight gagal; memulihkan server.mjs lama."
  cp "$BACKUP_DIR/server.mjs.before-remote-sync-030.$STAMP" "$SERVER_DIR/server.mjs"
  "$PREFIX/bin/sv" restart "$SERVICE_NAME" >/dev/null 2>&1 || true
  die "Upgrade API gagal. Migrasi 029/030 yang bersifat additive tetap ada; file API lama dipulihkan. Legacy DB/API/Relay/Billing tidak disentuh."
fi

psql_admin -d "$DB_NAME" -v source_ref="$SOURCE_REF" <<SQL >/dev/null
UPDATE private.stardesk_custom_install_meta
SET schema_version='androiddb_v0_030_agent_remote_sync',source_ref=:'source_ref'
WHERE singleton AND runtime_role='$RUNTIME_ROLE' AND api_login_role='$API_DB_USER';
SQL

log "Upgrade Remote + Agent sync 030 berhasil. API sehat, seluruh RPC protected lolos preflight."
log "Key verifikasi tersimpan hanya di $ENV_FILE; plaintext verification code tidak disimpan ke DB dan tidak dikirim ke Remote APK."
log "Target hanya $DB_NAME, API 8789 dan service $SERVICE_NAME. Legacy Billing 8788/DB/Relay tidak disentuh."
