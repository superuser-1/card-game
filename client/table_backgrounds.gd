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


## Normalises whatever the client sent us to a safe stored id.
static func sanitize(id: String) -> String:
	var clean := ""
	for c in id:
		var ok := (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-"
		if ok:
			clean += c
	if clean == "" or not has_id(clean):
		return DEFAULT_ID
	return clean
