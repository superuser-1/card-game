extends Control

const AVATAR_PICKER := preload("res://client/avatar_picker.tscn")
const ROUND_SHADER := preload("res://client/rounded_button.gdshader")

# Menu button feel: rounded art via ROUND_SHADER, and on hover the border
# lights up while the button swells 5%.
const HOVER_SCALE := 1.05
const HOVER_TIME := 0.10
const EDGE_STRIP_FRAC := 0.05        # backplate width, as a fraction of button width
const EDGE_BORDER_ON := 0.02         # rounded_button.gdshader border_width while hovered

var _rank := 0
var _avatar_onboard: Control = null


func _ready() -> void:
	if not Session.is_logged_in():
		Session.goto("res://client/login_screen.tscn")
		return

	# Safety net: any path back to the menu from a singleplayer game restores
	# the client's networked role, so matchmaking/ladder RPCs work again even
	# if we didn't come through the result screen's Menu button.
	if Net.is_solo:
		Net.end_singleplayer()

	_render_account()

	Net.profile_received.connect(_on_profile)
	Net.avatar_updated.connect(_on_avatar_updated)
	Net.frame_updated.connect(_on_avatar_updated)
	Net.background_updated.connect(_on_avatar_updated)
	Net.request_profile()

	_maybe_prompt_avatar()
	_render_quests()

	Net.ladder_received.connect(_on_ladder)
	Net.request_ladder(1, 0)

	%SingleplayerButton.pressed.connect(_on_singleplayer)
	%MultiplayerButton.pressed.connect(_show_multiplayer)
	%LadderButton.pressed.connect(_on_ladder_screen)
	%DeckbuilderButton.pressed.connect(_on_deckbuilder)
	%OptionsButton.pressed.connect(_on_options)
	%LogoutButton.pressed.connect(_on_logout)

	_decorate_image_button(%MultiplayerButton, "multiplayer")
	_decorate_image_button(%SingleplayerButton, "solo play")
	_decorate_image_button(%LadderButton, "ladder")
	_decorate_image_button(%DeckbuilderButton, "deckbuilder")
	_decorate_image_button(%OptionsButton, "options")

	# Multiplayer submenu — swaps in over the main 4 tiles, side panels stay.
	%RankedButton.pressed.connect(_on_ranked_play)
	%TournamentButton.pressed.connect(_on_tournament_play)
	%CustomGameButton.pressed.connect(_on_custom_game)
	%MpPlaceholderButton.pressed.connect(_coming_soon.bind("That mode"))
	%BackButton.pressed.connect(_show_main)
	_decorate_panel_button(%RankedButton, false)
	_decorate_panel_button(%TournamentButton, true)
	_decorate_panel_button(%CustomGameButton, true)
	_decorate_panel_button(%MpPlaceholderButton, true)
	_decorate_panel_button(%BackButton, false)

	# Click the portrait to change avatar.
	%AvatarImage.mouse_filter = Control.MOUSE_FILTER_STOP
	%AvatarImage.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	%AvatarImage.tooltip_text = "Change avatar, frame or background"
	%AvatarImage.gui_input.connect(_on_avatar_clicked)


func _render_account() -> void:
	var a: Dictionary = Session.account
	%NameLabel.text = str(a.get("display_name", "Player"))
	%PortraitBgImage.texture = Backgrounds.texture_for(str(a.get("background", "")))
	%AvatarImage.texture = Avatars.texture_for(str(a.get("avatar", "")))
	%PortraitFrameImage.texture = Frames.texture_for(str(a.get("frame", "")))

	var rank_text: String = "—"
	if _rank > 0:
		rank_text = str(_rank)

	%StatsLabel.text = "Elo %d · Rank #%s" % [int(a.get("elo", 0)), rank_text]
	%RecordLabel.text = "%d W – %d L · %d pts" % [
		int(a.get("wins", 0)),
		int(a.get("losses", 0)),
		int(a.get("points", 0)),
	]


func _on_profile(data: Dictionary) -> void:
	Session.set_account(data.get("account", {}))
	_render_account()
	_maybe_prompt_avatar()
	_render_quests()


## First-login onboarding: if the account has no avatar yet, raise the picker
## in mandatory mode (no cancel) and keep it up until the server confirms the
## saved choice. Reappears on every menu entry until an avatar is set.
func _maybe_prompt_avatar() -> void:
	if is_instance_valid(_avatar_onboard):
		return
	if not Avatars.needs_choice(str(Session.account.get("avatar", ""))):
		return

	var layer := CanvasLayer.new()
	layer.name = "AvatarOnboardLayer"
	layer.layer = 100
	var picker: Control = AVATAR_PICKER.instantiate()
	picker.configure(false)
	picker.chosen.connect(_on_onboard_avatar_chosen)
	layer.add_child(picker)
	add_child(layer)
	_avatar_onboard = picker


func _on_onboard_avatar_chosen(id: String) -> void:
	Net.set_avatar(id)


func _on_avatar_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_open_avatar_change()


## Voluntary avatar change from the menu — the picker opens dismissable (has a
## Cancel), unlike the forced first-login prompt. On pick, Net.set_avatar()
## round-trips and _on_avatar_updated refreshes the portrait.
func _open_avatar_change() -> void:
	if is_instance_valid(_avatar_onboard):
		return  # forced onboarding is still up
	if get_node_or_null("AvatarChangeLayer") != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "AvatarChangeLayer"
	layer.layer = 100
	var picker: Control = AVATAR_PICKER.instantiate()
	picker.configure(true)
	picker.chosen.connect(func(id: String) -> void: Net.set_avatar(id))
	picker.frame_chosen.connect(func(id: String) -> void: Net.set_frame(id))
	picker.background_chosen.connect(func(id: String) -> void: Net.set_background(id))
	picker.tree_exited.connect(layer.queue_free)
	layer.add_child(picker)
	add_child(layer)


func _on_avatar_updated(account: Dictionary) -> void:
	Session.set_account(account)
	_render_account()
	if is_instance_valid(_avatar_onboard):
		var layer := _avatar_onboard.get_parent()
		_avatar_onboard = null
		if layer != null:
			layer.queue_free()


func _on_ladder(data: Dictionary) -> void:
	_rank = int(data.get("your_rank", 0))
	_render_account()


func _on_singleplayer() -> void:
	if Session.active_tournament_id != 0:
		_toast("Checked in to a tournament — finish it first.")
		return
	var reveal: bool = bool(Session.settings.get("sp_reveal_mode", false))
	Net.start_singleplayer(reveal)
	Session.goto("res://client/game_ui.tscn")


## Multiplayer opens a submenu in place of the main 4 tiles; the top bar,
## quest panel and Options button stay put. Back returns to the main tiles.
func _show_multiplayer() -> void:
	%MenuGrid.visible = false
	%MultiplayerGrid.visible = true
	%BackButton.visible = true


func _show_main() -> void:
	%MultiplayerGrid.visible = false
	%MenuGrid.visible = true
	%BackButton.visible = false


func _on_ranked_play() -> void:
	Session.goto("res://client/queue_screen.tscn")


func _on_tournament_play() -> void:
	Session.goto("res://client/tournament_list_screen.tscn")


func _on_custom_game() -> void:
	Session.goto("res://client/custom_game_screen.tscn")


func _coming_soon(what: String) -> void:
	_toast("%s — coming soon" % what)


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


func _on_ladder_screen() -> void:
	Session.goto("res://client/ladder_screen.tscn")


func _on_deckbuilder() -> void:
	Session.goto("res://client/deckbuilder_screen.tscn")


func _on_options() -> void:
	Session.open_options()


func _on_logout() -> void:
	Session.clear()
	Session.goto("res://client/login_screen.tscn")


# --- menu button styling --------------------------------------------------

## Mask an art button's corners round via ROUND_SHADER (the button keeps
## filling its wide grid cell, art cropped not stretched), and lay its name
## down the left edge on a grey backplate EDGE_STRIP_FRAC of the button wide.
func _decorate_image_button(btn: TextureButton, label_text: String) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = ROUND_SHADER
	mat.set_shader_parameter("border_width", 0.0)
	btn.material = mat

	var strip := Panel.new()
	strip.name = "EdgeStrip"
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.anchor_right = EDGE_STRIP_FRAC
	strip.anchor_bottom = 1.0
	strip.offset_right = 0.0
	strip.offset_bottom = 0.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.11, 0.13, 0.6)
	sb.corner_radius_top_left = 14
	sb.corner_radius_bottom_left = 14
	strip.add_theme_stylebox_override("panel", sb)
	btn.add_child(strip)

	var lbl := Label.new()
	lbl.name = "EdgeLabel"
	lbl.text = label_text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(0.93, 0.93, 0.93))
	btn.add_child(lbl)

	btn.resized.connect(_layout_image_button.bind(btn, lbl))
	_layout_image_button(btn, lbl)
	_wire_hover(btn)


## Keep the rounded-corner shader honest (it needs the live crop + aspect),
## re-place the vertical edge label, and re-centre the hover-scale pivot —
## all of which depend on the button's current pixel size.
func _layout_image_button(btn: TextureButton, lbl: Label) -> void:
	var w := btn.size.x
	var h := btn.size.y
	btn.pivot_offset = btn.size * 0.5
	if w <= 0.0 or h <= 0.0:
		return

	var mat := btn.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("node_aspect", w / h)
		var tex := btn.texture_normal
		if tex != null:
			# Replicate KEEP_ASPECT_COVERED's source crop so the shader can map
			# UV back to 0..1 across the node.
			var ts := tex.get_size()
			var s := maxf(w / ts.x, h / ts.y)
			var vis := Vector2(w, h) / s          # texture px actually shown
			var pos := (ts - vis) * 0.5
			mat.set_shader_parameter("uv_min", pos / ts)
			mat.set_shader_parameter("uv_max", (pos + vis) / ts)

	var strip_w := w * EDGE_STRIP_FRAC
	# Label font tracks the strip so it stays inside it on the small Options
	# button as well as the big grid tiles.
	lbl.add_theme_font_size_override("font_size", int(clampf(strip_w * 0.82, 9.0, 14.0)))
	# Box authored horizontal (length = along the button's height, thickness =
	# strip width), pivoted at its centre, then turned 90° counter-clockwise so
	# the text runs bottom-to-top up the strip.
	lbl.size = Vector2(h * 0.9, strip_w)
	lbl.pivot_offset = lbl.size * 0.5
	lbl.rotation_degrees = -90.0
	lbl.position = Vector2(strip_w, h) * 0.5 - lbl.size * 0.5


## Art-less menu buttons (the multiplayer submenu, Back): a translucent
## rounded panel with a centred title, lit border + 5% swell on hover. `dim`
## marks a not-yet-built mode.
func _decorate_panel_button(btn: Button, dim: bool) -> void:
	btn.add_theme_stylebox_override("normal", _panel_box(Color(0.06, 0.06, 0.09, 0.66), Color(1, 1, 1, 0.14), 1))
	var lit := _panel_box(Color(0.1, 0.1, 0.14, 0.8), Color(1.0, 0.86, 0.55, 0.9), 2)
	btn.add_theme_stylebox_override("hover", lit)
	btn.add_theme_stylebox_override("pressed", lit)
	btn.add_theme_stylebox_override("focus", lit)
	btn.add_theme_font_size_override("font_size", 22 if btn.name == "BackButton" else 30)
	if dim:
		btn.self_modulate = Color(1, 1, 1, 0.68)
	btn.resized.connect(func() -> void: btn.pivot_offset = btn.size * 0.5)
	btn.pivot_offset = btn.size * 0.5
	_wire_hover(btn)


func _panel_box(bg: Color, border: Color, border_w: int) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = bg
	b.border_color = border
	b.set_border_width_all(border_w)
	b.set_corner_radius_all(14)
	b.set_content_margin_all(14)
	return b


func _wire_hover(ctrl: Control) -> void:
	ctrl.mouse_entered.connect(_hover_button.bind(ctrl, true))
	ctrl.mouse_exited.connect(_hover_button.bind(ctrl, false))


func _hover_button(ctrl: Control, over: bool) -> void:
	ctrl.z_index = 1 if over else 0
	if ctrl.has_meta("hover_tw"):
		var old: Tween = ctrl.get_meta("hover_tw")
		if old != null and old.is_valid():
			old.kill()
	var tw := create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(ctrl, "scale", Vector2.ONE * (HOVER_SCALE if over else 1.0), HOVER_TIME)
	if ctrl.material is ShaderMaterial:
		tw.parallel().tween_property(
			ctrl.material, "shader_parameter/border_width",
			EDGE_BORDER_ON if over else 0.0, HOVER_TIME
		)
	ctrl.set_meta("hover_tw", tw)


func _render_quests() -> void:
	var vbox := %QuestVBox
	for child in vbox.get_children():
		if child.name != "QuestHeader":
			child.queue_free()
	var rows: Array = Session.account.get("quests", [])
	if rows.is_empty():
		var empty := Label.new()
		empty.text = "Quests load after your first match."
		empty.modulate = Color(1, 1, 1, 0.55)
		empty.add_theme_font_size_override("font_size", 12)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(empty)
		return

	for r in rows:
		var done: bool = bool(r.get("completed", false))

		# Tile: PanelContainer carries the rounded bg + hover border; it is the
		# only STOP-filter node so hover is unambiguous. All visual content lives
		# in a plain inner Control so anchors/offsets are actually honoured
		# (a PanelContainer would stretch every child to fill instead).
		var tile := PanelContainer.new()
		tile.custom_minimum_size = Vector2(0, 150)
		tile.size_flags_vertical = Control.SIZE_EXPAND_FILL
		tile.clip_contents = true
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(10)
		sb.bg_color = Color(0.08, 0.08, 0.10, 0.9)
		sb.border_color = Color(1, 1, 1, 0.1)
		sb.set_border_width_all(1)
		tile.add_theme_stylebox_override("panel", sb)

		var inner := Control.new()
		inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		inner.clip_contents = true
		tile.add_child(inner)

		# Art: full-bleed background
		var art := TextureRect.new()
		art.name = "Art"
		art.texture = QuestArt.texture_for(str(r.get("id", "")))
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		inner.add_child(art)

		# Bottom overlay: name, points, progress bar over a dark scrim.
		var overlay := PanelContainer.new()
		overlay.name = "BottomOverlay"
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.anchor_left = 0.0
		overlay.anchor_top = 1.0
		overlay.anchor_right = 1.0
		overlay.anchor_bottom = 1.0
		overlay.offset_left = 0.0
		overlay.offset_right = 0.0
		overlay.offset_top = -66.0
		overlay.offset_bottom = 0.0
		var scrim := StyleBoxFlat.new()
		scrim.bg_color = Color(0, 0, 0, 0.5)
		scrim.set_content_margin_all(7)
		overlay.add_theme_stylebox_override("panel", scrim)

		var strip := VBoxContainer.new()
		strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		strip.add_theme_constant_override("separation", 2)
		overlay.add_child(strip)

		var name_label := Label.new()
		name_label.name = "NameLabel"
		name_label.text = str(r.get("name", "Quest"))
		name_label.add_theme_font_size_override("font_size", 13)
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		name_label.add_theme_constant_override("shadow_outline_size", 2)
		strip.add_child(name_label)

		# Points reward, sits between the name and the bar.
		var points_label := Label.new()
		points_label.name = "PointsLabel"
		points_label.text = "+%d pts" % int(r.get("points", 0))
		points_label.add_theme_font_size_override("font_size", 11)
		points_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
		points_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
		strip.add_child(points_label)

		var bar := ProgressBar.new()
		bar.name = "Bar"
		bar.min_value = 0
		bar.max_value = int(r.get("target", 1))
		bar.value = int(r.get("progress", 0))
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(0, 14)
		var bar_bg := StyleBoxFlat.new()
		bar_bg.bg_color = Color(1, 1, 1, 0.12)
		bar_bg.set_corner_radius_all(3)
		bar.add_theme_stylebox_override("background", bar_bg)
		var bar_fill := StyleBoxFlat.new()
		bar_fill.bg_color = Color(0.30, 0.78, 0.35)
		bar_fill.set_corner_radius_all(3)
		bar.add_theme_stylebox_override("fill", bar_fill)
		strip.add_child(bar)

		inner.add_child(overlay)

		# Completed: green "FINISHED" banner at the top, art + bar dimmed.
		if done:
			var finished_label := Label.new()
			finished_label.name = "FinishedLabel"
			finished_label.text = "✓ FINISHED"
			finished_label.anchor_left = 0.0
			finished_label.anchor_top = 0.0
			finished_label.anchor_right = 1.0
			finished_label.anchor_bottom = 0.0
			finished_label.offset_bottom = 30.0
			finished_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			finished_label.add_theme_font_size_override("font_size", 14)
			finished_label.add_theme_color_override("font_color", Color(0.40, 0.90, 0.45))
			finished_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
			finished_label.add_theme_constant_override("shadow_outline_size", 2)
			finished_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			inner.add_child(finished_label)

			art.modulate = Color(1, 1, 1, 0.30)
			name_label.modulate = Color(0.65, 0.65, 0.65)
			points_label.modulate = Color(0.65, 0.65, 0.65)
			bar.modulate = Color(0.65, 0.65, 0.65)
			bar.value = int(r.get("target", 1))

		# Hover: 5% swell + highlighted border, matching the menu buttons.
		tile.pivot_offset = tile.size * 0.5
		tile.resized.connect(func() -> void: tile.pivot_offset = tile.size * 0.5)
		tile.mouse_entered.connect(_hover_quest_tile.bind(tile, sb, true))
		tile.mouse_exited.connect(_hover_quest_tile.bind(tile, sb, false))

		vbox.add_child(tile)


func _hover_quest_tile(tile: Control, sb: StyleBoxFlat, over: bool) -> void:
	tile.z_index = 1 if over else 0
	if tile.has_meta("hover_tw"):
		var old: Tween = tile.get_meta("hover_tw")
		if old != null and old.is_valid():
			old.kill()
	var tw := create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(tile, "scale", Vector2.ONE * (HOVER_SCALE if over else 1.0), HOVER_TIME)
	tile.set_meta("hover_tw", tw)
	sb.border_color = Color(1.0, 0.86, 0.55, 0.9) if over else Color(1, 1, 1, 0.1)
	sb.set_border_width_all(2 if over else 1)
