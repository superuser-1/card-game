extends Control

var _mode := "login"  # "login" | "register"
var _busy := false
var _resuming := false


func _ready() -> void:
	Net.auth_completed.connect(_on_auth_completed)
	Net.error_received.connect(_on_net_error)

	%SubmitButton.pressed.connect(_on_submit)
	%ToggleModeButton.pressed.connect(_toggle_mode)
	%PasswordField.text_submitted.connect(_on_submit)

	var saved: String = Session.load_token()
	if saved != "":
		_resuming = true
		%StatusLabel.text = "Resuming session..."
		_busy = true
		_disable_inputs()
		var connected: bool = await _ensure_connected()
		if connected:
			Net.auth_resume(saved)
		else:
			# Server unreachable — don't leave the form frozen on the spinner.
			_busy = false
			_resuming = false
			_enable_inputs()
			%StatusLabel.text = "Could not reach server. Log in to retry."
	else:
		await _ensure_connected()


## Returns true once connected, false if the connection attempt failed.
func _ensure_connected() -> bool:
	var mp := multiplayer.multiplayer_peer
	if mp == null:
		return false
	if mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return true
	while mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		await get_tree().process_frame
	return mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _toggle_mode() -> void:
	if _mode == "login":
		_mode = "register"
		%ModeLabel.text = "Register"
		%SubmitButton.text = "Register"
		%ToggleModeButton.text = "Already have an account? Log in"
	else:
		_mode = "login"
		%ModeLabel.text = "Log in"
		%SubmitButton.text = "Log in"
		%ToggleModeButton.text = "Need an account? Register"
	%ErrorLabel.text = ""


func _on_submit() -> void:
	if _busy:
		return

	var username: String = %UsernameField.text.strip_edges()
	var password: String = %PasswordField.text

	if username == "" or password == "":
		%ErrorLabel.text = "Enter a username and password."
		return

	_busy = true
	_disable_inputs()
	%ErrorLabel.text = ""
	%StatusLabel.text = "..."

	var connected: bool = await _ensure_connected()
	if not connected:
		_busy = false
		_enable_inputs()
		%StatusLabel.text = ""
		%ErrorLabel.text = "Could not reach server."
		return

	if _mode == "register":
		Net.auth_register(username, password)
	else:
		Net.auth_login(username, password)


func _on_auth_completed(result: Dictionary) -> void:
	var was_resuming := _resuming
	_busy = false
	_resuming = false
	%StatusLabel.text = ""

	var ok: bool = bool(result.get("ok", false))
	if ok:
		Session.set_account(result.get("account", {}))
		Session.save_token(result.get("token", ""))
		Session.goto("res://client/main_menu.tscn")
		return

	# Back to a usable form.
	_enable_inputs()
	var error: String = result.get("error", "")
	if error == "session_expired" or was_resuming:
		Session.clear()
		%StatusLabel.text = "Please log in."
	else:
		%ErrorLabel.text = _friendly(error)


func _friendly(err: String) -> String:
	var error_map: Dictionary = {
		"bad_username": "Username must be 1–20 letters, digits or underscore.",
		"bad_password": "Enter a password.",
		"username_taken": "That username is taken.",
		"no_such_user": "No account with that username.",
		"bad_credentials": "Wrong username or password.",
	}
	if error_map.has(err):
		return error_map.get(err, "")
	return "Could not sign in (%s)." % err


func _on_net_error(msg: String) -> void:
	if _busy or _resuming:
		_busy = false
		_resuming = false
		_enable_inputs()
		%StatusLabel.text = ""
	%ErrorLabel.text = msg


func _disable_inputs() -> void:
	%UsernameField.editable = false
	%PasswordField.editable = false
	%SubmitButton.disabled = true
	%ToggleModeButton.disabled = true


func _enable_inputs() -> void:
	%UsernameField.editable = true
	%PasswordField.editable = true
	%SubmitButton.disabled = false
	%ToggleModeButton.disabled = false
