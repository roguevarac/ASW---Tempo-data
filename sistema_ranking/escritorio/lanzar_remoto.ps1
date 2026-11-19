# Auditor de Rankings Digitales: abre la aplicacion, que funciona en un servidor (esta PC ya no es el servidor).
# Lo genera "bash ranking.sh acceso-directo" (o "retirar") en %LOCALAPPDATA%\RankingDigital (no editar: se regenera).
#   (sin opciones)   abre la aplicacion en su propia ventana
#   -SoloServidor / -Apagar   no hacen nada: el servidor ya no es esta PC
param([switch]$SoloServidor, [switch]$Apagar)
$ErrorActionPreference = 'SilentlyContinue'
$Url = '__URL__'
if ($SoloServidor -or $Apagar) { exit 0 }
function Navegador {
    $candidatos = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe")
    foreach ($c in $candidatos) { if (-not $c.StartsWith('\') -and (Test-Path $c)) { return $c } }
    return $null
}
$n = Navegador
if ($n) { Start-Process -FilePath $n -ArgumentList @("--app=$Url") } else { Start-Process $Url }
