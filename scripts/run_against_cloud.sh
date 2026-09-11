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
PID_FILE="$(dirname "$0")/.flickbattle_cloud_pids.txt"

# Stop any clients THIS script previously started — without this, re-running
# the script just piles up more clients on top of the old ones, all still
# logged into the same --profile=p1/p2 accounts, which fight over those two
# account slots on the server (one-connection-per-account kicks the older
# peer every time a newer one logs in). Left unchecked across enough re-runs
# that's a connect/kick storm on the server, not a stray local annoyance.
if [ -f "$PID_FILE" ]; then
	echo "Stopping previous cloud-test client processes..."
	while IFS= read -r pid; do
		[ -z "$pid" ] && continue
		if kill -0 "$pid" 2>/dev/null; then
			# Graceful first (WM_CLOSE -> Session._notification closes the
			# multiplayer peer cleanly, see client/session.gd), so the server
			# sees a real disconnect instead of timing the peer out. Force
			# only if it's still alive after a moment.
			taskkill //PID "$pid" >/dev/null 2>&1
			for _ in 1 2 3 4 5 6 7 8 9 10; do
				kill -0 "$pid" 2>/dev/null || break
				sleep 0.3
			done
			kill -0 "$pid" 2>/dev/null && taskkill //PID "$pid" //F >/dev/null 2>&1
		fi
	done < "$PID_FILE"
	rm -f "$PID_FILE"
fi

echo "Starting client 1 (Player 1) -> ${SERVER_IP}:${PORT} ..."
"$GODOT" --path "$PROJECT" -- --address="$SERVER_IP" --port="$PORT" --profile=p1 &
P1=$!
sleep 1

echo "Starting client 2 (Player 2) -> ${SERVER_IP}:${PORT} ..."
# Separate --profile so the two clients keep independent saved logins.
"$GODOT" --path "$PROJECT" -- --address="$SERVER_IP" --port="$PORT" --profile=p2 &
P2=$!

printf '%s\n%s\n' "$P1" "$P2" > "$PID_FILE"

echo ""
echo "Launched 2 client windows against ${SERVER_IP}:${PORT}."
echo "This terminal can be closed; the clients keep running detached."
echo ""
echo "NOTE: the deployed server runs with real matchmaking rules (no"
echo "--mm-any / short bot-fill override like local dev) -- queue BOTH"
echo "clients within ~15s of each other or the first one gets paired with"
echo "a bot instead of waiting for the second."
