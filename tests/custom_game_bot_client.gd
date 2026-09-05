extends Node
## Throwaway headless smoke test: drives the friend-invite custom game flow
## end to end over real separate processes. Not part of the shipped game.
##
## --role=host --game-name=X   : register, create the custom game X, wait for match
## --role=guest --game-name=X  : register, join custom game X
## --role=guest2 --game-name=X : register, attempt to join X too (expects "not_found" once host is full)

var _role := ""
var _game_name := ""
var _username := ""


func _ready() -> void:
	Net.auth_completed.connect(_on_auth_completed)
	Net.custom_game_created.connect(_on_custom_game_created)
	Net.custom_game_join_result.connect(_on_join_result)
	Net.match_found.connect(_on_match_found)
	Net.match_ended.connect(_on_match_ended)
	Net.player_assigned.connect(func(pid): print("[%s] assigned player_id %d" % [_role, pid]))
	Net.state_updated.connect(_on_state_updated)
	Net.error_received.connect(func(msg): print("[%s] ERROR: %s" % [_role, msg]))

	var uargs := OS.get_cmdline_user_args()
	for a in uargs:
		if a.begins_with("--role="):
			_role = a.substr(7)
		elif a.begins_with("--game-name="):
			_game_name = a.substr(12)
	_authenticate.call_deferred()


func _authenticate() -> void:
	var mp := multiplayer.multiplayer_peer
	if mp != null and mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		await multiplayer.connected_to_server
	_username = "cg_%s_%d" % [_role, OS.get_process_id()]
	Net.auth_register(_username, "custompass123")


func _on_auth_completed(result: Dictionary) -> void:
	if not result.ok:
		print("[%s] AUTH FAILED: %s" % [_role, result.error])
		get_tree().quit(1)
		return
	print("[%s] authenticated as %s" % [_role, _username])
	if _role == "host":
		Net.create_custom_game(_game_name, 3)  # Bo3, to also exercise the series path
	else:
		# Give the host a moment to actually create the lobby first.
		await get_tree().create_timer(1.0).timeout
		Net.join_custom_game(_game_name)


func _on_custom_game_created(result: Dictionary) -> void:
	print("[%s] custom_game_created ok=%s error=%s name=%s" % [_role, result.ok, result.get("error", ""), result.get("name", "")])


func _on_join_result(result: Dictionary) -> void:
	print("[%s] custom_game_join_result ok=%s error=%s" % [_role, result.ok, result.get("error", "")])
	if not result.ok and _role == "guest2":
		# Expected outcome for the double-join race test.
		get_tree().create_timer(0.5).timeout.connect(func(): get_tree().quit())


func _on_match_found(info: Dictionary) -> void:
	print("[%s] match_found: seat %d vs %s match_format=%s" % [_role, int(info.your_seat), str(info.opponent_name), str(info.get("match_format", "?"))])


func _on_match_ended(summary: Dictionary) -> void:
	print("[%s] MATCH ENDED outcome=%s ranked=%s format=%s games=%d-%d" % [
		_role, str(summary.outcome), str(summary.ranked), str(summary.get("match_format", "?")),
		int(summary.get("games_won", -1)), int(summary.get("games_won_opponent", -1))
	])
	get_tree().create_timer(0.5).timeout.connect(func(): get_tree().quit())


func _on_state_updated(state: Dictionary) -> void:
	if _role == "guest2":
		return
	var game_over: bool = state.own_hand.is_empty() or state.opponent_hand_size == 0
	if game_over:
		return
	if state.phase == "awaiting_category" and state.active_player == Net.my_player_id:
		var category: String = state.offered_categories[0]
		var card_id: String = state.own_hand[0].id
		Net.submit_category_and_card(category, card_id)
	elif state.phase == "awaiting_response" and not state.your_card_committed:
		var card_id: String = state.own_hand[0].id
		Net.submit_response_card(card_id)
