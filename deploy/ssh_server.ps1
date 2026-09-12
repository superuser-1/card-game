# Opens an SSH session to the deployed game server via gcloud (auto-manages
# the SSH key, no manual PuTTY/key setup needed).
#
# For routine deploys, use .\deploy\deploy.ps1 instead — it does the whole
# update in one non-interactive shot. Use this script only when you actually
# need an interactive shell to poke around; once connected, `sudo su -
# taurum_sc2` gets you into the account the game server/repo checkout
# actually run under (your own login here has no access to ~/card-game).
#
# Usage: .\deploy\ssh_server.ps1

$ErrorActionPreference = "Stop"

$VmName = "flickbattle-server"
$Zone = "us-east1-b"

gcloud compute ssh $VmName --zone $Zone
