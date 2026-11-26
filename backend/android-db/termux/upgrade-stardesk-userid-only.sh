#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# One-time safe upgrade for an existing StarDesk Custom Termux installation.
# - Only touches stardesk_custom_v0 and the StarDesk API service on port 8789.
# - Does not restart PostgreSQL or touch Ani Games Ready legacy DB/API/Relay.
# - Includes Coin x100 migration 026 when still required, then User ID-only migration 027.
# - Backs up the StarDesk DB and current API source before an explicit APPLY.

DB_NAME="stardesk_custom_v0"
DB_OWNER_ROLE="stardesk_v0_owner"
RUNTIME_ROLE="stardesk_v0_runtime"
API_DB_USER="stardesk_v0_login"
DB_PORT="5432"
API_PORT="8789"
SERVICE_NAME="stardesk-custom-v0-api"
APP_DIR="$HOME/ani-games-stardesk-custom-v0"
SERVER_DIR="$APP_DIR/server"
SERVER_FILE="$SERVER_DIR/server.mjs"
PREFIX="${PREFIX:-}"
PGDATA="$HOME/../usr/var/lib/postgresql"
if [ -n "$PREFIX" ]; then PGDATA="$PREFIX/var/lib/postgresql"; fi
if [ -f "$HOME/.postgres/postgresql.conf" ]; then PGDATA="$HOME/.postgres"; fi
SOURCE_REF="${ANI_STARDESK_SOURCE_REF:-}"

log(){ printf '[STAR-DESK-USERID-ONLY] %s\n' "$*"; }
die(){ printf '[STAR-DESK-USERID-ONLY] STOP: %s\n' "$*" >&2; exit 1; }

[ -n "$PREFIX" ] && [ -x "$PREFIX/bin/psql" ] || die "Jalankan dari Termux Android."
[ -r /dev/tty ] || die "Jalankan dari sesi Termux interaktif agar konfirmasi APPLY bisa dibaca."
for bin in psql pg_isready pg_dump pg_restore curl sha256sum readlink date sed node sv; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia. Tidak ada perubahan."
done
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_STARDESK_SOURCE_REF wajib berisi SHA commit 40 karakter yang sama dengan updater ini."
[ -f "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL Termux tidak ditemukan. Script tidak akan membuat atau menyalakan cluster."
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL existing belum siap pada socket Termux. Script tidak akan restart PostgreSQL."
[ -s "$SERVER_FILE" ] || die "File API StarDesk aktif tidak ditemukan: $SERVER_FILE"
[ -d "$PREFIX/var/service/$SERVICE_NAME" ] || die "Service StarDesk API tidak ditemukan: $SERVICE_NAME"

PG_ADMIN_USER=""
for candidate in "$(id -un)" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null | grep -qx t; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Superuser PostgreSQL lokal tidak ditemukan."
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

SERVER_MAJOR="$(psql_admin -d postgres -Atqc "SELECT current_setting('server_version_num')::int / 10000")"
DUMP_MAJOR="$(pg_dump --version | sed -E 's/^pg_dump \(PostgreSQL\) ([0-9]+).*/\1/')"
[ "$SERVER_MAJOR" = "$DUMP_MAJOR" ] || die "Versi pg_dump ($DUMP_MAJOR) tidak cocok dengan PostgreSQL server ($SERVER_MAJOR)."
EXPECTED_PGDATA="$(readlink -f "$PGDATA")"
SERVER_PGDATA="$(psql_admin -d postgres -Atqc "SHOW data_directory")"
ACTUAL_PGDATA="$(readlink -f "$SERVER_PGDATA")"
[ -n "$EXPECTED_PGDATA" ] && [ "$EXPECTED_PGDATA" = "$ACTUAL_PGDATA" ] || die "Server yang merespons bukan cluster Termux yang dipilih."

DB_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
[ "$DB_EXISTS" = "1" ] || die "Database StarDesk $DB_NAME tidak ditemukan."
ROLE_OK="$(psql_admin -d postgres -Atqc "SELECT (EXISTS(SELECT 1 FROM pg_roles WHERE rolname='$DB_OWNER_ROLE' AND NOT rolcanlogin) AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname='$RUNTIME_ROLE' AND NOT rolcanlogin) AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname='$API_DB_USER' AND rolcanlogin))::int")"
[ "$ROLE_OK" = "1" ] || die "Identitas role StarDesk tidak cocok."

TABLES_OK="$(psql_admin -d "$DB_NAME" -Atqc "SELECT bool_and(to_regclass(x) IS NOT NULL)::int FROM unnest(ARRAY['androiddb_v0.rental_accounts','androiddb_v0.client_sessions','androiddb_v0.coin_wallets','androiddb_v0.coin_topup_orders','androiddb_v0.coin_lots','androiddb_v0.coin_ledger','androiddb_v0.sessions','androiddb_v0.pc_coin_rates']) x")"
[ "$TABLES_OK" = "1" ] || die "Schema Android DB v0 belum lengkap. Pastikan migrasi 025 pernah diterapkan."
ACTIVE_SESSIONS="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM androiddb_v0.sessions WHERE status IN ('requested','connecting','connected') AND settled_at IS NULL")"
[ "$ACTIVE_SESSIONS" = "0" ] || die "Masih ada $ACTIVE_SESSIONS sesi Coin aktif/pending. Akhiri sesi sebelum upgrade."

CURRENT_SCALE="1"
if [ "$(psql_admin -d "$DB_NAME" -Atqc "SELECT (to_regclass('androiddb_v0.coin_unit_config') IS NOT NULL)::int")" = "1" ]; then
  CURRENT_SCALE="$(psql_admin -d "$DB_NAME" -Atqc "SELECT coalesce((SELECT coin_scale::text FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE),'1')")"
fi
[ "$CURRENT_SCALE" = "1" ] || [ "$CURRENT_SCALE" = "100" ] || die "Skala Coin '$CURRENT_SCALE' tidak dikenal."
HAS_USERID_LOGIN="$(psql_admin -d "$DB_NAME" -Atqc "SELECT (to_regprocedure('api.androiddb_v0_remote_login(text,text)') IS NOT NULL AND to_regprocedure('api.androiddb_v0_remote_login(text,text,text)') IS NULL AND to_regprocedure('api.androiddb_v0_admin_issue_activation(text,uuid)') IS NULL AND to_regclass('androiddb_v0.client_credentials') IS NULL)::int")"

TMP_DIR="$(mktemp -d "$PREFIX/tmp/stardesk-userid-upgrade.XXXXXX")"
cleanup(){ [ -z "${TMP_DIR:-}" ] || [ ! -d "$TMP_DIR" ] || rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
API_TMP="$TMP_DIR/server.mjs"
MIGRATION_026="$TMP_DIR/026_androiddb_v0_coin_x100.sql"
MIGRATION_027="$TMP_DIR/027_androiddb_v0_remote_userid_only_login.sql"

log "Mengambil server StarDesk dan migrasi yang dipin pada commit $SOURCE_REF..."
BASE_URL="https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$SOURCE_REF"
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 90 "$BASE_URL/backend/android-db/server/server.mjs" -o "$API_TMP"
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 "$BASE_URL/backend/android-db/migrations/026_androiddb_v0_coin_x100.sql" -o "$MIGRATION_026"
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 "$BASE_URL/backend/android-db/migrations/027_androiddb_v0_remote_userid_only_login.sql" -o "$MIGRATION_027"
[ -s "$API_TMP" ] && [ -s "$MIGRATION_026" ] && [ -s "$MIGRATION_027" ] || die "Source API/migrasi kosong."
# Match the StarDesk-specific branding applied by the fresh installer.
sed -i \
  -e 's/Ani Games Ready Local Server/StarDesk Custom Local API/g' \
  -e 's/Setup Admin Ani Games Ready/Setup StarDesk Custom Owner/g' \
  -e 's/Database lokal Ani Games Ready. Blynk\\/WoL tidak disentuh./Database khusus StarDesk Custom. Database Ani Games Ready lama tidak disentuh./g' \
  -e 's/ani-games-ready-local-api/stardesk-custom-v0-api/g' \
  "$API_TMP"
grep -q 'StarDesk Custom Local API' "$API_TMP" || die "Branding API StarDesk tidak cocok."
node --check "$API_TMP"
grep -q 'api.androiddb_v0_remote_login($1::text,$2::text)' "$API_TMP" || die "API source bukan route login User ID-only."
grep -q 'androiddb_v0_remote_login(text,text)' "$MIGRATION_027" || die "Migrasi 027 tidak memuat login User ID-only."
grep -q 'DROP TABLE IF EXISTS androiddb_v0.client_credentials' "$MIGRATION_027" || die "Migrasi 027 tidak menghapus tabel aktivasi lama."
if grep -q 'androiddb_v0_admin_issue_activation:' "$API_TMP"; then
  die "Allowlist API masih mengandung RPC penerbit aktivasi Admin."
fi

BACKUP_DIR="$HOME/stardesk-backups/userid-only-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$HOME/stardesk-backups" "$BACKUP_DIR"
BACKUP_DB="$BACKUP_DIR/$DB_NAME-before-userid-only.dump"
BACKUP_API="$BACKUP_DIR/server.mjs.before-userid-only"
log "Membuat backup database StarDesk..."
pg_dump -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -d "$DB_NAME" --format=custom --no-owner --file="$BACKUP_DB"
[ -s "$BACKUP_DB" ] || die "Backup database gagal/berukuran nol."
pg_restore --list "$BACKUP_DB" >/dev/null || die "Validasi arsip backup gagal."
cp -p "$SERVER_FILE" "$BACKUP_API"
[ -s "$BACKUP_API" ] || die "Backup file API gagal."
sha256sum "$BACKUP_DB" "$BACKUP_API" > "$BACKUP_DIR/SHA256SUMS.txt"
log "Backup database: $BACKUP_DB"
log "Backup API source: $BACKUP_API"
log "Coin scale saat ini: $CURRENT_SCALE; User ID-only schema sudah aktif: $HAS_USERID_LOGIN"
log "Service target hanya $SERVICE_NAME (port $API_PORT). PostgreSQL tidak akan direstart."

printf '\nTutup aplikasi Admin dan Remote sebelum melanjutkan.\n'
printf 'Database target: %s. Backup database + server.mjs sudah tervalidasi.\n' "$DB_NAME"
printf 'Coin x100 akan diterapkan hanya bila skala saat ini 1. Migrasi 027 dan API login User ID-only akan diperbarui.\n'
printf 'Ketik APPLY untuk melanjutkan, atau selain itu untuk membatalkan: '
read -r CONFIRM </dev/tty
[ "$CONFIRM" = "APPLY" ] || die "Dibatalkan. Database/API belum diubah; backup tetap tersimpan."

if [ "$CURRENT_SCALE" = "1" ]; then
  log "Menerapkan Coin x100 migration 026..."
  { printf 'SET ROLE %s;\n' "$DB_OWNER_ROLE"; sed "s/ani_api_runtime/$RUNTIME_ROLE/g" "$MIGRATION_026"; } |
    psql_admin -d "$DB_NAME"
else
  log "Coin x100 sudah aktif. Migrasi 026 dilewati."
fi

if [ "$HAS_USERID_LOGIN" != "1" ]; then
  log "Menerapkan User ID-only login migration 027..."
  { printf 'SET ROLE %s;\n' "$DB_OWNER_ROLE"; sed "s/ani_api_runtime/$RUNTIME_ROLE/g" "$MIGRATION_027"; } |
    psql_admin -d "$DB_NAME"
else
  log "Database sudah memakai User ID-only login. Migrasi 027 dilewati."
fi

POST_OK="$(psql_admin -d "$DB_NAME" -Atqc "SELECT ( (SELECT coin_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE)=100 AND to_regprocedure('api.androiddb_v0_remote_login(text,text)') IS NOT NULL AND to_regprocedure('api.androiddb_v0_remote_login(text,text,text)') IS NULL AND to_regprocedure('api.androiddb_v0_admin_issue_activation(text,uuid)') IS NULL AND to_regclass('androiddb_v0.client_credentials') IS NULL )::int")"
[ "$POST_OK" = "1" ] || die "Verifikasi DB gagal. Backup tersedia di $BACKUP_DIR. API belum diganti."

API_NEW="$SERVER_DIR/server.mjs.userid-only-new"
cp "$API_TMP" "$API_NEW"
chmod 600 "$API_NEW"
node --check "$API_NEW"
mv -f "$API_NEW" "$SERVER_FILE"
chmod 600 "$SERVER_FILE"

log "Database siap. Mengaktifkan source API User ID-only..."
if "$PREFIX/bin/sv" status "$SERVICE_NAME" 2>&1 | grep -q '^run:'; then
  "$PREFIX/bin/sv" restart "$SERVICE_NAME" >/dev/null
else
  "$PREFIX/bin/sv" up "$SERVICE_NAME" >/dev/null
fi

HEALTH=""
for ((attempt=0; attempt<25; attempt++)); do
  HEALTH="$(curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "http://127.0.0.1:$API_PORT/health" 2>/dev/null || true)"
  if printf '%s' "$HEALTH" | grep -q '"api":"online"' && printf '%s' "$HEALTH" | grep -q '"database":"online"' &&
     "$PREFIX/bin/sv" status "$SERVICE_NAME" 2>&1 | grep -q '^run:'; then
    break
  fi
  sleep 1
done
if ! printf '%s' "$HEALTH" | grep -q '"api":"online"' || ! printf '%s' "$HEALTH" | grep -q '"database":"online"'; then
  die "API StarDesk belum sehat setelah restart. Jangan restart PostgreSQL atau service legacy. Periksa $PREFIX/var/log/sv/$SERVICE_NAME/current. Backup: $BACKUP_DIR"
fi

log "BERHASIL: Coin scale 100, login Remote cukup User ID, kode aktivasi Admin dihapus dari Android DB v0."
log "API StarDesk online di 127.0.0.1:$API_PORT; PostgreSQL dan Ani Games Ready lama tidak disentuh."
log "Backup lengkap: $BACKUP_DIR"
