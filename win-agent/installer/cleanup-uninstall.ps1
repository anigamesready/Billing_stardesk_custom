$ErrorActionPreference = "SilentlyContinue"
$serviceName = "AniGamesReadyStarDeskAgent"
Get-Process -Name "AniGamesReady.Agent.Tray" | Stop-Process -Force

$service = Get-Service -Name $serviceName
if ($null -ne $service) {
    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $serviceName -Force
        $service = Get-Service -Name $serviceName
        $service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(20)
        )
    }
    & sc.exe delete $serviceName | Out-Null
}
# Deliberately preserve %ProgramData%\AniGamesReady\StarDeskAgent so reinstall
# can reuse the existing protected Agent identity and pairing.
