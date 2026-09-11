#!/usr/bin/env bash
# Launches 2 local clients pointed at the deployed cloud server instead of
# a local one. Run from a git-bash terminal:
#   bash scripts/run_against_cloud.sh <server-ip> [port]
#
# Example:
#   bash scripts/run_against_cloud.sh 35.207.34.103

set -e

if [ -z "$1" ]; then
	echo "Usage: bash scripts/run_against_cloud.sh <server-ip> [port]" >&2
	exit 1
fi

SERVER_IP="$1"
PORT="${2:-8910}"

GODOT="/c/Users/tauru/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
PROJECT="/c/Users/tauru/Projects/VS/CardGame"

echo "Starting client 1 (Player 1) -> ${SERVER_IP}:${PORT} ..."
"$GODOT" --path "$PROJECT" -- --address="$SERVER_IP" --port="$PORT" --profile=p1 &
sleep 1

echo "Starting client 2 (Player 2) -> ${SERVER_IP}:${PORT} ..."
# Separate --profile so the two clients keep independent saved logins.
"$GODOT" --path "$PROJECT" -- --address="$SERVER_IP" --port="$PORT" --profile=p2 &

echo ""
echo "Launched 2 client windows against ${SERVER_IP}:${PORT}."
echo "This terminal can be closed; the clients keep running detached."
echo ""
echo "NOTE: the deployed server runs with real matchmaking rules (no"
echo "--mm-any / short bot-fill override like local dev) -- queue BOTH"
echo "clients within ~15s of each other or the first one gets paired with"
echo "a bot instead of waiting for the second."
