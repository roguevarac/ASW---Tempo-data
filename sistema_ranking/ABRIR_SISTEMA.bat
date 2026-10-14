@echo off
rem Arranca el sistema si estaba apagado y lo abre en el navegador.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\abrir.ps1"
if errorlevel 1 pause
