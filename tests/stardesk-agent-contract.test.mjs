import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL("../" + path, import.meta.url), "utf8");
const migration = read("backend/android-db/migrations/027_windows_agent_domain.sql");
const server = read("backend/android-db/server/server.mjs");
const installer = read("backend/android-db/termux/install-stardesk-custom-v0.sh");
const upgrader = read("backend/android-db/termux/upgrade-stardesk-agent-027.sh");
const admin = read("admin-androiddb-v0/app/src/main/assets/index.html");
const gradle = read("admin-androiddb-v0/app/build.gradle");
const manifest = read("admin-androiddb-v0/app/src/main/AndroidManifest.xml");
const shared = read("win-agent/Agent.Shared/AgentContracts.cs");
const tray = read("win-agent/Agent.Tray/AgentTrayForm.cs");
const worker = read("win-agent/Agent.Service/AgentWorker.cs");
const commandSql = migration.slice(migration.indexOf("CREATE OR REPLACE FUNCTION api.androiddb_v0_admin_agent_enqueue_command"));

test("Agent database is separate from legacy PC Billing and device tables", () => {
  for (const table of ["rental_pcs", "agent_enrollments", "agent_devices", "agent_commands"])
    assert.match(migration, new RegExp("CREATE TABLE IF NOT EXISTS androiddb_v0\\." + table));
  assert.doesNotMatch(migration, /public\.devices|public\.rental_accounts|public\.rental_sessions|remaining_seconds|expiry_at/i);
  assert.match(migration, /agent_token_hash/);
  assert.match(migration, /pair_code_hash/);
});

test("Owner-only pairing and administration are enforced inside SECURITY DEFINER routines", () => {
  for (const name of [
    "androiddb_v0_admin_agent_pair",
    "androiddb_v0_admin_agent_list",
    "androiddb_v0_admin_agent_update_pc",
    "androiddb_v0_admin_agent_enqueue_command",
    "androiddb_v0_admin_agent_command_status",
    "androiddb_v0_admin_agent_revoke"
  ]) assert.match(migration, new RegExp("FUNCTION api\\." + name));
  assert.ok((migration.match(/private\.androiddb_v0_require_admin\(p_session_token\)/g) || []).length >= 6);
});

test("Agent enrollment is rate limited and heartbeat/ACK require a bearer token", () => {
  assert.match(server, /name === "androiddb_v0_agent_enroll_request"/);
  assert.match(server, /androiddb-v0-agent-owner-pair/);
  assert.match(server, /callRateLimit\(key,5\)/);
  assert.match(server, /callRateLimit\(key,10\)/);
  assert.match(server, /androiddb_v0_agent_heartbeat: \{ auth: "agent"/);
  assert.match(server, /androiddb_v0_agent_ack: \{ auth: "agent"/);
  assert.match(migration, /agent_token_hash=encode\(extensions\.digest\(p_agent_token,'sha256'\),'hex'\)/);
});

test("Windows Agent commands are allowlisted and do not invoke a command shell", () => {
  assert.match(commandSql, /cmd NOT IN \('message','logoff','restart','shutdown'\)/);
  assert.match(worker, /"message" => await SendMessageAsync/);
  assert.match(worker, /"logoff" => LogoffInteractiveSessions/);
  assert.match(worker, /"restart" => await SchedulePowerActionAsync/);
  assert.match(worker, /"shutdown" => await SchedulePowerActionAsync/);
  assert.doesNotMatch(worker, /cmd\.exe|powershell\.exe|ProcessStartInfo\("cmd"/i);
  assert.match(worker, /shutdown\.exe/);
  assert.match(worker, /msg\.exe/);
});

test("Service credential is protected by user-scoped Windows DPAPI", () => {
  assert.match(shared, /ProtectedData\.Protect/);
  assert.match(shared, /ProtectedData\.Unprotect/);
  assert.match(shared, /DataProtectionScope\.CurrentUser/);
  assert.match(shared, /ProtectedToken/);
  assert.doesNotMatch(shared, /"AgentToken"\s*=\s*config\.AgentToken/);
});

test("Tray minimizes and closes to tray while leaving the Windows Service running", () => {
  assert.match(tray, /FormClosing \+= OnFormClosing/);
  assert.match(tray, /e\.Cancel = true/);
  assert.match(tray, /WindowState == FormWindowState\.Minimized/);
  assert.match(tray, /Service Agent tetap berjalan/);
});

test("Admin panel adds independent pairing, PC name/GPU/rate editing and Agent commands", () => {
  for (const token of ['data-tab="agentpc"', 'id="agentPairCode"', 'id="agentPcList"', "pairAgentPC()", "updateAgentPC(", "sendAgentCommand(", "revokeAgentPC("])
    assert.ok(admin.includes(token), "missing Admin Agent UI: " + token);
  assert.match(admin, /androiddb_v0_admin_agent_pair/);
  assert.match(admin, /androiddb_v0_admin_agent_enqueue_command/);
  assert.match(admin, /status ini hanya heartbeat Windows/i);
});

test("AniCoin GPU hourly rate remains stored and rendered with x100 scale", () => {
  assert.ok(migration.includes("WHEN 'GTX 1050' THEN rupiah:=6000; coin_units:=4500"));
  assert.ok(migration.includes("WHEN 'GTX 1660' THEN rupiah:=6000; coin_units:=4500"));
  assert.ok(migration.includes("WHEN 'RTX 3060' THEN rupiah:=7000; coin_units:=5250"));
  assert.ok(migration.includes("WHEN 'RTX 5060' THEN rupiah:=8000; coin_units:=6000"));
  assert.match(admin, /hourly_coin_units[^;]*\/100/);
});

test("Isolated first-install script applies migration 027 and records the Agent schema version", () => {
  assert.match(installer, /027_windows_agent_domain\.sql/);
  assert.match(installer, /androiddb_v0_027_agent/);
  assert.match(installer, /stardesk_custom_v0/);
  assert.match(upgrader, /DB_NAME="stardesk_custom_v0"/);
  assert.match(upgrader, /API_PORT="8789"/);
  assert.match(upgrader, /stardesk-custom-v0-api/);
});

test("Admin Android build identity is a separate preview version", () => {
  assert.match(gradle, /versionCode 9/);
  assert.match(gradle, /versionName "0\.2\.7-agent-preview"/);
  assert.match(manifest, /Ani Games Admin Coin x100 \+ Agent Preview 0\.2\.7/);
});
