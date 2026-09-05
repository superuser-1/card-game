class_name AchievementSystem
extends RefCounted

const CATALOG: Array = [
	{"id": "veteran",     "name": "Veteran",      "stat": "games",               "tiers": [
		{"threshold": 10,    "points": 20,  "reward": ""},
		{"threshold": 100,   "points": 100, "reward": ""},
		{"threshold": 1000,  "points": 500, "reward": "frame_veteran"},
	]},
	{"id": "winner",      "name": "Winner",       "stat": "wins",                "tiers": [
		{"threshold": 10,    "points": 20,  "reward": ""},
		{"threshold": 100,   "points": 150, "reward": ""},
		{"threshold": 1000,  "points": 750, "reward": "avatar_champion"},
	]},
	{"id": "on_fire",     "name": "On Fire",      "stat": "win_streak_best",     "tiers": [
		{"threshold": 3,     "points": 20,  "reward": ""},
		{"threshold": 5,     "points": 60,  "reward": ""},
		{"threshold": 10,    "points": 200, "reward": "sleeve_flame"},
	]},
	{"id": "perfectionist", "name": "Perfectionist", "stat": "perfect_wins",     "tiers": [
		{"threshold": 1,     "points": 30,  "reward": ""},
		{"threshold": 10,    "points": 120, "reward": ""},
		{"threshold": 50,    "points": 400, "reward": ""},
	]},
	{"id": "tycoon",      "name": "Tycoon",       "stat": "money_games_won",     "tiers": [
		{"threshold": 5,     "points": 30,  "reward": ""},
		{"threshold": 25,    "points": 100, "reward": ""},
		{"threshold": 100,   "points": 300, "reward": ""},
	]},
	{"id": "historian",   "name": "Historian",    "stat": "time_games_won",      "tiers": [
		{"threshold": 5,     "points": 30,  "reward": ""},
		{"threshold": 25,    "points": 100, "reward": ""},
		{"threshold": 100,   "points": 300, "reward": ""},
	]},
	{"id": "laureate",    "name": "Laureate",     "stat": "awards_games_won",    "tiers": [
		{"threshold": 5,     "points": 30,  "reward": ""},
		{"threshold": 25,    "points": 100, "reward": ""},
		{"threshold": 100,   "points": 300, "reward": ""},
	]},
	{"id": "competitor",  "name": "Competitor",   "stat": "tournaments_played",  "tiers": [
		{"threshold": 1,     "points": 20,  "reward": ""},
		{"threshold": 10,    "points": 100, "reward": ""},
		{"threshold": 50,    "points": 400, "reward": ""},
	]},
	{"id": "champion",    "name": "Champion",     "stat": "tournaments_won",     "tiers": [
		{"threshold": 1,     "points": 100, "reward": ""},
		{"threshold": 5,     "points": 300, "reward": ""},
		{"threshold": 25,    "points": 1000, "reward": "frame_champion"},
	]},
	{"id": "high_roller", "name": "High Roller",  "stat": "points_earned_total", "tiers": [
		{"threshold": 1000,  "points": 0,   "reward": ""},
		{"threshold": 10000, "points": 100, "reward": ""},
		{"threshold": 100000, "points": 500, "reward": ""},
	]},
]

const TIER_NAMES := ["Bronze", "Silver", "Gold"]


static func def_for(id: String) -> Dictionary:
	for ach in CATALOG:
		if str(ach.id) == id:
			return ach
	return {}


## unlocked: { achid: highest_tier_index_reached }  (missing key => -1)
## Returns:
##   {"unlocked": Dictionary,              -- updated
##    "newly":   Array of {id, name, tier_index, tier_name, points, reward},
##    "points_awarded": int,
##    "reward_ids": Array of String}       -- non-empty tier rewards, for grant_reward
static func evaluate(stats: Dictionary, unlocked: Dictionary) -> Dictionary:
	var new_unlocked := unlocked.duplicate()
	var newly := []
	var points_awarded := 0
	var reward_ids := []

	for ach in CATALOG:
		var ach_id := str(ach.id)
		var stat_key := str(ach.stat)
		var current_val := int(stats.get(stat_key, 0))
		var highest_tier := int(new_unlocked.get(ach_id, -1))
		var tiers: Array = ach.get("tiers", [])

		for tier_idx in range(tiers.size()):
			if tier_idx <= highest_tier:
				continue
			var tier: Dictionary = tiers[tier_idx]
			var threshold := int(tier.get("threshold", 0))
			if current_val >= threshold:
				new_unlocked[ach_id] = tier_idx
				var points := int(tier.get("points", 0))
				var reward := str(tier.get("reward", ""))
				newly.append({
					"id": ach_id,
					"name": str(ach.name),
					"tier_index": tier_idx,
					"tier_name": TIER_NAMES[tier_idx] if tier_idx < TIER_NAMES.size() else "Unknown",
					"points": points,
					"reward": reward,
				})
				points_awarded += points
				if reward != "":
					reward_ids.append(reward)

	return {
		"unlocked": new_unlocked,
		"newly": newly,
		"points_awarded": points_awarded,
		"reward_ids": reward_ids,
	}


## Display rows for the client screen — current stat value, tiers done,
## next threshold, whether maxed.
static func rows(stats: Dictionary, unlocked: Dictionary) -> Array:
	var rows_out := []
	for ach in CATALOG:
		var ach_id := str(ach.id)
		var stat_key := str(ach.stat)
		var current_val := int(stats.get(stat_key, 0))
		var highest_tier := int(unlocked.get(ach_id, -1))
		var tiers: Array = ach.get("tiers", [])

		var tiers_done := highest_tier + 1
		var next_threshold := 0
		var maxed := highest_tier >= int(tiers.size()) - 1

		if not maxed and highest_tier + 1 < tiers.size():
			next_threshold = int(tiers[highest_tier + 1].get("threshold", 0))

		var reward_on_final := ""
		if tiers.size() > 0:
			reward_on_final = str(tiers[tiers.size() - 1].get("reward", ""))

		rows_out.append({
			"id": ach_id,
			"name": str(ach.name),
			"stat": stat_key,
			"current_value": current_val,
			"tiers_done": tiers_done,
			"next_threshold": next_threshold,
			"maxed": maxed,
			"reward_on_final": reward_on_final,
		})

	return rows_out
