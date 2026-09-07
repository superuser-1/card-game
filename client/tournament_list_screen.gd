extends Control

## Cached so _on_tournament_list_stale_check can re-render with an up-to-date
## Session.my_tournaments once request_my_tournament's reply lands — it can
## arrive a beat after list_tournaments()'s own reply, which would otherwise
## leave a just-joined tournament briefly showing "Join" instead of "Cancel".
var _last_rows: Array = []
var _has_finished := false
var _on_private_tab := false
var _countdowns: Array = []   # {label, target_ts, prefix}
var _tick_accum := 0.0
var _refresh_accum := 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto("res://client/main_menu.tscn")
		get_viewport().set_input_as_handled()


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	%FinishedToggleButton.toggled.connect(_on_finished_toggled)
	%PublicTabButton.pressed.connect(func(): _select_tab(false))
	%PrivateTabButton.pressed.connect(func(): _select_tab(true))
	Net.tournament_list_received.connect(_on_tournament_list)
	Net.tournament_joined.connect(_on_tournament_joined)
	Net.tournament_withdrawn.connect(_on_tournament_withdrawn)
	Net.tournament_checked_in.connect(_on_tournament_checked_in)
	Net.my_tournament_status.connect(func(_t): _on_tournament_list_stale_check())
	Net.request_my_tournament()
	Net.list_tournaments()


func _process(delta: float) -> void:
	_tick_accum += delta
	if _tick_accum >= 0.5:
		_tick_accum = 0.0
		var now := int(Time.get_unix_time_from_system())
		for c in _countdowns:
			if is_instance_valid(c.label):
				c.label.text = "%s%s" % [c.prefix, _fmt_delta(int(c.target_ts) - now)]
	# A phase flip is server-driven and only broadcast to participants, so a
	# browser needs to re-poll to see it.
	_refresh_accum += delta
	if _refresh_accum >= 12.0:
		_refresh_accum = 0.0
		Net.list_tournaments()


func _fmt_delta(secs: int) -> String:
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


## {prefix, target_ts} for the countdown to a tournament's next phase, or {} if
## there's nothing to count down to (in progress / finished).
func _next_phase(row: Dictionary) -> Dictionary:
	match str(row.get("status", "")):
		"signup_private":
			if str(row.get("availability", "")) == "semi_private":
				return {"prefix": "Opens to all in ", "target": int(row.get("private_signup_close_ts", 0))}
			return {"prefix": "Check-in in ", "target": int(row.get("check_in_open_ts", 0))}
		"signup":
			return {"prefix": "Sign-up closes in ", "target": int(row.get("signup_close_ts", 0))}
		"pre_check_in":
			return {"prefix": "Check-in opens in ", "target": int(row.get("check_in_open_ts", 0))}
		"check_in":
			return {"prefix": "Starts in ", "target": int(row.get("start_ts", 0))}
	return {}


func _on_finished_toggled(pressed: bool) -> void:
	%FinishedScrollContainer.visible = pressed
	%FinishedToggleButton.text = "Hide Finished Tournaments ▴" if pressed else "Show Finished Tournaments ▾"


## Public vs Private-Tournaments tab. Finished tournaments only make sense under
## the Public view.
func _select_tab(private_tab: bool) -> void:
	_on_private_tab = private_tab
	%PublicTabButton.button_pressed = not private_tab
	%PrivateTabButton.button_pressed = private_tab
	%ScrollContainer.visible = not private_tab
	%PrivateScrollContainer.visible = private_tab
	%FinishedToggleButton.visible = (not private_tab) and _has_finished
	if private_tab:
		%FinishedScrollContainer.visible = false


## Cleanup: finished tournaments (completed/cancelled) never clutter the main
## list — they only ever show up tucked away under the "Finished Tournaments"
## toggle, read-only (View Bracket only, no Join/Check-In).
func _on_tournament_list(rows: Array) -> void:
	_last_rows = rows
	_render_rows(rows)


func _on_tournament_list_stale_check() -> void:
	if not _last_rows.is_empty():
		_render_rows(_last_rows)


func _render_rows(rows: Array) -> void:
	%StatusLabel.visible = false
	_countdowns.clear()

	for c in %RowsBox.get_children():
		c.queue_free()
	for c in %PrivateRowsBox.get_children():
		c.queue_free()
	for c in %FinishedRowsBox.get_children():
		c.queue_free()

	var public_rows := []
	var private_rows := []
	var finished_rows := []
	for row in rows:
		if str(row.get("status", "")) in ["completed", "cancelled"]:
			finished_rows.append(row)
		elif bool(row.get("is_private_now", false)):
			private_rows.append(row)
		else:
			public_rows.append(row)

	if public_rows.is_empty():
		%RowsBox.add_child(_make_label("No tournaments available.", 0.0))
	else:
		for row in public_rows:
			_add_tournament_row(row, %RowsBox, false, false)

	if private_rows.is_empty():
		%PrivateRowsBox.add_child(_make_label("No private tournaments open for sign-up.", 0.0))
	else:
		for row in private_rows:
			_add_tournament_row(row, %PrivateRowsBox, false, true)

	_has_finished = not finished_rows.is_empty()
	%FinishedToggleButton.visible = _has_finished and not _on_private_tab
	if not _has_finished:
		%FinishedScrollContainer.visible = false
		%FinishedToggleButton.button_pressed = false
	else:
		for row in finished_rows:
			_add_tournament_row(row, %FinishedRowsBox, true, false)


func _card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.15, 0.85)
	sb.border_color = Color(1, 1, 1, 0.10)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(12)
	return sb


func _info_label(text: String, col: Color, sz := 12) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	return l


func _add_tournament_row(tournament: Dictionary, target_box: VBoxContainer, is_finished: bool, is_private: bool) -> void:
	var tid := int(tournament.get("id", 0))
	var name := str(tournament.get("name", ""))
	var status := str(tournament.get("status", ""))
	var bracket_size := int(tournament.get("bracket_size", 0))
	var participant_count := int(tournament.get("participant_count", 0))
	var start_ts := int(tournament.get("start_ts", 0))
	var match_format := int(tournament.get("match_format", 1))
	var has_cube := bool(tournament.get("has_cube", false))
	var prizes: Dictionary = tournament.get("prizes", {})

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_style())
	if is_finished:
		card.modulate = Color(1, 1, 1, 0.6)

	var outer := HBoxContainer.new()
	outer.add_theme_constant_override("separation", 12)
	card.add_child(outer)

	# --- creator portrait ---
	outer.add_child(AvatarStack.make(
		str(tournament.get("creator_avatar", "")), str(tournament.get("creator_frame", "")),
		str(tournament.get("creator_background", "")), 52.0))

	# --- info column ---
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)

	info.add_child(_info_label(name, Color(1, 1, 1, 1), 15))
	info.add_child(_info_label("by %s" % str(tournament.get("creator_name", "—")), Color(1, 1, 1, 0.6)))

	var status_text: String = {
		"signup_private": "Private sign-up (password)",
		"signup": "Sign-up open",
		"pre_check_in": "Sign-up closed — check-in soon",
		"check_in": "Check-in",
		"in_progress": "In progress",
		"completed": "Completed",
		"cancelled": "Cancelled",
	}.get(status, status)
	if status == "signup" and str(tournament.get("availability", "")) == "semi_private":
		status_text = "Open sign-up (was private)"
	info.add_child(_info_label(status_text, Color(1, 1, 1, 0.7)))

	info.add_child(_info_label("%d / %d signed up  ·  Best of %d" % [participant_count, bracket_size, match_format], Color(1, 1, 1, 0.7)))
	info.add_child(_info_label("Custom cube" if has_cube else "Original catalogue",
		Color(0.55, 0.8, 1.0) if has_cube else Color(1, 1, 1, 0.6)))

	var phase := _next_phase(tournament)
	if not phase.is_empty() and int(phase.target) > 0:
		var cd := _info_label("", Color(1.0, 0.86, 0.5), 13)
		info.add_child(cd)
		_countdowns.append({"label": cd, "target_ts": int(phase.target), "prefix": str(phase.prefix)})
		cd.text = "%s%s" % [phase.prefix, _fmt_delta(int(phase.target) - int(Time.get_unix_time_from_system()))]
	info.add_child(_info_label("Starts %s" % Time.get_datetime_string_from_unix_time(start_ts, true).replace("T", " "), Color(1, 1, 1, 0.45), 11))

	outer.add_child(info)

	# --- right column: prizes + action ---
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(172, 0)
	right.add_theme_constant_override("separation", 8)
	right.add_child(PrizeView.column(prizes, 22.0))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(spacer)
	var action := _action_button(tournament, tid, name, status, is_finished, is_private)
	if action != null:
		action.size_flags_horizontal = Control.SIZE_SHRINK_END
		right.add_child(action)
	outer.add_child(right)

	target_box.add_child(card)


func _action_button(tournament: Dictionary, tid: int, name: String, status: String, is_finished: bool, is_private: bool) -> Button:
	if not is_finished:
		var in_signup := status in ["signup", "signup_private"]
		if in_signup and (Session.my_tournaments as Dictionary).has(tid):
			var b := Button.new()
			b.text = "Cancel"
			b.pressed.connect(_on_cancel_pressed.bind(tid))
			return b
		elif in_signup:
			var b := Button.new()
			b.text = "Join"
			if is_private or status == "signup_private":
				b.pressed.connect(_on_private_join_pressed.bind(tid, name))
			else:
				b.pressed.connect(_on_join_pressed.bind(tid))
			return b
		elif status == "check_in":
			var b := Button.new()
			b.text = "Check In"
			b.pressed.connect(_on_checkin_pressed.bind(tid))
			return b
	if status in ["in_progress", "completed"]:
		var b := Button.new()
		b.text = "View Bracket"
		b.pressed.connect(_on_view_bracket_pressed.bind(tid))
		return b
	return null


func _on_join_pressed(tournament_id: int) -> void:
	Net.join_tournament(tournament_id)


## Password-gated join: prompt for the password, then sign up. The tournament
## name is already known from the row, so it's just the one field.
func _on_private_join_pressed(tournament_id: int, tournament_name: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Join \"%s\"" % tournament_name
	dialog.ok_button_text = "Join"
	var edit := LineEdit.new()
	edit.secret = true
	edit.placeholder_text = "Tournament password"
	edit.custom_minimum_size = Vector2(280, 0)
	dialog.add_child(edit)
	var submit := func():
		Net.join_tournament(tournament_id, edit.text.strip_edges())
		dialog.queue_free()
	dialog.confirmed.connect(submit)
	edit.text_submitted.connect(func(_t): submit.call())
	dialog.canceled.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered(Vector2i(320, 130))
	edit.grab_focus()


func _on_cancel_pressed(tournament_id: int) -> void:
	Net.withdraw_tournament(tournament_id)


func _on_checkin_pressed(tournament_id: int) -> void:
	Net.tournament_check_in(tournament_id)


func _on_view_bracket_pressed(tournament_id: int) -> void:
	get_tree().set_meta("browse_tournament_id", tournament_id)
	Session.goto("res://client/tournament_bracket_screen.tscn")


func _on_tournament_joined(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_toast("Joined tournament!")
	else:
		var friendly := {
			"bad_password": "Wrong password.",
			"signup_closed": "Sign-up for that tournament has closed.",
			"tournament_full": "That tournament is full.",
			"already_signed_up": "You're already signed up.",
		}
		var error := str(result.get("error", "Unknown error"))
		_toast(friendly.get(error, "Error: %s" % error))
	Net.list_tournaments()


func _on_tournament_withdrawn(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_toast("Left tournament.")
	else:
		var error := str(result.get("error", "Unknown error"))
		_toast("Error: %s" % error)
	Net.list_tournaments()


func _on_tournament_checked_in(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_toast("Checked in!")
	else:
		var friendly := {
			"check_in_not_open": "Check-in isn't open yet.",
			"not_signed_up": "You didn't sign up for that tournament.",
			"late_check_in_not_open": "Last-minute check-in hasn't opened yet.",
			"tournament_full": "That tournament is full.",
			"already_checked_in": "You're already checked in.",
		}
		var error := str(result.get("error", "Unknown error"))
		_toast(friendly.get(error, "Error: %s" % error))
	Net.list_tournaments()


func _toast(msg: String) -> void:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.anchor_left = 0.4
	box.anchor_right = 0.4
	box.anchor_top = 0.86
	box.anchor_bottom = 0.86
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.07, 0.92)
	sb.border_color = Color(1, 1, 1, 0.15)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = msg
	lbl.add_theme_font_size_override("font_size", 15)
	box.add_child(lbl)
	add_child(box)

	box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(box, "modulate:a", 1.0, 0.15)
	tw.tween_interval(1.4)
	tw.tween_property(box, "modulate:a", 0.0, 0.4)
	await tw.finished
	box.queue_free()


func _make_label(txt: String, w: float) -> Label:
	var label := Label.new()
	label.text = txt
	if w > 0.0:
		label.custom_minimum_size.x = w
	return label
