@echo off
REM Double-click to launch 2 local clients pointed at the deployed cloud
REM server instead of a local one. Defaults to the current static IP --
REM just press Enter, or type a different one if it ever changes.
set DEFAULT_IP=35.207.34.103
set /p SERVERIP="Cloud server IP [%DEFAULT_IP%]: "
if "%SERVERIP%"=="" set SERVERIP=%DEFAULT_IP%
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_against_cloud.ps1" -ServerIp "%SERVERIP%"
pause
