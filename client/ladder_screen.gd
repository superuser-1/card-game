extends Control

const FRAME_MAT_SHADER := preload("res://client/frame_overlay.gdshader")

const RANK_COLORS := {
	1: Color(1.00, 0.80, 0.30),   # gold
	2: Color(0.80, 0.83, 0.90),   # silver
	3: Color(0.85, 0.58, 0.36),   # bronze
}
const YOU_GOLD := Color(1.0, 0.86, 0.45)

var _frame_mat: ShaderMaterial


func _ready() -> void:
	_frame_mat = ShaderMaterial.new()
	_frame_mat.shader = FRAME_MAT_SHADER
	_frame_mat.set_shader_parameter("white_threshold", 0.9)

	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	%RowsBox.add_theme_constant_override("separation", 8)
	Net.ladder_received.connect(_on_ladder)
	Net.request_ladder(50, 0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto("res://client/main_menu.tscn")
		get_viewport().set_input_as_handled()


func _on_ladder(data: Dictionary) -> void:
	%StatusLabel.visible = false

	var your_rank: int = int(data.get("your_rank", 0))
	%YourRankLabel.text = ("Your rank   #%d" % your_rank) if your_rank > 0 else "Your rank   unranked"
	%YourRankLabel.add_theme_color_override("font_color", YOU_GOLD if your_rank > 0 else Color(1, 1, 1, 0.55))

	for c in %RowsBox.get_children():
		c.queue_free()

	var rows: Array = data.get("rows", [])
	if rows.is_empty():
		var empty := Label.new()
		empty.text = "No ranked players yet — play a ranked match to get on the board."
		empty.modulate = Color(1, 1, 1, 0.55)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		%RowsBox.add_child(empty)
		return

	var pinned_you := not bool(data.get("your_row_included", true))
	var last := rows.size() - 1
	for i in range(rows.size()):
		# A "···" divider before the viewer's own row when it was pinned on
		# from outside the visible window.
		if pinned_you and i == last and bool(rows[i].get("is_you", false)):
			var gap := Label.new()
			gap.text = "· · ·"
			gap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			gap.modulate = Color(1, 1, 1, 0.35)
			%RowsBox.add_child(gap)
		%RowsBox.add_child(_make_row(rows[i]))


func _make_row(row: Dictionary) -> Control:
	var is_you := bool(row.get("is_you", false))
	var rank := int(row.get("rank", 0))

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 62)
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(10)
	sb.bg_color = Color(0.17, 0.15, 0.10, 0.92) if is_you else Color(0.13, 0.13, 0.16, 0.85)
	sb.border_color = Color(YOU_GOLD.r, YOU_GOLD.g, YOU_GOLD.b, 0.9) if is_you else Color(1, 1, 1, 0.06)
	sb.set_border_width_all(2 if is_you else 1)
	sb.content_margin_left = 12
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	card.add_theme_stylebox_override("panel", sb)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 12)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(hb)

	hb.add_child(_rank_badge(rank))
	hb.add_child(_avatar_stack(row, 44.0))

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 2)
	hb.add_child(col)

	var name_l := Label.new()
	name_l.text = str(row.get("display_name", "Player"))
	name_l.add_theme_font_size_override("font_size", 16)
	if bool(row.get("is_provisional", false)):
		name_l.text += "  ·  provisional"
	if is_you:
		name_l.add_theme_color_override("font_color", YOU_GOLD)
	col.add_child(name_l)

	var w := int(row.get("wins", 0))
	var l := int(row.get("losses", 0))
	var d := int(row.get("draws", 0))
	var g := int(row.get("games", w + l + d))
	var wr := (100.0 * float(w) / float(g)) if g > 0 else 0.0
	var rec := Label.new()
	rec.text = "%d W · %d L%s   ·   %.0f%% win" % [w, l, ("  ·  %d D" % d) if d > 0 else "", wr]
	rec.add_theme_font_size_override("font_size", 11)
	rec.add_theme_color_override("font_color", Color(0.68, 0.71, 0.80))
	col.add_child(rec)

	var elo_box := VBoxContainer.new()
	elo_box.custom_minimum_size.x = 66
	elo_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	elo_box.add_theme_constant_override("separation", 0)
	var elo_l := Label.new()
	elo_l.text = str(int(row.get("elo", 0)))
	elo_l.add_theme_font_size_override("font_size", 20)
	elo_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	elo_l.add_theme_color_override("font_color", Color(0.86, 0.91, 1.0))
	elo_box.add_child(elo_l)
	var elo_cap := Label.new()
	elo_cap.text = "ELO"
	elo_cap.add_theme_font_size_override("font_size", 9)
	elo_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	elo_cap.add_theme_color_override("font_color", Color(0.52, 0.55, 0.64))
	elo_box.add_child(elo_cap)
	hb.add_child(elo_box)

	return card


func _rank_badge(rank: int) -> Control:
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(42, 42)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var s := StyleBoxFlat.new()
	s.set_corner_radius_all(21)
	if RANK_COLORS.has(rank):
		var c: Color = RANK_COLORS[rank]
		s.bg_color = Color(c.r, c.g, c.b, 0.18)
		s.border_color = c
		s.set_border_width_all(2)
	else:
		s.bg_color = Color(1, 1, 1, 0.04)
		s.border_color = Color(1, 1, 1, 0.09)
		s.set_border_width_all(1)
	box.add_theme_stylebox_override("panel", s)

	var l := Label.new()
	l.text = str(rank)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 15 if rank < 100 else 12)
	if RANK_COLORS.has(rank):
		l.add_theme_color_override("font_color", RANK_COLORS[rank])
	else:
		l.add_theme_color_override("font_color", Color(0.8, 0.82, 0.9))
	box.add_child(l)
	return box


## bg + avatar + frame, layered like the in-game player panels.
func _avatar_stack(row: Dictionary, px: float) -> Control:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = Vector2(px, px)
	wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wrap.clip_contents = true
	var ws := StyleBoxFlat.new()
	ws.set_corner_radius_all(6)
	ws.bg_color = Color(0, 0, 0, 0.35)
	ws.border_color = Color(1, 1, 1, 0.10)
	ws.set_border_width_all(1)
	wrap.add_theme_stylebox_override("panel", ws)

	var inner := Control.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.clip_contents = true
	wrap.add_child(inner)

	var bg := TextureRect.new()
	bg.texture = Backgrounds.texture_for(str(row.get("background", "")))
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(bg)

	var av := TextureRect.new()
	av.texture = Avatars.texture_for(str(row.get("avatar", "")))
	av.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	av.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(av)

	var fr_tex := Frames.texture_for(str(row.get("frame", "")))
	if fr_tex != null:
		var fr := TextureRect.new()
		fr.texture = fr_tex
		fr.material = _frame_mat
		fr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		fr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.add_child(fr)

	return wrap
