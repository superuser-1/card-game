extends SceneTree
## Dev-only cheat: flip is_admin on an account. Necessary because there is no
## other way to mint the FIRST admin (every RPC path that could set it is
## itself gated on already being an admin — see net_node.gd's _require_admin).
## Once at least one admin account exists, further admin grants/revokes could
## reasonably move into the admin tool itself; this script stays as the
## bootstrap path and a headless/CI-friendly escape hatch.
##
## Run with the server STOPPED (it holds accounts.json in memory and would
## overwrite this on its next save), then restart it.
##
##   godot --headless --path . --script scripts/grant_admin.gd -- --user=NAME
##   godot --headless --path . --script scripts/grant_admin.gd -- --user=NAME --revoke
##
## Flags:
##   --user=NAME   account username (case-insensitive). Required.
##   --revoke      clear is_admin instead of setting it.
##   --data=DIR    store dir (default: user://flickbattle/)

func _initialize() -> void:
	var username := ""
	var revoke := false
	var data_dir := "user://flickbattle/"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--user="):
			username = arg.substr("--user=".length()).strip_edges().to_lower()
		elif arg == "--revoke":
			revoke = true
		elif arg.begins_with("--data="):
			data_dir = arg.substr("--data=".length()).strip_edges()

	if username == "":
		push_error("pass --user=NAME")
		quit(1)
		return

	var store := ServerStore.new()
	store.open(data_dir)

	var target := {}
	for account in store._accounts:
		if str(account.get("username_lower", "")) == username:
			target = account
			break

	if target.is_empty():
		push_error("no account '%s' in %s" % [username, ProjectSettings.globalize_path(data_dir + "accounts.json")])
		quit(1)
		return

	target["is_admin"] = not revoke
	store._save_accounts()
	print("%s admin rights for '%s'." % ["Revoked" if revoke else "Granted", target.get("username")])
	quit(0)
