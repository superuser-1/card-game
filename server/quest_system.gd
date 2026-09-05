class_name QuestSystem
extends RefCounted

const CATALOG: Array = [
	{"id": "win_1",        "type": "wins",         "target": 1,  "points": 10,  "name": "Win a Game"},
	{"id": "win_3",        "type": "wins",         "target": 3,  "points": 40,  "name": "Win 3 Games"},
	{"id": "win_10",       "type": "wins",         "target": 10, "points": 150, "name": "Win 10 Games"},
	{"id": "perfect_win",  "type": "perfect_win",  "target": 1,  "points": 50,  "name": "Win a Perfect Game (7–0)"},
	{"id": "perfect_loss", "type": "perfect_loss", "target": 1,  "points": 60,  "name": "Lose a Game 0–7"},
	{"id": "money_game",   "type": "group_win", "group": "money", "min_picks": 2, "target": 1, "points": 40, "name": "Win a Money Game"},
	{"id": "time_game",    "type": "group_win", "group": "time",  "min_picks": 2, "target": 1, "points": 40, "name": "Win a Time Game"},
]

const DAILY_COUNT := 3

## UTC "YYYY-MM-DD". Pass a fixed unix time in tests; -1 = now.
static func today_key(unix_time: float = -1.0) -> String:
	var t := unix_time if unix_time >= 0.0 else Time.get_unix_time_from_system()
	var d := Time.get_datetime_dict_from_unix_time(int(t))
	return "%04d-%02d-%02d" % [d.year, d.month, d.day]

## The quest definition for an id, or {} if unknown.
static func def_for(id: String) -> Dictionary:
	for q in CATALOG:
		if str(q.id) == id:
			return q
	return {}

## Deterministic per-UTC-day pick of DAILY_COUNT quest ids. Same for everyone on
## a given date; stable across restarts (seeded by the date string). Array order
## is the display order.
static func daily_quest_ids(day: String) -> Array:
	var ids := []
	for q in CATALOG:
		ids.append(str(q.id))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(day)
	for i in range(ids.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = ids[i]
		ids[i] = ids[j]
		ids[j] = tmp
	return ids.slice(0, min(DAILY_COUNT, ids.size()))

## { qid: {"progress": 0, "completed": false} } for the active quest ids.
static func fresh_state(active_ids: Array) -> Dictionary:
	var s := {}
	for id in active_ids:
		s[id] = {"progress": 0, "completed": false}
	return s

## Normalise an account's stored quests dict for `day`. Shape:
##   {"day": String, "active_ids": Array, "state": Dictionary}
## Resets state when the day rolled or the stored shape is missing/garbage;
## otherwise keeps it and backfills any newly-added catalog ids. Never saves.
static func ensure_day(quests, day: String) -> Dictionary:
	var active_ids := daily_quest_ids(day)
	if typeof(quests) != TYPE_DICTIONARY \
			or str(quests.get("day", "")) != day \
			or typeof(quests.get("state")) != TYPE_DICTIONARY:
		return {"day": day, "active_ids": active_ids, "state": fresh_state(active_ids)}
	# Same day: keep earned progress, reconcile to the current active set.
	var old_state: Dictionary = quests["state"]
	var state := {}
	for id in active_ids:
		state[id] = old_state.get(id, {"progress": 0, "completed": false})
	return {"day": day, "active_ids": active_ids, "state": state}

## match_ctx (all keys required):
##   "outcome": "win" | "loss" | "draw"
##   "your_score": int
##   "opp_score": int
##   "your_group_picks": {"money": int, "time": int, "awards": int}
##       -- categories THIS player chose (as active player), bucketed by group
##   "your_pick_count": int   -- total categories THIS player chose
##
## Returns:
##   {"state": Dictionary (deep copy, updated),
##    "completed": Array of {id, name, points}   -- flipped false->true this call,
##    "points_awarded": int}
static func evaluate(state: Dictionary, match_ctx: Dictionary) -> Dictionary:
	var out_state: Dictionary = state.duplicate(true)
	var completed := []
	var points := 0
	for id in out_state.keys():
		var q := def_for(id)
		if q.is_empty():
			continue
		var qs: Dictionary = out_state[id]
		if bool(qs.get("completed", false)):
			continue
		var inc := _progress_for(q, match_ctx)
		if inc > 0:
			qs["progress"] = min(int(qs.get("progress", 0)) + inc, int(q.target))
		if int(qs["progress"]) >= int(q.target):
			qs["completed"] = true
			completed.append({"id": id, "name": q.name, "points": int(q.points)})
			points += int(q.points)
	return {"state": out_state, "completed": completed, "points_awarded": points}

static func _progress_for(q: Dictionary, ctx: Dictionary) -> int:
	match str(q.type):
		"wins":
			return 1 if str(ctx.outcome) == "win" else 0
		"perfect_win":
			return 1 if (str(ctx.outcome) == "win" and int(ctx.opp_score) == 0 and int(ctx.your_score) >= 7) else 0
		"perfect_loss":
			return 1 if (str(ctx.outcome) == "loss" and int(ctx.your_score) == 0 and int(ctx.opp_score) >= 7) else 0
		"group_win":
			if str(ctx.outcome) != "win":
				return 0
			var picks: Dictionary = ctx.your_group_picks
			var in_group := int(picks.get(str(q.group), 0))
			if in_group >= int(q.min_picks) and in_group == int(ctx.your_pick_count):
				return 1
			return 0
	return 0
