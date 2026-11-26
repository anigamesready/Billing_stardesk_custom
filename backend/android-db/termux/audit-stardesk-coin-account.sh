#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

DB_NAME="stardesk_custom_v0"
DB_PORT="5432"
if [ "$#" -ge 1 ]; then TARGET_CODE="$1"; else TARGET_CODE="IRFAN19"; fi
TARGET_CODE="$(printf '%s' "$TARGET_CODE" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
PREFIX="$(printenv PREFIX 2>/dev/null || true)"
PG_ADMIN_USER=""

log(){ printf '[STAR-DESK-COIN-AUDIT] %s\n' "$*"; }
die(){ printf '[STAR-DESK-COIN-AUDIT] STOP: %s\n' "$*" >&2; exit 1; }
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

[ -n "$PREFIX" ] && [ -x "$PREFIX/bin/pkg" ] || die "Jalankan di Termux pada perangkat server StarDesk."
for bin in psql pg_isready readlink; do command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."; done
[[ "$TARGET_CODE" =~ ^[A-Z0-9_-]{3,40}$ ]] || die "User ID harus 3–40 karakter A-Z, angka, _ atau -."

PGDATA="$PREFIX/var/lib/postgresql"
if [ -f "$HOME/.postgres/postgresql.conf" ]; then PGDATA="$HOME/.postgres"; fi
[ -s "$PGDATA/PG_VERSION" ] || die "Cluster PostgreSQL Termux tidak ditemukan."
pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1 || die "PostgreSQL Termux belum siap."
EXPECTED_PGDATA="$(readlink -f "$PGDATA")"
for candidate in "$(id -un)" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname=current_user" 2>/dev/null | grep -qx t; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Akun PostgreSQL lokal untuk audit tidak ditemukan."
ACTUAL_PGDATA="$(readlink -f "$(psql_admin -d postgres -Atqc "SHOW data_directory")")"
[ "$EXPECTED_PGDATA" = "$ACTUAL_PGDATA" ] || die "Server PostgreSQL aktif bukan cluster Termux yang diharapkan."
DB_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
[ "$DB_EXISTS" = "1" ] || die "Database khusus $DB_NAME tidak ditemukan."

log "Database target: $DB_NAME"
log "Pencarian User ID: $TARGET_CODE"
log "Mode: READ ONLY — tidak membuat akun, memindahkan saldo, atau mengubah sesi."
psql_admin -d "$DB_NAME" -v target_code="$TARGET_CODE" -P pager=off <<'SQL'
BEGIN TRANSACTION READ ONLY;

SELECT
  'androiddb_v0' AS coin_domain,
  COALESCE((
    SELECT r.status
    FROM androiddb_v0.rental_accounts r
    WHERE upper(r.code)=:'target_code'
    LIMIT 1
  ),'NOT_FOUND') AS account_status,
  COALESCE((
    SELECT r.code
    FROM androiddb_v0.rental_accounts r
    WHERE upper(r.code)=:'target_code'
    LIMIT 1
  ),'—') AS matched_code,
  COALESCE((
    SELECT count(*)
    FROM androiddb_v0.rental_accounts r
    JOIN androiddb_v0.coin_wallets w ON w.rental_account_id=r.id
    JOIN androiddb_v0.coin_lots l ON l.wallet_id=w.id
    WHERE upper(r.code)=:'target_code' AND l.expires_at>now() AND l.remaining_coins>0
  ),0) AS active_coin_lots,
  COALESCE((
    SELECT sum(l.remaining_coins)
    FROM androiddb_v0.rental_accounts r
    JOIN androiddb_v0.coin_wallets w ON w.rental_account_id=r.id
    JOIN androiddb_v0.coin_lots l ON l.wallet_id=w.id
    WHERE upper(r.code)=:'target_code' AND l.expires_at>now()
  ),0) AS active_coin_balance

UNION ALL

SELECT
  'remote_play/public' AS coin_domain,
  COALESCE((
    SELECT r.status
    FROM public.rental_accounts r
    WHERE upper(r.code)=:'target_code'
    LIMIT 1
  ),'NOT_FOUND') AS account_status,
  COALESCE((
    SELECT r.code
    FROM public.rental_accounts r
    WHERE upper(r.code)=:'target_code'
    LIMIT 1
  ),'—') AS matched_code,
  COALESCE((
    SELECT count(*)
    FROM public.rental_accounts r
    JOIN remote_play.coin_wallets w ON w.rental_account_id=r.id
    JOIN remote_play.coin_lots l ON l.wallet_id=w.id
    WHERE upper(r.code)=:'target_code' AND l.expires_at>now() AND l.remaining_coins>0
  ),0) AS active_coin_lots,
  COALESCE((
    SELECT sum(l.remaining_coins)
    FROM public.rental_accounts r
    JOIN remote_play.coin_wallets w ON w.rental_account_id=r.id
    JOIN remote_play.coin_lots l ON l.wallet_id=w.id
    WHERE upper(r.code)=:'target_code' AND l.expires_at>now()
  ),0) AS active_coin_balance;

COMMIT;
SQL

log "Selesai. Hasil hanya menunjukkan domain, status akun, jumlah lot, dan saldo aktif."
