# Copies the most recent account-data backup from the VM down to
# deploy/backups/ on this dev machine. Requires an SSH key already
# authorized on the VM (the same one used to `gcloud compute ssh`, or a
# key added to the instance's metadata).
#
# Usage: .\deploy\pull_backup.ps1 -VmHost user@1.2.3.4

param(
	[Parameter(Mandatory = $true)]
	[string]$VmHost
)

$ErrorActionPreference = "Stop"
$localDir = Join-Path $PSScriptRoot "backups"
New-Item -ItemType Directory -Force -Path $localDir | Out-Null

$latest = ssh $VmHost "ls -t ~/card-game/deploy/backups/flickbattle-*.tar.gz | head -1"
if (-not $latest) {
	Write-Error "No backups found on ${VmHost}:~/card-game/deploy/backups/"
}

Write-Host "Pulling $latest ..."
scp "${VmHost}:$latest" $localDir
Write-Host "Saved to $localDir"
