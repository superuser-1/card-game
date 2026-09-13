extends Control

const BracketCanvasScript := preload("res://client/bracket_canvas.gd")

const COL_MUTED := Color(1, 1, 1, 0.6)
const COL_GOOD := Color(0.35, 0.85, 0.45)
const COL_WARN := Color(0.95, 0.85, 0.35)
const COL_GOLD := Color(1, 0.86, 0.5)

var _tournament_id := 0
var _tournament: Dictionary = {}
var _bracket_canvas: Control = null

## Live "starts in Xh Ym" style countdown for the meta row's phase line —
## ticked from _process alongside the round clock/intermission countdowns.
var _phase_label: Label = null
var _phase_prefix := ""
var _phase_target_ts := 0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto("res://client/main_menu.tscn")
		get_viewport().set_input_as_handled()


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.129, 0.129, 0.176)
	sb.border_color = Color(1, 1, 1, 0.075)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	%MetaPanel.add_theme_stylebox_override("panel", sb)

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
	Net.tournament_withdrawn.connect(_on_tournament_withdrawn)
	Net.request_tournament(_tournament_id)


func _on_tournament_updated(tournament: Dictionary) -> void:
	if int(tournament.get("id", 0)) != _tournament_id:
		return

	_tournament = tournament
	_render_bracket()


## Live per-second countdowns: the between-round intermission ("next round in
## 1:47") and, during a round, the round's hard-cap deadline ("round time
## limit: 41:07"). Both are driven off unix timestamps in the tournament
## snapshot, so they keep ticking smoothly between broadcasts.
func _process(_delta: float) -> void:
	if _tournament.is_empty():
		return
	var now := int(Time.get_unix_time_from_system())
	var in_progress := str(_tournament.get("status", "")) == "in_progress"
	var inter_left := int(_tournament.get("intermission_until_ts", 0)) - now
	var round_left := int(_tournament.get("round_deadline_ts", 0)) - now

	if in_progress and inter_left > 0:
		%IntermissionLabel.text = "Next round starts in %s — time for a break" % _fmt_clock(inter_left)
		%IntermissionLabel.visible = true
		%RoundClockLabel.visible = false
	elif in_progress and int(_tournament.get("round_deadline_ts", 0)) > 0:
		%IntermissionLabel.visible = false
		%RoundClockLabel.text = ("Round time limit: %s" % _fmt_clock(round_left)) if round_left > 0 \
			else "Round time limit reached — resolving…"
		%RoundClockLabel.visible = true
	else:
		%IntermissionLabel.visible = false
		%RoundClockLabel.visible = false

	if is_instance_valid(_phase_label):
		_phase_label.text = "%s%s" % [_phase_prefix, _fmt_clock_or_soon(_phase_target_ts - now)]


func _fmt_clock(secs: int) -> String:
	secs = max(secs, 0)
	return "%d:%02d" % [secs / 60, secs % 60]


## Same "Xh Ym" / "Xm Ys" style as the tournament list screen's countdowns.
func _fmt_clock_or_soon(secs: int) -> String:
	if secs <= 0:
		return "any moment"
	var h := secs / 3600
	var m := (secs % 3600) / 60
	var s := secs % 60
	if h > 0:
		return "%dh %dm" % [h, m]
	if m > 0:
		return "%dm %ds" % [m, s]
	return "%ds" % s


func _on_match_found(info: Dictionary) -> void:
	var ctx = info.get("tournament_ctx", {})
	if ctx.is_empty() or int(ctx.get("tournament_id", 0)) != _tournament_id:
		return

	Session.last_match_info = info
	Session.goto("res://client/game_ui.tscn")


## Withdrawing removes us from the participant list, so the server's own
## broadcast of the updated tournament (_broadcast_tournament) never reaches
## us — this screen relies on the direct RPC reply instead, which still
## carries a fresh snapshot in `result.tournament`.
func _on_tournament_withdrawn(result: Dictionary) -> void:
	var t: Dictionary = result.get("tournament", {})
	if t.is_empty() or int(t.get("id", 0)) != _tournament_id:
		return
	if bool(result.get("ok", false)):
		_tournament = t
		_render_bracket()


func _on_cancel_pressed(btn: Button) -> void:
	btn.disabled = true
	Net.withdraw_tournament(_tournament_id)


func _render_bracket() -> void:
	var status := str(_tournament.get("status", ""))
	var name := str(_tournament.get("name", ""))

	%ErrorLabel.visible = false

	var header_text := "%s (%s)" % [name, status]
	if status == "completed":
		var winner_name := _get_winner_name()
		header_text += " — Winner: %s" % winner_name

	%HeaderLabel.text = header_text

	_render_meta_row()

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

		# During the between-round pause the IntermissionLabel says it better.
		var in_intermission := int(_tournament.get("intermission_until_ts", 0)) > int(Time.get_unix_time_from_system())
		if not has_current_match and not in_intermission:
			%WaitingLabel.visible = true


## {prefix, target} for the countdown to this tournament's next phase, or {}
## if there's nothing to count down to (in progress / completed / cancelled)
## — same phase→field mapping as the tournament list screen's _next_phase.
func _next_phase_info() -> Dictionary:
	match str(_tournament.get("status", "")):
		"signup_private":
			if str(_tournament.get("availability", "")) == "semi_private":
				return {"prefix": "Opens to all in ", "target": int(_tournament.get("private_signup_close_ts", 0))}
			return {"prefix": "Check-in in ", "target": int(_tournament.get("check_in_open_ts", 0))}
		"signup":
			return {"prefix": "Sign-up closes in ", "target": int(_tournament.get("signup_close_ts", 0))}
		"pre_check_in":
			return {"prefix": "Check-in opens in ", "target": int(_tournament.get("check_in_open_ts", 0))}
		"check_in":
			return {"prefix": "Starts in ", "target": int(_tournament.get("start_ts", 0))}
	return {}


## Creator portrait + name, signed-up/min-players count, format, cube vs
## original catalogue, and a live countdown to whatever phase comes next —
## the same information the tournament list card shows, so opening a
## tournament from either place lands on a consistent picture of it.
func _render_meta_row() -> void:
	for c in %MetaRow.get_children():
		c.queue_free()
	_phase_label = null

	var portrait := AvatarStack.make(
		str(_tournament.get("creator_avatar", "")), str(_tournament.get("creator_frame", "")),
		str(_tournament.get("creator_background", "")), 48.0)
	portrait.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	%MetaRow.add_child(portrait)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)

	info.add_child(_meta_label("by %s" % str(_tournament.get("creator_name", "—")), COL_MUTED))

	var bracket_size := int(_tournament.get("bracket_size", 0))
	var participant_count := (_tournament.get("participants", []) as Array).size()
	var match_format := int(_tournament.get("match_format", 1))
	var min_players := TournamentSystem.MIN_TOURNAMENT_PLAYERS
	var enough := participant_count >= min_players
	var count_row := HBoxContainer.new()
	count_row.add_theme_constant_override("separation", 0)
	count_row.add_child(_meta_label("%d (%d)" % [participant_count, min_players], COL_GOOD if enough else COL_WARN))
	count_row.add_child(_meta_label(" / %d signed up  ·  Best of %d" % [bracket_size, match_format], COL_MUTED))
	info.add_child(count_row)

	var has_cube := (_tournament.get("cube_ids", []) as Array).size() > 0
	info.add_child(_meta_label("Custom cube" if has_cube else "Original catalogue",
		Color(0.55, 0.8, 1.0) if has_cube else COL_MUTED))

	var phase := _next_phase_info()
	if not phase.is_empty() and int(phase.target) > 0:
		_phase_prefix = str(phase.prefix)
		_phase_target_ts = int(phase.target)
		_phase_label = _meta_label("", COL_GOLD, 13)
		info.add_child(_phase_label)
		_phase_label.text = "%s%s" % [_phase_prefix, _fmt_clock_or_soon(_phase_target_ts - int(Time.get_unix_time_from_system()))]

	info.add_child(_meta_label("Starts %s" % Time.get_datetime_string_from_unix_time(int(_tournament.get("start_ts", 0)), true).replace("T", " "), Color(1, 1, 1, 0.45), 11))

	# Withdraw only ever shows up (and only ever works) pre-check-in, and only
	# for a tournament we're actually signed up for — moved here from the main
	# menu card, which now only ever shows a status summary.
	var status := str(_tournament.get("status", ""))
	if status in ["signup", "signup_private"] and (Session.my_tournaments as Dictionary).has(_tournament_id):
		var cancel_btn := Button.new()
		cancel_btn.text = "Cancel"
		cancel_btn.add_theme_font_size_override("font_size", 12)
		cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		cancel_btn.pressed.connect(_on_cancel_pressed.bind(cancel_btn))
		info.add_child(cancel_btn)

	%MetaRow.add_child(info)

	var prizes: Dictionary = _tournament.get("prizes", {})
	if not prizes.is_empty():
		%MetaRow.add_child(PrizeView.column(prizes, 22.0))


func _meta_label(text: String, col: Color, sz := 13) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	return l


func _render_participants_list(participants: Array) -> void:
	%ParticipantsList.visible = true

	for child in %ParticipantsList.get_children():
		child.queue_free()

	var title := Label.new()
	title.text = "Participants (%d)" % len(participants)
	title.add_theme_font_size_override("font_size", 14)
	%ParticipantsList.add_child(title)

	# 3 across, filling row by row — a participant entry doesn't need a full
	# screen-width line to itself.
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	%ParticipantsList.add_child(grid)

	for p in participants:
		var row := PanelContainer.new()
		row.custom_minimum_size = Vector2(340, 0)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var row_sb := StyleBoxFlat.new()
		row_sb.bg_color = Color(1, 1, 1, 0.04)
		row_sb.set_corner_radius_all(8)
		row_sb.set_content_margin_all(8)
		row.add_theme_stylebox_override("panel", row_sb)

		var p_hbox := HBoxContainer.new()
		p_hbox.add_theme_constant_override("separation", 10)
		row.add_child(p_hbox)

		var portrait := AvatarStack.make(
			str(p.get("avatar", "")), str(p.get("frame", "")), str(p.get("background", "")), 40.0)
		p_hbox.add_child(portrait)

		var elo := int(p.get("elo", 0))
		var text_col := VBoxContainer.new()
		text_col.add_theme_constant_override("separation", 0)
		text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var title_label := Label.new()
		title_label.text = TitleSystem.display_name(str(p.get("title", "")), elo)
		title_label.clip_text = true
		title_label.add_theme_font_size_override("font_size", 11)
		title_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4, 1))
		text_col.add_child(title_label)

		var name_label := Label.new()
		name_label.text = str(p.get("display_name", "Unknown"))
		name_label.clip_text = true
		text_col.add_child(name_label)

		var elo_label := Label.new()
		elo_label.text = "Elo %d" % elo
		elo_label.add_theme_font_size_override("font_size", 11)
		elo_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
		text_col.add_child(elo_label)

		p_hbox.add_child(text_col)

		var checked_in := bool(p.get("checked_in", false))
		var status_label := Label.new()
		status_label.text = "✓ Checked in" if checked_in else "Awaiting check-in"
		status_label.modulate = Color(0.4, 0.9, 0.45) if checked_in else Color(1, 1, 1, 0.6)
		status_label.add_theme_font_size_override("font_size", 12)
		status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		p_hbox.add_child(status_label)

		grid.add_child(row)


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
