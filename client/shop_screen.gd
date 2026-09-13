extends Control
## Cosmetics shop. Server is authoritative on price + ownership (see
## ServerStore.purchase / the equip-gate); this screen only renders the
## catalog and fires Net.shop_purchase / Net.set_<type>.
##
## Purchases go through a cart (right-hand panel) instead of buying instantly:
## clicking an item's action button adds/removes it from `_cart`, and "Buy
## All" checks it out one item at a time (`_checkout_queue`) since
## Net.shop_purchase is a single-item RPC — there's no batch-purchase call on
## the wire, so this just walks the cart sequentially, waiting for each
## result/error before sending the next.

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
const COL_IN_CART := Color(0.55, 0.36, 0.75)

const CART_THUMB := Vector2(32, 32)

## Which ShopCatalog.TYPES index is currently shown.
var _active_tab := 0

## item_id -> {"type": String, "price": int, "name": String}, insertion-ordered
## (GDScript Dictionaries preserve insertion order) so the cart panel lists
## items in the order they were added.
var _cart: Dictionary = {}

## Checkout walks this queue one id at a time — Net.shop_purchase is a
## single-item RPC, so a "Buy All" press just fires them in sequence rather
## than all at once, waiting for each result before sending the next.
var _checkout_queue: Array = []
var _checkout_current_id := ""
var _checkout_failed: Array = []  # [{"name": String, "message": String}]


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	Net.shop_purchase_result.connect(_on_purchase_result)
	Net.error_received.connect(_on_net_error)
	Net.avatar_updated.connect(_on_account_updated)
	Net.frame_updated.connect(_on_account_updated)
	Net.background_updated.connect(_on_account_updated)
	Net.sleeve_updated.connect(_on_account_updated)
	Net.table_background_updated.connect(_on_account_updated)
	Net.title_updated.connect(_on_account_updated)

	%CartBuyButton.pressed.connect(_start_checkout)
	%CartClearButton.pressed.connect(_clear_cart)
	%CartPanel.add_theme_stylebox_override("panel", _card_style())

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
	else:
		for item_id in item_ids:
			_add_item_tile(item_id, ShopCatalog.def_for(item_id), type_name)

	_refresh_cart_panel()


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
	var name := ShopCatalog.display_name_for(item_id, type_name)
	var name_label := Label.new()
	name_label.text = name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.add_theme_font_size_override("font_size", 15)
	box.add_child(name_label)

	var price := int(def.get("price", 0))

	# --- action button: adds/removes this item from the cart, never buys
	# directly — _show_tab already filters to buyable-and-not-yet-owned items,
	# so this tile is always something the player could still add.
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.name = "ActionButton"

	if _cart.has(item_id):
		_style_button(btn, "In Cart ✕", COL_IN_CART, false)
		btn.pressed.connect(_on_cart_remove_pressed.bind(item_id))
	else:
		var affordable := price <= _points_available_for_cart()
		if affordable:
			_style_button(btn, "Add  ◈%d" % price, COL_BUY, false)
			btn.pressed.connect(_on_cart_add_pressed.bind(item_id, type_name, price, name))
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


# --- cart ---------------------------------------------------------------

## Points still free to spend on a NEW addition — the balance minus whatever
## is already sitting in the cart, so adding several items in a row can never
## build a cart total above what the player can actually afford.
func _points_available_for_cart() -> int:
	return int(Session.account.get("points", 0)) - _cart_total()


func _cart_total() -> int:
	var total := 0
	for entry: Dictionary in _cart.values():
		total += int(entry.price)
	return total


func _on_cart_add_pressed(item_id: String, type_name: String, price: int, name: String) -> void:
	_cart[item_id] = {"type": type_name, "price": price, "name": name}
	_show_tab(_active_tab)


func _on_cart_remove_pressed(item_id: String) -> void:
	_cart.erase(item_id)
	_show_tab(_active_tab)


func _clear_cart() -> void:
	_cart.clear()
	_show_tab(_active_tab)


func _refresh_cart_panel() -> void:
	for c in %CartItemsBox.get_children():
		c.queue_free()

	%CartEmptyLabel.visible = _cart.is_empty()
	for item_id in _cart:
		_add_cart_row(item_id, _cart[item_id])

	var total := _cart_total()
	%CartTotalLabel.text = "Total: ◈ %d" % total
	var checking_out := not _checkout_queue.is_empty() or _checkout_current_id != ""
	%CartBuyButton.disabled = checking_out or _cart.is_empty() or total > int(Session.account.get("points", 0))
	%CartClearButton.disabled = checking_out or _cart.is_empty()


func _add_cart_row(item_id: String, entry: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var thumb_frame := PanelContainer.new()
	thumb_frame.custom_minimum_size = CART_THUMB
	thumb_frame.clip_contents = true
	var thumb_bg := StyleBoxFlat.new()
	thumb_bg.bg_color = COL_ART_BG
	thumb_bg.set_corner_radius_all(4)
	thumb_frame.add_theme_stylebox_override("panel", thumb_bg)
	var tex := _get_preview_texture(item_id, str(entry.type))
	if tex != null:
		var thumb := TextureRect.new()
		thumb.texture = tex
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.custom_minimum_size = CART_THUMB
		thumb_frame.add_child(thumb)
	row.add_child(thumb_frame)

	var name_label := Label.new()
	name_label.text = str(entry.name)
	name_label.clip_text = true
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 12)
	row.add_child(name_label)

	var price_label := Label.new()
	price_label.text = "◈%d" % int(entry.price)
	price_label.add_theme_font_size_override("font_size", 12)
	price_label.add_theme_color_override("font_color", Color(1, 0.843, 0.4, 1))
	row.add_child(price_label)

	var remove_btn := Button.new()
	remove_btn.text = "✕"
	remove_btn.flat = true
	remove_btn.focus_mode = Control.FOCUS_NONE
	remove_btn.add_theme_font_size_override("font_size", 13)
	remove_btn.pressed.connect(_on_cart_remove_pressed.bind(item_id))
	row.add_child(remove_btn)

	%CartItemsBox.add_child(row)


## Buy All checks the cart out one item at a time (see the note at the top of
## this file for why) — each Net.shop_purchase call waits for either
## shop_purchase_result (success) or error_received (failure) before the next
## one is sent.
func _start_checkout() -> void:
	if _cart.is_empty() or not _checkout_queue.is_empty():
		return
	_checkout_queue = _cart.keys()
	_checkout_failed = []
	_checkout_next()


func _checkout_next() -> void:
	if _checkout_queue.is_empty():
		_finish_checkout()
		return
	_checkout_current_id = str(_checkout_queue.pop_front())
	Net.shop_purchase(_checkout_current_id)


func _finish_checkout() -> void:
	_checkout_current_id = ""
	var failed_count := _checkout_failed.size()
	if failed_count == 0:
		_toast("Purchase complete!")
	else:
		_toast("%d item(s) could not be purchased." % failed_count)
	_checkout_failed = []
	_show_tab(_active_tab)


func _toast(msg: String) -> void:
	var label := Label.new()
	label.text = msg
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(1, 0.843, 0.4, 1))
	%CartBox.add_child(label)
	%CartBox.move_child(label, 1)  # right under "Cart", not after the buttons
	var tw := create_tween()
	tw.tween_interval(2.0)
	tw.tween_callback(label.queue_free)


func _on_purchase_result(account: Dictionary) -> void:
	Session.account = account
	if _checkout_current_id != "":
		_cart.erase(_checkout_current_id)
		_checkout_current_id = ""
		_checkout_next()
	else:
		_show_tab(_active_tab)


## Global error bus (Net.error_received) — only relevant to us mid-checkout;
## anything else firing while this screen is up isn't ours to react to.
func _on_net_error(message: String) -> void:
	if _checkout_current_id == "":
		return
	_checkout_failed.append({"name": str(_cart.get(_checkout_current_id, {}).get("name", _checkout_current_id)), "message": message})
	_checkout_current_id = ""
	_checkout_next()


func _on_account_updated(account: Dictionary) -> void:
	Session.account = account
	_show_tab(_active_tab)
