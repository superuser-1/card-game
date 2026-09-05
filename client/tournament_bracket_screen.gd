extends Control

var _tournament_id := 0
var _tournament: Dictionary = {}


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))

	_tournament_id = Session.active_tournament_id
	if _tournament_id == 0:
		_tournament_id = int(get_tree().get_meta("browse_tournament_id", 0))

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

	var rounds = _tournament.get("rounds", [])
	var participants = _tournament.get("participants", [])

	if rounds.is_empty():
		_render_participants_list(participants)
		%ScrollContainer.visible = false
		%ParticipantsList.visible = true
		return

	%ParticipantsList.visible = false
	%ScrollContainer.visible = true

	var rounds_hbox = %RoundsHBox
	for child in rounds_hbox.get_children():
		child.queue_free()

	var bracket_size := int(_tournament.get("bracket_size", 0))
	var current_round := int(_tournament.get("current_round", 0))
	var my_id := int(Session.account.get("id", 0))
	var is_my_tournament := Session.active_tournament_id == _tournament_id

	for round_idx in range(len(rounds)):
		var round_slots = rounds[round_idx]
		var round_vbox := VBoxContainer.new()
		round_vbox.add_theme_constant_override("separation", 8)

		var round_label := Label.new()
		round_label.text = "Round %d" % (round_idx + 1)
		round_label.add_theme_font_size_override("font_size", 12)
		round_label.modulate = Color(1, 1, 1, 0.6)
		round_vbox.add_child(round_label)

		for slot in round_slots:
			var slot_panel := _make_slot_display(slot, participants)
			round_vbox.add_child(slot_panel)

		rounds_hbox.add_child(round_vbox)

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


func _make_slot_display(slot: Dictionary, participants: Array) -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 0.9)
	sb.border_color = Color(1, 1, 1, 0.1)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)

	var account_id_a := int(slot.get("account_id_a", 0))
	var account_id_b := int(slot.get("account_id_b", 0))
	var is_bot_a := bool(slot.get("is_bot_a", false))
	var is_bot_b := bool(slot.get("is_bot_b", false))
	var resolved := bool(slot.get("resolved", false))
	var winner_account_id := int(slot.get("winner_account_id", 0))
	var winner_is_bot := bool(slot.get("winner_is_bot", false))
	var score_a := int(slot.get("score_a", 0))
	var score_b := int(slot.get("score_b", 0))

	var name_a := _get_display_name(account_id_a, is_bot_a, participants)
	var name_b := _get_display_name(account_id_b, is_bot_b, participants)

	var label_a := Label.new()
	label_a.text = "%s — %d" % [name_a, score_a]
	label_a.add_theme_font_size_override("font_size", 13)
	if resolved and ((winner_account_id == account_id_a and not winner_is_bot) or (winner_is_bot and is_bot_a)):
		label_a.add_theme_color_override("font_color", Color(0.4, 0.9, 0.45))
		label_a.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.5))
		label_a.add_theme_constant_override("outline_size", 2)
	vbox.add_child(label_a)

	var label_b := Label.new()
	label_b.text = "%s — %d" % [name_b, score_b]
	label_b.add_theme_font_size_override("font_size", 13)
	if resolved and ((winner_account_id == account_id_b and not winner_is_bot) or (winner_is_bot and is_bot_b)):
		label_b.add_theme_color_override("font_color", Color(0.4, 0.9, 0.45))
		label_b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.5))
		label_b.add_theme_constant_override("outline_size", 2)
	vbox.add_child(label_b)

	panel.add_child(vbox)
	return panel


func _get_display_name(account_id: int, is_bot: bool, participants: Array) -> String:
	if is_bot or account_id == 0:
		return "Bot"

	for p in participants:
		if int(p.get("account_id", -1)) == account_id:
			return str(p.get("display_name", "Unknown"))

	return "Unknown"


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
