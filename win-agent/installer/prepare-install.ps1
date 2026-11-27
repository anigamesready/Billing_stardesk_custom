$ErrorActionPreference = "Stop"

$serviceName = "AniGamesReadyStarDeskAgent"
$installRoot = Join-Path $env:ProgramFiles "Ani Games Ready\StarDesk Agent"
$credentialRoot = Join-Path $env:ProgramData "AniGamesReady\StarDeskAgent"
$credentialFile = Join-Path $credentialRoot "private\agent.json"
$serviceExe = Join-Path $installRoot "Agent.Service\AniGamesReady.Agent.Service.exe"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Installer wajib dijalankan sebagai Administrator."
}

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $service) {
    # Existing install must keep its DPAPI identity. Abort before replacing binaries
    # if its encrypted agent credential is missing.
    if (!(Test-Path -LiteralPath $credentialFile -PathType Leaf)) {
        throw "Service Agent lama terdeteksi tetapi credential ProgramData tidak ditemukan. Installer dihentikan agar tidak membuat Device ID baru atau merusak pairing."
    }

    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $serviceName -Force
        $service = Get-Service -Name $serviceName
        $service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(30)
        )
    }

    Get-Process -Name "AniGamesReady.Agent.Tray" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $backupRoot = Join-Path $credentialRoot "updates"
    $backupPath = Join-Path $backupRoot ("setup-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
    foreach ($folder in @("Agent.Service", "Agent.Tray")) {
        $source = Join-Path $installRoot $folder
        if (Test-Path -LiteralPath $source -PathType Container) {
            Copy-Item -LiteralPath $source -Destination $backupPath -Recurse -Force
        }
    }
    Write-Host "Existing Agent preserved; binary backup: $backupPath"
} else {
    Get-Process -Name "AniGamesReady.Agent.Tray" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}


# TesseractOCR 5.5.2 native x64 binaries require the Microsoft Visual C++ 2015-2022 runtime.
$vcRuntimeKey = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
$vcRuntime = Get-ItemProperty -Path $vcRuntimeKey -ErrorAction SilentlyContinue
if ($null -eq $vcRuntime -or [int]$vcRuntime.Installed -ne 1) {
    $redistPath = Join-Path $env:TEMP "AniGamesReady-vc_redist.x64.exe"
    try {
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile $redistPath -UseBasicParsing
        $signature = Get-AuthenticodeSignature -FilePath $redistPath
        if ($signature.Status.ToString() -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch "Microsoft Corporation") {
            throw "Tanda tangan Microsoft VC++ Redistributable tidak valid."
        }
        $runtimeProcess = Start-Process -FilePath $redistPath -ArgumentList "/install /quiet /norestart" -Wait -PassThru
        if ($runtimeProcess.ExitCode -notin @(0, 3010)) {
            throw "Pemasangan Microsoft Visual C++ runtime gagal (exit $($runtimeProcess.ExitCode))."
        }
    }
    finally {
        Remove-Item -LiteralPath $redistPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Installer preparation completed."
