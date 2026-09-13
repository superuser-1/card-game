extends Control
## Cosmetics shop. Server is authoritative on price + ownership (see
## ServerStore.purchase / the equip-gate); this screen only renders the
## catalog and fires Net.shop_purchase / Net.set_<type>.

const CARD_W := 190
const ART := 166

## Art box size per item type, matched to each cosmetic's real aspect ratio
## (avatars/frames/backgrounds are square, card backs are card-shaped, table
## backgrounds are widescreen) so the art is shown uncropped instead of
## force-fit into a square. Longest side is capped at ART so cards stay a
## consistent size within a tab (every card in a tab is the same item type,
## so this never has to reconcile two ratios in one grid).
const ART_SIZE := {
	"avatar": Vector2(166, 166),
	"frame": Vector2(166, 166),
	"background": Vector2(166, 166),
	"sleeve": Vector2(114, 166),
	"table_background": Vector2(166, 93),
	"title": Vector2(166, 166),
}

const COL_CARD_BG := Color(0.129, 0.129, 0.176)
const COL_CARD_BORDER := Color(1, 1, 1, 0.075)
const COL_ART_BG := Color(0.09, 0.09, 0.125)
const COL_MUTED := Color(0.56, 0.56, 0.63)
const COL_BUY := Color(0.192, 0.573, 0.353)
const COL_EQUIPPED := Color(0.243, 0.435, 0.678)
const COL_OWNED := Color(0.27, 0.27, 0.33)

## Which ShopCatalog.TYPES index is currently shown.
var _active_tab := 0


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	Net.shop_purchase_result.connect(_on_purchase_result)
	Net.avatar_updated.connect(_on_account_updated)
	Net.frame_updated.connect(_on_account_updated)
	Net.background_updated.connect(_on_account_updated)
	Net.sleeve_updated.connect(_on_account_updated)
	Net.table_background_updated.connect(_on_account_updated)
	Net.title_updated.connect(_on_account_updated)

	_render_tabs()
	_show_tab(0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto("res://client/main_menu.tscn")
		get_viewport().set_input_as_handled()


# --- tabs -----------------------------------------------------------------

## One filter button per item type — TabContainer isn't used because its tabs
## come from child controls, not an add_tab() call.
func _render_tabs() -> void:
	for c in %TypeTabs.get_children():
		c.queue_free()
	var types: Array[String] = ShopCatalog.TYPES
	for i in range(types.size()):
		var btn := Button.new()
		btn.text = "  %s  " % types[i].capitalize()
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_show_tab.bind(i))
		%TypeTabs.add_child(btn)


func _style_tab(btn: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(8)
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.bg_color = COL_EQUIPPED if active else Color(0.16, 0.16, 0.21)
	for s in ["normal", "hover", "pressed", "disabled", "focus"]:
		btn.add_theme_stylebox_override(s, sb)
	btn.add_theme_color_override("font_color", Color.WHITE if active else COL_MUTED)
	btn.add_theme_color_override("font_disabled_color", Color.WHITE if active else COL_MUTED)
	btn.disabled = active  # active tab isn't clickable


func _show_tab(tab_index: int) -> void:
	var types: Array[String] = ShopCatalog.TYPES
	if tab_index < 0 or tab_index >= types.size():
		return
	_active_tab = tab_index

	var tab_buttons := %TypeTabs.get_children()
	for i in range(tab_buttons.size()):
		_style_tab(tab_buttons[i] as Button, i == tab_index)

	%PointsLabel.text = "◈ %d" % int(Session.account.get("points", 0))

	for c in %ItemsGrid.get_children():
		c.queue_free()

	var type_name := types[tab_index]
	# Only items actually for sale AND not already owned — once bought, an item
	# drops out of the shop entirely; it's equipped from the avatar picker from
	# then on, same as an achievement-reward cosmetic always was.
	var owned: Array = Session.account.get("owned_rewards", [])
	var all_buyable := ShopCatalog.buyable_ids_of_type(type_name)
	var item_ids := all_buyable.filter(func(id): return id not in owned)
	if item_ids.is_empty():
		var empty := Label.new()
		empty.text = "You own everything here!" if not all_buyable.is_empty() else "Nothing here yet."
		empty.add_theme_color_override("font_color", COL_MUTED)
		%ItemsGrid.add_child(empty)
		return
	for item_id in item_ids:
		_add_item_tile(item_id, ShopCatalog.def_for(item_id), type_name)


# --- item card ----------------------------------------------------------

func _card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_CARD_BG
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(1)
	sb.border_color = COL_CARD_BORDER
	sb.set_content_margin_all(12)
	return sb


func _add_item_tile(item_id: String, def: Dictionary, type_name: String) -> void:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(CARD_W, 0)
	card.add_theme_stylebox_override("panel", _card_style())

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	card.add_child(box)

	# --- art (sized to this type's real aspect ratio, shown uncropped) ---
	var art_size: Vector2 = ART_SIZE.get(type_name, Vector2(ART, ART))
	var art_frame := PanelContainer.new()
	art_frame.custom_minimum_size = art_size
	art_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	art_frame.clip_contents = true
	var art_bg := StyleBoxFlat.new()
	art_bg.bg_color = COL_ART_BG
	art_bg.set_corner_radius_all(8)
	art_frame.add_theme_stylebox_override("panel", art_bg)
	box.add_child(art_frame)

	var tex := _get_preview_texture(item_id, type_name)
	if tex != null:
		var art := TextureRect.new()
		art.texture = tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.custom_minimum_size = art_size
		art_frame.add_child(art)
	else:
		var ph := Label.new()
		ph.text = "No preview"
		ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		ph.add_theme_color_override("font_color", COL_MUTED)
		ph.add_theme_font_size_override("font_size", 12)
		art_frame.add_child(ph)

	# --- name ---
	var name_label := Label.new()
	name_label.text = ShopCatalog.display_name_for(item_id, type_name)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.add_theme_font_size_override("font_size", 15)
	box.add_child(name_label)

	var price := int(def.get("price", 0))

	# --- action button ---
	# _show_tab already filters to buyable-and-not-yet-owned items, so this
	# tile is always something the player could still buy — just Buy or Need.
	var points := int(Session.account.get("points", 0))

	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	if points >= price:
		_style_button(btn, "Buy  ◈%d" % price, COL_BUY, false)
		btn.pressed.connect(_purchase_item.bind(item_id))
	else:
		_style_button(btn, "Need ◈%d" % price, COL_OWNED, true)

	box.add_child(btn)
	%ItemsGrid.add_child(card)


func _style_button(btn: Button, text: String, col: Color, disabled: bool) -> void:
	btn.text = text
	btn.disabled = disabled
	var sb := StyleBoxFlat.new()
	sb.bg_color = col if not disabled else col.darkened(0.15)
	sb.set_corner_radius_all(8)
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	var hover := sb.duplicate()
	hover.bg_color = col.lightened(0.12)
	btn.add_theme_stylebox_override("normal", sb)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", sb)
	btn.add_theme_stylebox_override("disabled", sb)
	btn.add_theme_stylebox_override("focus", sb)
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.7))
	btn.add_theme_font_size_override("font_size", 14)


# --- helpers ----------------------------------------------------------

func _get_preview_texture(item_id: String, type_name: String) -> Texture2D:
	match type_name:
		"avatar": return Avatars.texture_for(item_id)
		"frame": return Frames.texture_for(item_id)
		"background": return Backgrounds.texture_for(item_id)
		"table_background": return TableBackgrounds.texture_for(item_id)
		"sleeve": return Sleeves.texture_for(item_id)
	return null


func _purchase_item(item_id: String) -> void:
	Net.shop_purchase(item_id)


func _on_purchase_result(account: Dictionary) -> void:
	Session.account = account
	_show_tab(_active_tab)


func _on_account_updated(account: Dictionary) -> void:
	Session.account = account
	_show_tab(_active_tab)
