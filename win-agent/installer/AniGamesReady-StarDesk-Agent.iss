#define AppVersion "0.2.8"
#define BundleRoot "..\..\out\WindowsAgent"

[Setup]
AppId={{7B0C17A1-E5D8-4DBA-B8B7-0A0200000001}
AppName=Ani Games Ready StarDesk Agent
AppVersion={#AppVersion}
AppPublisher=Ani Games Ready
DefaultDirName={autopf}\Ani Games Ready\StarDesk Agent
DefaultGroupName=Ani Games Ready
UninstallDisplayName=Ani Games Ready StarDesk Agent
OutputDir=..\..\out\WindowsAgent
OutputBaseFilename=Ani-Games-Ready-StarDesk-Agent-Setup-0.2.8-win-x64
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
DisableProgramGroupPage=yes
DisableDirPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
DisableStartupPrompt=yes
CloseApplications=yes
RestartApplications=no
Uninstallable=yes
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
VersionInfoCompany=Ani Games Ready
VersionInfoDescription=One-click installer for Ani Games Ready StarDesk Windows Agent
VersionInfoProductName=Ani Games Ready StarDesk Agent
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "prepare-install.ps1"; Flags: dontcopy noencryption
Source: "complete-install.ps1"; Flags: dontcopy noencryption
Source: "cleanup-uninstall.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#BundleRoot}\Agent.Service\*"; DestDir: "{app}\Agent.Service"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleRoot}\Agent.Tray\*"; DestDir: "{app}\Agent.Tray"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleRoot}\README.txt"; DestDir: "{app}"; Flags: ignoreversion
[Icons]
Name: "{commonprograms}\Ani Games Ready\StarDesk Agent"; Filename: "{app}\Agent.Tray\AniGamesReady.Agent.Tray.exe"; WorkingDir: "{app}"
Name: "{commonstartup}\Ani Games Ready StarDesk Agent"; Filename: "{app}\Agent.Tray\AniGamesReady.Agent.Tray.exe"; WorkingDir: "{app}"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\cleanup-uninstall.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveStarDeskAgentService"

[Code]
function RunPowerShellScript(const ScriptName, ScriptParameters: string): Boolean;
var
  ResultCode: Integer;
  ScriptPath: string;
  Params: string;
begin
  ExtractTemporaryFile(ScriptName);
  ScriptPath := ExpandConstant('{tmp}\') + ScriptName;
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ScriptPath + '"';
  if ScriptParameters <> '' then
    Params := Params + ' ' + ScriptParameters;
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not RunPowerShellScript('prepare-install.ps1', '') then
    Result := 'Persiapan Agent gagal. Instalasi dibatalkan agar pairing dan credential lama tetap aman.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Params: string;
begin
  if CurStep = ssPostInstall then
  begin
    Params := '-InstallRoot "' + ExpandConstant('{app}') + '"';
    if not RunPowerShellScript('complete-install.ps1', Params) then
      RaiseException('Agent gagal dipasang atau dijalankan. Periksa Windows Service AniGamesReadyStarDeskAgent.');
  end;
end;
