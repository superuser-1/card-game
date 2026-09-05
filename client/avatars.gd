class_name Avatars
extends RefCounted
## Shared avatar lookup. Square avatar images live in res://assets/avatars/ as
## <id>.png (drop more in there — they'll show up in the picker automatically).
## "default" is the fallback when an id has no file; "bot" is used for AI
## opponents.

const DIR := "res://assets/avatars/"
const DEFAULT_ID := "default"
const BOT_ID := "bot"


## All selectable avatar ids (everything in DIR except the reserved
## "default"/"bot" entries), sorted. Falls back to a fixed list if the
## directory can't be scanned (e.g. an odd export context).
static func list_ids() -> Array:
	var ids: Array = []
	var d := DirAccess.open(DIR)
	if d != null:
		for f in d.get_files():
			var name := f
			if name.ends_with(".import"):
				name = name.substr(0, name.length() - ".import".length())
			if not name.ends_with(".png"):
				continue
			var id := name.substr(0, name.length() - ".png".length())
			if id == DEFAULT_ID or id == BOT_ID:
				continue
			if not ids.has(id):
				ids.append(id)
	if ids.is_empty():
		for kind in ["female", "male"]:
			for i in range(1, 7):
				ids.append("avatar_%s_%02d" % [kind, i])
	ids.sort()
	return ids


static func has_id(id: String) -> bool:
	return ResourceLoader.exists(DIR + id + ".png")


## True when an account still needs to pick an avatar: no id stored, or a
## stored id whose file no longer exists. Drives the first-login onboarding
## prompt in the main menu.
static func needs_choice(id: String) -> bool:
	return id.strip_edges() == "" or not has_id(id)


static func path_for(id: String) -> String:
	if id != "" and ResourceLoader.exists(DIR + id + ".png"):
		return DIR + id + ".png"
	return DIR + DEFAULT_ID + ".png"


static func texture_for(id: String) -> Texture2D:
	return load(path_for(id))


## Normalises whatever the client sent us to a safe stored id.
static func sanitize(id: String) -> String:
	var clean := ""
	for c in id:
		var ok := (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "_" or c == "-"
		if ok:
			clean += c
	if clean == "" or clean == BOT_ID or not has_id(clean):
		return list_ids()[0] if not list_ids().is_empty() else DEFAULT_ID
	return clean
