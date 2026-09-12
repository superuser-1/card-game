@echo off
REM Double-click to open an SSH session to the deployed game server.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssh_server.ps1"
pause
