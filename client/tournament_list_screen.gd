extends Control

## Cached so _on_tournament_list_stale_check can re-render with an up-to-date
## Session.my_tournaments once request_my_tournament's reply lands — it can
## arrive a beat after list_tournaments()'s own reply, which would otherwise
## leave a just-joined tournament briefly showing "Join" instead of "Cancel".
var _last_rows: Array = []


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	%FinishedToggleButton.toggled.connect(_on_finished_toggled)
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
	for c in %FinishedRowsBox.get_children():
		c.queue_free()

	var active_rows := []
	var finished_rows := []
	for row in rows:
		if str(row.get("status", "")) in ["completed", "cancelled"]:
			finished_rows.append(row)
		else:
			active_rows.append(row)

	if active_rows.is_empty():
		%RowsBox.add_child(_make_label("No tournaments available.", 0.0))
	else:
		for row in active_rows:
			_add_tournament_row(row, %RowsBox, false)

	%FinishedToggleButton.visible = not finished_rows.is_empty()
	if finished_rows.is_empty():
		%FinishedScrollContainer.visible = false
		%FinishedToggleButton.button_pressed = false
	else:
		for row in finished_rows:
			_add_tournament_row(row, %FinishedRowsBox, true)


func _add_tournament_row(tournament: Dictionary, target_box: VBoxContainer, is_finished: bool) -> void:
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

	var info_vbox := VBoxContainer.new()
	info_vbox.custom_minimum_size = Vector2(300, 0)
	info_vbox.add_theme_constant_override("separation", 2)

	var name_label := Label.new()
	name_label.text = name
	name_label.add_theme_font_size_override("font_size", 14)
	info_vbox.add_child(name_label)

	var status_label := Label.new()
	status_label.text = "Status: %s" % status
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.modulate = Color(1, 1, 1, 0.7)
	info_vbox.add_child(status_label)

	var participants_label := Label.new()
	participants_label.text = "%d / %d signed up  ·  Best of %d" % [participant_count, bracket_size, match_format]
	participants_label.add_theme_font_size_override("font_size", 12)
	participants_label.modulate = Color(1, 1, 1, 0.7)
	info_vbox.add_child(participants_label)

	var start_label := Label.new()
	start_label.text = "Start: %s" % Time.get_datetime_string_from_unix_time(start_ts)
	start_label.add_theme_font_size_override("font_size", 12)
	start_label.modulate = Color(1, 1, 1, 0.7)
	info_vbox.add_child(start_label)

	row_hbox.add_child(info_vbox)

	var buttons_hbox := HBoxContainer.new()
	buttons_hbox.add_theme_constant_override("separation", 8)

	if not is_finished:
		# Cancel only ever shows up (and only ever works) pre-check-in — once
		# check-in opens, backing out is no longer a plain "never mind",
		# there's the no-show/bot-fill machinery to consider instead.
		if status == "signup" and (Session.my_tournaments as Dictionary).has(tid):
			var cancel_btn := Button.new()
			cancel_btn.text = "Cancel"
			cancel_btn.pressed.connect(_on_cancel_pressed.bind(tid))
			buttons_hbox.add_child(cancel_btn)
		elif status == "signup":
			var join_btn := Button.new()
			join_btn.text = "Join"
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
		var error := str(result.get("error", "Unknown error"))
		_toast("Error: %s" % error)
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
