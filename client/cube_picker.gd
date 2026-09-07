class_name CubePicker
## Shared helper for the "pick a card pool" dropdown shown in the custom-game
## and custom-tournament creation modals. Item 0 is always "Full collection"
## (send no cube); items 1..n are the player's local cubes. Cubes below the
## legal minimum are listed but disabled.


## Fill `opt` and return the cubes array. Item i (for i >= 1) corresponds to
## the returned array's element i - 1.
static func populate(opt: OptionButton) -> Array:
	var cubes: Array = Session.load_cubes()
	opt.clear()
	opt.add_item("Full collection")
	for c in cubes:
		var n: int = (c["card_ids"] as Array).size()
		var idx := opt.item_count
		if n >= CubeRules.MIN_SIZE:
			opt.add_item("%s  (%d cards)" % [c["name"], n])
		else:
			opt.add_item("%s  (%d — needs %d)" % [c["name"], n, CubeRules.MIN_SIZE])
			opt.set_item_disabled(idx, true)
	opt.select(0)
	return cubes


## The card-id list for the current selection: empty for "Full collection" (or
## any out-of-range / disabled pick), otherwise that cube's ids.
static func selected_ids(opt: OptionButton, cubes: Array) -> PackedStringArray:
	var i := opt.selected
	if i <= 0 or i - 1 >= cubes.size():
		return PackedStringArray()
	var out := PackedStringArray()
	for cid in (cubes[i - 1]["card_ids"] as Array):
		out.append(str(cid))
	return out
