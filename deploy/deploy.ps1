# Deploys the latest server-backend code in one shot: git pull, reimport
# assets, restart the service. No interactive SSH session, no `su`/`sudo su`
# dance — this runs the whole update as a single non-interactive remote
# command and streams the output back here.
#
# Usage: .\deploy\deploy.ps1

$ErrorActionPreference = "Stop"

$VmName = "flickbattle-server"
$Zone = "us-east1-b"

# git pull + the reimport run as taurum_sc2 (owns ~/card-game and its
# GitHub deploy key); the service restart runs as whichever account this
# SSH session lands as (tauru), which already has passwordless sudo.
$RemoteCmd = "sudo -u taurum_sc2 -i bash -c 'cd ~/card-game && git pull && bash deploy/provision_vm.sh' && sudo systemctl restart flickbattle-server && echo '=== DEPLOY COMPLETE ==='"

gcloud compute ssh $VmName --zone $Zone --command $RemoteCmd
