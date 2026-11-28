import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL("../" + path, import.meta.url), "utf8");
const migration = read("backend/android-db/migrations/031_stardesk_invite_coin_sessions.sql");
const server = read("backend/android-db/server/server.mjs");
const installer = read("backend/android-db/termux/install-stardesk-custom-v0.sh");
const upgrader = read("backend/android-db/termux/upgrade-stardesk-coin-031.sh");
const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
const watcher = read("win-agent/Agent.Tray/StarDeskWindowEventWatcher.cs");
const tray = read("win-agent/Agent.Tray/AgentTrayForm.cs");
const pipeClient = read("win-agent/Agent.Tray/AgentCapturePipeClient.cs");
const worker = read("win-agent/Agent.Service/AgentWorker.cs");
const contracts = read("win-agent/Agent.Shared/AgentContracts.cs");
const trayProject = read("win-agent/Agent.Tray/Agent.Tray.csproj");
const serviceProject = read("win-agent/Agent.Service/Agent.Service.csproj");
const installerIss = read("win-agent/installer/AniGamesReady-StarDesk-Agent.iss");

test("Migration 031 is additive and keeps the Agent PC identity separate from legacy devices", () => {
  assert.match(migration, /ALTER TABLE androiddb_v0\.agent_devices\s+ADD COLUMN IF NOT EXISTS last_ui_monitor_at/);
  assert.match(migration, /ALTER TABLE androiddb_v0\.stardesk_pairings[\s\S]*invite_url_ciphertext[\s\S]*capture_fingerprint/);
  assert.match(migration, /rental_pc_id uuid NOT NULL REFERENCES androiddb_v0\.rental_pcs\(id\)/);
  assert.match(migration, /rental_account_id uuid NOT NULL REFERENCES androiddb_v0\.rental_accounts\(id\)/);
  assert.doesNotMatch(migration, /REFERENCES public\.devices|FROM androiddb_v0\.sessions/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS androiddb_v0\.coin_rental_sessions/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS androiddb_v0\.coin_session_billing_events/);
});

test("Invite URL and verification code are stored as authenticated-encryption tuples", () => {
  for (const column of ["invite_url_ciphertext","invite_url_nonce","invite_url_tag","verification_ciphertext","verification_nonce","verification_tag"])
    assert.ok(migration.includes(column), "missing encrypted column: " + column);
  assert.match(migration, /stardesk_pairings_invite_cipher_tuple_check[\s\S]*invite_url_ciphertext IS NULL[\s\S]*invite_url_tag IS NULL[\s\S]*invite_url_ciphertext IS NOT NULL[\s\S]*invite_url_tag IS NOT NULL/);
  assert.match(migration, /invite_url_nonce\)=16/);
  assert.match(server, /createCipheriv\("aes-256-gcm"/);
  assert.match(server, /createDecipheriv\("aes-256-gcm"/);
  assert.match(server, /crypto\.createHash\("sha256"\)/);
  assert.match(server, /ANI_STARDESK_PAIRING_KEY/);
});

test("Three-field clipboard contract is strict and only accepts the official invite URL shape", () => {
  assert.match(capture, /DeviceLabelRegex/);
  assert.match(capture, /LabelledCodeRegex/);
  assert.match(capture, /InviteUrlLabelRegex/);
  assert.match(capture, /https:\/\/app\\\.stardesk\\\.net\/invite\//);
  assert.match(capture, /TryParseCopiedCredentials\([\s\S]*out string inviteUrl/);
  assert.match(capture, /parsedUri\.Scheme != Uri\.UriSchemeHttps/);
  assert.match(capture, /parsedUri\.Host[\s\S]*app\.stardesk\.net/);
  assert.match(capture, /parsedUri\.AbsolutePath/);
  assert.match(capture, /ReadPartial\(bool forceCopy = false, bool allowCopy = true\)/);
  assert.match(capture, /if \(allowCopy && \(forceCopy/);
});

test("Agent pairing copy/sync is event-driven rather than a 4-second polling loop", () => {
  assert.doesNotMatch(tray, /autoSyncTimer|AutoSyncStarDeskAsync|Interval\s*=\s*4000/);
  assert.match(tray, /StarDeskWindowEventWatcher/);
  assert.match(tray, /QueueStarDeskProbe/);
  assert.match(tray, /ProcessDebouncedStarDeskEventAsync/);
  assert.match(tray, /ReadPartial\(allowCopy:\s*false\)/);
  assert.match(tray, /var needCopy = appJustOpened \|\| sessionJustEnded \|\| pairChanged/);
  assert.match(tray, /ReadPartial\(forceCopy:\s*true\)/);
  assert.match(tray, /lastSyncedFingerprint/);
  assert.match(tray, /GetProcessesByName\("StarDesk"\)/);
  assert.match(watcher, /SetWinEventHook/);
  assert.match(watcher, /EventObjectValueChange/);
  assert.match(watcher, /EnumWindows/);
});

test("Clipboard sync only sends all three fields, and local monitor heartbeat is a separate pipe", () => {
  assert.match(pipeClient, /stardesk_device_id = capture\.DeviceId/);
  assert.match(pipeClient, /verification_code = capture\.VerificationCode/);
  assert.match(pipeClient, /invite_url = capture\.InviteUrl/);
  assert.match(pipeClient, /SendSessionEventAsync/);
  assert.match(pipeClient, /MonitorPipeName/);
  assert.match(pipeClient, /SendMonitorHeartbeatAsync/);
  assert.match(pipeClient, /PipeName = "AniGamesReady\.StarDeskAgent\.Capture\.v1"/);
  assert.match(pipeClient, /MonitorPipeName = "AniGamesReady\.StarDeskAgent\.Monitor\.v1"/);
});

test("Windows Service receives capture/session events and meters only while UI monitor lease is live", () => {
  assert.match(worker, /RunStarDeskCapturePipeAsync/);
  assert.match(worker, /RunStarDeskMonitorPipeAsync/);
  assert.match(worker, /pairing_refresh/);
  assert.match(worker, /session_event/);
  assert.match(worker, /androiddb_v0_agent_sync_stardesk_pairing/);
  assert.match(worker, /androiddb_v0_agent_stardesk_session_event/);
  assert.match(worker, /androiddb_v0_agent_ui_monitor_heartbeat/);
  assert.match(worker, /androiddb_v0_agent_stardesk_session_tick/);
  assert.match(worker, /TimeSpan\.FromSeconds\(45\)/);
  assert.match(worker, /monitorTimeoutEndSent/);
  assert.match(worker, /NamedPipeServerStreamAcl\.Create/);
});

test("Coin session snapshots the selected PC tariff and charges by server-side elapsed seconds", () => {
  assert.match(migration, /hourly_coin_units integer NOT NULL[\s\S]*coin_scale integer NOT NULL DEFAULT 100 CHECK \(coin_scale=100\)/);
  assert.match(migration, /v_due:=round\(s\.hourly_coin_units::numeric\*v_elapsed\/3600,8\)/);
  assert.match(migration, /v_charge:=least\(v_due,v_available\)/);
  assert.match(migration, /clock_timestamp\(\)/);
  assert.match(migration, /'session_debit'/);
  assert.match(migration, /coin-session:/);
  assert.match(migration, /UNIQUE\(session_id,event_id\)/);
  assert.match(migration, /last_billed_at=clock_timestamp\(\)/);
  assert.match(migration, /status=CASE WHEN v_exhausted THEN 'ended'/);
});

test("Only one rental session may reserve each account and PC at a time", () => {
  assert.match(migration, /androiddb_v0_one_open_coin_session_per_rental[\s\S]*ON androiddb_v0\.coin_rental_sessions\(rental_account_id\)[\s\S]*status IN \('requested','connected'\)/);
  assert.match(migration, /androiddb_v0_one_open_coin_session_per_pc[\s\S]*ON androiddb_v0\.coin_rental_sessions\(rental_pc_id\)/);
  assert.match(migration, /p_idempotency_key/);
  assert.match(migration, /ANDROIDDB_V0_COIN_AGENT_OFFLINE/);
  assert.match(migration, /ANDROIDDB_V0_STARDESK_INVITE_NOT_READY/);
});

test("Agent monitor lease is required before a rental PC is advertised available", () => {
  assert.match(migration, /api\.androiddb_v0_agent_ui_monitor_heartbeat/);
  assert.match(migration, /last_ui_monitor_at>clock_timestamp\(\)-interval '45 seconds'/);
  assert.match(migration, /stardesk_session_active boolean NOT NULL DEFAULT false/);
  assert.match(migration, /IF d\.stardesk_session_active THEN[\s\S]*ANDROIDDB_V0_STARDESK_ALREADY_ACTIVE/);
  assert.match(migration, /stardesk_session_active=true,last_stardesk_session_state_at/);
  assert.match(migration, /stardesk_session_active=false,last_stardesk_session_state_at/);
  assert.match(migration, /WHERE org_id=r\.org_id AND status='requested'[\s\S]*request_expires_at<=clock_timestamp\(\)/);
  assert.match(migration, /ANDROIDDB_V0_COIN_SESSION_NO_LONGER_REQUESTABLE/);
  assert.match(migration, /api\.androiddb_v0_agent_stardesk_session_tick/);
  assert.match(migration, /end_reason=coalesce\(end_reason,'agent_heartbeat_timeout'\)/);
  assert.match(migration, /v_billing_until:=least\(clock_timestamp\(\),s\.last_billed_at\+interval '45 seconds'\)/);
});

test("Legacy two-field StarDesk pairing RPC is revoked after migration 031", () => {
  assert.match(migration, /REVOKE ALL ON FUNCTION api\.androiddb_v0_agent_sync_stardesk_pairing\(text,text,text,text,text\) FROM PUBLIC,stardesk_v0_runtime/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION api\.androiddb_v0_agent_sync_stardesk_pairing\(text,text,text,text,text,text,text,text,text\)/);
});

test("Remote request decrypts the invite URL only after remote session authentication", () => {
  assert.match(server, /if \(name === "androiddb_v0_remote_request_session"\)/);
  assert.match(server, /const token = bearer\(req\)/);
  assert.match(server, /androiddb_v0_remote_request_session\(\$1::text,\$2::uuid,\$3::text\)/);
  assert.match(server, /createDecipheriv\("aes-256-gcm"/);
  assert.match(server, /const \{invite_url_ciphertext,invite_url_nonce,invite_url_tag,\.\.\.safeResult\} = result/);
  assert.match(server, /invite_url:inviteUrl/);
});

test("New install and upgrade scripts only target the StarDesk Custom database and API", () => {
  assert.match(installer, /031_stardesk_invite_coin_sessions\.sql/);
  assert.match(installer, /androiddb_v0_031_stardesk_coin_sessions/);
  assert.match(upgrader, /DB_NAME="stardesk_custom_v0"/);
  assert.match(upgrader, /API_PORT="8789"/);
  assert.match(upgrader, /SERVICE_NAME="stardesk-custom-v0-api"/);
  assert.match(upgrader, /ANI_STARDESK_PAIRING_KEY/);
  assert.match(upgrader, /schema_version='androiddb_v0_031_stardesk_coin_sessions'/);
  assert.match(upgrader, /AUTH_REQUIRED/);
  assert.doesNotMatch(upgrader, /sv (restart|down|up) (ani-games-ready-api|postgres)/);
});

test("Agent is built consistently as version 0.2.7", () => {
  assert.match(worker, /Version = "0\.2\.7"/);
  assert.match(contracts, /AgentVersion .*"0\.2\.7"/);
  assert.match(trayProject, /<Version>0\.2\.7<\/Version>/);
  assert.match(serviceProject, /<Version>0\.2\.7<\/Version>/);
  assert.match(installerIss, /AppVersion "0\.2\.7"/);
  assert.match(installerIss, /OutputBaseFilename=.*0\.2\.7-win-x64/);
});
