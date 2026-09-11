@echo off
REM Double-click to launch 2 local clients pointed at the deployed cloud
REM server instead of a local one. Prompts for the server IP each time.
set /p SERVERIP="Cloud server IP (e.g. 35.207.34.103): "
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_against_cloud.ps1" -ServerIp "%SERVERIP%"
pause
