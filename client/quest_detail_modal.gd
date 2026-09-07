extends Control
## Read-only detail popup for one daily quest. Opened from main_menu's quest
## tiles. `setup(row)` takes a Session.account.quests entry
## ({id, name, points, target, progress, completed}); the description / how-to
## text comes from QuestSystem.def_for(id).

const FRAME_SHADER := preload("res://client/rounded_frame.gdshader")

const GROUP_TITLE := {"money": "money", "time": "time", "awards": "awards",
	"acclaim": "acclaim", "people": "people"}


func setup(row: Dictionary) -> void:
	var id := str(row.get("id", ""))
	var def := QuestSystem.def_for(id)
	var target := int(row.get("target", def.get("target", 1)))
	var progress: int = clamp(int(row.get("progress", 0)), 0, target)
	var done := bool(row.get("completed", false))

	var body: VBoxContainer = %Body

	# --- art ---
	var art_wrap := Control.new()
	art_wrap.custom_minimum_size = Vector2(0, 210)
	art_wrap.clip_contents = true
	var art := TextureRect.new()
	art.texture = QuestArt.texture_for(id)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if done:
		art.modulate = Color(1, 1, 1, 0.4)
	art_wrap.add_child(art)
	_add_rounded_frame(art_wrap)
	body.add_child(art_wrap)

	# --- title + reward ---
	var title := Label.new()
	title.text = str(row.get("name", def.get("name", "Quest")))
	title.add_theme_font_size_override("font_size", 22)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(title)

	var reward := Label.new()
	reward.text = "+%d points" % int(row.get("points", def.get("points", 0)))
	reward.add_theme_font_size_override("font_size", 14)
	reward.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	body.add_child(reward)

	# --- progress ---
	if done:
		var fin := Label.new()
		fin.text = "✓ Completed"
		fin.add_theme_font_size_override("font_size", 14)
		fin.add_theme_color_override("font_color", Color(0.4, 0.9, 0.45))
		body.add_child(fin)
	else:
		var bar := ProgressBar.new()
		bar.min_value = 0
		bar.max_value = target
		bar.value = progress
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 18)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color(1, 1, 1, 0.12)
		bg.set_corner_radius_all(3)
		bar.add_theme_stylebox_override("background", bg)
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color(0.30, 0.78, 0.35)
		fill.set_corner_radius_all(3)
		bar.add_theme_stylebox_override("fill", fill)
		body.add_child(bar)

		var prog := Label.new()
		prog.text = "%d / %d" % [progress, target]
		prog.add_theme_font_size_override("font_size", 12)
		prog.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		body.add_child(prog)

	body.add_child(HSeparator.new())

	# --- description ---
	var desc_txt := str(def.get("desc", ""))
	if desc_txt != "":
		var desc := Label.new()
		desc.text = desc_txt
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.add_theme_font_size_override("font_size", 14)
		body.add_child(desc)

	# --- how to complete ---
	var how_header := Label.new()
	how_header.text = "How to complete"
	how_header.add_theme_font_size_override("font_size", 13)
	how_header.add_theme_color_override("font_color", Color(0.6, 0.78, 1.0))
	body.add_child(how_header)

	var how := Label.new()
	how.text = str(def.get("how", "Play matches to make progress."))
	how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	how.add_theme_font_size_override("font_size", 13)
	how.add_theme_color_override("font_color", Color(1, 1, 1, 0.82))
	body.add_child(how)

	if str(def.get("type", "")) == "group_win":
		var cats := Label.new()
		cats.text = "Counts as %s: %s" % [
			GROUP_TITLE.get(str(def.get("group", "")), str(def.get("group", ""))),
			_group_category_names(str(def.get("group", "")))]
		cats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cats.add_theme_font_size_override("font_size", 12)
		cats.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		body.add_child(cats)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(spacer)

	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(_close)
	body.add_child(close)


func _ready() -> void:
	$Dim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_close())


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()


func _close() -> void:
	var parent := get_parent()
	if parent is CanvasLayer:
		parent.queue_free()
	else:
		queue_free()


func _group_category_names(group: String) -> String:
	var names := []
	for key in GameEngine.CATEGORY_GROUP:
		if str(GameEngine.CATEGORY_GROUP[key]) == group:
			names.append(CategoryView.DISPLAY_NAME.get(key, key))
	return ", ".join(names)


func _add_rounded_frame(host: Control) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = FRAME_SHADER
	mat.set_shader_parameter("radius_px", 10.0)
	mat.set_shader_parameter("border_px", 1.0)
	mat.set_shader_parameter("border_color", Color(1, 1, 1, 0.1))
	var frame := ColorRect.new()
	frame.color = Color(0.11, 0.12, 0.16)
	frame.material = mat
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.resized.connect(func() -> void: mat.set_shader_parameter("rect_px", frame.size))
	host.add_child(frame)
	mat.set_shader_parameter("rect_px", frame.size)
