# Auditor de Rankings Digitales: mientras se comparte con otras computadoras (bash ranking.sh compartir), Windows no
# suspende la PC por inactividad. No impide apagarla, suspenderla a mano ni cerrar la tapa.
# Lo copia ranking.sh en %LOCALAPPDATA%\RankingDigital (no editar: se regenera al actualizar) y lo inicia lanzar.ps1, oculto.
$ErrorActionPreference = 'SilentlyContinue'
$energia = Add-Type -Name Energia -Namespace AuditorRankings -PassThru -MemberDefinition `
    '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint estado);'
[void]$energia::SetThreadExecutionState([Convert]::ToUInt32('80000001', 16))   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
while ($true) { Start-Sleep -Seconds 3600 }
