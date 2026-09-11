@echo off
REM Double-click to launch the admin tool pointed at the deployed cloud
REM server. Just press Enter for the current static IP, or type a different
REM one (e.g. 127.0.0.1 to point at a local server) if it ever changes.
set DEFAULT_IP=35.207.34.103
set /p SERVERIP="Server IP [%DEFAULT_IP%]: "
if "%SERVERIP%"=="" set SERVERIP=%DEFAULT_IP%
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_admin_tool.ps1" -ServerIp "%SERVERIP%"
pause
