class_name PrizeView
## Shared rendering for tournament prize pools: item art lookup + compact
## "◈500 [icon] · ◈200 …" rows, used by the creation modal, the per-bucket
## prize editor, the tournament list and the bracket screen so they all look
## the same.

const GOLD := Color(1.0, 0.85, 0.4)


## Texture for a shop item id, or null if the type has no art.
static func item_texture(shop_id: String) -> Texture2D:
	match str(ShopCatalog.def_for(shop_id).get("type", "")):
		"avatar": return Avatars.texture_for(shop_id)
		"frame": return Frames.texture_for(shop_id)
		"background": return Backgrounds.texture_for(shop_id)
		"sleeve": return Sleeves.texture_for(shop_id)
	return null


## A square icon Control for one item — its art cropped-not-stretched, or a
## muted "?" tile when there's no preview.
static func make_icon(shop_id: String, px: float) -> Control:
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(px, px)
	frame.clip_contents = true
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.tooltip_text = str(ShopCatalog.def_for(shop_id).get("name", shop_id))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.25)
	sb.set_corner_radius_all(5)
	frame.add_theme_stylebox_override("panel", sb)

	var tex := item_texture(shop_id)
	if tex != null:
		var art := TextureRect.new()
		art.texture = tex
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.custom_minimum_size = Vector2(px, px)
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(art)
	else:
		var q := Label.new()
		q.text = "?"
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		q.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
		frame.add_child(q)
	return frame


## Contents of ONE bucket ("◈500" chip + item icons, or "— none —"), packed
## into an HBoxContainer. `prize` is {points, items}.
static func bucket_contents(prize: Dictionary, icon_px: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var points := int(prize.get("points", 0))
	var items: Array = prize.get("items", [])
	if points <= 0 and items.is_empty():
		var none := Label.new()
		none.text = "— none —"
		none.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
		none.add_theme_font_size_override("font_size", 12)
		row.add_child(none)
		return row
	if points > 0:
		var pts := Label.new()
		pts.text = "◈%d" % points
		pts.add_theme_color_override("font_color", GOLD)
		pts.add_theme_font_size_override("font_size", 13)
		row.add_child(pts)
	for id in items:
		row.add_child(make_icon(str(id), icon_px))
	return row


## Vertical prize list for a card's right column: a "Prizes" header + one
## "<label>  <contents>" line per set bucket. Returns an empty (invisible)
## VBox when there are no prizes.
static func column(prizes: Dictionary, icon_px := 24.0) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	if prizes.is_empty():
		col.visible = false
		return col
	var head := Label.new()
	head.text = "Prizes"
	head.add_theme_color_override("font_color", GOLD)
	head.add_theme_font_size_override("font_size", 12)
	col.add_child(head)
	for b in TournamentPrizes.BUCKETS:
		if not prizes.has(b):
			continue
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 5)
		var lbl := Label.new()
		lbl.text = TournamentPrizes.LABELS.get(b, b)
		lbl.custom_minimum_size = Vector2(74, 0)
		lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
		lbl.add_theme_font_size_override("font_size", 12)
		line.add_child(lbl)
		line.add_child(bucket_contents(prizes[b], icon_px))
		col.add_child(line)
	return col


## Full read-only prize summary for the list / bracket screens: one wrapping
## row of "<label>: <contents>" groups.
static func summary_row(prizes: Dictionary, icon_px := 22.0) -> Control:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 12)
	flow.add_theme_constant_override("v_separation", 3)

	var head := Label.new()
	head.text = "Prizes"
	head.add_theme_color_override("font_color", GOLD)
	head.add_theme_font_size_override("font_size", 12)
	flow.add_child(head)

	for b in TournamentPrizes.BUCKETS:
		if not prizes.has(b):
			continue
		var group := HBoxContainer.new()
		group.add_theme_constant_override("separation", 4)
		var lbl := Label.new()
		lbl.text = "%s:" % TournamentPrizes.LABELS.get(b, b)
		lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
		lbl.add_theme_font_size_override("font_size", 12)
		group.add_child(lbl)
		group.add_child(bucket_contents(prizes[b], icon_px))
		flow.add_child(group)
	return flow
