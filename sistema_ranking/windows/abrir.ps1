# Arranca el sistema (si estaba apagado) y lo abre en el navegador. Se corre con ABRIR_SISTEMA.bat o el acceso directo.
# -SinNavegador: lo usa el arranque automatico al prender la PC (sin ventanas ni preguntas).
param([switch]$SinNavegador)
. "$PSScriptRoot\comun.ps1"
if ($SinNavegador) {
    # Sin ventana: si algo falla queda anotado en logs\arranque.log en lugar de esperar un Enter que nadie ve.
    function Fallar($texto) {
        New-Item -ItemType Directory -Force $Logs | Out-Null
        Add-Content -Path (Unir $Logs 'arranque.log') -Value "$(Get-Date -Format s) $texto"
        exit 1
    }
}
Verificar-Instalado
Write-Host "Arrancando Auditor de Rankings Digitales..."
Iniciar-Sistema
if (-not $SinNavegador) { Start-Process (Direccion) }
