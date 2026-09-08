extends Control
## Cube builder. A "cube" is a player-curated movie catalogue (MTG term) used as
## the card pool for custom games and custom tournaments. Cubes are saved LOCALLY
## (Session.load_cubes / save_cubes); when one is actually chosen for a match the
## server re-validates it from scratch and owns the pool from then on. Legality
## rule: at least CubeRules.MIN_SIZE distinct cards, no upper limit.

const CARD_VIEW_SCENE := preload("res://client/card_view.tscn")
const CARD_DISPLAY_SCALE := 0.62
const MAIN_MENU := "res://client/main_menu.tscn"

@onready var _status: Label = %StatusLabel
@onready var _cube_list: ItemList = %CubeList
@onready var _new_btn: Button = %NewButton
@onready var _rename_btn: Button = %RenameButton
@onready var _delete_btn: Button = %DeleteButton
@onready var _search: LineEdit = %SearchEdit
@onready var _genre_opt: OptionButton = %GenreOption
@onready var _clear_btn: Button = %ClearButton
@onready var _result_count: Label = %ResultCount
@onready var _grid: GridContainer = %CardGrid
@onready var _rename_dialog: AcceptDialog = %RenameDialog
@onready var _rename_edit: LineEdit = %RenameEdit
@onready var _delete_dialog: ConfirmationDialog = %DeleteDialog
@onready var _back: Button = %BackButton

var _all_cards: Array = []
var _wrappers: Dictionary = {}       # card_id -> {"wrapper": Control, "sel": Panel}
var _genre_choices: Array = []        # index-aligned with _genre_opt items after the first
var _cubes: Array = []
var _active_idx: int = -1

const _SEL_BORDER := Color(0.36, 0.78, 0.45, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto(MAIN_MENU)
		get_viewport().set_input_as_handled()


func _ready() -> void:
	_back.pressed.connect(func(): Session.goto(MAIN_MENU))
	_new_btn.pressed.connect(_on_new)
	_rename_btn.pressed.connect(_on_rename)
	_delete_btn.pressed.connect(_on_delete)
	_clear_btn.pressed.connect(_on_clear_filters)
	_search.text_changed.connect(func(_t): _apply_filter())
	_genre_opt.item_selected.connect(func(_i): _apply_filter())
	_cube_list.item_selected.connect(_on_cube_selected)
	_rename_dialog.confirmed.connect(_on_rename_confirmed)
	_delete_dialog.confirmed.connect(_on_delete_confirmed)

	_all_cards = CardLoader.load_cards("res://data/cards.json")
	_build_genre_options()
	_build_grid()

	_cubes = Session.load_cubes()
	_refresh_cube_list()
	if not _cubes.is_empty():
		_select_cube(0)
	else:
		_update_status()
	_apply_filter()

	# The grid (text + layout) is up immediately; stream the ~300 card textures
	# in over the following frames so entering the screen doesn't freeze.
	_hydrate_art()


# --- catalogue ---------------------------------------------------------------

func _build_genre_options() -> void:
	var seen := {}
	for c in _all_cards:
		for g in (c.get("genres", []) as Array):
			seen[str(g)] = true
	_genre_choices = seen.keys()
	_genre_choices.sort()
	_genre_opt.clear()
	_genre_opt.add_item("All genres")
	for g in _genre_choices:
		_genre_opt.add_item(g)


func _build_grid() -> void:
	for c: Dictionary in _all_cards:
		var id := str(c["id"])
		var wrapper := Control.new()
		wrapper.custom_minimum_size = CardView.CARD_SIZE * CARD_DISPLAY_SCALE

		var view: CardView = CARD_VIEW_SCENE.instantiate()
		wrapper.add_child(view)
		# Wrapper must be in the tree before set_card()/use_as_static_thumbnail()
		# so the CardView's _ready() has run (resolved @onready refs, set its
		# default pivot — which use_as_static_thumbnail then overrides).
		_grid.add_child(wrapper)
		view.use_as_static_thumbnail(CARD_DISPLAY_SCALE)
		view.set_card(c, false)   # text now; art streamed in by _hydrate_art()
		view.pressed.connect(_on_card_pressed.bind(id))

		# Selection outline drawn on top; ignores the mouse so the card still
		# gets the click.
		var sel := Panel.new()
		sel.set_anchors_preset(Control.PRESET_FULL_RECT)
		sel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sel.visible = false
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.36, 0.78, 0.45, 0.14)
		sb.set_border_width_all(3)
		sb.border_color = _SEL_BORDER
		sb.set_corner_radius_all(8)
		sel.add_theme_stylebox_override("panel", sb)
		wrapper.add_child(sel)

		var tick := Label.new()
		tick.text = "✓"
		tick.add_theme_color_override("font_color", Color(1, 1, 1, 1))
		tick.add_theme_font_size_override("font_size", 22)
		tick.position = Vector2(6, 2)
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tick.visible = false
		wrapper.add_child(tick)

		_wrappers[id] = {"wrapper": wrapper, "view": view, "sel": sel, "tick": tick}


func _hydrate_art() -> void:
	const PER_FRAME := 12
	var n := 0
	for id in _wrappers:
		_wrappers[id]["view"].apply_art()
		n += 1
		if n % PER_FRAME == 0:
			await get_tree().process_frame
			if not is_inside_tree():
				return


func _apply_filter() -> void:
	var needle := _search.text.strip_edges().to_lower()
	var gi := _genre_opt.selected
	var genre := "" if gi <= 0 else str(_genre_choices[gi - 1])
	var shown := 0
	for c: Dictionary in _all_cards:
		var ok := true
		if needle != "" and not str(c["title"]).to_lower().contains(needle):
			ok = false
		if ok and genre != "" and genre not in (c.get("genres", []) as Array):
			ok = false
		_wrappers[str(c["id"])]["wrapper"].visible = ok
		if ok:
			shown += 1
	_result_count.text = "showing %d of %d" % [shown, _all_cards.size()]


func _on_clear_filters() -> void:
	_search.text = ""
	_genre_opt.select(0)
	_apply_filter()


# --- cube membership -------------------------------------------------------

func _active_cube() -> Dictionary:
	return _cubes[_active_idx] if _active_idx >= 0 and _active_idx < _cubes.size() else {}


func _on_card_pressed(card_id: String) -> void:
	var cube := _active_cube()
	if cube.is_empty():
		_toast("Create or pick a cube first")
		return
	var ids: Array = cube["card_ids"]
	if card_id in ids:
		ids.erase(card_id)
	else:
		ids.append(card_id)
	Session.save_cubes(_cubes)
	_refresh_badge(card_id)
	_update_status()
	_refresh_cube_list_labels()


func _refresh_badge(card_id: String) -> void:
	var w = _wrappers.get(card_id)
	if w == null:
		return
	var inside: bool = (not _active_cube().is_empty()) and card_id in _active_cube()["card_ids"]
	w["sel"].visible = inside
	w["tick"].visible = inside


func _refresh_all_badges() -> void:
	for id in _wrappers:
		_refresh_badge(id)


# --- cube list -----------------------------------------------------------

func _refresh_cube_list() -> void:
	_cube_list.clear()
	for cube in _cubes:
		_cube_list.add_item(_cube_list_label(cube))
	if _active_idx >= 0 and _active_idx < _cubes.size():
		_cube_list.select(_active_idx)
	_update_buttons()


func _refresh_cube_list_labels() -> void:
	for i in _cubes.size():
		if i < _cube_list.item_count:
			_cube_list.set_item_text(i, _cube_list_label(_cubes[i]))


func _cube_list_label(cube: Dictionary) -> String:
	var n := (cube["card_ids"] as Array).size()
	var mark := "" if n >= CubeRules.MIN_SIZE else "  ⚠"
	return "%s  (%d)%s" % [cube["name"], n, mark]


func _on_cube_selected(idx: int) -> void:
	_select_cube(idx)


func _select_cube(idx: int) -> void:
	_active_idx = idx
	if idx >= 0 and idx < _cube_list.item_count:
		_cube_list.select(idx)
	_refresh_all_badges()
	_update_status()
	_update_buttons()


func _update_buttons() -> void:
	var has := not _active_cube().is_empty()
	_rename_btn.disabled = not has
	_delete_btn.disabled = not has


func _update_status() -> void:
	var cube := _active_cube()
	if cube.is_empty():
		_status.text = "No cube selected"
		_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		return
	var n := (cube["card_ids"] as Array).size()
	if n >= CubeRules.MIN_SIZE:
		_status.text = "%s — %d cards · legal ✓" % [cube["name"], n]
		_status.add_theme_color_override("font_color", _SEL_BORDER)
	else:
		_status.text = "%s — %d / %d  (need %d more)" % [
			cube["name"], n, CubeRules.MIN_SIZE, CubeRules.MIN_SIZE - n
		]
		_status.add_theme_color_override("font_color", Color(0.92, 0.66, 0.30, 1.0))


# --- new / rename / delete ---------------------------------------------------

func _on_new() -> void:
	var cube := {
		"id": Session.new_cube_id(),
		"name": _unique_name("New Cube"),
		"card_ids": [],
	}
	_cubes.append(cube)
	Session.save_cubes(_cubes)
	_refresh_cube_list()
	_select_cube(_cubes.size() - 1)


func _unique_name(base: String) -> String:
	var taken := {}
	for c in _cubes:
		taken[str(c["name"])] = true
	if not taken.has(base):
		return base
	var i := 2
	while taken.has("%s %d" % [base, i]):
		i += 1
	return "%s %d" % [base, i]


func _on_rename() -> void:
	if _active_cube().is_empty():
		return
	_rename_edit.text = str(_active_cube()["name"])
	_rename_dialog.popup_centered(Vector2i(320, 120))
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func _on_rename_confirmed() -> void:
	var new_name := _rename_edit.text.strip_edges()
	if new_name == "":
		return
	_active_cube()["name"] = new_name.substr(0, 40)
	Session.save_cubes(_cubes)
	_refresh_cube_list()
	_update_status()
	_rename_dialog.hide()


func _on_delete() -> void:
	if _active_cube().is_empty():
		return
	_delete_dialog.dialog_text = "Delete cube \"%s\"? This can't be undone." % _active_cube()["name"]
	_delete_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	if _active_idx < 0 or _active_idx >= _cubes.size():
		return
	_cubes.remove_at(_active_idx)
	Session.save_cubes(_cubes)
	if _cubes.is_empty():
		_active_idx = -1
	else:
		_active_idx = clampi(_active_idx, 0, _cubes.size() - 1)
	_refresh_cube_list()
	if _active_idx >= 0:
		_select_cube(_active_idx)
	else:
		_refresh_all_badges()
		_update_status()
		_update_buttons()


# --- toast -----------------------------------------------------------------

func _toast(msg: String) -> void:
	var lbl := Label.new()
	lbl.text = msg
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	box.position = Vector2(size.x * 0.5, size.y - 90)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.07, 0.92)
	sb.border_color = Color(1, 1, 1, 0.15)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", sb)
	box.add_child(lbl)
	add_child(box)
	box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(box, "modulate:a", 1.0, 0.12)
	tw.tween_interval(1.3)
	tw.tween_property(box, "modulate:a", 0.0, 0.35)
	await tw.finished
	box.queue_free()
