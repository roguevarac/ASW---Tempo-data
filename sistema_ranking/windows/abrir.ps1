# Arranca el sistema (si estaba apagado) y lo abre en el navegador. Se corre con ABRIR_SISTEMA.bat.
. "$PSScriptRoot\comun.ps1"
Verificar-Docker
if (-not (Test-Path (Ruta-Env))) { Fallar "Primero corre 1_INSTALAR.bat." }
docker compose up -d
Esperar-Sistema
Start-Process (Direccion)
