#!/data/data/com.termux/files/usr/bin/bash
set -Ee -o pipefail
umask 077

APP_DIR="$HOME/ani-games-ready-android-db"
SERVER_DIR="$APP_DIR/server"
MIGRATIONS_DIR="$APP_DIR/migrations"
ENV_FILE="$SERVER_DIR/.env"
DB_DEFAULT="ani_games_ready"
DB_PORT="5432"
if [ -n "$ANI_DB_NAME" ]; then DB_DEFAULT="$ANI_DB_NAME"; fi
if [ -n "$ANI_DB_PORT" ]; then DB_PORT="$ANI_DB_PORT"; fi
PGDATA="$PREFIX/var/lib/postgresql"
if [ -f "$HOME/.postgres/postgresql.conf" ]; then PGDATA="$HOME/.postgres"; fi
OS_DB_USER="$(id -un)"
NEW_DATABASE=0
NEW_CLUSTER=0
ENV_PRESENT=0

log(){ printf '[ANI-ANDROID-DB] %s\n' "$*"; }
die(){ printf '[ANI-ANDROID-DB] STOP: %s\n' "$*" >&2; exit 1; }
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

[ -n "$PREFIX" ] && [ -x "$PREFIX/bin/pkg" ] || die "Script ini khusus Termux Android."
[ -n "$ANI_DB_REF" ] || die "ANI_DB_REF harus berisi SHA commit 40 karakter yang dipin."
[[ "$ANI_DB_REF" =~ ^[0-9a-fA-F]{40}$ ]] || die "ANI_DB_REF wajib SHA commit 40 karakter (bukan branch bergerak)."
[[ "$DB_DEFAULT" =~ ^[A-Za-z0-9_]{1,50}$ ]] || die "Nama database tidak valid."
[[ "$DB_PORT" =~ ^[0-9]{1,5}$ ]] || die "Port database tidak valid."
[ -r /dev/tty ] || die "Jalankan dari terminal interaktif Termux."

log "Memeriksa versi PostgreSQL sebelum memasang/memperbarui paket..."
EXISTING_PG_CLUSTER=0
if [ -f "$PGDATA/PG_VERSION" ]; then
  EXISTING_PG_CLUSTER=1
  command -v postgres >/dev/null 2>&1 || die "Cluster PostgreSQL existing ditemukan tetapi binary postgres tidak tersedia. Tidak akan memasang binary baru di atas data lama secara otomatis."
  DATA_MAJOR="$(cat "$PGDATA/PG_VERSION" | tr -d '[:space:]')"
  SERVER_VERSION="$(postgres --version | awk '{print $NF}')"
  SERVER_MAJOR="$(printf '%s' "$SERVER_VERSION" | cut -d. -f1)"
  [ "$DATA_MAJOR" = "$SERVER_MAJOR" ] || die "Major version PostgreSQL tidak cocok (data=$DATA_MAJOR, binary=$SERVER_MAJOR). Tidak ada package upgrade, initdb, pg_upgrade atau migrasi yang dijalankan."
fi

log "Memasang runtime resmi Termux (Node LTS, npm, service manager)..."
pkg update -y
if [ "$EXISTING_PG_CLUSTER" = 1 ]; then
  # Do not request/upgrade the PostgreSQL package over a live data directory.
  pkg install -y nodejs-lts npm termux-services curl openssl procps termux-api
else
  pkg install -y postgresql nodejs-lts npm termux-services curl openssl procps termux-api
fi

mkdir -p "$HOME" "$APP_DIR" "$SERVER_DIR"
# Preserve an existing API .env and use its local database/port.
if [ -f "$ENV_FILE" ]; then
  ENV_PRESENT=1
  set -a
  . "$ENV_FILE"
  set +a
  [ -n "$DATABASE_URL" ] || die ".env lama tidak memiliki DATABASE_URL."
  DB_INFO="$(node --input-type=module -e '
    const u = new URL(process.env.DATABASE_URL);
    const db = decodeURIComponent(u.pathname.replace(/^\\//, ""));
    process.stdout.write([u.hostname,u.port || "5432",db].join("|"));
  ')"
  IFS='|' read -r DB_HOST DB_PORT DB_NAME <<< "$DB_INFO"
  if [ -z "$ANI_BIND" ]; then ANI_BIND="127.0.0.1"; fi
  case "$ANI_BIND" in 127.0.0.1|localhost|::1) ;; *) die "ANI_BIND harus loopback sebelum proses migrasi database."; esac
  if [ -z "$PORT" ]; then PORT="8787"; fi
  case "$DB_HOST" in 127.0.0.1|localhost|::1) ;; *) die "DATABASE_URL bukan database lokal Termux. Host luar tidak disentuh."; esac
else
  DB_HOST="127.0.0.1"
  DB_NAME="$DB_DEFAULT"
fi
[[ "$DB_PORT" =~ ^[0-9]{1,5}$ ]] || die "Port database di .env tidak valid."
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]{1,50}$ ]] || die "Nama database di .env tidak valid."

# Download an immutable source archive. Local .env and database files are never overwritten.
TMP_DIR="$(mktemp -d "$PREFIX/tmp/ani-db-install.XXXXXX")"
cleanup(){ rm -rf "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE="$TMP_DIR/source.tar.gz"
log "Mengambil source terpin $ANI_DB_REF..."
curl --fail --location --silent --show-error \
  "https://codeload.github.com/anigamesready/Billing_stardesk_custom/tar.gz/$ANI_DB_REF" \
  -o "$ARCHIVE"
tar -tzf "$ARCHIVE" >/dev/null
tar -xzf "$ARCHIVE" -C "$TMP_DIR"
SOURCE_ROOT="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -n "$SOURCE_ROOT" ] || die "Arsip source kosong."
[ -f "$SOURCE_ROOT/backend/android-db/server/server.mjs" ] || die "Source backend tidak ditemukan."
[ -f "$SOURCE_ROOT/backend/android-db/migrations/022_coin_unit_scale_100.sql" ] || die "Migrasi coin x100 tidak ada dalam source terpin."
cp -R "$SOURCE_ROOT/backend/android-db/server/." "$SERVER_DIR/"
mkdir -p "$MIGRATIONS_DIR"
cp -R "$SOURCE_ROOT/backend/android-db/migrations/." "$MIGRATIONS_DIR/"
chmod 700 "$APP_DIR" "$SERVER_DIR"
chmod 600 "$ENV_FILE" 2>/dev/null || true

# An existing live server is never re-initialized or launched twice.
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  if [ -d "$HOME/.postgres" ] && [ "$PGDATA" != "$HOME/.postgres" ] && find "$HOME/.postgres" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "Legacy PostgreSQL data ditemukan di ~/.postgres tetapi config tidak lengkap. Tidak akan membuat cluster baru."
  fi
  if pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1; then
    die "PostgreSQL aktif tetapi PGDATA tidak ditemukan di lokasi standar. Tidak akan initdb."
  fi
  if [ -d "$PGDATA" ] && find "$PGDATA" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    die "Direktori PostgreSQL ada tetapi bukan cluster yang dikenal. Tidak akan initdb/menimpa: $PGDATA"
  fi
  log "Cluster PostgreSQL belum ada. Membuat cluster baru..."
  mkdir -p "$PGDATA"
  initdb -D "$PGDATA" --username="$OS_DB_USER" --auth-local=trust --auth-host=scram-sha-256
  NEW_CLUSTER=1
fi

# Enable Termux runit service manager and packaged PostgreSQL service.
export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log"
mkdir -p "$SVDIR" "$LOGDIR" "$PREFIX/var/run"
if [ -f "$PREFIX/etc/profile.d/start-services.sh" ]; then
  . "$PREFIX/etc/profile.d/start-services.sh"
elif [ -x "$PREFIX/bin/service-daemon" ]; then
  "$PREFIX/bin/service-daemon" start >/dev/null 2>&1 || true
else
  die "termux-services/service-daemon tidak ditemukan."
fi
[ -x "$PREFIX/bin/sv" ] || die "runit sv command tidak ditemukan."
[ -d "$SVDIR/postgres" ] || die "Service PostgreSQL Termux tidak ditemukan."

if pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1; then
  if ! "$PREFIX/bin/sv" status postgres 2>&1 | grep -q '^run:'; then
    die "PostgreSQL sudah aktif tetapi tidak dikelola runit. Proses lama dibiarkan utuh; audit service diperlukan."
  fi
else
  "$PREFIX/bin/sv-enable" postgres >/dev/null 2>&1 || true
  "$PREFIX/bin/sv" up postgres >/dev/null 2>&1 || true
fi
READY=0
for _ in $(seq 1 40); do
  if pg_isready -h "$PREFIX/tmp" -p "$DB_PORT" >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
[ "$READY" = 1 ] || die "PostgreSQL belum siap. Cek: $PREFIX/var/log/sv/postgres/current"

# Find an existing local cluster superuser. Never use the API login for migrations.
PG_ADMIN_USER=""
for candidate in "$OS_DB_USER" postgres; do
  if psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$candidate" -d postgres -Atqc "SELECT 1" >/dev/null 2>&1; then
    PG_ADMIN_USER="$candidate"
    break
  fi
done
[ -n "$PG_ADMIN_USER" ] || die "Login superuser lokal gagal. Tidak ada perubahan skema yang dilakukan."

# If there is an existing cluster without this installer .env, select only one DB
# whose Android rental + Remote Play core signatures match. Ambiguity is a hard stop.
if [ "$NEW_CLUSTER" != "1" ] && [ "$ENV_PRESENT" != "1" ]; then
  MATCH_COUNT=0
  DISCOVERED_DB=""
  while IFS= read -r candidate; do
    [[ "$candidate" =~ ^[A-Za-z0-9_]{1,50}$ ]] || continue
    has_core="$(psql_admin -d "$candidate" -Atqc "SELECT (to_regclass('public.rental_accounts') IS NOT NULL AND to_regclass('public.devices') IS NOT NULL AND to_regclass('public.rental_sessions') IS NOT NULL AND to_regprocedure('private.admin_account_by_token(text)') IS NOT NULL)::int" 2>/dev/null || printf '0')"
    if [ "$has_core" = "1" ]; then
      MATCH_COUNT=$((MATCH_COUNT+1))
      DISCOVERED_DB="$candidate"
    fi
  done < <(psql_admin -d postgres -Atqc "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname<>'postgres' ORDER BY datname")
  if [ "$MATCH_COUNT" -eq 1 ]; then
    DB_NAME="$DISCOVERED_DB"
    log "Satu database Android DB cocok ditemukan: $DB_NAME"
  elif [ "$MATCH_COUNT" -gt 1 ]; then
    die "Ada beberapa database Android DB yang cocok. Tetapkan ANI_DB_NAME secara eksplisit; tidak ada database yang disentuh."
  else
    die "Cluster existing tidak memiliki satu database dengan signature rental/device/Remote Play yang dikenali. Tidak akan membuat database baru."
  fi
fi

DB_EXISTS="$(psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
if [ "$DB_EXISTS" != "1" ]; then
  if [ "$NEW_CLUSTER" != "1" ]; then
    die "Database '$DB_NAME' tidak ditemukan pada cluster PostgreSQL existing. Tidak akan membuat database baru atau mengalihkan data."
  fi
  log "Cluster PostgreSQL baru; membuat database awal $DB_NAME."
  createdb -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" "$DB_NAME"
  NEW_DATABASE=1
fi

apply_file(){
  file="$1"
  [ -f "$MIGRATIONS_DIR/$file" ] || die "File migrasi hilang: $file"
  log "Menerapkan $file"
  psql_admin -d "$DB_NAME" -f "$MIGRATIONS_DIR/$file" >/dev/null
}
backup_existing(){
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$HOME/ani-games-ready-backups/$DB_NAME-$stamp"
  mkdir -p "$dir"
  chmod 700 "$HOME/ani-games-ready-backups" "$dir"
  log "Membuat backup database sebelum migrasi addon..."
  pg_dump -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -d "$DB_NAME" -Fc -f "$dir/database.dump"
  pg_dumpall -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" --globals-only -f "$dir/cluster-roles.sql"
  pg_restore --list "$dir/database.dump" >/dev/null
  [ -s "$dir/cluster-roles.sql" ] || die "Backup role cluster kosong; migrasi dibatalkan."
  chmod 600 "$dir/database.dump" "$dir/cluster-roles.sql"
  sha256sum "$dir/database.dump" "$dir/cluster-roles.sql" > "$dir/SHA256SUMS.txt"
  log "Backup tervalidasi: $dir"
}

if [ "$NEW_DATABASE" = 1 ]; then
  log "Database baru: instalasi skema bersih penuh. Database yang sudah ada tidak disentuh."
  for file in \
    000_prerequisites.sql \
    002_core_business_schema.sql \
    003_pc_device_api_functions.sql \
    004_billing_reseller_api.sql \
    005_runtime_privileges.sql \
    006_admin_local_auth_and_rpc.sql \
    007_billing_control_commands.sql \
    008_local_business_triggers.sql \
    009_admin_business_routines.sql \
    010_billing_reseller_refresh_and_devices.sql \
    011_billing_control_android_rpcs.sql \
    012_billing_stop_pause_policy.sql \
    013_remote_play.sql \
    014_remote_play_pairing.sql \
    015_remote_play_admin_controls.sql \
    016_remote_play_cloudflare_mesh.sql \
    017_remote_play_dashboard_cooldown.sql \
    018_remote_play_server_watchdog.sql \
    019_remote_play_session_connected.sql \
    020_remote_coin_wallet.sql \
    021_android_wol_relay.sql \
    022_coin_unit_scale_100.sql; do
    apply_file "$file"
  done
else
  DB_STATE="$(psql_admin -d "$DB_NAME" -At -F '|' -c "
    SELECT
      (to_regclass('public.rental_accounts') IS NOT NULL)::int,
      (to_regclass('public.devices') IS NOT NULL)::int,
      (to_regclass('remote_play.sessions') IS NOT NULL)::int,
      (to_regprocedure('api.remote_play_login(text,text,text)') IS NOT NULL)::int,
      (to_regprocedure('api.admin_remote_play_dashboard(text,integer)') IS NOT NULL)::int,
      (to_regprocedure('private.remote_play_get_client(text)') IS NOT NULL)::int,
      (to_regprocedure('private.remote_play_require_admin(text)') IS NOT NULL)::int,
      (SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')),
      (SELECT count(*) FROM unnest(ARRAY[
        to_regclass('remote_play.coin_wallets'),to_regclass('remote_play.coin_topup_orders'),
        to_regclass('remote_play.coin_lots'),to_regclass('remote_play.coin_ledger'),
        to_regclass('remote_play.pc_coin_rates'),to_regclass('remote_play.stardesk_device_links')
      ]) AS u(name) WHERE u.name IS NOT NULL),
      (SELECT count(*) FROM unnest(ARRAY[
        to_regclass('remote_play.wol_relay_enrollments'),to_regclass('remote_play.wol_relay_devices'),
        to_regclass('remote_play.wol_relay_commands'),to_regclass('remote_play.wol_relay_probes')
      ]) AS u(name) WHERE u.name IS NOT NULL),
      (SELECT count(*) FROM unnest(ARRAY[
        to_regprocedure('api.remote_coin_wallet(text)'),
        to_regprocedure('api.remote_coin_create_topup(text,bigint,text)'),
        to_regprocedure('api.remote_coin_history(text,integer)'),
        to_regprocedure('api.remote_coin_dashboard(text)'),
        to_regprocedure('api.admin_remote_coin_topups(text,integer)'),
        to_regprocedure('api.admin_remote_coin_approve_topup(text,uuid)'),
        to_regprocedure('api.admin_remote_coin_reject_topup(text,uuid,text)'),
        to_regprocedure('api.admin_remote_coin_set_device_rate(text,uuid,text)'),
        to_regprocedure('api.admin_remote_coin_link_stardesk_device(text,uuid,text,boolean)')
      ]) AS u(name) WHERE u.name IS NOT NULL),
      (SELECT count(*) FROM unnest(ARRAY[
        to_regprocedure('api.wol_relay_create_enrollment(text)'),
        to_regprocedure('api.wol_relay_status(text)'),
        to_regprocedure('api.wol_relay_enqueue(text,uuid)'),
        to_regprocedure('api.wol_relay_command_status(text,uuid)'),
        to_regprocedure('api.wol_relay_register(text,text,text,text,text)'),
        to_regprocedure('api.wol_relay_heartbeat(text,jsonb)'),
        to_regprocedure('api.wol_relay_poll(text)'),
        to_regprocedure('api.wol_relay_ack(text,uuid,text,jsonb)'),
        to_regprocedure('api.wol_relay_probe_request(text)'),
        to_regprocedure('api.wol_relay_probe_status(text,uuid)'),
        to_regprocedure('api.wol_relay_probe_ack(text,uuid,uuid,jsonb)')
      ]) AS u(name) WHERE u.name IS NOT NULL)
  ")"
  IFS='|' read -r CORE_RENTALS CORE_DEVICES RP_SESSIONS RP_LOGIN RP_ADMIN RP_CLIENT RP_ADMIN_HELPER TABLE_COUNT COIN_TABLES WOL_TABLES COIN_API_COUNT WOL_API_COUNT <<< "$DB_STATE"
  RP_SCHEMA="$(psql_admin -d "$DB_NAME" -Atqc "SELECT (to_regnamespace('remote_play') IS NOT NULL)::int")"
  CORE_ADDON_READY="$(psql_admin -d "$DB_NAME" -Atqc "
    SELECT (
      to_regclass('public.rental_accounts') IS NOT NULL
      AND to_regclass('public.devices') IS NOT NULL
      AND to_regclass('public.rental_sessions') IS NOT NULL
      AND to_regclass('public.usage_events') IS NOT NULL
      AND to_regclass('public.audit_logs') IS NOT NULL
      AND to_regclass('public.admin_accounts') IS NOT NULL
      AND to_regclass('public.org_members') IS NOT NULL
      AND to_regclass('public.device_tokens') IS NOT NULL
      AND to_regprocedure('private.admin_account_by_token(text)') IS NOT NULL
      AND to_regprocedure('api.admin_context_v2(text)') IS NOT NULL
      AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ani_api_runtime' AND NOT rolcanlogin)
    )::int
  ")"
  RP_COMPLETE="$(psql_admin -d "$DB_NAME" -Atqc "
    SELECT (
      to_regclass('remote_play.sessions') IS NOT NULL
      AND to_regprocedure('api.remote_play_login(text,text,text)') IS NOT NULL
      AND to_regprocedure('api.remote_play_pairing_prepare(text,uuid,text,text,inet)') IS NOT NULL
      AND to_regprocedure('api.remote_play_host_pairing_poll(text,uuid)') IS NOT NULL
      AND to_regprocedure('api.admin_remote_play_dashboard(text,integer)') IS NOT NULL
      AND to_regprocedure('api.remote_play_watchdog_sweep()') IS NOT NULL
      AND to_regprocedure('api.remote_play_session_connected(text,uuid)') IS NOT NULL
      AND to_regprocedure('private.remote_play_get_client(text)') IS NOT NULL
      AND to_regprocedure('private.remote_play_require_admin(text)') IS NOT NULL
    )::int
  ")"
  COIN_SCALE=0
  if [ "$COIN_TABLES" = 6 ]; then
    if [ "$(psql_admin -d "$DB_NAME" -Atqc "SELECT to_regclass('remote_play.coin_unit_config') IS NOT NULL")" = "t" ]; then
      COIN_SCALE="$(psql_admin -d "$DB_NAME" -Atqc "SELECT coin_scale FROM remote_play.coin_unit_config WHERE singleton IS TRUE")"
    fi
  fi

  if [ "$CORE_RENTALS" = 0 ] && [ "$CORE_DEVICES" = 0 ] && [ "$TABLE_COUNT" = 0 ]; then
    log "Database kosong terdeteksi; memasang skema bersih penuh."
    for file in \
      000_prerequisites.sql \
      002_core_business_schema.sql \
      003_pc_device_api_functions.sql \
      004_billing_reseller_api.sql \
      005_runtime_privileges.sql \
      006_admin_local_auth_and_rpc.sql \
      007_billing_control_commands.sql \
      008_local_business_triggers.sql \
      009_admin_business_routines.sql \
      010_billing_reseller_refresh_and_devices.sql \
      011_billing_control_android_rpcs.sql \
      012_billing_stop_pause_policy.sql \
      013_remote_play.sql \
      014_remote_play_pairing.sql \
      015_remote_play_admin_controls.sql \
      016_remote_play_cloudflare_mesh.sql \
      017_remote_play_dashboard_cooldown.sql \
      018_remote_play_server_watchdog.sql \
      019_remote_play_session_connected.sql \
      020_remote_coin_wallet.sql \
      021_android_wol_relay.sql \
      022_coin_unit_scale_100.sql; do
      apply_file "$file"
    done
  else
    [ "$CORE_RENTALS" = 1 ] && [ "$CORE_DEVICES" = 1 ] && [ "$CORE_ADDON_READY" = 1 ] || die "Database existing belum memenuhi signature core Android DB 000-012. Tidak ada migrasi diterapkan."
    [ "$COIN_TABLES" = 0 ] || [ "$COIN_TABLES" = 6 ] || die "Tabel coin terpasang sebagian ($COIN_TABLES/6); hentikan untuk audit."
    [ "$WOL_TABLES" = 0 ] || [ "$WOL_TABLES" = 4 ] || die "Tabel WoL terpasang sebagian ($WOL_TABLES/4); hentikan untuk audit."
    NEEDS_REMOTE_PLAY=0
    if [ "$RP_SCHEMA" = 1 ]; then
      [ "$RP_COMPLETE" = 1 ] || die "Schema Remote Play terdeteksi tetapi kontrak 013-019 tidak lengkap. Tidak ada migrasi otomatis."
    else
      [ "$RP_SESSIONS" = 0 ] && [ "$RP_LOGIN" = 0 ] && [ "$COIN_TABLES" = 0 ] && [ "$WOL_TABLES" = 0 ] || die "Remote Play/addon terpasang sebagian tanpa schema remote_play. Butuh audit manual."
      NEEDS_REMOTE_PLAY=1
    fi
    if [ "$COIN_TABLES" = 6 ] && [ "$COIN_API_COUNT" != 9 ]; then
      die "Coin table sudah ada tetapi kontrak API tidak lengkap ($COIN_API_COUNT/9). Tidak ada migrasi otomatis."
    fi
    if [ "$WOL_TABLES" = 4 ] && [ "$WOL_API_COUNT" != 11 ]; then
      die "WoL table sudah ada tetapi kontrak API tidak lengkap ($WOL_API_COUNT/11). Tidak ada migrasi otomatis."
    fi
    NEEDS_UPDATE=0
    [ "$NEEDS_REMOTE_PLAY" = 0 ] || NEEDS_UPDATE=1
    [ "$COIN_TABLES" = 6 ] || NEEDS_UPDATE=1
    [ "$WOL_TABLES" = 4 ] || NEEDS_UPDATE=1
    [ "$COIN_SCALE" = 100 ] || NEEDS_UPDATE=1
    if [ "$NEEDS_UPDATE" = 1 ]; then
      log "Core Android DB dikenali. Backup tervalidasi dan persetujuan APPLY wajib sebelum addon Remote Play/Coin/WoL."
      backup_existing
      printf '\nDB: %s | Remote Play perlu: %s | coin tables: %s/6 | WoL tables: %s/4 | coin scale: %s\n' "$DB_NAME" "$NEEDS_REMOTE_PLAY" "$COIN_TABLES" "$WOL_TABLES" "$COIN_SCALE"
      printf 'Ketik APPLY untuk menyetujui migrasi addon setelah backup tervalidasi: '
      read -r CONFIRM < /dev/tty
      [ "$CONFIRM" = "APPLY" ] || die "Dibatalkan. Database tetap pada keadaan semula."
      if [ "$NEEDS_REMOTE_PLAY" = 1 ]; then
        apply_file "013_remote_play.sql"
        apply_file "014_remote_play_pairing.sql"
        apply_file "015_remote_play_admin_controls.sql"
        apply_file "016_remote_play_cloudflare_mesh.sql"
        apply_file "017_remote_play_dashboard_cooldown.sql"
        apply_file "018_remote_play_server_watchdog.sql"
        apply_file "019_remote_play_session_connected.sql"
      fi
      [ "$COIN_TABLES" = 6 ] || apply_file "020_remote_coin_wallet.sql"
      [ "$WOL_TABLES" = 4 ] || apply_file "021_android_wol_relay.sql"
      apply_file "022_coin_unit_scale_100.sql"
    else
      log "Remote Play, coin, WoL dan coin scale=100 sudah lengkap; tidak ada migrasi yang perlu dijalankan."
    fi
  fi
fi

# Create an isolated, least-privilege API login only for first install.
if [ ! -f "$ENV_FILE" ]; then
  RUNTIME_ROLE="$(psql_admin -d "$DB_NAME" -Atqc "SELECT 1 FROM pg_roles WHERE rolname='ani_api_runtime' AND NOT rolcanlogin")"
  [ "$RUNTIME_ROLE" = 1 ] || die "Role ani_api_runtime tidak siap; API login tidak dibuat."
  API_DB_USER="ani_api_login_$(openssl rand -hex 4)"
  API_DB_PASSWORD="$(openssl rand -hex 32)"
  psql_admin -d postgres -v api_user="$API_DB_USER" -v api_password="$API_DB_PASSWORD" -v db_name="$DB_NAME" <<'SQL' >/dev/null
CREATE ROLE :"api_user" LOGIN PASSWORD :'api_password'
  INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT ani_api_runtime TO :"api_user";
GRANT CONNECT ON DATABASE :"db_name" TO :"api_user";
SQL
  BLYNK_TOKEN=""
  printf '\nToken Blynk (opsional, kosongkan bila belum siap): '
  read -r -s BLYNK_TOKEN < /dev/tty
  printf '\n'
  API_PEPPER="$(openssl rand -hex 32)"
  BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
  cat > "$ENV_FILE" <<EOF
DATABASE_URL=postgresql://$API_DB_USER:$API_DB_PASSWORD@127.0.0.1:$DB_PORT/$DB_NAME?sslmode=disable
ANI_BIND=127.0.0.1
PORT=8787
ANI_API_PEPPER=$API_PEPPER
ANI_ADMIN_BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN
ANI_ALLOWED_ORIGINS=
BLYNK_AUTH_TOKEN=$BLYNK_TOKEN
BLYNK_POWER_PIN=V0
EOF
  chmod 600 "$ENV_FILE"
fi

set -a
. "$ENV_FILE"
set +a
[ -n "$DATABASE_URL" ] || die "DATABASE_URL belum tersedia."
if [ -z "$ANI_BIND" ]; then ANI_BIND="127.0.0.1"; fi
if [ -z "$PORT" ]; then PORT="8787"; fi
API_PORT="$PORT"
[[ "$API_PORT" =~ ^[0-9]{1,5}$ ]] || die "Port API tidak valid."
case "$ANI_BIND" in 127.0.0.1|localhost|::1) ;; *) die "ANI_BIND harus loopback sampai HTTPS tunnel dikonfigurasi."; esac

cd "$SERVER_DIR"
log "Memasang dependency Node dan memeriksa syntax API..."
npm install --omit=dev --no-audit --no-fund
npm run check
node --input-type=module <<'NODE'
import pg from "pg";
const pool = new pg.Pool({connectionString: process.env.DATABASE_URL, max: 1, connectionTimeoutMillis: 5000});
try {
  const r = await pool.query("SELECT 1 AS ok, to_regprocedure('api.remote_coin_wallet(text)') IS NOT NULL AS coin_api, to_regprocedure('api.wol_relay_status(text)') IS NOT NULL AS wol_api");
  if (r.rows[0]?.ok !== 1 || !r.rows[0]?.coin_api || !r.rows[0]?.wol_api) {
    throw new Error("ANDROID_DB_REQUIRED_API_NOT_READY");
  }
} finally {
  await pool.end();
}
NODE

SERVICE_DIR="$PREFIX/var/service/ani-games-ready-api"
mkdir -p "$SERVICE_DIR/log"
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

# Optional boot start; Termux:Boot companion app must be installed/opened separately.
BOOT_DIR="$HOME/.termux/boot"
BOOT_FILE="$BOOT_DIR/99-ani-games-ready-services"
mkdir -p "$BOOT_DIR"
if [ ! -f "$BOOT_FILE" ]; then
  cat > "$BOOT_FILE" <<EOF
#!$PREFIX/bin/sh
termux-wake-lock >/dev/null 2>&1 || true
export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log"
. "$PREFIX/etc/profile.d/start-services.sh"
sleep 2
"$PREFIX/bin/sv" up postgres >/dev/null 2>&1 || true
"$PREFIX/bin/sv" up ani-games-ready-api >/dev/null 2>&1 || true
EOF
  chmod 700 "$BOOT_FILE"
fi

if [ -f "$PREFIX/etc/profile.d/start-services.sh" ]; then . "$PREFIX/etc/profile.d/start-services.sh"; fi
sleep 2
if "$PREFIX/bin/sv" status ani-games-ready-api 2>&1 | grep -q '^run:'; then
  "$PREFIX/bin/sv" down ani-games-ready-api >/dev/null 2>&1 || true
  sleep 1
  "$PREFIX/bin/sv" up ani-games-ready-api >/dev/null 2>&1 || true
else
  "$PREFIX/bin/sv-enable" ani-games-ready-api >/dev/null 2>&1 || true
  "$PREFIX/bin/sv" up ani-games-ready-api >/dev/null 2>&1 || true
fi
HEALTH=0
for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1 && "$PREFIX/bin/sv" status ani-games-ready-api 2>&1 | grep -q '^run:'; then
    HEALTH=1
    break
  fi
  sleep 1
done
[ "$HEALTH" = 1 ] || die "API belum sehat. Cek log: $PREFIX/var/log/sv/ani-games-ready-api/current"

log "INSTALLASI BACKEND SELESAI."
log "API lokal: http://127.0.0.1:$API_PORT/health"
log "Setup Owner pertama: http://127.0.0.1:8787/setup"
log "Service PostgreSQL: sv status postgres"
log "Service API: sv status ani-games-ready-api"
log "Log API: cat $PREFIX/var/log/sv/ani-games-ready-api/current"
log "Secret berada di $ENV_FILE (izin 600); jangan dibagikan."
log "Backup existing DB dibuat sebelum addon migration yang disetujui."
log "Termux:Boot app perlu dipasang/dibuka sekali agar service mulai saat Android reboot."
