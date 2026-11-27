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
  assert.match(capture, /AutomationElement\.FromHandle/);
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


test("Windows Agent falls back to secure manual StarDesk fields when UI Automation cannot read them", () => {
  const tray = read("win-agent/Agent.Tray/AgentTrayForm.cs");
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  const dialog = read("win-agent/Agent.Tray/StarDeskManualEntryDialog.cs");
  const worker = read("win-agent/Agent.Service/AgentWorker.cs");
  assert.match(tray, /StarDeskUiCapture\.ReadPartial/);
  assert.match(tray, /new StarDeskManualEntryDialog/);
  assert.match(tray, /AgentCapturePipeClient\.SyncAsync\(capture\)/);
  assert.match(capture, /DeviceValueRegex/);
  assert.match(capture, /\\d\{3\}/);
  assert.match(capture, /NormalizeDeviceId/);
  assert.match(dialog, /UseSystemPasswordChar = true/);
  assert.match(dialog, /SIMPAN & SINKRONKAN/);
  assert.match(dialog, /code\.Contains\('\\r'\)/);
  assert.match(worker, /androiddb_v0_agent_sync_stardesk_pairing/);
  assert.match(worker, /verification_code = verificationCode/);
  assert.doesNotMatch(worker, /File\.WriteAllText\([^\n]*verificationCode/i);
});


test("StarDesk 1.6.x temporary code is read from Verification Method visual row", () => {
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  assert.match(capture, /verificationmethod/);
  assert.match(capture, /CodeValueRegex/);
  assert.match(capture, /BoundingRectangle/);
  assert.match(capture, /SwShowNoActivate/);
  assert.match(capture, /RestoreOriginalWindowState/);
  assert.match(capture, /FindVerificationCode/);
  assert.match(capture, /RemoteSessionStateKnown/);
  assert.match(capture, /DetectRemoteSession/);
});

test("Windows Agent monitors code changes automatically and syncs only after a stable idle capture", () => {
  const tray = read("win-agent/Agent.Tray/AgentTrayForm.cs");
  assert.match(tray, /autoSyncTimer\.Interval = 4000/);
  assert.match(tray, /AutoSyncStarDeskAsync/);
  assert.match(tray, /candidateStableReads >= 2/);
  assert.match(tray, /candidateStableReads >= 4/);
  assert.match(tray, /capture\.RemoteSessionActive/);
  assert.match(tray, /AgentCapturePipeClient\.SyncAsync\(capture\)/);
  assert.match(tray, /lastSyncedFingerprint/);
  assert.match(tray, /DateTime\.UtcNow\.AddSeconds\(seconds\)/);
  assert.match(tray, /autoSyncTimer\.Stop\(\)/);
  assert.match(tray, /autoSyncTimer\.Start\(\)/);
  assert.doesNotMatch(tray, /verificationCode.*(WriteAllText|File\.AppendAllText)/i);
});

test("Automatic temporal sync reuses isolated encrypted pairing RPC without a new schema", () => {
  const worker = read("win-agent/Agent.Service/AgentWorker.cs");
  const server = read("backend/android-db/server/server.mjs");
  const migration = read("backend/android-db/migrations/030_agent_remote_pc_sync.sql");
  assert.match(worker, /androiddb_v0_agent_sync_stardesk_pairing/);
  assert.match(server, /createCipheriv\("aes-256-gcm"/);
  assert.match(migration, /ON CONFLICT\(rental_pc_id\) DO UPDATE SET/);
  assert.match(migration, /verification_ciphertext=EXCLUDED\.verification_ciphertext/);
  assert.doesNotMatch(migration, /verification_code\s+text/i);
});

test("Windows Agent version metadata is bumped together for the auto-sync build", () => {
  assert.match(read("win-agent/Agent.Service/AgentWorker.cs"), /Version = "0\.2\.4"/);
  assert.match(read("win-agent/Agent.Shared/AgentContracts.cs"), /AgentVersion .*"0\.2\.4"/);
  assert.match(read("win-agent/Agent.Tray/Agent.Tray.csproj"), /<Version>0\.2\.4<\/Version>/);
  assert.match(read("win-agent/Agent.Service/Agent.Service.csproj"), /<Version>0\.2\.4<\/Version>/);
  assert.match(read("win-agent/installer/AniGamesReady-StarDesk-Agent.iss"), /AppVersion "0\.2\.4"/);
});


test("StarDesk capture rejects the STARDESK title and never scans arbitrary text for an eight-character code", () => {
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  assert.match(capture, /"STARDESK"/);
  assert.match(capture, /TryParseCopiedCredentials/);
  assert.match(capture, /verificationmethod/);
  assert.doesNotMatch(capture, /foreach \(var node in nodes\)\s*if \(TryCodeToken\(node\.Text, out var candidate\)\)/);
});

test("StarDesk uses its Copy button, restores clipboard, and handles tray-hidden windows", () => {
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  assert.match(capture, /ControlType\.Button/);
  assert.match(capture, /invoke\.Invoke\(\)/);
  assert.match(capture, /Clipboard\.GetDataObject/);
  assert.match(capture, /Clipboard\.SetDataObject\(previous, true\)/);
  assert.match(capture, /SwShowNoActivate/);
  assert.match(capture, /IsIconic/);
  assert.match(capture, /RestoreOriginalWindowState/);
  assert.match(capture, /EnumWindows/);
});

test("Copied credentials parser requires a Device ID and one unambiguous valid code", () => {
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  assert.match(capture, /LabelledCodeRegex/);
  assert.match(capture, /DeviceValueRegex/);
  assert.match(capture, /candidates\.Length != 1/);
  assert.match(capture, /verificationCode = candidates\[0\]/);
  assert.match(capture, /TryParseCopiedCredentials\(copied, out _, out _\)/);
});


test("StarDesk 0.2.4 selects a main top-level window and does not stop on the first partial helper window", () => {
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  assert.match(capture, /EnumWindows/);
  assert.match(capture, /GetWindowRect/);
  assert.match(capture, /OrderByDescending\(x => x\.Title\.Contains\("StarDesk"/);
  assert.match(capture, /ThenByDescending\(x => x\.Area/);
  assert.match(capture, /bestScore/);
  assert.match(capture, /Never stop at the first partial/);
});

test("Verification Code capture cannot accept arbitrary eight-character words such as KARAKTER", () => {
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  assert.match(capture, /"KARAKTER"/);
  assert.match(capture, /minY: 8, maxY: 82/);
  assert.match(capture, /Verification Method/);
  assert.doesNotMatch(capture, /for \(var i = methodIndex \+ 1;.*24/);
  assert.doesNotMatch(capture, /CodeValueRegex\.Matches\(text\)/);
});

test("StarDesk Copy must change Windows clipboard sequence and parser accepts only explicit/isolated code", () => {
  const capture = read("win-agent/Agent.Tray/StarDeskUiCapture.cs");
  assert.match(capture, /GetClipboardSequenceNumber/);
  assert.match(capture, /sequenceBefore/);
  assert.match(capture, /currentSequence == sequenceBefore/);
  assert.match(capture, /LabelledCodeRegex/);
  assert.match(capture, /ExactCodeLineRegex/);
  assert.match(capture, /candidates\.Length != 1/);
  assert.match(capture, /Clipboard\.SetDataObject\(previous, true\)/);
  assert.match(capture, /LegacyIAccessiblePattern/);
});

test("Manual sync dialog reports safe diagnostics and does not prefill unvalidated code", () => {
  const tray = read("win-agent/Agent.Tray/AgentTrayForm.cs");
  const dialog = read("win-agent/Agent.Tray/StarDeskManualEntryDialog.cs");
  assert.match(tray, /ReadPartial\(forceCopy: true\)/);
  assert.match(tray, /capture\.Diagnostics/);
  assert.match(dialog, /nilai tebakan/);
  assert.match(dialog, /DIAGNOSTIK \(tanpa menampilkan kode\)/);
  assert.match(dialog, /sengaja dibiarkan kosong/);
});

test("Agent build version is bumped consistently to 0.2.4", () => {
  assert.match(read("win-agent/Agent.Service/AgentWorker.cs"), /Version = "0\.2\.4"/);
  assert.match(read("win-agent/Agent.Shared/AgentContracts.cs"), /AgentVersion .*"0\.2\.4"/);
  assert.match(read("win-agent/Agent.Tray/Agent.Tray.csproj"), /<Version>0\.2\.4<\/Version>/);
  assert.match(read("win-agent/Agent.Service/Agent.Service.csproj"), /<Version>0\.2\.4<\/Version>/);
  assert.match(read("win-agent/installer/AniGamesReady-StarDesk-Agent.iss"), /AppVersion "0\.2\.4"/);
});
