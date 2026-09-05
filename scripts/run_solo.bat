@echo off
REM Double-click to play solo against the heuristic bot. Only stops a
REM process it previously started itself — safe to run even while you have
REM the Godot editor open separately.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_solo.ps1"
pause
