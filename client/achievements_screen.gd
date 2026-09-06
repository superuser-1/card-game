extends Control

# Tile feel mirrors the main-menu buttons / quest tiles: rounded panel, lit
# border + 5% swell on hover (see main_menu.gd _hover_quest_tile).
const HOVER_SCALE := 1.05
const HOVER_TIME := 0.12

const BORDER_IDLE := Color(1, 1, 1, 0.12)
const BORDER_HOVER := Color(1.0, 0.86, 0.55, 0.95)
const BORDER_DONE := Color(1.0, 0.80, 0.35, 0.85)


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	%AchievementsBox.add_theme_constant_override("h_separation", 14)
	%AchievementsBox.add_theme_constant_override("v_separation", 14)
	_render_achievements()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto("res://client/main_menu.tscn")
		get_viewport().set_input_as_handled()


func _render_achievements() -> void:
	for c in %AchievementsBox.get_children():
		c.queue_free()

	var stats: Dictionary = Session.account.get("stats", {})
	var unlocked: Dictionary = Session.account.get("achievements", {}).get("unlocked", {})
	var rows := AchievementSystem.rows(stats, unlocked)

	# Only show achievements that actually have art — the legacy tiered
	# achievements with no PNG yet would just render as empty placeholders.
	var visible_rows := []
	for row in rows:
		if AchievementArt.texture_for(str(row.get("id", ""))) != null:
			visible_rows.append(row)

	if visible_rows.is_empty():
		var label := Label.new()
		label.text = "No achievements yet."
		label.modulate = Color(1, 1, 1, 0.55)
		%AchievementsBox.add_child(label)
		return

	for row in visible_rows:
		%AchievementsBox.add_child(_make_tile(row))


func _make_tile(row: Dictionary) -> Control:
	var maxed := bool(row.get("maxed", false))
	var tiers_done := int(row.get("tiers_done", 0))
	var tier_total := int(row.get("tier_total", 1))
	var current := int(row.get("current_value", 0))
	var next_threshold := int(row.get("next_threshold", 0))

	# Outer panel: rounded bg + border, only mouse-STOP node so hover is clean.
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(240, 280)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.clip_contents = true

	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(12)
	sb.bg_color = Color(0.09, 0.09, 0.12, 0.95)
	sb.border_color = BORDER_DONE if maxed else BORDER_IDLE
	sb.set_border_width_all(2 if maxed else 1)
	tile.add_theme_stylebox_override("panel", sb)

	var inner := Control.new()
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.clip_contents = true
	tile.add_child(inner)

	# Full-bleed art, aspect-covered so the tile is always filled.
	var art := TextureRect.new()
	art.name = "Art"
	art.texture = AchievementArt.texture_for(str(row.get("id", "")))
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not maxed:
		art.modulate = Color(0.62, 0.62, 0.66)  # locked = desaturated-ish dim
	inner.add_child(art)

	# Bottom scrim with name + status/progress.
	var overlay := PanelContainer.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.anchor_left = 0.0
	overlay.anchor_top = 1.0
	overlay.anchor_right = 1.0
	overlay.anchor_bottom = 1.0
	overlay.offset_top = -70.0
	var scrim := StyleBoxFlat.new()
	scrim.bg_color = Color(0, 0, 0, 0.6)
	scrim.set_content_margin_all(10)
	overlay.add_theme_stylebox_override("panel", scrim)

	var strip := VBoxContainer.new()
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_theme_constant_override("separation", 3)
	overlay.add_child(strip)

	var name_label := Label.new()
	name_label.text = str(row.get("name", ""))
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	name_label.add_theme_constant_override("shadow_outline_size", 2)
	strip.add_child(name_label)

	if maxed:
		var done_label := Label.new()
		# 3-tier achievements keep the Bronze/Silver/Gold word; single-tier
		# milestones just read "UNLOCKED".
		done_label.text = "✓ COMPLETE" if tier_total > 1 else "✓ UNLOCKED"
		done_label.add_theme_font_size_override("font_size", 11)
		done_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.4))
		done_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		strip.add_child(done_label)
	else:
		var badge := ""
		if tier_total > 1 and tiers_done > 0:
			badge = AchievementSystem.TIER_NAMES[tiers_done - 1] + " · "
		var prog_label := Label.new()
		prog_label.text = "%s%d / %d" % [badge, current, next_threshold] if next_threshold > 0 else "%s%d" % [badge, current]
		prog_label.add_theme_font_size_override("font_size", 11)
		prog_label.add_theme_color_override("font_color", Color(0.85, 0.88, 1.0))
		prog_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		strip.add_child(prog_label)

		var bar := ProgressBar.new()
		bar.min_value = 0
		bar.max_value = max(next_threshold, 1)
		bar.value = clamp(current, 0, max(next_threshold, 1))
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 10)
		var bar_bg := StyleBoxFlat.new()
		bar_bg.bg_color = Color(1, 1, 1, 0.12)
		bar_bg.set_corner_radius_all(3)
		bar.add_theme_stylebox_override("background", bar_bg)
		var bar_fill := StyleBoxFlat.new()
		bar_fill.bg_color = Color(0.45, 0.60, 0.95)
		bar_fill.set_corner_radius_all(3)
		bar.add_theme_stylebox_override("fill", bar_fill)
		strip.add_child(bar)

	inner.add_child(overlay)

	# Hover: 5% swell + highlighted border (matches the menu buttons).
	tile.pivot_offset = tile.size * 0.5
	tile.resized.connect(func() -> void: tile.pivot_offset = tile.size * 0.5)
	tile.mouse_entered.connect(_hover_tile.bind(tile, sb, maxed, true))
	tile.mouse_exited.connect(_hover_tile.bind(tile, sb, maxed, false))

	return tile


func _hover_tile(tile: Control, sb: StyleBoxFlat, maxed: bool, over: bool) -> void:
	tile.z_index = 1 if over else 0
	if tile.has_meta("hover_tw"):
		var old: Tween = tile.get_meta("hover_tw")
		if old != null and old.is_valid():
			old.kill()
	var tw := create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(tile, "scale", Vector2.ONE * (HOVER_SCALE if over else 1.0), HOVER_TIME)
	tile.set_meta("hover_tw", tw)
	sb.border_color = BORDER_HOVER if over else (BORDER_DONE if maxed else BORDER_IDLE)
	sb.set_border_width_all(2 if (over or maxed) else 1)
