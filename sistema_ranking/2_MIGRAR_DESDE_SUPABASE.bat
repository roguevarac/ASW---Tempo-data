@echo off
rem Trae de Supabase los datos, usuarios e historial.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\migrar.ps1"
if errorlevel 1 pause
