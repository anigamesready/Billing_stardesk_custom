param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot
)

$ErrorActionPreference = "Stop"
$serviceName = "AniGamesReadyStarDeskAgent"
$displayName = "Ani Games Ready StarDesk Agent"
$serviceExe = Join-Path $InstallRoot "Agent.Service\AniGamesReady.Agent.Service.exe"
$trayExe = Join-Path $InstallRoot "Agent.Tray\AniGamesReady.Agent.Tray.exe"
$credentialFile = Join-Path $env:ProgramData "AniGamesReady\StarDeskAgent\private\agent.json"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Installer wajib dijalankan sebagai Administrator."
}
foreach ($file in @($serviceExe, $trayExe)) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "File hasil instalasi tidak ditemukan: $file"
    }
}

# Existing DPAPI credential must not be touched. On a first install the
# Windows Service creates it under LocalSystem on first start.
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -eq $service) {
    & sc.exe create $serviceName binPath= "`"$serviceExe`"" start= delayed-auto obj= LocalSystem DisplayName= $displayName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Pembuatan Windows Service gagal (sc.exe exit $LASTEXITCODE)."
    }
} else {
    & sc.exe config $serviceName binPath= "`"$serviceExe`"" start= delayed-auto obj= LocalSystem | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Pembaruan konfigurasi Windows Service gagal (sc.exe exit $LASTEXITCODE)."
    }
}

& sc.exe description $serviceName "Background Agent Ani Games Ready untuk StarDesk Custom." | Out-Null
& sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null

Start-Service -Name $serviceName
$service = Get-Service -Name $serviceName
$service.WaitForStatus(
    [System.ServiceProcess.ServiceControllerStatus]::Running,
    [TimeSpan]::FromSeconds(30)
)

$programs = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ani Games Ready"
$startup = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Force -Path $programs, $startup | Out-Null
$shell = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in @(
    (Join-Path $programs "StarDesk Agent.lnk"),
    (Join-Path $startup "Ani Games Ready StarDesk Agent.lnk")
)) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $trayExe
    $shortcut.WorkingDirectory = $InstallRoot
    $shortcut.Description = "Ani Games Ready StarDesk Agent - status dan pairing"
    $shortcut.Save()
}

if (Test-Path -LiteralPath $credentialFile -PathType Leaf) {
    Write-Host "Credential Agent ditemukan dan dipertahankan."
} else {
    Write-Host "Instalasi pertama: Agent akan membuat Device ID dan kode pairing saat service mulai."
}
Start-Process -FilePath $trayExe
Write-Host "Ani Games Ready StarDesk Agent berhasil dipasang/diperbarui."
Write-Host "Windows Service: RUNNING"
