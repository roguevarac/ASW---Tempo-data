@echo off
rem Instala y arranca el sistema en esta PC.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\instalar.ps1"
if errorlevel 1 pause
