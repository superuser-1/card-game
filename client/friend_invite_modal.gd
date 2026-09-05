extends Control
## Create side of the friend-invite custom game flow. Form -> Create ->
## WaitingBox (still this same modal) until Net.match_found fires for this
## peer, at which point we hand off to the game screen exactly like the
## matchmaking queue screen does. Closing/leaving before that cancels the
## open lobby server-side so it doesn't linger forever.

var _created := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	Net.custom_game_created.connect(_on_custom_game_created)
	Net.match_found.connect(_on_match_found)

	%CreateButton.pressed.connect(_on_create_pressed)
	%CancelButton.pressed.connect(_close)
	%LeaveButton.pressed.connect(_on_leave_pressed)


func _on_create_pressed() -> void:
	var name_text := (%NameLineEdit.text as String).strip_edges()
	if name_text.is_empty():
		%ErrorLabel.text = "Enter a game name."
		return

	var match_format: int = [1, 3, 5][int(%MatchFormatOptionButton.selected)]

	%CreateButton.disabled = true
	%ErrorLabel.text = ""
	Net.create_custom_game(name_text, match_format)


func _on_custom_game_created(result: Dictionary) -> void:
	%CreateButton.disabled = false
	if not bool(result.get("ok", false)):
		%ErrorLabel.text = _friendly(str(result.get("error", "unknown")))
		return

	_created = true
	%FormBox.visible = false
	%WaitingBox.visible = true
	%WaitingNameLabel.text = "Game: %s" % str(result.get("name", ""))


func _on_match_found(info: Dictionary) -> void:
	if not _created:
		return  # not our lobby (e.g. a ranked/tournament match_found firing for another flow)
	Session.last_match_info = info
	Session.goto("res://client/game_ui.tscn")


func _on_leave_pressed() -> void:
	if _created:
		Net.cancel_custom_game()
	_close()


func _friendly(err: String) -> String:
	var error_map: Dictionary = {
		"bad_name": "Game name must be 1–40 characters.",
		"name_taken": "That game name is already in use — pick another.",
		"already_hosting": "You're already hosting an open game.",
		"already_in_match": "Finish your current match first.",
		"tournament_lock": "Checked in to a tournament — finish it first.",
	}
	return error_map.get(err, "Could not create the game (%s)." % err)


func _close() -> void:
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
