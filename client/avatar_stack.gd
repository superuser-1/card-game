class_name AvatarStack
## Layered avatar widget (background + avatar + frame overlay), matching the
## in-game player panels. Shared by the ladder, bracket and tournament screens
## so they all look the same.

const _FRAME_SHADER := preload("res://client/frame_overlay.gdshader")

static var _frame_mat: ShaderMaterial


static func _mat() -> ShaderMaterial:
	if _frame_mat == null:
		_frame_mat = ShaderMaterial.new()
		_frame_mat.shader = _FRAME_SHADER
		_frame_mat.set_shader_parameter("white_threshold", 0.9)
	return _frame_mat


static func make(avatar_id: String, frame_id: String, background_id: String, px: float) -> Control:
	var wrap := PanelContainer.new()
	wrap.custom_minimum_size = Vector2(px, px)
	wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wrap.clip_contents = true
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
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

	_layer(inner, Backgrounds.texture_for(background_id), null)
	_layer(inner, Avatars.texture_for(avatar_id), null)
	var fr := Frames.texture_for(frame_id)
	if fr != null:
		_layer(inner, fr, _mat())
	return wrap


static func _layer(parent: Control, tex: Texture2D, mat: ShaderMaterial) -> void:
	if tex == null:
		return
	var t := TextureRect.new()
	t.texture = tex
	t.material = mat
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(t)
