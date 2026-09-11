extends Control
## Standalone admin tool window — a SEPARATE lightweight UI from the game
## client, launched via `godot -- --admin-tool [--address=IP]` (see main.gd),
## reusing the same Net/Session autoloads and ENet connection the game client
## uses (same one-connection-per-account server, same auth RPCs) rather than
## a whole second Godot project. No game art, no menu chrome.
##
## Every admin action here is a thin call into a Net RPC wrapper, which is
## itself a thin dispatcher into a plain ServerStore method server-side (see
## server/server_store.gd's "admin tools" section and net_node.gd's "Admin
## tools" section). If this ever needs to become a website instead of a PC
## tool, the server-side logic doesn't change — only the transport (HTTP
## instead of ENet RPCs) and this front-end would be replaced.

var _selected_account_id := 0


func _ready() -> void:
	DisplayServer.window_set_title("Flick Battle — Admin Tool")
	DisplayServer.window_set_size(Vector2i(720, 640))

	Net.auth_completed.connect(_on_auth_completed)
	Net.error_received.connect(_on_net_error)
	Net.admin_search_result.connect(_on_admin_search_result)
	Net.admin_account_detail.connect(_on_admin_account_detail)
	Net.admin_action_result.connect(_on_admin_action_result)
	Net.admin_online_list.connect(_on_admin_online_list)
	Net.admin_log_received.connect(_on_admin_log_result)
	Net.kicked.connect(_on_kicked)
	Net.force_logout.connect(_on_force_logout)

	%LoginButton.pressed.connect(_on_login_pressed)
	%PasswordField.text_submitted.connect(func(_t): _on_login_pressed())
	%LogoutButton.pressed.connect(_on_logout_pressed)
	%SearchButton.pressed.connect(_on_search_pressed)
	%SearchField.text_submitted.connect(func(_t): _on_search_pressed())
	%ResultsList.item_selected.connect(_on_result_selected)
	%BanButton.pressed.connect(_on_ban_pressed)
	%UnbanButton.pressed.connect(_on_unban_pressed)
	%SetEloButton.pressed.connect(_on_set_elo_pressed)
	%AdjustPointsButton.pressed.connect(_on_adjust_points_pressed)
	%RefreshOnlineButton.pressed.connect(func(): Net.admin_list_online())
	%RefreshLogButton.pressed.connect(func(): Net.admin_recent_actions(100))

	%ConnLabel.text = "Connecting..."
	var connected: bool = await _ensure_connected()
	if not connected:
		%ConnLabel.text = "Could not reach server."
		return
	%ConnLabel.text = ""

	var saved := Session.load_token()
	if saved != "":
		%ConnLabel.text = "Resuming session..."
		Net.auth_resume(saved)


func _ensure_connected() -> bool:
	var mp := multiplayer.multiplayer_peer
	if mp == null:
		return false
	if mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return true
	while mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		await get_tree().process_frame
	return mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


# --- auth ----------------------------------------------------------------

func _on_login_pressed() -> void:
	var username: String = %UsernameField.text.strip_edges()
	var password: String = %PasswordField.text
	if username == "" or password == "":
		%LoginErrorLabel.text = "Enter a username and password."
		return
	%LoginErrorLabel.text = ""
	%ConnLabel.text = "Signing in..."
	Net.auth_login(username, password)


func _on_auth_completed(result: Dictionary) -> void:
	%ConnLabel.text = ""
	if not bool(result.get("ok", false)):
		Session.clear()
		var error: String = result.get("error", "")
		if error == "banned":
			%LoginErrorLabel.text = "This account is suspended."
		elif error == "session_expired":
			%LoginErrorLabel.text = "Session expired — please log in again."
		else:
			%LoginErrorLabel.text = "Sign-in failed (%s)." % error
		return

	Session.set_account(result.get("account", {}))
	Session.save_token(result.get("token", ""))
	# account_snapshot() never exposes is_admin (a player's own client has no
	# use for it) — the real gate is server-side on every admin RPC, so probe
	# with a harmless read: admin_online_list on success, or an explicit
	# not_admin admin_action_result if this account isn't an admin.
	Net.admin_list_online()


func _on_logout_pressed() -> void:
	Session.clear()
	%MainPanel.visible = false
	%LoginPanel.visible = true
	%UsernameField.text = ""
	%PasswordField.text = ""
	%LoginErrorLabel.text = ""


func _on_kicked() -> void:
	Session.clear()
	%MainPanel.visible = false
	%LoginPanel.visible = true
	%LoginErrorLabel.text = "Disconnected from server."


func _on_force_logout(reason: String) -> void:
	%LoginErrorLabel.text = reason


func _on_net_error(msg: String) -> void:
	%ConnLabel.text = ""
	%LoginErrorLabel.text = msg


# --- accounts --------------------------------------------------------------

func _on_search_pressed() -> void:
	Net.admin_search_accounts(%SearchField.text.strip_edges())


func _on_admin_search_result(rows: Array) -> void:
	# First reply to land after login also means this account IS an admin —
	# reveal the tool now if we're still sitting on the login panel.
	_show_main_panel()
	%ResultsList.clear()
	%ResultsList.set_meta("rows", rows)
	for row in rows:
		var banned_tag := " [BANNED]" if bool(row.get("banned", false)) else ""
		%ResultsList.add_item("%s (#%d) elo=%d%s" % [
			str(row.get("username", "?")), int(row.get("id", 0)), int(row.get("elo", 0)), banned_tag
		])


func _on_result_selected(index: int) -> void:
	var rows: Array = %ResultsList.get_meta("rows", [])
	if index < 0 or index >= rows.size():
		return
	_selected_account_id = int(rows[index].get("id", 0))
	Net.admin_get_account(_selected_account_id)


func _on_admin_account_detail(account: Dictionary) -> void:
	if account.is_empty():
		%DetailLabel.text = "Account not found."
		return
	var lines := [
		"#%d  %s" % [int(account.get("id", 0)), str(account.get("username", ""))],
		"Elo: %d (peak %d)" % [int(account.get("elo", 0)), int(account.get("peak_elo", 0))],
		"Record: %d-%d-%d over %d games" % [
			int(account.get("wins", 0)), int(account.get("losses", 0)),
			int(account.get("draws", 0)), int(account.get("games", 0))
		],
		"Points: %d" % int(account.get("points", 0)),
		"Admin: %s" % ("yes" if bool(account.get("is_admin", false)) else "no"),
	]
	if bool(account.get("banned", false)):
		lines.append("BANNED — reason: %s" % str(account.get("ban_reason", "")))
		lines.append("Banned by %s" % str(account.get("banned_by", "")))
	%DetailLabel.text = "\n".join(lines)


func _on_ban_pressed() -> void:
	if _selected_account_id == 0:
		return
	Net.admin_ban(_selected_account_id, %ReasonField.text.strip_edges())


func _on_unban_pressed() -> void:
	if _selected_account_id == 0:
		return
	Net.admin_unban(_selected_account_id)


func _on_set_elo_pressed() -> void:
	if _selected_account_id == 0:
		return
	var text: String = %NewEloField.text.strip_edges()
	if not text.is_valid_int():
		%StatusLabel.text = "Enter a whole-number elo value."
		return
	Net.admin_set_elo(_selected_account_id, int(text))


func _on_adjust_points_pressed() -> void:
	if _selected_account_id == 0:
		return
	var text: String = %PointsDeltaField.text.strip_edges()
	if not text.is_valid_int():
		%StatusLabel.text = "Enter a whole-number points delta (e.g. -50)."
		return
	Net.admin_adjust_points(_selected_account_id, int(text))


func _on_admin_action_result(result: Dictionary) -> void:
	var action: String = result.get("action", "")
	if not bool(result.get("ok", false)):
		var error: String = result.get("error", "")
		if error == "not_admin":
			# The probe call after login (or any later call) came back denied —
			# this account has no admin rights. Kick back to the login form.
			Session.clear()
			%MainPanel.visible = false
			%LoginPanel.visible = true
			%LoginErrorLabel.text = "This account does not have admin rights."
			return
		%StatusLabel.text = "%s failed: %s" % [action, error]
		return

	%StatusLabel.text = "%s: OK" % action
	var account: Dictionary = result.get("account", {})
	if not account.is_empty():
		_on_admin_account_detail(account)
		if int(account.get("id", 0)) == _selected_account_id:
			%ReasonField.text = ""
			%NewEloField.text = ""
			%PointsDeltaField.text = ""


# --- online / log ------------------------------------------------------------

func _on_admin_online_list(rows: Array) -> void:
	_show_main_panel()
	%OnlineList.clear()
	for row in rows:
		%OnlineList.add_item("%s (#%d) elo=%d" % [
			str(row.get("username", "?")), int(row.get("id", 0)), int(row.get("elo", 0))
		])


func _on_admin_log_result(rows: Array) -> void:
	%LogList.clear()
	for row in rows:
		var ts := int(row.get("ts", 0))
		var when := Time.get_datetime_string_from_unix_time(ts, true)
		%LogList.add_item("%s  %s  %s -> account #%d  %s" % [
			when, str(row.get("admin", "")), str(row.get("action", "")),
			int(row.get("account_id", 0)), str(row.get("details", ""))
		])


func _show_main_panel() -> void:
	if %MainPanel.visible:
		return
	%LoginPanel.visible = false
	%MainPanel.visible = true
	%WelcomeLabel.text = "Signed in as %s" % str(Session.account.get("username", ""))
	Net.admin_recent_actions(100)
