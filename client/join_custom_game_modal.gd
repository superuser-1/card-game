extends Control
## Join side of the friend-invite custom game flow. Enter the host's game
## name -> Join -> the server immediately starts the match and sends
## match_found to both sides, so success here just means "wait a beat", and
## the actual hand-off happens the same way the create side does.

var _joining := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	Net.custom_game_join_result.connect(_on_join_result)
	Net.match_found.connect(_on_match_found)
	%NameLineEdit.text_submitted.connect(func(_t): _on_join_pressed())

	%JoinButton.pressed.connect(_on_join_pressed)
	%CancelButton.pressed.connect(_close)


func _on_join_pressed() -> void:
	var name_text := (%NameLineEdit.text as String).strip_edges()
	if name_text.is_empty():
		%ErrorLabel.text = "Enter a game name."
		return

	%JoinButton.disabled = true
	%ErrorLabel.text = ""
	_joining = true
	Net.join_custom_game(name_text)


func _on_join_result(result: Dictionary) -> void:
	%JoinButton.disabled = false
	if not bool(result.get("ok", false)):
		_joining = false
		%ErrorLabel.text = _friendly(str(result.get("error", "unknown")))


func _on_match_found(info: Dictionary) -> void:
	if not _joining:
		return  # not from our join attempt
	Session.last_match_info = info
	Session.goto("res://client/game_ui.tscn")


func _friendly(err: String) -> String:
	var error_map: Dictionary = {
		"not_found": "No open game with that name — check the spelling, or it may already be full.",
		"cant_join_own_game": "You can't join your own game.",
		"already_in_match": "Finish your current match first.",
		"tournament_lock": "Checked in to a tournament — finish it first.",
	}
	return error_map.get(err, "Could not join the game (%s)." % err)


func _close() -> void:
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
