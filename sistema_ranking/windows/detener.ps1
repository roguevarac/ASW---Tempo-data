# Apaga el sistema (los datos quedan guardados). Se corre con DETENER.bat.
. "$PSScriptRoot\comun.ps1"
Verificar-Instalado
Detener-Sistema
Ok "Sistema detenido. Los datos quedan guardados; para volver a usarlo: el acceso directo o ABRIR_SISTEMA.bat."
Read-Host "Presiona Enter para cerrar" | Out-Null
