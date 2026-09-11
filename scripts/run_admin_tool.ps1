# Starts the standalone admin tool window pointed at a server (local or
# cloud). Separate process from the game client — see admin_tool/admin_tool.gd
# and main.gd's --admin-tool role.
#
# Usage: .\scripts\run_admin_tool.ps1 -ServerIp 34.1.2.3
#        .\scripts\run_admin_tool.ps1                    (defaults to localhost)

param(
	[string]$ServerIp = "127.0.0.1",
	[int]$Port = 8910
)

$ErrorActionPreference = "Stop"

$godot = "C:\Users\tauru\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
$project = "C:\Users\tauru\Projects\VS\CardGame"

Write-Host "Starting admin tool -> ${ServerIp}:${Port} ..."
Start-Process -FilePath $godot -ArgumentList @("--path", $project, "--", "--admin-tool", "--address=$ServerIp", "--port=$Port")
