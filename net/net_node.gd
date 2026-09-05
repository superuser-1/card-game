extends Node
## Autoload singleton ("Net"), present in every running instance — server,
## networked client, or singleplayer (local, vs bot). Owns the
## ENetMultiplayerPeer connection when networked, and is the single fixed-path
## RPC target both sides call into ("/root/Net" resolves identically on server
## and client since they run the same project).
##
## Role is chosen explicitly by whoever bootstraps the process (see main.gd),
## never auto-detected.
##
## Server responsibilities now, beyond running the rules engine:
##   * authenticate every peer (username/password) before it may do anything
##   * run MANY concurrent matches (see Match), routing each RPC by sender peer
##   * a matchmaking queue that pairs by Elo, widening the window on wait time,
##     and fills a lonely queue with a bot after BOT_FILL_SECONDS
##   * on game over: write the result (Elo/points) via ServerStore and push a
##     personalised match_ended summary to each human seat
##
## Singleplayer is modelled as just another Match (one human seat, one bot
## seat) so the bot driver and match-end path are shared with networked bot
## matches. Singleplayer never touches ServerStore and is always unranked.

# --- existing signals (unchanged contract) ---
signal state_updated(state: Dictionary)
signal error_received(message: String)
signal player_assigned(player_id: int)

# --- new client-facing signals ---
signal auth_completed(result: Dictionary)       # {ok, error, token, account}
signal queue_updated(state: String, elapsed_s: float)   # "searching" | "cancelled"
signal match_found(info: Dictionary)
signal match_ended(summary: Dictionary)
signal ladder_received(data: Dictionary)
signal profile_received(data: Dictionary)
signal avatar_updated(account: Dictionary)      # fresh account snapshot after set_avatar
signal frame_updated(account: Dictionary)       # fresh account snapshot after set_frame
signal background_updated(account: Dictionary)  # fresh account snapshot after set_background

const BOT_THINK_SECONDS := 0.7
const BOT_FILL_SECONDS := 15.0
const MM_TICK_SECONDS := 1.0

## Per-turn clock: the player who is on the clock (choosing a category, or
## responding) has this many seconds to act. If it expires the server calls
## GameEngine.resolve_timeout — they forfeit the category and lose a random
## card. Bots are never put on this clock.
const TURN_SECONDS := 30.0

# Sentinels for Match.seats — a seat is either a real peer_id (>0) or one of:
const BOT_SEAT := -1
const LOCAL_SEAT := -2

var is_server := false
var is_solo := false

## True once start_client() has run — i.e. this process is fundamentally a
## networked client that connected to a real server. The menu's Singleplayer
## button flips is_server/is_solo true to host a local match on such a client;
## end_singleplayer() uses this to know it must flip them back afterwards (a
## dedicated --solo process has no networked role to return to).
var _is_networked_client := false

# --- server-side bookkeeping (networked server only) ---
var _store: ServerStore = null
var _peer_account: Dictionary = {}      # peer_id -> account_id
var _peer_token: Dictionary = {}        # peer_id -> token
var _token_peer: Dictionary = {}        # token -> peer_id (current live binding)
var _token_account: Dictionary = {}     # token -> account_id (survives peer churn, for resume)
var _account_peer: Dictionary = {}      # account_id -> peer_id (one live connection per account)
var _matches: Dictionary = {}           # match_id -> Match dict
var _peer_match: Dictionary = {}        # peer_id -> match_id
var _next_match_id := 1
var _queue: Array = []                  # [{account_id, peer_id, elo, since_ms}]
var _mm_timer: Timer = null

# --- solo-only ---
var _solo_match_id := 0
var _sp_reveal := false                 # reserved: opponent-card reveal in singleplayer

# --- client-side bookkeeping (networked client only) ---
var my_player_id := 0
var _last_state: Dictionary = {}
var _last_assigned_player := 0

# Server/solo: 1s housekeeping tick that enforces the per-turn clock.
var _turn_timer: Timer = null
# Effective per-turn clock; TURN_SECONDS unless overridden with a
# `--turn-seconds=N` command-line user arg (dev/testing).
var _turn_seconds := TURN_SECONDS

# Matchmaking dev overrides (server-only command-line user args):
#   --bot-fill-seconds=N  how long a lonely queuer waits before being given a
#                         bot (default BOT_FILL_SECONDS; pass a huge value to
#                         effectively disable bot-fill).
#   --mm-any              ignore Elo entirely and immediately pair the two
#                         longest-waiting queuers. For local 2-client testing
#                         where the test accounts' Elo has drifted apart.
var _bot_fill_seconds := BOT_FILL_SECONDS
var _mm_any := false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--turn-seconds="):
			_turn_seconds = maxf(1.0, float(arg.substr("--turn-seconds=".length())))
			print("Net: per-turn clock overridden to %.0fs" % _turn_seconds)
		elif arg.begins_with("--bot-fill-seconds="):
			_bot_fill_seconds = maxf(0.0, float(arg.substr("--bot-fill-seconds=".length())))
			print("Net: bot-fill wait overridden to %.0fs" % _bot_fill_seconds)
		elif arg == "--mm-any":
			_mm_any = true
			print("Net: matchmaking will ignore Elo (--mm-any)")

	_turn_timer = Timer.new()
	# Poll fairly tightly so the timeout fires close to the true deadline
	# rather than up to a full second late.
	_turn_timer.wait_time = 0.25
	_turn_timer.autostart = true
	add_child(_turn_timer)
	_turn_timer.timeout.connect(_tick_turn_timers)


# =========================================================================
# Bootstrap
# =========================================================================

func start_server(port: int = NetConfig.DEFAULT_PORT) -> void:
	is_server = true
	is_solo = false
	_store = ServerStore.new()
	_store.open()

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, NetConfig.MAX_SERVER_PEERS)
	if err != OK:
		push_error("GameServer: failed to listen on port %d (error %d)" % [port, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	_mm_timer = Timer.new()
	_mm_timer.wait_time = MM_TICK_SECONDS
	_mm_timer.autostart = true
	add_child(_mm_timer)
	_mm_timer.timeout.connect(_tick_matchmaking)

	print("GameServer: listening on port %d" % port)


func start_client(address: String = NetConfig.DEFAULT_ADDRESS, port: int = NetConfig.DEFAULT_PORT) -> void:
	is_server = false
	is_solo = false
	_is_networked_client = true
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("Client: failed to connect to %s:%d (error %d)" % [address, port, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(func(): print("Client: connected to server"))
	multiplayer.connection_failed.connect(func(): error_received.emit("Could not connect to server."))
	multiplayer.server_disconnected.connect(func(): error_received.emit("Disconnected from server."))


## --- Client -> Server auth wrappers (the UI calls these) ---

func auth_register(username: String, password: String) -> void:
	_rpc_auth_register.rpc_id(1, username, password)


## Set (or change) the logged-in account's avatar. Reply comes back on
## `avatar_updated` with a fresh account snapshot.
func set_avatar(avatar: String) -> void:
	_rpc_set_avatar.rpc_id(1, avatar)


## Set (or clear, with "") the logged-in account's avatar frame. Reply comes
## back on `frame_updated` with a fresh account snapshot.
func set_frame(frame: String) -> void:
	_rpc_set_frame.rpc_id(1, frame)


## Set (or clear, with "") the logged-in account's background. Reply comes
## back on `background_updated` with a fresh account snapshot.
func set_background(background: String) -> void:
	_rpc_set_background.rpc_id(1, background)


func auth_login(username: String, password: String) -> void:
	_rpc_auth_login.rpc_id(1, username, password)


func auth_resume(token: String) -> void:
	_rpc_auth_resume.rpc_id(1, token)


## Singleplayer: no networking, a local GameEngine with player 1 as the human
## (driven by the UI via submit_*), player 2 driven by BotPlayer. Always
## unranked. `start_solo()` is kept as the no-arg alias used by the --solo CLI
## role and the headless smoke tests.
func start_solo() -> void:
	start_singleplayer(false)


func start_singleplayer(reveal := false) -> void:
	is_server = true
	is_solo = true
	my_player_id = 1
	_sp_reveal = reveal

	var cards := CardLoader.load_cards()
	var engine := GameEngine.new(cards)
	engine.deal_hands()

	var m := _new_match(engine, {1: LOCAL_SEAT, 2: BOT_SEAT}, {1: 0, 2: 0}, {1: "You", 2: "Bot"}, 2, false)
	_solo_match_id = m.id
	print("Singleplayer: match started, %d cards, vs bot" % cards.size())

	_last_assigned_player = 1
	player_assigned.emit(1)
	# Solo has no real match_found handshake; emit a minimal one so the game UI
	# can render the opponent (bot) panel. The UI fills "your" side from
	# Session.account.
	match_found.emit({
		"match_id": m.id,
		"your_seat": 1,
		"opponent_name": "Bot",
		"opponent_avatar": Avatars.BOT_ID,
		"opponent_frame": "",
		"opponent_background": "",
		"opponent_elo": ServerStore.START_ELO,
		"is_bot_match": true,
	})
	_broadcast_match(m)


## Tear down a local singleplayer match and hand the process back to whatever
## role it had before it was started. On a networked client (the menu's
## Singleplayer button temporarily set is_server/is_solo to host the match
## locally) this clears both flags so the client-facing RPC guards — and thus
## matchmaking, cancel, ladder, etc. — work again. On a dedicated --solo
## process there's no networked role to return to, so it just drops the match.
## Safe to call when no solo match is running.
func end_singleplayer() -> void:
	if _solo_match_id != 0:
		_matches.erase(_solo_match_id)
		_solo_match_id = 0
	is_solo = false
	_last_state = {}
	_last_assigned_player = 0
	my_player_id = 0
	if _is_networked_client:
		is_server = false


# =========================================================================
# Match structure
# =========================================================================

func _new_match(engine: GameEngine, seats: Dictionary, account_ids: Dictionary,
		names: Dictionary, bot_seat: int, is_bot_match: bool) -> Dictionary:
	var m := {
		"id": _next_match_id,
		"engine": engine,
		"seats": seats,              # {1: peer_id|BOT_SEAT|LOCAL_SEAT, 2: ...}
		"account_ids": account_ids,  # {1: int (0 = bot/local), 2: int}
		"names": names,              # {1: String, 2: String}
		"bot_seat": bot_seat,        # 0, 1 or 2
		"is_bot_match": is_bot_match,
		"ended": false,
		"turn_started_ms": Time.get_ticks_msec(),
		"on_clock_seat": 0,          # 1|2 while the match is live, 0 otherwise
	}
	_next_match_id += 1
	_matches[m.id] = m
	for seat in [1, 2]:
		var s = seats[seat]
		if typeof(s) == TYPE_INT and s > 0:
			_peer_match[s] = m.id
	return m


func _seat_of_peer(m: Dictionary, peer_id: int) -> int:
	if m.seats.get(1) == peer_id:
		return 1
	if m.seats.get(2) == peer_id:
		return 2
	return 0


func _match_for_peer(peer_id: int) -> Dictionary:
	if not _peer_match.has(peer_id):
		return {}
	return _matches.get(_peer_match[peer_id], {})


# =========================================================================
# State broadcast
# =========================================================================

func _broadcast_match(m: Dictionary) -> void:
	var engine: GameEngine = m.engine
	if engine == null:
		return
	# Roll (idempotently) the 3 offered categories for the active player —
	# get_state_for_player only reads this list, it never populates it.
	if engine.phase == "awaiting_category" and not engine.is_game_over():
		engine.get_offered_categories()

	# Every _broadcast_match call is a genuine turn/phase change, so (re)start
	# the turn clock here for whoever is now on it.
	var on_clock := 0
	if not engine.is_game_over():
		if engine.phase == "awaiting_category":
			on_clock = engine.active_player
		elif engine.phase == "awaiting_response":
			on_clock = 3 - engine.active_player
	m.on_clock_seat = on_clock
	m.turn_started_ms = Time.get_ticks_msec()

	var now := Time.get_ticks_msec()
	for seat in [1, 2]:
		var target = m.seats[seat]
		if typeof(target) != TYPE_INT:
			continue
		var st := engine.get_state_for_player(seat)
		if on_clock != 0:
			st["on_clock_player"] = on_clock
			st["turn_seconds_left"] = maxf(0.0, _turn_seconds - (now - m.turn_started_ms) / 1000.0)
		else:
			st["on_clock_player"] = 0
			st["turn_seconds_left"] = -1.0
		if target == LOCAL_SEAT:
			_last_state = st
			state_updated.emit(st)
		elif target > 0:
			_rpc_receive_state.rpc_id(target, st)


# =========================================================================
# Move application (shared by solo, networked, and bot paths)
# =========================================================================

func submit_category_and_card(category: String, card_id: String) -> void:
	if is_solo:
		var m: Dictionary = _matches.get(_solo_match_id, {})
		if not m.is_empty():
			_apply_category(m, 1, category, card_id)
	else:
		_rpc_submit_category_and_card.rpc_id(1, category, card_id)


func submit_response_card(card_id: String) -> void:
	if is_solo:
		var m: Dictionary = _matches.get(_solo_match_id, {})
		if not m.is_empty():
			_apply_response(m, 1, card_id)
	else:
		_rpc_submit_response_card.rpc_id(1, card_id)


## Give up the whole match. The caller is recorded as the loser (Elo/points
## adjust accordingly), then the normal match_ended summary flows to both
## sides so the result screen shows the rating change.
func forfeit_match() -> void:
	if is_solo:
		var m: Dictionary = _matches.get(_solo_match_id, {})
		if not m.is_empty() and not m.ended:
			_finish_match(m, 2)  # human is seat 1; seat 2 (bot) "wins"
	else:
		_rpc_forfeit.rpc_id(1)


func _apply_category(m: Dictionary, player_id: int, category: String, card_id: String) -> void:
	var engine: GameEngine = m.get("engine")
	if m.is_empty() or m.ended or engine == null:
		return
	var result: Dictionary = engine.submit_category_and_card(player_id, category, card_id)
	if not result.ok:
		_report_error_seat(m, player_id, result.error)
		return
	_after_move(m)


func _apply_response(m: Dictionary, player_id: int, card_id: String) -> void:
	var engine: GameEngine = m.get("engine")
	if m.is_empty() or m.ended or engine == null:
		return
	var result: Dictionary = engine.submit_response_card(player_id, card_id)
	if not result.ok:
		_report_error_seat(m, player_id, result.error)
		return
	_after_move(m)


func _after_move(m: Dictionary) -> void:
	var engine: GameEngine = m.get("engine")
	_broadcast_match(m)
	if engine.is_game_over():
		_finish_match(m)
	else:
		_maybe_trigger_bot(m)


func _report_error_seat(m: Dictionary, player_id: int, message: String) -> void:
	var target = m.seats.get(player_id)
	if target == LOCAL_SEAT:
		error_received.emit(message)
	elif typeof(target) == TYPE_INT and target > 0:
		_rpc_receive_error.rpc_id(target, message)


# =========================================================================
# Per-turn clock
# =========================================================================

func _tick_turn_timers() -> void:
	if not is_server:
		return
	var now := Time.get_ticks_msec()
	for mid in _matches.keys().duplicate():
		var m: Dictionary = _matches.get(mid, {})
		if m.is_empty() or m.ended:
			continue
		var engine: GameEngine = m.get("engine")
		if engine == null or engine.is_game_over():
			continue
		var seat: int = m.on_clock_seat
		if seat != 1 and seat != 2:
			continue
		if m.seats.get(seat) == BOT_SEAT:
			continue  # bots always move well inside the clock; never time them out
		if now - int(m.turn_started_ms) >= int(_turn_seconds * 1000.0):
			_apply_timeout(m, seat)


func _apply_timeout(m: Dictionary, seat: int) -> void:
	var engine: GameEngine = m.get("engine")
	if engine == null or engine.is_game_over() or m.ended:
		return
	engine.resolve_timeout(seat)
	_after_move(m)


# =========================================================================
# Bot driver (any match with a bot_seat, solo or networked)
# =========================================================================

func _maybe_trigger_bot(m: Dictionary) -> void:
	if m.is_empty() or m.ended or m.bot_seat == 0:
		return
	var engine: GameEngine = m.engine
	if engine == null or engine.is_game_over():
		return
	var bp: int = m.bot_seat
	if engine.phase == "awaiting_category" and engine.active_player == bp:
		get_tree().create_timer(BOT_THINK_SECONDS).timeout.connect(_bot_choose_category.bind(m.id))
	elif engine.phase == "awaiting_response" and not engine.committed_cards.has(bp):
		get_tree().create_timer(BOT_THINK_SECONDS).timeout.connect(_bot_choose_response.bind(m.id))


func _bot_choose_category(match_id: int) -> void:
	var m: Dictionary = _matches.get(match_id, {})
	if m.is_empty() or m.ended:
		return
	var engine: GameEngine = m.engine
	var bp: int = m.bot_seat
	if engine == null or engine.phase != "awaiting_category" or engine.active_player != bp:
		return
	var move := BotPlayer.choose_active_move(
		engine.current_offered_categories, engine.hands[bp], engine.get_card_pool()
	)
	_apply_category(m, bp, move.category, move.card_id)


func _bot_choose_response(match_id: int) -> void:
	var m: Dictionary = _matches.get(match_id, {})
	if m.is_empty() or m.ended:
		return
	var engine: GameEngine = m.engine
	var bp: int = m.bot_seat
	if engine == null or engine.phase != "awaiting_response" or engine.committed_cards.has(bp):
		return
	var card_id: String = BotPlayer.choose_response_card(
		engine.chosen_category, engine.hands[bp], engine.get_card_pool(),
		engine.scores[bp], engine.scores[3 - bp]
	)
	_apply_response(m, bp, card_id)


# =========================================================================
# Match end -> rating + summary
# =========================================================================

## forced_winner: -1 = decide from the score (normal game over); 0/1/2 = force
## it (a forfeit — the quitting player is passed as the loser). Elo/points are
## always computed from `winner` and the current scores.
func _finish_match(m: Dictionary, forced_winner := -1) -> void:
	if m.ended:
		return
	m.ended = true
	m.on_clock_seat = 0
	var engine: GameEngine = m.engine
	var winner := engine.get_winner() if forced_winner < 0 else forced_winner

	if is_solo or _store == null:
		var seat := 1
		var summary := {
			"outcome": _outcome_str(winner, seat),
			"your_score": engine.scores[seat],
			"opponent_score": engine.scores[3 - seat],
			"ranked": false,
			"elo_before": 0, "elo_after": 0, "elo_delta": 0,
			"points_delta": 0, "points_total": 0, "new_rank": 0,
			"quest_completions": [],
			"quest_points": 0,
		}
		match_ended.emit(summary)
	else:
		var rec := _store.record_match(
			int(m.account_ids[1]), int(m.account_ids[2]), winner,
			engine.scores[1], engine.scores[2], bool(m.is_bot_match)
		)
		for seat in [1, 2]:
			var target = m.seats[seat]
			if typeof(target) != TYPE_INT or target <= 0:
				continue
			var acc_id := int(m.account_ids[seat])
			var before := int(rec.get("elo_%d_before" % seat, 0))
			var after := int(rec.get("elo_%d_after" % seat, 0))
			var quest_completions := []
			var quest_points := 0
			if not bool(m.is_bot_match):
				var q_ctx := {
					"outcome": _outcome_str(winner, seat),
					"your_score": engine.scores[seat],
					"opp_score": engine.scores[3 - seat],
					"your_group_picks": engine.group_pick_counts(seat),
					"your_pick_count": engine.pick_count(seat),
				}
				var q_res := _store.apply_quest_progress(acc_id, q_ctx)
				quest_completions = q_res["completed"]
				quest_points = int(q_res["points_awarded"])
			var summary := {
				"outcome": _outcome_str(winner, seat),
				"your_score": engine.scores[seat],
				"opponent_score": engine.scores[3 - seat],
				"ranked": true,
				"elo_before": before,
				"elo_after": after,
				"elo_delta": after - before,
				"points_delta": int(rec.get("points_%d_delta" % seat, 0)),
				"points_total": int(_store.get_account(acc_id).get("points", 0)),
				"new_rank": _store.rank_of(acc_id),
				"quest_completions": quest_completions,
				"quest_points": quest_points,
			}
			_rpc_match_ended.rpc_id(target, summary)

	_cleanup_match(m)


func _outcome_str(winner: int, seat: int) -> String:
	if winner == 0:
		return "draw"
	return "win" if winner == seat else "loss"


func _cleanup_match(m: Dictionary) -> void:
	for seat in [1, 2]:
		var target = m.seats[seat]
		if typeof(target) == TYPE_INT and target > 0:
			_peer_match.erase(target)
	_matches.erase(m.id)
	if m.id == _solo_match_id:
		_solo_match_id = 0


# =========================================================================
# Connection lifecycle (networked server)
# =========================================================================

func _on_peer_connected(peer_id: int) -> void:
	if not is_server:
		return
	print("GameServer: peer %d connected (unauthenticated)" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_server:
		return
	print("GameServer: peer %d disconnected" % peer_id)

	_queue = _queue.filter(func(e): return e.peer_id != peer_id)

	if _peer_token.has(peer_id):
		var tok: String = _peer_token[peer_id]
		if _token_peer.get(tok) == peer_id:
			_token_peer.erase(tok)
		_peer_token.erase(peer_id)
	if _peer_account.has(peer_id):
		var acc: int = _peer_account[peer_id]
		if _account_peer.get(acc) == peer_id:
			_account_peer.erase(acc)
		_peer_account.erase(peer_id)

	# Abort any match this peer was in. MVP: no forfeit rating penalty.
	# TODO: award the remaining player a ranked win on opponent abandon.
	if _peer_match.has(peer_id):
		var m: Dictionary = _matches.get(_peer_match[peer_id], {})
		_peer_match.erase(peer_id)
		if not m.is_empty() and not m.ended:
			m.ended = true
			for seat in [1, 2]:
				var other = m.seats[seat]
				if other != peer_id and typeof(other) == TYPE_INT and other > 0:
					_peer_match.erase(other)
					_rpc_receive_error.rpc_id(other, "Opponent disconnected. Match ended.")
			_matches.erase(m.id)


func _require_auth(peer_id: int) -> bool:
	return _peer_account.has(peer_id)


func _bind_session(peer_id: int, account_id: int) -> String:
	# One live connection per account: kick any older peer bound to it.
	if _account_peer.has(account_id) and _account_peer[account_id] != peer_id:
		var old_peer: int = _account_peer[account_id]
		_peer_account.erase(old_peer)
		_peer_match.erase(old_peer)
		if _peer_token.has(old_peer):
			_token_peer.erase(_peer_token[old_peer])
			_peer_token.erase(old_peer)
		multiplayer.multiplayer_peer.disconnect_peer(old_peer)

	var token := Crypto.new().generate_random_bytes(24).hex_encode()
	_peer_account[peer_id] = account_id
	_peer_token[peer_id] = token
	_token_peer[token] = peer_id
	_token_account[token] = account_id
	_account_peer[account_id] = peer_id
	return token


# =========================================================================
# Auth RPCs
# =========================================================================

@rpc("any_peer", "call_remote", "reliable")
func _rpc_auth_register(username: String, password: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	# No avatar at registration — the client runs a first-login picker and
	# calls set_avatar() afterwards.
	var res := _store.create_account(username, password)
	if not res.ok:
		_rpc_auth_result.rpc_id(peer_id, {"ok": false, "error": res.error, "token": "", "account": {}})
		return
	var token := _bind_session(peer_id, int(res.account.id))
	_rpc_auth_result.rpc_id(peer_id, {
		"ok": true, "error": "", "token": token,
		"account": _store.account_snapshot(res.account),
	})


@rpc("any_peer", "call_remote", "reliable")
func _rpc_auth_login(username: String, password: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var res := _store.verify_login(username, password)
	if not res.ok:
		_rpc_auth_result.rpc_id(peer_id, {"ok": false, "error": res.error, "token": "", "account": {}})
		return
	var token := _bind_session(peer_id, int(res.account.id))
	_rpc_auth_result.rpc_id(peer_id, {
		"ok": true, "error": "", "token": token,
		"account": _store.account_snapshot(res.account),
	})


@rpc("any_peer", "call_remote", "reliable")
func _rpc_auth_resume(token: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _token_account.has(token):
		_rpc_auth_result.rpc_id(peer_id, {"ok": false, "error": "session_expired", "token": "", "account": {}})
		return
	var account_id := int(_token_account[token])
	var account := _store.get_account(account_id)
	if account.is_empty():
		_rpc_auth_result.rpc_id(peer_id, {"ok": false, "error": "session_expired", "token": "", "account": {}})
		return
	var new_token := _bind_session(peer_id, account_id)
	_rpc_auth_result.rpc_id(peer_id, {
		"ok": true, "error": "", "token": new_token,
		"account": _store.account_snapshot(account),
	})


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_avatar(avatar: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var acc_id := int(_peer_account[peer_id])
	var res := _store.set_avatar(acc_id, Avatars.sanitize(avatar))
	if not res.ok:
		_rpc_receive_error.rpc_id(peer_id, "Could not save avatar.")
		return
	_rpc_avatar_result.rpc_id(peer_id, _store.account_snapshot(res.account))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_frame(frame: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var acc_id := int(_peer_account[peer_id])
	var res := _store.set_frame(acc_id, Frames.sanitize(frame))
	if not res.ok:
		_rpc_receive_error.rpc_id(peer_id, "Could not save frame.")
		return
	_rpc_frame_result.rpc_id(peer_id, _store.account_snapshot(res.account))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_background(background: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var acc_id := int(_peer_account[peer_id])
	var res := _store.set_background(acc_id, Backgrounds.sanitize(background))
	if not res.ok:
		_rpc_receive_error.rpc_id(peer_id, "Could not save background.")
		return
	_rpc_background_result.rpc_id(peer_id, _store.account_snapshot(res.account))


# =========================================================================
# Matchmaking
# =========================================================================

func enqueue_match() -> void:
	_rpc_enqueue_match.rpc_id(1)


func cancel_queue() -> void:
	_rpc_cancel_queue.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_enqueue_match() -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	if _peer_match.has(peer_id):
		return
	for e in _queue:
		if e.peer_id == peer_id:
			return
	var account_id: int = _peer_account[peer_id]
	_queue.append({
		"account_id": account_id,
		"peer_id": peer_id,
		"elo": int(_store.get_account(account_id).get("elo", ServerStore.START_ELO)),
		"since_ms": Time.get_ticks_msec(),
	})
	_rpc_queue_status.rpc_id(peer_id, "searching", 0.0)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_cancel_queue() -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var elapsed := 0.0
	for e in _queue:
		if e.peer_id == peer_id:
			elapsed = (Time.get_ticks_msec() - e.since_ms) / 1000.0
	_queue = _queue.filter(func(e): return e.peer_id != peer_id)
	_rpc_queue_status.rpc_id(peer_id, "cancelled", elapsed)


func _tick_matchmaking() -> void:
	if not is_server or _queue.is_empty():
		return
	var now := Time.get_ticks_msec()
	_queue.sort_custom(func(a, b): return a.since_ms < b.since_ms)

	# Try to pair the longest-waiting entry with the nearest-Elo partner
	# inside a window that widens with wait time. --mm-any (dev) skips the Elo
	# check and just takes the next-longest waiter.
	if _queue.size() >= 2:
		var a: Dictionary = _queue[0]
		var best_j := -1
		if _mm_any:
			best_j = 1
		else:
			var wait_s: float = (now - int(a.since_ms)) / 1000.0
			var window: float = min(50.0 + 25.0 * floor(wait_s / 5.0), 400.0)
			var best_diff := INF
			for j in range(1, _queue.size()):
				var diff: float = abs(int(_queue[j].elo) - int(a.elo))
				if diff <= window and diff < best_diff:
					best_diff = diff
					best_j = j
		if best_j != -1:
			var b: Dictionary = _queue[best_j]
			_queue.remove_at(best_j)
			_queue.remove_at(0)
			_create_pvp_match(a, b)
			_push_queue_status()
			return

	# Nobody to pair with — fill with a bot once the wait is long enough.
	var head: Dictionary = _queue[0]
	if (now - int(head.since_ms)) / 1000.0 >= _bot_fill_seconds:
		_queue.remove_at(0)
		_create_bot_match(head)

	_push_queue_status()


func _push_queue_status() -> void:
	var now := Time.get_ticks_msec()
	for e in _queue:
		_rpc_queue_status.rpc_id(e.peer_id, "searching", (now - e.since_ms) / 1000.0)


func _create_pvp_match(a: Dictionary, b: Dictionary) -> void:
	var engine := GameEngine.new(CardLoader.load_cards())
	engine.deal_hands()
	var name_a := str(_store.get_account(a.account_id).get("display_name", "Player"))
	var name_b := str(_store.get_account(b.account_id).get("display_name", "Player"))
	var m := _new_match(
		engine,
		{1: a.peer_id, 2: b.peer_id},
		{1: a.account_id, 2: b.account_id},
		{1: name_a, 2: name_b},
		0, false
	)
	_send_match_found(m, 1)
	_send_match_found(m, 2)
	_broadcast_match(m)


func _create_bot_match(a: Dictionary) -> void:
	var engine := GameEngine.new(CardLoader.load_cards())
	engine.deal_hands()
	var name_a := str(_store.get_account(a.account_id).get("display_name", "Player"))
	var m := _new_match(
		engine,
		{1: a.peer_id, 2: BOT_SEAT},
		{1: a.account_id, 2: 0},
		{1: name_a, 2: "Bot"},
		2, true
	)
	_send_match_found(m, 1)
	_broadcast_match(m)
	_maybe_trigger_bot(m)


## One entry per seat: {id, name, avatar, elo, is_bot}. Bot seats (account_id
## 0) resolve to fixed "Bot" identity.
func _seat_identity(m: Dictionary, seat: int) -> Dictionary:
	var acc_id := int(m.account_ids.get(seat, 0))
	if acc_id == 0:
		return {"name": "Bot", "avatar": Avatars.BOT_ID, "frame": "", "background": "", "elo": ServerStore.START_ELO, "is_bot": true}
	var acc := _store.get_account(acc_id)
	return {
		"name": str(acc.get("display_name", "Player")),
		"avatar": str(acc.get("avatar", "")),
		"frame": str(acc.get("frame", "")),
		"background": str(acc.get("background", "")),
		"elo": int(acc.get("elo", ServerStore.START_ELO)),
		"is_bot": false,
	}


func _send_match_found(m: Dictionary, seat: int) -> void:
	var target = m.seats[seat]
	if typeof(target) != TYPE_INT or target <= 0:
		return
	var me := _seat_identity(m, seat)
	var opp := _seat_identity(m, 3 - seat)
	_rpc_match_found.rpc_id(target, {
		"match_id": m.id,
		"your_seat": seat,
		"your_name": me.name,
		"your_avatar": me.avatar,
		"your_frame": me.frame,
		"your_background": me.background,
		"your_elo": me.elo,
		"opponent_name": opp.name,
		"opponent_avatar": opp.avatar,
		"opponent_frame": opp.frame,
		"opponent_background": opp.background,
		"opponent_elo": opp.elo,
		"is_bot_match": opp.is_bot,
	})
	_rpc_receive_player_assignment.rpc_id(target, seat)


# =========================================================================
# Ladder / profile
# =========================================================================

func request_ladder(limit := 50, offset := 0) -> void:
	_rpc_request_ladder.rpc_id(1, limit, offset)


func request_profile() -> void:
	_rpc_request_profile.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_ladder(limit: int, offset: int) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		return
	var data := _store.ladder(limit, offset, int(_peer_account[peer_id]))
	_rpc_receive_ladder.rpc_id(peer_id, data)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_profile() -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		return
	var acc_id := int(_peer_account[peer_id])
	_rpc_receive_profile.rpc_id(peer_id, {
		"account": _store.account_snapshot(_store.get_account(acc_id)),
		"recent_matches": _store.recent_matches(acc_id, 10),
	})


# =========================================================================
# Client -> Server move RPCs (networked play only)
# =========================================================================

@rpc("any_peer", "call_remote", "reliable")
func _rpc_submit_category_and_card(category: String, card_id: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var m := _match_for_peer(peer_id)
	if m.is_empty():
		return
	var seat := _seat_of_peer(m, peer_id)
	if seat == 0:
		return
	_apply_category(m, seat, category, card_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_submit_response_card(card_id: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var m := _match_for_peer(peer_id)
	if m.is_empty():
		return
	var seat := _seat_of_peer(m, peer_id)
	if seat == 0:
		return
	_apply_response(m, seat, card_id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_forfeit() -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var m := _match_for_peer(peer_id)
	if m.is_empty() or m.ended:
		return
	var seat := _seat_of_peer(m, peer_id)
	if seat == 0:
		return
	_finish_match(m, 3 - seat)  # the forfeiting seat is the loser


# =========================================================================
# Server -> Client RPCs
# =========================================================================

@rpc("authority", "call_remote", "reliable")
func _rpc_auth_result(result: Dictionary) -> void:
	if is_server:
		return
	auth_completed.emit(result)


@rpc("authority", "call_remote", "reliable")
func _rpc_queue_status(state: String, elapsed_s: float) -> void:
	if is_server:
		return
	queue_updated.emit(state, elapsed_s)


@rpc("authority", "call_remote", "reliable")
func _rpc_match_found(info: Dictionary) -> void:
	if is_server:
		return
	match_found.emit(info)


@rpc("authority", "call_remote", "reliable")
func _rpc_match_ended(summary: Dictionary) -> void:
	if is_server:
		return
	match_ended.emit(summary)


@rpc("authority", "call_remote", "reliable")
func _rpc_receive_ladder(data: Dictionary) -> void:
	if is_server:
		return
	ladder_received.emit(data)


@rpc("authority", "call_remote", "reliable")
func _rpc_receive_profile(data: Dictionary) -> void:
	if is_server:
		return
	profile_received.emit(data)


@rpc("authority", "call_remote", "reliable")
func _rpc_avatar_result(account: Dictionary) -> void:
	if is_server:
		return
	avatar_updated.emit(account)


@rpc("authority", "call_remote", "reliable")
func _rpc_frame_result(account: Dictionary) -> void:
	if is_server:
		return
	frame_updated.emit(account)


@rpc("authority", "call_remote", "reliable")
func _rpc_background_result(account: Dictionary) -> void:
	if is_server:
		return
	background_updated.emit(account)


@rpc("authority", "call_remote", "reliable")
func _rpc_receive_player_assignment(player_id: int) -> void:
	if is_server:
		return
	my_player_id = player_id
	_last_assigned_player = player_id
	player_assigned.emit(player_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_receive_state(state: Dictionary) -> void:
	if is_server:
		return
	_last_state = state
	state_updated.emit(state)


@rpc("authority", "call_remote", "reliable")
func _rpc_receive_error(message: String) -> void:
	if is_server:
		return
	error_received.emit(message)


## Re-emit the cached assignment + last state. The game UI is loaded via a
## scene swap AFTER match_found / the first state broadcast have already
## arrived, so its _ready() calls this to catch up. Harmless in singleplayer
## (re-emits the same values the UI already has).
func replay_state() -> void:
	if _last_assigned_player != 0:
		player_assigned.emit(_last_assigned_player)
	if not _last_state.is_empty():
		state_updated.emit(_last_state)
