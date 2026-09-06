class_name Avatars
extends RefCounted
## Shared avatar lookup. Square avatar images live in res://assets/avatars/ as
## <id>.png (drop more in there — they'll show up in the picker automatically).
## "default" is the fallback when an id has no file; "bot" is used for AI
## opponents.

const DIR := "res://assets/avatars/"
const DEFAULT_ID := "default"
const BOT_ID := "bot"

# Every bot wears the same frame + background (only the portrait varies,
# drawn from bot_pool()). See bot_identity().
const BOT_FRAME := "frame1"
const BOT_BACKGROUND := "avatar_bg_grainy_field_3"


## All selectable avatar ids (everything in DIR except the reserved
## "default"/"bot" placeholders and the bot-only portrait pool), sorted.
## Falls back to a fixed list if the directory can't be scanned (e.g. an
## odd export context).
static func list_ids() -> Array:
	var ids: Array = []
	var d := DirAccess.open(DIR)
	if d != null:
		for f in d.get_files():
			var name := f
			if name.ends_with(".import"):
				name = name.substr(0, name.length() - ".import".length())
			var id := ""
			if name.ends_with(".png"):
				id = name.substr(0, name.length() - ".png".length())
			elif name.ends_with(".tres"):
				# Animated avatar (AnimatedTexture, scripts/gif_to_cosmetic.py).
				id = name.substr(0, name.length() - ".tres".length())
			else:
				continue
			if _is_reserved(id):
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
	return ResourceLoader.exists(DIR + id + ".tres") or ResourceLoader.exists(DIR + id + ".png")


## Reserved ids a player may never pick: the generic "default"/"bot"
## placeholders and the bot-only portrait pool (bot1, bot2, ...).
static func _is_reserved(id: String) -> bool:
	return id == DEFAULT_ID or id == BOT_ID or _is_bot_pool_id(id)


static func _is_bot_pool_id(id: String) -> bool:
	if not id.begins_with("bot"):
		return false
	var rest := id.substr(3)
	return rest.length() > 0 and rest.is_valid_int()


## The bot-only portrait pool — res://assets/avatars/bot<N>.png, sorted.
## Drop more in and bots use them automatically. Falls back to [BOT_ID]
## when none are present.
static func bot_pool() -> Array:
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
			if _is_bot_pool_id(id) and not ids.has(id):
				ids.append(id)
	ids.sort()
	return ids if not ids.is_empty() else [BOT_ID]


## A random portrait id for a fresh bot opponent, drawn from bot_pool().
static func random_bot_id() -> String:
	var pool := bot_pool()
	return str(pool[randi() % pool.size()])


## Full cosmetic identity for a fresh bot: a random pool portrait plus the
## fixed bot frame + background. Callers should compute this once per match
## and reuse it so the look stays stable.
static func bot_identity() -> Dictionary:
	return {"avatar": random_bot_id(), "frame": BOT_FRAME, "background": BOT_BACKGROUND}


## True when an account still needs to pick an avatar: no id stored, or a
## stored id whose file no longer exists. Drives the first-login onboarding
## prompt in the main menu.
static func needs_choice(id: String) -> bool:
	return id.strip_edges() == "" or not has_id(id)


static func path_for(id: String) -> String:
	if id != "":
		# .tres (animated) wins over a still .png of the same id.
		if ResourceLoader.exists(DIR + id + ".tres"):
			return DIR + id + ".tres"
		if ResourceLoader.exists(DIR + id + ".png"):
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
	if clean == "" or _is_reserved(clean) or not has_id(clean):
		return list_ids()[0] if not list_ids().is_empty() else DEFAULT_ID
	return clean
