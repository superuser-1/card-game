extends Control
## Draws an actual connected single-elimination bracket tree (paired boxes
## merging into their next-round box via right-angle connector lines).
## Connector lines and box backgrounds are custom-drawn (_draw()); each
## player row (avatar+background+frame composite, name, Elo) is a real child
## Control positioned absolutely, since compositing the frame's shader
## overlay per-avatar isn't practical from a single _draw() call. Bots have
## no real account, so they get a stable-per-slot random avatar/frame/bg
## combo instead (seeded off round+slot+side, not re-rolled on every redraw).

const FRAME_SHADER := preload("res://client/frame_overlay.gdshader")

const BOX_W := 210.0
const ROW_H := 38.0
const BOX_H := ROW_H * 2.0
const ROUND_GAP := 64.0
const MATCH_GAP := 16.0
const MARGIN := 20.0
const AVATAR_SIZE := 30.0
const ROW_PAD := 4.0

var _rounds: Array = []
var _participants: Array = []
var _my_id: int = 0
var _positions: Array = []  # positions[r][i] = y-center of that slot's box
var _row_nodes: Array = []  # child Controls built by set_data(), cleared each call
## {node, position, size} per row — Label minimum-size isn't accurate until
## at least one frame has passed (text-shaping settles late), so a Control's
## size assigned immediately after creating text children gets clamped UP to
## a temporarily-inflated minimum and then never shrinks back down on its
## own. _reapply_row_sizes() re-asserts the intended size one frame later,
## once real metrics have settled, to correct that.
var _row_targets: Array = []


func set_data(rounds: Array, participants: Array, my_id: int) -> void:
	_rounds = rounds
	_participants = participants
	_my_id = my_id
	_compute_positions()

	for n in _row_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_row_nodes.clear()
	_row_targets.clear()

	var round_count := _rounds.size()
	var total_w: float = MARGIN * 2.0 + round_count * BOX_W + maxi(round_count - 1, 0) * ROUND_GAP
	var total_h := MARGIN * 2.0
	if not _positions.is_empty():
		var first_round: Array = _positions[0]
		total_h += first_round.size() * (BOX_H + MATCH_GAP) - MATCH_GAP
	custom_minimum_size = Vector2(total_w, maxf(total_h, BOX_H + MARGIN * 2.0))

	for r in range(_rounds.size()):
		for i in range((_rounds[r] as Array).size()):
			_build_slot_rows(r, i)

	queue_redraw()
	if not _row_targets.is_empty():
		# Engine.get_main_loop() rather than get_tree() — this can run before
		# this Control is confirmed inside a tree from its own perspective
		# (e.g. immediately after being reparented), and the main loop is
		# always available regardless.
		(Engine.get_main_loop() as SceneTree).process_frame.connect(_reapply_row_sizes, CONNECT_ONE_SHOT)


func _reapply_row_sizes() -> void:
	for entry in _row_targets:
		if is_instance_valid(entry.node):
			entry.node.size = entry.size


func _compute_positions() -> void:
	_positions = []
	if _rounds.is_empty():
		return
	var y := []
	for i in range((_rounds[0] as Array).size()):
		y.append(MARGIN + i * (BOX_H + MATCH_GAP) + BOX_H / 2.0)
	_positions.append(y)
	for r in range(1, _rounds.size()):
		var prev: Array = _positions[r - 1]
		var cur := []
		for i in range((_rounds[r] as Array).size()):
			cur.append((float(prev[2 * i]) + float(prev[2 * i + 1])) * 0.5)
		_positions.append(cur)


func _round_x(r: int) -> float:
	return MARGIN + r * (BOX_W + ROUND_GAP)


func _draw() -> void:
	if _rounds.is_empty():
		return

	var line_color := Color(1, 1, 1, 0.22)
	for r in range(1, _rounds.size()):
		for i in range((_rounds[r] as Array).size()):
			var x_prev := _round_x(r - 1) + BOX_W
			var x_mid := x_prev + ROUND_GAP * 0.5
			var y_a: float = _positions[r - 1][2 * i]
			var y_b: float = _positions[r - 1][2 * i + 1]
			var y_c: float = _positions[r][i]
			draw_line(Vector2(x_prev, y_a), Vector2(x_mid, y_a), line_color, 2.0)
			draw_line(Vector2(x_prev, y_b), Vector2(x_mid, y_b), line_color, 2.0)
			draw_line(Vector2(x_mid, y_a), Vector2(x_mid, y_b), line_color, 2.0)
			draw_line(Vector2(x_mid, y_c), Vector2(_round_x(r), y_c), line_color, 2.0)

	for r in range(_rounds.size()):
		for i in range((_rounds[r] as Array).size()):
			_draw_slot_box(r, i)


func _draw_slot_box(r: int, i: int) -> void:
	var slot: Dictionary = _rounds[r][i]
	var x := _round_x(r)
	var y := float(_positions[r][i]) - BOX_H / 2.0
	var acc_a := int(slot.get("account_id_a", 0))
	var acc_b := int(slot.get("account_id_b", 0))
	var is_bot_a := bool(slot.get("is_bot_a", false))
	var is_bot_b := bool(slot.get("is_bot_b", false))
	var is_my_slot := (acc_a == _my_id and not is_bot_a) or (acc_b == _my_id and not is_bot_b)

	draw_rect(Rect2(x, y, BOX_W, BOX_H), Color(0.08, 0.08, 0.11, 0.95), true)
	draw_rect(Rect2(x, y, BOX_W, BOX_H), Color(1.0, 0.86, 0.4, 0.85) if is_my_slot else Color(1, 1, 1, 0.14), false, 2.0 if is_my_slot else 1.0)
	draw_line(Vector2(x, y + ROW_H), Vector2(x + BOX_W, y + ROW_H), Color(1, 1, 1, 0.1), 1.0)


func _build_slot_rows(r: int, i: int) -> void:
	var slot: Dictionary = _rounds[r][i]
	var x := _round_x(r)
	var y := float(_positions[r][i]) - BOX_H / 2.0

	var acc_a := int(slot.get("account_id_a", 0))
	var acc_b := int(slot.get("account_id_b", 0))
	var is_bot_a := bool(slot.get("is_bot_a", false))
	var is_bot_b := bool(slot.get("is_bot_b", false))
	var resolved := bool(slot.get("resolved", false))
	var winner_acc := int(slot.get("winner_account_id", 0))
	var winner_is_bot := bool(slot.get("winner_is_bot", false))
	# Bot-vs-bot resolutions don't track which bot "won" (both sides are the
	# same undifferentiated bot placeholder) — skip winner highlighting there
	# rather than lighting up both sides green.
	var is_bot_vs_bot := is_bot_a and is_bot_b
	var is_a_winner := resolved and not is_bot_vs_bot and (winner_is_bot == is_bot_a) and (winner_is_bot or winner_acc == acc_a)
	var is_b_winner := resolved and not is_bot_vs_bot and (winner_is_bot == is_bot_b) and (winner_is_bot or winner_acc == acc_b)

	var score_a := int(slot.get("score_a", 0))
	var score_b := int(slot.get("score_b", 0))

	var row_size := Vector2(BOX_W - ROW_PAD * 2.0, ROW_H - ROW_PAD * 2.0)

	var row_a := _make_player_row(acc_a, is_bot_a, hash("%d_%d_a" % [r, i]), _row_color(is_a_winner, resolved), score_a if resolved else -1)
	add_child(row_a)
	row_a.position = Vector2(x + ROW_PAD, y + ROW_PAD)
	row_a.size = row_size
	_row_nodes.append(row_a)
	_row_targets.append({"node": row_a, "size": row_size})

	var row_b := _make_player_row(acc_b, is_bot_b, hash("%d_%d_b" % [r, i]), _row_color(is_b_winner, resolved), score_b if resolved else -1)
	add_child(row_b)
	row_b.position = Vector2(x + ROW_PAD, y + ROW_H + ROW_PAD)
	row_b.size = row_size
	_row_nodes.append(row_b)
	_row_targets.append({"node": row_b, "size": row_size})


func _row_color(is_winner: bool, resolved: bool) -> Color:
	if is_winner:
		return Color(0.45, 0.9, 0.5)
	if resolved:
		return Color(0.55, 0.55, 0.55)
	return Color(0.9, 0.9, 0.9)


## Builds one player row: avatar (bg+avatar+frame composite) on the left,
## name (top) and Elo (bottom) to its right. `score` is -1 to hide it
## (unresolved match).
func _make_player_row(account_id: int, is_bot: bool, seed_val: int, name_color: Color, score: int) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)

	var avatar_id := Avatars.DEFAULT_ID
	var frame_id := Frames.NONE_ID
	var background_id := Backgrounds.NONE_ID
	var display_name := "Player"
	var elo_text := ""

	if is_bot or account_id == 0:
		var ids := _bot_identity(seed_val)
		avatar_id = ids.avatar
		frame_id = ids.frame
		background_id = ids.background
		display_name = "Bot"
	else:
		for p in _participants:
			if int(p.get("account_id", -1)) == account_id:
				avatar_id = str(p.get("avatar", Avatars.DEFAULT_ID))
				frame_id = str(p.get("frame", Frames.NONE_ID))
				background_id = str(p.get("background", Backgrounds.NONE_ID))
				display_name = str(p.get("display_name", "Player"))
				elo_text = "Elo %d" % int(p.get("elo", 0))
				break

	var avatar_tile := _make_avatar_tile(avatar_id, frame_id, background_id)
	# Without these, HBoxContainer stretches the tile to the row's full
	# height by default (only custom_minimum_size was set) — SHRINK_CENTER
	# pins it to exactly its minimum size, centered, so it stays square.
	avatar_tile.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	avatar_tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(avatar_tile)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vbox.add_theme_constant_override("separation", 0)

	var name_label := Label.new()
	name_label.text = "%s%s" % [display_name, ("  %d" % score) if score >= 0 else ""]
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.add_theme_color_override("font_color", name_color)
	name_label.clip_text = true
	vbox.add_child(name_label)

	var elo_label := Label.new()
	elo_label.text = elo_text
	elo_label.add_theme_font_size_override("font_size", 10)
	elo_label.add_theme_color_override("font_color", Color(name_color, 0.75))
	vbox.add_child(elo_label)

	row.add_child(vbox)
	return row


func _make_avatar_tile(avatar_id: String, frame_id: String, background_id: String) -> Control:
	var box := Control.new()
	box.custom_minimum_size = Vector2(AVATAR_SIZE, AVATAR_SIZE)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bg_tex := Backgrounds.texture_for(background_id)
	if bg_tex != null:
		box.add_child(_make_layer_texture(bg_tex, null))

	box.add_child(_make_layer_texture(Avatars.texture_for(avatar_id), null))

	var frame_tex := Frames.texture_for(frame_id)
	if frame_tex != null:
		var mat := ShaderMaterial.new()
		mat.shader = FRAME_SHADER
		box.add_child(_make_layer_texture(frame_tex, mat))

	return box


func _make_layer_texture(tex: Texture2D, mat: ShaderMaterial) -> TextureRect:
	var t := TextureRect.new()
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if mat != null:
		t.material = mat
	return t


## Bots have no real account. Each bot SLOT gets a seeded (not re-rolled every
## redraw) portrait from the bot-only pool, plus the shared fixed bot frame +
## background — same identity bots wear everywhere else (see Avatars.bot_identity).
func _bot_identity(seed_val: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	var avatar_ids := Avatars.bot_pool()
	var avatar_id: String = avatar_ids[rng.randi() % avatar_ids.size()] if not avatar_ids.is_empty() else Avatars.BOT_ID

	return {"avatar": avatar_id, "frame": Avatars.BOT_FRAME, "background": Avatars.BOT_BACKGROUND}
