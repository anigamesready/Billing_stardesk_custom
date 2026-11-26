#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

DB_NAME="stardesk_custom_v0"
DB_PORT="5432"
if [ "$#" -ge 1 ]; then TARGET_CODE="$1"; else TARGET_CODE="IRFAN19"; fi
TARGET_CODE="$(printf '%s' "$TARGET_CODE" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
PREFIX="$(printenv PREFIX 2>/dev/null || true)"
APP_DIR="$HOME/ani-games-stardesk-custom-v0"
API_FILE="$APP_DIR/server/server.mjs"
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
log "Pemeriksaan kontrak SQL dan versi schema:"
psql_admin -d "$DB_NAME" -P pager=off -At <<'SQL'
SELECT 'login_rpc_2_parameters|' || (to_regprocedure('api.androiddb_v0_remote_login(text,text)') IS NOT NULL)::text;
SELECT 'login_rpc_3_parameters|' || (to_regprocedure('api.androiddb_v0_remote_login(text,text,text)') IS NOT NULL)::text;
SELECT CASE
  WHEN to_regclass('private.stardesk_custom_install_meta') IS NULL THEN 'schema_version|METADATA_TABLE_MISSING'
  ELSE 'schema_version|' || COALESCE((SELECT schema_version FROM private.stardesk_custom_install_meta WHERE singleton IS TRUE),'UNKNOWN')
END;
SQL

if [ -s "$API_FILE" ]; then
  if grep -Fq "SELECT api.androiddb_v0_remote_login(\$1::text,\$2::text) AS result" "$API_FILE"; then
    log "API_SOURCE_HANDLER|USER_ID_ONLY_TWO_PARAMETERS"
  elif grep -Fq "SELECT api.androiddb_v0_remote_login(\$1::text,\$2::text,\$3::text) AS result" "$API_FILE"; then
    log "API_SOURCE_HANDLER|LEGACY_ACTIVATION_THREE_PARAMETERS"
  else
    log "API_SOURCE_HANDLER|UNRECOGNIZED — periksa server.mjs"
  fi
else
  log "API_SOURCE_HANDLER|SOURCE_FILE_NOT_FOUND at $API_FILE"
fi

V0_READY="$(psql_admin -d "$DB_NAME" -Atqc "SELECT
  to_regclass('androiddb_v0.rental_accounts') IS NOT NULL
  AND to_regclass('androiddb_v0.coin_wallets') IS NOT NULL
  AND to_regclass('androiddb_v0.coin_lots') IS NOT NULL")"
if [ "$V0_READY" = "t" ]; then
  log "Akun pada domain canonical androiddb_v0:"
  psql_admin -d "$DB_NAME" -v target_code="$TARGET_CODE" -P pager=off <<'SQL'
BEGIN TRANSACTION READ ONLY;
SELECT
  r.code,
  r.status,
  COALESCE((
    SELECT count(*)
    FROM androiddb_v0.coin_wallets w
    JOIN androiddb_v0.coin_lots l ON l.wallet_id=w.id
    WHERE w.rental_account_id=r.id AND l.expires_at>now() AND l.remaining_coins>0
  ),0) AS active_coin_lots,
  COALESCE((
    SELECT sum(l.remaining_coins)
    FROM androiddb_v0.coin_wallets w
    JOIN androiddb_v0.coin_lots l ON l.wallet_id=w.id
    WHERE w.rental_account_id=r.id AND l.expires_at>now()
  ),0) AS active_coin_balance
FROM androiddb_v0.rental_accounts r
WHERE upper(r.code)=:'target_code'
ORDER BY r.created_at;
SELECT 'androiddb_v0_account_lookup|' || CASE WHEN EXISTS(
  SELECT 1 FROM androiddb_v0.rental_accounts WHERE upper(code)=:'target_code'
) THEN 'FOUND' ELSE 'NOT_FOUND' END;
COMMIT;
SQL
else
  log "androiddb_v0|SCHEMA_OR_COIN_TABLES_NOT_INSTALLED"
fi

OLD_READY="$(psql_admin -d "$DB_NAME" -Atqc "SELECT
  to_regclass('public.rental_accounts') IS NOT NULL
  AND to_regclass('remote_play.coin_wallets') IS NOT NULL
  AND to_regclass('remote_play.coin_lots') IS NOT NULL")"
if [ "$OLD_READY" = "t" ]; then
  log "Akun pada domain Coin lama remote_play/public (bukan sumber login Remote v0.6.4):"
  psql_admin -d "$DB_NAME" -v target_code="$TARGET_CODE" -P pager=off <<'SQL'
BEGIN TRANSACTION READ ONLY;
SELECT
  r.code,
  r.status,
  COALESCE((
    SELECT count(*)
    FROM remote_play.coin_wallets w
    JOIN remote_play.coin_lots l ON l.wallet_id=w.id
    WHERE w.rental_account_id=r.id AND l.expires_at>now() AND l.remaining_coins>0
  ),0) AS active_coin_lots,
  COALESCE((
    SELECT sum(l.remaining_coins)
    FROM remote_play.coin_wallets w
    JOIN remote_play.coin_lots l ON l.wallet_id=w.id
    WHERE w.rental_account_id=r.id AND l.expires_at>now()
  ),0) AS active_coin_balance
FROM public.rental_accounts r
WHERE upper(r.code)=:'target_code'
ORDER BY r.created_at;
SELECT 'remote_play_public_account_lookup|' || CASE WHEN EXISTS(
  SELECT 1 FROM public.rental_accounts r
  WHERE upper(r.code)=:'target_code'
    AND EXISTS(SELECT 1 FROM remote_play.coin_wallets w WHERE w.rental_account_id=r.id)
) THEN 'FOUND_WITH_COIN_WALLET' ELSE 'NOT_FOUND_WITH_COIN_WALLET' END;
COMMIT;
SQL
else
  log "remote_play/public|OLD_COIN_DOMAIN_NOT_INSTALLED"
fi

log "Selesai. Kirim seluruh output ini; tidak ada rahasia/token/password yang dicetak."
