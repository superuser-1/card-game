extends Node
## Headless integration test for the mid-match reconnect / abandon-grace path
## (net_node RECONNECT_GRACE_SECONDS + _try_rejoin_match).
##
## Registers a throwaway account, plays a couple of moves, then simulates a
## network drop (multiplayer.multiplayer_peer.close()). After RECONNECT_DELAY it
## rebuilds the peer (Net.reconnect()) and resumes the saved token
## (Net.auth_resume) — the server should rebind it to the still-held match, and
## play then runs to a normal finish.
##
## PASS = a state_updated arrived AFTER the resume AND match_ended came back with
## a real win/loss/draw outcome (i.e. we were NOT decided against by the grace
## timer). Prints "RECONNECT TEST: PASS" and quits 0; "RECONNECT TEST: FAIL" + 1
## otherwise.
##
## Run one of these plus one plain `--bot` against a `--server`; see
## scripts/reconnect_test.sh which also checks the server log.
##
## Not part of the shipped game — dev/verification tool only.

const MOVES_BEFORE_DROP := 2
const RECONNECT_DELAY := 2.0
const HARD_TIMEOUT := 120.0   # absolute upper bound before declaring FAIL

var _username := ""
var _token := ""
var _moves := 0
var _dropped := false
var _resumed := false
var _saw_state_after_resume := false
var _done := false


func _ready() -> void:
	Net.auth_completed.connect(_on_auth_completed)
	Net.state_updated.connect(_on_state_updated)
	Net.match_ended.connect(_on_match_ended)
	Net.error_received.connect(func(m): print("[recon] server msg: %s" % m))
	get_tree().create_timer(HARD_TIMEOUT).timeout.connect(func():
		if not _done:
			print("[recon] hard timeout reached")
			_finish(false)
	)
	_authenticate.call_deferred()


func _authenticate() -> void:
	var mp := multiplayer.multiplayer_peer
	if mp != null and mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		await multiplayer.connected_to_server
	_username = "recon_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec() % 100000]
	print("[recon] registering as %s" % _username)
	Net.auth_register(_username, "reconpassword")


func _on_auth_completed(result: Dictionary) -> void:
	if not result.ok:
		print("[recon] AUTH FAILED: %s" % result.error)
		_finish(false)
		return
	_token = str(result.token)
	if _dropped:
		_resumed = true
		print("[recon] session RESUMED after drop (token ok)")
	else:
		print("[recon] authenticated — entering queue")
		Net.enqueue_match()


func _on_state_updated(state: Dictionary) -> void:
	if _done:
		return
	if _resumed:
		_saw_state_after_resume = true

	var game_over: bool = state.own_hand.is_empty() or state.opponent_hand_size == 0
	if game_over:
		return

	# Peer is down between the close() and the resume — do nothing.
	if _dropped and not _resumed:
		return

	if not _dropped and _moves >= MOVES_BEFORE_DROP:
		_dropped = true
		print("[recon] dropping connection after %d moves" % _moves)
		multiplayer.multiplayer_peer.close()
		get_tree().create_timer(RECONNECT_DELAY).timeout.connect(_reconnect)
		return

	if state.phase == "awaiting_category" and state.active_player == Net.my_player_id:
		_moves += 1
		Net.submit_category_and_card(state.offered_categories[0], state.own_hand[0].id)
	elif state.phase == "awaiting_response" and not state.your_card_committed:
		_moves += 1
		Net.submit_response_card(state.own_hand[0].id)


func _reconnect() -> void:
	print("[recon] rebuilding peer + resuming token")
	if not Net.reconnect():
		print("[recon] Net.reconnect() failed")
		_finish(false)
		return
	var mp := multiplayer.multiplayer_peer
	while mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		await get_tree().process_frame
	if mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		print("[recon] reconnect did not establish a connection")
		_finish(false)
		return
	Net.auth_resume(_token)


func _on_match_ended(summary: Dictionary) -> void:
	if _done:
		return
	var outcome := str(summary.get("outcome", ""))
	print("[recon] MATCH ENDED outcome=%s | dropped=%s resumed=%s state_after_resume=%s" % [
		outcome, _dropped, _resumed, _saw_state_after_resume])
	var ok := _dropped and _resumed and _saw_state_after_resume and outcome in ["win", "loss", "draw"]
	_finish(ok)


func _finish(ok: bool) -> void:
	if _done:
		return
	_done = true
	print("RECONNECT TEST: %s" % ("PASS" if ok else "FAIL"))
	get_tree().create_timer(0.3).timeout.connect(func(): get_tree().quit(0 if ok else 1))
