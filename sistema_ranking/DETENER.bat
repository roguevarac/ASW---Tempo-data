@echo off
rem Apaga el sistema (los datos quedan guardados). Para volver a usarlo: el acceso directo o ABRIR_SISTEMA.bat.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\detener.ps1"
