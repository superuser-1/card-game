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
## Fired when the ENet connection to the server drops for any reason —
## crucially including the server forcibly disconnecting this peer because the
## same account just logged in from somewhere else (see _bind_session's
## one-connection-per-account rule). Session listens globally (it's the one
## thing alive across every screen) and forces a return to the login screen,
## since a screen-local error_received handler only helps if the player
## happens to be looking at a screen that listens for it.
signal kicked()
signal auth_completed(result: Dictionary)       # {ok, error, token, account}
signal queue_updated(state: String, elapsed_s: float)   # "searching" | "cancelled"
signal match_found(info: Dictionary)
signal match_ended(summary: Dictionary)
signal ladder_received(data: Dictionary)
signal profile_received(data: Dictionary)
signal avatar_updated(account: Dictionary)      # fresh account snapshot after set_avatar
signal frame_updated(account: Dictionary)       # fresh account snapshot after set_frame
signal background_updated(account: Dictionary)  # fresh account snapshot after set_background
signal sleeve_updated(account: Dictionary)      # fresh account snapshot after set_sleeve
signal shop_purchase_result(account: Dictionary) # fresh account snapshot after shop_purchase
signal achievements_unlocked(list: Array)       # from out-of-band tournament stat apply
## The server is deliberately ending this session (e.g. the same account just
## signed in elsewhere). Distinct from a bare `kicked`/server_disconnected,
## which can also mean the connection merely dropped — Session uses this to
## decide whether to wipe the saved token or try to reconnect.
signal force_logout(reason: String)

# --- custom (friend-invite) game signals ---
signal custom_game_created(result: Dictionary)      # {ok, error, name}
signal custom_game_join_result(result: Dictionary)  # {ok, error, name}

# --- tournament signals ---
signal tournament_list_received(rows: Array)
signal tournament_created(result: Dictionary)          # {ok, error, tournament}
signal tournament_joined(result: Dictionary)            # {ok, error, tournament}
signal tournament_withdrawn(result: Dictionary)         # {ok, error, tournament}
signal tournament_checked_in(result: Dictionary)        # {ok, error, tournament}
signal tournament_updated(tournament: Dictionary)       # full bracket snapshot
signal my_tournament_status(tournaments: Array)         # every live tournament this account has a stake in
signal tournament_prize_awarded(info: Dictionary)       # {tournament_id, name, bucket, points, items, account}
signal account_updated(account: Dictionary)             # generic "your wallet/inventory changed" snapshot push

const BOT_THINK_SECONDS := 0.7
const BOT_FILL_SECONDS := 15.0
const MM_TICK_SECONDS := 1.0
const TOURNAMENT_TICK_SECONDS := 5.0

## Hardcoded prod fallback for tournament-creation admin rights (not enforced
## while --dev-tournaments is set, see _is_tournament_admin). Real admin infra
## is the account "is_admin" field; this list is a secondary path.
const ADMIN_USERNAME_FALLBACK := ["admin", "flickbattle_admin"]

## Per-turn clock: the player who is on the clock (choosing a category, or
## responding) has this many seconds to act. If it expires the server calls
## GameEngine.resolve_timeout — they forfeit the category and lose a random
## card. Bots are never put on this clock.
const TURN_SECONDS := 30.0

## After a round resolves, the clients play a fixed round-resolution animation
## (see game_ui.gd _play_resolution_sequence / _play_timeout_sequence) during
## which the next player physically cannot act. The server holds the next
## player's turn clock frozen for this long so that span isn't counted against
## them. Biased slightly longer than the real animation so the server never
## times a player out mid-reveal; the client mirror (game_ui _process) freezes
## for the same window.
const REVEAL_PAUSE_SECONDS := 7.0
const TIMEOUT_PAUSE_SECONDS := 2.5

## A player who drops out of a live match has this long to reconnect (via
## auth_resume / auth_login from a fresh peer) before the match is decided
## against them. Only applies while they are actually in a match — a
## disconnect from the menu/queue is cleaned up immediately.
const RECONNECT_GRACE_SECONDS := 60.0
## Brief clock breather given to a player the instant they rejoin, so they
## aren't dumped straight onto a nearly-expired turn clock.
const REJOIN_PAUSE_SECONDS := 3.0

# Sentinels for Match.seats — a seat is either a real peer_id (>0) or one of:
const BOT_SEAT := -1
const LOCAL_SEAT := -2

var is_server := false
var is_solo := false

## Remembered so a client can rebuild a dropped ENet peer (reconnect()) — the
## original peer object is unusable once server_disconnected has fired.
var _srv_address := ""
var _srv_port := 0

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

## Open friend-invite lobbies waiting for a second player, keyed by the game
## name lowercased+trimmed (so "Movie Night" and "movie night " collide, which
## is the point — names must be unique among currently-open lobbies so a
## second creator can't silently shadow the first). A lobby is consumed
## (erased) the instant a join succeeds, so a second join attempt on the same
## name always sees "not_found" rather than needing a separate "full" state —
## with exactly 2 seats, "gone because someone already joined" and "full" are
## the same thing.
## {name, creator_account_id, creator_peer_id, match_format, created_ms}
var _custom_games: Dictionary = {}

# --- tournaments (server-only) ---
var _tournament_timer: Timer = null
## peer_id -> tournament_id, set on successful check-in, cleared on that
## player's elimination, tournament victory, or the tournament completing.
## While present, the peer is refused ranked queue/solo/custom-game entry
## points (see _blocked_by_tournament_lock) — per the locked design, the lock
## covers the player's whole tournament run, not just until their match starts.
var _peer_tournament_lock: Dictionary = {}
## Server-only dev override (--dev-tournaments): every account may create
## tournaments, bypassing is_admin/ADMIN_USERNAME_FALLBACK, and admins may pick
## a bracket size smaller than TournamentSystem.MIN_BRACKET_SIZE for testing.
var _dev_tournaments := false

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

## >0 overrides TournamentSystem.match_hard_cap_ms for every tournament match
## (dev/testing — `--tournament-match-cap-seconds=N`). See
## _enforce_tournament_match_cap.
var _tournament_match_cap_ms := 0

## Between-round tournament pause, seconds. Overridable with
## `--tournament-intermission-seconds=N` (dev/testing; 0 = advance immediately).
## See _maybe_advance_round.
var _intermission_seconds := TournamentSystem.INTERMISSION_SECONDS


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
		elif arg == "--dev-tournaments":
			_dev_tournaments = true
			print("Net: all accounts may create tournaments (--dev-tournaments)")
		elif arg.begins_with("--tournament-match-cap-seconds="):
			_tournament_match_cap_ms = int(maxf(1.0, float(arg.substr("--tournament-match-cap-seconds=".length()))) * 1000.0)
			print("Net: tournament per-match hard cap overridden to %ds" % (_tournament_match_cap_ms / 1000))
		elif arg.begins_with("--tournament-intermission-seconds="):
			_intermission_seconds = int(maxf(0.0, float(arg.substr("--tournament-intermission-seconds=".length()))))
			print("Net: tournament between-round pause overridden to %ds" % _intermission_seconds)

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
	_mm_timer.timeout.connect(_check_disconnect_grace)

	_tournament_timer = Timer.new()
	_tournament_timer.wait_time = TOURNAMENT_TICK_SECONDS
	_tournament_timer.autostart = true
	add_child(_tournament_timer)
	_tournament_timer.timeout.connect(_tick_tournaments)

	print("GameServer: listening on port %d" % port)


func start_client(address: String = NetConfig.DEFAULT_ADDRESS, port: int = NetConfig.DEFAULT_PORT) -> void:
	is_server = false
	is_solo = false
	_is_networked_client = true
	_srv_address = address
	_srv_port = port
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		push_error("Client: failed to connect to %s:%d (error %d)" % [address, port, err])
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(func(): print("Client: connected to server"))
	multiplayer.connection_failed.connect(func(): error_received.emit("Could not connect to server."))
	multiplayer.server_disconnected.connect(func():
		error_received.emit("Disconnected from server.")
		kicked.emit()
	)


## Rebuild the ENet client peer after the previous one dropped. The old peer is
## dead once server_disconnected has fired — it can't be reused — so a
## reconnect needs a fresh create_client. The `multiplayer` signal wiring above
## lives on the API object, not the peer, so it survives the swap untouched.
## Re-authentication is the caller's job (login_screen resumes the saved token).
func reconnect() -> bool:
	if _srv_address == "":
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(_srv_address, _srv_port)
	if err != OK:
		push_error("Client: reconnect to %s:%d failed (error %d)" % [_srv_address, _srv_port, err])
		return false
	multiplayer.multiplayer_peer = peer
	return true


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


## Set (or clear, with "") the logged-in account's card-back sleeve. Reply comes
## back on `sleeve_updated` with a fresh account snapshot.
func set_sleeve(sleeve: String) -> void:
	_rpc_set_sleeve.rpc_id(1, sleeve)


## Purchase a shop item by id. Reply comes back on `shop_purchase_result` with
## a fresh account snapshot, or `error_received` if the purchase fails.
func shop_purchase(item_id: String) -> void:
	_rpc_shop_purchase.rpc_id(1, item_id)


## DEV-ONLY: top up the caller's points wallet. Silently ignored unless the
## server was started with --dev-tournaments. Reply on `account_updated`.
func dev_grant_points(amount: int) -> void:
	_rpc_dev_grant_points.rpc_id(1, amount)


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
	m["bot_identity"] = Avatars.bot_identity()
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
		"opponent_avatar": m["bot_identity"]["avatar"],
		"opponent_frame": m["bot_identity"]["frame"],
		"opponent_background": m["bot_identity"]["background"],
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

## `match_format` is the number of games needed to decide the whole match: 1
## (single game, the historical default), 3 (best of 3, first to 2 game wins)
## or 5 (best of 5, first to 3 game wins). `games_to_win` is derived once here
## rather than recomputed everywhere a decision needs it.
func _new_match(engine: GameEngine, seats: Dictionary, account_ids: Dictionary,
		names: Dictionary, bot_seat: int, is_bot_match: bool, tournament_ctx := {},
		match_format := 1) -> Dictionary:
	var m := {
		"id": _next_match_id,
		"engine": engine,
		"seats": seats,              # {1: peer_id|BOT_SEAT|LOCAL_SEAT, 2: ...}
		"account_ids": account_ids,  # {1: int (0 = bot/local), 2: int}
		"names": names,              # {1: String, 2: String}
		"bot_seat": bot_seat,        # 0, 1 or 2
		"is_bot_match": is_bot_match,
		"ended": false,
		# Wall-clock the match was created (never rolled forward). Only read by
		# _enforce_tournament_match_cap so a hung tournament game can't wedge the
		# bracket indefinitely.
		"created_ms": Time.get_ticks_msec(),
		"turn_started_ms": Time.get_ticks_msec(),
		"on_clock_seat": 0,          # 1|2 while the match is live, 0 otherwise
		# While > now, the turn clock is frozen (round-resolution animation is
		# playing on the clients, or a player just rejoined). _broadcast_match
		# rolls turn_started_ms forward to this value so the countdown only
		# begins once the clients can actually act again.
		"clock_pause_until_ms": 0,
		# seat (1|2) -> unix-ms deadline. Non-empty => a player dropped and the
		# match is holding for their reconnect; the turn clock is frozen and
		# _check_disconnect_grace decides the match if the deadline passes.
		"disconnected": {},
		# seat (1|2) -> reconnect-grace budget still available THIS MATCH, in ms.
		# Each drop's hold window is capped at whatever is left here, and each
		# rejoin subtracts the time spent away — so serial disconnects can't keep
		# minting fresh 60s freezes. Runs out => the next drop is an instant loss.
		"grace_left_ms": {1: int(RECONNECT_GRACE_SECONDS * 1000.0), 2: int(RECONNECT_GRACE_SECONDS * 1000.0)},
		# seat (1|2) -> ticks_msec the current drop began (for the budget maths).
		"dc_started_ms": {},
		# seat (1|2) -> ms left on that seat's turn clock at the instant it
		# dropped (only set if it was on the clock). The rejoin restores this
		# instead of handing out a fresh full turn.
		"turn_left_at_drop_ms": {},
		# Consumed by the next _broadcast_match: ms to resume the turn clock with
		# (a disconnect-interrupted turn picks up where it left off). -1 = unset.
		"turn_resume_ms": -1,
		# {tournament_id, round, bracket_size} when this match is a tournament
		# round; empty for ranked/solo/bot-fill matches.
		"tournament_ctx": tournament_ctx,
		"match_format": match_format,
		"games_to_win": (match_format / 2) + 1,
		"series_wins": {1: 0, 2: 0},  # completed games won by each seat so far
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

	var now := Time.get_ticks_msec()
	# Freeze the countdown while the clients are mid round-resolution animation
	# (or a rejoin breather): the clock only really starts once it can be acted
	# on. If the pause window has already elapsed, drop it.
	var pause_until := int(m.get("clock_pause_until_ms", 0))
	var paused := on_clock != 0 and pause_until > now
	# A turn interrupted by a disconnect resumes with the time it had left, not a
	# fresh 30s — backdate turn_started_ms by the already-used slice.
	var resume_ms := int(m.get("turn_resume_ms", -1))
	var used_ms := 0
	if resume_ms >= 0 and on_clock != 0:
		used_ms = clampi(int(_turn_seconds * 1000.0) - resume_ms, 0, int(_turn_seconds * 1000.0))
	if paused:
		m.turn_started_ms = pause_until - used_ms
	else:
		m.turn_started_ms = now - used_ms
		m.clock_pause_until_ms = 0
	if resume_ms >= 0:
		m.turn_resume_ms = -1

	for seat in [1, 2]:
		var target = m.seats[seat]
		if typeof(target) != TYPE_INT:
			continue
		var st := engine.get_state_for_player(seat)
		if on_clock != 0:
			st["on_clock_player"] = on_clock
			st["turn_seconds_left"] = clampf(_turn_seconds - (now - int(m.turn_started_ms)) / 1000.0, 0.0, _turn_seconds)
			st["turn_paused"] = paused
		else:
			st["on_clock_player"] = 0
			st["turn_seconds_left"] = -1.0
			st["turn_paused"] = false
		st["match_format"] = int(m.get("match_format", 1))
		st["games_to_win"] = int(m.get("games_to_win", 1))
		st["series_wins"] = (m.get("series_wins", {1: 0, 2: 0}) as Dictionary).duplicate()
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
	# The round just resolved — clients now play the reveal animation. Freeze
	# the next player's clock until it finishes.
	m.clock_pause_until_ms = Time.get_ticks_msec() + int(REVEAL_PAUSE_SECONDS * 1000.0)
	_after_move(m)


func _after_move(m: Dictionary) -> void:
	var engine: GameEngine = m.get("engine")
	_broadcast_match(m)
	if engine.is_game_over():
		_handle_game_over(m)
	else:
		_maybe_trigger_bot(m)


## One 7-card GameEngine game just ended. For a plain Bo1 match (the historical
## default) that's always the whole match. For Bo3/Bo5 it only ends the match
## once a side has reached games_to_win — otherwise a fresh game is dealt to
## the same two seats and the series continues. A drawn game (equal score at
## hands-empty) awards neither seat a series win, so the series simply plays
## another game instead of getting stuck undecided.
func _handle_game_over(m: Dictionary) -> void:
	var engine: GameEngine = m.engine
	var game_winner := engine.get_winner()
	var format := int(m.get("match_format", 1))
	var games_to_win := int(m.get("games_to_win", 1))
	if game_winner != 0:
		m.series_wins[game_winner] = int(m.series_wins.get(game_winner, 0)) + 1

	var series_winner := -1
	if int(m.series_wins.get(1, 0)) >= games_to_win:
		series_winner = 1
	elif int(m.series_wins.get(2, 0)) >= games_to_win:
		series_winner = 2
	elif format == 1:
		series_winner = game_winner  # Bo1: the single game's result (including a draw) is final.

	if series_winner != -1:
		_finish_match(m, series_winner)
	else:
		var next_engine := GameEngine.new(engine.get_card_pool())
		next_engine.deal_hands()
		m.engine = next_engine
		_broadcast_match(m)
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
		# A player is mid-reconnect grace — the whole match is on hold, nobody
		# gets timed out until they return or the grace lapses.
		if not (m.get("disconnected", {}) as Dictionary).is_empty():
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
	# Shorter reveal (no card lunge on a timeout) but still a beat to watch.
	m.clock_pause_until_ms = Time.get_ticks_msec() + int(TIMEOUT_PAUSE_SECONDS * 1000.0)
	_after_move(m)


# =========================================================================
# Reconnect grace (networked server)
# =========================================================================

## 1s tick (shares _mm_timer). Any match holding for a dropped player whose
## grace deadline has passed is decided now — a default win for whoever stayed
## (ranked Elo/points, a tournament advance, or an unranked custom-game win),
## or a quiet abort if the only one left is a bot.
func _check_disconnect_grace() -> void:
	if not is_server:
		return
	var now := Time.get_ticks_msec()
	for mid in _matches.keys().duplicate():
		var m: Dictionary = _matches.get(mid, {})
		if m.is_empty() or m.ended:
			continue
		var dc: Dictionary = m.get("disconnected", {})
		if dc.is_empty():
			continue
		var lapsed := false
		for seat in dc.keys():
			if now >= int(dc[seat]):
				lapsed = true
				break
		if lapsed:
			_resolve_abandoned_match(m, dc)


func _resolve_abandoned_match(m: Dictionary, dc: Dictionary) -> void:
	var is_tournament: bool = not (m.get("tournament_ctx", {}) as Dictionary).is_empty()
	# Both sides gone.
	if dc.size() >= 2:
		# A tournament slot can't be left unresolved or the round never advances
		# — coin-flip a winner so the bracket moves on. Neither player is around
		# to see it; the loser is eliminated like any other loss.
		if is_tournament and (int(m.account_ids.get(1, 0)) != 0 or int(m.account_ids.get(2, 0)) != 0):
			var flip := 1 + (randi() % 2)
			print("GameServer: tournament match %d — both seats abandoned, coin-flip advances seat %d" % [int(m.id), flip])
			m["unfinished"] = true
			_finish_match(m, flip)
			return
		_abort_match_silently(m)
		return
	var gone_seat := int(dc.keys()[0])
	var stay_seat := 3 - gone_seat
	# The only seat left is a bot (bot-fill match) — nothing to award, and a
	# bot "win" would try to record a match against account 0.
	if int(m.account_ids.get(stay_seat, 0)) == 0:
		_abort_match_silently(m)
		return
	# A real player is still here. _finish_match dispatches by match kind and
	# handles cleanup: ranked -> Elo/points/quest/achievement + summary;
	# tournament -> _finish_tournament_match advances the bracket and eliminates
	# the absentee; custom -> _finish_custom_match, an unranked win on the
	# result screen.
	print("GameServer: match %d — seat %d abandoned, seat %d wins by default" % [int(m.id), gone_seat, stay_seat])
	_finish_match(m, stay_seat)


func _abort_match_silently(m: Dictionary) -> void:
	if m.ended:
		return
	m.ended = true
	for seat in [1, 2]:
		var target = m.seats[seat]
		if typeof(target) == TYPE_INT and target > 0:
			_peer_match.erase(target)
			_rpc_receive_error.rpc_id(target, "Match ended — opponent did not reconnect.")
	_matches.erase(m.id)
	if m.id == _solo_match_id:
		_solo_match_id = 0


## After a (re)auth, if this account holds a seat in a live match it isn't
## currently connected to (dropped and inside its grace window, or a fast
## reconnect the server hasn't noticed the drop for yet), rebind the fresh peer
## to that seat and resume. Returns true if a rejoin happened.
func _try_rejoin_match(peer_id: int, account_id: int) -> bool:
	for mid in _matches.keys():
		var m: Dictionary = _matches.get(mid, {})
		if m.is_empty() or m.ended:
			continue
		for seat in [1, 2]:
			if int(m.account_ids.get(seat, 0)) != account_id:
				continue
			var cur = m.seats.get(seat)
			if cur == peer_id:
				return true  # already bound (nothing to do, but it IS our match)
			if typeof(cur) == TYPE_INT and cur > 0 and _peer_account.has(cur):
				continue     # a live peer already holds this seat
			m.seats[seat] = peer_id
			_peer_match[peer_id] = int(m.id)
			(m.get("disconnected", {}) as Dictionary).erase(seat)
			var now_ms := Time.get_ticks_msec()
			# Charge the time spent away against this seat's grace budget so a
			# later drop gets only what's left (and eventually nothing).
			var started := int((m.get("dc_started_ms", {}) as Dictionary).get(seat, 0))
			if started > 0:
				var gl := m.get("grace_left_ms", {}) as Dictionary
				gl[seat] = maxi(0, int(gl.get(seat, 0)) - (now_ms - started))
			(m.get("dc_started_ms", {}) as Dictionary).erase(seat)
			# Resume the interrupted turn with the time it had left; only grant
			# the settle-in breather when that remainder is nearly gone.
			var restore_ms := int((m.get("turn_left_at_drop_ms", {}) as Dictionary).get(seat, -1))
			(m.get("turn_left_at_drop_ms", {}) as Dictionary).erase(seat)
			if restore_ms >= 0:
				m.turn_resume_ms = restore_ms
				m.clock_pause_until_ms = now_ms + int(REJOIN_PAUSE_SECONDS * 1000.0) if restore_ms < 5000 else 0
			else:
				m.turn_resume_ms = -1
				m.clock_pause_until_ms = 0
			var other = m.seats[3 - seat]
			if typeof(other) == TYPE_INT and other > 0:
				_rpc_receive_error.rpc_id(other, "Opponent reconnected.")
			_send_match_found(m, seat)
			_broadcast_match(m)
			print("GameServer: account %d rejoined match %d seat %d" % [account_id, int(m.id), seat])
			return true
	return false


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
	var tournament_ctx: Dictionary = m.get("tournament_ctx", {})

	if not tournament_ctx.is_empty():
		_finish_tournament_match(m, winner, tournament_ctx)
	elif bool(m.get("is_custom_match", false)):
		_finish_custom_match(m, winner)
	elif is_solo or _store == null:
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
			"match_format": int(m.get("match_format", 1)),
			"games_won": int(m.series_wins.get(seat, 0)),
			"games_won_opponent": int(m.series_wins.get(3 - seat, 0)),
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
			var achievement_unlocks := []
			var achievement_points := 0
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
				var a_res := _store.apply_match_stats(acc_id, q_ctx)
				achievement_unlocks = a_res["achievement_unlocks"]
				achievement_points = int(a_res["achievement_points"])
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
				"achievement_unlocks": achievement_unlocks,
				"achievement_points": achievement_points,
				"match_format": int(m.get("match_format", 1)),
				"games_won": int(m.series_wins.get(seat, 0)),
				"games_won_opponent": int(m.series_wins.get(3 - seat, 0)),
			}
			_rpc_match_ended.rpc_id(target, summary)

	_cleanup_match(m)


## A friend-invite custom game: two real human seats, always unranked (no
## ServerStore.record_match, no quest progress — same "just play a game"
## spirit as a tournament match, but outside any bracket).
func _finish_custom_match(m: Dictionary, winner: int) -> void:
	var engine: GameEngine = m.engine
	for seat in [1, 2]:
		var target = m.seats[seat]
		if typeof(target) != TYPE_INT or target <= 0:
			continue
		_rpc_match_ended.rpc_id(target, {
			"outcome": _outcome_str(winner, seat),
			"your_score": engine.scores[seat],
			"opponent_score": engine.scores[3 - seat],
			"ranked": false,
			"elo_before": 0, "elo_after": 0, "elo_delta": 0,
			"points_delta": 0, "points_total": 0, "new_rank": 0,
			"quest_completions": [], "quest_points": 0,
			"match_format": int(m.get("match_format", 1)),
			"games_won": int(m.series_wins.get(seat, 0)),
			"games_won_opponent": int(m.series_wins.get(3 - seat, 0)),
		})


func _outcome_str(winner: int, seat: int) -> String:
	if winner == 0:
		return "draw"
	return "win" if winner == seat else "loss"


func _cleanup_match(m: Dictionary) -> void:
	for seat in [1, 2]:
		var target = m.seats[seat]
		# Only erase if it's still THIS match's mapping. A tournament match's
		# _finish_match runs _finish_tournament_match (which can synchronously
		# dispatch the player's NEXT round match, overwriting _peer_match[target]
		# with the new match's id) before reaching this cleanup — an
		# unconditional erase here would then wipe the brand-new mapping
		# instead of this match's stale one, silently breaking every move
		# submission for the next round.
		if typeof(target) == TYPE_INT and target > 0 and _peer_match.get(target) == m.id:
			_peer_match.erase(target)
	_matches.erase(m.id)
	if m.id == _solo_match_id:
		_solo_match_id = 0


# =========================================================================
# Tournaments
# =========================================================================

func _is_tournament_admin(account: Dictionary) -> bool:
	if _dev_tournaments:
		return true
	if bool(account.get("is_admin", false)):
		return true
	return str(account.get("username", "")).to_lower() in ADMIN_USERNAME_FALLBACK


func _blocked_by_tournament_lock(peer_id: int) -> bool:
	return _peer_tournament_lock.has(peer_id)


func _release_tournament_lock(account_id: int) -> void:
	var peer: int = int(_account_peer.get(account_id, 0))
	if peer > 0:
		_peer_tournament_lock.erase(peer)


func _tournament_participant_account_ids(t: Dictionary) -> Array:
	var ids := []
	for p in (t.participants as Array):
		ids.append(int(p.account_id))
	return ids


## Bump a tournament-driven achievement stat for one account and, if that peer
## is connected, push any newly-unlocked achievements out of band (there is no
## match summary to fold them into). If offline, they are already persisted and
## show as unlocked next time the player opens the Achievements screen.
func _apply_tournament_achievement(account_id: int, key: String) -> void:
	if _store == null:
		return
	var newly: Array = _store.apply_tournament_stat(account_id, key)
	if newly.is_empty():
		return
	var peer: int = int(_account_peer.get(account_id, 0))
	if peer > 0:
		_rpc_achievements_unlocked.rpc_id(peer, newly)


## Pushes the full bracket snapshot to every currently-connected participant.
## Used instead of a client-driven poll so the bracket/wait screen updates the
## instant a round resolves or advances.
func _broadcast_tournament(t: Dictionary) -> void:
	var public := _store.tournament_public_view(t)
	for acc_id in _tournament_participant_account_ids(t):
		var peer: int = int(_account_peer.get(acc_id, 0))
		if peer > 0:
			_rpc_tournament_snapshot.rpc_id(peer, public)


## Replaces `result.tournament` (if present and non-empty) with its
## client-safe view, so an RPC reply never leaks the password hash.
func _public_result(result: Dictionary) -> Dictionary:
	var tt = result.get("tournament", {})
	if tt is Dictionary and not (tt as Dictionary).is_empty():
		result = result.duplicate()
		result["tournament"] = _store.tournament_public_view(tt)
	return result


func _tick_tournaments() -> void:
	if not is_server:
		return
	var now := int(Time.get_unix_time_from_system())
	for t in _store.all_tournaments():
		match str(t.status):
			"signup_private":
				# semi_private: private phase → open sign-up. private: sign-up
				# closes → the sign-up-closed / check-in-not-open gap (or straight
				# to check-in when they coincide).
				var avail := str(t.get("availability", "open"))
				if avail == "semi_private" and now >= int(t.get("private_signup_close_ts", 0)):
					t.status = "signup"
					_store.persist_tournament(t)
					_broadcast_tournament(t)
				elif avail == "private" and now >= int(t.signup_close_ts):
					t.status = "check_in" if now >= int(t.check_in_open_ts) else "pre_check_in"
					_store.persist_tournament(t)
					_broadcast_tournament(t)
			"signup":
				if now >= int(t.signup_close_ts):
					t.status = "check_in" if now >= int(t.check_in_open_ts) else "pre_check_in"
					_store.persist_tournament(t)
					_broadcast_tournament(t)
			"pre_check_in":
				if now >= int(t.check_in_open_ts):
					t.status = "check_in"
					_store.persist_tournament(t)
					_broadcast_tournament(t)
			"check_in":
				if now >= int(t.start_ts):
					_start_tournament(t)
			"in_progress":
				# Re-check the current round every tick, not just when a new
				# one is created — _dispatch_round is idempotent and, since
				# _matches is purely in-memory, this is what recovers a slot
				# whose match got orphaned by a server restart mid-tournament
				# (see _dispatch_round's staleness check below).
				var round_idx := int(t.current_round) - 1
				if round_idx >= 0 and round_idx < (t.rounds as Array).size():
					if _dispatch_round(t, round_idx):
						_store.persist_tournament(t)
						_broadcast_tournament(t)
					_enforce_tournament_match_cap(t, round_idx)
				_maybe_advance_round(t)


func _start_tournament(t: Dictionary) -> void:
	var checked_in_ids := []
	for p in (t.participants as Array):
		if bool(p.get("checked_in", false)):
			checked_in_ids.append(int(p.account_id))

	# Real tournaments need a real crowd — below the floor they cancel rather
	# than run (tournament matches feed quests/achievements). Dev-bot
	# tournaments skip the check and still bot-fill, so testing stays cheap;
	# --dev-tournaments also lowers the floor to 2 so a small real bracket
	# (bye path included) can be exercised without 32 live clients.
	var dev_bot := bool(t.get("is_dev_bot_tournament", false))
	var min_players := 2 if _dev_tournaments else TournamentSystem.MIN_TOURNAMENT_PLAYERS
	if not dev_bot and checked_in_ids.size() < min_players:
		_cancel_tournament_insufficient(t)
		return

	t.rng_seed = Time.get_ticks_usec()
	if dev_bot:
		t.rounds = [TournamentSystem.generate_bracket(t.participants, int(t.bracket_size), int(t.rng_seed))]
	else:
		t.rounds = [TournamentSystem.generate_bracket_shrink(checked_in_ids, int(t.rng_seed))]
	t.status = "in_progress"
	t.current_round = 1
	# Credit "tournament played" to everyone who checked in (a no-show who
	# checked in but never played still gets it — see PLAN_achievements §7).
	for p in (t.participants as Array):
		if bool(p.get("checked_in", false)):
			_apply_tournament_achievement(int(p.account_id), "tournaments_played")
	_mark_round_started(t)
	_dispatch_round(t, 0)
	_store.persist_tournament(t)
	_broadcast_tournament(t)


## Too few checked-in players by start time: mark the tournament cancelled,
## free every participant's check-in gameplay lock, and push the terminal
## state to clients (which already render "cancelled").
func _cancel_tournament_insufficient(t: Dictionary) -> void:
	_store.cancel_tournament(int(t.id))
	for acc_id in _tournament_participant_account_ids(t):
		_release_tournament_lock(acc_id)
	# Nothing was ever paid out — refund the creator's prize escrow in full and
	# push them a fresh wallet snapshot if they're online.
	var refunded := _store.refund_tournament_escrow(t)
	if refunded > 0:
		var creator_id := int(t.get("created_by_account_id", 0))
		var peer: int = int(_account_peer.get(creator_id, 0))
		if peer > 0:
			_rpc_account_snapshot.rpc_id(peer, _store.account_snapshot(_store.get_account(creator_id)))
	_store.persist_tournament(t)
	_broadcast_tournament(t)


## Starts (or instantly resolves) every not-yet-started slot in one round.
## Idempotent per slot: a slot with a `match_id` that's still live in
## `_matches` is left alone. A slot whose `match_id` points to nothing live —
## `_matches` is purely in-memory, so a server restart mid-tournament orphans
## whatever match was in flight — gets its match recreated here instead of
## being stuck unresolved forever; a fresh match_found is sent to the human
## side(s) same as the first time.
func _dispatch_round(t: Dictionary, round_idx: int) -> bool:
	var round: Array = t.rounds[round_idx]
	var ctx := {
		"tournament_id": int(t.id), "round": round_idx + 1, "bracket_size": int(t.bracket_size),
		"match_format": int(t.get("match_format", 1)),
		"cube_ids": t.get("cube_ids", []),
		# unix s this round's matches are force-resolved if still unfinished, so
		# game_ui can show a round-time countdown alongside the turn clock.
		"round_deadline_ts": int(t.get("round_deadline_ts", 0)),
	}
	var rng := RandomNumberGenerator.new()
	rng.seed = int(t.rng_seed) + round_idx + 1
	var changed := false
	for slot in round:
		if bool(slot.resolved):
			continue
		if bool(slot.get("is_bye", false)):
			continue   # one-player slot, already resolved at creation
		if int(slot.match_id) != 0 and _matches.has(int(slot.match_id)):
			continue
		slot.match_id = 0
		changed = true
		if TournamentSystem.is_bot_vs_bot(slot):
			TournamentSystem.resolve_bot_vs_bot(slot, rng)
		elif bool(slot.is_bot_a) or bool(slot.is_bot_b):
			var human_acc: int = slot.account_id_b if bool(slot.is_bot_a) else slot.account_id_a
			var m := _create_bot_match_for_account(human_acc, ctx)
			slot.match_id = m.id
		else:
			var m := _create_pvp_match_for_accounts(int(slot.account_id_a), int(slot.account_id_b), ctx)
			slot.match_id = m.id
	return changed


func _maybe_advance_round(t: Dictionary) -> void:
	var round_idx := int(t.current_round) - 1
	if round_idx < 0 or round_idx >= (t.rounds as Array).size():
		return
	var round: Array = t.rounds[round_idx]
	if not TournamentSystem.round_fully_resolved(round):
		return
	if TournamentSystem.is_tournament_complete(t.rounds):
		_complete_tournament(t)
		return

	# Between-round breather so players can step away. On the first tick the
	# finished round reads as fully resolved we arm intermission_until_ts and
	# hold; later ticks fall through here until it elapses. Skipped entirely
	# when the pause is disabled (dev override 0). No pause before round 1
	# (that path is _start_tournament) or after the final (handled above).
	var now := int(Time.get_unix_time_from_system())
	if _intermission_seconds > 0:
		var until := int(t.get("intermission_until_ts", 0))
		if until == 0:
			t.intermission_until_ts = now + _intermission_seconds
			_store.persist_tournament(t)
			_broadcast_tournament(t)
			return
		if now < until:
			return
	t.intermission_until_ts = 0

	# Positional advancement (winner of slot 2i meets winner of slot 2i+1), so
	# the bracket stays a fixed, drawable tree after round 0's random seeding.
	# A trailing unpaired winner (odd slot count, from a bye upstream) byes
	# forward. advance_round() can re-shuffle if passed a non-zero seed; we
	# deliberately don't.
	var next_round := TournamentSystem.advance_round(round)
	(t.rounds as Array).append(next_round)
	t.current_round = int(t.current_round) + 1
	# Stamp the new round's window BEFORE dispatch so each match's ctx carries
	# the round deadline.
	_mark_round_started(t)
	_dispatch_round(t, (t.rounds as Array).size() - 1)
	_store.persist_tournament(t)
	_broadcast_tournament(t)


## Stamp when the current round's matches went live and when the round's
## hard-cap force-resolve deadline lands, so clients can show a countdown. The
## match format is uniform across a tournament, so one deadline covers every
## match in the round.
func _mark_round_started(t: Dictionary) -> void:
	var now := int(Time.get_unix_time_from_system())
	var cap_ms: int = _tournament_match_cap_ms if _tournament_match_cap_ms > 0 \
		else TournamentSystem.match_hard_cap_ms(int(t.get("match_format", 1)))
	t.round_started_ts = now
	t.round_deadline_ts = now + int(cap_ms / 1000.0)


## Wall-clock backstop for the current round's live matches. A tournament match
## that outlives TournamentSystem.match_hard_cap_ms (or the
## --tournament-match-cap-seconds override) is force-resolved so one hung /
## broken game can't freeze the bracket — every unresolved slot blocks the
## round. Winner = whoever leads on games won, then on this game's card score,
## then a coin flip. A firing cap means something is wrong upstream, so it is
## logged loud; the resolution still routes through the normal tournament-match
## finish (slot resolved, loser eliminated, round advances).
func _enforce_tournament_match_cap(t: Dictionary, round_idx: int) -> void:
	var round: Array = t.rounds[round_idx]
	var now_ms := Time.get_ticks_msec()
	for slot in round:
		if bool(slot.resolved) or bool(slot.get("is_bye", false)):
			continue
		var mid := int(slot.match_id)
		if mid == 0 or not _matches.has(mid):
			continue
		var m: Dictionary = _matches[mid]
		if m.is_empty() or bool(m.ended):
			continue
		var cap_ms: int = _tournament_match_cap_ms if _tournament_match_cap_ms > 0 \
			else TournamentSystem.match_hard_cap_ms(int(m.get("match_format", 1)))
		if now_ms - int(m.get("created_ms", now_ms)) < cap_ms:
			continue
		var engine: GameEngine = m.get("engine")
		var sw: Dictionary = m.get("series_wins", {1: 0, 2: 0})
		var winner := 0
		if int(sw.get(1, 0)) != int(sw.get(2, 0)):
			winner = 1 if int(sw.get(1, 0)) > int(sw.get(2, 0)) else 2
		elif engine != null and int(engine.scores[1]) != int(engine.scores[2]):
			winner = 1 if int(engine.scores[1]) > int(engine.scores[2]) else 2
		else:
			winner = 1 + (randi() % 2)
		push_warning("GameServer: tournament %d round %d match %d hit the %ds hard cap — force-resolving to seat %d" \
			% [int(t.id), round_idx + 1, mid, cap_ms / 1000, winner])
		m["unfinished"] = true
		_finish_match(m, winner)


func _complete_tournament(t: Dictionary) -> void:
	var final_slot: Dictionary = t.rounds[-1][0]
	t.status = "completed"
	t.intermission_until_ts = 0
	t.winner_account_id = int(final_slot.winner_account_id) if not bool(final_slot.winner_is_bot) else 0
	if int(t.winner_account_id) != 0:
		_release_tournament_lock(int(t.winner_account_id))
		_apply_tournament_achievement(int(t.winner_account_id), "tournaments_won")
	# Defensive: release anyone still locked to this tournament (should
	# already be released at elimination — see _record_tournament_result).
	for acc_id in _tournament_participant_account_ids(t):
		_release_tournament_lock(acc_id)

	# Pay out the prize pool (idempotent). Push each recipient a fresh account
	# snapshot + a "you won" notification if they're connected.
	var payouts := _store.pay_tournament_prizes(t)
	for pay in payouts:
		var acc_id: int = int(pay.account_id)
		var peer: int = int(_account_peer.get(acc_id, 0))
		if peer <= 0:
			continue
		_rpc_tournament_prize.rpc_id(peer, {
			"tournament_id": int(t.id),
			"name": str(t.name),
			"bucket": str(pay.bucket),
			"points": int(pay.points),
			"items": pay.get("granted", []),
			"account": _store.account_snapshot(_store.get_account(acc_id)),
		})

	_store.persist_tournament(t)
	_broadcast_tournament(t)


## Account-id-based match creation for tournament rounds (mirrors
## _create_pvp_match/_create_bot_match, which take queue-entry dicts instead —
## kept separate so ranked-queue call sites are untouched).
# --- cube pools --------------------------------------------------------------
# A "cube" is a player-curated subset of the card set (see CubeRules). The
# server always builds the GameEngine pool from a sanitized id list it trusts;
# an empty list means "the full collection". The id set is cached because
# CardLoader re-reads and re-parses cards.json on every call.
var _known_card_ids_cache: Dictionary = {}


func _known_card_ids() -> Dictionary:
	if _known_card_ids_cache.is_empty():
		_known_card_ids_cache = CubeRules.id_set(CardLoader.load_cards())
	return _known_card_ids_cache


func _pool_for_cube(cube_ids) -> Array:
	return CubeRules.filter_pool(CardLoader.load_cards(), cube_ids)


func _create_pvp_match_for_accounts(account_a: int, account_b: int, ctx: Dictionary) -> Dictionary:
	var engine := GameEngine.new(_pool_for_cube(ctx.get("cube_ids", [])))
	engine.deal_hands()
	var peer_a: int = int(_account_peer.get(account_a, 0))
	var peer_b: int = int(_account_peer.get(account_b, 0))
	var name_a := str(_store.get_account(account_a).get("display_name", "Player"))
	var name_b := str(_store.get_account(account_b).get("display_name", "Player"))
	var m := _new_match(
		engine,
		{1: peer_a, 2: peer_b},
		{1: account_a, 2: account_b},
		{1: name_a, 2: name_b},
		0, false, ctx, int(ctx.get("match_format", 1))
	)
	if peer_a > 0:
		_send_match_found(m, 1)
	if peer_b > 0:
		_send_match_found(m, 2)
	_broadcast_match(m)
	return m


func _create_bot_match_for_account(account_human: int, ctx: Dictionary) -> Dictionary:
	var engine := GameEngine.new(_pool_for_cube(ctx.get("cube_ids", [])))
	engine.deal_hands()
	var peer: int = int(_account_peer.get(account_human, 0))
	var name := str(_store.get_account(account_human).get("display_name", "Player"))
	var m := _new_match(
		engine,
		{1: peer, 2: BOT_SEAT},
		{1: account_human, 2: 0},
		{1: name, 2: "Bot"},
		2, true, ctx, int(ctx.get("match_format", 1))
	)
	if peer > 0:
		_send_match_found(m, 1)
	_broadcast_match(m)
	_maybe_trigger_bot(m)
	return m


## Tournament matches are always unranked (a separate track from the ladder) —
## the summary carries tournament_ctx so game_ui.gd routes to the bracket
## screen instead of match_result_screen on match end.
func _finish_tournament_match(m: Dictionary, winner: int, ctx: Dictionary) -> void:
	var engine: GameEngine = m.engine
	# Bo1 draws are possible (GameEngine: equal score at hand-empty is a draw)
	# but single-elimination can't advance a draw. Not spec'd by the original
	# requirements — breaking the tie with a coin flip is a judgment call.
	var actual_winner := winner
	if actual_winner == 0:
		actual_winner = 1 + (randi() % 2)

	for seat in [1, 2]:
		var target = m.seats[seat]
		if typeof(target) != TYPE_INT or target <= 0:
			continue
		_rpc_match_ended.rpc_id(target, {
			"outcome": _outcome_str(actual_winner, seat),
			"your_score": engine.scores[seat],
			"opponent_score": engine.scores[3 - seat],
			"ranked": false,
			"elo_before": 0, "elo_after": 0, "elo_delta": 0,
			"points_delta": 0, "points_total": 0, "new_rank": 0,
			"quest_completions": [], "quest_points": 0,
			"tournament_ctx": ctx,
			"match_id": m.id,
			"match_format": int(m.get("match_format", 1)),
			"games_won": int(m.series_wins.get(seat, 0)),
			"games_won_opponent": int(m.series_wins.get(3 - seat, 0)),
			# True when the match didn't finish through play — hit the hard cap
			# or both seats abandoned — and the bracket result was decided on
			# score / coin flip. The client shows a brief note before the
			# bracket screen.
			"unfinished": bool(m.get("unfinished", false)),
		})

	_record_tournament_result(m, actual_winner, ctx)


func _record_tournament_result(m: Dictionary, winner: int, ctx: Dictionary) -> void:
	var t := _store.get_tournament(int(ctx.tournament_id))
	if t.is_empty():
		return
	var round_idx := int(ctx.round) - 1
	if round_idx < 0 or round_idx >= (t.rounds as Array).size():
		return
	var round: Array = t.rounds[round_idx]
	var slot := {}
	for s in round:
		if int(s.match_id) == int(m.id):
			slot = s
			break
	if slot.is_empty() or bool(slot.resolved):
		return

	var winner_acc_id := int(m.account_ids[winner])
	var loser_acc_id := int(m.account_ids[3 - winner])
	slot.resolved = true
	slot.winner_is_bot = winner_acc_id == 0
	slot.winner_account_id = winner_acc_id
	var seat_for_a := 1 if int(m.account_ids[1]) == int(slot.account_id_a) else 2
	# Games won (not the last game's card score) so a Bo3/Bo5 bracket reads as
	# "2-1", not just whatever the deciding game's score happened to be.
	slot.score_a = int(m.series_wins.get(seat_for_a, 0))
	slot.score_b = int(m.series_wins.get(3 - seat_for_a, 0))

	if loser_acc_id != 0:
		for p in (t.participants as Array):
			if int(p.account_id) == loser_acc_id:
				p.eliminated_round = int(ctx.round)
				break
		_release_tournament_lock(loser_acc_id)

	_store.persist_tournament(t)
	_broadcast_tournament(t)
	_maybe_advance_round(t)


# =========================================================================
# Tournament RPCs
# =========================================================================

func create_tournament(name: String, bracket_size: int, signup_close_ts: int,
		check_in_open_ts: int, start_ts: int, is_dev_bot: bool, match_format: int = 1,
		cube_ids: PackedStringArray = PackedStringArray(), availability := "open",
		password := "", private_signup_close_ts := 0, late_check_in := false,
		late_check_in_open_ts := 0, prize_spec := {}) -> void:
	_rpc_create_tournament.rpc_id(1, name, bracket_size, signup_close_ts, check_in_open_ts, start_ts,
		is_dev_bot, match_format, cube_ids, availability, password, private_signup_close_ts,
		late_check_in, late_check_in_open_ts, prize_spec)


func list_tournaments() -> void:
	_rpc_list_tournaments.rpc_id(1)


func join_tournament(tournament_id: int, password := "") -> void:
	_rpc_join_tournament.rpc_id(1, tournament_id, password)


## Withdraw from a tournament's sign-up list — only works while it's still in
## "signup" status (before check-in opens); the UI only shows the Cancel
## button then too, but the server re-checks regardless.
func withdraw_tournament(tournament_id: int) -> void:
	_rpc_withdraw_tournament.rpc_id(1, tournament_id)


func tournament_check_in(tournament_id: int) -> void:
	_rpc_tournament_check_in.rpc_id(1, tournament_id)


## Read-only bracket fetch — works for browsing any tournament, not just ones
## the caller is in.
func request_tournament(tournament_id: int) -> void:
	_rpc_request_tournament.rpc_id(1, tournament_id)


## "Which live tournament (if any) am I signed up for?" — fires
## my_tournament_status({} if none) with the full record if so. Session calls
## this on login/menu load so the menu's status card survives a relog instead
## of only ever appearing reactively from signals fired during THIS session.
func request_my_tournament() -> void:
	_rpc_request_my_tournament.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_create_tournament(name: String, bracket_size: int, signup_close_ts: int,
		check_in_open_ts: int, start_ts: int, is_dev_bot: bool, match_format: int = 1,
		cube_ids: PackedStringArray = PackedStringArray(), availability := "open",
		password := "", private_signup_close_ts := 0, late_check_in := false,
		late_check_in_open_ts := 0, prize_spec := {}) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var account := _store.get_account(int(_peer_account[peer_id]))
	# Re-checked here even though the client only shows the button to accounts
	# it thinks are eligible — the client is never trusted as the authority.
	if not _is_tournament_admin(account):
		_rpc_tournament_created.rpc_id(peer_id, {"ok": false, "error": "not_admin", "tournament": {}})
		return
	# The client's cube is never trusted: re-derive a clean, legal id list here
	# (unknown ids dropped, deduped, MIN_SIZE enforced) or bail with the reason.
	var cube := CubeRules.sanitize(cube_ids, _known_card_ids())
	if not bool(cube.ok):
		_rpc_tournament_created.rpc_id(peer_id, {"ok": false, "error": cube.error, "tournament": {}})
		return
	var res := _store.create_tournament(
		int(account.id), name, bracket_size, signup_close_ts, check_in_open_ts, start_ts,
		is_dev_bot, _dev_tournaments, match_format, cube.ids,
		availability, password, private_signup_close_ts, late_check_in, late_check_in_open_ts,
		prize_spec
	)
	# Count every created tournament toward the creator's `tourney_created_*`
	# achievements (dev-bot ones included — the admin still built it), then
	# hand back a fresh account snapshot so the client's stats/achievement
	# progress updates without waiting for the next menu reload.
	if bool(res.get("ok", false)):
		_apply_tournament_achievement(int(account.id), "tournaments_created")
		res["account"] = _store.account_snapshot(_store.get_account(int(account.id)))
	_rpc_tournament_created.rpc_id(peer_id, _public_result(res))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_list_tournaments() -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		return
	_rpc_tournament_list_result.rpc_id(peer_id, _store.list_tournaments())


@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_tournament(tournament_id: int, password := "") -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var res := _store.sign_up(tournament_id, int(_peer_account[peer_id]), password)
	_rpc_tournament_join_result.rpc_id(peer_id, _public_result(res))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_withdraw_tournament(tournament_id: int) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var res := _store.withdraw(tournament_id, int(_peer_account[peer_id]))
	_rpc_tournament_withdraw_result.rpc_id(peer_id, _public_result(res))
	if bool(res.get("ok", false)):
		_broadcast_tournament(res.tournament)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_tournament_check_in(tournament_id: int) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var res := _store.check_in(tournament_id, int(_peer_account[peer_id]))
	if res.ok:
		_peer_tournament_lock[peer_id] = tournament_id
	_rpc_tournament_check_in_result.rpc_id(peer_id, _public_result(res))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_tournament(tournament_id: int) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		return
	var t := _store.get_tournament(tournament_id)
	if not t.is_empty():
		_rpc_tournament_snapshot.rpc_id(peer_id, _store.tournament_public_view(t))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_my_tournament() -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		return
	var acc_id := int(_peer_account[peer_id])
	var found := []
	var now := int(Time.get_unix_time_from_system())
	for t in _store.all_tournaments():
		var st := str(t.status)
		if st == "completed":
			continue
		# A cancelled tournament lingers on the menu as a "didn't fire" notice
		# for 30 minutes, then drops off.
		if st == "cancelled" and now - int(t.get("cancelled_ts", 0)) >= 1800:
			continue
		for p in (t.participants as Array):
			if int(p.account_id) == acc_id:
				found.append(_store.tournament_public_view(t))
				break
	_rpc_my_tournament_status.rpc_id(peer_id, found)


@rpc("authority", "call_remote", "reliable")
func _rpc_my_tournament_status(tournaments: Array) -> void:
	if is_server:
		return
	my_tournament_status.emit(tournaments)


@rpc("authority", "call_remote", "reliable")
func _rpc_tournament_created(result: Dictionary) -> void:
	if is_server:
		return
	tournament_created.emit(result)


@rpc("authority", "call_remote", "reliable")
func _rpc_tournament_list_result(rows: Array) -> void:
	if is_server:
		return
	tournament_list_received.emit(rows)


@rpc("authority", "call_remote", "reliable")
func _rpc_tournament_join_result(result: Dictionary) -> void:
	if is_server:
		return
	tournament_joined.emit(result)


@rpc("authority", "call_remote", "reliable")
func _rpc_tournament_withdraw_result(result: Dictionary) -> void:
	if is_server:
		return
	tournament_withdrawn.emit(result)


@rpc("authority", "call_remote", "reliable")
func _rpc_tournament_check_in_result(result: Dictionary) -> void:
	if is_server:
		return
	tournament_checked_in.emit(result)


@rpc("authority", "call_remote", "reliable")
func _rpc_tournament_snapshot(tournament: Dictionary) -> void:
	if is_server:
		return
	tournament_updated.emit(tournament)


@rpc("authority", "call_remote", "reliable")
func _rpc_account_snapshot(account: Dictionary) -> void:
	if is_server:
		return
	account_updated.emit(account)


@rpc("authority", "call_remote", "reliable")
func _rpc_tournament_prize(info: Dictionary) -> void:
	if is_server:
		return
	if info.has("account"):
		account_updated.emit(info.account)
	tournament_prize_awarded.emit(info)


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
	_peer_tournament_lock.erase(peer_id)
	for key in _custom_games.keys().duplicate():
		if int(_custom_games[key].creator_peer_id) == peer_id:
			_custom_games.erase(key)

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

	# A peer in a live match gets a reconnect grace window rather than an
	# instant abort — the match is frozen, and _check_disconnect_grace decides
	# it against them only if they fail to return in time. A peer NOT in a
	# match (menu/queue) needs nothing more than the cleanup above.
	if _peer_match.has(peer_id):
		var m: Dictionary = _matches.get(_peer_match[peer_id], {})
		_peer_match.erase(peer_id)
		if not m.is_empty() and not m.ended:
			var seat := _seat_of_peer(m, peer_id)
			if seat == 1 or seat == 2:
				m.seats[seat] = 0  # vacant; rebound by account id on reconnect
				var now_ms := Time.get_ticks_msec()
				# Hold only for whatever grace this seat has left this match. Zero
				# left => deadline is now, so the next _check_disconnect_grace tick
				# ends the match against them.
				var budget: int = maxi(0, int((m.get("grace_left_ms", {}) as Dictionary).get(seat, int(RECONNECT_GRACE_SECONDS * 1000.0))))
				(m.disconnected as Dictionary)[seat] = now_ms + budget
				(m.dc_started_ms as Dictionary)[seat] = now_ms
				# Remember how much of their turn was left so the rejoin restores
				# it rather than granting a fresh full turn.
				if int(m.get("on_clock_seat", 0)) == seat:
					var left_ms := clampi(int(_turn_seconds * 1000.0) - (now_ms - int(m.turn_started_ms)), 0, int(_turn_seconds * 1000.0))
					(m.turn_left_at_drop_ms as Dictionary)[seat] = left_ms
				else:
					(m.turn_left_at_drop_ms as Dictionary).erase(seat)
				var other = m.seats[3 - seat]
				if typeof(other) == TYPE_INT and other > 0:
					if budget > 0:
						_rpc_receive_error.rpc_id(other, "Opponent disconnected — up to %d s to reconnect…" % ceili(budget / 1000.0))
					else:
						_rpc_receive_error.rpc_id(other, "Opponent disconnected.")
				print("GameServer: match %d seat %d dropped — holding %.0fs for reconnect (budget)" % [int(m.id), seat, budget / 1000.0])


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
		# Tell the old client this is a deliberate sign-out (not a network drop)
		# so it clears its saved token instead of trying to reconnect. Sent
		# before disconnect_peer, which flushes queued reliable packets first.
		_rpc_force_logout.rpc_id(old_peer, "This account signed in from another device.")
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
	# Token lost but the account reconnected inside its grace window — put them
	# back in the match they dropped from.
	_try_rejoin_match(peer_id, int(res.account.id))


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
	# Reconnect after a dropped connection — rebind to the held match, if any.
	_try_rejoin_match(peer_id, account_id)


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


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_sleeve(sleeve: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var acc_id := int(_peer_account[peer_id])
	var res := _store.set_sleeve(acc_id, Sleeves.sanitize(sleeve))
	if not res.ok:
		_rpc_receive_error.rpc_id(peer_id, "Could not save sleeve.")
		return
	_rpc_sleeve_result.rpc_id(peer_id, _store.account_snapshot(res.account))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_shop_purchase(item_id: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	var acc_id := int(_peer_account[peer_id])
	var res := _store.purchase(acc_id, item_id)
	if not res.ok:
		_rpc_receive_error.rpc_id(peer_id, "Purchase failed: %s" % res.get("error", "unknown error"))
		return
	_rpc_shop_purchase_result.rpc_id(peer_id, _store.account_snapshot(res.account))


@rpc("any_peer", "call_remote", "reliable")
func _rpc_dev_grant_points(amount: int) -> void:
	if not is_server or is_solo or not _dev_tournaments:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		return
	var account := _store.get_account(int(_peer_account[peer_id]))
	if account.is_empty() or amount <= 0:
		return
	_store.grant_reward(account, amount, [])
	_rpc_account_snapshot.rpc_id(peer_id, _store.account_snapshot(account))


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
	if _blocked_by_tournament_lock(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Checked in to a tournament — finish it first.")
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


# =========================================================================
# Custom games (friend invite)
# =========================================================================

func create_custom_game(name: String, match_format: int,
		cube_ids: PackedStringArray = PackedStringArray()) -> void:
	_rpc_create_custom_game.rpc_id(1, name, match_format, cube_ids)


func join_custom_game(name: String) -> void:
	_rpc_join_custom_game.rpc_id(1, name)


## Withdraw a lobby this peer is hosting, if it hasn't been joined yet. Silent
## no-op if there's nothing to cancel (already joined, already gone, or was
## never this peer's) — mirrors cancel_queue's "just clean up if there's
## anything to clean up" shape.
func cancel_custom_game() -> void:
	_rpc_cancel_custom_game.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_create_custom_game(name: String, match_format: int,
		cube_ids: PackedStringArray = PackedStringArray()) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	if _blocked_by_tournament_lock(peer_id):
		_rpc_custom_game_created.rpc_id(peer_id, {"ok": false, "error": "tournament_lock", "name": ""})
		return
	if _peer_match.has(peer_id):
		_rpc_custom_game_created.rpc_id(peer_id, {"ok": false, "error": "already_in_match", "name": ""})
		return
	for lobby in _custom_games.values():
		if int(lobby.creator_peer_id) == peer_id:
			_rpc_custom_game_created.rpc_id(peer_id, {"ok": false, "error": "already_hosting", "name": ""})
			return

	var clean_name := name.strip_edges()
	if clean_name.length() < 1 or clean_name.length() > 40:
		_rpc_custom_game_created.rpc_id(peer_id, {"ok": false, "error": "bad_name", "name": ""})
		return
	var key := clean_name.to_lower()
	if _custom_games.has(key):
		_rpc_custom_game_created.rpc_id(peer_id, {"ok": false, "error": "name_taken", "name": ""})
		return
	# Client-picked cube is re-validated here (unknown ids dropped, deduped,
	# MIN_SIZE enforced). An empty list means "use the full collection".
	var cube := CubeRules.sanitize(cube_ids, _known_card_ids())
	if not bool(cube.ok):
		_rpc_custom_game_created.rpc_id(peer_id, {"ok": false, "error": cube.error, "name": ""})
		return
	var format := match_format if match_format in [1, 3, 5] else 1

	_custom_games[key] = {
		"name": clean_name,
		"creator_account_id": int(_peer_account[peer_id]),
		"creator_peer_id": peer_id,
		"match_format": format,
		"cube_ids": cube.ids,
		"created_ms": Time.get_ticks_msec(),
	}
	_rpc_custom_game_created.rpc_id(peer_id, {"ok": true, "error": "", "name": clean_name})


@rpc("any_peer", "call_remote", "reliable")
func _rpc_join_custom_game(name: String) -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _require_auth(peer_id):
		_rpc_receive_error.rpc_id(peer_id, "Not authenticated.")
		return
	if _blocked_by_tournament_lock(peer_id):
		_rpc_custom_game_join_result.rpc_id(peer_id, {"ok": false, "error": "tournament_lock", "name": ""})
		return
	if _peer_match.has(peer_id):
		_rpc_custom_game_join_result.rpc_id(peer_id, {"ok": false, "error": "already_in_match", "name": ""})
		return

	var key := name.strip_edges().to_lower()
	if not _custom_games.has(key):
		# Covers "never existed", "typo'd", and "someone else already joined
		# it" (a joined lobby is erased immediately below) all with one error —
		# with exactly 2 seats, "full" and "gone" are indistinguishable to a
		# second would-be joiner anyway.
		_rpc_custom_game_join_result.rpc_id(peer_id, {"ok": false, "error": "not_found", "name": ""})
		return
	var lobby: Dictionary = _custom_games[key]
	if int(lobby.creator_peer_id) == peer_id:
		_rpc_custom_game_join_result.rpc_id(peer_id, {"ok": false, "error": "cant_join_own_game", "name": ""})
		return
	if not _peer_account.has(int(lobby.creator_peer_id)):
		# Defensive: the creator's peer disconnect should already have erased
		# this lobby (see _on_peer_disconnected) — but never hand a joiner a
		# match against a peer that isn't there any more.
		_custom_games.erase(key)
		_rpc_custom_game_join_result.rpc_id(peer_id, {"ok": false, "error": "not_found", "name": ""})
		return

	# Consumed immediately (before any further await/broadcast work) so a
	# second near-simultaneous join attempt sees "not_found", never a race
	# where both joiners think they got in.
	_custom_games.erase(key)
	var joiner_account := int(_peer_account[peer_id])
	_rpc_custom_game_join_result.rpc_id(peer_id, {"ok": true, "error": "", "name": lobby.name})
	_create_custom_match(lobby, peer_id, joiner_account)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_cancel_custom_game() -> void:
	if not is_server or is_solo:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	for key in _custom_games.keys():
		if int(_custom_games[key].creator_peer_id) == peer_id:
			_custom_games.erase(key)
			return


func _create_custom_match(lobby: Dictionary, joiner_peer: int, joiner_account: int) -> void:
	var creator_peer: int = int(lobby.creator_peer_id)
	var creator_account: int = int(lobby.creator_account_id)
	var engine := GameEngine.new(_pool_for_cube(lobby.get("cube_ids", [])))
	engine.deal_hands()
	var name_a := str(_store.get_account(creator_account).get("display_name", "Player"))
	var name_b := str(_store.get_account(joiner_account).get("display_name", "Player"))
	var m := _new_match(
		engine,
		{1: creator_peer, 2: joiner_peer},
		{1: creator_account, 2: joiner_account},
		{1: name_a, 2: name_b},
		0, false, {}, int(lobby.match_format)
	)
	m.is_custom_match = true
	_send_match_found(m, 1)
	_send_match_found(m, 2)
	_broadcast_match(m)


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
		# One identity per match (portrait from the bot-only pool + the fixed
		# bot frame/background), kept stable for the life of the match.
		if not m.has("bot_identity"):
			m["bot_identity"] = Avatars.bot_identity()
		var bi: Dictionary = m["bot_identity"]
		return {"name": "Bot", "avatar": str(bi["avatar"]), "frame": str(bi["frame"]), "background": str(bi["background"]), "sleeve": "", "elo": ServerStore.START_ELO, "is_bot": true}
	var acc := _store.get_account(acc_id)
	return {
		"name": str(acc.get("display_name", "Player")),
		"avatar": str(acc.get("avatar", "")),
		"frame": str(acc.get("frame", "")),
		"background": str(acc.get("background", "")),
		"sleeve": str(acc.get("sleeve", "")),
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
		"your_sleeve": me.sleeve,
		"your_elo": me.elo,
		"opponent_name": opp.name,
		"opponent_avatar": opp.avatar,
		"opponent_frame": opp.frame,
		"opponent_background": opp.background,
		"opponent_sleeve": opp.sleeve,
		"opponent_elo": opp.elo,
		"is_bot_match": opp.is_bot,
		"tournament_ctx": m.get("tournament_ctx", {}),
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
func _rpc_custom_game_created(result: Dictionary) -> void:
	if is_server:
		return
	custom_game_created.emit(result)


@rpc("authority", "call_remote", "reliable")
func _rpc_custom_game_join_result(result: Dictionary) -> void:
	if is_server:
		return
	custom_game_join_result.emit(result)


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
func _rpc_sleeve_result(account: Dictionary) -> void:
	if is_server:
		return
	sleeve_updated.emit(account)


@rpc("authority", "call_remote", "reliable")
func _rpc_shop_purchase_result(account: Dictionary) -> void:
	if is_server:
		return
	shop_purchase_result.emit(account)


@rpc("authority", "call_remote", "reliable")
func _rpc_achievements_unlocked(newly: Array) -> void:
	if is_server:
		return
	achievements_unlocked.emit(newly)


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


@rpc("authority", "call_remote", "reliable")
func _rpc_force_logout(reason: String) -> void:
	if is_server:
		return
	force_logout.emit(reason)


## Re-emit the cached assignment + last state. The game UI is loaded via a
## scene swap AFTER match_found / the first state broadcast have already
## arrived, so its _ready() calls this to catch up. Harmless in singleplayer
## (re-emits the same values the UI already has).
func replay_state() -> void:
	if _last_assigned_player != 0:
		player_assigned.emit(_last_assigned_player)
	if not _last_state.is_empty():
		state_updated.emit(_last_state)
