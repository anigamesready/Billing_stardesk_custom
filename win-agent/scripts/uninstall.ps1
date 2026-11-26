$ErrorActionPreference = "Stop"

$serviceName = "AniGamesReadyStarDeskAgent"
$installRoot = Join-Path $env:ProgramFiles "Ani Games Ready\StarDesk Agent"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Jalankan PowerShell sebagai Administrator."
}

Get-Process -Name "AniGamesReady.Agent.Tray" -ErrorAction SilentlyContinue | Stop-Process -Force
Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
& sc.exe delete $serviceName | Out-Null
if ($LASTEXITCODE -ne 0 -and (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
    throw "Gagal menghapus Windows Service $serviceName."
}

$programs = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Ani Games Ready"
$startup = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Startup"
Remove-Item -LiteralPath (Join-Path $programs "StarDesk Agent.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $startup "Ani Games Ready StarDesk Agent.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $programs -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Agent service dan program telah dihapus."
Write-Host "Credential dan identitas di ProgramData dipertahankan agar reinstall tidak membuat identitas baru."
Write-Host "Cabut pairing dari Admin bila PC tidak akan digunakan lagi."
