@echo off
rem Apaga el sistema (los datos quedan guardados). Para volver a usarlo: ABRIR_SISTEMA.bat.
cd /d "%~dp0"
docker compose stop
echo Sistema detenido. Los datos quedan guardados.
pause
