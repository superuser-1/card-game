#!/usr/bin/env bash
# Headless integration test for the mid-match reconnect / abandon-grace path
# (net_node RECONNECT_GRACE_SECONDS + _try_rejoin_match).
#
#   bash scripts/reconnect_test.sh
#
# Spins up a --server plus a --reconnect-test client (drops mid-match, then
# resumes its token) and a plain --bot. PASS requires:
#   * the reconnect client prints "RECONNECT TEST: PASS" and exits 0
#   * the server log shows "rejoined match"
#   * the server did NOT decide the match by the grace timer
#     ("wins by default")
# Exits 0 on PASS, 1 on FAIL. Only touches Godot processes it launched (matched
# by the unique --port), so it is safe to run with the editor open.

set -u

GODOT="${GODOT:-/c/Users/tauru/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe}"
PROJECT="${PROJECT:-/c/Users/tauru/Projects/VS/CardGame}"
PORT="${PORT:-8931}"
LOGDIR="$(mktemp -d)"

kill_ours() {
	powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"name like 'Godot%'\" | Where-Object { \$_.CommandLine -like '*port=$PORT*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }" >/dev/null 2>&1
}
trap kill_ours EXIT

echo "Importing..."
"$GODOT" --path "$PROJECT" --headless --import >/dev/null 2>&1

echo "Starting server on port $PORT..."
# --mm-any: pair the two clients regardless of Elo. --bot-fill-seconds huge:
# never fill with a bot, so we always get the real PvP pairing.
"$GODOT" --path "$PROJECT" --headless -- --server --port="$PORT" --mm-any --bot-fill-seconds=9999 \
	> "$LOGDIR/server.log" 2>&1 &
sleep 4
if ! grep -q "listening on port" "$LOGDIR/server.log"; then
	echo "SERVER FAILED TO START"; sed 's/^/  /' "$LOGDIR/server.log"; exit 1
fi

echo "Starting reconnect client + plain bot..."
"$GODOT" --path "$PROJECT" --headless -- --reconnect-test --port="$PORT" > "$LOGDIR/recon.log" 2>&1 &
RECON=$!
"$GODOT" --path "$PROJECT" --headless -- --bot --port="$PORT" > "$LOGDIR/plain.log" 2>&1 &

for _ in $(seq 1 130); do
	kill -0 "$RECON" 2>/dev/null || break
	sleep 1
done

RC=1
if kill -0 "$RECON" 2>/dev/null; then
	echo "reconnect client did not exit in time"
	kill "$RECON" 2>/dev/null
else
	wait "$RECON"; RC=$?
fi

echo
echo "----- server.log (relevant) -----"
grep -E "dropped — holding|rejoined match|abandoned, seat|wins by default|Opponent reconnected" "$LOGDIR/server.log" | sed 's/^/  /'
echo "----- recon.log (relevant) -----"
grep -E "registering|entering queue|dropping connection|RESUMED|rebuilding|MATCH ENDED|RECONNECT TEST" "$LOGDIR/recon.log" | sed 's/^/  /'
echo

PASS=1
[ "$RC" -eq 0 ] || { echo "FAIL: reconnect client exit code $RC"; PASS=0; }
grep -q "RECONNECT TEST: PASS" "$LOGDIR/recon.log" || { echo "FAIL: client did not report PASS"; PASS=0; }
grep -q "rejoined match" "$LOGDIR/server.log" || { echo "FAIL: server never logged a rejoin"; PASS=0; }
if grep -q "wins by default" "$LOGDIR/server.log"; then
	echo "FAIL: grace timer decided the match (reconnect was too slow / not rebound)"; PASS=0
fi

if [ "$PASS" -eq 1 ]; then
	echo "RESULT: PASS"; exit 0
else
	echo "RESULT: FAIL  (logs kept in $LOGDIR)"; trap - EXIT; kill_ours; exit 1
fi
