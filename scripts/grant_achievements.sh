#!/usr/bin/env bash
# Dev cheat: fake-unlock every achievement for local accounts so the reward
# flow (avatar picker, achievement-screen reward badges, equipped cosmetics)
# can be tested without grinding stats.
#
# Kills any running Godot first -- the --server keeps accounts.json in memory
# and would overwrite the grant on its next save. Restart the server + log in
# afterwards.
#
#   bash scripts/grant_achievements.sh 1 2       # unlock all for accounts "1","2"
#   bash scripts/grant_achievements.sh --all     # every non-bot account
#   bash scripts/grant_achievements.sh --reset 1 # wipe it back for account "1"

set -e

GODOT="/c/Users/tauru/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Stopping any running Godot instances..."
powershell -NoProfile -Command "Get-Process | Where-Object { \$_.ProcessName -like 'Godot*' } | Stop-Process -Force -ErrorAction SilentlyContinue"
sleep 1

ARGS=()
for a in "$@"; do
	case "$a" in
		--all|--reset) ARGS+=("$a") ;;
		--user=*)      ARGS+=("$a") ;;
		*)             ARGS+=("--user=$a") ;;
	esac
done

"$GODOT" --headless --path "$PROJECT" --script tests/grant_achievements.gd -- "${ARGS[@]}"

echo
echo "Done. Start the server again (scripts/run_local.sh) and log in."
