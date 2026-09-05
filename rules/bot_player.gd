class_name BotPlayer
extends RefCounted
## Heuristic solo opponent — no LLM, just percentile comparisons against the
## full card pool, per the design doc: "offer/pick the category where your
## card's percentile in the deck is highest" for the active-player move, and
## "play your median-strength card unless behind on points, then play your
## strongest" for the hidden-mode response. Pure logic, no scene dependency,
## same as GameEngine.

## Fraction of `pool` (cards with a real value for this category's field)
## that `card` would beat outright. Cards missing the field return 0.0,
## matching the engine's own null-handling (null always loses).
static func percentile(card: Dictionary, category: String, pool: Array) -> float:
	var field: String = GameEngine.CATEGORY_FIELD[category]
	var higher_wins: bool = GameEngine.HIGHER_WINS[category]
	var value = card.get(field)
	if value == null:
		return 0.0

	var real_values: Array = []
	for pool_card: Dictionary in pool:
		var v = pool_card.get(field)
		if v != null:
			real_values.append(v)
	if real_values.is_empty():
		return 0.0

	var beat_count := 0
	for v in real_values:
		if higher_wins and value > v:
			beat_count += 1
		elif not higher_wins and value < v:
			beat_count += 1
	return float(beat_count) / float(real_values.size())


## Active-player move: try every (offered category, hand card) pairing and
## take whichever has the single highest percentile.
static func choose_active_move(offered_categories: Array, hand: Array, pool: Array) -> Dictionary:
	var best_category := ""
	var best_card_id := ""
	var best_score := -1.0

	for category: String in offered_categories:
		for card: Dictionary in hand:
			var score := percentile(card, category, pool)
			if score > best_score:
				best_score = score
				best_category = category
				best_card_id = card.id

	return {"category": best_category, "card_id": best_card_id}


## Response card, hidden-mode heuristic: play safely (median strength for
## this category) unless behind on points, in which case swing for the win
## with the strongest card.
static func choose_response_card(category: String, hand: Array, pool: Array, own_score: int, opponent_score: int) -> String:
	var scored: Array = []
	for card: Dictionary in hand:
		scored.append({"id": card.id, "score": percentile(card, category, pool)})
	scored.sort_custom(func(a, b): return a.score < b.score)

	if own_score < opponent_score:
		return scored[-1].id
	return scored[scored.size() / 2].id
