extends Node
## Headless tournament integration client. One process == one player.
##
##   --tournament-test --tag=X --seq=N [--players=M]
##
## seq 0 creates an OPEN tournament named "<tag> cup" (Bo1, cap 8); every seq
## registers a throwaway account, finds that tournament, signs up, checks in,
## and auto-plays each of its bracket matches (first offered category, first
## card). It exits 0 once the tournament reaches "completed" or once this
## player is eliminated, and 1 on cancel / timeout / auth failure.
##
## Requires the server to run with --dev-tournaments: that drops the admin gate
## (so a bot can create) and the 32-player minimum (so an M-player bracket, bye
## path included, actually fires). Not part of the shipped game.

const CAP := 8
const TIMEOUT_S := 220.0

var _tag := "t"
var _seq := 0
var _players := 7
var _username := ""
var _tid := 0
var _my_id := 0
var _signed_up := false
var _checked_in := false
var _finished := false
var _in_match := false
var _last_status := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tag="):
			_tag = a.substr(6)
		elif a.begins_with("--seq="):
			_seq = int(a.substr(6))
		elif a.begins_with("--players="):
			_players = int(a.substr(10))

	Net.auth_completed.connect(_on_auth)
	Net.tournament_created.connect(_on_created)
	Net.tournament_list_received.connect(_on_list)
	Net.tournament_joined.connect(_on_joined)
	Net.tournament_checked_in.connect(_on_checked_in)
	Net.tournament_updated.connect(_on_updated)
	Net.match_found.connect(_on_match_found)
	Net.match_ended.connect(_on_match_ended)
	Net.state_updated.connect(_on_state)
	Net.error_received.connect(func(m): _log("ERROR: %s" % m))

	var to := Timer.new()
	to.wait_time = TIMEOUT_S
	to.one_shot = true
	to.timeout.connect(func(): _fail("timeout after %ds (status=%s tid=%d signed_up=%s checked_in=%s)" % [
		int(TIMEOUT_S), _last_status, _tid, _signed_up, _checked_in]))
	add_child(to)
	to.start()

	# Slow backstop poll — most progress is driven by tournament_updated, but
	# before sign-up we aren't a broadcast target, and a checked-in player on a
	# bye gets no match_found, so keep asking.
	var poll := Timer.new()
	poll.wait_time = 3.0
	poll.timeout.connect(_tick)
	add_child(poll)
	poll.start()

	_authenticate.call_deferred()


func _authenticate() -> void:
	var mp := multiplayer.multiplayer_peer
	if mp != null and mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		await multiplayer.connected_to_server
	_username = "tt_%s_%d" % [_tag, _seq]
	_log("registering as %s" % _username)
	Net.auth_register(_username, "ttpassword123")


func _on_auth(result: Dictionary) -> void:
	if not result.ok:
		_fail("auth failed: %s" % result.error)
		return
	_my_id = int(result.account.id)
	_log("authenticated (account %d)" % _my_id)
	if _seq == 0:
		var now := int(Time.get_unix_time_from_system())
		# Windows generous enough to survive the 5s tournament tick: sign-up
		# closes ~15s out, check-in ~15s, start ~35s.
		Net.create_tournament("%s cup" % _tag, CAP, now + 15, now + 15, now + 35, false, 1)
	else:
		Net.list_tournaments()


func _on_created(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_fail("create_tournament failed: %s" % result.get("error", "?"))
		return
	_tid = int(result.tournament.id)
	_log("created tournament %d" % _tid)
	Net.join_tournament(_tid)


func _on_list(rows: Array) -> void:
	if _tid != 0:
		return
	for r in rows:
		if str(r.get("name", "")) == "%s cup" % _tag:
			_tid = int(r.id)
			_log("found tournament %d" % _tid)
			Net.join_tournament(_tid)
			return


func _on_joined(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_signed_up = true
		_log("signed up")
	else:
		var e := str(result.get("error", "?"))
		if e == "already_signed_up":
			_signed_up = true
		else:
			_log("join failed: %s (will retry)" % e)


func _on_checked_in(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		_checked_in = true
		_log("checked in")


func _tick() -> void:
	if _finished:
		return
	if _tid == 0:
		Net.list_tournaments()
		return
	if not _signed_up:
		Net.join_tournament(_tid)
		return
	if _last_status == "check_in" and not _checked_in:
		Net.tournament_check_in(_tid)


func _on_updated(t: Dictionary) -> void:
	if int(t.get("id", 0)) != _tid:
		return
	var status := str(t.get("status", ""))
	if status != _last_status:
		_log("tournament status -> %s" % status)
		_last_status = status

	if status == "check_in" and not _checked_in:
		Net.tournament_check_in(_tid)
	elif status == "cancelled":
		_fail("tournament was cancelled")
		return
	elif status == "completed":
		var w := int(t.get("winner_account_id", 0))
		if _seq == 0:
			_log("TOURNAMENT TEST: COMPLETE winner=%d rounds=%d" % [w, (t.get("rounds", []) as Array).size()])
		_ok("tournament completed (winner account %d)" % w)
		return

	# Eliminated? (own participant record carries eliminated_round once we lose)
	for p in (t.get("participants", []) as Array):
		if int(p.get("account_id", -1)) == _my_id and int(p.get("eliminated_round", 0)) != 0:
			_ok("eliminated in round %d" % int(p.eliminated_round))
			return


func _on_match_found(info: Dictionary) -> void:
	var ctx = info.get("tournament_ctx", {})
	if ctx.is_empty() or int(ctx.get("tournament_id", 0)) != _tid:
		return
	_in_match = true
	_log("match_found: round %s seat %d vs %s" % [str(ctx.get("round", "?")), int(info.your_seat), str(info.opponent_name)])


func _on_match_ended(summary: Dictionary) -> void:
	_in_match = false
	_log("match ended: outcome=%s %d-%d" % [str(summary.get("outcome", "?")), int(summary.get("your_score", 0)), int(summary.get("opponent_score", 0))])


func _on_state(state: Dictionary) -> void:
	if not _in_match or _finished:
		return
	if state.get("own_hand", []).is_empty() or int(state.get("opponent_hand_size", 0)) == 0:
		return
	if state.get("phase", "") == "awaiting_category" and int(state.get("active_player", 0)) == Net.my_player_id:
		Net.submit_category_and_card(str(state.offered_categories[0]), str(state.own_hand[0].id))
	elif state.get("phase", "") == "awaiting_response" and not bool(state.get("your_card_committed", false)):
		Net.submit_response_card(str(state.own_hand[0].id))


func _log(msg: String) -> void:
	print("[tt %s#%d] %s" % [_tag, _seq, msg])


func _ok(msg: String) -> void:
	if _finished:
		return
	_finished = true
	_log("PASS — %s" % msg)
	get_tree().create_timer(0.5).timeout.connect(func(): get_tree().quit(0))


func _fail(msg: String) -> void:
	if _finished:
		return
	_finished = true
	_log("FAIL — %s" % msg)
	get_tree().create_timer(0.2).timeout.connect(func(): get_tree().quit(1))
