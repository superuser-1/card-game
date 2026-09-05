extends Control
## Modal avatar/frame/background grid. Click a tile to highlight it, then
## press Select to confirm — `chosen(id)` / `frame_chosen(id)` /
## `background_chosen(id)` are emitted only on Select, never on the first
## click.
##
## Dismissable mode (default): shows the Avatars/Frames/Backgrounds category
## tabs, and frees itself right after a Select — or on Cancel / ui_cancel (no
## signal). Select commits whichever tab is currently active.
## Mandatory mode (`configure(false)`): no category tabs (avatar only, since
## this is the first-login onboarding prompt), no Cancel button, ui_cancel is
## ignored, and it stays up after `chosen` until the caller calls `close()` —
## used for the first-login onboarding prompt, which must not be escaped.

signal chosen(id: String)
signal frame_chosen(id: String)
signal background_chosen(id: String)

const TILE := Vector2(92, 92)
const ACCENT := Color(0.38, 0.68, 1.0)
const CAT_AVATAR := "avatar"
const CAT_FRAME := "frame"
const CAT_BACKGROUND := "background"
const NONE_TILE := "__none__"

var _dismissable := true
var _category := CAT_AVATAR
var _selected_avatar_id := ""

# Frame/Background both allow "" (none) as a real choice, so a plain string
# can't distinguish "nothing picked yet" from "explicitly picked none" —
# hence the separate _touched flags, keyed by category.
var _selected := {CAT_FRAME: "", CAT_BACKGROUND: ""}
var _touched := {CAT_FRAME: false, CAT_BACKGROUND: false}

var _tiles := {}  # id (or NONE_TILE) -> PanelContainer frame, for the active category

@onready var _grid: GridContainer = %Grid
@onready var _cancel: Button = %CancelButton
@onready var _select: Button = %SelectButton
@onready var _avatar_tab: Button = %AvatarTabButton
@onready var _frame_tab: Button = %FrameTabButton
@onready var _background_tab: Button = %BackgroundTabButton
@onready var _tabs: Control = %CategoryTabs


## Call before adding to the tree. `false` => mandatory onboarding mode.
func configure(dismissable: bool) -> void:
	_dismissable = dismissable


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	_tabs.visible = _dismissable
	_avatar_tab.pressed.connect(_switch_category.bind(CAT_AVATAR))
	_frame_tab.pressed.connect(_switch_category.bind(CAT_FRAME))
	_background_tab.pressed.connect(_switch_category.bind(CAT_BACKGROUND))

	_cancel.visible = _dismissable
	_cancel.pressed.connect(_close)

	_select.disabled = true
	_select.pressed.connect(_on_select_pressed)

	_build_grid()
	_update_tab_styles()


func _switch_category(cat: String) -> void:
	if cat == _category:
		return
	_category = cat
	_build_grid()
	_update_tab_styles()


func _update_tab_styles() -> void:
	_avatar_tab.button_pressed = _category == CAT_AVATAR
	_frame_tab.button_pressed = _category == CAT_FRAME
	_background_tab.button_pressed = _category == CAT_BACKGROUND


func _list_ids(cat: String) -> Array:
	if cat == CAT_FRAME:
		return Frames.list_ids()
	return Backgrounds.list_ids()


## Only the cosmetics this player may actually equip: free (non-catalog) items,
## plus premium items they own — bought in the shop or granted by an unlock.
## Everything still for sale is hidden here (it lives in the shop instead).
func _is_available(id: String) -> bool:
	if not ShopCatalog.is_premium(id):
		return true
	return id in (Session.account.get("owned_rewards", []) as Array)


func _available(ids: Array) -> Array:
	return ids.filter(_is_available)


func _texture_for(cat: String, id: String) -> Texture2D:
	if cat == CAT_FRAME:
		return Frames.texture_for(id)
	return Backgrounds.texture_for(id)


## (Re)populates the grid for the active category and restores the Select
## button's enabled state to match whatever was already picked on that tab.
func _build_grid() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.free()
	_tiles.clear()

	if _category == CAT_AVATAR:
		for id: String in _available(Avatars.list_ids()):
			_add_tile(id, Avatars.texture_for(id))
		_select.disabled = _selected_avatar_id == ""
		if _tiles.has(_selected_avatar_id):
			_tiles[_selected_avatar_id].add_theme_stylebox_override("panel", _frame_style(true))
	else:
		_add_tile(NONE_TILE, null)
		for id: String in _available(_list_ids(_category)):
			_add_tile(id, _texture_for(_category, id))
		var touched: bool = _touched[_category]
		_select.disabled = not touched
		var sel: String = _selected[_category]
		var key: String = sel if sel != "" else NONE_TILE
		if touched and _tiles.has(key):
			_tiles[key].add_theme_stylebox_override("panel", _frame_style(true))


func _add_tile(id: String, tex: Texture2D) -> void:
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", _frame_style(false))

	if tex != null:
		var btn := TextureButton.new()
		btn.texture_normal = tex
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		btn.custom_minimum_size = TILE
		frame.add_child(btn)
		btn.pressed.connect(_on_tile_pressed.bind(id))
	else:
		var btn := Button.new()
		btn.text = "None"
		btn.custom_minimum_size = TILE
		btn.flat = true
		frame.add_child(btn)
		btn.pressed.connect(_on_tile_pressed.bind(id))

	_grid.add_child(frame)
	_tiles[id] = frame


func _on_tile_pressed(id: String) -> void:
	if _category == CAT_AVATAR:
		if id == _selected_avatar_id:
			return
		if _tiles.has(_selected_avatar_id):
			_tiles[_selected_avatar_id].add_theme_stylebox_override("panel", _frame_style(false))
		_selected_avatar_id = id
		_tiles[id].add_theme_stylebox_override("panel", _frame_style(true))
	else:
		var new_id := "" if id == NONE_TILE else id
		var prev_sel: String = _selected[_category]
		var prev_key: String = prev_sel if prev_sel != "" else NONE_TILE
		if _touched[_category] and id == prev_key:
			return
		if _tiles.has(prev_key):
			_tiles[prev_key].add_theme_stylebox_override("panel", _frame_style(false))
		_selected[_category] = new_id
		_touched[_category] = true
		_tiles[id].add_theme_stylebox_override("panel", _frame_style(true))

	_select.disabled = false


func _on_select_pressed() -> void:
	if _category == CAT_AVATAR:
		if _selected_avatar_id == "":
			return
		chosen.emit(_selected_avatar_id)
	elif _category == CAT_FRAME:
		if not _touched[CAT_FRAME]:
			return
		frame_chosen.emit(_selected[CAT_FRAME])
	else:
		if not _touched[CAT_BACKGROUND]:
			return
		background_chosen.emit(_selected[CAT_BACKGROUND])

	if _dismissable:
		_close()


## Border width and content margin are constant so selecting a tile never
## reflows the grid — only the colours change.
func _frame_style(selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.set_corner_radius_all(6)
	s.set_content_margin_all(4)
	s.set_border_width_all(3)
	if selected:
		s.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.15)
		s.border_color = ACCENT
	else:
		s.bg_color = Color(0, 0, 0, 0)
		s.border_color = Color(0, 0, 0, 0)
	return s


## Free the modal. Public so a mandatory-mode caller can dismiss it once the
## pick has been confirmed (e.g. saved on the server).
func close() -> void:
	_close()


func _close() -> void:
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if _dismissable and event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
