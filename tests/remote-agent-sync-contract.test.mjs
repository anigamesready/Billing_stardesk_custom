import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const read = (path) => fs.readFileSync(path, "utf8");

test("Remote client uses User ID-only login with generated install identity", () => {
  const html = read("android-client/app/src/main/assets/index.html");
  assert.match(html, /androiddb_v0_remote_login",\{p_rental_code:rentalCode,p_client_install_id:clientId\}/);
  assert.doesNotMatch(html, /activationCode|activation_code|p_activation_code/i);
  assert.match(html, /native\.getClientId\(\)/);
  assert.match(html, /AndroidKeyStore|secretSet\("remote_access_token"/);
});

test("Remote inventory uses Windows Agent data and does not enable billing before stream validation", () => {
  const migration = read("backend/android-db/migrations/030_agent_remote_pc_sync.sql");
  assert.match(migration, /FROM androiddb_v0\.rental_pcs pc/);
  assert.match(migration, /LEFT JOIN androiddb_v0\.agent_devices/);
  assert.match(migration, /LEFT JOIN androiddb_v0\.stardesk_pairings/);
  assert.match(migration, /'available',false/);
  assert.match(migration, /'host_agent_ready',false/);
  assert.match(migration, /'can_start',false/);
  assert.doesNotMatch(migration, /FROM public\.devices/);
});

test("StarDesk verification code is encrypted server-side; DB stores cipher tuple only", () => {
  const server = read("backend/android-db/server/server.mjs");
  const migration = read("backend/android-db/migrations/030_agent_remote_pc_sync.sql");
  assert.match(server, /ANI_STARDESK_PAIRING_KEY/);
  assert.match(server, /createCipheriv\("aes-256-gcm"/);
  assert.match(server, /verificationCode/);
  assert.match(server, /androiddb_v0_agent_sync_stardesk_pairing/);
  assert.match(migration, /verification_ciphertext/);
  assert.match(migration, /verification_nonce/);
  assert.match(migration, /verification_tag/);
  assert.doesNotMatch(migration, /'verification_code'\s*,\s*p_verification_code/);
  assert.match(server, /androiddb_v0_remote_login\(\$1::text,\$2::text\)/);
  assert.doesNotMatch(server, /androiddb_v0_admin_issue_activation/);
});

test("Windows Agent capture is local-pipe only and never logs plaintext code", () => {
  const worker = read("win-agent/Agent.Service/AgentWorker.cs");
  const tray = read("win-agent/Agent.Tray/AgentTrayForm.cs");
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  const client = read("win-agent/Agent.Tray/AgentCapturePipeClient.cs");
  assert.match(worker, /NamedPipeServerStreamAcl\.Create/);
  assert.match(worker, /WellKnownSidType\.InteractiveSid/);
  assert.match(worker, /androiddb_v0_agent_sync_stardesk_pairing/);
  assert.match(tray, /Sinkronkan StarDesk/);
  assert.match(capture, /AutomationElement\.RootElement/);
  assert.match(capture, /VerificationCode/);
  assert.match(client, /NamedPipeClientStream/);
  assert.doesNotMatch(worker, /Log\w*\([^\n]*verificationCode/i);
  assert.doesNotMatch(worker, /logger\.[A-Za-z]+\([^\n]*line/);
});

test("Upgrade script is isolated and provisions private AES key without printing it", () => {
  const script = read("backend/android-db/termux/upgrade-stardesk-remote-sync-030.sh");
  assert.match(script, /DB_NAME="stardesk_custom_v0"/);
  assert.match(script, /API_PORT="8789"/);
  assert.match(script, /SERVICE_NAME="stardesk-custom-v0-api"/);
  assert.match(script, /ANI_STARDESK_PAIRING_KEY/);
  assert.match(script, /randomBytes\(32\)/);
  assert.match(script, /chmod 600 "\$ENV_FILE"/);
  assert.match(script, /029_androiddb_v0_remote_userid_agent_inventory\.sql/);
  assert.match(script, /030_agent_remote_pc_sync\.sql/);
  assert.doesNotMatch(script, /sv (restart|down|up) (ani-games-ready-api|postgres)/);
});

test("Remote displays Agent PC inventory and keeps native StarDesk launch separate", () => {
  const html = read("android-client/app/src/main/assets/index.html");
  assert.match(html, /Windows Agent/);
  assert.match(html, /stardesk_device_id/);
  assert.match(html, /stardesk:\/\/external\/device\/control/);
  assert.match(html, /Penagihan Coin tetap dikunci/);
});


test("One-click Windows Setup elevates, preserves pairing, updates existing service, and keeps uninstall credentials", () => {
  const iss = read("win-agent/installer/AniGamesReady-StarDesk-Agent.iss");
  const prepare = read("win-agent/installer/prepare-install.ps1");
  const complete = read("win-agent/installer/complete-install.ps1");
  const cleanup = read("win-agent/installer/cleanup-uninstall.ps1");

  assert.match(iss, /PrivilegesRequired=admin/);
  assert.match(iss, /PrepareToInstall/);
  assert.match(iss, /complete-install\.ps1/);
  assert.match(iss, /cleanup-uninstall\.ps1/);
  assert.match(iss, /Agent\.Service/);
  assert.match(iss, /Agent\.Tray/);

  assert.match(prepare, /AniGamesReadyStarDeskAgent/);
  assert.match(prepare, /private\\agent\.json/);
  assert.match(prepare, /credential ProgramData tidak ditemukan/);
  assert.match(prepare, /Stop-Service/);
  assert.match(prepare, /backupPath/);

  assert.match(complete, /Get-Service -Name \$serviceName/);
  assert.match(complete, /sc\.exe config/);
  assert.match(complete, /sc\.exe create/);
  assert.match(complete, /LocalSystem/);
  assert.match(complete, /Start-Service/);
  assert.match(complete, /Start-Process -FilePath \$trayExe/);

  assert.match(cleanup, /sc\.exe delete/);
  assert.match(cleanup, /Deliberately preserve %ProgramData%/);
  assert.doesNotMatch(cleanup, /Remove-Item.*StarDeskAgent/i);
});
