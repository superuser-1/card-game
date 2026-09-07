extends Control


var _cubes: Array = []
var _start_dates: Array = []   # date dicts {year,month,day}, index-aligned with StartDateOption


const _AVAILABILITY := ["open", "semi_private", "private"]


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	Net.tournament_created.connect(_on_tournament_created)
	_cubes = CubePicker.populate(%CubeOptionButton)
	_populate_start_dates()
	%AvailabilityOptionButton.item_selected.connect(func(_i): _refresh_rows())
	%LateCheckInCheckBox.toggled.connect(func(_p): _refresh_rows())
	_refresh_rows()
	%CreateButton.pressed.connect(_on_create_pressed)
	%CancelButton.pressed.connect(_close)


## Next 14 local days for the start-date dropdown. Uses noon to stay clear of
## DST edges when converting back and forth.
func _populate_start_dates() -> void:
	%StartDateOption.clear()
	_start_dates.clear()
	var noon_today := _local_dict_to_unix(_with_time(Time.get_datetime_dict_from_system(), 12, 0))
	for i in 14:
		var d := Time.get_datetime_dict_from_unix_time(noon_today + i * 86400)
		var date := {"year": d.year, "month": d.month, "day": d.day}
		_start_dates.append(date)
		var suffix := ""
		if i == 0:
			suffix = "  ·  Today"
		elif i == 1:
			suffix = "  ·  Tomorrow"
		%StartDateOption.add_item("%04d-%02d-%02d%s" % [d.year, d.month, d.day, suffix])
	%StartDateOption.select(0)


## Password rows: anything but Open. Private-close row: Semi-Private only.
## Late-check-in-open row: only when the late check-in box is ticked.
func _refresh_rows() -> void:
	var mode: String = _AVAILABILITY[int(%AvailabilityOptionButton.selected)]
	var gated := mode != "open"
	%PasswordLabel.visible = gated
	%PasswordLineEdit.visible = gated
	%PrivateCloseLabel.visible = mode == "semi_private"
	%MinutesUntilPrivateCloseSpinBox.visible = mode == "semi_private"
	var late: bool = %LateCheckInCheckBox.button_pressed
	%LateCheckInOpenLabel.visible = late
	%MinutesLateCheckInSpinBox.visible = late


## Time.get_unix_time_from_datetime_dict() reads its argument as UTC; correct for
## the machine's local offset (measured against "now") so a dict built from the
## local-time pickers maps to the right epoch.
func _local_dict_to_unix(d: Dictionary) -> int:
	var now_unix := int(Time.get_unix_time_from_system())
	var bias := now_unix - int(Time.get_unix_time_from_datetime_dict(Time.get_datetime_dict_from_system()))
	return int(Time.get_unix_time_from_datetime_dict(d)) + bias


func _with_time(date: Dictionary, hour: int, minute: int) -> Dictionary:
	return {"year": date.year, "month": date.month, "day": date.day,
		"hour": hour, "minute": minute, "second": 0}


func _on_create_pressed() -> void:
	var name_text := (%NameLineEdit.text as String).strip_edges()
	if name_text.is_empty():
		_toast("Enter a tournament name")
		return

	var availability: String = _AVAILABILITY[int(%AvailabilityOptionButton.selected)]
	var password := (%PasswordLineEdit.text as String).strip_edges()
	if availability != "open" and password.is_empty():
		_toast("Set a password for a private / semi-private tournament")
		return

	var bracket_size := int(%BracketSizeSpinBox.value)
	var is_dev_bot: bool = %DevBotCheckBox.button_pressed
	var late_check_in: bool = %LateCheckInCheckBox.button_pressed
	var match_format: int = [1, 3, 5][int(%MatchFormatOptionButton.selected)]
	var cube_ids := CubePicker.selected_ids(%CubeOptionButton, _cubes)

	# Absolute start time from the local-time pickers.
	var date: Dictionary = _start_dates[int(%StartDateOption.selected)]
	var start_ts := _local_dict_to_unix(_with_time(date, int(%StartHourSpin.value), int(%StartMinOption.get_selected_id())))
	if start_ts <= int(Time.get_unix_time_from_system()) + 120:
		_toast("Pick a start time at least a couple of minutes out")
		return

	# The rest are offsets (minutes) BEFORE start.
	var signup_close_ts := start_ts - int(%MinutesUntilCloseSpinBox.value) * 60
	var check_in_open_ts := start_ts - int(%MinutesCheckInOpenSpinBox.value) * 60
	if not (signup_close_ts <= check_in_open_ts and check_in_open_ts < start_ts):
		_toast("Order must be: sign-up close ≤ check-in ≤ start")
		return

	var private_signup_close_ts := 0
	if availability == "semi_private":
		private_signup_close_ts = start_ts - int(%MinutesUntilPrivateCloseSpinBox.value) * 60
		if private_signup_close_ts >= signup_close_ts:
			_toast("Private sign-up must close before open sign-up does")
			return

	var late_check_in_open_ts := 0
	if late_check_in:
		late_check_in_open_ts = start_ts - int(%MinutesLateCheckInSpinBox.value) * 60
		if late_check_in_open_ts < check_in_open_ts or late_check_in_open_ts >= start_ts:
			_toast("Late check-in must open between check-in and start")
			return

	%CreateButton.disabled = true
	Net.create_tournament(name_text, bracket_size, signup_close_ts, check_in_open_ts, start_ts,
		is_dev_bot, match_format, cube_ids, availability, password, private_signup_close_ts,
		late_check_in, late_check_in_open_ts)


func _on_tournament_created(result: Dictionary) -> void:
	%CreateButton.disabled = false
	if bool(result.get("ok", false)):
		# Server sends a fresh snapshot so "Tournaments Created" achievement
		# progress is up to date the moment the player opens the screen.
		var acc = result.get("account", {})
		if acc is Dictionary and not (acc as Dictionary).is_empty():
			Session.set_account(acc)
		_toast("Tournament created!")
		await get_tree().create_timer(0.5).timeout
		_close()
	else:
		var error := str(result.get("error", "Unknown error"))
		var friendly := {
			"cube_too_small": "That cube has fewer than %d cards — add more in the Deckbuilder." % CubeRules.MIN_SIZE,
			"not_admin": "You don't have permission to create tournaments.",
			"bad_name": "Tournament name must be 1–60 characters.",
			"bad_availability": "Pick a valid availability mode.",
			"bad_password": "Private tournaments need a password of 1–72 characters.",
			"bad_schedule": "Phase order must be: private close < sign-up close ≤ check-in ≤ late check-in < start.",
		}
		_toast(friendly.get(error, "Error: %s" % error))


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


func _close() -> void:
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
