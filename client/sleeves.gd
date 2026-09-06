class_name Sleeves
extends RefCounted
## Shared card-back (sleeve) lookup. Sleeve images live in
## res://assets/avatars/card_backs/ (any image extension — drop more in there and
## they show up in the picker automatically). Sleeves are optional decoration for
## the face-down card back, so "" (no sleeve / default) is a valid, selectable id
## — the default resolves to the existing res://assets/cards/card_back1.png.
## Everything in the folder is free to use (card backs are not in ShopCatalog).

const DIR := "res://assets/avatars/card_backs/"
const EXTENSIONS: Array[String] = ["png", "jpg", "jpeg", "webp"]
const NONE_ID := "classic"


## All selectable sleeve ids, sorted. Empty array if the folder is empty/missing.
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
			# Guards against a stale orphaned .import left behind after the
			# source image itself was deleted (has_id resolves the real file).
			if not ids.has(id) and has_id(id):
				ids.append(id)
	ids.sort()
	return ids


static func has_id(id: String) -> bool:
	if id == NONE_ID or id == "":
		return true
	for ext in EXTENSIONS:
		if ResourceLoader.exists(DIR + id + "." + ext):
			return true
	return false


static func path_for(id: String) -> String:
	if id == NONE_ID or id == "":
		return "res://assets/cards/card_back1.png"
	for ext in EXTENSIONS:
		var p: String = DIR + id + "." + str(ext)
		if ResourceLoader.exists(p):
			return p
	return "res://assets/cards/card_back1.png"


## null when id is NONE_ID (or unresolvable) — callers just clear the texture.
static func texture_for(id: String) -> Texture2D:
	var p := path_for(id)
	if ResourceLoader.exists(p):
		return load(p)
	return null


## Normalises whatever the client sent us to a safe stored id. Empty string
## (default sleeve) always passes through unchanged.
static func sanitize(id: String) -> String:
	var clean := ""
	for c in id:
		var ok := (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-"
		if ok:
			clean += c
	if clean == "" or clean == NONE_ID or not has_id(clean):
		return ""
	return clean
