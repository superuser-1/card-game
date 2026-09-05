# Starts a single solo-vs-bot instance. Only ever stops a process THIS
# script previously started (tracked by PID) — never touches the Godot
# editor or anything else, even though it's the same executable.

$ErrorActionPreference = "Stop"

$godot = "C:\Users\tauru\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
$project = "C:\Users\tauru\Projects\VS\CardGame"
$pidFile = Join-Path $PSScriptRoot ".flickbattle_solo_pid.txt"

# Format is "PID,StartTimeTicks" — the start-time check means that if the
# tracked PID was already reused by an unrelated process (Windows recycles
# PID numbers once a process exits), we recognize that and skip killing it,
# instead of blindly stopping whatever now holds that PID.
if (Test-Path $pidFile) {
    Write-Host "Stopping previous solo match..."
    $parts = (Get-Content $pidFile) -split ","
    $procId = $parts[0] -as [int]
    $startTicks = $parts[1] -as [long]
    if ($procId) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc -and $proc.StartTime.Ticks -eq $startTicks) {
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

Write-Host "Importing any new/changed assets..."
& $godot --path $project --headless --import
Start-Sleep -Seconds 1

Write-Host "Starting solo match (vs bot)..."
$logOut = Join-Path $env:TEMP "flickbattle_solo.log"
$logErr = Join-Path $env:TEMP "flickbattle_solo.err.log"
$solo = Start-Process -FilePath $godot -ArgumentList @("--path", $project, "--", "--solo") -PassThru -RedirectStandardOutput $logOut -RedirectStandardError $logErr
"$($solo.Id),$($solo.StartTime.Ticks)" | Out-File -FilePath $pidFile -Encoding ascii

Write-Host ""
Write-Host "Launched. Your Godot editor (if open) was left alone."
Write-Host "Run this script again any time to stop it and start a fresh match."
