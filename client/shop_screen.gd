extends Control

## Which ShopCatalog.TYPES index is currently shown.
var _active_tab := 0


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	Net.shop_purchase_result.connect(_on_purchase_result)
	Net.avatar_updated.connect(_on_account_updated)
	Net.frame_updated.connect(_on_account_updated)
	Net.background_updated.connect(_on_account_updated)
	Net.sleeve_updated.connect(_on_account_updated)

	_render_tabs()
	_show_tab(0)


## One filter button per item type — TabContainer isn't used because its tabs
## come from child controls, not an add_tab() call.
func _render_tabs() -> void:
	for c in %TypeTabs.get_children():
		c.queue_free()

	var types: Array[String] = ShopCatalog.TYPES
	for i in range(types.size()):
		var btn := Button.new()
		btn.text = types[i].capitalize()
		btn.pressed.connect(_show_tab.bind(i))
		%TypeTabs.add_child(btn)


func _show_tab(tab_index: int) -> void:
	var types: Array[String] = ShopCatalog.TYPES
	if tab_index < 0 or tab_index >= types.size():
		return
	_active_tab = tab_index

	# Reflect the active filter on the buttons.
	var tab_buttons := %TypeTabs.get_children()
	for i in range(tab_buttons.size()):
		(tab_buttons[i] as Button).disabled = (i == tab_index)

	var type_name := types[tab_index]
	var item_ids := ShopCatalog.ids_of_type(type_name)

	# Update points balance
	%PointsLabel.text = "Points: %d" % int(Session.account.get("points", 0))

	# Clear existing tiles
	for c in %ItemsGrid.get_children():
		c.queue_free()

	# Create tiles for each item
	for item_id in item_ids:
		var def := ShopCatalog.def_for(item_id)
		_add_item_tile(item_id, def, type_name)


func _add_item_tile(item_id: String, def: Dictionary, type_name: String) -> void:
	var tile := VBoxContainer.new()
	tile.alignment = BoxContainer.ALIGNMENT_CENTER
	tile.custom_minimum_size = Vector2(120, 160)

	# Preview art
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(100, 100)
	preview.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	preview.texture = _get_preview_texture(item_id, type_name)
	tile.add_child(preview)

	# Name
	var name_label := Label.new()
	name_label.text = str(def.get("name", item_id))
	name_label.add_theme_font_size_override("font_size", 12)
	name_label.custom_minimum_size.x = 120
	tile.add_child(name_label)

	# Price or unlock info
	var price_label := Label.new()
	var source := str(def.get("source", ""))
	if source == "shop":
		price_label.text = "Price: %d" % int(def.get("price", 0))
	else:
		price_label.text = "Achievement"
	price_label.add_theme_font_size_override("font_size", 10)
	tile.add_child(price_label)

	# State button
	var button := Button.new()
	var owned: Array = Session.account.get("owned_rewards", [])
	var equipped_id := _get_equipped_id(item_id, type_name)
	var is_owned := item_id in owned
	var is_equipped := equipped_id == item_id
	var points := int(Session.account.get("points", 0))
	var price := int(def.get("price", 0))

	if is_equipped:
		button.text = "Equipped"
		button.disabled = true
	elif is_owned:
		button.text = "Equip"
		button.pressed.connect(func(): _equip_item(item_id, type_name))
	elif source == "shop":
		if points >= price:
			button.text = "Buy"
			button.pressed.connect(func(): _purchase_item(item_id))
		else:
			button.text = "Can't afford"
			button.disabled = true
	else:
		button.text = "Unlock via Achievement"
		button.disabled = true

	tile.add_child(button)
	%ItemsGrid.add_child(tile)


func _get_preview_texture(item_id: String, type_name: String) -> Texture2D:
	match type_name:
		"avatar":
			return Avatars.texture_for(item_id)
		"frame":
			return Frames.texture_for(item_id)
		"background":
			return Backgrounds.texture_for(item_id)
		"sleeve":
			return Sleeves.texture_for(item_id)
	return null


func _get_equipped_id(item_id: String, type_name: String) -> String:
	match type_name:
		"avatar":
			return str(Session.account.get("avatar", ""))
		"frame":
			return str(Session.account.get("frame", ""))
		"background":
			return str(Session.account.get("background", ""))
		"sleeve":
			return str(Session.account.get("sleeve", ""))
	return ""


func _equip_item(item_id: String, type_name: String) -> void:
	match type_name:
		"avatar":
			Net.set_avatar(item_id)
		"frame":
			Net.set_frame(item_id)
		"background":
			Net.set_background(item_id)
		"sleeve":
			Net.set_sleeve(item_id)


func _purchase_item(item_id: String) -> void:
	Net.shop_purchase(item_id)


func _on_purchase_result(account: Dictionary) -> void:
	Session.account = account
	%PointsLabel.text = "Points: %d" % int(account.get("points", 0))
	_show_tab(_active_tab)


func _on_account_updated(account: Dictionary) -> void:
	Session.account = account
	_show_tab(_active_tab)
