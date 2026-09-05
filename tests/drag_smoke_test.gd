extends Node
## Headless drag-and-drop smoke test: injects REAL InputEventMouseButton/
## InputEventMouseMotion events (via Viewport.push_input) to exercise the
## actual _get_drag_data/_can_drop_data/_drop_data machinery, instead of
## calling Net.submit_* directly like tests/solo_smoke_test.gd does. That
## driver never touches CardView's drag code at all — this one specifically
## targets it, since a regression there wouldn't show up in the other tests.
##
## Not part of the shipped game — dev/verification tool only.

func _ready() -> void:
	Net.player_assigned.connect(func(_pid): print("[drag-test] assigned player_id"))
	Net.error_received.connect(func(msg): print("[drag-test] ERROR: ", msg))
	Net.state_updated.connect(_on_state_updated)


var _tried := false


func _on_state_updated(state: Dictionary) -> void:
	if _tried:
		return
	if state.phase != "awaiting_category" or state.active_player != Net.my_player_id:
		return
	if state.offered_categories.is_empty() or state.own_hand.is_empty():
		return
	_tried = true
	# _render_hand() has its own internal `await get_tree().process_frame`
	# before it actually creates the card nodes (see game_ui.gd), so a couple
	# of frames isn't a reliable margin — wait a full second to be certain
	# everything's settled before hunting for nodes to click on.
	await get_tree().create_timer(1.0).timeout
	await _run_drag_test()


func _run_drag_test() -> void:
	var ui := get_tree().get_first_node_in_group("game_ui_root")
	if ui == null:
		# Fallback: search the tree for a node with a _hand_box property.
		ui = _find_game_ui(get_tree().root)
	if ui == null:
		print("[drag-test] FAIL: could not find GameUI node")
		get_tree().quit(1)
		return

	var hand_box: Control = ui.get("_hand_box")
	var category_box: Control = ui.get("_category_box")
	if hand_box == null or category_box == null:
		print("[drag-test] FAIL: GameUI missing _hand_box/_category_box")
		get_tree().quit(1)
		return

	var card_view: Control = null
	for child in hand_box.get_children():
		if child.has_method("set_card"):
			card_view = child
			break
	var category_view: Control = null
	for child in category_box.get_children():
		if child.has_method("set_category"):
			category_view = child
			break

	if card_view == null or category_view == null:
		print("[drag-test] FAIL: no draggable card or category view found (card=%s category=%s)" % [card_view, category_view])
		get_tree().quit(1)
		return

	print("[drag-test] found card at %s, category at %s" % [card_view.global_position, category_view.global_position])

	# NOT card_view.global_position + size*scale*0.5 — CardView's pivot is
	# bottom-center at NATIVE (unscaled) size, so global_position (the
	# transformed location of local (0,0)) doesn't correspond to any simple
	# corner/center offset once scale is involved. get_global_transform()
	# lets Godot do that math instead of re-deriving it by hand.
	var from: Vector2 = card_view.get_global_transform() * (card_view.size * 0.5)
	var to: Vector2 = category_view.get_global_transform() * (category_view.size * 0.5)
	print("[drag-test] simulating drag from %s to %s" % [from, to])

	await _simulate_drag(from, to)

	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0)


func _find_game_ui(node: Node) -> Node:
	if node.get_script() != null and (node as Object).has_method("_render_table"):
		return node
	for child in node.get_children():
		var found := _find_game_ui(child)
		if found:
			return found
	return null


func _find_drag_preview(node: Node) -> CardDragPreview:
	if node is CardDragPreview:
		return node
	for child in node.get_children():
		var found := _find_drag_preview(child)
		if found:
			return found
	return null


func _simulate_drag(from: Vector2, to: Vector2) -> void:
	var vp := get_viewport()

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = from
	down.global_position = from
	vp.push_input(down)
	await get_tree().process_frame
	print("[drag-test] after mouse down: gui_is_dragging=%s" % vp.gui_is_dragging())

	var steps := 8
	for i in range(1, steps + 1):
		var t := float(i) / steps
		var pos: Vector2 = from.lerp(to, t)
		var motion := InputEventMouseMotion.new()
		motion.position = pos
		motion.global_position = pos
		motion.relative = Vector2(4, 4)
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT  # Godot needs this to recognize "button held while moving"
		vp.push_input(motion)
		await get_tree().process_frame

	print("[drag-test] after motion to target: gui_is_dragging=%s" % vp.gui_is_dragging())

	var preview := _find_drag_preview(get_tree().root)
	if preview:
		print("[drag-test] preview visual size=%s pos=%s" % [preview._visual.size, preview._visual.position])
		print("[drag-test] preview art size=%s pos=%s texture_native=%s" % [
			preview._art.size, preview._art.position,
			preview._art.texture.get_size() if preview._art.texture else "null"
		])
		print("[drag-test] preview name_label text=%s size=%s pos=%s | director_label text=%s size=%s pos=%s" % [
			preview._name_label.text, preview._name_label.size, preview._name_label.position,
			preview._director_label.text, preview._director_label.size, preview._director_label.position
		])
	else:
		print("[drag-test] no CardDragPreview node found in tree")

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = to
	up.global_position = to
	vp.push_input(up)
	await get_tree().process_frame

	print("[drag-test] after mouse up: gui_is_dragging=%s" % vp.gui_is_dragging())
