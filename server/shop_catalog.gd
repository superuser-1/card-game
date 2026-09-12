class_name ShopCatalog
extends RefCounted

# type ∈ "avatar" | "frame" | "background" | "table_background" | "sleeve" | "title"
# source ∈ "shop" (buyable) | "achievement" (granted only, price ignored)
# NOTE: every shop price is 5 on purpose — debug placeholder. Real cosmetics +
# real prices get added here later by the user; this is a data edit only.
const CATALOG: Array = [
	# --- avatars (art in res://assets/avatars/<id>.png) ---
	{"id": "aphrodite", "type": "avatar", "name": "Aphrodite", "price": 5, "source": "shop"},
	{"id": "athena",    "type": "avatar", "name": "Athena",    "price": 5, "source": "shop"},
	{"id": "ella",      "type": "avatar", "name": "Ella",      "price": 5, "source": "shop"},
	{"id": "eric",      "type": "avatar", "name": "Eric",      "price": 5, "source": "shop"},
	{"id": "hades",     "type": "avatar", "name": "Hades",     "price": 5, "source": "shop"},
	{"id": "helena",    "type": "avatar", "name": "Helena",    "price": 5, "source": "shop"},
	{"id": "hercules",  "type": "avatar", "name": "Hercules",  "price": 5, "source": "shop"},
	{"id": "lea",       "type": "avatar", "name": "Lea",       "price": 5, "source": "shop"},
	{"id": "lily",      "type": "avatar", "name": "Lily",      "price": 5, "source": "shop"},
	{"id": "stephanus", "type": "avatar", "name": "Stephanus", "price": 5, "source": "shop"},
	{"id": "zeus",      "type": "avatar", "name": "Zeus",      "price": 5, "source": "shop"},
	# --- placeholders (no art yet — replace when real cosmetics land) ---
	{"id": "frame_neon",       "type": "frame",           "name": "Neon",          "price": 5, "source": "shop"},
	{"id": "bg_starfield",     "type": "background",      "name": "Starfield",     "price": 5, "source": "shop"},
	{"id": "sleeve_noir",      "type": "sleeve",          "name": "Noir",          "price": 5, "source": "shop"},
	{"id": "title_night_owl",  "type": "title",           "name": "Night Owl",     "price": 5, "source": "shop"},
	# --- table backgrounds (art: res://assets/tables/<id>.png|jpg) ---
	# table_game_canvas_1 (default, free) / _2 / _3 are free for everyone —
	# not in this catalog at all, same as any other non-premium cosmetic.
	# _4 through _12 are shop-buyable.
	{"id": "table_game_canvas_4",  "type": "table_background", "name": "Table 4",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_5",  "type": "table_background", "name": "Table 5",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_6",  "type": "table_background", "name": "Table 6",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_7",  "type": "table_background", "name": "Table 7",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_8",  "type": "table_background", "name": "Table 8",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_9",  "type": "table_background", "name": "Table 9",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_10", "type": "table_background", "name": "Table 10", "price": 5, "source": "shop"},
	{"id": "table_game_canvas_11", "type": "table_background", "name": "Table 11", "price": 5, "source": "shop"},
	{"id": "table_game_canvas_12", "type": "table_background", "name": "Table 12", "price": 5, "source": "shop"},
	# --- achievement-only (see PLAN_achievements.md §1); not buyable ---
	{"id": "frame_champion",   "type": "frame",      "name": "Champion",      "price": 0, "source": "achievement"},
	{"id": "frame_veteran",    "type": "frame",      "name": "Veteran",       "price": 0, "source": "achievement"},
	{"id": "avatar_champion",  "type": "avatar",     "name": "Grand Champion","price": 0, "source": "achievement"},
	{"id": "sleeve_flame",     "type": "sleeve",     "name": "Flame",         "price": 0, "source": "achievement"},
	{"id": "title_champion",   "type": "title",      "name": "Champion",      "price": 0, "source": "achievement"},
	# Avatar rewards for the ranked-loss ladder (art: res://assets/avatars/<id>.png).
	{"id": "30_ranked_losses_avatar",   "type": "avatar", "name": "30 Ranked Losses",   "price": 0, "source": "achievement"},
	{"id": "50_ranked_losses_avatar",   "type": "avatar", "name": "50 Ranked Losses",   "price": 0, "source": "achievement"},
	{"id": "100_ranked_losses_avatar",  "type": "avatar", "name": "100 Ranked Losses",  "price": 0, "source": "achievement"},
	{"id": "250_ranked_losses_avatar",  "type": "avatar", "name": "250 Ranked Losses",  "price": 0, "source": "achievement"},
	{"id": "500_ranked_losses_avatar",  "type": "avatar", "name": "500 Ranked Losses",  "price": 0, "source": "achievement"},
	{"id": "1000_ranked_losses_avatar", "type": "avatar", "name": "1000 Ranked Losses", "price": 0, "source": "achievement"},
	# Avatar rewards for the tournament-win ladder (art: res://assets/avatars/<id>.png).
	{"id": "1_tournament_win_avatar",   "type": "avatar", "name": "1 Tournament Win",    "price": 0, "source": "achievement"},
	{"id": "5_tournament_win_avatar",   "type": "avatar", "name": "5 Tournament Wins",   "price": 0, "source": "achievement"},
	{"id": "10_tournament_win_avatar",  "type": "avatar", "name": "10 Tournament Wins",  "price": 0, "source": "achievement"},
	{"id": "25_tournament_win_avatar",  "type": "avatar", "name": "25 Tournament Wins",  "price": 0, "source": "achievement"},
	{"id": "50_tournament_win_avatar",  "type": "avatar", "name": "50 Tournament Wins",  "price": 0, "source": "achievement"},
	{"id": "100_tournament_win_avatar", "type": "avatar", "name": "100 Tournament Wins", "price": 0, "source": "achievement"},
	# Avatar rewards for the tournament-created ladder (art: res://assets/avatars/<id>.png).
	{"id": "5_tournaments_created",   "type": "avatar", "name": "5 Tournaments Created",   "price": 0, "source": "achievement"},
	{"id": "15_tournaments_created",  "type": "avatar", "name": "15 Tournaments Created",  "price": 0, "source": "achievement"},
	{"id": "50_tournaments_created",  "type": "avatar", "name": "50 Tournaments Created",  "price": 0, "source": "achievement"},
	{"id": "100_tournaments_created", "type": "avatar", "name": "100 Tournaments Created", "price": 0, "source": "achievement"},
	{"id": "250_tournaments_created", "type": "avatar", "name": "250 Tournaments Created", "price": 0, "source": "achievement"},
	{"id": "500_tournaments_created", "type": "avatar", "name": "500 Tournaments Created", "price": 0, "source": "achievement"},
	# Avatar rewards for the ranked-win ladder (art: res://assets/avatars/<id>.png).
	{"id": "1_ranked_win",    "type": "avatar", "name": "First Ranked Win", "price": 0, "source": "achievement"},
	{"id": "5_ranked_win",    "type": "avatar", "name": "5 Ranked Wins",    "price": 0, "source": "achievement"},
	{"id": "10_ranked_win",   "type": "avatar", "name": "10 Ranked Wins",   "price": 0, "source": "achievement"},
	{"id": "30_ranked_win",   "type": "avatar", "name": "30 Ranked Wins",   "price": 0, "source": "achievement"},
	{"id": "50_ranked_win",   "type": "avatar", "name": "50 Ranked Wins",   "price": 0, "source": "achievement"},
	{"id": "100_ranked_win",  "type": "avatar", "name": "100 Ranked Wins",  "price": 0, "source": "achievement"},
	{"id": "250_ranked_win",  "type": "avatar", "name": "250 Ranked Wins",  "price": 0, "source": "achievement"},
	{"id": "500_ranked_win",  "type": "avatar", "name": "500 Ranked Wins",  "price": 0, "source": "achievement"},
	{"id": "1000_ranked_win", "type": "avatar", "name": "1000 Ranked Wins", "price": 0, "source": "achievement"},
	# Avatar rewards for the quests-completed ladder (art: res://assets/avatars/<id>.png).
	{"id": "5_quests_completed",    "type": "avatar", "name": "5 Quests Completed",    "price": 0, "source": "achievement"},
	{"id": "10_quests_completed",   "type": "avatar", "name": "10 Quests Completed",   "price": 0, "source": "achievement"},
	{"id": "25_quests_completed",   "type": "avatar", "name": "25 Quests Completed",   "price": 0, "source": "achievement"},
	{"id": "100_quests_completed",  "type": "avatar", "name": "100 Quests Completed",  "price": 0, "source": "achievement"},
	{"id": "250_quests_completed",  "type": "avatar", "name": "250 Quests Completed",  "price": 0, "source": "achievement"},
	{"id": "1000_quests_completed", "type": "avatar", "name": "1000 Quests Completed", "price": 0, "source": "achievement"},
]

const TYPES: Array[String] = ["avatar", "frame", "background", "table_background", "sleeve", "title"]


static func def_for(id: String) -> Dictionary:
	for item in CATALOG:
		if str(item.id) == id:
			return item
	return {}


static func is_premium(id: String) -> bool:
	return not def_for(id).is_empty()


## Points price of an item, or 0 if the id is unknown.
static func price_for(id: String) -> int:
	return int(def_for(id).get("price", 0))


static func is_buyable(id: String) -> bool:
	var d := def_for(id)
	return not d.is_empty() and str(d.source) == "shop"


static func ids_of_type(t: String) -> Array:
	var ids := []
	for item in CATALOG:
		if str(item.type) == t:
			ids.append(str(item.id))
	return ids


## Ids of a type that are actually for sale. Achievement-only rewards are
## granted by unlocks and equipped from the avatar picker once owned — they are
## never listed in the shop.
static func buyable_ids_of_type(t: String) -> Array:
	return ids_of_type(t).filter(func(id): return is_buyable(id))
