extends Control

var _elapsed := 0.0
var _searching := true


func _ready() -> void:
	Net.queue_updated.connect(_on_queue_updated)
	Net.match_found.connect(_on_match_found)
	Net.error_received.connect(_on_error)
	%CancelButton.pressed.connect(_on_cancel)
	Net.enqueue_match()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_cancel()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _searching:
		_elapsed += delta
		%ElapsedLabel.text = "%ds" % int(_elapsed)


func _on_queue_updated(state: String, elapsed_s: float) -> void:
	if state == "searching" and elapsed_s > _elapsed:
		_elapsed = elapsed_s
	elif state == "cancelled":
		_searching = false
		Session.goto("res://client/main_menu.tscn")


func _on_match_found(info: Dictionary) -> void:
	_searching = false
	# The game scene loads after this signal fires, so hand the payload over
	# through Session for game_ui to pick up on _ready.
	Session.last_match_info = info
	Session.goto("res://client/game_ui.tscn")


func _on_cancel() -> void:
	if not _searching:
		Session.goto("res://client/main_menu.tscn")
		return

	%CancelButton.disabled = true
	%HeadLabel.text = "Cancelling…"
	Net.cancel_queue()


func _on_error(msg: String) -> void:
	_searching = false
	%HeadLabel.text = msg
	%CancelButton.text = "Back"
