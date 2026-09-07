extends Control
## Full-screen fallback result screen. The normal path shows the summary as an
## overlay on the finished board (game_ui._show_result_overlay); this scene is
## kept for cases where there's no board to overlay (e.g. landing here after a
## reconnect into an already-finished match).

# Captured on entry: the match we're showing results for was a local bot game,
# not a ranked networked one. "Play again" then restarts singleplayer directly
# instead of dropping into the matchmaking queue, and leaving hands the Net
# state back to a plain client (see Net.end_singleplayer).
var _was_solo := false


func _ready() -> void:
	_was_solo = Net.is_solo

	var s: Dictionary = Session.last_match_summary
	Session.last_match_summary = {}

	var panel: MatchSummaryPanel = %SummaryPanel
	panel.set_again_label("Play Again" if _was_solo else "Find Another")
	panel.render(s)
	panel.again_pressed.connect(_on_again)
	panel.menu_pressed.connect(_on_menu)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_menu()
		get_viewport().set_input_as_handled()


func _on_again() -> void:
	if _was_solo:
		Net.start_singleplayer()
		Session.goto("res://client/game_ui.tscn")
	else:
		Session.goto("res://client/queue_screen.tscn")


func _on_menu() -> void:
	if _was_solo:
		Net.end_singleplayer()
	Session.goto("res://client/main_menu.tscn")
