extends Node
## Headless solo-mode smoke-test driver: auto-plays Player 1's side (always
## first offered category, first card in hand) so the internal BotPlayer
## (Player 2, driven by net/net_node.gd's timer-based triggers) can be
## observed responding on its own, without needing a human to drag cards.
##
## Not part of the shipped game — dev/verification tool only.

func _ready() -> void:
	Net.player_assigned.connect(func(pid): print("[solo-test] assigned player_id ", pid))
	Net.error_received.connect(func(msg): print("[solo-test] ERROR: ", msg))
	Net.state_updated.connect(_on_state_updated)


func _on_state_updated(state: Dictionary) -> void:
	print("[solo-test] state: %s" % JSON.stringify(state))

	var game_over: bool = state.own_hand.is_empty() or state.opponent_hand_size == 0
	if game_over:
		print("[solo-test] GAME OVER — own_score=%d opponent_score=%d" % [state.own_score, state.opponent_score])
		get_tree().create_timer(1.0).timeout.connect(func(): get_tree().quit())
		return

	if state.phase == "awaiting_category" and state.active_player == 1:
		var category: String = state.offered_categories[0]
		var card_id: String = state.own_hand[0].id
		print("[solo-test] -> submit_category_and_card(%s, %s)" % [category, card_id])
		Net.submit_category_and_card(category, card_id)
