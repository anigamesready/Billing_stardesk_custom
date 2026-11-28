$ErrorActionPreference = "Stop"

$serviceName = "AniGamesReadyStarDeskAgent"
$displayName = "Ani Games Ready StarDesk Agent"
$installRoot = Join-Path $env:ProgramFiles "Ani Games Ready\StarDesk Agent"
$serviceExe = Join-Path $installRoot "Agent.Service\AniGamesReady.Agent.Service.exe"
$trayExe = Join-Path $installRoot "Agent.Tray\AniGamesReady.Agent.Tray.exe"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Jalankan PowerShell sebagai Administrator."
}

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$required = @(
    (Join-Path $sourceRoot "Agent.Service\AniGamesReady.Agent.Service.exe"),
    (Join-Path $sourceRoot "Agent.Tray\AniGamesReady.Agent.Tray.exe"),
    (Join-Path $sourceRoot "README.txt")
)
foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "File build tidak ditemukan: $file"
    }
}

$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Agent versi lama ditemukan. Menghentikan Service/Tray untuk upgrade..."
    Get-Process -Name "AniGamesReady.Agent.Tray" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if ($existingService.Status -ne "Stopped") {
        Stop-Service -Name $serviceName -Force
        (Get-Service -Name $serviceName).WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
    }
}

New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
# Replace only the program binaries. Agent DPAPI credentials under ProgramData are not touched.
foreach ($folder in @("Agent.Service", "Agent.Tray")) {
    $target = Join-Path $installRoot $folder
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
Copy-Item -Path (Join-Path $sourceRoot "Agent.Service") -Destination $installRoot -Recurse
Copy-Item -Path (Join-Path $sourceRoot "Agent.Tray") -Destination $installRoot -Recurse
Copy-Item -Path (Join-Path $sourceRoot "README.txt") -Destination $installRoot -Force

$binPath = '"' + $serviceExe + '"'
if ($existingService) {
    & sc.exe config $serviceName binPath= $binPath start= delayed-auto obj= LocalSystem | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Konfigurasi ulang Windows Service gagal (sc.exe exit $LASTEXITCODE)." }
} else {
    & sc.exe create $serviceName binPath= $binPath start= delayed-auto obj= LocalSystem DisplayName= $displayName | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Pembuatan Windows Service gagal (sc.exe exit $LASTEXITCODE)." }
}

& sc.exe description $serviceName "Background Agent Ani Games Ready untuk StarDesk Custom." | Out-Null
& sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/15000/restart/30000 | Out-Null

Start-Service -Name $serviceName
(Get-Service -Name $serviceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(30))

$programs = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ani Games Ready"
$startup = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Force -Path $programs,$startup | Out-Null
$shell = New-Object -ComObject WScript.Shell
foreach ($shortcutPath in @(
    (Join-Path $programs "StarDesk Agent.lnk"),
    (Join-Path $startup "Ani Games Ready StarDesk Agent.lnk")
)) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $trayExe
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.Description = "Ani Games Ready StarDesk Agent 0.2.7 — event monitor & pairing"
    $shortcut.Save()
}

Start-Process -FilePath $trayExe
Write-Host "Ani Games Ready StarDesk Agent 0.2.7 berhasil dipasang/diperbarui."
Write-Host "Windows Service: $serviceName (Automatic / Delayed Start)"
Write-Host "Credential DPAPI di ProgramData tidak dihapus; pairing tetap dipertahankan."
Write-Host "Kode pairing awal muncul pada aplikasi Agent bila PC belum dipasangkan."
