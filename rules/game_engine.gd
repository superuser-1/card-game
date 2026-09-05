class_name GameEngine
extends RefCounted


const CATEGORIES: Array = [
	"most_oscars", "first_published", "box_office", "longest_runtime",
	"shortest_runtime", "highest_budget", "lowest_budget",
	"highest_audience_score", "director_oscars", "oldest_director", "youngest_director",
	"profit_cost_ratio",
]
const HAND_SIZE := 7

const CATEGORY_GROUP := {
	"most_oscars": "awards",
	"first_published": "time",
	"longest_runtime": "time",
	"shortest_runtime": "time",
	"box_office": "money",
	"highest_budget": "money",
	"lowest_budget": "money",
	"highest_audience_score": "acclaim",
	"director_oscars": "awards",
	"oldest_director": "people",
	"youngest_director": "people",
	"profit_cost_ratio": "money",
}

# Single source of truth for what each category compares, shared with
# BotPlayer so its heuristics can never drift out of sync with the actual
# resolution rules below.
const CATEGORY_FIELD := {
	"most_oscars": "oscars_won",
	"first_published": "release_year",
	"box_office": "box_office_usd",
	"longest_runtime": "runtime_minutes",
	"shortest_runtime": "runtime_minutes",
	"highest_budget": "budget_usd",
	"lowest_budget": "budget_usd",
	"highest_audience_score": "audience_score",
	"director_oscars": "director_oscars_won",
	"oldest_director": "director_age_at_release",
	"youngest_director": "director_age_at_release",
	"profit_cost_ratio": "profit_cost_ratio_pct",
}
const HIGHER_WINS := {
	"most_oscars": true,
	"first_published": false,
	"box_office": true,
	"longest_runtime": true,
	"shortest_runtime": false,
	"highest_budget": true,
	"lowest_budget": false,
	"highest_audience_score": true,
	"director_oscars": true,
	"oldest_director": true,
	"youngest_director": false,
	"profit_cost_ratio": true,
}
# director_age_at_release is null on ~6 cards (co-directed / unknown birth year),
# so oldest/youngest_director need the null-aware comparison path too.
# profit_cost_ratio_pct shares box_office/budget's nullability (no data
# currently triggers it, but stays defensive if a future card is missing one).
const NULLABLE_CATEGORIES: Array = [
	"box_office", "highest_budget", "lowest_budget",
	"oldest_director", "youngest_director", "profit_cost_ratio",
]

var _card_pool: Array
var _rng: RandomNumberGenerator

var hands: Dictionary  # {1: Array, 2: Array}
var reserve: Array
var scores: Dictionary  # {1: int, 2: int}
var active_player: int
var phase: String  # "awaiting_category" or "awaiting_response"
var current_offered_categories: Array
var chosen_category: String
var committed_cards: Dictionary  # {player_id: card_id}
var last_round_result: Dictionary
var round_history: Array  # [{ "category": String, "chooser": int }] — one entry per DECISIVE round (winner or timeout with a category). Ties add nothing.
var _round_number: int


func _init(card_pool: Array, rng_seed: int = -1) -> void:
	_card_pool = card_pool.duplicate(true)
	_rng = RandomNumberGenerator.new()

	if rng_seed >= 0:
		_rng.seed = rng_seed
	else:
		_rng.randomize()

	hands = {}
	reserve = []
	scores = {1: 0, 2: 0}
	active_player = 1
	phase = "awaiting_category"
	current_offered_categories = []
	chosen_category = ""
	committed_cards = {}
	last_round_result = {}
	round_history = []
	_round_number = 1


func deal_hands() -> void:
	# Shuffle card pool using internal RNG
	var shuffled = _card_pool.duplicate()
	_fisher_yates_shuffle(shuffled)

	# Deal 7 to player 1
	hands[1] = shuffled.slice(0, HAND_SIZE)

	# Deal 7 to player 2
	hands[2] = shuffled.slice(HAND_SIZE, HAND_SIZE * 2)

	# Rest goes to reserve
	reserve = shuffled.slice(HAND_SIZE * 2)

	# Reset state
	scores = {1: 0, 2: 0}
	active_player = 1
	phase = "awaiting_category"
	current_offered_categories = []
	chosen_category = ""
	committed_cards = {}
	last_round_result = {}
	round_history = []
	_round_number = 1


func _fisher_yates_shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j = _rng.randi_range(0, i)
		var temp = arr[i]
		arr[i] = arr[j]
		arr[j] = temp


func get_offered_categories() -> Array:
	if phase != "awaiting_category":
		push_error("GameEngine: get_offered_categories called when phase is not 'awaiting_category'")
		return []

	if not current_offered_categories.is_empty():
		return current_offered_categories

	# Pick 3 unique random categories
	var shuffled_categories = CATEGORIES.duplicate()
	_fisher_yates_shuffle(shuffled_categories)
	current_offered_categories = shuffled_categories.slice(0, 3)

	return current_offered_categories


func submit_category_and_card(player_id: int, category: String, card_id: String) -> Dictionary:
	if phase != "awaiting_category":
		return {"ok": false, "error": "not_awaiting_category"}

	if player_id != active_player:
		return {"ok": false, "error": "not_your_turn"}

	if not category in current_offered_categories:
		return {"ok": false, "error": "category_not_offered"}

	if not _card_exists_in_hand(player_id, card_id):
		return {"ok": false, "error": "card_not_in_hand"}

	chosen_category = category
	committed_cards[player_id] = card_id
	phase = "awaiting_response"
	last_round_result = {}

	return {"ok": true, "error": ""}


func submit_response_card(player_id: int, card_id: String) -> Dictionary:
	if phase != "awaiting_response":
		return {"ok": false, "error": "not_awaiting_response"}

	var other_player = 3 - active_player  # Flips 1->2 or 2->1
	if player_id != other_player:
		return {"ok": false, "error": "not_your_turn"}

	if not _card_exists_in_hand(player_id, card_id):
		return {"ok": false, "error": "card_not_in_hand"}

	committed_cards[player_id] = card_id
	var result = resolve_round()

	return {"ok": true, "error": "", "result": result}


func resolve_round() -> Dictionary:
	var player_1_card = _find_card_in_hand(1, committed_cards[1])
	var player_2_card = _find_card_in_hand(2, committed_cards[2])

	var winner = _determine_winner(player_1_card, player_2_card, chosen_category)
	var is_tie = (winner == 0)

	# Capture the committed card ids and who was active BEFORE clearing/
	# flipping state below — clients need to know who initiated this round
	# to lay cards out consistently (active player's card always on the
	# same side), and active_player itself gets flipped further down.
	var active_player_this_round = active_player
	var p1_card_id = committed_cards[1]
	var p2_card_id = committed_cards[2]
	var category_used = chosen_category

	# Remove both cards from hands
	_remove_card_from_hand(1, p1_card_id)
	_remove_card_from_hand(2, p2_card_id)

	# Award points and update active player
	if not is_tie:
		scores[winner] += 1
		active_player = 3 - active_player  # Flip active player
		round_history.append({"category": category_used, "chooser": active_player_this_round})
	else:
		# Tie: redraw from reserve
		_redraw_from_reserve(1)
		_redraw_from_reserve(2)
		# active_player stays the same

	# Check if game is over
	var game_over = hands[1].is_empty() or hands[2].is_empty()
	var match_winner = 0
	if game_over:
		if scores[1] > scores[2]:
			match_winner = 1
		elif scores[2] > scores[1]:
			match_winner = 2
		else:
			match_winner = 0

	# If not a tie, increment round number
	if not is_tie:
		_round_number += 1

	# Build result before resetting state
	var result = {
		"category": category_used,
		"active_player": active_player_this_round,
		"player_1_card": player_1_card.duplicate(),
		"player_2_card": player_2_card.duplicate(),
		"player_1_card_id": p1_card_id,
		"player_2_card_id": p2_card_id,
		"winner": winner,
		"is_tie": is_tie,
		"scores": scores.duplicate(),
		"game_over": game_over,
		"match_winner": match_winner
	}

	# Reset state for next round
	chosen_category = ""
	current_offered_categories = []
	committed_cards = {}
	phase = "awaiting_category"

	last_round_result = result
	return result


## The server calls this when a player's turn clock (30s) runs out. The
## timed-out player forfeits the current category: their opponent takes the
## point, the timed-out player discards a random card from hand, and the
## round then advances exactly like a normal decisive round (active player
## flips, round number increments, game-over is checked). Works whether the
## clock expired while choosing a category (awaiting_category — the active
## player timed out, nothing on the table yet) or while responding
## (awaiting_response — the responder timed out; the active player's already
## committed card is treated as legitimately played and removed as usual).
func resolve_timeout(timed_out_player: int) -> Dictionary:
	var opponent = 3 - timed_out_player
	var active_player_this_round = active_player
	var category_used = chosen_category  # "" if they timed out before choosing

	# Active player's already-committed card (only in awaiting_response) counts
	# as a normal play and leaves their hand.
	var active_card := {}
	var active_card_id := ""
	if phase == "awaiting_response" and committed_cards.has(active_player):
		active_card_id = committed_cards[active_player]
		active_card = _find_card_in_hand(active_player, active_card_id).duplicate()
		_remove_card_from_hand(active_player, active_card_id)

	# The timed-out player loses a random card (their phantom play).
	var discarded_card := {}
	var discarded_card_id := ""
	if not hands[timed_out_player].is_empty():
		var idx = _rng.randi_range(0, hands[timed_out_player].size() - 1)
		discarded_card = hands[timed_out_player][idx].duplicate()
		discarded_card_id = discarded_card.get("id", "")
		hands[timed_out_player].remove_at(idx)

	scores[opponent] += 1
	active_player = 3 - active_player
	_round_number += 1

	if category_used != "":
		round_history.append({"category": category_used, "chooser": active_player_this_round})

	var game_over = hands[1].is_empty() or hands[2].is_empty()
	var match_winner = 0
	if game_over:
		if scores[1] > scores[2]:
			match_winner = 1
		elif scores[2] > scores[1]:
			match_winner = 2

	# Lay cards out on their owners' sides for the client: the active player's
	# committed card on their side, the timed-out player's forced discard on
	# theirs (these are the same side when the active player is the one who
	# timed out).
	var p1_card := {}
	var p2_card := {}
	if not active_card.is_empty():
		if active_player_this_round == 1:
			p1_card = active_card
		else:
			p2_card = active_card
	if timed_out_player == 1:
		p1_card = discarded_card
	else:
		p2_card = discarded_card

	var result = {
		"category": category_used,
		"timeout": true,
		"timed_out_player": timed_out_player,
		"active_player": active_player_this_round,
		"player_1_card": p1_card,
		"player_2_card": p2_card,
		"player_1_card_id": p1_card.get("id", ""),
		"player_2_card_id": p2_card.get("id", ""),
		"winner": opponent,
		"is_tie": false,
		"scores": scores.duplicate(),
		"game_over": game_over,
		"match_winner": match_winner
	}

	chosen_category = ""
	current_offered_categories = []
	committed_cards = {}
	phase = "awaiting_category"

	last_round_result = result
	return result


func _determine_winner(card_1: Dictionary, card_2: Dictionary, category: String) -> int:
	var field: String = CATEGORY_FIELD[category]
	var higher_wins: bool = HIGHER_WINS[category]

	if category in NULLABLE_CATEGORIES:
		return _compare_with_nulls(card_1.get(field), card_2.get(field), higher_wins)

	var v1 = card_1.get(field, 0)
	var v2 = card_2.get(field, 0)
	if higher_wins:
		if v1 > v2:
			return 1
		elif v2 > v1:
			return 2
		else:
			return 0
	else:
		if v1 < v2:
			return 1
		elif v2 < v1:
			return 2
		else:
			return 0


func _compare_with_nulls(val1, val2, highest_wins: bool) -> int:
	var is_null1 = val1 == null
	var is_null2 = val2 == null

	# Both null -> tie
	if is_null1 and is_null2:
		return 0

	# One null, one real -> real value wins
	if is_null1 and not is_null2:
		return 2
	if is_null2 and not is_null1:
		return 1

	# Both real -> compare
	if highest_wins:
		if val1 > val2:
			return 1
		elif val2 > val1:
			return 2
		else:
			return 0
	else:
		if val1 < val2:
			return 1
		elif val2 < val1:
			return 2
		else:
			return 0


func _card_exists_in_hand(player_id: int, card_id: String) -> bool:
	if not hands.has(player_id):
		return false
	for card in hands[player_id]:
		if card.get("id") == card_id:
			return true
	return false


func _find_card_in_hand(player_id: int, card_id: String) -> Dictionary:
	for card in hands[player_id]:
		if card.get("id") == card_id:
			return card
	return {}


func _remove_card_from_hand(player_id: int, card_id: String) -> void:
	if not hands.has(player_id):
		return
	for i in range(hands[player_id].size()):
		if hands[player_id][i].get("id") == card_id:
			hands[player_id].remove_at(i)
			return


func _redraw_from_reserve(player_id: int) -> void:
	if reserve.is_empty():
		return
	var random_index = _rng.randi_range(0, reserve.size() - 1)
	var card = reserve[random_index]
	reserve.remove_at(random_index)
	hands[player_id].append(card)


func get_state_for_player(player_id: int) -> Dictionary:
	var other_player = 3 - player_id

	return {
		"own_hand": hands[player_id].duplicate(true),
		"own_score": scores[player_id],
		"opponent_score": scores[other_player],
		"opponent_hand_size": hands[other_player].size(),
		"round_number": _round_number,
		"active_player": active_player,
		"phase": phase,
		"offered_categories": current_offered_categories if (player_id == active_player and phase == "awaiting_category") else [],
		"chosen_category": chosen_category,
		"your_card_committed": committed_cards.has(player_id),
		"last_round_result": last_round_result.duplicate(true)
	}


func get_card_pool() -> Array:
	return _card_pool


func is_game_over() -> bool:
	return hands[1].is_empty() or hands[2].is_empty()


func get_winner() -> int:
	if scores[1] > scores[2]:
		return 1
	elif scores[2] > scores[1]:
		return 2
	else:
		return 0


func group_pick_counts(player_id: int) -> Dictionary:
	var counts := {}
	for g in CATEGORY_GROUP.values():
		counts[g] = 0
	for entry in round_history:
		if int(entry.chooser) == player_id:
			var g := str(CATEGORY_GROUP.get(entry.category, ""))
			if counts.has(g):
				counts[g] += 1
	return counts


func pick_count(player_id: int) -> int:
	var n := 0
	for entry in round_history:
		if int(entry.chooser) == player_id:
			n += 1
	return n
