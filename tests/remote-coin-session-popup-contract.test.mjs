import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (path) => readFileSync(new URL("../" + path, import.meta.url), "utf8");
const html = read("android-client/app/src/main/assets/index.html");
const java = read("android-client/app/src/main/java/com/anigamesready/stardeskclient/MainActivity.java");
const gradle = read("android-client/app/build.gradle");
const manifest = read("android-client/app/src/main/AndroidManifest.xml");
const server = read("backend/android-db/server/server.mjs");
const migration = read("backend/android-db/migrations/031_stardesk_invite_coin_sessions.sql");
const upgrader = read("backend/android-db/termux/upgrade-stardesk-coin-031.sh");

test("Remote 0.6.8 build identity is bumped without changing the application ID", () => {
  assert.match(gradle, /applicationId "com\.anigamesready\.stardeskclient\.coinx100preview"/);
  assert.match(gradle, /versionCode 14/);
  assert.match(gradle, /versionName "0\.6\.8-coin-session"/);
  assert.match(manifest, /Ani Games Ready Remote Coin Session 0\.6\.8/);
  assert.match(java, /return "0\.6\.8-coin-session"/);
});

test("PLAY is offered only for a backend-available PC and requests its canonical rental_pc_id", () => {
  assert.match(html, /const available=!!p\.available&&!!state\.canStart/);
  assert.match(html, /data-play-pc=/);
  assert.match(html, /async function startRemoteSession\(rentalPcId\)/);
  assert.match(html, /p_rental_pc_id:String\(rentalPcId\)/);
  assert.match(html, /p_idempotency_key:key/);
  assert.match(html, /if\(!pc\|\|!pc\.available\|\|!state\.canStart\)/);
  assert.doesNotMatch(html, /data-open-stardesk/);
});

test("PLAY popup contains all three provider fields with working copy and direct-open controls", () => {
  assert.match(html, /id="sessionDeviceId"/);
  assert.match(html, /id="sessionCode"/);
  assert.match(html, /id="sessionInviteUrl"/);
  assert.match(html, /data-session-copy="sessionDeviceId"/);
  assert.match(html, /data-session-copy="sessionCode"/);
  assert.match(html, /data-session-copy="sessionInviteUrl"/);
  assert.match(html, /function copySessionField\(id\)/);
  assert.match(html, /function openSessionInvite\(\)/);
  assert.match(html, /BUKA LINK LANGSUNG DI STAR DESK/);
  assert.match(html, /function closeSessionPopup\(\)/);
  assert.match(html, /sessionCode"\)\.value=""/);
});

test("Remote validates direct invite URL host, path, and optional lang query before opening", () => {
  assert.match(html, /function validateInviteUrl\(value\)/);
  assert.match(html, /url\.hostname==="app\.stardesk\.net"/);
  assert.match(html, /url\.pathname/);
  assert.match(html, /keys\.every\(x=>x==="lang"\)/);
  assert.match(html, /window\.location\.href=invite/);
  assert.match(java, /isAllowedStarDeskInvite\(uri\)/);
  assert.match(java, /"app\.stardesk\.net"/);
  assert.ok(java.includes('path.matches("^/invite/[A-Za-z0-9_-]{20,256}$")'));
  assert.match(java, /i\.setPackage\("com\.stardesk"\)/);
});

test("Only an authenticated remote session reservation can release decrypted three-field data", () => {
  const routeStart = server.indexOf('if (name === "androiddb_v0_remote_request_session")');
  const routeEnd = server.indexOf('if (name === "androiddb_v0_admin_agent_pair"', routeStart);
  const route = server.slice(routeStart, routeEnd);
  assert.ok(routeStart >= 0 && routeEnd > routeStart);
  assert.match(route, /const token = bearer\(req\)/);
  assert.match(route, /androiddb_v0_remote_request_session\(\$1::text,\$2::uuid,\$3::text\)/);
  assert.match(route, /createDecipheriv\("aes-256-gcm"/);
  assert.match(route, /verificationCiphertext/);
  assert.match(route, /verificationCode/);
  assert.match(route, /inviteCiphertext/);
  assert.match(route, /inviteUrl/);
  assert.match(route, /verification_code:verificationCode/);
  assert.match(route, /invite_url:parsedInvite\.toString\(\)/);
  assert.match(route, /verification_ciphertext,verification_nonce,verification_tag/);
  assert.match(route, /invite_url_ciphertext,invite_url_nonce,invite_url_tag/);
});

test("Database returns encrypted pairing only from the reserved PC and snapshots its tariff", () => {
  const start = migration.indexOf("CREATE OR REPLACE FUNCTION api.androiddb_v0_remote_request_session");
  const end = migration.indexOf("CREATE OR REPLACE FUNCTION api.androiddb_v0_agent_ui_monitor_heartbeat", start);
  const body = migration.slice(start, end);
  assert.ok(start >= 0 && end > start);
  assert.match(body, /private\.androiddb_v0_get_client\(p_session_token\)/);
  assert.match(body, /rental_pc_id=p_rental_pc_id AND org_id=r\.org_id AND enabled/);
  assert.match(body, /stardesk_device_id/);
  assert.match(body, /verification_ciphertext/);
  assert.match(body, /invite_url_ciphertext/);
  assert.match(body, /hourly_coin_units/);
  assert.match(body, /ANDROIDDB_V0_COIN_SESSION_NO_LONGER_REQUESTABLE/);
  assert.match(body, /ANDROIDDB_V0_COIN_AGENT_OFFLINE/);
  assert.match(body, /ANDROIDDB_V0_STARDESK_INVITE_NOT_READY/);
});

test("Remote status refresh reads the server session and does not run a local billing timer", () => {
  assert.match(html, /androiddb_v0_remote_session_status/);
  assert.match(html, /setInterval\(\(\)=>refreshActiveSessionStatus\(true\),6000\)/);
  assert.match(html, /CONNECTED • COUNTER COIN AKTIF/);
  assert.match(html, /SESI TIDAK AKTIF • COUNTER COIN BERHENTI/);
  assert.match(html, /refreshActiveSessionStatus\(false\)/);
  assert.doesNotMatch(html, /setInterval\([^\n]*coin.*debit/i);
});

test("Coin x100 is converted for display while wallet/top-up/expiry calculations retain internal units", () => {
  assert.match(html, /function coinFor\(n\)[\s\S]*COIN_UNIT_SCALE/);
  assert.match(html, /function coinText\(units\)[\s\S]*\/COIN_UNIT_SCALE/);
  assert.match(html, /coinText\(state\.balance\)/);
  assert.match(html, /coinText\(l\.remaining_coins\)/);
  assert.match(html, /expiryDays\(t\)/);
  assert.match(html, /state\.balance\+c/);
  assert.match(html, /coinText\(order\.coin_amount\)/);
});

test("Session lifecycle and billing remain server-side in migration 031", () => {
  assert.match(migration, /status='requested'/);
  assert.match(migration, /status='connected'/);
  assert.match(migration, /private\.androiddb_v0_coin_rental_charge/);
  assert.match(migration, /api\.androiddb_v0_agent_stardesk_session_tick/);
  assert.match(migration, /v_due:=round\(s\.hourly_coin_units::numeric\*v_elapsed\/3600,8\)/);
  assert.match(migration, /event_name NOT IN \('connected','ended','monitor_lost'\)/);
});

test("Existing Termux updater is isolated to StarDesk Custom DB/API and preflights Remote session RPCs", () => {
  assert.match(upgrader, /DB_NAME="stardesk_custom_v0"/);
  assert.match(upgrader, /API_PORT="8789"/);
  assert.match(upgrader, /SERVICE_NAME="stardesk-custom-v0-api"/);
  assert.match(upgrader, /031_stardesk_invite_coin_sessions\.sql/);
  assert.match(upgrader, /androiddb_v0_remote_request_session/);
  assert.match(upgrader, /androiddb_v0_remote_session_status/);
  assert.doesNotMatch(upgrader, /sv (restart|down|up) (ani-games-ready-api|postgres)/);
});
