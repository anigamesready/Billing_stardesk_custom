#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077
API_DIR="$HOME/ani-games-db-android-stage/server"
ENV_FILE="$API_DIR/.env"
DB_NAME="ani_games_ready_stage"
DB_PORT="5432"
log(){ printf '[ANI-ADMIN-V0-AUDIT] %s\n' "$*"; }
die(){ printf '[ANI-ADMIN-V0-AUDIT] STOP: %s\n' "$*" >&2; exit 1; }
[ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || die "Khusus Termux Android."
for bin in psql node; do command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."; done
[ -s "$ENV_FILE" ] || die "File .env API stage tidak ditemukan."
set -a
. "$ENV_FILE"
set +a
[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL tidak ada."
node --input-type=module - "$DATABASE_URL" "$DB_NAME" "$DB_PORT" <<'NODE'
import { URL } from 'node:url';
const u = new URL(process.argv[2]);
const db = decodeURIComponent(u.pathname.replace(/^\//, ''));
if (!['127.0.0.1','localhost','::1'].includes(u.hostname) ||
    (u.port || '5432') !== process.argv[4] || db !== process.argv[3] ||
    !['postgres:','postgresql:'].includes(u.protocol)) {
  process.stderr.write('DATABASE_TARGET_NOT_THE_EXISTING_ANDROID_STAGE\n');
  process.exit(2);
}
NODE
PG_ADMIN_USER="$(id -un)"
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }
psql_admin -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -qx 1 || die "Database stage tidak ditemukan."
log "Audit read-only; tidak ada migration, update source, restart service, atau perubahan data."
psql_admin -d "$DB_NAME" -P pager=off -F '|' -Atc "
WITH checks(label, present) AS (
 VALUES
 ('core.public.rental_accounts',to_regclass('public.rental_accounts') IS NOT NULL),
 ('core.public.devices',to_regclass('public.devices') IS NOT NULL),
 ('core.public.rental_sessions',to_regclass('public.rental_sessions') IS NOT NULL),
 ('core.public.usage_events',to_regclass('public.usage_events') IS NOT NULL),
 ('core.public.audit_logs',to_regclass('public.audit_logs') IS NOT NULL),
 ('core.public.admin_accounts',to_regclass('public.admin_accounts') IS NOT NULL),
 ('core.public.org_members',to_regclass('public.org_members') IS NOT NULL),
 ('core.public.device_tokens',to_regclass('public.device_tokens') IS NOT NULL),
 ('core.private.admin_account_by_token(text)',to_regprocedure('private.admin_account_by_token(text)') IS NOT NULL),
 ('core.api.admin_context(text)',to_regprocedure('api.admin_context(text)') IS NOT NULL),
 ('core.api.admin_context_v2(text)',to_regprocedure('api.admin_context_v2(text)') IS NOT NULL),
 ('core.api.admin_login(text,text)',to_regprocedure('api.admin_login(text,text)') IS NOT NULL),
 ('remote.schema',to_regnamespace('remote_play') IS NOT NULL),
 ('remote.sessions',to_regclass('remote_play.sessions') IS NOT NULL),
 ('remote.login',to_regprocedure('api.remote_play_login(text,text,text)') IS NOT NULL),
 ('remote.pairing_prepare',to_regprocedure('api.remote_play_pairing_prepare(text,uuid,text,text,inet)') IS NOT NULL),
 ('remote.host_pairing_poll',to_regprocedure('api.remote_play_host_pairing_poll(text,uuid)') IS NOT NULL),
 ('remote.admin_dashboard',to_regprocedure('api.admin_remote_play_dashboard(text,integer)') IS NOT NULL),
 ('remote.watchdog',to_regprocedure('api.remote_play_watchdog_sweep()') IS NOT NULL),
 ('remote.session_connected',to_regprocedure('api.remote_play_session_connected(text,uuid)') IS NOT NULL),
 ('remote.private_get_client',to_regprocedure('private.remote_play_get_client(text)') IS NOT NULL),
 ('remote.private_require_admin',to_regprocedure('private.remote_play_require_admin(text)') IS NOT NULL),
 ('coin.tables',(
  to_regclass('remote_play.coin_wallets') IS NOT NULL AND
  to_regclass('remote_play.coin_topup_orders') IS NOT NULL AND
  to_regclass('remote_play.coin_lots') IS NOT NULL AND
  to_regclass('remote_play.coin_ledger') IS NOT NULL AND
  to_regclass('remote_play.pc_coin_rates') IS NOT NULL AND
  to_regclass('remote_play.stardesk_device_links') IS NOT NULL)),
 ('coin.wallet_api',to_regprocedure('api.remote_coin_wallet(text)') IS NOT NULL),
 ('coin.create_topup_api',to_regprocedure('api.remote_coin_create_topup(text,bigint,text)') IS NOT NULL),
 ('coin.history_api',to_regprocedure('api.remote_coin_history(text,integer)') IS NOT NULL),
 ('coin.dashboard_api',to_regprocedure('api.remote_coin_dashboard(text)') IS NOT NULL),
 ('coin.admin_topups_api',to_regprocedure('api.admin_remote_coin_topups(text,integer)') IS NOT NULL),
 ('coin.admin_approve_api',to_regprocedure('api.admin_remote_coin_approve_topup(text,uuid)') IS NOT NULL),
 ('coin.admin_reject_api',to_regprocedure('api.admin_remote_coin_reject_topup(text,uuid,text)') IS NOT NULL),
 ('coin.admin_rate_api',to_regprocedure('api.admin_remote_coin_set_device_rate(text,uuid,text)') IS NOT NULL),
 ('coin.admin_link_api',to_regprocedure('api.admin_remote_coin_link_stardesk_device(text,uuid,text,boolean)') IS NOT NULL),
 ('coin.admin_overview_api',to_regprocedure('api.admin_remote_coin_overview(text,integer)') IS NOT NULL),
 ('coin.admin_wallet_api',to_regprocedure('api.admin_remote_coin_wallet(text,uuid,integer)') IS NOT NULL),
 ('wol.tables',(
  to_regclass('remote_play.wol_relay_enrollments') IS NOT NULL AND
  to_regclass('remote_play.wol_relay_devices') IS NOT NULL AND
  to_regclass('remote_play.wol_relay_commands') IS NOT NULL AND
  to_regclass('remote_play.wol_relay_probes') IS NOT NULL)),
 ('wol.create_enrollment',to_regprocedure('api.wol_relay_create_enrollment(text)') IS NOT NULL),
 ('wol.status',to_regprocedure('api.wol_relay_status(text)') IS NOT NULL),
 ('wol.enqueue',to_regprocedure('api.wol_relay_enqueue(text,uuid)') IS NOT NULL),
 ('wol.command_status',to_regprocedure('api.wol_relay_command_status(text,uuid)') IS NOT NULL),
 ('wol.register',to_regprocedure('api.wol_relay_register(text,text,text,text,text)') IS NOT NULL),
 ('wol.heartbeat',to_regprocedure('api.wol_relay_heartbeat(text,jsonb)') IS NOT NULL),
 ('wol.poll',to_regprocedure('api.wol_relay_poll(text)') IS NOT NULL),
 ('wol.ack',to_regprocedure('api.wol_relay_ack(text,uuid,text,jsonb)') IS NOT NULL),
 ('wol.probe_request',to_regprocedure('api.wol_relay_probe_request(text)') IS NOT NULL),
 ('wol.probe_status',to_regprocedure('api.wol_relay_probe_status(text,uuid)') IS NOT NULL),
 ('wol.probe_ack',to_regprocedure('api.wol_relay_probe_ack(text,uuid,uuid,jsonb)') IS NOT NULL),
 ('coin_v0.schema',to_regnamespace('androiddb_v0') IS NOT NULL),
 ('coin_v0.admin_dashboard',to_regprocedure('api.androiddb_v0_admin_dashboard(text,integer)') IS NOT NULL)
)
SELECT label || '|' || CASE WHEN present THEN 'OK' ELSE 'MISSING' END FROM checks
UNION ALL
SELECT 'db.role.ani_api_runtime|' || CASE WHEN EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ani_api_runtime' AND NOT rolcanlogin) THEN 'OK' ELSE 'MISSING' END
ORDER BY 1;
"
if [ "$(psql_admin -d "$DB_NAME" -Atqc "SELECT to_regclass('remote_play.coin_unit_config') IS NOT NULL")" = "t" ]; then
  psql_admin -d "$DB_NAME" -P pager=off -Atqc "SELECT 'coin.scale|' || COALESCE((SELECT coin_scale::text FROM remote_play.coin_unit_config WHERE singleton IS TRUE),'NOT_SET')"
else
  printf 'coin.scale|MISSING_TABLE\n'
fi
log "Selesai. Kirim output audit ini; tidak ada rahasia yang ditampilkan."
