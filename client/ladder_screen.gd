extends Control

func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	Net.ladder_received.connect(_on_ladder)
	Net.request_ladder(50, 0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto("res://client/main_menu.tscn")
		get_viewport().set_input_as_handled()


func _on_ladder(data: Dictionary) -> void:
	%StatusLabel.visible = false

	var your_rank: int = int(data.get("your_rank", 0))
	if your_rank > 0:
		%YourRankLabel.text = "Your rank: #%d" % your_rank
	else:
		%YourRankLabel.text = "Your rank: unranked"

	# Clear existing rows
	for c in %RowsBox.get_children():
		c.queue_free()

	# Add header row
	var header := HBoxContainer.new()
	header.add_child(_make_label("#", 44.0))
	header.add_child(_make_label("Player", 220.0))
	header.add_child(_make_label("Elo", 70.0))
	header.add_child(_make_label("W–L", 90.0))
	%RowsBox.add_child(header)

	var rows: Array = data.get("rows", [])
	if rows.is_empty():
		%RowsBox.add_child(_make_label("No ranked players yet.", 0.0))
		return

	# Add each row
	for row in rows:
		var row_hbox := HBoxContainer.new()

		var rank_label := _make_label(str(int(row.get("rank", 0))), 44.0)
		var name_label := _make_label(str(row.get("display_name", "")), 220.0)
		var elo_label := _make_label(str(int(row.get("elo", 0))), 70.0)
		var wl_label := _make_label("%d–%d" % [int(row.get("wins", 0)), int(row.get("losses", 0))], 90.0)

		row_hbox.add_child(rank_label)
		row_hbox.add_child(name_label)
		row_hbox.add_child(elo_label)
		row_hbox.add_child(wl_label)

		if bool(row.get("is_you", false)):
			row_hbox.modulate = Color(1.0, 0.9, 0.4, 1.0)
			name_label.text = "▶ " + name_label.text

		%RowsBox.add_child(row_hbox)


func _make_label(txt: String, w: float) -> Label:
	var label := Label.new()
	label.text = txt
	if w > 0.0:
		label.custom_minimum_size.x = w
	return label
