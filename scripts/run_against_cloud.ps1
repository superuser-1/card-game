# Starts 2 local clients pointed at the deployed cloud server instead of a
# local one — same PID-tracking pattern as run_local.ps1 (only ever stops
# processes this script previously started).
#
# Usage: .\scripts\run_against_cloud.ps1 -ServerIp 34.1.2.3

param(
	[Parameter(Mandatory = $true)]
	[string]$ServerIp,
	[int]$Port = 8910
)

$ErrorActionPreference = "Stop"

$godot = "C:\Users\tauru\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
$project = "C:\Users\tauru\Projects\VS\CardGame"
$pidFile = Join-Path $PSScriptRoot ".flickbattle_cloud_pids.txt"

if (Test-Path $pidFile) {
	Write-Host "Stopping previous cloud-test client processes..."
	$pending = @()
	Get-Content $pidFile | ForEach-Object {
		$parts = $_ -split ","
		$procId = $parts[0] -as [int]
		$startTicks = $parts[1] -as [long]
		if ($procId) {
			$proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
			if ($proc -and $proc.StartTime.Ticks -eq $startTicks) {
				# Ask nicely first: CloseMainWindow() posts WM_CLOSE, which
				# Session._notification (client/session.gd) handles by closing
				# the multiplayer peer cleanly before quitting, so the server
				# sees a real disconnect instead of timing the peer out.
				# Stop-Process -Force skips straight to TerminateProcess,
				# which gives it no chance to do that.
				if ($proc.CloseMainWindow()) {
					$pending += $proc
				} else {
					Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
				}
			}
		}
	}
	if ($pending.Count -gt 0) {
		$deadline = (Get-Date).AddSeconds(3)
		while ((Get-Date) -lt $deadline -and ($pending | Where-Object { -not $_.HasExited })) {
			Start-Sleep -Milliseconds 200
		}
		foreach ($proc in $pending) {
			if (-not $proc.HasExited) {
				Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
			}
		}
	}
	Remove-Item $pidFile -ErrorAction SilentlyContinue
}

$trackedLines = @()

Write-Host "Starting client 1 (Player 1) -> ${ServerIp}:${Port} ..."
$client1 = Start-Process -FilePath $godot -ArgumentList @("--path", $project, "--", "--address=$ServerIp", "--port=$Port", "--profile=p1") -PassThru -RedirectStandardOutput (Join-Path $env:TEMP "flickbattle_cloud_client1.log") -RedirectStandardError (Join-Path $env:TEMP "flickbattle_cloud_client1.err.log")
$trackedLines += "$($client1.Id),$($client1.StartTime.Ticks)"
Start-Sleep -Seconds 1

Write-Host "Starting client 2 (Player 2) -> ${ServerIp}:${Port} ..."
$client2 = Start-Process -FilePath $godot -ArgumentList @("--path", $project, "--", "--address=$ServerIp", "--port=$Port", "--profile=p2") -PassThru -RedirectStandardOutput (Join-Path $env:TEMP "flickbattle_cloud_client2.log") -RedirectStandardError (Join-Path $env:TEMP "flickbattle_cloud_client2.err.log")
$trackedLines += "$($client2.Id),$($client2.StartTime.Ticks)"

$trackedLines | Out-File -FilePath $pidFile -Encoding ascii

Write-Host ""
Write-Host "Launched 2 client windows against ${ServerIp}:${Port}."
Write-Host "Run this script again any time to stop these and start fresh."
