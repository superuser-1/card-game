#!/usr/bin/env bash
# Deploys the latest server-backend code in one shot: git pull, reimport any
# new/changed assets, restart the service. No interactive SSH session, no
# `su`/`sudo su` dance — this runs the whole update as a single
# non-interactive remote command and streams the output back here.
#
# Deliberately does NOT run the full deploy/provision_vm.sh — that installs
# Godot/system packages and copies systemd unit files, all of which need real
# sudo (a password prompt provision_vm.sh's own `sudo apt-get` etc. can't get
# without a TTY, which this non-interactive command doesn't have). None of
# that is needed for a routine code update anyway. If you've actually changed
# a systemd unit file or need a Godot version bump, SSH in instead
# (ssh_server.sh -> `sudo su - taurum_sc2`) and run provision_vm.sh by hand,
# where a real login shell can prompt for a password if needed. Run from a
# git-bash terminal:
#   bash deploy/deploy.sh

VM_NAME="flickbattle-server"
ZONE="us-east1-b"

# git pull + the asset reimport run as taurum_sc2 (owns ~/card-game and its
# GitHub deploy key) — neither needs sudo. The service restart runs as
# whichever account this SSH session lands as (tauru), which already has
# passwordless sudo.
REMOTE_CMD="sudo -u taurum_sc2 -i bash -c 'cd ~/card-game && git pull && /opt/godot/godot --headless --path . --import' && sudo systemctl restart flickbattle-server && echo '=== DEPLOY COMPLETE ==='"

gcloud compute ssh "$VM_NAME" --zone "$ZONE" --command "$REMOTE_CMD"
