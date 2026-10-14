@echo off
rem Crear usuarios, cambiar contrasenas, roles y bloqueos.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\usuarios.ps1"
if errorlevel 1 pause
