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
				for t in _tournaments:
					if int(t.get("id", 0)) >= _next_tournament_id:
						_next_tournament_id = int(t["id"]) + 1
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
	account["background"] = clean
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


func account_snapshot(account: Dictionary) -> Dictionary:
	return {
		"id": account.get("id"),
		"username": account.get("username"),
		"display_name": account.get("display_name"),
		"avatar": account.get("avatar", ""),
		"frame": account.get("frame", ""),
		"background": account.get("background", ""),
		"elo": account.get("elo"),
		"games": account.get("games"),
		"wins": account.get("wins"),
		"losses": account.get("losses"),
		"draws": account.get("draws"),
		"points": account.get("points"),
		"owned_rewards": (account.get("owned_rewards", []) as Array).duplicate(),
		"is_provisional": int(account.get("games", 0)) < PROVISIONAL_GAMES,
		"quests": _quest_rows(QuestSystem.ensure_day(account.get("quests", {}), QuestSystem.today_key())),
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
	_save_accounts()

	return {
		"completed": res["completed"],
		"points_awarded": int(res["points_awarded"]),
		"points_total": int(account.get("points", 0)),
		"quests": _quest_rows(normalised),
	}


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


static func points_delta(outcome: String) -> int:
	match outcome:
		"win": return 10
		"loss": return 3
		"draw": return 5
		_: return 0


static func _outcome_for(winner: int, seat: int) -> String:
	if winner == 0:
		return "draw"
	return "win" if winner == seat else "loss"


# --- match write ----------------------------------------------------------

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

	_apply_account_result(account_1, res["elo_a_after"], _outcome_for(winner, 1))
	if is_real:
		_apply_account_result(account_2, res["elo_b_after"], _outcome_for(winner, 2))
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
		"points_1_delta": points_delta(_outcome_for(winner, 1)),
		"points_2_delta": points_delta(_outcome_for(winner, 2)),
		"is_bot_match": is_bot_match,
	}
	_matches.append(record)
	_next_match_id += 1
	_save_matches()
	return record


func _apply_account_result(account: Dictionary, elo_after: int, outcome: String) -> void:
	account["elo"] = elo_after
	account["games"] = int(account.get("games", 0)) + 1
	account["points"] = int(account.get("points", 0)) + points_delta(outcome)
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
		rows.append({
			"rank": i + 1,
			"display_name": account.get("display_name"),
			"elo": account.get("elo"),
			"wins": int(account.get("wins", 0)),
			"losses": int(account.get("losses", 0)),
			"is_you": is_you,
		})
	return {
		"rows": rows,
		"your_rank": rank_of(viewer_id),
		"your_row_included": your_row_included,
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
func create_tournament(created_by: int, name: String, requested_bracket_size: int,
		signup_close_ts: int, check_in_open_ts: int, start_ts: int,
		is_dev_bot: bool, allow_small := false) -> Dictionary:
	var clean_name := name.strip_edges()
	if clean_name.length() < 1 or clean_name.length() > 60:
		return {"ok": false, "error": "bad_name", "tournament": {}}
	if not (signup_close_ts <= check_in_open_ts and check_in_open_ts < start_ts):
		return {"ok": false, "error": "bad_schedule", "tournament": {}}

	var bracket_size := TournamentSystem.resolve_bracket_size(requested_bracket_size, allow_small)
	var tournament := {
		"id": _next_tournament_id,
		"name": clean_name,
		"created_by_account_id": created_by,
		"is_dev_bot_tournament": is_dev_bot,
		"bracket_size": bracket_size,
		"status": "signup",
		"signup_close_ts": signup_close_ts,
		"check_in_open_ts": check_in_open_ts,
		"start_ts": start_ts,
		"rng_seed": 0,
		"participants": [],
		"rounds": [],
		"current_round": 0,
		"winner_account_id": 0,
	}
	_tournaments.append(tournament)
	_next_tournament_id += 1
	_save_tournaments()
	return {"ok": true, "error": "", "tournament": tournament}


## Trimmed rows for the browse screen — no bracket payload.
func list_tournaments(status_filter := "") -> Array:
	var rows := []
	for t in _tournaments:
		if status_filter != "" and str(t.get("status", "")) != status_filter:
			continue
		rows.append({
			"id": t.id,
			"name": t.name,
			"status": t.status,
			"is_dev_bot_tournament": t.is_dev_bot_tournament,
			"bracket_size": t.bracket_size,
			"participant_count": (t.participants as Array).size(),
			"signup_close_ts": t.signup_close_ts,
			"check_in_open_ts": t.check_in_open_ts,
			"start_ts": t.start_ts,
		})
	rows.sort_custom(func(a, b): return int(a.start_ts) < int(b.start_ts))
	return rows


func get_tournament(id: int) -> Dictionary:
	for t in _tournaments:
		if int(t.get("id", -1)) == id:
			return t
	return {}


func all_tournaments() -> Array:
	return _tournaments


func sign_up(tournament_id: int, account_id: int) -> Dictionary:
	var t := get_tournament(tournament_id)
	if t.is_empty():
		return {"ok": false, "error": "no_such_tournament", "tournament": {}}
	if str(t.status) != "signup":
		return {"ok": false, "error": "signup_closed", "tournament": {}}
	var participants: Array = t.participants
	for p in participants:
		if int(p.account_id) == account_id:
			return {"ok": false, "error": "already_signed_up", "tournament": t}
	if participants.size() >= int(t.bracket_size):
		return {"ok": false, "error": "tournament_full", "tournament": {}}
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "tournament": {}}
	participants.append({
		"account_id": account_id,
		"display_name": str(account.get("display_name", "Player")),
		"signed_up_ts": int(Time.get_unix_time_from_system()),
		"checked_in": false,
		"eliminated_round": 0,
	})
	_save_tournaments()
	return {"ok": true, "error": "", "tournament": t}


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
	return {"ok": false, "error": "not_signed_up", "tournament": {}}


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
