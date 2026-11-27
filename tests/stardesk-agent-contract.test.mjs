import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL("../" + path, import.meta.url), "utf8");
const migration = read("backend/android-db/migrations/027_windows_agent_domain.sql");
const ratesMigration = read("backend/android-db/migrations/028_manual_pc_tariffs.sql");
const server = read("backend/android-db/server/server.mjs");
const installer = read("backend/android-db/termux/install-stardesk-custom-v0.sh");
const upgrader = read("backend/android-db/termux/upgrade-stardesk-agent-027.sh");
const admin = read("admin-androiddb-v0/app/src/main/assets/index.html");
const gradle = read("admin-androiddb-v0/app/build.gradle");
const manifest = read("admin-androiddb-v0/app/src/main/AndroidManifest.xml");
const shared = read("win-agent/Agent.Shared/AgentContracts.cs");
const tray = read("win-agent/Agent.Tray/AgentTrayForm.cs");
const worker = read("win-agent/Agent.Service/AgentWorker.cs");
const gateway = read("edge/cloudflare/ani-games-db-android-stage-gateway.mjs");
const commandSql = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_enqueue_command"));

test("Agent database remains isolated from legacy PC Billing tables", () => {
  for (const table of ["rental_pcs", "agent_enrollments", "agent_devices", "agent_commands"])
    assert.ok(migration.includes("CREATE TABLE IF NOT EXISTS androiddb_v0." + table));
  for (const legacy of ["public.devices", "public.rental_accounts", "public.rental_sessions", "remaining_seconds", "expiry_at"])
    assert.ok(!migration.includes(legacy));
  assert.ok(migration.includes("agent_token_hash"));
  assert.ok(migration.includes("pair_code_hash"));
});

test("Owner-only Agent SQL administration is enforced", () => {
  for (const name of ["androiddb_v0_admin_agent_pair","androiddb_v0_admin_agent_list","androiddb_v0_admin_agent_update_pc","androiddb_v0_admin_agent_enqueue_command","androiddb_v0_admin_agent_command_status","androiddb_v0_admin_agent_revoke"])
    assert.ok(migration.includes("FUNCTION api." + name));
  assert.ok((migration.match(/private\.androiddb_v0_require_admin\(p_session_token\)/g) || []).length >= 6);
});

test("Agent enrollment is rate limited and heartbeat/ACK require bearer tokens", () => {
  for (const token of ['name === "androiddb_v0_agent_enroll_request"','androiddb-v0-agent-owner-pair','callRateLimit(key,5)','callRateLimit(key,10)','androiddb_v0_agent_heartbeat: { auth: "agent"','androiddb_v0_agent_ack: { auth: "agent"','name === "androiddb_v0_admin_agent_pair_manual"'])
    assert.ok(server.includes(token), "missing server security guard: " + token);
  assert.ok(migration.includes("agent_token_hash=encode(extensions.digest(p_agent_token,'sha256'),'hex')"));
});

test("Manual hourly tariffs accept free GPU labels and keep Coin precision at x100", () => {
  for (const name of ["androiddb_v0_admin_set_device_custom_rate","androiddb_v0_admin_agent_pair_manual","androiddb_v0_admin_agent_update_pc_manual"])
    assert.ok(ratesMigration.includes("FUNCTION api." + name));
  for (const constraint of ["rental_pcs_gpu_class_check","pc_coin_rates_gpu_class_check"])
    assert.ok(ratesMigration.includes("DROP CONSTRAINT IF EXISTS " + constraint));
  assert.ok(ratesMigration.includes("p_hourly_coin_units::numeric/100"));
  assert.ok(ratesMigration.includes("p_hourly_coin_units NOT BETWEEN 1 AND 100000000"));
  assert.ok(ratesMigration.includes("ALTER COLUMN hourly_coins TYPE numeric(16,8)"));
  for (const rpc of ["androiddb_v0_admin_set_device_custom_rate: { auth: \"admin\"","androiddb_v0_admin_agent_pair_manual: { auth: \"admin\"","androiddb_v0_admin_agent_update_pc_manual: { auth: \"admin\""])
    assert.ok(server.includes(rpc));
});

test("Admin UI collects manual prices for Agent pairing/editing and PC Host", () => {
  for (const id of ["agentPairRupiah","agentPairCoin","agentPairGpu","agentPairCode","agentPairName","agentPcList"])
    assert.ok(admin.includes('id="' + id + '"'));
  assert.ok(admin.includes('id="hostRupiah_'));
  assert.ok(admin.includes('id="hostCoin_'));
  for (const token of ["function parseManualCoinUnits","function parseManualRupiah","function readManualRate","function agentBackendError","androiddb_v0_admin_agent_pair_manual","androiddb_v0_admin_agent_update_pc_manual","androiddb_v0_admin_set_device_custom_rate"])
    assert.ok(admin.includes(token));
  assert.ok(!admin.includes("Tarif otomatis:"));
  assert.ok(!admin.includes('const items=["GTX 1050","GTX 1660","RTX 3060","RTX 5060"]'));
});


test("Manual tariff parser accepts plain and Indonesian grouped Rupiah and decimal Coin", () => {
  const start = admin.indexOf("function parseManualCoinUnits(raw){");
  const end = admin.indexOf("async function saveLink(id){", start);
  assert.ok(start >= 0 && end > start, "manual price helper block not found");
  const context = vm.createContext({val: value => String(value === null || value === undefined ? "" : value)});
  const helpers = vm.runInContext(admin.slice(start, end) + ";({parseManualRupiah,parseManualCoinUnits})", context);
  assert.equal(helpers.parseManualRupiah("8000"), 8000);
  assert.equal(helpers.parseManualRupiah("8.000"), 8000);
  assert.equal(helpers.parseManualRupiah("Rp 8.000"), 8000);
  assert.equal(helpers.parseManualRupiah("10,000"), 10000);
  assert.equal(helpers.parseManualCoinUnits("60"), 6000);
  assert.equal(helpers.parseManualCoinUnits("52,5"), 5250);
  assert.equal(helpers.parseManualCoinUnits("52.50"), 5250);
  assert.throws(() => helpers.parseManualRupiah("8,00"));
  assert.throws(() => helpers.parseManualCoinUnits("52,555"));
});

test("Admin menu uses primary tabs and moves remaining modules into the side drawer", () => {
  const nav = admin.slice(admin.indexOf('<nav class="tabs"'), admin.indexOf('<section id="dashboard"'));
  assert.ok(nav.includes("primary-tab"));
  assert.ok(nav.includes("openAllMenu()"));
  assert.ok(admin.includes('id="allMenuDrawer"'));
  for (const id of ["dashboard","pairing","active","devices","reports","users","chat","free","remote","rentals","hosts","agentpc","payments","settings"])
    assert.ok(admin.includes('data-tab="' + id + '"'), "menu entry absent: " + id);
  assert.ok(!admin.includes("overflow-x:auto;scrollbar-width:thin"));
  assert.ok(admin.includes("function navigateMenu(id)"));
});

test("Windows Agent commands remain allowlisted and avoid launching a command shell", () => {
  assert.ok(commandSql.includes("cmd NOT IN ('message','logoff','restart','shutdown')"));
  for (const token of ['"message" => await SendMessageAsync','"logoff" => LogoffInteractiveSessions','"restart" => await SchedulePowerActionAsync','"shutdown" => await SchedulePowerActionAsync','shutdown.exe','msg.exe'])
    assert.ok(worker.includes(token), "Agent command handler missing: " + token);
  assert.ok(!worker.includes("cmd.exe"));
  assert.ok(!worker.includes("powershell.exe"));
});

test("Windows Agent credential remains protected by user-scoped DPAPI", () => {
  for (const token of ["ProtectedData.Protect","ProtectedData.Unprotect","DataProtectionScope.CurrentUser","ProtectedToken"])
    assert.ok(shared.includes(token));
  assert.ok(!shared.includes('"AgentToken" = config.AgentToken'));
});

test("Windows Agent tray can hide without stopping the Service", () => {
  for (const token of ["FormClosing += OnFormClosing","e.Cancel = true","WindowState == FormWindowState.Minimized","Service Agent tetap berjalan"])
    assert.ok(tray.includes(token));
});

test("Fresh install and live upgrade apply migration 028 only to isolated StarDesk Custom", () => {
  for (const token of ["027_windows_agent_domain.sql","028_manual_pc_tariffs.sql","androiddb_v0_028_manual_rates","stardesk_custom_v0"])
    assert.ok(installer.includes(token), "installer missing: " + token);
  for (const token of ['DB_NAME="stardesk_custom_v0"','API_PORT="8789"','stardesk-custom-v0-api',"028_manual_pc_tariffs.sql","rpc_route_check","AUTH_REQUIRED","androiddb_v0_028_manual_rates"])
    assert.ok(upgrader.includes(token), "upgrade safety check missing: " + token);
  assert.ok(!upgrader.includes('API_PORT="8788"'));
  assert.ok(!upgrader.includes("ani_games_ready_stage"));
});

test("Admin Android preview package version is incremented without changing package identity", () => {
  assert.ok(gradle.includes("versionCode 11"));
  assert.ok(gradle.includes('versionName "0.2.9-agent-pricing-fix"'));
  assert.ok(manifest.includes("Ani Games Admin Coin x100 + Agent Preview 0.2.9"));
  assert.ok(gradle.includes('applicationId "com.anigames.billingadmin.coinx100preview"'));
});

test("StarDesk gateway continues forwarding the isolated /stardesk namespace generically", () => {
  assert.ok(gateway.includes('routePath.startsWith("/stardesk/")'));
  assert.ok(gateway.includes('const relayUrl = new URL(routePath + url.search, "https://relay.internal")'));
});
