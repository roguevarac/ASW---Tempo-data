# Auditor de Rankings Digitales: abre la aplicacion (y enciende el servidor en Ubuntu si hace falta), sin ventanas negras.
# Lo genera "bash ranking.sh acceso-directo" en %LOCALAPPDATA%\RankingDigital (no editar: se regenera al actualizar).
#   (sin opciones)   abre la aplicacion en su propia ventana; si el servidor no estaba prendido, lo enciende
#   -SoloServidor    enciende el servidor sin abrir nada (arranque automatico al iniciar Windows)
#   -Apagar          apaga el sistema (los datos quedan guardados)
param([switch]$SoloServidor, [switch]$Apagar)
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$Distro = '__DISTRO__'
$Proyecto = '__PROYECTO__'
$Puerto = __PUERTO__
$Url = "http://localhost:$Puerto/"
$Log = Join-Path $PSScriptRoot 'lanzador.log'

function Anotar($texto) { Add-Content -Path $Log -Value "$(Get-Date -Format s) $texto" }
function Comillas($s) { if ($s -match '\s') { return '"' + $s + '"' } else { return $s } }
function Wsl($argumentos, [switch]$Esperar) {
    $lista = @($argumentos | ForEach-Object { Comillas $_ })
    if ($Esperar) { Start-Process -FilePath 'wsl.exe' -ArgumentList $lista -WindowStyle Hidden -Wait }
    else { Start-Process -FilePath 'wsl.exe' -ArgumentList $lista -WindowStyle Hidden }
}
function Responde {
    try { return ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "$($Url)health").StatusCode -eq 200) } catch { return $false }
}
# El "mantenedor" es un wsl.exe oculto que deja Ubuntu prendido (y con el, Docker, el sistema y la carga de YouTube).
function Mantenedores {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" | Where-Object { $_.CommandLine -like '*abrir --mantener*' })
}
function Encender {
    if ((Mantenedores).Count -gt 0) { return }
    Wsl @('-d', $Distro, '-u', 'root', '--', 'service', 'docker', 'start') -Esperar   # como root: no pide contrasena
    Wsl @('-d', $Distro, '--cd', $Proyecto, '--', 'bash', 'ranking.sh', 'abrir', '--mantener', '--sin-navegador')
    Anotar 'servidor encendido'
}
function Navegador {
    $candidatos = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe")
    foreach ($c in $candidatos) { if (-not $c.StartsWith('\') -and (Test-Path $c)) { return $c } }
    return $null
}
# Ventana propia de la aplicacion (sin pestanas ni barra de direcciones). Sin Edge ni Chrome, el navegador comun.
function Abrir-Ventana($destino) {
    $n = Navegador
    if ($n) { Start-Process -FilePath $n -ArgumentList @("--app=$destino") } else { Start-Process $destino }
}

if ($Apagar) {
    Wsl @('-d', $Distro, '--cd', $Proyecto, '--', 'bash', 'ranking.sh', 'detener') -Esperar
    foreach ($m in Mantenedores) { Stop-Process -Id $m.ProcessId -Force }
    Anotar 'sistema apagado'
    exit 0
}
Encender
if ($SoloServidor) { exit 0 }
if (Responde) { Abrir-Ventana $Url }
else {
    $pantalla = [Uri]::new((Join-Path $PSScriptRoot 'iniciando.html')).AbsoluteUri   # file:///C:/.../iniciando.html
    Abrir-Ventana $pantalla
}
