class_name ServerStore
extends RefCounted
## Persistence layer for the authoritative headless server. Two JSON files under
## `_dir` (default `user://flickbattle/`): `accounts.json` = {"accounts":[...]}
## and `matches.json` = {"matches":[...]}. Everything is held in memory and the
## whole relevant file is rewritten on each mutation — fine at the scale we need;
## a SQLite backend is a later drop-in behind this same API.
##
## Pure logic module: no Node/scene deps, mirrors the rules/ style. The Elo,
## points and password-hash helpers are `static` so they can be unit-tested
## without touching disk.
##
## SECURITY NOTE: the password hash here is salted iterated SHA-256, which is
## adequate for a dev build but NOT production-grade. Replace with Argon2id or
## bcrypt via a native addon before any real launch.

const START_ELO := 1000
const PROVISIONAL_GAMES := 10
const HASH_ITERATIONS := 200000

# DEV: relaxed for local testing. Bump back to 3 / 6 before any real launch.
const MIN_USERNAME_LEN := 1
const MIN_PASSWORD_LEN := 1

var _dir: String
var _accounts: Array
var _matches: Array
var _tournaments: Array
var _next_account_id: int
var _next_match_id: int
var _next_tournament_id: int


func open(dir := "user://flickbattle/") -> void:
	_dir = dir
	_accounts = []
	_matches = []
	_tournaments = []
	_next_account_id = 1
	_next_match_id = 1
	_next_tournament_id = 1

	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var accounts_path := dir + "accounts.json"
	if FileAccess.file_exists(accounts_path):
		var file := FileAccess.open(accounts_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary and parsed.has("accounts"):
				_accounts = parsed["accounts"]
				for account in _accounts:
					if int(account.get("id", 0)) >= _next_account_id:
						_next_account_id = int(account["id"]) + 1
				_backfill_all_achievement_rewards()
	else:
		_save_accounts()

	var matches_path := dir + "matches.json"
	if FileAccess.file_exists(matches_path):
		var file := FileAccess.open(matches_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary and parsed.has("matches"):
				_matches = parsed["matches"]
				for m in _matches:
					if int(m.get("id", 0)) >= _next_match_id:
						_next_match_id = int(m["id"]) + 1
	else:
		_save_matches()

	var tournaments_path := dir + "tournaments.json"
	if FileAccess.file_exists(tournaments_path):
		var file := FileAccess.open(tournaments_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary and parsed.has("tournaments"):
				_tournaments = parsed["tournaments"]
				var migrated := false
				# Back-fill fields added by the availability / late-check-in
				# rework onto tournaments persisted before it.
				var defaults := {
					"availability": "open", "pw_salt": "", "pw_hash": "",
					"pw_iterations": 0, "private_signup_close_ts": 0, "late_check_in": false,
					"late_check_in_open_ts": 0, "prizes": {}, "prize_escrow": 0,
					"escrow_refunded": false, "prizes_paid": false,
				}
				for t in _tournaments:
					if int(t.get("id", 0)) >= _next_tournament_id:
						_next_tournament_id = int(t["id"]) + 1
					for k in defaults:
						if not t.has(k):
							t[k] = defaults[k]
							migrated = true
				if migrated:
					_save_tournaments()
	else:
		_save_tournaments()


# --- auth ------------------------------------------------------------------

func username_taken(username: String) -> bool:
	var lower := username.to_lower()
	for account in _accounts:
		if str(account.get("username_lower", "")) == lower:
			return true
	return false


func create_account(username: String, password: String, avatar := "") -> Dictionary:
	if not _valid_username(username):
		return {"ok": false, "error": "bad_username", "account": {}}
	if password.length() < MIN_PASSWORD_LEN or password.length() > 72:
		return {"ok": false, "error": "bad_password", "account": {}}
	if username_taken(username):
		return {"ok": false, "error": "username_taken", "account": {}}

	# Empty by default — the client prompts for an avatar as a first-login
	# onboarding step (see main_menu / Avatars.needs_choice) and calls
	# set_avatar() once the player picks one.
	var avatar_id := avatar.strip_edges()
	if avatar_id.length() > 40:
		avatar_id = ""

	var hashed := hash_password(password)
	var account := {
		"id": _next_account_id,
		"username": username,
		"username_lower": username.to_lower(),
		"display_name": username,
		"avatar": avatar_id,
		"frame": "",
		"background": "",
		"sleeve": "",
		"auth_provider": "password",
		"pw_salt": hashed["salt"],
		"pw_hash": hashed["hash"],
		"pw_iterations": hashed["iterations"],
		"elo": START_ELO,
		"games": 0,
		"wins": 0,
		"losses": 0,
		"draws": 0,
		"points": 0,
		"owned_rewards": ["sleeve_classic"],
		"season_id": 1,
		"created_ts": int(Time.get_unix_time_from_system()),
		"quests": {"day": "", "state": {}},
		"stats": {},
		"achievements": {"unlocked": {}},
		"is_admin": false,
	}
	_accounts.append(account)
	_next_account_id += 1
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


func verify_login(username: String, password: String) -> Dictionary:
	var lower := username.to_lower()
	var account := {}
	for acc in _accounts:
		if str(acc.get("username_lower", "")) == lower:
			account = acc
			break
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}

	var ok := verify_password(
		password,
		str(account.get("pw_salt", "")),
		str(account.get("pw_hash", "")),
		int(account.get("pw_iterations", HASH_ITERATIONS))
	)
	if not ok:
		return {"ok": false, "error": "bad_credentials", "account": {}}
	return {"ok": true, "error": "", "account": account}


func get_account(id: int) -> Dictionary:
	for account in _accounts:
		if int(account.get("id", -1)) == id:
			return account
	return {}


## Store a chosen avatar id on an existing account. The id is trusted only as
## far as shape here (non-empty, <=40 chars); the RPC layer runs it through
## Avatars.sanitize first so only real ids reach disk.
func set_avatar(account_id: int, avatar_id: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean := avatar_id.strip_edges()
	if clean == "" or clean.length() > 40:
		return {"ok": false, "error": "bad_avatar", "account": {}}
	if ShopCatalog.is_premium(clean) and clean not in account.get("owned_rewards", []):
		return {"ok": false, "error": "not_owned", "account": {}}
	account["avatar"] = clean
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


## Store a chosen frame id on an existing account. Unlike avatars, "" (no
## frame) is a valid choice — it un-equips whatever frame was set. The RPC
## layer runs the id through Frames.sanitize first so only real ids (or "")
## reach disk.
func set_frame(account_id: int, frame_id: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean := frame_id.strip_edges()
	if clean.length() > 40:
		return {"ok": false, "error": "bad_frame", "account": {}}
	if ShopCatalog.is_premium(clean) and clean not in account.get("owned_rewards", []):
		return {"ok": false, "error": "not_owned", "account": {}}
	account["frame"] = clean
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


## Store a chosen background id on an existing account. Unlike avatars, ""
## (no background) is a valid choice — it un-equips whatever background was
## set. The RPC layer runs the id through Backgrounds.sanitize first so only
## real ids (or "") reach disk.
func set_background(account_id: int, background_id: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean := background_id.strip_edges()
	if clean.length() > 40:
		return {"ok": false, "error": "bad_background", "account": {}}
	if ShopCatalog.is_premium(clean) and clean not in account.get("owned_rewards", []):
		return {"ok": false, "error": "not_owned", "account": {}}
	account["background"] = clean
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


## Store a chosen sleeve id (face-down card art) on an existing account. Unlike
## avatars, "" (no sleeve/use default) is a valid choice — it un-equips whatever
## sleeve was set. The RPC layer runs the id through Sleeves.sanitize first so
## only real ids (or "") reach disk.
func set_sleeve(account_id: int, sleeve_id: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean := sleeve_id.strip_edges()
	if clean.length() > 40:
		return {"ok": false, "error": "bad_sleeve", "account": {}}
	if ShopCatalog.is_premium(clean) and clean not in account.get("owned_rewards", []):
		return {"ok": false, "error": "not_owned", "account": {}}
	account["sleeve"] = clean
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


func account_snapshot(account: Dictionary) -> Dictionary:
	_ensure_stats(account)
	return {
		"id": account.get("id"),
		"username": account.get("username"),
		"display_name": account.get("display_name"),
		"avatar": account.get("avatar", ""),
		"frame": account.get("frame", ""),
		"background": account.get("background", ""),
		"sleeve": account.get("sleeve", ""),
		"elo": account.get("elo"),
		"games": account.get("games"),
		"wins": account.get("wins"),
		"losses": account.get("losses"),
		"draws": account.get("draws"),
		"points": account.get("points"),
		"owned_rewards": (account.get("owned_rewards", []) as Array).duplicate(),
		"is_provisional": int(account.get("games", 0)) < PROVISIONAL_GAMES,
		"quests": _quest_rows(QuestSystem.ensure_day(account.get("quests", {}), QuestSystem.today_key())),
		"stats": (account.get("stats", {}) as Dictionary).duplicate(),
		"achievements": {
			"unlocked": (account.get("achievements", {}).get("unlocked", {}) as Dictionary).duplicate()
		},
	}


## Roll the daily reset if needed, then apply ONE finished match's result to this
## account's quests. Mutates + persists the account (adds any earned points to
## account["points"] — the same pool shop purchases spend). Caller MUST only
## invoke this for ranked, non-bot, human matches (see net_node._finish_match).
## Returns:
##   {"completed": Array of {id, name, points},
##    "points_awarded": int,
##    "points_total": int,          -- account points AFTER the award
##    "quests": Array}              -- display rows, same shape as _quest_rows
func apply_quest_progress(account_id: int, match_ctx: Dictionary, day_override := "") -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		push_error("ServerStore.apply_quest_progress: account not found: %d" % account_id)
		return {"completed": [], "points_awarded": 0, "points_total": 0, "quests": []}

	var day := day_override if day_override != "" else QuestSystem.today_key()
	var normalised := QuestSystem.ensure_day(account.get("quests", {}), day)
	var res := QuestSystem.evaluate(normalised["state"], match_ctx)
	normalised["state"] = res["state"]
	account["quests"] = normalised
	if int(res["points_awarded"]) > 0:
		account["points"] = int(account.get("points", 0)) + int(res["points_awarded"])

	# Lifetime quest-completion counter, feeds the `quests_completed_*` achievements.
	# Achievement evaluation itself happens in apply_match_stats, which
	# net_node._finish_match always calls right after this for the same account.
	var completed_now := int((res["completed"] as Array).size())
	if completed_now > 0:
		_ensure_stats(account)
		var stats: Dictionary = account["stats"]
		stats["quests_completed"] = int(stats.get("quests_completed", 0)) + completed_now

	_save_accounts()

	return {
		"completed": res["completed"],
		"points_awarded": int(res["points_awarded"]),
		"points_total": int(account.get("points", 0)),
		"quests": _quest_rows(normalised),
	}


## Credit `points_award` into account["points"] and grant every id in
## `item_ids` the account does not already own. Persists. Returns
## {"points_total": int, "granted": Array of newly-owned ids}.
func grant_reward(account: Dictionary, points_award: int, item_ids: Array) -> Dictionary:
	if int(points_award) > 0:
		account["points"] = int(account.get("points", 0)) + int(points_award)
	var granted := []
	var owned: Array = account.get("owned_rewards", [])
	for id in item_ids:
		var id_str := str(id)
		if id_str != "" and id_str not in owned:
			owned.append(id_str)
			granted.append(id_str)
	_save_accounts()
	return {
		"points_total": int(account.get("points", 0)),
		"granted": granted,
	}


## Purchase a shop item. Returns error dict if the purchase fails, or
## {"ok": true, "error": "", "account": account} on success.
func purchase(account_id: int, item_id: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}

	var def := ShopCatalog.def_for(item_id)
	if def.is_empty():
		return {"ok": false, "error": "no_such_item", "account": {}}
	if str(def.source) != "shop":
		return {"ok": false, "error": "not_for_sale", "account": {}}

	var owned: Array = account.get("owned_rewards", [])
	if item_id in owned:
		return {"ok": false, "error": "already_owned", "account": {}}

	var price := int(def.price)
	var points := int(account.get("points", 0))
	if points < price:
		return {"ok": false, "error": "insufficient", "account": {}}

	account["points"] = points - price
	owned.append(item_id)
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


## Runs backfill_achievement_rewards across every loaded account, once, at
## server startup — catches rewards added to tiers players already cleared.
func _backfill_all_achievement_rewards() -> void:
	for account in _accounts:
		backfill_achievement_rewards(account)


## Grant any reward whose achievement tier the account already has unlocked
## but never received the item for — happens when a reward id is added to a
## tier after players already cleared it (evaluate() only looks at tiers
## past the recorded high-water mark, so it can't catch these on its own).
## Idempotent; safe to call on every account at server startup.
func backfill_achievement_rewards(account: Dictionary) -> Array:
	_ensure_stats(account)
	var reward_ids: Array = AchievementSystem.reward_ids_for_unlocked(account["achievements"]["unlocked"])
	if reward_ids.is_empty():
		return []
	return grant_reward(account, 0, reward_ids)["granted"]


## Ensure account has stats and achievements dicts initialized.
func _ensure_stats(account: Dictionary) -> void:
	if not account.has("stats") or typeof(account["stats"]) != TYPE_DICTIONARY:
		account["stats"] = {}
	if not account.has("achievements") or typeof(account["achievements"]) != TYPE_DICTIONARY:
		account["achievements"] = {"unlocked": {}}
	if not account["achievements"].has("unlocked"):
		account["achievements"]["unlocked"] = {}


## Apply a ranked, non-bot match result to this account's stats and achievements.
## Mutates + persists the account. Called from net_node._finish_match.
## Returns:
##   {"achievement_unlocks": Array, "achievement_points": int}
func apply_match_stats(account_id: int, match_ctx: Dictionary) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		push_error("ServerStore.apply_match_stats: account not found: %d" % account_id)
		return {"achievement_unlocks": [], "achievement_points": 0}

	_ensure_stats(account)
	var stats: Dictionary = account["stats"]

	# Bump match counters
	stats["games"] = int(stats.get("games", 0)) + 1
	match str(match_ctx.get("outcome", "")):
		"win":
			stats["wins"] = int(stats.get("wins", 0)) + 1
			stats["win_streak_current"] = int(stats.get("win_streak_current", 0)) + 1
		"loss":
			stats["losses"] = int(stats.get("losses", 0)) + 1
			stats["win_streak_current"] = 0
		"draw":
			stats["draws"] = int(stats.get("draws", 0)) + 1
			stats["win_streak_current"] = 0

	# Update best streak
	var current_streak := int(stats.get("win_streak_current", 0))
	var best_streak := int(stats.get("win_streak_best", 0))
	if current_streak > best_streak:
		stats["win_streak_best"] = current_streak

	# Perfect win: your_score >= 7 && opp_score == 0 && outcome == win
	if str(match_ctx.get("outcome", "")) == "win" \
			and int(match_ctx.get("your_score", 0)) >= 7 \
			and int(match_ctx.get("opp_score", 0)) == 0:
		stats["perfect_wins"] = int(stats.get("perfect_wins", 0)) + 1

	# Group wins (money/time/awards)
	var picks: Dictionary = match_ctx.get("your_group_picks", {})
	var pick_count := int(match_ctx.get("your_pick_count", 0))
	if str(match_ctx.get("outcome", "")) == "win":
		for group in ["money", "time", "awards"]:
			var in_group := int(picks.get(group, 0))
			if in_group >= 2 and in_group == pick_count:
				var key := "%s_games_won" % group
				stats[key] = int(stats.get(key, 0)) + 1

	# Points earned total — the amount actually banked for this match, computed
	# once in _finish_match and handed down so achievements and the wallet
	# never disagree.
	var match_points := int(match_ctx.get("match_points_awarded", 0))
	stats["points_earned_total"] = int(stats.get("points_earned_total", 0)) + match_points

	# Evaluate achievements
	var ach_res := AchievementSystem.evaluate(stats, account["achievements"]["unlocked"])
	account["achievements"]["unlocked"] = ach_res["unlocked"]

	# Grant rewards (do NOT include achievement payouts in points_earned_total)
	grant_reward(account, int(ach_res["points_awarded"]), ach_res["reward_ids"])

	return {
		"achievement_unlocks": ach_res["newly"],
		"achievement_points": int(ach_res["points_awarded"]),
	}


## Apply a tournament stat bump (tournaments_played, tournaments_won, or
## tournaments_created). Mutates, evaluates achievements, grants rewards,
## persists. Returns newly-unlocked achievements list (for out-of-band push
## to client).
func apply_tournament_stat(account_id: int, key: String) -> Array:
	var account := get_account(account_id)
	if account.is_empty():
		push_error("ServerStore.apply_tournament_stat: account not found: %d" % account_id)
		return []

	_ensure_stats(account)
	var stats: Dictionary = account["stats"]

	if key in ["tournaments_played", "tournaments_won", "tournaments_created"]:
		stats[key] = int(stats.get(key, 0)) + 1

	var ach_res := AchievementSystem.evaluate(stats, account["achievements"]["unlocked"])
	account["achievements"]["unlocked"] = ach_res["unlocked"]
	grant_reward(account, int(ach_res["points_awarded"]), ach_res["reward_ids"])

	return ach_res["newly"]


## Flat rows for the client (menu quest panel + result screen). Reads a
## normalised {day, state} dict (from QuestSystem.ensure_day).
func _quest_rows(quests_norm: Dictionary) -> Array:
	var rows := []
	var state: Dictionary = quests_norm.get("state", {})
	for id in quests_norm.get("active_ids", []):
		var q := QuestSystem.def_for(id)
		if q.is_empty():
			continue
		var qs: Dictionary = state.get(id, {"progress": 0, "completed": false})
		rows.append({
			"id": id,
			"name": q.name,
			"progress": int(qs.get("progress", 0)),
			"target": int(q.target),
			"points": int(q.points),
			"completed": bool(qs.get("completed", false)),
		})
	return rows


func _valid_username(username: String) -> bool:
	if username.length() < MIN_USERNAME_LEN or username.length() > 20:
		return false
	for c in username:
		var is_alnum := (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9")
		if not (is_alnum or c == "_"):
			return false
	return true


# --- password hashing (pure static) --------------------------------------

static func hash_password(password: String, salt_hex := "") -> Dictionary:
	var salt_bytes: PackedByteArray
	if salt_hex == "":
		salt_bytes = Crypto.new().generate_random_bytes(16)
		salt_hex = salt_bytes.hex_encode()
	else:
		salt_bytes = _hex_to_bytes(salt_hex)

	var digest := _sha256(salt_bytes + password.to_utf8_buffer())
	for i in range(HASH_ITERATIONS - 1):
		digest = _sha256(digest)

	return {"salt": salt_hex, "hash": digest.hex_encode(), "iterations": HASH_ITERATIONS}


static func verify_password(password: String, salt_hex: String, hash_hex: String, iterations: int) -> bool:
	var salt_bytes := _hex_to_bytes(salt_hex)
	var digest := _sha256(salt_bytes + password.to_utf8_buffer())
	for i in range(max(iterations - 1, 0)):
		digest = _sha256(digest)
	var computed := digest.hex_encode()

	# length-independent-ish equality (no early return on first mismatch)
	if computed.length() != hash_hex.length():
		return false
	var diff := 0
	for i in range(computed.length()):
		diff |= computed.unicode_at(i) ^ hash_hex.unicode_at(i)
	return diff == 0


static func _sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()


static func _hex_to_bytes(hex: String) -> PackedByteArray:
	var bytes := PackedByteArray()
	for i in range(0, hex.length() - 1, 2):
		bytes.append(hex.substr(i, 2).hex_to_int())
	return bytes


# --- elo / points (pure static) ----------------------------------------

static func expected_score(my_elo: int, opp_elo: int) -> float:
	return 1.0 / (1.0 + pow(10.0, (float(opp_elo) - float(my_elo)) / 400.0))


static func k_factor(games_played: int) -> int:
	if games_played < 10:
		return 40
	elif games_played < 30:
		return 20
	return 10


static func apply_result(elo_a: int, games_a: int, elo_b: int, games_b: int, winner: int) -> Dictionary:
	var score_a := 1.0 if winner == 1 else (0.5 if winner == 0 else 0.0)
	var score_b := 1.0 - score_a
	var delta_a := int(round(k_factor(games_a) * (score_a - expected_score(elo_a, elo_b))))
	var delta_b := int(round(k_factor(games_b) * (score_b - expected_score(elo_b, elo_a))))
	return {
		"elo_a_after": elo_a + delta_a,
		"elo_b_after": elo_b + delta_b,
		"delta_a": delta_a,
		"delta_b": delta_b,
	}


## Ranked match points, scaled by how many categories the player actually won
## across the whole match (a Bo1's single game, or the running total over a
## Bo3/Bo5 series). The loser banks exactly what they fought for; the winner
## banks double. So a Bo1 clean sweep is 14 for the winner / 0 for the loser,
## a 4–3 grind is 8 / 3, and a swept Bo3 is ~28 / ~7. Points-per-minute stays
## roughly flat across formats; points-per-match scales with series length.
static func match_points(outcome: String, own_score: int) -> int:
	match outcome:
		"win": return maxi(own_score, 0) * 2
		"loss": return maxi(own_score, 0)
		"draw": return maxi(own_score, 0)
		_: return 0


static func _outcome_for(winner: int, seat: int) -> String:
	if winner == 0:
		return "draw"
	return "win" if winner == seat else "loss"


# --- match write ----------------------------------------------------------

# `score1` / `score2` are each seat's category wins across the WHOLE match —
# for a Bo1 that's the single game's score, for a Bo3/Bo5 the running total
# over every game played. They drive the points award (see match_points).
func record_match(a1_id: int, a2_id: int, winner: int, score1: int, score2: int, is_bot_match: bool) -> Dictionary:
	var account_1 := get_account(a1_id)
	if account_1.is_empty():
		push_error("ServerStore.record_match: account 1 not found: %d" % a1_id)
		return {}

	var account_2 := {}
	var is_real := a2_id != 0
	var elo_2_before := START_ELO
	var games_2_before := 1000  # bot: fixed, => k_factor 10
	if is_real:
		account_2 = get_account(a2_id)
		if account_2.is_empty():
			push_error("ServerStore.record_match: account 2 not found: %d" % a2_id)
			return {}
		elo_2_before = int(account_2.get("elo", START_ELO))
		games_2_before = int(account_2.get("games", 0))

	var elo_1_before := int(account_1.get("elo", START_ELO))
	var games_1_before := int(account_1.get("games", 0))

	var res := apply_result(elo_1_before, games_1_before, elo_2_before, games_2_before, winner)

	_apply_account_result(account_1, res["elo_a_after"], _outcome_for(winner, 1), score1)
	if is_real:
		_apply_account_result(account_2, res["elo_b_after"], _outcome_for(winner, 2), score2)
	_save_accounts()

	var record := {
		"id": _next_match_id,
		"ts": int(Time.get_unix_time_from_system()),
		"account_1_id": a1_id,
		"account_2_id": a2_id,
		"winner": winner,
		"score_1": score1,
		"score_2": score2,
		"elo_1_before": elo_1_before,
		"elo_1_after": res["elo_a_after"],
		"elo_2_before": elo_2_before,
		"elo_2_after": res["elo_b_after"],
		"points_1_delta": match_points(_outcome_for(winner, 1), score1),
		"points_2_delta": match_points(_outcome_for(winner, 2), score2),
		"is_bot_match": is_bot_match,
	}
	_matches.append(record)
	_next_match_id += 1
	_save_matches()
	return record


func _apply_account_result(account: Dictionary, elo_after: int, outcome: String, own_score: int) -> void:
	account["elo"] = elo_after
	account["games"] = int(account.get("games", 0)) + 1
	account["points"] = int(account.get("points", 0)) + match_points(outcome, own_score)
	match outcome:
		"win": account["wins"] = int(account.get("wins", 0)) + 1
		"loss": account["losses"] = int(account.get("losses", 0)) + 1
		"draw": account["draws"] = int(account.get("draws", 0)) + 1


# --- ladder / profile --------------------------------------------------

func _sorted_by_rank() -> Array:
	var sorted := _accounts.duplicate()
	sorted.sort_custom(func(a, b):
		var ea := int(a.get("elo", START_ELO))
		var eb := int(b.get("elo", START_ELO))
		if ea != eb:
			return ea > eb
		return int(a.get("id", 0)) < int(b.get("id", 0))
	)
	return sorted


func rank_of(account_id: int) -> int:
	var sorted := _sorted_by_rank()
	for i in range(sorted.size()):
		if int(sorted[i].get("id", -1)) == account_id:
			return i + 1
	return 0


func ladder(limit: int, offset: int, viewer_id: int) -> Dictionary:
	var sorted := _sorted_by_rank()
	var rows := []
	var your_row_included := false
	for i in range(offset, min(offset + limit, sorted.size())):
		var account: Dictionary = sorted[i]
		var is_you := int(account.get("id", -1)) == viewer_id
		if is_you:
			your_row_included = true
		rows.append(_ladder_row(account, i + 1, is_you))
	# Pin the viewer's own row on the end if they placed outside this window.
	if not your_row_included and viewer_id > 0:
		for i in range(sorted.size()):
			if int(sorted[i].get("id", -1)) == viewer_id:
				rows.append(_ladder_row(sorted[i], i + 1, true))
				break
	return {
		"rows": rows,
		"your_rank": rank_of(viewer_id),
		"your_row_included": your_row_included,
	}


func _ladder_row(account: Dictionary, rank: int, is_you: bool) -> Dictionary:
	var w := int(account.get("wins", 0))
	var l := int(account.get("losses", 0))
	var d := int(account.get("draws", 0))
	return {
		"rank": rank,
		"display_name": account.get("display_name"),
		"elo": int(account.get("elo", 0)),
		"wins": w, "losses": l, "draws": d, "games": w + l + d,
		"avatar": str(account.get("avatar", "")),
		"frame": str(account.get("frame", "")),
		"background": str(account.get("background", "")),
		"is_provisional": bool(account.get("is_provisional", false)),
		"is_you": is_you,
	}


func recent_matches(account_id: int, limit := 10) -> Array:
	var mine := []
	for m in _matches:
		if int(m.get("account_1_id", -1)) == account_id or int(m.get("account_2_id", -1)) == account_id:
			mine.append(m)
	mine.sort_custom(func(a, b):
		var ta := int(a.get("ts", 0))
		var tb := int(b.get("ts", 0))
		if ta != tb:
			return ta > tb
		return int(a.get("id", 0)) > int(b.get("id", 0))
	)

	var out := []
	for i in range(min(limit, mine.size())):
		var m: Dictionary = mine[i]
		var seat := 1 if int(m.get("account_1_id", -1)) == account_id else 2
		var winner := int(m.get("winner", 0))
		var elo_delta := int(m.get("elo_%d_after" % seat, 0)) - int(m.get("elo_%d_before" % seat, 0))
		var opp_id := int(m.get("account_2_id", 0)) if seat == 1 else int(m.get("account_1_id", 0))
		var opp_name := "Bot"
		if opp_id > 0:
			opp_name = str(get_account(opp_id).get("username", "Unknown"))
		out.append({
			"outcome": _outcome_for(winner, seat),
			"elo_delta": elo_delta,
			"opponent_name": opp_name,
			"is_bot_match": bool(m.get("is_bot_match", false)),
			"ts": int(m.get("ts", 0)),
		})
	return out


# --- tournaments ------------------------------------------------------------

func is_admin_account(account: Dictionary) -> bool:
	return bool(account.get("is_admin", false))


## Creates a tournament in "signup" status. `bracket_size` is coerced to a
## power of 2 via TournamentSystem (floor 32 unless `allow_small`, e.g. a dev
## admin testing with a tiny bracket). Timestamps are unix seconds and must be
## strictly increasing (signup_close_ts == check_in_open_ts is allowed/typical
## per the locked design — sign-ups close exactly when check-in opens).
const _AVAILABILITY := ["open", "semi_private", "private"]

func create_tournament(created_by: int, name: String, requested_bracket_size: int,
		signup_close_ts: int, check_in_open_ts: int, start_ts: int,
		is_dev_bot: bool, allow_small := false, requested_match_format := 1,
		cube_card_ids: Array = [], availability := "open", password := "",
		private_signup_close_ts := 0, late_check_in := false,
		late_check_in_open_ts := 0, prize_spec := {}) -> Dictionary:
	var clean_name := name.strip_edges()
	if clean_name.length() < 1 or clean_name.length() > 60:
		return {"ok": false, "error": "bad_name", "tournament": {}}
	if availability not in _AVAILABILITY:
		return {"ok": false, "error": "bad_availability", "tournament": {}}

	# Password required for the private / semi-private sign-up phase.
	var gated := availability in ["semi_private", "private"]
	var clean_pw := password.strip_edges()
	if gated and (clean_pw.length() < 1 or clean_pw.length() > 72):
		return {"ok": false, "error": "bad_password", "tournament": {}}

	# Schedule ordering (unix seconds). All phase boundaries sit before start.
	# semi_private adds the private→open boundary, which must come strictly
	# before open sign-up closes (no zero-length open window — use Private for
	# that). When late check-in is enabled it opens between check-in and start.
	var ok_schedule := signup_close_ts <= check_in_open_ts and check_in_open_ts < start_ts
	if availability == "semi_private":
		ok_schedule = ok_schedule and private_signup_close_ts < signup_close_ts
	if late_check_in and late_check_in_open_ts > 0:
		ok_schedule = ok_schedule and check_in_open_ts <= late_check_in_open_ts and late_check_in_open_ts < start_ts
	if not ok_schedule:
		return {"ok": false, "error": "bad_schedule", "tournament": {}}

	var stored_private_close := 0
	if availability == "semi_private":
		stored_private_close = private_signup_close_ts
	elif availability == "private":
		stored_private_close = signup_close_ts

	var pw := {"salt": "", "hash": "", "iterations": 0}
	if gated:
		pw = hash_password(clean_pw)

	# Prize pool: clean + price the spec, then escrow the full cost out of the
	# creator's wallet (refunded in full if the tournament never fires).
	var pr := TournamentPrizes.sanitize(prize_spec,
		func(id): return ShopCatalog.price_for(id) if ShopCatalog.is_buyable(id) else -1)
	if not bool(pr.ok):
		return {"ok": false, "error": pr.error, "tournament": {}}
	var creator := {}
	if int(pr.cost) > 0:
		creator = get_account(created_by)
		if creator.is_empty():
			return {"ok": false, "error": "no_such_user", "tournament": {}}
		if int(creator.get("points", 0)) < int(pr.cost):
			return {"ok": false, "error": "insufficient_points", "tournament": {}}

	var bracket_size := TournamentSystem.resolve_bracket_size(requested_bracket_size, allow_small)
	# Only Bo1/Bo3 are offered — Bo5 tournaments run too long. Anything else
	# (incl. a stale client still sending 5) silently falls back to Bo1 rather
	# than rejecting the whole creation call.
	var match_format := requested_match_format if requested_match_format in [1, 3] else 1
	var tournament := {
		"id": _next_tournament_id,
		"name": clean_name,
		"created_by_account_id": created_by,
		"is_dev_bot_tournament": is_dev_bot,
		"bracket_size": bracket_size,
		"match_format": match_format,
		"availability": availability,
		# Salted-hash material for the gated sign-up phase. Never sent to
		# clients — see tournament_public_view().
		"pw_salt": pw.salt,
		"pw_hash": pw.hash,
		"pw_iterations": pw.iterations,
		"late_check_in": late_check_in,
		# When > 0, strangers may only late-check-in from this time onward (the
		# "last minute" window); 0 = the whole check-in phase.
		"late_check_in_open_ts": late_check_in_open_ts if late_check_in else 0,
		# Player-curated card pool for every match in this tournament, as a list
		# of card ids the net layer already sanitized. [] == full collection.
		# Persisted with the tournament so later rounds still use it even if the
		# creator is offline by then.
		"cube_ids": cube_card_ids,
		# Prize pool (see rules/tournament_prizes.gd). prize_escrow was debited
		# from the creator now; escrow_refunded / prizes_paid guard against
		# double refund / double payout.
		"prizes": pr.prizes,
		"prize_escrow": int(pr.cost),
		"escrow_refunded": false,
		"prizes_paid": false,
		"status": "signup_private" if gated else "signup",
		"private_signup_close_ts": stored_private_close,
		"signup_close_ts": signup_close_ts,
		"check_in_open_ts": check_in_open_ts,
		"start_ts": start_ts,
		"rng_seed": 0,
		"participants": [],
		"rounds": [],
		"current_round": 0,
		# Round pacing (set by net_node as rounds start / finish):
		#   round_started_ts    unix s the current round's matches went live
		#   round_deadline_ts   unix s the round's hard-cap force-resolve point
		#                       (round_started_ts + match cap for this format)
		#   intermission_until_ts  unix s the next round is held until (0 = none)
		"round_started_ts": 0,
		"round_deadline_ts": 0,
		"intermission_until_ts": 0,
		"winner_account_id": 0,
	}
	if int(pr.cost) > 0:
		creator["points"] = int(creator.get("points", 0)) - int(pr.cost)
		_save_accounts()
	_tournaments.append(tournament)
	_next_tournament_id += 1
	_save_tournaments()
	return {"ok": true, "error": "", "tournament": tournament}


## Refund a cancelled tournament's prize escrow to its creator (nothing was
## ever paid out). Idempotent. Returns the amount refunded (0 if none / already
## done).
func refund_tournament_escrow(t: Dictionary) -> int:
	var amt := int(t.get("prize_escrow", 0))
	if amt <= 0 or bool(t.get("escrow_refunded", false)):
		return 0
	var creator := get_account(int(t.get("created_by_account_id", 0)))
	if not creator.is_empty():
		creator["points"] = int(creator.get("points", 0)) + amt
		_save_accounts()
	t["escrow_refunded"] = true
	_save_tournaments()
	return amt


## Pay a completed tournament's prizes: every participant whose finish maps to a
## "set" bucket gets that bucket's points + items (grant_reward skips items they
## already own). Idempotent. Returns [{account_id, bucket, points, granted}].
func pay_tournament_prizes(t: Dictionary) -> Array:
	if bool(t.get("prizes_paid", false)):
		return []
	var prizes: Dictionary = t.get("prizes", {})
	var payouts := []
	if not prizes.is_empty():
		var total_rounds := (t.get("rounds", []) as Array).size()
		for p in (t.get("participants", []) as Array):
			var bucket := TournamentPrizes.bucket_for_placement(int(p.get("eliminated_round", 0)), total_rounds)
			if bucket == "" or not prizes.has(bucket):
				continue
			var account := get_account(int(p.get("account_id", 0)))
			if account.is_empty():
				continue
			var prize: Dictionary = prizes[bucket]
			var res := grant_reward(account, int(prize.get("points", 0)), prize.get("items", []))
			payouts.append({
				"account_id": int(p.account_id),
				"bucket": bucket,
				"points": int(prize.get("points", 0)),
				"granted": res.get("granted", []),
			})
	t["prizes_paid"] = true
	_save_tournaments()
	return payouts


## Trimmed rows for the browse screen — no bracket payload.
func list_tournaments(status_filter := "") -> Array:
	var rows := []
	for t in _tournaments:
		if status_filter != "" and str(t.get("status", "")) != status_filter:
			continue
		var creator := get_account(int(t.get("created_by_account_id", 0)))
		rows.append({
			"id": t.id,
			"name": t.name,
			"status": t.status,
			"is_dev_bot_tournament": t.is_dev_bot_tournament,
			"bracket_size": t.bracket_size,
			"match_format": t.get("match_format", 1),
			"participant_count": (t.participants as Array).size(),
			"creator_name": str(creator.get("display_name", "—")),
			"creator_avatar": str(creator.get("avatar", "")),
			"creator_frame": str(creator.get("frame", "")),
			"creator_background": str(creator.get("background", "")),
			# True when this tournament runs on a player-curated cube rather than
			# the full card set (see net_node cube handling).
			"has_cube": (t.get("cube_ids", []) as Array).size() > 0,
			"prizes": t.get("prizes", {}),
			"availability": str(t.get("availability", "open")),
			"late_check_in": bool(t.get("late_check_in", false)),
			"late_check_in_open_ts": int(t.get("late_check_in_open_ts", 0)),
			# Derived: true while the tournament is in its password-gated phase,
			# so the client can bucket it into the "Private Tournaments" tab.
			"is_private_now": str(t.get("status", "")) == "signup_private",
			"private_signup_close_ts": int(t.get("private_signup_close_ts", 0)),
			"signup_close_ts": t.signup_close_ts,
			"check_in_open_ts": t.check_in_open_ts,
			"start_ts": t.start_ts,
		})
	rows.sort_custom(func(a, b): return int(a.start_ts) < int(b.start_ts))
	return rows


## The version of a tournament record that is safe to send to clients: a deep
## copy with the password-hash material stripped and a plain `has_password`
## flag in its place. EVERY path that ships a full tournament dict to a peer
## must route through this.
func tournament_public_view(t: Dictionary) -> Dictionary:
	var v := t.duplicate(true)
	v.erase("pw_salt")
	v.erase("pw_hash")
	v.erase("pw_iterations")
	v["has_password"] = str(t.get("pw_hash", "")) != ""
	return v


func get_tournament(id: int) -> Dictionary:
	for t in _tournaments:
		if int(t.get("id", -1)) == id:
			return t
	return {}


func all_tournaments() -> Array:
	return _tournaments


func sign_up(tournament_id: int, account_id: int, password := "") -> Dictionary:
	var t := get_tournament(tournament_id)
	if t.is_empty():
		return {"ok": false, "error": "no_such_tournament", "tournament": {}}
	if str(t.status) not in ["signup", "signup_private"]:
		return {"ok": false, "error": "signup_closed", "tournament": {}}
	# The password gate applies only during the private phase; the semi-private
	# open phase (and open mode) ignore whatever password is passed.
	if str(t.status) == "signup_private":
		if not verify_password(password, str(t.get("pw_salt", "")), str(t.get("pw_hash", "")), int(t.get("pw_iterations", 0))):
			return {"ok": false, "error": "bad_password", "tournament": {}}
	var participants: Array = t.participants
	for p in participants:
		if int(p.account_id) == account_id:
			return {"ok": false, "error": "already_signed_up", "tournament": t}
	if participants.size() >= int(t.bracket_size):
		return {"ok": false, "error": "tournament_full", "tournament": {}}
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "tournament": {}}
	participants.append(_new_participant(account, account_id, false))
	_save_tournaments()
	return {"ok": true, "error": "", "tournament": t}


## One participant record. Portrait/elo are snapshotted here (same convention
## as display_name) so the bracket card renders without a live account lookup.
func _new_participant(account: Dictionary, account_id: int, checked_in: bool) -> Dictionary:
	return {
		"account_id": account_id,
		"display_name": str(account.get("display_name", "Player")),
		"avatar": str(account.get("avatar", "")),
		"frame": str(account.get("frame", "")),
		"background": str(account.get("background", "")),
		"elo": int(account.get("elo", START_ELO)),
		"signed_up_ts": int(Time.get_unix_time_from_system()),
		"checked_in": checked_in,
		"eliminated_round": 0,
	}


func check_in(tournament_id: int, account_id: int) -> Dictionary:
	var t := get_tournament(tournament_id)
	if t.is_empty():
		return {"ok": false, "error": "no_such_tournament", "tournament": {}}
	if str(t.status) != "check_in":
		return {"ok": false, "error": "check_in_not_open", "tournament": {}}
	var participants: Array = t.participants
	for p in participants:
		if int(p.account_id) == account_id:
			if bool(p.checked_in):
				return {"ok": false, "error": "already_checked_in", "tournament": t}
			p.checked_in = true
			_save_tournaments()
			return {"ok": true, "error": "", "tournament": t}

	# Not a pre-registered participant. With late check-in enabled this is a
	# one-step sign-up-and-check-in (no password, any availability mode); the
	# sign-up cap still applies. Otherwise it's just "you never signed up".
	if not bool(t.get("late_check_in", false)):
		return {"ok": false, "error": "not_signed_up", "tournament": {}}
	var lci_open := int(t.get("late_check_in_open_ts", 0))
	if lci_open > 0 and int(Time.get_unix_time_from_system()) < lci_open:
		return {"ok": false, "error": "late_check_in_not_open", "tournament": {}}
	if participants.size() >= int(t.bracket_size):
		return {"ok": false, "error": "tournament_full", "tournament": {}}
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "tournament": {}}
	participants.append(_new_participant(account, account_id, true))
	_save_tournaments()
	return {"ok": true, "error": "", "tournament": t}


## Withdraws a signed-up participant. Allowed only while status is "signup" —
## once check-in opens, the bracket-fill logic (bot-replaces-no-show) already
## handles a missing player, and letting someone un-sign-up mid-check-in would
## complicate that; a plain cancel is a pre-check-in-only courtesy.
func withdraw(tournament_id: int, account_id: int) -> Dictionary:
	var t := get_tournament(tournament_id)
	if t.is_empty():
		return {"ok": false, "error": "no_such_tournament", "tournament": {}}
	if str(t.status) not in ["signup", "signup_private"]:
		return {"ok": false, "error": "too_late", "tournament": {}}
	var participants: Array = t.participants
	for i in range(participants.size()):
		if int(participants[i].account_id) == account_id:
			participants.remove_at(i)
			_save_tournaments()
			return {"ok": true, "error": "", "tournament": t}
	return {"ok": false, "error": "not_signed_up", "tournament": {}}


## Marks a tournament cancelled (e.g. too few players checked in by start time).
## Lock release / client broadcast is the caller's job (Net). Idempotent-ish:
## re-cancelling an already-terminal tournament is a no-op.
func cancel_tournament(tournament_id: int, reason := "insufficient_players") -> Dictionary:
	var t := get_tournament(tournament_id)
	if t.is_empty():
		return {"ok": false, "error": "no_such_tournament", "tournament": {}}
	if str(t.status) in ["completed", "cancelled"]:
		return {"ok": true, "error": "", "tournament": t}
	t.status = "cancelled"
	t.cancel_reason = reason
	t.cancelled_ts = int(Time.get_unix_time_from_system())
	_save_tournaments()
	return {"ok": true, "error": "", "tournament": t}


## Tournament records are references into `_tournaments` (GDScript Dictionaries
## are by-reference), so in-place mutation elsewhere (e.g. Net's bracket
## advancement) just needs this to flush to disk.
func persist_tournament(_record: Dictionary) -> void:
	_save_tournaments()


# --- disk ------------------------------------------------------------------

func _save_accounts() -> void:
	var file := FileAccess.open(_dir + "accounts.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"accounts": _accounts}, "\t"))


func _save_matches() -> void:
	var file := FileAccess.open(_dir + "matches.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"matches": _matches}, "\t"))


func _save_tournaments() -> void:
	var file := FileAccess.open(_dir + "tournaments.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"tournaments": _tournaments}, "\t"))
