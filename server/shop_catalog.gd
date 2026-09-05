class_name ShopCatalog
extends RefCounted

# type ∈ "avatar" | "frame" | "background" | "sleeve"
# source ∈ "shop" (buyable) | "achievement" (granted only, price ignored)
# NOTE: every shop price is 5 on purpose — debug placeholder. Real cosmetics +
# real prices get added here later by the user; this is a data edit only.
const CATALOG: Array = [
	{"id": "avatar_gold_reel", "type": "avatar",     "name": "Gold Reel",     "price": 5, "source": "shop"},
	{"id": "frame_neon",       "type": "frame",      "name": "Neon",          "price": 5, "source": "shop"},
	{"id": "bg_starfield",     "type": "background", "name": "Starfield",     "price": 5, "source": "shop"},
	{"id": "sleeve_noir",      "type": "sleeve",     "name": "Noir",          "price": 5, "source": "shop"},
	# --- achievement-only (see PLAN_achievements.md §1); not buyable ---
	{"id": "frame_champion",   "type": "frame",      "name": "Champion",      "price": 0, "source": "achievement"},
	{"id": "frame_veteran",    "type": "frame",      "name": "Veteran",       "price": 0, "source": "achievement"},
	{"id": "avatar_champion",  "type": "avatar",     "name": "Grand Champion","price": 0, "source": "achievement"},
	{"id": "sleeve_flame",     "type": "sleeve",     "name": "Flame",         "price": 0, "source": "achievement"},
]

const TYPES: Array[String] = ["avatar", "frame", "background", "sleeve"]


static func def_for(id: String) -> Dictionary:
	for item in CATALOG:
		if str(item.id) == id:
			return item
	return {}


static func is_premium(id: String) -> bool:
	return not def_for(id).is_empty()


static func is_buyable(id: String) -> bool:
	var d := def_for(id)
	return not d.is_empty() and str(d.source) == "shop"


static func ids_of_type(t: String) -> Array:
	var ids := []
	for item in CATALOG:
		if str(item.type) == t:
			ids.append(str(item.id))
	return ids
