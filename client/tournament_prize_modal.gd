extends Control
## Editor for ONE tournament prize bucket (1st / 2nd / 3rd / 4th–8th / 9th–16th).
## Opened by tournament_creation_modal as a child; emits `saved` on OK. The
## creation modal owns the spec and re-prices the whole pool — this is just a
## picker.

signal saved(bucket: String, spec: Dictionary)

var _bucket := ""
var _checks: Dictionary = {}   # shop_id -> CheckBox


## Call right after instancing, before the modal is shown.
func setup(bucket: String, spec: Dictionary) -> void:
	_bucket = bucket
	%Title.text = "%s place prize" % TournamentPrizes.LABELS.get(bucket, bucket)
	%PointsSpin.value = float(int(spec.get("points", 0)))

	var have: Array = spec.get("items", [])
	for def in ShopCatalog.CATALOG:
		if str(def.get("source", "")) != "shop":
			continue
		var id := str(def.id)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var cb := CheckBox.new()
		cb.button_pressed = id in have
		cb.toggled.connect(func(_p): _refresh())
		row.add_child(cb)

		row.add_child(PrizeView.make_icon(id, 36.0))

		var lbl := Label.new()
		lbl.text = "%s   ◈%d   (%s)" % [str(def.name), int(def.price), str(def.type)]
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(lbl)

		%ItemsBox.add_child(row)
		_checks[id] = cb
	_refresh()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	%PointsSpin.value_changed.connect(func(_v): _refresh())
	%OkButton.pressed.connect(_on_ok)
	%CancelButton.pressed.connect(queue_free)


func _current_spec() -> Dictionary:
	var items := []
	for id in _checks:
		if _checks[id].button_pressed:
			items.append(id)
	return {"points": int(%PointsSpin.value), "items": items}


func _refresh() -> void:
	var spec := _current_spec()

	# Cap at MAX_ITEMS_PER_BUCKET — once the limit is hit, lock the unchecked
	# boxes so no more can be added.
	var at_limit: bool = (spec.items as Array).size() >= TournamentPrizes.MAX_ITEMS_PER_BUCKET
	for id in _checks:
		_checks[id].disabled = at_limit and not _checks[id].button_pressed

	var slots := int(TournamentPrizes.SLOTS.get(_bucket, 1))
	var per := int(spec.points)
	for id in spec.items:
		per += ShopCatalog.price_for(id)
	%CostLabel.text = "This placement: ◈%d  ·  ×%d slot%s  =  ◈%d   (up to %d items)" % [
		per, slots, "" if slots == 1 else "s", per * slots, TournamentPrizes.MAX_ITEMS_PER_BUCKET
	]


func _on_ok() -> void:
	var spec := _current_spec()
	# An empty save clears the bucket — the creation modal decides whether that's
	# allowed (it isn't if a later bucket is still set).
	saved.emit(_bucket, spec)
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		queue_free()
		get_viewport().set_input_as_handled()
