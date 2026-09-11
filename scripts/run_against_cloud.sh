#!/usr/bin/env bash
# Launches a single local client pointed at the deployed cloud server
# instead of a local one. Run from a git-bash terminal:
#   bash scripts/run_against_cloud.sh <server-ip> [profile] [port]
#
# Examples:
#   bash scripts/run_against_cloud.sh 35.207.34.103
#   bash scripts/run_against_cloud.sh 35.207.34.103 p1
#
# `profile` (optional, default "p1") keeps separate saved logins if you run
# this more than once at a time — see client/session.gd's --profile= flag.

set -e

if [ -z "$1" ]; then
	echo "Usage: bash scripts/run_against_cloud.sh <server-ip> [profile] [port]" >&2
	exit 1
fi

SERVER_IP="$1"
PROFILE="${2:-p1}"
PORT="${3:-8910}"

GODOT="/c/Users/tauru/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
PROJECT="/c/Users/tauru/Projects/VS/CardGame"

echo "Starting client (profile=$PROFILE) -> ${SERVER_IP}:${PORT} ..."
"$GODOT" --path "$PROJECT" -- --address="$SERVER_IP" --port="$PORT" --profile="$PROFILE" &

echo ""
echo "Launched. This terminal can be closed; the client keeps running detached."
echo "Run again with a different profile (e.g. p2) to open a second client."
