@echo off
REM Double-click to (re)start a local networked match: 1 server + 2 clients.
REM Only stops processes it previously started itself — safe to run even
REM while you have the Godot editor open separately.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_local.ps1"
pause
