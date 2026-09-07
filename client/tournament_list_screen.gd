extends Control

## Cached so _on_tournament_list_stale_check can re-render with an up-to-date
## Session.my_tournaments once request_my_tournament's reply lands — it can
## arrive a beat after list_tournaments()'s own reply, which would otherwise
## leave a just-joined tournament briefly showing "Join" instead of "Cancel".
var _last_rows: Array = []
var _has_finished := false
var _on_private_tab := false


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


func _add_tournament_row(tournament: Dictionary, target_box: VBoxContainer, is_finished: bool, is_private: bool) -> void:
	var row_hbox := HBoxContainer.new()
	row_hbox.add_theme_constant_override("separation", 12)
	if is_finished:
		row_hbox.modulate = Color(1, 1, 1, 0.6)

	var tid := int(tournament.get("id", 0))
	var name := str(tournament.get("name", ""))
	var status := str(tournament.get("status", ""))
	var bracket_size := int(tournament.get("bracket_size", 0))
	var participant_count := int(tournament.get("participant_count", 0))
	var start_ts := int(tournament.get("start_ts", 0))
	var match_format := int(tournament.get("match_format", 1))
	var creator_name := str(tournament.get("creator_name", "—"))
	var has_cube := bool(tournament.get("has_cube", false))

	var info_vbox := VBoxContainer.new()
	info_vbox.custom_minimum_size = Vector2(300, 0)
	info_vbox.add_theme_constant_override("separation", 2)

	var name_label := Label.new()
	name_label.text = name
	name_label.add_theme_font_size_override("font_size", 14)
	info_vbox.add_child(name_label)

	var creator_label := Label.new()
	creator_label.text = "by %s" % creator_name
	creator_label.add_theme_font_size_override("font_size", 12)
	creator_label.modulate = Color(1, 1, 1, 0.7)
	info_vbox.add_child(creator_label)

	var status_text: String = {
		"signup_private": "Status: private sign-up (password)",
		"signup": "Status: sign-up open",
		"check_in": "Status: check-in",
		"in_progress": "Status: in progress",
	}.get(status, "Status: %s" % status)
	if status == "signup" and str(tournament.get("availability", "")) == "semi_private":
		status_text = "Status: open sign-up (was private)"
	var status_label := Label.new()
	status_label.text = status_text
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.modulate = Color(1, 1, 1, 0.7)
	info_vbox.add_child(status_label)

	var participants_label := Label.new()
	participants_label.text = "%d / %d signed up  ·  Best of %d" % [participant_count, bracket_size, match_format]
	participants_label.add_theme_font_size_override("font_size", 12)
	participants_label.modulate = Color(1, 1, 1, 0.7)
	info_vbox.add_child(participants_label)

	var pool_label := Label.new()
	pool_label.text = "Custom cube" if has_cube else "Original catalogue"
	pool_label.add_theme_font_size_override("font_size", 12)
	pool_label.modulate = Color(0.55, 0.8, 1.0, 1.0) if has_cube else Color(1, 1, 1, 0.7)
	info_vbox.add_child(pool_label)

	var start_label := Label.new()
	start_label.text = "Start: %s" % Time.get_datetime_string_from_unix_time(start_ts)
	start_label.add_theme_font_size_override("font_size", 12)
	start_label.modulate = Color(1, 1, 1, 0.7)
	info_vbox.add_child(start_label)

	row_hbox.add_child(info_vbox)

	var buttons_hbox := HBoxContainer.new()
	buttons_hbox.add_theme_constant_override("separation", 8)

	if not is_finished:
		var in_signup := status in ["signup", "signup_private"]
		# Cancel only ever shows up (and only ever works) pre-check-in — once
		# check-in opens, backing out is no longer a plain "never mind",
		# there's the no-show/bot-fill machinery to consider instead.
		if in_signup and (Session.my_tournaments as Dictionary).has(tid):
			var cancel_btn := Button.new()
			cancel_btn.text = "Cancel"
			cancel_btn.pressed.connect(_on_cancel_pressed.bind(tid))
			buttons_hbox.add_child(cancel_btn)
		elif in_signup:
			var join_btn := Button.new()
			join_btn.text = "Join"
			if is_private or status == "signup_private":
				join_btn.pressed.connect(_on_private_join_pressed.bind(tid, name))
			else:
				join_btn.pressed.connect(_on_join_pressed.bind(tid))
			buttons_hbox.add_child(join_btn)

		if status == "check_in":
			var checkin_btn := Button.new()
			checkin_btn.text = "Check In"
			checkin_btn.pressed.connect(_on_checkin_pressed.bind(tid))
			buttons_hbox.add_child(checkin_btn)

	if status in ["in_progress", "completed"]:
		var view_btn := Button.new()
		view_btn.text = "View Bracket"
		view_btn.pressed.connect(_on_view_bracket_pressed.bind(tid))
		buttons_hbox.add_child(view_btn)

	row_hbox.add_child(buttons_hbox)
	target_box.add_child(row_hbox)


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
		var error := str(result.get("error", "Unknown error"))
		_toast("Error: %s" % error)
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
