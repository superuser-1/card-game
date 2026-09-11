# Deploying the Flick Battle server

Runs the same headless Godot binary used locally (`scripts/run_local.*`),
supervised by systemd, on a free-tier GCE `e2-micro` VM. No export
templates involved — this is the engine binary running the project from a
git checkout, same as local dev.

## One-time GCP setup

1. Create/select a GCP project, enable the Compute Engine API.
2. Create the VM: machine type `e2-micro`, region `us-east1` (any zone),
   Debian 12 image — required to stay inside the Always Free allowance.
3. Compute Engine -> VPC network -> IP addresses: reserve a static
   external IP and attach it to the VM (free while attached to a running
   instance).
4. VPC network -> Firewall: add a rule allowing **UDP ingress on port
   8910** from `0.0.0.0/0` (the game's port, `NetConfig.DEFAULT_PORT`).
   SSH (22) is open by default via GCP's standard rule.
5. On GitHub: repo Settings -> Deploy keys -> add a new **read-only**
   deploy key (generate a keypair on the VM with `ssh-keygen`, paste the
   public half in). Keeps the VM's access scoped to just this repo.

## First deploy

```bash
# On the VM:
git clone git@github.com:superuser-1/card-game.git ~/card-game
cd ~/card-game
git checkout server-backend   # or master once this branch is merged
bash deploy/provision_vm.sh
```

`provision_vm.sh` downloads the matching Godot 4.7.2 Linux binary,
imports project assets, and installs/enables:
- `flickbattle-server.service` — the game server, `Restart=on-failure`,
  starts on boot.
- `flickbattle-backup.timer` — runs `backup_accounts.sh` daily.

**`e2-micro` only has ~1GB RAM, which is NOT enough to run `--import` on a
large asset batch** (confirmed during first deploy: it silently stalled,
and eventually starved the box badly enough that even opening a new SSH
session hung). Actual runtime footprint of the server itself is tiny
(~60-150MB) — it's specifically the one-time/occasional asset (re)import
that needs headroom. If a future `git pull` brings in a lot of new art and
`--import` seems to hang or the VM gets sluggish, don't fight it on
`e2-micro`:
1. Stop the VM, Edit → machine type → `e2-medium` (or bigger), Start.
2. Re-run the import: `/opt/godot/godot --headless --path ~/card-game --import`
   (or just `bash deploy/provision_vm.sh` again — idempotent).
3. Once it's done, stop → Edit → back to `e2-micro` → Start.
Costs a few cents for the hour it's upsized; far less painful than waiting
out a starved 1GB import.

## Day-to-day

Deploy an update:
```bash
cd ~/card-game && git pull
bash deploy/provision_vm.sh   # idempotent — re-import assets, refresh units
sudo systemctl restart flickbattle-server
```

Check on it:
```bash
systemctl status flickbattle-server
journalctl -u flickbattle-server -f      # live logs
systemctl list-timers flickbattle-backup.timer
ss -uln | grep 8910                      # confirm it's actually listening
```

Restore a backup (server should be stopped first):
```bash
sudo systemctl stop flickbattle-server
tar -xzf deploy/backups/flickbattle-<timestamp>.tar.gz \
    -C "$(find ~/.local/share/godot/app_userdata -maxdepth 2 -type d -name flickbattle)"
sudo systemctl start flickbattle-server
```

Pull the latest backup down to a dev machine:
```powershell
.\deploy\pull_backup.ps1 -VmHost you@<static-ip>
```

Point local dev clients at the cloud server instead of localhost:
```powershell
.\scripts\run_against_cloud.ps1 -ServerIp <static-ip>
```

## Known limits (fine for now, revisit if it becomes a problem)

- `e2-micro` is 1 shared vCPU / ~1GB RAM — plenty for dev-scale testing,
  will need a paid tier (e.g. Hetzner CX23, DigitalOcean $6/mo droplet)
  once concurrent player counts grow.
- Backups are on-box plus a manual `scp` pull — no automated off-box
  storage (e.g. GCS) yet.
- No exported/compiled builds yet — server and any test clients run from
  source via the engine binary.
