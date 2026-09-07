extends Control

const BracketCanvasScript := preload("res://client/bracket_canvas.gd")

var _tournament_id := 0
var _tournament: Dictionary = {}
var _bracket_canvas: Control = null


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto("res://client/main_menu.tscn")
		get_viewport().set_input_as_handled()


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))

	# An explicit "View Bracket" click always wins over whichever tournament we
	# happen to be actively checked into — otherwise, with a live check-in,
	# every click here would show that same active tournament regardless of
	# which one was actually clicked. The meta is a one-shot handoff (cleared
	# immediately after reading) so it can never leak into a LATER automatic
	# load of this screen (e.g. the between-rounds redirect for our own live
	# run), which must fall back to Session.active_tournament_id instead.
	var browse_tid := 0
	if get_tree().has_meta("browse_tournament_id"):
		browse_tid = int(get_tree().get_meta("browse_tournament_id"))
		get_tree().remove_meta("browse_tournament_id")
	_tournament_id = browse_tid if browse_tid != 0 else Session.active_tournament_id

	if _tournament_id == 0:
		%ErrorLabel.visible = true
		%ErrorLabel.text = "No tournament selected"
		%ScrollContainer.visible = false
		%ParticipantsList.visible = false
		return

	Net.tournament_updated.connect(_on_tournament_updated)
	Net.match_found.connect(_on_match_found)
	Net.request_tournament(_tournament_id)


func _on_tournament_updated(tournament: Dictionary) -> void:
	if int(tournament.get("id", 0)) != _tournament_id:
		return

	_tournament = tournament
	_render_bracket()


func _on_match_found(info: Dictionary) -> void:
	var ctx = info.get("tournament_ctx", {})
	if ctx.is_empty() or int(ctx.get("tournament_id", 0)) != _tournament_id:
		return

	Session.last_match_info = info
	Session.goto("res://client/game_ui.tscn")


func _render_bracket() -> void:
	var status := str(_tournament.get("status", ""))
	var name := str(_tournament.get("name", ""))

	%ErrorLabel.visible = false

	var header_text := "%s (%s)" % [name, status]
	if status == "completed":
		var winner_name := _get_winner_name()
		header_text += " — Winner: %s" % winner_name

	%HeaderLabel.text = header_text

	var prizes: Dictionary = _tournament.get("prizes", {})
	%PrizeLabel.visible = not prizes.is_empty()
	if not prizes.is_empty():
		%PrizeLabel.text = TournamentPrizes.summary_line(prizes,
			func(id): return str(ShopCatalog.def_for(id).get("name", id)))

	var rounds = _tournament.get("rounds", [])
	var participants = _tournament.get("participants", [])

	if rounds.is_empty():
		_render_participants_list(participants)
		%ScrollContainer.visible = false
		%ParticipantsList.visible = true
		return

	%ParticipantsList.visible = false
	%ScrollContainer.visible = true

	var current_round := int(_tournament.get("current_round", 0))
	var my_id := int(Session.account.get("id", 0))
	var is_my_tournament := Session.active_tournament_id == _tournament_id

	if _bracket_canvas == null:
		_bracket_canvas = Control.new()
		_bracket_canvas.set_script(BracketCanvasScript)
		%RoundsHBox.add_child(_bracket_canvas)
	_bracket_canvas.set_data(rounds, participants, my_id)

	%WaitingLabel.visible = false
	if is_my_tournament and status == "in_progress":
		var has_current_match := false
		# current_round is 1-based (round 1 == rounds[0]).
		var current_round_slots = rounds[current_round - 1] if current_round - 1 >= 0 and current_round - 1 < len(rounds) else []
		for slot in current_round_slots:
			if int(slot.get("match_id", 0)) > 0 and _slot_has_player(slot, my_id):
				has_current_match = true
				break

		if not has_current_match:
			%WaitingLabel.visible = true


func _render_participants_list(participants: Array) -> void:
	%ParticipantsList.visible = true

	for child in %ParticipantsList.get_children():
		child.queue_free()

	var title := Label.new()
	title.text = "Participants (%d)" % len(participants)
	title.add_theme_font_size_override("font_size", 14)
	%ParticipantsList.add_child(title)

	for p in participants:
		var p_hbox := HBoxContainer.new()

		var name_label := Label.new()
		name_label.text = str(p.get("display_name", "Unknown"))
		name_label.custom_minimum_size = Vector2(200, 0)
		p_hbox.add_child(name_label)

		var checked_in := bool(p.get("checked_in", false))
		var status_label := Label.new()
		status_label.text = "✓ Checked in" if checked_in else "Awaiting check-in"
		status_label.modulate = Color(0.4, 0.9, 0.45) if checked_in else Color(1, 1, 1, 0.6)
		p_hbox.add_child(status_label)

		%ParticipantsList.add_child(p_hbox)


func _get_winner_name() -> String:
	var winner_id := int(_tournament.get("winner_account_id", 0))
	if winner_id == 0:
		return "a bot"

	var participants = _tournament.get("participants", [])
	for p in participants:
		if int(p.get("account_id", -1)) == winner_id:
			return str(p.get("display_name", "Unknown"))

	return "Unknown"


func _slot_has_player(slot: Dictionary, account_id: int) -> bool:
	var a_id := int(slot.get("account_id_a", 0))
	var b_id := int(slot.get("account_id_b", 0))
	return a_id == account_id or b_id == account_id
