class_name ShopCatalog
extends RefCounted

# type ∈ "avatar" | "frame" | "background" | "table_background" | "sleeve" | "title"
# source ∈ "shop" (buyable) | "achievement" (auto-granted by an achievement
#   tier — see achievement_system.gd's own `reward` fields for which tier)
#   | "admin" (never auto-granted by anything — the ONLY way a player gets
#   one is an admin handing it out directly or as a tournament prize)
# Both achievement and admin items are hidden from the shop and equipped from
# the avatar/table/title picker once owned; price is ignored (kept at 0) for
# both.
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
	# --- frames (art: res://assets/avatars/avatar_frame/<id>.png) ---
	# frame1/2/3 are achievement-only now (see below); frame4/5 are shop-buyable.
	# None are free anymore.
	{"id": "frame4", "type": "frame", "name": "Frame 4", "price": 5, "source": "shop"},
	{"id": "frame5", "type": "frame", "name": "Frame 5", "price": 5, "source": "shop"},
	# --- avatar backgrounds (art: res://assets/avatars/avatar_bg/<id>.png) ---
	# All shop-buyable — no free tier for backgrounds.
	{"id": "avatar_bg_grainy_field_1", "type": "background", "name": "Grainy Field 1", "price": 5, "source": "shop"},
	{"id": "avatar_bg_grainy_field_2", "type": "background", "name": "Grainy Field 2", "price": 5, "source": "shop"},
	{"id": "avatar_bg_grainy_field_3", "type": "background", "name": "Grainy Field 3", "price": 5, "source": "shop"},
	{"id": "avatar_bg_oil_paint_1",    "type": "background", "name": "Oil Paint 1",    "price": 5, "source": "shop"},
	{"id": "avatar_bg_oil_paint_2",    "type": "background", "name": "Oil Paint 2",    "price": 5, "source": "shop"},
	# --- table backgrounds (art: res://assets/tables/<id>.png|jpg) ---
	# table_game_canvas_1 (default) is the only one still free for everyone —
	# not in this catalog at all, same as any other non-premium cosmetic.
	# _2 through _12 are shop-buyable.
	{"id": "table_game_canvas_2",  "type": "table_background", "name": "Table 2",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_3",  "type": "table_background", "name": "Table 3",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_4",  "type": "table_background", "name": "Table 4",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_5",  "type": "table_background", "name": "Table 5",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_6",  "type": "table_background", "name": "Table 6",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_7",  "type": "table_background", "name": "Table 7",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_8",  "type": "table_background", "name": "Table 8",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_9",  "type": "table_background", "name": "Table 9",  "price": 5, "source": "shop"},
	{"id": "table_game_canvas_10", "type": "table_background", "name": "Table 10", "price": 5, "source": "shop"},
	{"id": "table_game_canvas_11", "type": "table_background", "name": "Table 11", "price": 5, "source": "shop"},
	{"id": "table_game_canvas_12", "type": "table_background", "name": "Table 12", "price": 5, "source": "shop"},
	# --- card backs (art: res://assets/avatars/card_backs/<id>.png) ---
	# card_back_1/2/3 are free for everyone — not in this catalog at all.
	# card_back_4/6/7/10/11/12 are shop-buyable; 5/8/9 are admin-only (below).
	{"id": "card_back_4",  "type": "sleeve", "name": "Card Back 4",  "price": 5, "source": "shop"},
	{"id": "card_back_6",  "type": "sleeve", "name": "Card Back 6",  "price": 5, "source": "shop"},
	{"id": "card_back_7",  "type": "sleeve", "name": "Card Back 7",  "price": 5, "source": "shop"},
	{"id": "card_back_10", "type": "sleeve", "name": "Card Back 10", "price": 5, "source": "shop"},
	{"id": "card_back_11", "type": "sleeve", "name": "Card Back 11", "price": 5, "source": "shop"},
	{"id": "card_back_12", "type": "sleeve", "name": "Card Back 12", "price": 5, "source": "shop"},
	{"id": "test_tree_card_back_1", "type": "sleeve", "name": "Test Tree", "price": 5, "source": "shop"},
	{"id": "nay3920_A_spiral_galaxy_in_all_its_colors_and_glory__Animate__fa4650b7-7b52-4133-bd9d-a83c10de61b9_3", "type": "sleeve", "name": "Spiral Galaxy", "price": 5, "source": "shop"},
	{"id": "nay3920_Purple_Galaxy_spiraling_smoothly_and_having_some_gas__9633d83a-4a40-4750-afc8-50b7c97531ae_3", "type": "sleeve", "name": "Purple Galaxy", "price": 5, "source": "shop"},
	# --- admin-only: never auto-granted, awarded by hand or as a tournament
	# prize via the admin tool. card_back_5/8/9 flagged this way on request;
	# frame_champion/avatar_champion/title_champion are placeholders that were
	# never actually wired to an achievement tier below, so they belong here
	# too, not under "achievement".
	{"id": "card_back_5",      "type": "sleeve", "name": "Card Back 5",   "price": 0, "source": "admin"},
	{"id": "card_back_8",      "type": "sleeve", "name": "Card Back 8",   "price": 0, "source": "admin"},
	{"id": "card_back_9",      "type": "sleeve", "name": "Card Back 9",   "price": 0, "source": "admin"},
	{"id": "frame_champion",   "type": "frame",  "name": "Champion",      "price": 0, "source": "admin"},
	{"id": "avatar_champion",  "type": "avatar", "name": "Grand Champion","price": 0, "source": "admin"},
	{"id": "title_champion",   "type": "title",  "name": "Champion",      "price": 0, "source": "admin"},
	# --- achievement-only: auto-granted by clearing the achievement tier that
	# names it as a `reward` (see achievement_system.gd); not buyable ---
	{"id": "frame_veteran",    "type": "frame",      "name": "Veteran",       "price": 0, "source": "achievement"},
	{"id": "sleeve_flame",     "type": "sleeve",     "name": "Flame",         "price": 0, "source": "achievement"},
	# Frame rewards for the low-end ranked-loss ladder (art: res://assets/avatars/avatar_frame/<id>.png).
	{"id": "frame1", "type": "frame", "name": "First Ranked Loss", "price": 0, "source": "achievement"},
	{"id": "frame3", "type": "frame", "name": "5 Ranked Losses",   "price": 0, "source": "achievement"},
	{"id": "frame2", "type": "frame", "name": "10 Ranked Losses",  "price": 0, "source": "achievement"},
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


## Human-readable label for any cosmetic id, for display in the shop and the
## avatar picker. Catalog items (shop/achievement/admin) use the `name` set
## above; free/default items (never added to CATALOG) have no name field, so
## this derives a readable placeholder from the filename instead — rename
## specific ones by adding a CATALOG entry with price 0 and source "default".
static func display_name_for(id: String, type: String) -> String:
	var def := def_for(id)
	if not def.is_empty():
		return str(def.name)
	return _humanize(id, type)


static func _humanize(id: String, type: String) -> String:
	var s := id
	if type == "background" and s.begins_with("avatar_bg_"):
		s = s.substr("avatar_bg_".length())
	elif type == "table_background" and s.begins_with("table_game_canvas_"):
		return "Table " + s.substr("table_game_canvas_".length())
	var re := RegEx.new()
	re.compile("([a-zA-Z])([0-9])")
	s = re.sub(s, "$1 $2", true)
	return s.capitalize()
