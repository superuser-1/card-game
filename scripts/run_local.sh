#!/usr/bin/env bash
# Kills any leftover Godot processes, then launches one authoritative server
# and two game clients for local play. Run from a git-bash terminal:
#   bash scripts/run_local.sh

set -e

GODOT="/c/Users/tauru/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
PROJECT="/c/Users/tauru/Projects/VS/CardGame"

echo "Stopping any previous Godot instances..."
powershell -NoProfile -Command "Get-Process | Where-Object { \$_.ProcessName -like 'Godot*' } | Stop-Process -Force -ErrorAction SilentlyContinue"
sleep 1

echo "Importing any new/changed assets..."
"$GODOT" --path "$PROJECT" --headless --import
sleep 1

echo "Starting server..."
# Local dev only: --mm-any pairs the two test clients regardless of Elo drift;
# --bot-fill-seconds=600 effectively disables bot-fill so queuing one client
# slightly before the other still yields a PvP match.
"$GODOT" --path "$PROJECT" --headless -- --server --mm-any --bot-fill-seconds=600 &
sleep 2

echo "Starting client 1 (Player 1)..."
"$GODOT" --path "$PROJECT" -- --profile=p1 &
sleep 1

echo "Starting client 2 (Player 2)..."
# Separate --profile so the two clients keep independent saved logins.
"$GODOT" --path "$PROJECT" -- --profile=p2 &

echo ""
echo "Launched: 1 server + 2 client windows. This terminal can be closed;"
echo "the processes keep running detached. Run this script again any time"
echo "to kill everything and start a fresh match."
