#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail
umask 077

API_DIR="$HOME/ani-games-db-android-stage/server"
ENV_FILE="$API_DIR/.env"
DB_NAME="ani_games_ready_stage"
DB_PORT="5432"
API_PORT="8788"
API_SOURCE_REF="30a00886069d6267780498655e4e500ffc715e43"
REPO="anigamesready/Billing_stardesk_custom"
WORK_DIR="$HOME/ani-admin-v0-repair"
BACKUP_ROOT="$HOME/ani-games-ready-backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

log(){ printf '[ANI-ADMIN-V0-REPAIR] %s\n' "$*"; }
die(){ printf '[ANI-ADMIN-V0-REPAIR] STOP: %s\n' "$*" >&2; exit 1; }

[ -n "\${PREFIX:-}" ] && [ -x "$PREFIX/bin/pkg" ] || die "Khusus Termux Android."
for bin in node curl psql pg_dump pg_dumpall pg_restore sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin belum tersedia."
done
[ -d "$API_DIR" ] && [ -s "$API_DIR/server.mjs" ] || die "Folder/source API stage tidak ditemukan."
[ -s "$ENV_FILE" ] || die ".env API tidak ditemukan; tidak akan membuat kredensial baru."
[ -r /dev/tty ] || die "Jalankan dari terminal Termux interaktif."

set -a
. "$ENV_FILE"
set +a
[ -n "\${DATABASE_URL:-}" ] || die "DATABASE_URL tidak ada pada .env."
[ -n "\${ANI_API_PEPPER:-}" ] && [ "\${#ANI_API_PEPPER}" -ge 32 ] || die "ANI_API_PEPPER tidak valid."
[ "\${PORT:-}" = "$API_PORT" ] || die "Port API bukan 8788; tidak akan menebak target."
[ "\${ANI_BIND:-}" = "127.0.0.1" ] || die "API bukan loopback; hentikan untuk audit manual."

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

mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"
TMP_DIR="$(mktemp -d "$WORK_DIR/run.XXXXXX")"
chmod 700 "$TMP_DIR"
cleanup(){ rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log "Mengunduh API dan migration 025 dari commit yang dipin..."
curl -fsSL "https://raw.githubusercontent.com/$REPO/$API_SOURCE_REF/backend/android-db/server/server.mjs" -o "$TMP_DIR/server.mjs"
curl -fsSL "https://raw.githubusercontent.com/$REPO/$API_SOURCE_REF/backend/android-db/migrations/025_admin_androiddb_v0_coin_domain.sql" -o "$TMP_DIR/025_admin_androiddb_v0_coin_domain.sql"
[ -s "$TMP_DIR/server.mjs" ] && [ -s "$TMP_DIR/025_admin_androiddb_v0_coin_domain.sql" ] || die "Source download tidak lengkap."
grep -q 'admin_context: { auth: "admin"' "$TMP_DIR/server.mjs" || die "Source API baru tidak memiliki admin_context allowlist."
grep -q 'androiddb_v0_admin_dashboard: { auth: "admin"' "$TMP_DIR/server.mjs" || die "Source API baru tidak memiliki Coin v0 allowlist."
node --check "$TMP_DIR/server.mjs" || die "Syntax API baru gagal."
sha256sum "$TMP_DIR/server.mjs" "$TMP_DIR/025_admin_androiddb_v0_coin_domain.sql" > "$TMP_DIR/SOURCE-SHA256SUMS.txt"

API_PID="$(node --input-type=module - "$API_DIR" "$DATABASE_URL" "$ANI_API_PEPPER" "$PORT" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
const dir = fs.realpathSync(process.argv[2]);
const expected = { DATABASE_URL:process.argv[3], ANI_API_PEPPER:process.argv[4], PORT:process.argv[5] };
const found = [];
for (const name of fs.readdirSync('/proc')) {
  if (!/^[0-9]+$/.test(name)) continue;
  try {
    const base = '/proc/' + name;
    if (fs.realpathSync(base + '/cwd') !== dir) continue;
    const argv = fs.readFileSync(base + '/cmdline').toString().split('\0').filter(Boolean);
    if (!argv.some(x => path.basename(x) === 'server.mjs')) continue;
    const env = Object.fromEntries(fs.readFileSync(base + '/environ').toString().split('\0')
      .filter(Boolean).map(x => { const i=x.indexOf('='); return [x.slice(0,i),x.slice(i+1)]; }));
    if (env.DATABASE_URL !== expected.DATABASE_URL || env.ANI_API_PEPPER !== expected.ANI_API_PEPPER ||
        env.PORT !== expected.PORT || env.ANI_BIND !== '127.0.0.1') {
      process.stderr.write('API_PROCESS_ENV_MISMATCH\n'); process.exit(3);
    }
    found.push(name);
  } catch {}
}
if (found.length !== 1) {
  process.stderr.write('EXPECTED_EXACTLY_ONE_STAGE_API_PROCESS_FOUND_' + found.length + '\n');
  process.exit(4);
}
process.stdout.write(found[0]);
NODE
)" || die "Proses Node API tidak cocok dengan folder/.env stage atau terdeteksi lebih dari satu. Tidak ada proses dihentikan."
[[ "$API_PID" =~ ^[0-9]+$ ]] || die "PID API tidak valid."

PG_ADMIN_USER="$(id -un)"
psql_admin(){ psql -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -v ON_ERROR_STOP=1 "$@"; }

log "Memeriksa schema inti dan Remote Play sebelum migration..."
CORE_READY="$(psql_admin -d "$DB_NAME" -Atqc "
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
 AND to_regprocedure('api.admin_context(text)') IS NOT NULL
 AND to_regprocedure('api.admin_login(text,text)') IS NOT NULL
 AND to_regprocedure('api.admin_get_user(text)') IS NOT NULL
 AND EXISTS(SELECT 1 FROM pg_roles WHERE rolname='ani_api_runtime' AND NOT rolcanlogin)
)::int
")"
[ "$CORE_READY" = "1" ] || die "Signature core Admin/role runtime belum lengkap."
RP_READY="$(psql_admin -d "$DB_NAME" -Atqc "
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
 AND to_regprocedure('api.wol_relay_status(text)') IS NOT NULL
)::int
")"
[ "$RP_READY" = "1" ] || die "Addon Remote Play/WoL belum lengkap; hentikan untuk audit migrasi historis."

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
 (SELECT count(*) FROM unnest(ARRAY[
  to_regprocedure('api.androiddb_v0_admin_dashboard(text,integer)'),
  to_regprocedure('api.androiddb_v0_admin_create_rental(text,text,text)'),
  to_regprocedure('api.androiddb_v0_admin_set_rental_status(text,uuid,boolean)'),
  to_regprocedure('api.androiddb_v0_admin_issue_activation(text,uuid)'),
  to_regprocedure('api.androiddb_v0_admin_wallet(text,uuid,integer)'),
  to_regprocedure('api.androiddb_v0_admin_approve_topup(text,uuid)'),
  to_regprocedure('api.androiddb_v0_admin_reject_topup(text,uuid,text)'),
  to_regprocedure('api.androiddb_v0_admin_set_device_rate(text,uuid,text)'),
  to_regprocedure('api.androiddb_v0_admin_link_stardesk_device(text,uuid,text,boolean)'),
  to_regprocedure('api.androiddb_v0_admin_set_host_permission(text,uuid,boolean)'),
  to_regprocedure('api.androiddb_v0_admin_issue_host_enrollment(text,text)'),
  to_regprocedure('api.androiddb_v0_host_heartbeat(text,boolean,text)'),
  to_regprocedure('api.androiddb_v0_remote_login(text,text,text)'),
  to_regprocedure('api.androiddb_v0_remote_refresh(text)'),
  to_regprocedure('api.androiddb_v0_remote_logout(text)'),
  to_regprocedure('api.androiddb_v0_remote_coin_wallet(text)'),
  to_regprocedure('api.androiddb_v0_remote_coin_history(text,integer)'),
  to_regprocedure('api.androiddb_v0_remote_dashboard(text)'),
  to_regprocedure('api.androiddb_v0_remote_coin_create_topup(text,bigint,text)')
 ]) AS u(name) WHERE u.name IS NOT NULL)
")"
IFS='|' read -r V0_SCHEMA V0_TABLES V0_FUNCTIONS <<< "$V0_STATE"
if [ "$V0_SCHEMA" = "1" ]; then
  [ "$V0_TABLES" = "14" ] && [ "$V0_FUNCTIONS" = "19" ] || die "Schema androiddb_v0 parsial ($V0_TABLES/14 tabel, $V0_FUNCTIONS/19 signature). Audit manual diperlukan."
elif [ "$V0_SCHEMA" = "0" ] && [ "$V0_TABLES" = "0" ] && [ "$V0_FUNCTIONS" = "0" ]; then
  BACKUP_DIR="$BACKUP_ROOT/$DB_NAME-admin-v0-$STAMP"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_ROOT" "$BACKUP_DIR"
  log "Membuat backup DB + role cluster sebelum migration 025..."
  pg_dump -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" -d "$DB_NAME" -Fc -f "$BACKUP_DIR/database.dump"
  pg_dumpall -X -h "$PREFIX/tmp" -p "$DB_PORT" -U "$PG_ADMIN_USER" --globals-only -f "$BACKUP_DIR/cluster-roles.sql"
  pg_restore --list "$BACKUP_DIR/database.dump" > "$BACKUP_DIR/restore-list.txt"
  [ -s "$BACKUP_DIR/restore-list.txt" ] && [ -s "$BACKUP_DIR/cluster-roles.sql" ] || die "Backup tidak lengkap."
  chmod 600 "$BACKUP_DIR/database.dump" "$BACKUP_DIR/cluster-roles.sql" "$BACKUP_DIR/restore-list.txt"
  sha256sum "$BACKUP_DIR/database.dump" "$BACKUP_DIR/cluster-roles.sql" > "$BACKUP_DIR/SHA256SUMS.txt"
  (cd "$BACKUP_DIR" && sha256sum -c SHA256SUMS.txt >/dev/null) || die "Checksum backup gagal."
  log "Backup valid; restore-list tersedia."
  printf '\nDatabase: %s\nSchema AniCoin v0: belum terpasang\nBackup: %s\n' "$DB_NAME" "$BACKUP_DIR"
  printf 'Ketik APPLY untuk memasang schema Coin v0 terisolasi: '
  read -r CONFIRM < /dev/tty
  [ "$CONFIRM" = "APPLY" ] || die "Dibatalkan. Database tidak diubah."
  psql_admin -d "$DB_NAME" -f "$TMP_DIR/025_admin_androiddb_v0_coin_domain.sql"
else
  die "Signature schema Coin v0 tidak konsisten; tidak ada migration."
fi

V0_AFTER="$(psql_admin -d "$DB_NAME" -At -F '|' -c "
SELECT
 (SELECT count(*) FROM unnest(ARRAY[
  to_regclass('androiddb_v0.rental_accounts'),to_regclass('androiddb_v0.client_credentials'),
  to_regclass('androiddb_v0.client_sessions'),to_regclass('androiddb_v0.coin_wallets'),
  to_regclass('androiddb_v0.coin_topup_orders'),to_regclass('androiddb_v0.coin_lots'),
  to_regclass('androiddb_v0.coin_ledger'),to_regclass('androiddb_v0.pc_coin_rates'),
  to_regclass('androiddb_v0.stardesk_device_links'),to_regclass('androiddb_v0.host_permissions'),
  to_regclass('androiddb_v0.host_enrollments'),to_regclass('androiddb_v0.host_registrations'),
  to_regclass('androiddb_v0.sessions'),to_regclass('androiddb_v0.audit_events')
 ]) AS u(name) WHERE u.name IS NOT NULL),
 (SELECT count(*) FROM unnest(ARRAY[
  to_regprocedure('api.androiddb_v0_admin_dashboard(text,integer)'),
  to_regprocedure('api.androiddb_v0_admin_create_rental(text,text,text)'),
  to_regprocedure('api.androiddb_v0_admin_set_rental_status(text,uuid,boolean)'),
  to_regprocedure('api.androiddb_v0_admin_issue_activation(text,uuid)'),
  to_regprocedure('api.androiddb_v0_admin_wallet(text,uuid,integer)'),
  to_regprocedure('api.androiddb_v0_admin_approve_topup(text,uuid)'),
  to_regprocedure('api.androiddb_v0_admin_reject_topup(text,uuid,text)'),
  to_regprocedure('api.androiddb_v0_admin_set_device_rate(text,uuid,text)'),
  to_regprocedure('api.androiddb_v0_admin_link_stardesk_device(text,uuid,text,boolean)'),
  to_regprocedure('api.androiddb_v0_admin_set_host_permission(text,uuid,boolean)'),
  to_regprocedure('api.androiddb_v0_admin_issue_host_enrollment(text,uuid,integer)'),
  to_regprocedure('api.androiddb_v0_host_enroll(text,text)'),
  to_regprocedure('api.androiddb_v0_host_heartbeat(text,boolean,text)'),
  to_regprocedure('api.androiddb_v0_remote_login(text,text,text)'),
  to_regprocedure('api.androiddb_v0_remote_refresh(text)'),
  to_regprocedure('api.androiddb_v0_remote_logout(text)'),
  to_regprocedure('api.androiddb_v0_remote_coin_wallet(text)'),
  to_regprocedure('api.androiddb_v0_remote_coin_history(text,integer)'),
  to_regprocedure('api.androiddb_v0_remote_dashboard(text)'),
  to_regprocedure('api.androiddb_v0_remote_coin_create_topup(text,bigint,text)')
 ]) AS u(name) WHERE u.name IS NOT NULL)
")"
IFS='|' read -r V0_TABLES_AFTER V0_FUNCTIONS_AFTER <<< "$V0_AFTER"
[ "$V0_TABLES_AFTER" = "14" ] && [ "$V0_FUNCTIONS_AFTER" = "20" ] || die "Verifikasi migration v0 gagal ($V0_TABLES_AFTER/14 tabel, $V0_FUNCTIONS_AFTER/20 RPC)."

API_BACKUP_DIR="$HOME/ani-games-ready-backups/api-source-$STAMP"
mkdir -p "$API_BACKUP_DIR"
chmod 700 "$API_BACKUP_DIR"
cp -p "$API_DIR/server.mjs" "$API_BACKUP_DIR/server.mjs"
cp -p "$API_DIR/package.json" "$API_BACKUP_DIR/package.json" 2>/dev/null || true
sha256sum "$API_BACKUP_DIR/server.mjs" > "$API_BACKUP_DIR/SHA256SUMS.txt"
cp "$TMP_DIR/server.mjs" "$API_DIR/server.mjs"
chmod 600 "$API_DIR/server.mjs"
node --check "$API_DIR/server.mjs" || {
  cp -p "$API_BACKUP_DIR/server.mjs" "$API_DIR/server.mjs"
  die "Syntax API baru gagal. Source lama dipulihkan."
}

log "Restart hanya proses Node API stage; PostgreSQL tetap berjalan..."
node --input-type=module - "$API_DIR" "$API_PID" "$API_BACKUP_DIR/server.mjs" "$API_PORT" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const dir = fs.realpathSync(process.argv[2]);
const oldPid = Number(process.argv[3]);
const backup = process.argv[4];
const port = Number(process.argv[5]);
const env = { ...process.env };
const serverPath = path.join(dir, 'server.mjs');
const logPath = path.join(path.dirname(backup), 'api-restart.log');
if (!Number.isInteger(oldPid) || oldPid < 2 || !env.DATABASE_URL ||
    !env.ANI_API_PEPPER || env.PORT !== String(port) || env.ANI_BIND !== '127.0.0.1') {
  throw new Error('API_RESTART_GUARD_FAILED');
}
function alive(pid) { try { process.kill(pid,0); return true; } catch(e) { return e.code==='EPERM'; } }
const sleep = ms => new Promise(r => setTimeout(r,ms));
async function waitExit(pid, timeout) {
  const end=Date.now()+timeout;
  while(Date.now()<end){ if(!alive(pid))return true; await sleep(200); }
  return !alive(pid);
}
async function health() {
  const end=Date.now()+18000; let last='NO_RESPONSE';
  while(Date.now()<end){
    try{
      const r=await fetch('http://127.0.0.1:'+port+'/health',{signal:AbortSignal.timeout(1800)});
      const d=await r.json();
      if(r.status===200&&d.api==='online'&&d.database==='online')return d;
      last='HEALTH_NOT_READY';
    }catch(e){last=String(e.message||e);}
    await sleep(450);
  }
  throw new Error('API_HEALTH_CHECK_FAILED:'+last.slice(0,100));
}
async function gate(name){
  const r=await fetch('http://127.0.0.1:'+port+'/rest/v1/rpc/'+name,{
    method:'POST',headers:{'content-type':'application/json',accept:'application/json'},
    body:'{}',signal:AbortSignal.timeout(4000)
  });
  const d=await r.json().catch(()=>({}));
  if(r.status!==401||d.message!=='AUTH_REQUIRED')
    throw new Error('RPC_ALLOWLIST_SMOKE_FAILED:'+name+':'+r.status+':'+String(d.message||d.error||''));
}
const fd=fs.openSync(logPath,'a',0o600);
let child=null, oldStopped=false;
function start(){
  child=spawn(process.execPath,['server.mjs'],{cwd:dir,env,detached:true,stdio:['ignore',fd,fd]});
  child.unref(); return child.pid;
}
async function stopChild(){
  if(child?.pid&&alive(child.pid)){try{process.kill(child.pid,'SIGTERM');}catch{} await waitExit(child.pid,12000);}
}
try{
  if(fs.realpathSync('/proc/'+oldPid+'/cwd')!==dir)throw new Error('LIVE_API_CWD_CHANGED');
  const args=fs.readFileSync('/proc/'+oldPid+'/cmdline').toString().split('\0');
  if(!args.some(x=>path.basename(x)==='server.mjs'))throw new Error('LIVE_API_COMMAND_CHANGED');
  process.kill(oldPid,'SIGTERM');
  oldStopped=await waitExit(oldPid,12000);
  if(!oldStopped)throw new Error('OLD_API_DID_NOT_STOP_GRACEFULLY');
  const newPid=start();
  await health();
  await gate('admin_context');
  await gate('androiddb_v0_admin_dashboard');
  fs.closeSync(fd);
  process.stdout.write(JSON.stringify({
    api:'online',database:'online',port,previous_api_stopped:true,new_api_pid:newPid,
    admin_context:'protected_rpc_reached',anicoin_v0_dashboard:'protected_rpc_reached'
  })+'\n');
}catch(e){
  await stopChild();
  try{fs.copyFileSync(backup,serverPath);}catch{}
  let rollback='not_needed';
  if(oldStopped){
    try{const p=start();await health();rollback='old_api_restored_pid_'+p;}
    catch(x){rollback='failed:'+String(x.message||x).slice(0,120);}
  }
  try{fs.closeSync(fd);}catch{}
  process.stderr.write('API_UPDATE_FAILED_ROLLBACK_'+rollback+':'+String(e.message||e).slice(0,160)+'\n');
  process.exit(1);
}
NODE

log "Selesai. PostgreSQL dan data rental lama tetap dipertahankan."
log "Backup source API: $API_BACKUP_DIR"
[ -z "\${BACKUP_DIR:-}" ] || log "Backup database/roles: $BACKUP_DIR"
log "Smoke test: /health online, admin_context dan AniCoin v0 dikenali API (AUTH_REQUIRED, bukan RPC_NOT_ALLOWED)."
