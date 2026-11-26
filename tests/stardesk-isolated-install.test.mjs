import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const installer = readFileSync('backend/android-db/termux/install-stardesk-custom-v0.sh', 'utf8');
const agentInstaller = readFileSync('backend/android-db/relay-agent/install-stardesk-agent.sh', 'utf8');
const agentUpdater = readFileSync('backend/android-db/relay-agent/update-stardesk-agent.sh', 'utf8');
const relayAgent = readFileSync('backend/android-db/relay-agent/agent.mjs', 'utf8');
const relayReconnect = readFileSync('backend/android-db/relay-agent/reconnect.mjs', 'utf8');
const relayPackage = JSON.parse(readFileSync('backend/android-db/relay-agent/package.json', 'utf8'));
const migrationRoot = 'backend/android-db/migrations/';
const migrations = [
  '000_prerequisites.sql',
  '002_core_business_schema.sql',
  '003_pc_device_api_functions.sql',
  '004_billing_reseller_api.sql',
  '005_runtime_privileges.sql',
  '006_admin_local_auth_and_rpc.sql',
  '007_billing_control_commands.sql',
  '008_local_business_triggers.sql',
  '009_admin_business_routines.sql',
  '010_billing_reseller_refresh_and_devices.sql',
  '011_billing_control_android_rpcs.sql',
  '012_billing_stop_pause_policy.sql',
  '013_remote_play.sql',
  '014_remote_play_pairing.sql',
  '015_remote_play_admin_controls.sql',
  '016_remote_play_cloudflare_mesh.sql',
  '017_remote_play_dashboard_cooldown.sql',
  '018_remote_play_server_watchdog.sql',
  '019_remote_play_session_connected.sql',
  '020_remote_coin_wallet.sql',
  '021_android_wol_relay.sql',
  '022_coin_unit_scale_100.sql',
  '023_admin_coin_management_read_api.sql',
  '025_admin_androiddb_v0_coin_domain.sql',
];

test('StarDesk installer uses dedicated DB, roles, API port, directory and service', () => {
  for (const token of [
    'stardesk_custom_v0',
    'stardesk_v0_owner',
    'stardesk_v0_runtime',
    'stardesk_v0_login',
    'ani-games-stardesk-custom-v0',
    '8789',
    'stardesk-custom-v0-api',
    'ANI_STARDESK_SOURCE_REF',
    'androiddb_v0_admin_dashboard',
    'androiddb_v0_remote_login',
  ]) assert.ok(installer.includes(token), 'missing isolation identifier: ' + token);
});

test('StarDesk installer is fail-closed and does not target legacy DB/API/service', () => {
  for (const forbidden of [
    'ani_games_ready_stage',
    'ani-games-db-android-stage',
    'ani-games-ready-api',
    'ANI_DB_NAME',
    'PORT=8788',
    'DROP DATABASE',
    'DROP ROLE',
    'sv down ani-games-ready-api',
    'restart ani-games-ready-api',
  ]) assert.ok(!installer.includes(forbidden), 'legacy/destructive path present: ' + forbidden);
  for (const guard of [
    'DB_EXISTS',
    'OWNER_EXISTS',
    'RUNTIME_EXISTS',
    'LOGIN_EXISTS',
    'SERVICE_DIR',
    '/dev/tcp/127.0.0.1/$API_PORT',
    'pg_isready',
    'POSTGRES_SERVICE_STATUS',
    'SHOW data_directory',
    'ANI_STARDESK_SOURCE_REF',
  ]) assert.ok(installer.includes(guard), 'missing fail-closed guard: ' + guard);
});

test('migration bundle is complete and rewrites the NOLOGIN API runtime role', () => {
  assert.equal(migrations.length, 24);
  assert.ok(installer.includes('sed "s/ani_api_runtime/$RUNTIME_ROLE/g"'));
  for (const name of migrations) {
    const sql = readFileSync(migrationRoot + name, 'utf8');
    assert.ok(sql.length > 100, 'migration empty: ' + name);
    const isolated = sql.replaceAll('ani_api_runtime', 'stardesk_v0_runtime');
    assert.ok(!isolated.includes('ani_api_runtime'), 'legacy runtime reference remains after transformation: ' + name);
  }
});

test('StarDesk relay installer targets API 8789 and the dedicated relay route/service', () => {
  assert.ok(agentInstaller.includes('http://127.0.0.1:8789'));
  assert.ok(agentInstaller.includes('/agent/connect/stardesk'));
  assert.ok(agentInstaller.includes('ani-games-stardesk-relay-agent'));
  assert.ok(!agentInstaller.includes('sv down ani-games-relay-agent'));
  assert.ok(!agentInstaller.includes('sv down ani-games-ready-api'));
  assert.ok(!agentInstaller.includes('openssl rand'));
});

test('StarDesk installer accepts only the already-running, identity-verified PostgreSQL cluster', () => {
  assert.ok(installer.includes('pg_isready -h "$PREFIX/tmp"'));
  assert.ok(installer.includes('SHOW data_directory'));
  assert.ok(installer.includes('SERVER_MAJOR'));
  assert.ok(installer.includes('POSTGRES_SERVICE_STATUS'));
  for (const forbidden of [
    /^\\s*sv\\s+(?:up|down|enable)\\s+postgres\\b/m,
    /^\\s*pg_ctl\\s+(?:start|restart|stop)\\b/m,
    /^\\s*initdb\\b/m,
  ]) {
    assert.doesNotMatch(installer, forbidden, 'PostgreSQL lifecycle command found: ' + forbidden);
  }
});

test('StarDesk installer requires caller to pin the exact source commit', () => {
  assert.ok(installer.includes('SOURCE_REF="${ANI_STARDESK_SOURCE_REF:-}"'));
  assert.ok(installer.includes('ANI_STARDESK_SOURCE_REF wajib diisi'));
  assert.ok(!installer.includes('890bae3e2ae16dffe530e04d0929d066f38832b2'));
});

test('StarDesk Relay Agent reconnect lifecycle is persistent and stable-backoff controlled', () => {
  assert.ok(relayAgent.includes('createReconnectController'));
  assert.ok(relayAgent.includes('reconnectController.schedule()'));
  assert.ok(relayAgent.includes('reconnectController.markStable()'));
  assert.ok(relayAgent.includes('stableForMs: 60000'));
  assert.ok(!relayAgent.includes('reconnectTimer.unref'));
  assert.ok(!relayAgent.includes('reconnectDelay = 2000'));
  assert.ok(relayReconnect.includes('scheduleTimer(() =>'));
  assert.ok(relayReconnect.includes('cancelTimer(timer)'));
  assert.ok(relayPackage.scripts.check.includes('reconnect.mjs'));
  assert.ok(agentInstaller.includes('for file in agent.mjs protocol.mjs reconnect.mjs package.json protocol.test.mjs'));
  assert.ok(agentInstaller.includes('"$TMP/reconnect.mjs"'));
});

test('StarDesk Relay updater is pinned, transactional, and cannot retarget legacy services', () => {
  for (const token of [
    'ANI_RELAY_REF',
    'ani-games-stardesk-relay-agent',
    'http://127.0.0.1:8789',
    '/agent/connect/stardesk',
    'sv down "$SERVICE_NAME"',
    'sv up "$SERVICE_NAME"',
    'run.backup.',
    'RELAY_SHARED_SECRET',
  ]) assert.ok(agentUpdater.includes(token), 'missing updater safety contract: ' + token);
  for (const forbidden of [
    'ani-games-ready-api',
    'ani-games-relay-agent',
    'ani_games_ready_stage',
    '8788',
    'redmi-db-android-stage',
    'openssl rand',
  ]) assert.ok(!agentUpdater.includes(forbidden), 'legacy target or secret generation found: ' + forbidden);
  assert.ok(!agentUpdater.includes('cat "$ENV_FILE"'));
});


const adminHtml = readFileSync('admin-androiddb-v0/app/src/main/assets/index.html', 'utf8');
const adminJava = readFileSync('admin-androiddb-v0/app/src/main/java/com/anigamesready/adminandroiddbv0/MainActivity.java', 'utf8');
const dbControl = readFileSync('backend/android-db/termux/stardesk-db-control.sh', 'utf8');

test('Admin login waits past relay deadline and exposes a stage-aware Gateway health check', () => {
  assert.ok(adminJava.includes('connection.setReadTimeout("__gateway_health".equals(route) ? 15000 : 40000);'));
  assert.ok(adminJava.includes('GATEWAY_TIMEOUT: Gateway/Relay'));
  assert.ok(adminHtml.includes('checkGatewayConnection'));
  assert.ok(adminHtml.includes('__gateway_health'));
  assert.ok(adminHtml.includes('Tahap 1/2'));
  assert.ok(adminHtml.includes('Tahap 2/2'));
  assert.ok(adminHtml.includes('callbacks.route!=="__gateway_health"'));
});

test('Termux quick-control menu keeps DBs separate and defaults SQL sessions to read-only', () => {
  for (const token of ['ani_games_ready_stage','stardesk_custom_v0','8788','8789',
    'ani-games-ready-api','stardesk-custom-v0-api','ani-games-relay-agent',
    'ani-games-stardesk-relay-agent','default_transaction_read_only=on',
    '/stardesk/_ani_gateway/health']) assert.ok(dbControl.includes(token), 'missing item: '+token);
  assert.ok(dbControl.includes('case "$service" in "$STAR_API_SERVICE"|"$STAR_RELAY_SERVICE")'));
  assert.ok(dbControl.includes('readonly STAR_API_SERVICE="stardesk-custom-v0-api"'));
  assert.ok(dbControl.includes('readonly STAR_RELAY_SERVICE="ani-games-stardesk-relay-agent"'));
  assert.doesNotMatch(dbControl, /\bsv\s+(?:up|down|restart|start|stop)\s+(?:postgres|ani-games-ready-api|ani-games-relay-agent)\b/);
  assert.doesNotMatch(dbControl, /\b(?:DROP\s+DATABASE|DROP\s+ROLE|TRUNCATE\s+TABLE|DELETE\s+FROM|pg_ctl|initdb)\b/i);
  assert.doesNotMatch(dbControl, /\\\\\$\\{/i, "shell variable expansion must not contain a literal escape");
});
