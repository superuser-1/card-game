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
## FIDE Elo regulations (B.02): K=40 for a player's first 30 rated games,
## K=20 once established below the 2400 threshold, K=10 once a player has
## ever reached 2400+ (even if their rating later drops back below it —
## hence tracking `peak_elo` per account rather than current elo).
const K_PHASE_GAMES := 30
const K_HIGH_ELO_THRESHOLD := 2400
const HASH_ITERATIONS := 200000

# DEV: relaxed for local testing. Bump back to 3 / 6 before any real launch.
const MIN_USERNAME_LEN := 1
const MIN_PASSWORD_LEN := 1

var _dir: String
var _accounts: Array
var _matches: Array
var _tournaments: Array
var _admin_log: Array
var _presence_samples: Array
var _tournament_templates: Array
var _next_account_id: int

## Runtime-only (not persisted/saved) — the most recent tag_by_login_window
## call, for a one-shot "undo that" in the admin tool. See
## admin_undo_last_tag_operation().
var _last_tag_operation: Dictionary = {}
var _next_match_id: int
var _next_tournament_id: int
var _next_template_id: int

## Admin audit log kept on disk stays capped at this many most-recent entries —
## it's an incident-review trail, not a permanent ledger.
const ADMIN_LOG_MAX := 1000

## Presence samples: one {ts, count} row every PRESENCE_SAMPLE_SECONDS
## (net_node.gd's timer), capped to roughly 30 days of history at that
## interval — the admin tool's "players over time" graph, not a permanent
## record.
const PRESENCE_SAMPLE_SECONDS := 300
const PRESENCE_MAX := 8640


func open(dir := "user://flickbattle/") -> void:
	_dir = dir
	_accounts = []
	_matches = []
	_tournaments = []
	_admin_log = []
	_presence_samples = []
	_tournament_templates = []
	_next_account_id = 1
	_next_match_id = 1
	_next_tournament_id = 1
	_next_template_id = 1

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
					"completed_ts": 0, "payout_records": [],
					"rolled_back": false, "rolled_back_ts": 0, "rolled_back_by": "",
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

	var admin_log_path := dir + "admin_log.json"
	if FileAccess.file_exists(admin_log_path):
		var file := FileAccess.open(admin_log_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary and parsed.has("actions"):
				_admin_log = parsed["actions"]

	var presence_path := dir + "presence.json"
	if FileAccess.file_exists(presence_path):
		var file := FileAccess.open(presence_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary and parsed.has("samples"):
				_presence_samples = parsed["samples"]

	var templates_path := dir + "tournament_templates.json"
	if FileAccess.file_exists(templates_path):
		var file := FileAccess.open(templates_path, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary and parsed.has("templates"):
				_tournament_templates = parsed["templates"]
				for t in _tournament_templates:
					if int(t.get("id", 0)) >= _next_template_id:
						_next_template_id = int(t["id"]) + 1


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
		"table_background": TableBackgrounds.DEFAULT_ID,
		"favorite_tables": [],
		"sleeve": "",
		"title": "",
		"auth_provider": "password",
		"pw_salt": hashed["salt"],
		"pw_hash": hashed["hash"],
		"pw_iterations": hashed["iterations"],
		"elo": START_ELO,
		"peak_elo": START_ELO,
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
		"reward_log": [],
		"achievement_log": [],
		"shop_log": [],
		"points_ledger": [],
		"login_log": [],
		"tags": [],
		"is_admin": false,
		"banned": false,
		"ban_reason": "",
		"banned_ts": 0,
		"banned_by": "",
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
	if bool(account.get("banned", false)):
		return {"ok": false, "error": "banned", "account": account}
	return {"ok": true, "error": "", "account": account}


## Appends one login_log entry (capped at ACCOUNT_LOG_MAX, same as every other
## per-account log) — called by net_node.gd after a successful register or
## password login (NOT a token resume, which isn't a fresh login). This is
## what admin_tag_accounts_by_login_window() below reads to find "everyone who
## logged in during this window" for a beta/playtest cohort.
func record_login(account_id: int) -> void:
	var account := get_account(account_id)
	if account.is_empty():
		return
	_append_account_log(account, "login_log", {"ts": int(Time.get_unix_time_from_system())})
	_save_accounts()


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


## Store a chosen game-table background id (the full-screen backdrop behind a
## match — see TableBackgrounds, distinct from the avatar's own "background").
## Unlike avatars, this is still mandatory (never ""), same reasoning as
## Avatars.sanitize always resolving to something real. Also accepts
## TableBackgrounds.RANDOM_ID/RANDOM_FAVORITE_ID — modes, not real ids, so they
## skip the ownership check (they're only ever resolved to a real, owned id
## client-side at the point of use).
func set_table_background(account_id: int, table_background_id: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean := table_background_id.strip_edges()
	if clean == "" or clean.length() > 40:
		return {"ok": false, "error": "bad_table_background", "account": {}}
	if not TableBackgrounds.is_random_mode(clean) and ShopCatalog.is_premium(clean) and clean not in account.get("owned_rewards", []):
		return {"ok": false, "error": "not_owned", "account": {}}
	account["table_background"] = clean
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


## Toggles a table background id in/out of this account's favorites list —
## used to narrow the "Random Favorite Table" pool. The id is trusted only as
## far as shape here (non-empty, <=40 chars), same as set_table_background —
## the RPC layer already ran it through TableBackgrounds.sanitize(), which
## rewrites anything unresolvable (including the two random-mode sentinels)
## to a real id before it ever reaches this function.
func toggle_favorite_table(account_id: int, table_background_id: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean := table_background_id.strip_edges()
	if clean == "" or clean.length() > 40:
		return {"ok": false, "error": "bad_table_background", "account": {}}
	if ShopCatalog.is_premium(clean) and clean not in account.get("owned_rewards", []):
		return {"ok": false, "error": "not_owned", "account": {}}
	var favs: Array = (account.get("favorite_tables", []) as Array).duplicate()
	if clean in favs:
		favs.erase(clean)
	else:
		favs.append(clean)
	account["favorite_tables"] = favs
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


## Store a chosen title id. "" means "auto" (always show my current elo tier);
## any other id must be either the account's live elo tier or a title-type
## reward it owns — see TitleSystem.is_available.
func set_title(account_id: int, title_id: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean := title_id.strip_edges()
	if clean.length() > 40:
		return {"ok": false, "error": "bad_title", "account": {}}
	var elo := int(account.get("elo", START_ELO))
	var owned: Array = account.get("owned_rewards", [])
	if not TitleSystem.is_available(clean, elo, owned):
		return {"ok": false, "error": "not_available", "account": {}}
	account["title"] = clean
	_save_accounts()
	return {"ok": true, "error": "", "account": account}


## Clears a stored elo-tier title pick that no longer matches the account's
## live elo (e.g. picked "Grandmaster" at 1250, then dropped back below 1200)
## so display_name() falls back to the correct current tier automatically.
## Granted (owned-reward) titles are never touched here — those stay available
## at any elo once earned. Call after every elo change.
func _reconcile_title(account: Dictionary) -> void:
	var title_id := str(account.get("title", ""))
	if title_id == "" or not TitleSystem.is_elo_tier_id(title_id):
		return
	var elo := int(account.get("elo", START_ELO))
	if title_id != TitleSystem.elo_tier_id_for(elo):
		account["title"] = ""


func account_snapshot(account: Dictionary) -> Dictionary:
	_ensure_stats(account)
	return {
		"id": account.get("id"),
		"username": account.get("username"),
		"display_name": account.get("display_name"),
		"avatar": account.get("avatar", ""),
		"frame": account.get("frame", ""),
		"background": account.get("background", ""),
		"table_background": account.get("table_background", ""),
		"favorite_tables": (account.get("favorite_tables", []) as Array).duplicate(),
		"sleeve": account.get("sleeve", ""),
		"title": account.get("title", ""),
		"elo": account.get("elo"),
		"games": account.get("games"),
		"wins": account.get("wins"),
		"losses": account.get("losses"),
		"draws": account.get("draws"),
		"points": account.get("points"),
		"owned_rewards": (account.get("owned_rewards", []) as Array).duplicate(),
		"is_provisional": int(account.get("games", 0)) < K_PHASE_GAMES,
		"quests": _quest_rows(QuestSystem.ensure_day(account.get("quests", {}), QuestSystem.today_key())),
		"stats": (account.get("stats", {}) as Dictionary).duplicate(),
		"achievements": {
			"unlocked": (account.get("achievements", {}).get("unlocked", {}) as Dictionary).duplicate()
		},
	}


## --- admin tools -----------------------------------------------------------
## Every admin action is a plain method here, taking/returning plain data —
## no RPC, no auth check (the caller, net_node's admin RPC handlers, already
## verified the requester is an admin before reaching these). Kept this way so
## a future HTTP-based admin website can call the exact same functions behind
## a different transport, instead of duplicating the logic.

## Fuller account view than account_snapshot() (adds id/username/ban/admin
## fields a player's own client never needs to see). Still never includes
## password material.
func account_admin_view(account: Dictionary) -> Dictionary:
	if account.is_empty():
		return {}
	return {
		"id": account.get("id"),
		"username": account.get("username"),
		"display_name": account.get("display_name"),
		"elo": account.get("elo"),
		"peak_elo": account.get("peak_elo", account.get("elo")),
		"games": account.get("games"),
		"wins": account.get("wins"),
		"losses": account.get("losses"),
		"draws": account.get("draws"),
		"points": account.get("points"),
		"is_admin": bool(account.get("is_admin", false)),
		"banned": bool(account.get("banned", false)),
		"ban_reason": account.get("ban_reason", ""),
		"banned_ts": account.get("banned_ts", 0),
		"banned_by": account.get("banned_by", ""),
		"created_ts": account.get("created_ts", 0),
		"owned_rewards": (account.get("owned_rewards", []) as Array).duplicate(),
		"avatar": account.get("avatar", ""),
		"frame": account.get("frame", ""),
		"background": account.get("background", ""),
		"table_background": account.get("table_background", ""),
		"favorite_tables": (account.get("favorite_tables", []) as Array).duplicate(),
		"sleeve": account.get("sleeve", ""),
		"title": account.get("title", ""),
		"tags": (account.get("tags", []) as Array).duplicate(),
		"achievements_unlocked": (account.get("achievements", {}).get("unlocked", {}) as Dictionary).duplicate(),
	}


## Case-insensitive username substring match, or an exact id match if `query`
## parses as an int. Sorted by username. `limit` caps the result count so a
## broad/empty query on a big account list can't blow up the reply payload.
func search_accounts(query: String, limit := 25) -> Array:
	var q := query.strip_edges().to_lower()
	var out := []
	if q.is_valid_int():
		var by_id := get_account(int(q))
		if not by_id.is_empty():
			out.append(account_admin_view(by_id))
	for account in _accounts:
		if out.size() >= limit:
			break
		if int(account.get("id", -1)) == (int(q) if q.is_valid_int() else -1):
			continue  # already added above
		if q != "" and not str(account.get("username_lower", "")).contains(q):
			continue
		out.append(account_admin_view(account))
	out.sort_custom(func(a, b): return str(a.get("username", "")).to_lower() < str(b.get("username", "")).to_lower())
	return out


func _log_admin_action(admin_username: String, action: String, account_id: int, details: String) -> void:
	_admin_log.append({
		"ts": int(Time.get_unix_time_from_system()),
		"admin": admin_username,
		"action": action,
		"account_id": account_id,
		"details": details,
	})
	if _admin_log.size() > ADMIN_LOG_MAX:
		_admin_log = _admin_log.slice(_admin_log.size() - ADMIN_LOG_MAX)
	_save_admin_log()


## Public entry point for logging an admin action that isn't itself a
## ServerStore mutation (e.g. net_node.gd force-ending a live match, which is
## live in-memory state, not persisted account/tournament data).
func log_admin_action(admin_username: String, action: String, details: String, account_id := 0) -> void:
	_log_admin_action(admin_username, action, account_id, details)


## Most recent actions first.
func recent_admin_actions(limit := 100) -> Array:
	var n := _admin_log.size()
	var out := []
	var i := n - 1
	while i >= 0 and out.size() < limit:
		out.append(_admin_log[i])
		i -= 1
	return out


func ban_account(account_id: int, reason: String, admin_username: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	account["banned"] = true
	account["ban_reason"] = reason.strip_edges()
	account["banned_ts"] = int(Time.get_unix_time_from_system())
	account["banned_by"] = admin_username
	_save_accounts()
	_log_admin_action(admin_username, "ban", account_id, reason)
	return {"ok": true, "error": "", "account": account_admin_view(account)}


func unban_account(account_id: int, admin_username: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	account["banned"] = false
	account["ban_reason"] = ""
	account["banned_ts"] = 0
	account["banned_by"] = ""
	_save_accounts()
	_log_admin_action(admin_username, "unban", account_id, "")
	return {"ok": true, "error": "", "account": account_admin_view(account)}


## Manual elo correction — bypasses apply_result entirely (no opponent, no K
## factor). peak_elo is bumped along with it if the new value is a new high,
## same invariant record_match maintains, so the FIDE K=10 rule stays correct
## for this account afterwards.
func admin_set_elo(account_id: int, new_elo: int, admin_username: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var old_elo := int(account.get("elo", START_ELO))
	account["elo"] = new_elo
	account["peak_elo"] = maxi(int(account.get("peak_elo", START_ELO)), new_elo)
	_reconcile_title(account)
	_save_accounts()
	_log_admin_action(admin_username, "set_elo", account_id, "%d -> %d" % [old_elo, new_elo])
	return {"ok": true, "error": "", "account": account_admin_view(account)}


## `delta` may be negative; the wallet is floored at 0.
func admin_adjust_points(account_id: int, delta: int, admin_username: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var old_points := int(account.get("points", 0))
	account["points"] = maxi(0, old_points + delta)
	var applied_delta := int(account["points"]) - old_points
	_log_points_ledger(account, "admin_adjustment", applied_delta, "by %s" % admin_username)
	_save_accounts()
	_log_admin_action(admin_username, "adjust_points", account_id, "%d -> %d (delta %d)" % [old_points, int(account["points"]), delta])
	return {"ok": true, "error": "", "account": account_admin_view(account)}


## Admin: grant a single cosmetic item directly to one player's account — the
## same underlying mechanism (grant_reward, logged with source "admin") a
## tournament payout uses, just a one-off, one-account version of it. No
## points involved; item existence isn't validated against ShopCatalog since
## a free (non-catalog) id is a harmless no-op to "grant" — the account
## already has access to it regardless.
func admin_grant_item(account_id: int, item_id: String, admin_username: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean := item_id.strip_edges()
	if clean == "" or clean.length() > 40:
		return {"ok": false, "error": "bad_item", "account": {}}
	if clean in (account.get("owned_rewards", []) as Array):
		return {"ok": false, "error": "already_owned", "account": {}}
	grant_reward(account, 0, [clean], "admin")
	_log_admin_action(admin_username, "grant_item", account_id, clean)
	return {"ok": true, "error": "", "account": account_admin_view(account)}


## Adds `tag` (any free-form string — "beta_1", "playtest_alpha", whatever
## this cohort is called) to every account with at least one login_log entry
## in [start_ts, end_ts] (inclusive). Reusable for any future beta/playtest
## round — just pick a new tag and a new window. Idempotent: accounts that
## already carry the tag aren't double-added or re-counted.
##
## CAVEAT: login_log is capped at ACCOUNT_LOG_MAX (100) entries per account —
## an account that logged in more than 100 times *after* the window (before
## this runs) could have its in-window entries evicted. Run this soon after
## the window closes to avoid that; for anyone missed, admin_add_tag() below
## covers it by hand.
## Every account with at least one login_log entry in [start_ts, end_ts],
## sorted by username. Shared by the preview step (admin sees the list before
## committing to anything) and the actual tagging below.
func _accounts_logged_in_during(start_ts: int, end_ts: int) -> Array:
	var matches := []
	for account in _accounts:
		for entry in (account.get("login_log", []) as Array):
			var ts := int((entry as Dictionary).get("ts", 0))
			if ts >= start_ts and ts <= end_ts:
				matches.append(account)
				break
	matches.sort_custom(func(a, b): return str(a.get("username", "")).to_lower() < str(b.get("username", "")).to_lower())
	return matches


## Read-only preview for the admin tool's two-step cohort flow: "who WOULD
## get tagged" before actually committing to it. Nothing is modified.
func admin_preview_login_window(start_ts: int, end_ts: int) -> Dictionary:
	if end_ts < start_ts:
		return {"ok": false, "error": "bad_window", "accounts": []}
	var rows := []
	for account in _accounts_logged_in_during(start_ts, end_ts):
		rows.append({"id": int(account.get("id", 0)), "username": str(account.get("username", ""))})
	return {"ok": true, "error": "", "accounts": rows}


## Adds `tag` (any free-form string — "beta_1", "playtest_alpha", whatever
## this cohort is called) to every account with at least one login_log entry
## in [start_ts, end_ts] (inclusive) — same set admin_preview_login_window
## above shows before this actually runs. Reusable for any future beta/
## playtest round — just pick a new tag and a new window. Idempotent:
## accounts that already carry the tag aren't double-added or re-counted.
## Remembers exactly which accounts it newly tagged so
## admin_undo_last_tag_operation() can cleanly reverse just this one call.
##
## CAVEAT: login_log is capped at ACCOUNT_LOG_MAX (100) entries per account —
## an account that logged in more than 100 times *after* the window (before
## this runs) could have its in-window entries evicted. Run this soon after
## the window closes to avoid that; for anyone missed, admin_add_tag() below
## covers it by hand.
func admin_tag_accounts_by_login_window(start_ts: int, end_ts: int, tag: String, admin_username: String) -> Dictionary:
	var clean_tag := tag.strip_edges()
	if clean_tag == "" or clean_tag.length() > 40:
		return {"ok": false, "error": "bad_tag", "tagged_usernames": []}
	if end_ts < start_ts:
		return {"ok": false, "error": "bad_window", "tagged_usernames": []}

	var tagged_usernames := []
	var tagged_account_ids := []
	for account in _accounts_logged_in_during(start_ts, end_ts):
		var tags: Array = (account.get("tags", []) as Array)
		if clean_tag not in tags:
			tags.append(clean_tag)
			account["tags"] = tags
			tagged_usernames.append(str(account.get("username", "")))
			tagged_account_ids.append(int(account.get("id", 0)))

	if not tagged_usernames.is_empty():
		_save_accounts()
	_last_tag_operation = {"tag": clean_tag, "account_ids": tagged_account_ids}
	_log_admin_action(admin_username, "tag_by_login_window", 0,
		"'%s' [%s .. %s] -> %d account(s): %s" % [
			clean_tag,
			Time.get_datetime_string_from_unix_time(start_ts, true),
			Time.get_datetime_string_from_unix_time(end_ts, true),
			tagged_usernames.size(), ", ".join(tagged_usernames),
		])
	return {"ok": true, "error": "", "tagged_usernames": tagged_usernames}


## Reverses exactly the most recent admin_tag_accounts_by_login_window() call
## — removes that tag from exactly the accounts it added it to (not from
## anyone who already had the tag some other way beforehand). One-shot: calling
## this again with nothing new tagged since returns "nothing_to_undo". Runtime-
## only (not persisted) — meant as an immediate "oops" undo, not a permanent
## history; the admin log already records the original action forever.
func admin_undo_last_tag_operation(admin_username: String) -> Dictionary:
	if _last_tag_operation.is_empty():
		return {"ok": false, "error": "nothing_to_undo", "untagged_usernames": []}
	var tag: String = str(_last_tag_operation.get("tag", ""))
	var account_ids: Array = _last_tag_operation.get("account_ids", [])
	var untagged_usernames := []
	for account_id in account_ids:
		var account := get_account(int(account_id))
		if account.is_empty():
			continue
		var tags: Array = (account.get("tags", []) as Array)
		if tag in tags:
			tags.erase(tag)
			account["tags"] = tags
			untagged_usernames.append(str(account.get("username", "")))
	if not untagged_usernames.is_empty():
		_save_accounts()
	_log_admin_action(admin_username, "undo_tag_by_login_window", 0,
		"'%s' -> removed from %d account(s): %s" % [tag, untagged_usernames.size(), ", ".join(untagged_usernames)])
	_last_tag_operation = {}
	return {"ok": true, "error": "", "untagged_usernames": untagged_usernames}


## Manual single-account tag add/remove — for fixing up anyone the login-
## window sweep missed (or over-caught), without re-running the whole sweep.
func admin_add_tag(account_id: int, tag: String, admin_username: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean_tag := tag.strip_edges()
	if clean_tag == "" or clean_tag.length() > 40:
		return {"ok": false, "error": "bad_tag", "account": {}}
	var tags: Array = (account.get("tags", []) as Array)
	if clean_tag not in tags:
		tags.append(clean_tag)
		account["tags"] = tags
		_save_accounts()
		_log_admin_action(admin_username, "add_tag", account_id, clean_tag)
	return {"ok": true, "error": "", "account": account_admin_view(account)}


func admin_remove_tag(account_id: int, tag: String, admin_username: String) -> Dictionary:
	var account := get_account(account_id)
	if account.is_empty():
		return {"ok": false, "error": "no_such_user", "account": {}}
	var clean_tag := tag.strip_edges()
	var tags: Array = (account.get("tags", []) as Array)
	if clean_tag in tags:
		tags.erase(clean_tag)
		account["tags"] = tags
		_save_accounts()
		_log_admin_action(admin_username, "remove_tag", account_id, clean_tag)
	return {"ok": true, "error": "", "account": account_admin_view(account)}


## Grants `item_ids` (same grant_reward/"admin" mechanism admin_grant_item and
## a tournament payout use) to every account currently carrying `tag`. Safe
## to re-run — grant_reward is itself idempotent per item id (skips ids an
## account already owns), so granting the same tag+item twice (e.g. after
## tagging a few stragglers by hand) never double-grants anyone.
func admin_grant_to_tag(tag: String, item_ids: Array, admin_username: String) -> Dictionary:
	var clean_tag := tag.strip_edges()
	if clean_tag == "":
		return {"ok": false, "error": "bad_tag", "granted_usernames": []}
	var granted_usernames := []
	for account in _accounts:
		if clean_tag not in (account.get("tags", []) as Array):
			continue
		var res := grant_reward(account, 0, item_ids, "admin")
		if not (res.granted as Array).is_empty():
			granted_usernames.append(str(account.get("username", "")))
	_log_admin_action(admin_username, "grant_to_tag", 0,
		"'%s' -> items %s -> %d account(s): %s" % [
			clean_tag, str(item_ids), granted_usernames.size(), ", ".join(granted_usernames),
		])
	return {"ok": true, "error": "", "granted_usernames": granted_usernames}


## Every tournament this account has ever participated in, most recent first
## (by start_ts), capped at `limit`. Placement/payout are derived from the
## same data pay_tournament_prizes() already uses, so this stays correct even
## for tournaments that haven't been queried this way before.
func recent_tournament_history(account_id: int, limit := 30) -> Array:
	var mine := []
	for t in _tournaments:
		for p in (t.get("participants", []) as Array):
			if int(p.get("account_id", -1)) == account_id:
				mine.append(t)
				break
	mine.sort_custom(func(a, b): return int(a.get("start_ts", 0)) > int(b.get("start_ts", 0)))

	var out := []
	for i in range(mini(limit, mine.size())):
		var t: Dictionary = mine[i]
		var placement := ""
		var prize_points := 0
		var prize_items := []
		for pay in (t.get("payout_records", []) as Array):
			if int(pay.get("account_id", -1)) == account_id:
				placement = str(pay.get("bucket", ""))
				prize_points = int(pay.get("points", 0))
				prize_items = pay.get("granted", [])
				break
		out.append({
			"id": int(t.get("id", 0)),
			"name": str(t.get("name", "")),
			"status": str(t.get("status", "")),
			"start_ts": int(t.get("start_ts", 0)),
			"placement_bucket": placement,
			"prize_points": prize_points,
			"prize_items": prize_items,
			"rolled_back": bool(t.get("rolled_back", false)),
		})
	return out


func recent_reward_log(account_id: int, limit := 30) -> Array:
	var account := get_account(account_id)
	if account.is_empty():
		return []
	var log: Array = account.get("reward_log", [])
	return log.slice(maxi(0, log.size() - limit))


func recent_achievement_log(account_id: int, limit := 30) -> Array:
	var account := get_account(account_id)
	if account.is_empty():
		return []
	var log: Array = account.get("achievement_log", [])
	return log.slice(maxi(0, log.size() - limit))


func recent_shop_log(account_id: int, limit := 30) -> Array:
	var account := get_account(account_id)
	if account.is_empty():
		return []
	var log: Array = account.get("shop_log", [])
	return log.slice(maxi(0, log.size() - limit))


## Everything the admin tool's account-detail view needs beyond
## account_admin_view() in one call, so the UI doesn't have to sequence 5
## separate RPC round-trips per account selected.
func account_activity(account_id: int) -> Dictionary:
	return {
		"matches": recent_matches(account_id, 30),
		"tournaments": recent_tournament_history(account_id, 30),
		"rewards": recent_reward_log(account_id, 30),
		"achievements": recent_achievement_log(account_id, 30),
		"shop": recent_shop_log(account_id, 30),
		"points_ledger": recent_points_ledger(account_id, 30),
	}


## Tournaments that started within the last `days` days, most recent first,
## capped at `limit`. Mirrors list_tournaments()'s row shape plus admin-only
## fields (winner, total prize pool, rollback state).
func recent_tournaments(days := 30, limit := 100) -> Array:
	var cutoff := int(Time.get_unix_time_from_system()) - days * 86400
	var rows := []
	for t in _tournaments:
		if int(t.get("start_ts", 0)) < cutoff:
			continue
		var prize_total := 0
		for bucket in (t.get("prizes", {}) as Dictionary).values():
			prize_total += int((bucket as Dictionary).get("points", 0))
		rows.append({
			"id": int(t.get("id", 0)),
			"name": str(t.get("name", "")),
			"status": str(t.get("status", "")),
			"start_ts": int(t.get("start_ts", 0)),
			"completed_ts": int(t.get("completed_ts", 0)),
			"participant_count": (t.get("participants", []) as Array).size(),
			"winner_account_id": int(t.get("winner_account_id", 0)),
			"prize_pool_points": prize_total,
			"prizes_paid": bool(t.get("prizes_paid", false)),
			"rolled_back": bool(t.get("rolled_back", false)),
		})
	rows.sort_custom(func(a, b): return int(a.start_ts) > int(b.start_ts))
	if rows.size() > limit:
		rows = rows.slice(0, limit)
	return rows


## Full admin view of one tournament: parameters + every participant's
## placement and payout (derived from payout_records, same source rollback
## reads from).
func tournament_admin_detail(tournament_id: int) -> Dictionary:
	var t := get_tournament(tournament_id)
	if t.is_empty():
		return {}
	var payouts_by_account := {}
	for pay in (t.get("payout_records", []) as Array):
		payouts_by_account[int(pay.get("account_id", -1))] = pay

	var participants := []
	var total_rounds := (t.get("rounds", []) as Array).size()
	for p in (t.get("participants", []) as Array):
		var acc_id := int(p.get("account_id", 0))
		var account := get_account(acc_id)
		var pay: Dictionary = payouts_by_account.get(acc_id, {})
		participants.append({
			"account_id": acc_id,
			"username": str(account.get("username", "Unknown")),
			"eliminated_round": int(p.get("eliminated_round", 0)),
			"placement_bucket": TournamentPrizes.bucket_for_placement(int(p.get("eliminated_round", 0)), total_rounds),
			"prize_points": int(pay.get("points", 0)),
			"prize_items": pay.get("granted", []),
		})

	return {
		"id": int(t.get("id", 0)),
		"name": str(t.get("name", "")),
		"status": str(t.get("status", "")),
		"availability": str(t.get("availability", "open")),
		"bracket_size": int(t.get("bracket_size", 0)),
		"match_format": int(t.get("match_format", 1)),
		"start_ts": int(t.get("start_ts", 0)),
		"completed_ts": int(t.get("completed_ts", 0)),
		"winner_account_id": int(t.get("winner_account_id", 0)),
		"prizes": t.get("prizes", {}),
		"prizes_paid": bool(t.get("prizes_paid", false)),
		"rolled_back": bool(t.get("rolled_back", false)),
		"rolled_back_ts": int(t.get("rolled_back_ts", 0)),
		"rolled_back_by": str(t.get("rolled_back_by", "")),
		"participants": participants,
	}


## Undo a completed tournament's prize payout: subtract the points and
## remove the items each recipient's payout_records entry granted them.
## Idempotent (guarded by `rolled_back`), same style as escrow_refunded /
## prizes_paid. Does NOT touch elo, quest progress, or achievement unlocks
## earned by actually playing the matches — only the prize itself. Entry
## costs aren't implemented yet; when they are, refunding them belongs here
## too (t["entry_cost_*"] would be reversed alongside the payout below).
func rollback_tournament(tournament_id: int, admin_username: String) -> Dictionary:
	var t := get_tournament(tournament_id)
	if t.is_empty():
		return {"ok": false, "error": "no_such_tournament", "tournament": {}}
	if bool(t.get("rolled_back", false)):
		return {"ok": false, "error": "already_rolled_back", "tournament": tournament_admin_detail(tournament_id)}
	if not bool(t.get("prizes_paid", false)):
		return {"ok": false, "error": "nothing_paid_out", "tournament": tournament_admin_detail(tournament_id)}

	for pay in (t.get("payout_records", []) as Array):
		var acc_id := int(pay.get("account_id", -1))
		var account := get_account(acc_id)
		if account.is_empty():
			continue
		var points_to_claw_back := int(pay.get("points", 0))
		if points_to_claw_back > 0:
			var before := int(account.get("points", 0))
			account["points"] = maxi(0, before - points_to_claw_back)
			_log_points_ledger(account, "tournament_rollback", int(account["points"]) - before, "tournament #%d" % tournament_id)
		var owned: Array = account.get("owned_rewards", [])
		for item_id in (pay.get("granted", []) as Array):
			owned.erase(item_id)
	_save_accounts()

	t["rolled_back"] = true
	t["rolled_back_ts"] = int(Time.get_unix_time_from_system())
	t["rolled_back_by"] = admin_username
	_save_tournaments()
	_log_admin_action(admin_username, "rollback_tournament", 0, "tournament #%d '%s'" % [tournament_id, str(t.get("name", ""))])
	return {"ok": true, "error": "", "tournament": tournament_admin_detail(tournament_id)}


## Roll the daily reset if needed, then apply ONE finished match's result to this
## account's quests. Mutates + persists the account (adds any earned points to
## account["points"] — the same pool shop purchases spend). Caller MUST only
## invoke this for non-bot, human-vs-human matches — ranked or tournament (see
## net_node._finish_match / _finish_tournament_match). Solo and custom matches
## never call this.
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
		_log_points_ledger(account, "quest", int(res["points_awarded"]))

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


## Max entries kept per per-account history log (reward/achievement/shop) —
## an activity trail for the admin tool, not a permanent ledger. The admin
## tool only ever displays the last 30; this just bounds account file size.
const ACCOUNT_LOG_MAX := 100

## Append `entry` (a plain Dictionary) to account[log_key], trimming to
## ACCOUNT_LOG_MAX. Does NOT persist — callers already call _save_accounts()
## for the rest of what they just mutated.
func _append_account_log(account: Dictionary, log_key: String, entry: Dictionary) -> void:
	var log: Array = account.get(log_key, [])
	log.append(entry)
	if log.size() > ACCOUNT_LOG_MAX:
		log = log.slice(log.size() - ACCOUNT_LOG_MAX)
	account[log_key] = log


## Append one achievement_log entry per newly-unlocked tier (AchievementSystem
## .evaluate()'s "newly" list) for the admin tool's "recent achievements" view.
func _log_achievement_unlocks(account: Dictionary, newly: Array) -> void:
	if newly.is_empty():
		return
	var ts := int(Time.get_unix_time_from_system())
	for entry in newly:
		_append_account_log(account, "achievement_log", {
			"ts": ts,
			"id": str(entry.get("id", "")),
			"name": str(entry.get("name", "")),
			"tier_index": int(entry.get("tier_index", 0)),
			"tier_name": str(entry.get("tier_name", "")),
			"points": int(entry.get("points", 0)),
		})


## Every points-changing event, one source-tagged entry each — the admin
## tool's per-account "points ledger" view. Call AFTER account["points"] has
## already been mutated, so balance_after reflects the real post-change total.
## `delta` is signed: positive = came in, negative = went out.
func _log_points_ledger(account: Dictionary, source: String, delta: int, details := "") -> void:
	if delta == 0:
		return
	_append_account_log(account, "points_ledger", {
		"ts": int(Time.get_unix_time_from_system()),
		"source": source,
		"delta": delta,
		"balance_after": int(account.get("points", 0)),
		"details": details,
	})


func recent_points_ledger(account_id: int, limit := 30) -> Array:
	var account := get_account(account_id)
	if account.is_empty():
		return []
	var log: Array = account.get("points_ledger", [])
	return log.slice(maxi(0, log.size() - limit))


## Credit `points_award` into account["points"] and grant every id in
## `item_ids` the account does not already own. Persists. Returns
## {"points_total": int, "granted": Array of newly-owned ids}. `source`
## (e.g. "achievement", "tournament") is recorded in account["reward_log"]
## for the admin tool's "recent unlocks" view — every reward-granting path
## in the codebase routes through here, so this one hook covers all of them.
func grant_reward(account: Dictionary, points_award: int, item_ids: Array, source := "achievement") -> Dictionary:
	if int(points_award) > 0:
		account["points"] = int(account.get("points", 0)) + int(points_award)
		_log_points_ledger(account, "tournament_prize" if source == "tournament" else "achievement_reward", int(points_award))
	var granted := []
	var owned: Array = account.get("owned_rewards", [])
	for id in item_ids:
		var id_str := str(id)
		if id_str != "" and id_str not in owned:
			owned.append(id_str)
			granted.append(id_str)
	if int(points_award) > 0 or not granted.is_empty():
		_append_account_log(account, "reward_log", {
			"ts": int(Time.get_unix_time_from_system()),
			"source": source,
			"points": int(points_award),
			"items": granted,
		})
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
	_log_points_ledger(account, "shop_purchase", -price, item_id)
	owned.append(item_id)
	_append_account_log(account, "shop_log", {
		"ts": int(Time.get_unix_time_from_system()),
		"item_id": item_id,
		"price": price,
	})
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
	_log_achievement_unlocks(account, ach_res["newly"])

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
	_log_achievement_unlocks(account, ach_res["newly"])
	grant_reward(account, int(ach_res["points_awarded"]), ach_res["reward_ids"], "tournament")

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


## FIDE B.02: 40 during a player's first 30 rated games, then 20 unless the
## player's rating has ever reached the high-elo threshold (2400), in which
## case it drops to 10 permanently — hence `peak_elo` rather than current elo.
static func k_factor(games_played: int, peak_elo: int) -> int:
	if games_played < K_PHASE_GAMES:
		return 40
	elif peak_elo >= K_HIGH_ELO_THRESHOLD:
		return 10
	return 20


static func apply_result(elo_a: int, games_a: int, peak_a: int, elo_b: int, games_b: int, peak_b: int, winner: int) -> Dictionary:
	var score_a := 1.0 if winner == 1 else (0.5 if winner == 0 else 0.0)
	var score_b := 1.0 - score_a
	var delta_a := int(round(k_factor(games_a, peak_a) * (score_a - expected_score(elo_a, elo_b))))
	var delta_b := int(round(k_factor(games_b, peak_b) * (score_b - expected_score(elo_b, elo_a))))
	var elo_a_after := elo_a + delta_a
	var elo_b_after := elo_b + delta_b
	return {
		"elo_a_after": elo_a_after,
		"elo_b_after": elo_b_after,
		"delta_a": delta_a,
		"delta_b": delta_b,
		"peak_a_after": maxi(peak_a, elo_a_after),
		"peak_b_after": maxi(peak_b, elo_b_after),
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
	var games_2_before := 1000  # bot: fixed, high game count => k_factor 10
	var peak_2_before := START_ELO
	if is_real:
		account_2 = get_account(a2_id)
		if account_2.is_empty():
			push_error("ServerStore.record_match: account 2 not found: %d" % a2_id)
			return {}
		elo_2_before = int(account_2.get("elo", START_ELO))
		games_2_before = int(account_2.get("games", 0))
		peak_2_before = int(account_2.get("peak_elo", elo_2_before))

	var elo_1_before := int(account_1.get("elo", START_ELO))
	var games_1_before := int(account_1.get("games", 0))
	var peak_1_before := int(account_1.get("peak_elo", elo_1_before))

	var res := apply_result(elo_1_before, games_1_before, peak_1_before, elo_2_before, games_2_before, peak_2_before, winner)

	_apply_account_result(account_1, res["elo_a_after"], res["peak_a_after"], _outcome_for(winner, 1), score1)
	if is_real:
		_apply_account_result(account_2, res["elo_b_after"], res["peak_b_after"], _outcome_for(winner, 2), score2)
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


func _apply_account_result(account: Dictionary, elo_after: int, peak_elo_after: int, outcome: String, own_score: int) -> void:
	account["elo"] = elo_after
	account["peak_elo"] = peak_elo_after
	_reconcile_title(account)
	account["games"] = int(account.get("games", 0)) + 1
	var match_pts := match_points(outcome, own_score)
	account["points"] = int(account.get("points", 0)) + match_pts
	_log_points_ledger(account, "match", match_pts, outcome)
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
			"elo_before": int(m.get("elo_%d_before" % seat, 0)),
			"elo_after": int(m.get("elo_%d_after" % seat, 0)),
			"points_delta": int(m.get("points_%d_delta" % seat, 0)),
			"your_score": int(m.get("score_%d" % seat, 0)),
			"opponent_score": int(m.get("score_%d" % (3 - seat), 0)),
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

## `skip_cost`: true for an admin-created tournament (one-off or recurring —
## see admin_create_tournament / tournament templates below). Bypasses the
## prize-escrow wallet charge entirely and allows ANY catalog cosmetic
## (ShopCatalog.is_premium — shop-buyable AND achievement-only ids) as a
## prize item, not just the normally-buyable subset. Player-initiated
## tournaments (skip_cost=false, the only path net_node.gd's ordinary
## _rpc_create_tournament uses) are unaffected — same pricing/escrow as
## always.
func create_tournament(created_by: int, name: String, requested_bracket_size: int,
		signup_close_ts: int, check_in_open_ts: int, start_ts: int,
		is_dev_bot: bool, allow_small := false, requested_match_format := 1,
		cube_card_ids: Array = [], availability := "open", password := "",
		private_signup_close_ts := 0, late_check_in := false,
		late_check_in_open_ts := 0, prize_spec := {}, skip_cost := false) -> Dictionary:
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
	# creator's wallet (refunded in full if the tournament never fires) —
	# UNLESS skip_cost (admin-created), which validates item ids against the
	# full catalog (any premium cosmetic) but charges nothing and never touches
	# the creator's wallet.
	var pr: Dictionary
	if skip_cost:
		pr = TournamentPrizes.sanitize(prize_spec, func(id): return 0 if ShopCatalog.is_premium(id) else -1)
	else:
		pr = TournamentPrizes.sanitize(prize_spec,
			func(id): return ShopCatalog.price_for(id) if ShopCatalog.is_buyable(id) else -1)
	if not bool(pr.ok):
		return {"ok": false, "error": pr.error, "tournament": {}}
	var creator := {}
	if not skip_cost and int(pr.cost) > 0:
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
		# 0 for skip_cost tournaments even though pr.cost is nonzero (sum of
		# prize points) — no wallet was actually charged, so there's nothing
		# for refund_tournament_escrow to ever give back.
		"prize_escrow": 0 if skip_cost else int(pr.cost),
		"escrow_refunded": false,
		"prizes_paid": false,
		"payout_records": [],
		"rolled_back": false,
		"rolled_back_ts": 0,
		"rolled_back_by": "",
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
		"completed_ts": 0,
	}
	if not skip_cost and int(pr.cost) > 0:
		creator["points"] = int(creator.get("points", 0)) - int(pr.cost)
		_log_points_ledger(creator, "tournament_entry", -int(pr.cost), "tournament #%d" % int(tournament.id))
		_save_accounts()
	_tournaments.append(tournament)
	_next_tournament_id += 1
	_save_tournaments()
	return {"ok": true, "error": "", "tournament": tournament}


# --- admin tournament creation + recurring templates ------------------------
#
# Two ways for an admin to create a tournament, both always skip_cost=true
# (see create_tournament's doc): a one-off via admin_create_tournament, or a
# recurring template that tick_tournament_templates() (called from
# net_node.gd's existing tournament tick) fires automatically. Locked design
# (confirmed with the user): admin-created prizes may be ANY catalog cosmetic
# (ShopCatalog.is_premium — shop-buyable and achievement-only alike), not
# escrowed from any wallet; recurring templates always keep the NEXT
# occurrence already created once its signup lead time arrives, even while an
# earlier occurrence from the same template is still running.

## One-time (or one recurring instance) tournament creation from the admin
## tool. `spec` is a flat Dictionary: name, bracket_size, match_format,
## availability, password, cube_ids, signup_close_ts, check_in_open_ts,
## start_ts, late_check_in, late_check_in_open_ts, prize_spec, allow_small.
func admin_create_tournament(admin_account_id: int, spec: Dictionary) -> Dictionary:
	return create_tournament(
		admin_account_id,
		str(spec.get("name", "")),
		int(spec.get("bracket_size", 32)),
		int(spec.get("signup_close_ts", 0)),
		int(spec.get("check_in_open_ts", 0)),
		int(spec.get("start_ts", 0)),
		false,
		bool(spec.get("allow_small", false)),
		int(spec.get("match_format", 1)),
		spec.get("cube_ids", []),
		str(spec.get("availability", "open")),
		str(spec.get("password", "")),
		int(spec.get("private_signup_close_ts", 0)),
		bool(spec.get("late_check_in", false)),
		int(spec.get("late_check_in_open_ts", 0)),
		spec.get("prize_spec", {}),
		true,
	)


## `spec.weekdays`: Array of int 0-6 (Sunday=0 .. Saturday=6, matching Godot's
## Time.get_datetime_dict_from_unix_time "weekday" field). `time_of_day_minutes`:
## minutes since midnight UTC (0-1439). `signup_window_hours`: how long before
## each occurrence's start_ts the tournament is created (signup opens
## immediately on creation, closes when check-in opens). `check_in_window_minutes`
## must be > 0 (check-in must open strictly before start).
func create_tournament_template(admin_account_id: int, spec: Dictionary) -> Dictionary:
	var clean_name := str(spec.get("name", "")).strip_edges()
	if clean_name.length() < 1 or clean_name.length() > 60:
		return {"ok": false, "error": "bad_name", "template": {}}

	var weekdays := []
	for d in (spec.get("weekdays", []) as Array):
		var di := int(d)
		if di >= 0 and di <= 6 and di not in weekdays:
			weekdays.append(di)
	if weekdays.is_empty():
		return {"ok": false, "error": "bad_weekdays", "template": {}}

	var time_of_day := int(spec.get("time_of_day_minutes", -1))
	if time_of_day < 0 or time_of_day > 1439:
		return {"ok": false, "error": "bad_time_of_day", "template": {}}

	var signup_hours := int(spec.get("signup_window_hours", 24))
	if signup_hours <= 0:
		return {"ok": false, "error": "bad_signup_window", "template": {}}

	var check_in_minutes := int(spec.get("check_in_window_minutes", 30))
	if check_in_minutes <= 0:
		return {"ok": false, "error": "bad_check_in_window", "template": {}}

	# Validate the prize spec up front (same permissive admin pricing as
	# admin_create_tournament) so a bad template fails once here rather than
	# silently every time the scheduler tries and can't create it.
	var pr := TournamentPrizes.sanitize(spec.get("prize_spec", {}), func(id): return 0 if ShopCatalog.is_premium(id) else -1)
	if not bool(pr.ok):
		return {"ok": false, "error": pr.error, "template": {}}

	var template := {
		"id": _next_template_id,
		"name": clean_name,
		"weekdays": weekdays,
		"time_of_day_minutes": time_of_day,
		"bracket_size": int(spec.get("bracket_size", 32)),
		"match_format": int(spec.get("match_format", 1)) if int(spec.get("match_format", 1)) in [1, 3] else 1,
		"availability": str(spec.get("availability", "open")),
		"password": str(spec.get("password", "")),
		"cube_ids": spec.get("cube_ids", []),
		"signup_window_hours": signup_hours,
		"check_in_window_minutes": check_in_minutes,
		"late_check_in": bool(spec.get("late_check_in", false)),
		"late_check_in_minutes_before_start": maxi(0, int(spec.get("late_check_in_minutes_before_start", 0))),
		"prize_spec": pr.prizes,
		"allow_small": bool(spec.get("allow_small", false)),
		"active": true,
		"created_by_account_id": admin_account_id,
		"created_ts": int(Time.get_unix_time_from_system()),
		"last_created_start_ts": 0,
	}
	_tournament_templates.append(template)
	_next_template_id += 1
	_save_tournament_templates()
	return {"ok": true, "error": "", "template": template}


func list_tournament_templates() -> Array:
	return _tournament_templates


func get_tournament_template(template_id: int) -> Dictionary:
	for t in _tournament_templates:
		if int(t.get("id", -1)) == template_id:
			return t
	return {}


func delete_tournament_template(template_id: int) -> bool:
	for i in range(_tournament_templates.size()):
		if int(_tournament_templates[i].get("id", -1)) == template_id:
			_tournament_templates.remove_at(i)
			_save_tournament_templates()
			return true
	return false


func set_tournament_template_active(template_id: int, active: bool) -> Dictionary:
	var t := get_tournament_template(template_id)
	if t.is_empty():
		return {"ok": false, "error": "no_such_template", "template": {}}
	t["active"] = active
	_save_tournament_templates()
	return {"ok": true, "error": "", "template": t}


## Next unix-second timestamp matching one of `weekdays` at
## `time_of_day_minutes`, strictly after `after_ts`. Scans forward day by day;
## 8 days always covers a full week even when `after_ts` falls later in the
## day than time_of_day_minutes on an otherwise-matching weekday.
static func _next_occurrence_ts(weekdays: Array, time_of_day_minutes: int, after_ts: int) -> int:
	var day_start := after_ts - (after_ts % 86400)
	for offset in range(8):
		var candidate_day := day_start + offset * 86400
		var dt := Time.get_datetime_dict_from_unix_time(candidate_day)
		if int(dt.weekday) in weekdays:
			var candidate_ts := candidate_day + time_of_day_minutes * 60
			if candidate_ts > after_ts:
				return candidate_ts
	return 0


## Called every server tournament tick (net_node.gd's existing 5s
## _tick_tournaments). For each active template, ensures the NEXT occurrence
## is already created once its signup lead time arrives — even while an
## earlier occurrence from the same template is still running (locked
## decision: always keep one queued ahead). Returns the tournaments actually
## created this call (normally empty — this only does anything once every
## few days/weeks per template).
func tick_tournament_templates(now := -1) -> Array:
	if now < 0:
		now = int(Time.get_unix_time_from_system())
	var created := []
	for t in _tournament_templates:
		if not bool(t.get("active", false)):
			continue
		var after := int(t.get("last_created_start_ts", 0))
		if after < now:
			after = now
		var next_start := _next_occurrence_ts(t.weekdays, int(t.time_of_day_minutes), after)
		if next_start <= 0 or int(t.get("last_created_start_ts", 0)) >= next_start:
			continue

		var signup_open_ts := next_start - int(t.signup_window_hours) * 3600
		if now < signup_open_ts:
			continue  # not time to open signup for this occurrence yet

		var check_in_open_ts := next_start - int(t.check_in_window_minutes) * 60
		var late_open_ts := 0
		if bool(t.get("late_check_in", false)) and int(t.get("late_check_in_minutes_before_start", 0)) > 0:
			late_open_ts = next_start - int(t.late_check_in_minutes_before_start) * 60

		var res := admin_create_tournament(int(t.created_by_account_id), {
			"name": "%s — %s" % [str(t.name), Time.get_date_string_from_unix_time(next_start)],
			"bracket_size": int(t.bracket_size),
			"match_format": int(t.match_format),
			"availability": str(t.availability),
			"password": str(t.get("password", "")),
			"cube_ids": t.get("cube_ids", []),
			"signup_close_ts": check_in_open_ts,
			"check_in_open_ts": check_in_open_ts,
			"start_ts": next_start,
			"late_check_in": bool(t.get("late_check_in", false)),
			"late_check_in_open_ts": late_open_ts,
			"prize_spec": t.get("prize_spec", {}),
			"allow_small": bool(t.get("allow_small", false)),
		})
		# On failure (e.g. a bad schedule combination), deliberately do NOT
		# update last_created_start_ts — the tick will just keep retrying this
		# same occurrence every 5s until it either succeeds or is disabled.
		if bool(res.get("ok", false)):
			t["last_created_start_ts"] = next_start
			_save_tournament_templates()
			created.append(res.tournament)
	return created


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
		_log_points_ledger(creator, "tournament_refund", amt, "tournament #%d" % int(t.get("id", 0)))
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
			var res := grant_reward(account, int(prize.get("points", 0)), prize.get("items", []), "tournament")
			payouts.append({
				"account_id": int(p.account_id),
				"bucket": bucket,
				"points": int(prize.get("points", 0)),
				"granted": res.get("granted", []),
			})
	t["prizes_paid"] = true
	t["payout_records"] = payouts
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
	# Denormalized the same way list_tournaments() already does — the bracket
	# screen only ever gets `created_by_account_id` from the raw record
	# otherwise, and has no other way to show who made it.
	var creator := get_account(int(t.get("created_by_account_id", 0)))
	v["creator_name"] = str(creator.get("display_name", "—"))
	v["creator_avatar"] = str(creator.get("avatar", ""))
	v["creator_frame"] = str(creator.get("frame", ""))
	v["creator_background"] = str(creator.get("background", ""))
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
		"title": str(account.get("title", "")),
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


func _save_admin_log() -> void:
	var file := FileAccess.open(_dir + "admin_log.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"actions": _admin_log}, "\t"))


func _save_presence() -> void:
	var file := FileAccess.open(_dir + "presence.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"samples": _presence_samples}, "\t"))


func _save_tournament_templates() -> void:
	var file := FileAccess.open(_dir + "tournament_templates.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"templates": _tournament_templates}, "\t"))


## Called by net_node.gd's presence timer every PRESENCE_SAMPLE_SECONDS.
func record_presence_sample(count: int) -> void:
	_presence_samples.append({"ts": int(Time.get_unix_time_from_system()), "count": count})
	if _presence_samples.size() > PRESENCE_MAX:
		_presence_samples = _presence_samples.slice(_presence_samples.size() - PRESENCE_MAX)
	_save_presence()


## Samples from the last `hours` hours, oldest first (natural plot order).
func presence_samples_since(hours: int) -> Array:
	var cutoff := int(Time.get_unix_time_from_system()) - hours * 3600
	var out := []
	for s in _presence_samples:
		if int(s.get("ts", 0)) >= cutoff:
			out.append(s)
	return out
