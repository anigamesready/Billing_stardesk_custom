#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

# Safe, explicit upgrade for the already-installed StarDesk Custom database.
# It never starts/restarts PostgreSQL, never touches the legacy Ani Games DB,
# and does not restart the StarDesk API. Close Admin/Remote before applying.

DB_NAME="stardesk_custom_v0"
DB_OWNER_ROLE="stardesk_v0_owner"
RUNTIME_ROLE="stardesk_v0_runtime"
API_DB_USER="stardesk_v0_login"
DB_PORT="5432"
PREFIX="${PREFIX:-}"
PGDATA="$HOME/../usr/var/lib/postgresql"
if [ -n "$PREFIX" ]; then PGDATA="$PREFIX/var/lib/postgresql"; fi
if [ -f "$HOME/.postgres/postgresql.conf" ]; then PGDATA="$HOME/.postgres"; fi
SOURCE_REF="${ANI_STARDESK_SOURCE_REF:-}"

log(){ printf '[STAR-DESK-COIN-X100] %s\n' "$*"; }
die(){ printf '[STAR-DESK-COIN-X100] STOP: %s\n' "$*" >&2; exit 1; }

[ -n "$PREFIX" ] && [ -x "$PREFIX/bin/psql" ] || die "Jalankan dari Termux Android."
[ -r /dev/tty ] || die "Jalankan dari sesi Termux interaktif agar konfirmasi APPLY dapat dibaca."
for bin in psql pg_isready pg_dump pg_restore curl sha256sum readlink date sed; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia. Tidak ada perubahan database."
done
[[ "$SOURCE_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_STARDESK_SOURCE_REF wajib berisi SHA commit 40 karakter yang benar."
[ -f "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL Termux tidak ditemukan; script tidak akan initdb atau menyalakan service."
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL existing belum siap pada socket Termux. Script tidak akan restart PostgreSQL."

# Select only the already-running Termux cluster and prove server/data directory identity.
PG_ADMIN_USER=""
for candidate in "$(id -un)" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null | grep -qx t; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Superuser PostgreSQL lokal tidak ditemukan."
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }
SERVER_MAJOR="$(psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -d postgres -Atqc "SELECT current_setting('server_version_num')::int / 10000")"
DUMP_MAJOR="$(pg_dump --version | sed -E 's/^pg_dump \(PostgreSQL\) ([0-9]+).*/\1/')"
[ "$SERVER_MAJOR" = "$DUMP_MAJOR" ] || die "Versi pg_dump ($DUMP_MAJOR) tidak cocok dengan PostgreSQL server ($SERVER_MAJOR)."
EXPECTED_PGDATA="$(readlink -f "$PGDATA")"
SERVER_PGDATA="$(psql_admin -d postgres -Atqc "SHOW data_directory")"
ACTUAL_PGDATA="$(readlink -f "$SERVER_PGDATA")"
[ -n "$EXPECTED_PGDATA" ] && [ "$EXPECTED_PGDATA" = "$ACTUAL_PGDATA" ] || die "Server yang merespons bukan cluster Termux yang dipilih. Tidak ada perubahan."

DB_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
[ "$DB_EXISTS" = "1" ] || die "Database khusus StarDesk $DB_NAME tidak ditemukan."
ROLE_OK="$(psql_admin -d postgres -Atqc "SELECT (EXISTS(SELECT 1 FROM pg_roles WHERE rolname='$DB_OWNER_ROLE' AND NOT rolcanlogin) AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname='$RUNTIME_ROLE' AND NOT rolcanlogin) AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname='$API_DB_USER' AND rolcanlogin))::int")"
[ "$ROLE_OK" = "1" ] || die "Identitas role StarDesk tidak cocok. Tidak ada perubahan."

TABLES_OK="$(psql_admin -d "$DB_NAME" -Atqc "SELECT bool_and(to_regclass(x) IS NOT NULL)::int FROM unnest(ARRAY['androiddb_v0.coin_wallets','androiddb_v0.coin_topup_orders','androiddb_v0.coin_lots','androiddb_v0.coin_ledger','androiddb_v0.sessions','androiddb_v0.pc_coin_rates','androiddb_v0.rental_accounts']) x")"
[ "$TABLES_OK" = "1" ] || die "Schema Coin Android DB v0 belum lengkap. Pastikan migrasi 025 sudah pernah diterapkan."

CONFIG_EXISTS="$(psql_admin -d "$DB_NAME" -Atqc "SELECT (to_regclass('androiddb_v0.coin_unit_config') IS NOT NULL)::int")"
CURRENT_SCALE="1"
if [ "$CONFIG_EXISTS" = "1" ]; then
  CURRENT_SCALE="$(psql_admin -d "$DB_NAME" -Atqc "SELECT coalesce((SELECT coin_scale::text FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE),'1')")"
fi
if [ "$CURRENT_SCALE" = "100" ]; then
  log "Database sudah menggunakan Coin x100. Tidak ada pengalian ulang dan tidak ada perubahan."
  exit 0
fi
[ "$CURRENT_SCALE" = "1" ] || die "Skala Coin saat ini '$CURRENT_SCALE' tidak dikenali. Hentikan untuk audit manual."

ACTIVE_SESSIONS="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM androiddb_v0.sessions WHERE status IN ('requested','connecting','connected') AND settled_at IS NULL")"
[ "$ACTIVE_SESSIONS" = "0" ] || die "Masih ada $ACTIVE_SESSIONS sesi Coin aktif/pending. Tutup dan selesaikan sesi terlebih dahulu."

MIGRATION_FILE="$PREFIX/tmp/026_androiddb_v0_coin_x100.$$.sql"
cleanup(){ rm -f -- "$MIGRATION_FILE"; }
trap cleanup EXIT
MIGRATION_URL="https://raw.githubusercontent.com/anigamesready/Billing_stardesk_custom/$SOURCE_REF/backend/android-db/migrations/026_androiddb_v0_coin_x100.sql"
log "Mengambil migrasi terpin dari commit $SOURCE_REF..."
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 "$MIGRATION_URL" -o "$MIGRATION_FILE"
[ -s "$MIGRATION_FILE" ] || die "File migrasi kosong/tidak tersedia."
grep -q "androiddb_v0.coin_unit_config" "$MIGRATION_FILE" || die "File migrasi tidak cocok."
grep -q "p_amount_rupiah::numeric\*60\*unit_scale/8000" "$MIGRATION_FILE" || die "Rumus x100 tidak ditemukan di file migrasi."

# Capture exact totals before migration so the script can prove values were scaled once.
pre_sum(){ psql_admin -d "$DB_NAME" -Atqc "SELECT coalesce(sum($2),0)::numeric::text FROM $1"; }
PRE_WALLET="$(pre_sum androiddb_v0.coin_wallets balance)"
PRE_ORDER="$(pre_sum androiddb_v0.coin_topup_orders coin_amount)"
PRE_LOT_ORIGINAL="$(pre_sum androiddb_v0.coin_lots original_coins)"
PRE_LOT_REMAINING="$(pre_sum androiddb_v0.coin_lots remaining_coins)"
PRE_LEDGER_AMOUNT="$(pre_sum androiddb_v0.coin_ledger amount_coins)"
PRE_LEDGER_BALANCE="$(pre_sum androiddb_v0.coin_ledger balance_after)"
PRE_SESSION_RESERVED="$(pre_sum androiddb_v0.sessions reserved_coins)"
PRE_SESSION_DEBITED="$(pre_sum androiddb_v0.sessions debited_coins)"
PRE_RATE="$(pre_sum androiddb_v0.pc_coin_rates hourly_coins)"
PRE_RUPIAH="$(pre_sum androiddb_v0.coin_topup_orders amount_rupiah)"
PRE_WALLETS_COUNT="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM androiddb_v0.coin_wallets")"
PRE_ORDERS_COUNT="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM androiddb_v0.coin_topup_orders")"
PRE_LOTS_COUNT="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM androiddb_v0.coin_lots")"
PRE_LEDGER_COUNT="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM androiddb_v0.coin_ledger")"
PRE_SESSIONS_COUNT="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM androiddb_v0.sessions")"
PRE_RATES_COUNT="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM androiddb_v0.pc_coin_rates")"

BACKUP_DIR="$HOME/stardesk-backups/coin-x100-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$HOME/stardesk-backups" "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/$DB_NAME-before-coin-x100.dump"
log "Membuat backup database StarDesk (bukan database Ani Games Ready lama)..."
pg_dump -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -d "$DB_NAME" --format=custom --no-owner --file="$BACKUP_FILE"
[ -s "$BACKUP_FILE" ] || die "Backup database gagal/berukuran nol."
pg_restore --list "$BACKUP_FILE" >/dev/null || die "Validasi arsip backup gagal."
sha256sum "$BACKUP_FILE" > "$BACKUP_FILE.sha256"
log "Backup tervalidasi: $BACKUP_FILE"
log "SHA-256: $(cut -d' ' -f1 "$BACKUP_FILE.sha256")"
log "Ringkasan sebelum: wallet=$PRE_WALLET, topup_coin=$PRE_ORDER, lot_original=$PRE_LOT_ORIGINAL, ledger_amount=$PRE_LEDGER_AMOUNT, tarif_jam=$PRE_RATE, order_Rp=$PRE_RUPIAH"

printf '\nPENTING: tutup Admin Coin dan Remote lama/baru. Jangan ada sesi rental aktif.\n'
printf 'Database target hanya %s. PostgreSQL service dan database Ani Games Ready lama tidak disentuh.\n' "$DB_NAME"
printf 'Backup sudah dibuat dan tervalidasi. Untuk menerapkan konversi satu kali, ketik APPLY persis.\n'
printf 'Ketik selain APPLY untuk membatalkan (backup tetap disimpan): '
read -r CONFIRM </dev/tty
[ "$CONFIRM" = "APPLY" ] || die "Dibatalkan oleh pengguna. Database tidak diubah; backup tetap tersimpan."

log "Menerapkan migrasi Coin x100 dalam satu transaksi..."
{
  printf 'SET ROLE %s;\n' "$DB_OWNER_ROLE"
  sed "s/ani_api_runtime/$RUNTIME_ROLE/g" "$MIGRATION_FILE"
} | psql_admin -d "$DB_NAME"

POST_SCALE="$(psql_admin -d "$DB_NAME" -Atqc "SELECT coin_scale FROM androiddb_v0.coin_unit_config WHERE singleton IS TRUE")"
[ "$POST_SCALE" = "100" ] || die "Konfigurasi akhir bukan 100. Backup tersedia di $BACKUP_FILE."

assert_scaled(){
  label="$1"; table="$2"; column="$3"; before="$4"
  after="$(pre_sum "$table" "$column")"
  ok="$(psql_admin -d "$DB_NAME" -Atqc "SELECT (('$after'::numeric = '$before'::numeric * 100))::int")"
  [ "$ok" = "1" ] || die "Verifikasi x100 gagal pada $label. Backup tersedia di $BACKUP_FILE."
}
assert_count_unchanged(){
  table="$1"; before="$2"
  after="$(psql_admin -d "$DB_NAME" -Atqc "SELECT count(*) FROM $table")"
  [ "$after" = "$before" ] || die "Jumlah baris $table berubah. Backup tersedia di $BACKUP_FILE."
}
assert_scaled "wallet balance" androiddb_v0.coin_wallets balance "$PRE_WALLET"
assert_scaled "top-up coin amount" androiddb_v0.coin_topup_orders coin_amount "$PRE_ORDER"
assert_scaled "lot original" androiddb_v0.coin_lots original_coins "$PRE_LOT_ORIGINAL"
assert_scaled "lot remaining" androiddb_v0.coin_lots remaining_coins "$PRE_LOT_REMAINING"
assert_scaled "ledger amount" androiddb_v0.coin_ledger amount_coins "$PRE_LEDGER_AMOUNT"
assert_scaled "ledger balance_after" androiddb_v0.coin_ledger balance_after "$PRE_LEDGER_BALANCE"
assert_scaled "session reserved" androiddb_v0.sessions reserved_coins "$PRE_SESSION_RESERVED"
assert_scaled "session debited" androiddb_v0.sessions debited_coins "$PRE_SESSION_DEBITED"
assert_scaled "GPU hourly Coin" androiddb_v0.pc_coin_rates hourly_coins "$PRE_RATE"
POST_RUPIAH="$(pre_sum androiddb_v0.coin_topup_orders amount_rupiah)"
[ "$POST_RUPIAH" = "$PRE_RUPIAH" ] || die "Nominal Rupiah order berubah. Backup tersedia di $BACKUP_FILE."
assert_count_unchanged androiddb_v0.coin_wallets "$PRE_WALLETS_COUNT"
assert_count_unchanged androiddb_v0.coin_topup_orders "$PRE_ORDERS_COUNT"
assert_count_unchanged androiddb_v0.coin_lots "$PRE_LOTS_COUNT"
assert_count_unchanged androiddb_v0.coin_ledger "$PRE_LEDGER_COUNT"
assert_count_unchanged androiddb_v0.sessions "$PRE_SESSIONS_COUNT"
assert_count_unchanged androiddb_v0.pc_coin_rates "$PRE_RATES_COUNT"

log "BERHASIL: Android DB v0 sekarang memakai Coin x100; total Rupiah dan jumlah baris tetap."
log "Nilai konversi: Rp5.000=3.750; Rp10.000=7.500; Rp15.000=11.250; Rp20.000=15.000 AniCoin."
log "Tarif: GTX1050/GTX1660 4.500; RTX3060 5.250; RTX5060 6.000 AniCoin/jam."
log "Tidak perlu restart PostgreSQL atau API untuk perubahan fungsi SQL ini."
log "Backup tersimpan di: $BACKUP_FILE"
