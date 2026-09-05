extends Node
## Headless network smoke-test client. Registers a throwaway account, joins the
## matchmaking queue, then auto-plays (first offered category, first card in
## hand) so the full authenticated server<->client loop — auth, matchmaking,
## per-match RPC routing, hidden-info filtering, rating write — can be exercised
## end-to-end across real separate OS processes without a human.
##
## Run two of these against one --server to test a human-vs-human match, or one
## against a --server to test bot-fill after BOT_FILL_SECONDS.
##
## Not part of the shipped game — dev/verification tool only.

var _username := ""
var _idle := false        # --idle: auth + queue, then never act (for timeout tests)
var _forfeit := false     # --forfeit: give up after a couple of moves
var _moves := 0


func _ready() -> void:
	Net.auth_completed.connect(_on_auth_completed)
	Net.match_found.connect(_on_match_found)
	Net.match_ended.connect(_on_match_ended)
	Net.player_assigned.connect(_on_player_assigned)
	Net.state_updated.connect(_on_state_updated)
	Net.error_received.connect(_on_error_received)
	var uargs := OS.get_cmdline_user_args()
	_idle = "--idle" in uargs
	_forfeit = "--forfeit" in uargs
	_authenticate.call_deferred()


func _authenticate() -> void:
	var mp := multiplayer.multiplayer_peer
	if mp != null and mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		await multiplayer.connected_to_server
	_username = "bot_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec() % 100000]
	print("[bot] registering as %s" % _username)
	Net.auth_register(_username, "botpassword")


func _on_auth_completed(result: Dictionary) -> void:
	if not result.ok:
		print("[bot] AUTH FAILED: %s" % result.error)
		get_tree().quit(1)
		return
	print("[bot %s] authenticated, elo %d — entering queue" % [_username, int(result.account.elo)])
	Net.enqueue_match()


func _on_match_found(info: Dictionary) -> void:
	print("[bot %s] match_found: seat %d vs %s (bot_match=%s) | you=%s/%s opp_avatar=%s" % [
		_username, int(info.your_seat), str(info.opponent_name), str(info.is_bot_match),
		str(info.get("your_name", "?")), str(info.get("your_avatar", "?")), str(info.get("opponent_avatar", "?"))
	])


func _on_player_assigned(player_id: int) -> void:
	print("[bot %s] assigned player_id %d" % [_username, player_id])


func _on_error_received(message: String) -> void:
	print("[bot %s] ERROR: %s" % [_username, message])


func _on_match_ended(summary: Dictionary) -> void:
	print("[bot %s] MATCH ENDED — outcome=%s score %d-%d elo %+d (now %d) points +%d rank #%d" % [
		_username, str(summary.outcome), int(summary.your_score), int(summary.opponent_score),
		int(summary.elo_delta), int(summary.elo_after), int(summary.points_delta), int(summary.new_rank)
	])
	get_tree().create_timer(0.5).timeout.connect(func(): get_tree().quit())


func _on_state_updated(state: Dictionary) -> void:
	if _idle:
		return
	var game_over: bool = state.own_hand.is_empty() or state.opponent_hand_size == 0
	if game_over:
		return

	if _forfeit and _moves >= 3:
		print("[bot %s] -> forfeit_match() after %d moves" % [_username, _moves])
		_forfeit = false
		Net.forfeit_match()
		return

	if state.phase == "awaiting_category" and state.active_player == Net.my_player_id:
		var category: String = state.offered_categories[0]
		var card_id: String = state.own_hand[0].id
		print("[bot %s] -> submit_category_and_card(%s, %s)" % [_username, category, card_id])
		_moves += 1
		Net.submit_category_and_card(category, card_id)
	elif state.phase == "awaiting_response" and not state.your_card_committed:
		var card_id: String = state.own_hand[0].id
		_moves += 1
		print("[bot %s] -> submit_response_card(%s)" % [_username, card_id])
		Net.submit_response_card(card_id)
