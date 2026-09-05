# Starts 1 server + 2 clients for local networked play. Only ever stops
# processes THIS script previously started (tracked by PID in
# .flickbattle_pids.txt) — never touches the Godot editor or anything else,
# even though it's the same executable.

$ErrorActionPreference = "Stop"

$godot = "C:\Users\tauru\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
$project = "C:\Users\tauru\Projects\VS\CardGame"
$pidFile = Join-Path $PSScriptRoot ".flickbattle_pids.txt"

# Each line is "PID,StartTimeTicks" — the start-time check means that if a
# tracked PID was already reused by an unrelated process (Windows recycles
# PID numbers once a process exits), we recognize that and skip killing it,
# instead of blindly stopping whatever now holds that PID.
if (Test-Path $pidFile) {
    Write-Host "Stopping previous Flick Battle server/client processes..."
    Get-Content $pidFile | ForEach-Object {
        $parts = $_ -split ","
        $procId = $parts[0] -as [int]
        $startTicks = $parts[1] -as [long]
        if ($procId) {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc -and $proc.StartTime.Ticks -eq $startTicks) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

Write-Host "Importing any new/changed assets..."
& $godot --path $project --headless --import
Start-Sleep -Seconds 1

$trackedLines = @()

Write-Host "Starting server..."
# Local dev only:
#   --mm-any               pair the two test clients regardless of Elo drift
#   --bot-fill-seconds=600  effectively disable bot-fill so queuing one client
#                           a bit before the other still results in a PvP match
$server = Start-Process -FilePath $godot -ArgumentList @("--path", $project, "--headless", "--", "--server", "--mm-any", "--bot-fill-seconds=600") -PassThru -RedirectStandardOutput (Join-Path $env:TEMP "flickbattle_server.log") -RedirectStandardError (Join-Path $env:TEMP "flickbattle_server.err.log")
$trackedLines += "$($server.Id),$($server.StartTime.Ticks)"
Start-Sleep -Seconds 2

Write-Host "Starting client 1 (Player 1)..."
$client1 = Start-Process -FilePath $godot -ArgumentList @("--path", $project, "--", "--profile=p1") -PassThru -RedirectStandardOutput (Join-Path $env:TEMP "flickbattle_client1.log") -RedirectStandardError (Join-Path $env:TEMP "flickbattle_client1.err.log")
$trackedLines += "$($client1.Id),$($client1.StartTime.Ticks)"
Start-Sleep -Seconds 1

Write-Host "Starting client 2 (Player 2)..."
# Separate --profile so the two clients keep independent saved logins; without
# it the second client resumes the first's session token and the server's
# one-connection-per-account rule boots the first client.
$client2 = Start-Process -FilePath $godot -ArgumentList @("--path", $project, "--", "--profile=p2") -PassThru -RedirectStandardOutput (Join-Path $env:TEMP "flickbattle_client2.log") -RedirectStandardError (Join-Path $env:TEMP "flickbattle_client2.err.log")
$trackedLines += "$($client2.Id),$($client2.StartTime.Ticks)"

$trackedLines | Out-File -FilePath $pidFile -Encoding ascii

Write-Host ""
Write-Host "Launched: 1 server + 2 client windows. Your Godot editor (if open) was left alone."
Write-Host "Run this script again any time to stop these and start a fresh match."
