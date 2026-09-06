class_name AchievementSystem
extends RefCounted

const CATALOG: Array = [
	{"id": "veteran",     "name": "Veteran",      "stat": "games",               "tiers": [
		{"threshold": 10,    "points": 20,  "reward": ""},
		{"threshold": 100,   "points": 100, "reward": ""},
		{"threshold": 1000,  "points": 500, "reward": "frame_veteran"},
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
	{"id": "high_roller", "name": "High Roller",  "stat": "points_earned_total", "tiers": [
		{"threshold": 1000,  "points": 0,   "reward": ""},
		{"threshold": 10000, "points": 100, "reward": ""},
		{"threshold": 100000, "points": 500, "reward": ""},
	]},

	# --- Single-tier milestone achievements (user set, 2026-09-06) --------------
	# Each is its own catalog entry / art asset (assets/achievements/<id>.png),
	# one threshold, points only (no cosmetic reward). The generic evaluate/rows
	# code handles a 1-element `tiers` array the same as a 3-element one.

	# Ranked wins — stat `wins` (ranked human-vs-human only, see PLAN_achievements §2)
	{"id": "ranked_win_1",    "name": "First Ranked Win",   "stat": "wins", "tiers": [{"threshold": 1,    "points": 10,   "reward": ""}]},
	{"id": "ranked_win_5",    "name": "5 Ranked Wins",      "stat": "wins", "tiers": [{"threshold": 5,    "points": 25,   "reward": ""}]},
	{"id": "ranked_win_10",   "name": "10 Ranked Wins",     "stat": "wins", "tiers": [{"threshold": 10,   "points": 50,   "reward": ""}]},
	{"id": "ranked_win_30",   "name": "30 Ranked Wins",     "stat": "wins", "tiers": [{"threshold": 30,   "points": 100,  "reward": ""}]},
	{"id": "ranked_win_50",   "name": "50 Ranked Wins",     "stat": "wins", "tiers": [{"threshold": 50,   "points": 150,  "reward": ""}]},
	{"id": "ranked_win_100",  "name": "100 Ranked Wins",    "stat": "wins", "tiers": [{"threshold": 100,  "points": 300,  "reward": ""}]},
	{"id": "ranked_win_250",  "name": "250 Ranked Wins",    "stat": "wins", "tiers": [{"threshold": 250,  "points": 600,  "reward": ""}]},
	{"id": "ranked_win_500",  "name": "500 Ranked Wins",    "stat": "wins", "tiers": [{"threshold": 500,  "points": 1200, "reward": ""}]},
	{"id": "ranked_win_1000", "name": "1000 Ranked Wins",   "stat": "wins", "tiers": [{"threshold": 1000, "points": 2500, "reward": ""}]},

	# Ranked losses — stat `losses` (same thresholds/points as wins, user's call)
	{"id": "ranked_loss_1",    "name": "First Ranked Loss",  "stat": "losses", "tiers": [{"threshold": 1,    "points": 10,   "reward": ""}]},
	{"id": "ranked_loss_5",    "name": "5 Ranked Losses",    "stat": "losses", "tiers": [{"threshold": 5,    "points": 25,   "reward": ""}]},
	{"id": "ranked_loss_10",   "name": "10 Ranked Losses",   "stat": "losses", "tiers": [{"threshold": 10,   "points": 50,   "reward": ""}]},
	{"id": "ranked_loss_30",   "name": "30 Ranked Losses",   "stat": "losses", "tiers": [{"threshold": 30,   "points": 100,  "reward": "30_ranked_losses_avatar"}]},
	{"id": "ranked_loss_50",   "name": "50 Ranked Losses",   "stat": "losses", "tiers": [{"threshold": 50,   "points": 150,  "reward": "50_ranked_losses_avatar"}]},
	{"id": "ranked_loss_100",  "name": "100 Ranked Losses",  "stat": "losses", "tiers": [{"threshold": 100,  "points": 300,  "reward": "100_ranked_losses_avatar"}]},
	{"id": "ranked_loss_250",  "name": "250 Ranked Losses",  "stat": "losses", "tiers": [{"threshold": 250,  "points": 600,  "reward": ""}]},
	{"id": "ranked_loss_500",  "name": "500 Ranked Losses",  "stat": "losses", "tiers": [{"threshold": 500,  "points": 1200, "reward": ""}]},
	{"id": "ranked_loss_1000", "name": "1000 Ranked Losses", "stat": "losses", "tiers": [{"threshold": 1000, "points": 2500, "reward": ""}]},

	# Tournament wins — stat `tournaments_won` (bumped by apply_tournament_stat)
	{"id": "tourney_win_1",   "name": "1 Tournament Win",    "stat": "tournaments_won", "tiers": [{"threshold": 1,   "points": 100,  "reward": ""}]},
	{"id": "tourney_win_5",   "name": "5 Tournament Wins",   "stat": "tournaments_won", "tiers": [{"threshold": 5,   "points": 300,  "reward": ""}]},
	{"id": "tourney_win_10",  "name": "10 Tournament Wins",  "stat": "tournaments_won", "tiers": [{"threshold": 10,  "points": 600,  "reward": ""}]},
	{"id": "tourney_win_25",  "name": "25 Tournament Wins",  "stat": "tournaments_won", "tiers": [{"threshold": 25,  "points": 1200, "reward": ""}]},
	{"id": "tourney_win_50",  "name": "50 Tournament Wins",  "stat": "tournaments_won", "tiers": [{"threshold": 50,  "points": 2500, "reward": ""}]},
	{"id": "tourney_win_100", "name": "100 Tournament Wins", "stat": "tournaments_won", "tiers": [{"threshold": 100, "points": 5000, "reward": ""}]},

	# Quests completed — stat `quests_completed` (bumped by apply_quest_progress).
	# Ids match the art files in assets/achievements/ (quests_completed_*.png).
	{"id": "quests_completed_5",    "name": "5 Quests Completed",    "stat": "quests_completed", "tiers": [{"threshold": 5,    "points": 50,   "reward": ""}]},
	{"id": "quests_completed_10",   "name": "10 Quests Completed",   "stat": "quests_completed", "tiers": [{"threshold": 10,   "points": 100,  "reward": ""}]},
	{"id": "quests_completed_25",   "name": "25 Quests Completed",   "stat": "quests_completed", "tiers": [{"threshold": 25,   "points": 250,  "reward": ""}]},
	{"id": "quests_completed_100",  "name": "100 Quests Completed",  "stat": "quests_completed", "tiers": [{"threshold": 100,  "points": 800,  "reward": ""}]},
	{"id": "quests_completed_250",  "name": "250 Quests Completed",  "stat": "quests_completed", "tiers": [{"threshold": 250,  "points": 1800, "reward": ""}]},
	{"id": "quests_completed_1000", "name": "1000 Quests Completed", "stat": "quests_completed", "tiers": [{"threshold": 1000, "points": 6000, "reward": ""}]},

	# Tournaments created — stat `tournaments_created` (bumped on tournament
	# creation). Ids match assets/achievements/tourney_created_*.png.
	{"id": "tourney_created_5",   "name": "5 Tournaments Created",   "stat": "tournaments_created", "tiers": [{"threshold": 5,   "points": 50,   "reward": ""}]},
	{"id": "tourney_created_15",  "name": "15 Tournaments Created",  "stat": "tournaments_created", "tiers": [{"threshold": 15,  "points": 150,  "reward": ""}]},
	{"id": "tourney_created_50",  "name": "50 Tournaments Created",  "stat": "tournaments_created", "tiers": [{"threshold": 50,  "points": 500,  "reward": ""}]},
	{"id": "tourney_created_100", "name": "100 Tournaments Created", "stat": "tournaments_created", "tiers": [{"threshold": 100, "points": 1000, "reward": ""}]},
	{"id": "tourney_created_250", "name": "250 Tournaments Created", "stat": "tournaments_created", "tiers": [{"threshold": 250, "points": 2500, "reward": ""}]},
	{"id": "tourney_created_500", "name": "500 Tournaments Created", "stat": "tournaments_created", "tiers": [{"threshold": 500, "points": 5000, "reward": ""}]},
]

const TIER_NAMES := ["Bronze", "Silver", "Gold"]


## Display name for a tier. Single-tier (milestone) achievements have no
## Bronze/Silver/Gold distinction, so they return "".
static func tier_name_for(tier_idx: int, tier_total: int) -> String:
	if tier_total <= 1:
		return ""
	if tier_idx >= 0 and tier_idx < TIER_NAMES.size():
		return TIER_NAMES[tier_idx]
	return "Tier %d" % (tier_idx + 1)


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
					"tier_name": tier_name_for(tier_idx, tiers.size()),
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
			"tier_total": tiers.size(),
			"next_threshold": next_threshold,
			"maxed": maxed,
			"reward_on_final": reward_on_final,
		})

	return rows_out
