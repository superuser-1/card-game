#!/usr/bin/env bash
# One-time setup for a fresh Debian 12 GCE e2-micro VM. Idempotent — safe to
# re-run after a `git pull` to pick up service/timer file changes.
#
# Usage (on the VM, as a sudo-capable user):
#   git clone git@github.com:superuser-1/card-game.git ~/card-game
#   cd ~/card-game && bash deploy/provision_vm.sh
#
# Assumes the repo is already cloned at ~/card-game via a read-only GitHub
# deploy key (Settings -> Deploy keys on the repo) — see deploy/README.md.

set -euo pipefail

GODOT_VERSION="4.7.2-stable"
GODOT_ZIP="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${GODOT_ZIP}"
INSTALL_DIR="/opt/godot"
REPO_DIR="$HOME/card-game"

echo "== Installing dependencies =="
sudo apt-get update -y
sudo apt-get install -y unzip curl

echo "== Installing Godot ${GODOT_VERSION} to ${INSTALL_DIR} =="
sudo mkdir -p "$INSTALL_DIR"
if [ ! -f "${INSTALL_DIR}/godot" ]; then
	curl -fL -o "/tmp/${GODOT_ZIP}" "$GODOT_URL"
	sudo unzip -o "/tmp/${GODOT_ZIP}" -d "$INSTALL_DIR"
	sudo mv "${INSTALL_DIR}/Godot_v${GODOT_VERSION}_linux.x86_64" "${INSTALL_DIR}/godot"
	sudo chmod +x "${INSTALL_DIR}/godot"
	rm "/tmp/${GODOT_ZIP}"
else
	echo "Godot already installed, skipping download."
fi

if [ ! -d "$REPO_DIR" ]; then
	echo "ERROR: ${REPO_DIR} not found. Clone the repo there first (see deploy/README.md)." >&2
	exit 1
fi

echo "== Importing project assets (headless) =="
"${INSTALL_DIR}/godot" --headless --path "$REPO_DIR" --import

echo "== Installing systemd units =="
sudo cp "${REPO_DIR}/deploy/flickbattle-server.service" /etc/systemd/system/
sudo cp "${REPO_DIR}/deploy/flickbattle-backup.service" /etc/systemd/system/
sudo cp "${REPO_DIR}/deploy/flickbattle-backup.timer" /etc/systemd/system/

# Bake the actual user + repo path into the unit files (systemd User=/paths
# can't reference $HOME), rather than assuming a fixed username.
sudo sed -i "s|__USER__|$(whoami)|g; s|__REPO_DIR__|${REPO_DIR}|g; s|__GODOT_BIN__|${INSTALL_DIR}/godot|g" \
	/etc/systemd/system/flickbattle-server.service \
	/etc/systemd/system/flickbattle-backup.service

sudo systemctl daemon-reload
sudo systemctl enable --now flickbattle-server.service
sudo systemctl enable --now flickbattle-backup.timer

echo "== Done. Check status with: =="
echo "  systemctl status flickbattle-server"
echo "  systemctl list-timers flickbattle-backup.timer"
