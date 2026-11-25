# Ani Games Ready - StarDesk Host Diagnostic Collector
# Read-only. Does not install, launch, stop, modify, or reconfigure StarDesk.
# Does not collect passwords, tokens, browser data, or full command lines.

$ErrorActionPreference = 'SilentlyContinue'
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$work = Join-Path $env:TEMP "Ani-StarDesk-Diagnostic-$stamp"
$zip = Join-Path ([Environment]::GetFolderPath('Desktop')) "Ani-StarDesk-Diagnostic-$stamp.zip"
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Save-Json($Name, $Value) {
    $Value | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $work $Name) -Encoding UTF8
}

$pattern = '(?i)stardesk|gear.?up|livegearup'
$installed = @()
$registryPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($path in $registryPaths) {
    $installed += Get-ItemProperty -Path $path |
        Where-Object { $_.DisplayName -match $pattern } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallLocation, DisplayIcon
}
Save-Json 'installed-products.json' @($installed | Sort-Object DisplayName -Unique)

$processes = @()
foreach ($p in (Get-CimInstance Win32_Process | Where-Object { $_.Name -match $pattern -or $_.ExecutablePath -match $pattern })) {
    $file = $null
    $signature = $null
    if ($p.ExecutablePath -and (Test-Path -LiteralPath $p.ExecutablePath)) {
        $item = Get-Item -LiteralPath $p.ExecutablePath
        $file = [pscustomobject]@{
            ProductName = $item.VersionInfo.ProductName
            FileDescription = $item.VersionInfo.FileDescription
            FileVersion = $item.VersionInfo.FileVersion
            CompanyName = $item.VersionInfo.CompanyName
        }
        $signature = (Get-AuthenticodeSignature -FilePath $p.ExecutablePath).Status.ToString()
    }
    $processes += [pscustomobject]@{
        Name = $p.Name
        ProcessId = $p.ProcessId
        ExecutablePath = $p.ExecutablePath
        File = $file
        SignatureStatus = $signature
    }
}
Save-Json 'running-processes.json' @($processes)

$services = Get-CimInstance Win32_Service |
    Where-Object { $_.Name -match $pattern -or $_.DisplayName -match $pattern } |
    Select-Object Name, DisplayName, State, StartMode
Save-Json 'services.json' @($services)

$tasks = Get-ScheduledTask |
    Where-Object { $_.TaskName -match $pattern -or $_.TaskPath -match $pattern } |
    Select-Object TaskName, TaskPath, State
Save-Json 'scheduled-tasks.json' @($tasks)

$folderRoots = @(
    $env:ProgramFiles,
    [Environment]::GetFolderPath('ProgramFilesX86'),
    $env:ProgramData,
    $env:LOCALAPPDATA,
    $env:APPDATA
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

$folders = @()
foreach ($root in $folderRoots) {
    $folders += Get-ChildItem -LiteralPath $root -Directory -Force |
        Where-Object { $_.Name -match $pattern } |
        Select-Object @{n='Root';e={$root}}, FullName, LastWriteTimeUtc
}
Save-Json 'matching-folders.json' @($folders)

$providers = Get-WinEvent -ListProvider * |
    Where-Object { $_.Name -match $pattern } |
    Select-Object Name, LogLinks
Save-Json 'event-providers.json' @($providers)

$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
Save-Json 'system.json' ([pscustomobject]@{
    CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    WindowsCaption = $os.Caption
    WindowsVersion = $os.Version
    WindowsBuild = $os.BuildNumber
    OSArchitecture = $os.OSArchitecture
    Manufacturer = $computer.Manufacturer
    Model = $computer.Model
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
})

@'
Ani Games Ready / StarDesk Host Diagnostic

This archive contains read-only metadata used to identify the installed StarDesk
components and determine whether a supported host-session signal is exposed
locally. It does not contain passwords, tokens, browser history, full process
command lines, or file contents. It does not change or start/stop any app.

Please review the JSON files before sharing. You may remove the Computer Model
or any path/name you consider private.
'@ | Set-Content -LiteralPath (Join-Path $work 'README.txt') -Encoding UTF8

Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -CompressionLevel Optimal -Force
Write-Host ''
Write-Host 'Diagnostic selesai. File:'
Write-Host $zip
Write-Host 'Tinjau isi ZIP sebelum dibagikan.'
