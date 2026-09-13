extends Control
## Modal avatar/frame/background/table/title grid. Click a tile to highlight
## it, then press Save to confirm — `chosen(id)` / `frame_chosen(id)` /
## `background_chosen(id)` / `table_background_chosen(id)` / `title_chosen(id)`
## are emitted only on Save, never on the first click.
##
## Picks on every tab are remembered while the modal is open, and Save commits
## all of them at once (one signal per tab that was actually touched) — you
## can flip between Avatar/Frame/Background/etc, change several, and confirm
## with a single press instead of saving one tab at a time.
##
## Dismissable mode (default): shows the category tabs, and frees itself right
## after a Save — or on Cancel / ui_cancel (no signal).
## Mandatory mode (`configure(false)`): no category tabs (avatar only, since
## this is the first-login onboarding prompt), no Cancel button, ui_cancel is
## ignored, and it stays up after `chosen` until the caller calls `close()` —
## used for the first-login onboarding prompt, which must not be escaped.

signal chosen(id: String)
signal frame_chosen(id: String)
signal background_chosen(id: String)
signal sleeve_chosen(id: String)
signal table_background_chosen(id: String)
signal title_chosen(id: String)

const TILE := Vector2(84, 84)

## Per-category art size, matched to each cosmetic's natural aspect ratio
## (avatars/frames/backgrounds are square; card backs are card-shaped;
## tables are widescreen). Falls back to TILE for anything not listed.
const TILE_SIZE := {
	"avatar": Vector2(84, 84),
	"frame": Vector2(84, 84),
	"background": Vector2(84, 84),
	"sleeve": Vector2(76, 106),
	"table_background": Vector2(160, 92),
	"title": Vector2(140, 64),
}

## Grid columns per category — wider tiles (table/title) need fewer columns
## to stay inside the modal's fixed width.
const GRID_COLUMNS := {
	"table_background": 3,
	"title": 3,
}

## Height reserved below the art for the item's name label (art tiles only —
## the "None" tile and Title options already show their own label as the
## button text and don't get a second one).
const NAME_BAND := 16

const ACCENT := Color(0.38, 0.68, 1.0)
const HEART_SIZE := Vector2(24, 24)
const FAVORITE_COLOR := Color(0.3, 0.9, 0.45)
const NOT_FAVORITE_COLOR := Color(1, 1, 1, 0.35)
const CAT_AVATAR := "avatar"
const CAT_FRAME := "frame"
const CAT_BACKGROUND := "background"
const CAT_SLEEVE := "sleeve"
const CAT_TABLE := "table_background"
const CAT_TITLE := "title"
const NONE_TILE := "__none__"

const CATEGORY_HEADING := {
	CAT_AVATAR: "Choose your avatar",
	CAT_FRAME: "Choose a frame",
	CAT_BACKGROUND: "Choose a background",
	CAT_SLEEVE: "Choose a card back",
	CAT_TABLE: "Choose a table",
	CAT_TITLE: "Choose a title",
}

var _dismissable := true
var _category := CAT_AVATAR
var _selected_avatar_id := ""

# Frame/Background/Sleeve/Table/Title all allow "" as a real choice ("no
# frame"/"no background"/etc, or "auto elo tier" for Title), so a plain string
# can't distinguish "nothing picked yet" from "explicitly picked none" —
# hence the separate _touched flags, keyed by category.
var _selected := {CAT_FRAME: "", CAT_BACKGROUND: "", CAT_SLEEVE: "", CAT_TABLE: "", CAT_TITLE: ""}
var _touched := {CAT_FRAME: false, CAT_BACKGROUND: false, CAT_SLEEVE: false, CAT_TABLE: false, CAT_TITLE: false}

var _tiles := {}  # id (or NONE_TILE) -> the tile's Panel background, for the active category

@onready var _grid: GridContainer = %Grid
@onready var _cancel: Button = %CancelButton
@onready var _select: Button = %SelectButton
@onready var _avatar_tab: Button = %AvatarTabButton
@onready var _frame_tab: Button = %FrameTabButton
@onready var _background_tab: Button = %BackgroundTabButton
@onready var _sleeve_tab: Button = %SleeveTabButton
@onready var _table_tab: Button = %TableTabButton
@onready var _title_tab: Button = %TitleTabButton
@onready var _tabs: Control = %CategoryTabs
@onready var _title: Label = $Panel/MarginContainer/Box/Title


## Call before adding to the tree. `false` => mandatory onboarding mode.
func configure(dismissable: bool) -> void:
	_dismissable = dismissable


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	_tabs.visible = _dismissable
	_avatar_tab.pressed.connect(_switch_category.bind(CAT_AVATAR))
	_frame_tab.pressed.connect(_switch_category.bind(CAT_FRAME))
	_background_tab.pressed.connect(_switch_category.bind(CAT_BACKGROUND))
	_sleeve_tab.pressed.connect(_switch_category.bind(CAT_SLEEVE))
	_table_tab.pressed.connect(_switch_category.bind(CAT_TABLE))
	_title_tab.pressed.connect(_switch_category.bind(CAT_TITLE))

	_cancel.visible = _dismissable
	_cancel.pressed.connect(_close)

	_select.disabled = true
	_select.pressed.connect(_on_select_pressed)

	# Keeps the heart colours honest if a favorite toggle round-trips while
	# this tab is up (the click itself already flips it optimistically).
	Net.favorite_tables_updated.connect(_on_favorite_tables_updated)

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
	_sleeve_tab.button_pressed = _category == CAT_SLEEVE
	_table_tab.button_pressed = _category == CAT_TABLE
	_title_tab.button_pressed = _category == CAT_TITLE
	_title.text = str(CATEGORY_HEADING.get(_category, "Choose your avatar"))


func _list_ids(cat: String) -> Array:
	if cat == CAT_FRAME:
		return Frames.list_ids()
	if cat == CAT_SLEEVE:
		return Sleeves.list_ids()
	if cat == CAT_TABLE:
		return TableBackgrounds.list_ids()
	return Backgrounds.list_ids()


## Every title id this player may currently pick: "" (their live elo tier)
## plus every title-type reward they own — see TitleSystem.available_titles.
func _title_options() -> Array:
	var elo := int(Session.account.get("elo", 0))
	var owned: Array = Session.account.get("owned_rewards", [])
	return TitleSystem.available_titles(elo, owned)


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
	if cat == CAT_SLEEVE:
		return Sleeves.texture_for(id)
	if cat == CAT_TABLE:
		return TableBackgrounds.texture_for(id)
	return Backgrounds.texture_for(id)


## Whether Save has anything to commit across ANY tab, not just the active
## one — Save is a single "commit everything I changed" action, not "commit
## the tab I'm looking at".
func _any_pending() -> bool:
	if _selected_avatar_id != "":
		return true
	for touched: bool in _touched.values():
		if touched:
			return true
	return false


## (Re)populates the grid for the active category and restores the Save
## button's enabled state to reflect every tab's pending picks, not just this
## one (see _any_pending).
func _build_grid() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.free()
	_tiles.clear()

	_grid.columns = int(GRID_COLUMNS.get(_category, 4))

	if _category == CAT_AVATAR:
		for id: String in _available(Avatars.list_ids()):
			_add_tile(id, Avatars.texture_for(id), ShopCatalog.display_name_for(id, CAT_AVATAR))
		if _tiles.has(_selected_avatar_id):
			_tiles[_selected_avatar_id].add_theme_stylebox_override("panel", _frame_style(true))
	else:
		# Table is mandatory (no "none" choice); Title's "" entry is itself a
		# real, labelled option ("my current elo tier"), not a blank slot — so
		# neither one gets the generic NONE_TILE placeholder.
		if _category != CAT_TABLE and _category != CAT_TITLE:
			_add_tile(NONE_TILE, null)
		if _category == CAT_TITLE:
			for opt: Dictionary in _title_options():
				var id := str(opt.id)
				_add_tile(id if id != "" else NONE_TILE, null, str(opt.name))
		elif _category == CAT_TABLE:
			_add_tile(TableBackgrounds.RANDOM_ID, null, "🎲 Random Table")
			_add_tile(TableBackgrounds.RANDOM_FAVORITE_ID, null, "💚 Random Favorite")
			for id: String in _available(_list_ids(CAT_TABLE)):
				_add_tile(id, _texture_for(CAT_TABLE, id), ShopCatalog.display_name_for(id, CAT_TABLE), true)
		else:
			for id: String in _available(_list_ids(_category)):
				_add_tile(id, _texture_for(_category, id), ShopCatalog.display_name_for(id, _category))
		var touched: bool = _touched[_category]
		var sel: String = _selected[_category]
		var key: String = sel if sel != "" else NONE_TILE
		if touched and _tiles.has(key):
			_tiles[key].add_theme_stylebox_override("panel", _frame_style(true))

	_select.disabled = not _any_pending()


## `label_text` means different things depending on `tex`:
## - `tex == null`: it's the button's own text (defaults to "None" — the
##   frame/background/sleeve "no cosmetic" tile — but callers with an actual
##   textless option to show, e.g. a Title's name, pass it explicitly).
## - `tex != null`: it's the item's display name, shown in a name band below
##   the art so players can tell "frame1" from "Champion" at a glance.
## `show_heart` adds a favorite-toggle button in the top-right corner (Table
## tiles only, for narrowing the "Random Favorite Table" pool) — the tile is
## built from a plain Control rather than a PanelContainer so the heart can
## sit anchored in a corner instead of being stretched to fill like a
## PanelContainer forces on every child.
func _add_tile(id: String, tex: Texture2D, label_text := "", show_heart := false) -> void:
	var art_size: Vector2 = TILE_SIZE.get(_category, TILE)
	var has_name_band := tex != null
	var frame := Control.new()
	frame.custom_minimum_size = Vector2(art_size.x, art_size.y + (NAME_BAND if has_name_band else 0))

	# Built now but added to the tree last (see bottom of this function) so its
	# border/fill draws on top of the art/button instead of being hidden
	# underneath it — mouse_filter IGNORE means it still doesn't block clicks
	# on whatever is stacked below it.
	var bg := Panel.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_theme_stylebox_override("panel", _frame_style(false))

	if tex != null:
		var btn := TextureButton.new()
		btn.texture_normal = tex
		btn.ignore_texture_size = true
		btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
		btn.anchor_right = 1.0
		btn.offset_bottom = art_size.y
		frame.add_child(btn)
		btn.pressed.connect(_on_tile_pressed.bind(id))

		var name_label := Label.new()
		name_label.text = label_text
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", 10)
		name_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
		name_label.anchor_top = 0.0
		name_label.anchor_right = 1.0
		name_label.anchor_bottom = 0.0
		name_label.offset_top = art_size.y
		name_label.offset_bottom = art_size.y + NAME_BAND
		frame.add_child(name_label)
	else:
		var btn := Button.new()
		btn.text = label_text if label_text != "" else "None"
		btn.flat = true
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		frame.add_child(btn)
		btn.pressed.connect(_on_tile_pressed.bind(id))

	if show_heart:
		_add_heart_button(frame, id)

	frame.add_child(bg)
	_grid.add_child(frame)
	_tiles[id] = bg


func _is_favorite_table(id: String) -> bool:
	return id in (Session.account.get("favorite_tables", []) as Array)


func _add_heart_button(frame: Control, id: String) -> void:
	var heart := Button.new()
	heart.flat = true
	heart.text = "♥"
	heart.custom_minimum_size = HEART_SIZE
	heart.anchor_left = 1.0
	heart.anchor_right = 1.0
	heart.offset_left = -HEART_SIZE.x - 2.0
	heart.offset_right = -2.0
	heart.offset_top = 2.0
	heart.offset_bottom = 2.0 + HEART_SIZE.y
	heart.add_theme_font_size_override("font_size", 16)
	heart.add_theme_color_override("font_color", FAVORITE_COLOR if _is_favorite_table(id) else NOT_FAVORITE_COLOR)
	heart.add_theme_color_override("font_hover_color", FAVORITE_COLOR if _is_favorite_table(id) else Color(1, 1, 1, 0.7))
	heart.tooltip_text = "Favorite (used by Random Favorite Table)"
	heart.pressed.connect(_on_heart_pressed.bind(id, heart))
	frame.add_child(heart)


## Toggles favorite status optimistically (instant visual feedback) and fires
## the RPC; _on_favorite_tables_updated reconciles from the server's reply.
func _on_heart_pressed(id: String, heart: Button) -> void:
	Net.toggle_favorite_table(id)
	var favs: Array = (Session.account.get("favorite_tables", []) as Array).duplicate()
	if id in favs:
		favs.erase(id)
	else:
		favs.append(id)
	Session.account["favorite_tables"] = favs
	var is_fav: bool = id in favs
	heart.add_theme_color_override("font_color", FAVORITE_COLOR if is_fav else NOT_FAVORITE_COLOR)
	heart.add_theme_color_override("font_hover_color", FAVORITE_COLOR if is_fav else Color(1, 1, 1, 0.7))


func _on_favorite_tables_updated(account: Dictionary) -> void:
	Session.set_account(account)
	if _category == CAT_TABLE:
		_build_grid()


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


## Commits every tab's pending pick at once — not just whichever tab is
## currently active — so switching tabs before pressing Save never loses an
## earlier pick on another tab.
func _on_select_pressed() -> void:
	if _selected_avatar_id != "":
		chosen.emit(_selected_avatar_id)
	if _touched[CAT_FRAME]:
		frame_chosen.emit(_selected[CAT_FRAME])
	if _touched[CAT_BACKGROUND]:
		background_chosen.emit(_selected[CAT_BACKGROUND])
	if _touched[CAT_SLEEVE]:
		sleeve_chosen.emit(_selected[CAT_SLEEVE])
	if _touched[CAT_TABLE]:
		table_background_chosen.emit(_selected[CAT_TABLE])
	if _touched[CAT_TITLE]:
		title_chosen.emit(_selected[CAT_TITLE])

	if _dismissable:
		_close()


## Border width and content margin are constant so selecting a tile never
## reflows the grid — only the colours change. Rest state is now a faint
## visible card (not fully transparent) so tiles read as distinct slots
## instead of bare art floating on the modal background.
func _frame_style(selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.set_corner_radius_all(8)
	s.set_content_margin_all(4)
	s.set_border_width_all(2)
	if selected:
		s.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.18)
		s.border_color = ACCENT
	else:
		s.bg_color = Color(1, 1, 1, 0.06)
		s.border_color = Color(1, 1, 1, 0.14)
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
