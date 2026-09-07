#!/usr/bin/env bash
# Headless integration test for the real (bot-free) tournament path: shrink-to-
# fit bracket, random byes for an odd player count, positional advancement, and
# completion. Spins up a --server --dev-tournaments plus PLAYERS headless
# --tournament-test clients. seq 0 creates an OPEN Bo1 tournament (cap 8); every
# client signs up, checks in and auto-plays its matches.
#
#   bash scripts/tournament_test.sh          # 7 players (odd -> byes)
#   PLAYERS=8 bash scripts/tournament_test.sh
#
# PASS requires: every client exits 0, seq 0 logs
# "TOURNAMENT TEST: COMPLETE winner=<non-zero>", and the server never logs a
# tournament cancel. Exits 0 on PASS, 1 on FAIL. Only touches Godot processes
# it launched (matched by the unique --port), safe with the editor open.

set -u

GODOT="${GODOT:-/c/Users/tauru/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe}"
PROJECT="${PROJECT:-/c/Users/tauru/Projects/VS/CardGame}"
PORT="${PORT:-8942}"
PLAYERS="${PLAYERS:-7}"
TAG="tt$$"
LOGDIR="$(mktemp -d)"

kill_ours() {
	powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"name like 'Godot%'\" | Where-Object { \$_.CommandLine -like '*port=$PORT*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null 2>&1
}
trap kill_ours EXIT

echo "Importing..."
"$GODOT" --path "$PROJECT" --headless --import >/dev/null 2>&1

echo "Starting server on port $PORT (--dev-tournaments)..."
"$GODOT" --path "$PROJECT" --headless -- --server --port="$PORT" --dev-tournaments \
	> "$LOGDIR/server.log" 2>&1 &
sleep 4
if ! grep -q "listening on port" "$LOGDIR/server.log"; then
	echo "SERVER FAILED TO START"; sed 's/^/  /' "$LOGDIR/server.log"; exit 1
fi

echo "Launching $PLAYERS tournament clients (tag=$TAG)..."
PIDS=()
for i in $(seq 0 $((PLAYERS - 1))); do
	"$GODOT" --path "$PROJECT" --headless -- --tournament-test --port="$PORT" \
		--tag="$TAG" --seq="$i" --players="$PLAYERS" > "$LOGDIR/c$i.log" 2>&1 &
	PIDS+=($!)
	# stagger seq 0 (the creator) ahead of the rest
	[ "$i" -eq 0 ] && sleep 2
done

echo "Waiting for clients (up to ~240s)..."
RC_ALL=0
for idx in "${!PIDS[@]}"; do
	pid="${PIDS[$idx]}"
	for _ in $(seq 1 240); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
	done
	if kill -0 "$pid" 2>/dev/null; then
		echo "  client $idx did not exit in time"; kill "$pid" 2>/dev/null; RC_ALL=1
	else
		wait "$pid"; rc=$?
		[ "$rc" -eq 0 ] || { echo "  client $idx exit $rc"; RC_ALL=1; }
	fi
done

echo
echo "----- seq 0 log (relevant) -----"
grep -E "status ->|match_found|match ended|TOURNAMENT TEST|PRIZE|PASS|FAIL" "$LOGDIR/c0.log" | sed 's/^/  /'
echo "----- prize lines (all clients) -----"
grep -h "PRIZE won" "$LOGDIR"/c*.log | sed 's/^/  /'
echo "----- server log (tournament) -----"
grep -iE "tournament|cancel" "$LOGDIR/server.log" | sed 's/^/  /' | tail -20
echo

PASS=1
[ "$RC_ALL" -eq 0 ] || { echo "FAIL: a client exited non-zero / hung"; PASS=0; }
if ! grep -qE "TOURNAMENT TEST: COMPLETE winner=[1-9][0-9]*" "$LOGDIR/c0.log"; then
	echo "FAIL: no completion with a real winner in seq 0's log"; PASS=0
fi
if grep -qi "was cancelled" "$LOGDIR"/c*.log; then
	echo "FAIL: tournament cancelled"; PASS=0
fi
# Prize payout: the champion should have logged a bucket-1 win worth 300.
if ! grep -qh "PRIZE won bucket=1 points=300" "$LOGDIR"/c*.log; then
	echo "FAIL: no 1st-place prize payout observed"; PASS=0
fi
if ! grep -qh "PRIZE won bucket=2 points=100" "$LOGDIR"/c*.log; then
	echo "FAIL: no 2nd-place prize payout observed"; PASS=0
fi

if [ "$PASS" -eq 1 ]; then
	echo "RESULT: PASS"; exit 0
else
	echo "RESULT: FAIL  (logs kept in $LOGDIR)"; trap - EXIT; kill_ours; exit 1
fi
