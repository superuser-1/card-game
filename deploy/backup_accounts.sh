#!/usr/bin/env bash
# Tars accounts.json / matches.json / tournaments.json into a timestamped
# archive under deploy/backups/, pruning anything older than KEEP_DAYS.
# Run manually, or via the flickbattle-backup.timer systemd timer.

set -euo pipefail

KEEP_DAYS=14
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"

# Godot doesn't sanitize the project name's space in app_userdata on Linux,
# but we look it up rather than hardcoding "Flick Battle" so this keeps
# working if the project name ever changes.
DATA_DIR="$(find "$HOME/.local/share/godot/app_userdata" -maxdepth 2 -type d -name flickbattle 2>/dev/null | head -1)"

if [ -z "$DATA_DIR" ] || [ ! -f "${DATA_DIR}/accounts.json" ]; then
	echo "ERROR: couldn't find accounts.json under ~/.local/share/godot/app_userdata/*/flickbattle/" >&2
	exit 1
fi

mkdir -p "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="${BACKUP_DIR}/flickbattle-${STAMP}.tar.gz"

tar -czf "$ARCHIVE" -C "$DATA_DIR" accounts.json matches.json tournaments.json
echo "Backed up to ${ARCHIVE}"

find "$BACKUP_DIR" -name 'flickbattle-*.tar.gz' -mtime "+${KEEP_DAYS}" -delete
