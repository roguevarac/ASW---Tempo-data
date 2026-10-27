# Auditor de Rankings Digitales: mantiene la PC despierta (sin suspenderse por inactividad) mientras el sistema se
# comparte con otras computadoras (bash ranking.sh compartir). Lo inicia lanzar.ps1 y termina solo cuando se apaga el
# sistema. No impide apagar la PC ni suspenderla a mano o al cerrar la tapa.
$ErrorActionPreference = 'SilentlyContinue'
$energia = Add-Type -Name Energia -Namespace AuditorRankings -PassThru -MemberDefinition `
    '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint estado);'
$despierta = [Convert]::ToUInt32('80000001', 16)   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
$sinServidor = 0
while ($sinServidor -lt 3) {
    [void]$energia::SetThreadExecutionState($despierta)
    $mantenedores = @(Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" | Where-Object { $_.CommandLine -like '*abrir --mantener*' })
    if ($mantenedores.Count -gt 0) { $sinServidor = 0 } else { $sinServidor++ }
    Start-Sleep -Seconds 60
}
