class_name TableBackgrounds
extends RefCounted
## Game-table background lookup — the full-screen backdrop drawn behind an
## active match (game_ui.tscn's BackgroundRect). NOT the small backdrop behind
## the avatar portrait; see Backgrounds for that one. Images live in
## res://assets/tables/ as <id>.<ext> (drop more in — they show up in the
## picker automatically). Always resolves to something real: DEFAULT_ID ships
## unlocked on every new account, same convention as Avatars.

const DIR := "res://assets/tables/"
const DEFAULT_ID := "table_game_canvas_1"
# ".tres" first so an animated AnimatedTexture wins over a still <id>.png of
# the same id in path_for() (same convention as Backgrounds/Frames/Sleeves).
const EXTENSIONS: Array[String] = ["tres", "png", "jpg", "jpeg", "webp"]

# Stored in account["table_background"] instead of a real id — resolved to an
# actual owned id at the point of use (game_ui.gd, on match start) rather than
# up front, so the roll is fresh every match. See resolve_random().
const RANDOM_ID := "__random__"
const RANDOM_FAVORITE_ID := "__random_favorite__"


static func is_random_mode(id: String) -> bool:
	return id == RANDOM_ID or id == RANDOM_FAVORITE_ID


## All selectable table-background ids, sorted. Falls back to [DEFAULT_ID] if
## the folder can't be scanned or is empty.
static func list_ids() -> Array:
	var ids: Array = []
	var d := DirAccess.open(DIR)
	if d != null:
		for f in d.get_files():
			var name := f
			if name.ends_with(".import"):
				name = name.substr(0, name.length() - ".import".length())
			var dot := name.rfind(".")
			if dot == -1:
				continue
			var ext := name.substr(dot + 1).to_lower()
			if not EXTENSIONS.has(ext):
				continue
			var id := name.substr(0, dot)
			if not ids.has(id) and has_id(id):
				ids.append(id)
	if ids.is_empty():
		ids.append(DEFAULT_ID)
	ids.sort()
	return ids


static func has_id(id: String) -> bool:
	for ext in EXTENSIONS:
		if ResourceLoader.exists(DIR + id + "." + ext):
			return true
	return false


## Falls back to DEFAULT_ID when id is empty or unresolvable.
static func path_for(id: String) -> String:
	if id != "":
		for ext in EXTENSIONS:
			var p: String = DIR + id + "." + ext
			if ResourceLoader.exists(p):
				return p
	for ext in EXTENSIONS:
		var p: String = DIR + DEFAULT_ID + "." + ext
		if ResourceLoader.exists(p):
			return p
	return ""


static func texture_for(id: String) -> Texture2D:
	var p := path_for(id)
	if p == "":
		return null
	return load(p)


## Every table id this account actually owns: free ones, plus premium ones in
## owned_rewards. Same filter avatar_picker.gd applies to every other
## cosmetic category (see its _is_available), duplicated here so game_ui.gd
## can resolve a random pick without needing the picker loaded.
static func owned_ids(owned_rewards: Array) -> Array:
	return list_ids().filter(func(id): return not ShopCatalog.is_premium(id) or id in owned_rewards)


## Pure selection logic, split out from resolve_random() so it's unit-testable
## with a synthetic pool instead of needing extra files under assets/tables/.
## Narrows `pool` to `favorite_ids` for RANDOM_FAVORITE_ID (falling back to the
## full pool if that narrowing is empty), then rolls one id from it — or
## DEFAULT_ID if `pool` itself is empty.
static func _pick_random(stored_id: String, pool: Array, favorite_ids: Array) -> String:
	var candidates := pool
	if stored_id == RANDOM_FAVORITE_ID:
		var favs := pool.filter(func(id): return id in favorite_ids)
		if not favs.is_empty():
			candidates = favs
	if candidates.is_empty():
		return DEFAULT_ID
	return str(candidates[randi() % candidates.size()])


## Rolls an actual id for whatever's stored in account["table_background"]:
## a real id passes straight through; RANDOM_ID/RANDOM_FAVORITE_ID pick a
## fresh random owned id (falling back to the full owned pool if the
## favorites list is empty, and to DEFAULT_ID if even that is empty).
static func resolve_random(stored_id: String, owned_rewards: Array, favorite_ids: Array) -> String:
	if not is_random_mode(stored_id):
		return stored_id
	return _pick_random(stored_id, owned_ids(owned_rewards), favorite_ids)


## Normalises whatever the client sent us to a safe stored id. The two random
## modes pass through unchanged — they're a mode selector, not a filename.
static func sanitize(id: String) -> String:
	if is_random_mode(id):
		return id
	var clean := ""
	for c in id:
		var ok := (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-"
		if ok:
			clean += c
	if clean == "" or not has_id(clean):
		return DEFAULT_ID
	return clean
