@echo off
REM Double-click to deploy: git pull + reimport + restart on the live server,
REM all in one shot (see deploy.ps1). Window stays open so you can read the
REM result — press any key to close it once it's done.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1"
pause
