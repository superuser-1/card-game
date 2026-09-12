# Admin cheat sheet

Plain-language reference for running/maintaining the Flick Battle server.
Written for someone new to SSH/Linux — add to this file yourself as you
learn new things or hit new situations, and ask Claude to add to it too.

## Deploying an update — do this first, skip the SSH stuff below

For pulling down new code and restarting the server, you don't need SSH at
all. From your own PC, in the project folder:
```powershell
.\deploy\deploy.ps1
```
One command, does everything (pull + reimport + restart), and prints the
result right there in your own terminal. This is the only thing most updates
need — read on only if you actually need to poke around on the server itself
(check logs live, inspect files, etc).

## Connecting to the server (SSH) — only for manual poking around

The server runs on a Google Cloud VM called `flickbattle-server`. To run
any command below, you need a terminal *on that VM*, not on your PC.

Easiest way (no setup, works from any browser):
1. Go to the [GCP Console](https://console.cloud.google.com/compute/instances).
2. Find `flickbattle-server` in the list.
3. Click the **SSH** button next to it. A terminal opens in your browser,
   already logged in.

**Important:** the account you land in this way is NOT the one the game
server actually runs under, and has no access to the project files. Your very
first line in that terminal should always be:
```bash
sudo su - taurum_sc2
```
No password needed — it just works. Everything below assumes you've done
this and your prompt now shows `taurum_sc2@flickbattle-server`.

## The absolute basics

- `cd ~/card-game` — go into the project folder (most commands below assume
  you're already there; only works after `sudo su - taurum_sc2` above).
- Commands starting with `sudo` need admin rights on the VM — it'll just
  work, no extra password needed (GCP handles that).
- `Ctrl+C` stops whatever's currently running/printing in the terminal.
- Closing the SSH browser tab does **not** stop the game server — it keeps
  running in the background regardless (that's what `systemd`/the
  `.service` file is for).

## Is the server up? (check status)

```bash
sudo systemctl status flickbattle-server
```
Look for `Active: active (running)`. If it says `failed` or `inactive`,
something's wrong — see logs below.

## Watch what it's doing (logs)

```bash
sudo journalctl -u flickbattle-server -n 50 --no-pager   # last 50 lines
sudo journalctl -u flickbattle-server -f                 # live, updates as it happens (Ctrl+C to stop watching)
```

## Restart it (e.g. after it seems stuck, or after deploying)

```bash
sudo systemctl restart flickbattle-server
```

## Deploy an update (push new code from your PC to the live server)

Whenever Claude commits+pushes changes on your PC, they don't reach the
live server automatically — you have to pull them down and restart. Just run,
from your own PC (see the top of this file):
```powershell
.\deploy\deploy.ps1
```

**If this pull includes a lot of new art/assets** (ask Claude if unsure),
the import step can overwhelm the VM's small amount of memory. Do this
instead:
1. In the GCP Console: select the VM → **Stop** → **Edit** → change
   *Machine type* to `e2-medium` → **Save** → **Start**.
2. Run `.\deploy\deploy.ps1` from your PC as usual.
3. Once it finishes: **Stop** the VM again → **Edit** → set *Machine type*
   back to `e2-micro` → **Save** → **Start**.

(Running as `e2-medium` costs real money per hour — `e2-micro` is free.
Only stay on `e2-medium` for the few minutes the import needs.)

## Confirm it's actually reachable

```bash
ss -uln | grep 8910   # should print a line if the server is listening
```

## Backups

Backups happen automatically once a day (`flickbattle-backup.timer`) and
are saved on the VM itself under `deploy/backups/`.

Check the backup schedule:
```bash
systemctl list-timers flickbattle-backup.timer
```

Pull the newest backup down to your own PC (run this in PowerShell **on
your PC**, not in the SSH terminal):
```powershell
.\deploy\pull_backup.ps1 -VmHost you@<static-ip>
```
**Not verified working yet** — this script does a plain `ssh`/`scp`
(bypassing gcloud's automatic key management), and the backups actually live
under `taurum_sc2`'s home directory, not yours. It may need updating the same
way `deploy.ps1` was — ask Claude to check/fix it before relying on this one.

Restore a backup (careful — this overwrites live data; server must be
stopped first):
```bash
sudo systemctl stop flickbattle-server
tar -xzf deploy/backups/flickbattle-<timestamp>.tar.gz \
    -C "$(find ~/.local/share/godot/app_userdata -maxdepth 2 -type d -name flickbattle)"
sudo systemctl start flickbattle-server
```

## The admin tool (ban players, fix elo/points, see who's online)

This runs **on your PC**, not on the server — it's a small separate
program that connects to the live server over the network.

**One-time setup — make your account an admin.** Requires SSH access to
stop the server briefly:
```bash
sudo systemctl stop flickbattle-server
cd ~/card-game
/opt/godot/godot --headless --path . --script scripts/grant_admin.gd -- --user=YOUR_USERNAME
sudo systemctl start flickbattle-server
```
(`godot` isn't on the VM's PATH — the binary lives at `/opt/godot/godot`,
installed there by `deploy/provision_vm.sh`.)
(Only needs doing once per account you want to make an admin. To undo:
same command with `--revoke` added at the end.)

**Launching the tool** — on your PC, double-click:
```
scripts\run_admin_tool.bat
```
It'll ask for the server IP (press Enter for the default). Then log in with
your normal username/password — if your account has admin rights, the
tool unlocks automatically.

**What's in it (tabs across the top):**
- **Accounts** — search by username or id; ban/unban (with a reason and a
  confirmation prompt), manually correct elo or points, and a lower panel
  with that account's last 30 matches, last 30 tournaments, last 30
  unlocks, last 30 achievements, last 30 shop purchases, and their owned/
  equipped cosmetics.
- **Online** — everyone currently connected.
- **Tournaments** — every tournament from the last N days (type a number,
  default 30), with a name filter box. Select one to see its full
  participant list, placements, and prize payouts. **Rollback Prizes**
  claws back the points/items a tournament paid out (asks for
  confirmation first) — it does NOT touch elo or quest/achievement
  progress from the matches actually played, only the prize itself, and
  only works once prizes have actually been paid.
- **Live Ranked** — every ranked match currently in progress, live score,
  both players' elo, auto-refreshes every 5s while this tab is open. A
  name filter box, and a **Force-End** button (asks for confirmation) that
  voids a stuck/abusive match with no result recorded for either side.
- **Live Custom** — same idea for friend-invite games: open lobbies still
  waiting for a second player, and in-progress custom matches, each with
  its own force-end button.
- **Stats** — a graph of how many players were online over time (24h / 7d
  / 30d buttons), sampled by the server every 5 minutes, kept for 30 days.
- **Plan Tournaments** — create a tournament yourself (one-time, or a
  recurring template that fires automatically on chosen weekdays at a set
  time, always keeping the next occurrence queued ahead of time). Prizes
  can be ANY cosmetic in the game's catalog (not just the normal
  shop-buyable ones) — a reference list at the bottom shows every id, and
  clicking one copies it to your clipboard to paste into a prize field.
  Admin-created tournaments don't charge your own points wallet for the
  prize pool. Existing recurring templates are listed with pause/delete
  controls.
- **Log** — every admin action ever taken (ban, unban, elo/points
  corrections, tournament rollbacks, force-ended matches, template
  create/delete), who did it, and when.

## Point your local game client at the live server (instead of localhost)

On your PC, double-click:
```
scripts\run_against_cloud.bat
```

## Current server details (fill in / update as these change)

- VM name: `flickbattle-server`
- Static IP: `35.207.34.103`
- Zone: `us-east1-b`
- Game port: `8910` (UDP)
- Branch the VM tracks: `server-backend`

---
*Add new sections below as new situations come up — ask Claude to keep
this file updated whenever you deploy something new.*
