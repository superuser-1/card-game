extends Control


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	Net.tournament_list_received.connect(_on_tournament_list)
	Net.tournament_joined.connect(_on_tournament_joined)
	Net.tournament_checked_in.connect(_on_tournament_checked_in)
	Net.list_tournaments()


func _on_tournament_list(rows: Array) -> void:
	%StatusLabel.visible = false

	for c in %RowsBox.get_children():
		c.queue_free()

	if rows.is_empty():
		%RowsBox.add_child(_make_label("No tournaments available.", 0.0))
		return

	for row in rows:
		_add_tournament_row(row)


func _add_tournament_row(tournament: Dictionary) -> void:
	var row_hbox := HBoxContainer.new()
	row_hbox.add_theme_constant_override("separation", 12)

	var tid := int(tournament.get("id", 0))
	var name := str(tournament.get("name", ""))
	var status := str(tournament.get("status", ""))
	var bracket_size := int(tournament.get("bracket_size", 0))
	var participant_count := int(tournament.get("participant_count", 0))
	var start_ts := int(tournament.get("start_ts", 0))

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
	participants_label.text = "%d / %d signed up" % [participant_count, bracket_size]
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

	if status == "signup":
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
	%RowsBox.add_child(row_hbox)


func _on_join_pressed(tournament_id: int) -> void:
	Net.join_tournament(tournament_id)


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
