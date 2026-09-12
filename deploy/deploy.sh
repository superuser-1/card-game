#!/usr/bin/env bash
# Deploys the latest server-backend code in one shot: git pull, reimport
# assets, restart the service. No interactive SSH session, no `su`/`sudo su`
# dance — this runs the whole update as a single non-interactive remote
# command and streams the output back here. Run from a git-bash terminal:
#   bash deploy/deploy.sh

VM_NAME="flickbattle-server"
ZONE="us-east1-b"

# git pull + the reimport run as taurum_sc2 (owns ~/card-game and its
# GitHub deploy key); the service restart runs as whichever account this
# SSH session lands as (tauru), which already has passwordless sudo.
REMOTE_CMD="sudo -u taurum_sc2 -i bash -c 'cd ~/card-game && git pull && bash deploy/provision_vm.sh' && sudo systemctl restart flickbattle-server && echo '=== DEPLOY COMPLETE ==='"

gcloud compute ssh "$VM_NAME" --zone "$ZONE" --command "$REMOTE_CMD"
