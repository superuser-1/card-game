class_name Frames
extends RefCounted
## Shared avatar-frame lookup. Frame images live in
## res://assets/avatars/avatar_frame/ (any image extension — drop more in
## there and they show up in the picker automatically). Frames are optional
## decoration drawn BEHIND the avatar image, so "" (no frame) is a valid,
## selectable id — unlike Avatars there is no forced default.

const DIR := "res://assets/avatars/avatar_frame/"
# ".tres" first so an animated AnimatedTexture (scripts/gif_to_cosmetic.py)
# wins over a still <id>.png of the same id in path_for().
const EXTENSIONS: Array[String] = ["tres", "png", "jpg", "jpeg", "webp"]
const NONE_ID := ""


## All selectable frame ids, sorted. Empty array if the folder is empty/missing.
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
	if id == NONE_ID:
		return true
	for ext in EXTENSIONS:
		if ResourceLoader.exists(DIR + id + "." + ext):
			return true
	return false


static func path_for(id: String) -> String:
	if id == NONE_ID:
		return ""
	for ext in EXTENSIONS:
		var p: String = DIR + id + "." + str(ext)
		if ResourceLoader.exists(p):
			return p
	return ""


## null when id is NONE_ID (or unresolvable) — callers just clear the texture.
static func texture_for(id: String) -> Texture2D:
	var p := path_for(id)
	if p == "":
		return null
	return load(p)


## Normalises whatever the client sent us to a safe stored id. Empty string
## (no frame) always passes through unchanged.
static func sanitize(id: String) -> String:
	var clean := ""
	for c in id:
		var ok := (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-"
		if ok:
			clean += c
	if clean == "" or not has_id(clean):
		return NONE_ID
	return clean
