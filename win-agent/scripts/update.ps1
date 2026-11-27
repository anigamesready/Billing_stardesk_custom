$ErrorActionPreference = "Stop"

$serviceName = "AniGamesReadyStarDeskAgent"
$installRoot = Join-Path $env:ProgramFiles "Ani Games Ready\StarDesk Agent"
$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$serviceBundle = Join-Path $sourceRoot "Agent.Service"
$trayBundle = Join-Path $sourceRoot "Agent.Tray"
$serviceExe = Join-Path $installRoot "Agent.Service\AniGamesReady.Agent.Service.exe"
$trayExe = Join-Path $installRoot "Agent.Tray\AniGamesReady.Agent.Tray.exe"
$credentialRoot = Join-Path $env:ProgramData "AniGamesReady\StarDeskAgent"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Jalankan PowerShell sebagai Administrator."
}
if (!(Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
    throw "Windows Agent lama tidak ditemukan pada lokasi instalasi standar. Gunakan install.ps1 untuk instalasi pertama."
}
foreach ($file in @(
    (Join-Path $serviceBundle "AniGamesReady.Agent.Service.exe"),
    (Join-Path $trayBundle "AniGamesReady.Agent.Tray.exe")
)) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "File Agent update tidak lengkap: $file"
    }
}

$service = Get-Service -Name $serviceName -ErrorAction Stop
if ($service.Status -ne "Stopped") {
    Stop-Service -Name $serviceName -Force
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
}

# Close the interactive tray before replacing its executable. The service identity
# and ProgramData DPAPI credential store are preserved; do not uninstall/re-pair.
Get-Process -Name "AniGamesReady.Agent.Tray" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$backupRoot = Join-Path $credentialRoot "updates"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $backupRoot $stamp
New-Item -ItemType Directory -Force -Path $backupPath | Out-Null

if (Test-Path -LiteralPath (Join-Path $installRoot "Agent.Service")) {
    Copy-Item -Path (Join-Path $installRoot "Agent.Service") -Destination $backupPath -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $installRoot "Agent.Tray")) {
    Copy-Item -Path (Join-Path $installRoot "Agent.Tray") -Destination $backupPath -Recurse -Force
}

try {
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    Copy-Item -Path $serviceBundle -Destination $installRoot -Recurse -Force
    Copy-Item -Path $trayBundle -Destination $installRoot -Recurse -Force
    Copy-Item -Path (Join-Path $sourceRoot "README.txt") -Destination $installRoot -Force

    Start-Service -Name $serviceName
    $service = Get-Service -Name $serviceName
    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
    Start-Process -FilePath $trayExe
}
catch {
    try {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $oldService = Join-Path $backupPath "Agent.Service"
        $oldTray = Join-Path $backupPath "Agent.Tray"
        if (Test-Path -LiteralPath $oldService) {
            Copy-Item -Path $oldService -Destination $installRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $oldTray) {
            Copy-Item -Path $oldTray -Destination $installRoot -Recurse -Force
        }
        Start-Service -Name $serviceName
    } catch {
        Write-Warning "Pemulihan binary otomatis tidak selesai. Backup tersedia di: $backupPath"
    }
    throw
}

if (!(Test-Path -LiteralPath (Join-Path $credentialRoot "private\agent.json") -PathType Leaf)) {
    Write-Warning "Credential Agent tidak ditemukan. Jangan uninstall atau hapus ProgramData; periksa pemasangan awal."
}
Write-Host "StarDesk Windows Agent berhasil diperbarui."
Write-Host "Windows Service: RUNNING"
Write-Host "Credential DPAPI dan Agent Device ID lama dipertahankan; tidak perlu pairing ulang."
Write-Host "Backup binary: $backupPath"
Write-Host "Buka jendela StarDesk Remote Assist di PC, lalu klik Sinkronkan StarDesk pada tray Agent."
