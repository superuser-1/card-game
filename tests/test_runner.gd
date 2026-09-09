extends SceneTree


var _test_count = 0
var _fail_count = 0

var _test_cards = [
	{"id": "card_a", "title": "High Oscar Film", "release_year": 1990, "runtime_minutes": 120, "oscars_won": 5, "box_office_usd": 100000000, "budget_usd": 50000000, "audience_score": 92, "director_oscars_won": 3, "director_age_at_release": 55, "profit_cost_ratio_pct": 100},
	{"id": "card_b", "title": "Low Oscar Film", "release_year": 1995, "runtime_minutes": 100, "oscars_won": 0, "box_office_usd": 50000000, "budget_usd": 10000000, "audience_score": 65, "director_oscars_won": 0, "director_age_at_release": 40, "profit_cost_ratio_pct": 400},
	{"id": "card_c", "title": "Old Movie", "release_year": 1950, "runtime_minutes": 110, "oscars_won": 2, "box_office_usd": 200000000, "budget_usd": 30000000, "audience_score": 88, "director_oscars_won": 2, "director_age_at_release": 62, "profit_cost_ratio_pct": 60},
	{"id": "card_d", "title": "New Movie", "release_year": 2020, "runtime_minutes": 130, "oscars_won": 1, "box_office_usd": 300000000, "budget_usd": 80000000, "audience_score": 70, "director_oscars_won": 1, "director_age_at_release": 35, "profit_cost_ratio_pct": 275},
	{"id": "card_e", "title": "Short Film", "release_year": 1980, "runtime_minutes": 90, "oscars_won": 1, "box_office_usd": 10000000, "budget_usd": 5000000, "audience_score": 60, "director_oscars_won": 0, "director_age_at_release": 48, "profit_cost_ratio_pct": -20},
	{"id": "card_f", "title": "Long Film", "release_year": 1985, "runtime_minutes": 180, "oscars_won": 3, "box_office_usd": 150000000, "budget_usd": 40000000, "audience_score": 85, "director_oscars_won": 4, "director_age_at_release": 70, "profit_cost_ratio_pct": 275},
	{"id": "card_g", "title": "High Budget", "release_year": 2000, "runtime_minutes": 115, "oscars_won": 2, "box_office_usd": 250000000, "budget_usd": 200000000, "audience_score": 75, "director_oscars_won": 1, "director_age_at_release": 44, "profit_cost_ratio_pct": 25},
	{"id": "card_h", "title": "Low Budget", "release_year": 2005, "runtime_minutes": 105, "oscars_won": 1, "box_office_usd": 50000000, "budget_usd": 1000000, "audience_score": 80, "director_oscars_won": 0, "director_age_at_release": 38, "profit_cost_ratio_pct": 4900},
	{"id": "card_i", "title": "Null Box Office", "release_year": 1960, "runtime_minutes": 125, "oscars_won": 2, "box_office_usd": null, "budget_usd": 25000000, "audience_score": 90, "director_oscars_won": 2, "director_age_at_release": null, "profit_cost_ratio_pct": null},
	{"id": "card_j", "title": "Real Box Office", "release_year": 1965, "runtime_minutes": 95, "oscars_won": 1, "box_office_usd": 100000, "budget_usd": 20000000, "audience_score": 78, "director_oscars_won": 1, "director_age_at_release": 52, "profit_cost_ratio_pct": 90},
	{"id": "card_k", "title": "Null Budget 1", "release_year": 1970, "runtime_minutes": 110, "oscars_won": 0, "box_office_usd": 50000000, "budget_usd": null, "audience_score": 68, "director_oscars_won": 0, "director_age_at_release": null, "profit_cost_ratio_pct": null},
	{"id": "card_l", "title": "Null Budget 2", "release_year": 1975, "runtime_minutes": 140, "oscars_won": 0, "box_office_usd": 75000000, "budget_usd": null, "audience_score": 72, "director_oscars_won": 0, "director_age_at_release": 66, "profit_cost_ratio_pct": 500},
	{"id": "card_m", "title": "Tie Oscar Card 1", "release_year": 2010, "runtime_minutes": 100, "oscars_won": 2, "box_office_usd": 100000000, "budget_usd": 15000000, "audience_score": 82, "director_oscars_won": 2, "director_age_at_release": 50, "profit_cost_ratio_pct": 566},
	{"id": "card_n", "title": "Tie Oscar Card 2", "release_year": 2012, "runtime_minutes": 110, "oscars_won": 2, "box_office_usd": 50000000, "budget_usd": 12000000, "audience_score": 82, "director_oscars_won": 2, "director_age_at_release": 50, "profit_cost_ratio_pct": 566},
	{"id": "card_o", "title": "Medium Film 1", "release_year": 2015, "runtime_minutes": 120, "oscars_won": 1, "box_office_usd": 120000000, "budget_usd": 25000000, "audience_score": 76, "director_oscars_won": 1, "director_age_at_release": 45, "profit_cost_ratio_pct": 380},
	{"id": "card_p", "title": "Medium Film 2", "release_year": 2018, "runtime_minutes": 135, "oscars_won": 1, "box_office_usd": 110000000, "budget_usd": 35000000, "audience_score": 79, "director_oscars_won": 1, "director_age_at_release": 58, "profit_cost_ratio_pct": 214},
]


func _initialize() -> void:
	# Run tests
	test_card_loader_basic()
	test_deal_hands()
	test_get_offered_categories()
	test_submit_category_validation()
	test_submit_response_validation()
	test_full_non_tie_round()
	test_null_handling()
	test_new_categories()
	test_tie_round()
	test_game_exhaust_and_winner()
	test_bot_player()
	test_resolve_timeout_awaiting_category()
	test_resolve_timeout_awaiting_response()
	test_round_history()
	test_cube_rules()

	# Print final result
	if _fail_count == 0:
		print("ALL TESTS PASSED")
		quit(0)
	else:
		print("TESTS FAILED: %d" % _fail_count)
		quit(1)


func pass_test(message: String) -> void:
	_test_count += 1
	print("PASS: %s" % message)


func fail_test(message: String) -> void:
	_test_count += 1
	_fail_count += 1
	print("FAIL: %s" % message)


func assert_equal(actual, expected, message: String) -> void:
	if actual == expected:
		pass_test(message)
	else:
		fail_test("%s (expected %s, got %s)" % [message, str(expected), str(actual)])


func assert_true(condition: bool, message: String) -> void:
	if condition:
		pass_test(message)
	else:
		fail_test(message)


func test_card_loader_basic() -> void:
	print("\n=== CardLoader Tests ===")
	var cards = CardLoader.load_cards("res://data/cards.json")
	# 308 rows in the data, minus the 2 direct-to-streaming titles the loader
	# drops from the playable pool by default (see CardLoader.load_cards).
	assert_true(cards.size() == 306, "load_cards returns 306 playable cards from real data")
	assert_true(cards[0] is Dictionary, "first card is a Dictionary")
	assert_true(cards[0].has("title"), "first card has 'title' key")
	var has_streaming := false
	for c in cards:
		if bool(c.get("streaming_release", false)):
			has_streaming = true
	assert_true(not has_streaming, "playable pool excludes streaming_release cards")
	assert_true(CardLoader.load_cards("res://data/cards.json", true).size() == 308, "include_streaming returns all 308")


func test_deal_hands() -> void:
	print("\n=== Deal Hands Tests ===")
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()

	assert_equal(engine.hands[1].size(), 7, "player 1 has 7 cards")
	assert_equal(engine.hands[2].size(), 7, "player 2 has 7 cards")
	assert_equal(engine.reserve.size(), 2, "reserve has 2 cards (16 total - 14 dealt)")

	# Check no duplicate ids
	var all_ids = {}
	for card in engine.hands[1]:
		var card_id = card.get("id")
		assert_true(not all_ids.has(card_id), "no duplicate id: %s" % card_id)
		all_ids[card_id] = true

	for card in engine.hands[2]:
		var card_id = card.get("id")
		assert_true(not all_ids.has(card_id), "no duplicate id between hands: %s" % card_id)
		all_ids[card_id] = true

	for card in engine.reserve:
		var card_id = card.get("id")
		assert_true(not all_ids.has(card_id), "no duplicate id in reserve: %s" % card_id)


func test_get_offered_categories() -> void:
	print("\n=== Get Offered Categories Tests ===")
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()

	var cats1 = engine.get_offered_categories()
	assert_equal(cats1.size(), 3, "offers 3 categories")

	var has_all_valid = true
	for cat in cats1:
		if not cat in GameEngine.CATEGORIES:
			has_all_valid = false
	assert_true(has_all_valid, "all offered categories are valid")

	# Check for uniqueness
	var unique_set = {}
	for cat in cats1:
		unique_set[cat] = true
	assert_equal(unique_set.size(), 3, "offered categories are unique")

	# Idempotent - calling again returns same array
	var cats2 = engine.get_offered_categories()
	assert_equal(cats1, cats2, "get_offered_categories is idempotent")


func test_submit_category_validation() -> void:
	print("\n=== Submit Category Validation Tests ===")
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()

	var offered = engine.get_offered_categories()
	var player1_cards = engine.hands[1]
	var valid_card_id = player1_cards[0].get("id")

	# Wrong phase (should work first time, then fail second time if we don't complete round)
	var result = engine.submit_category_and_card(1, offered[0], valid_card_id)
	assert_true(result["ok"], "valid submit succeeds")
	assert_equal(engine.phase, "awaiting_response", "phase changes to awaiting_response")

	# Now phase is awaiting_response, so this should fail
	var engine2 = GameEngine.new(_test_cards, 42)
	engine2.deal_hands()
	offered = engine2.get_offered_categories()
	result = engine2.submit_category_and_card(2, offered[0], player1_cards[0].get("id"), )
	assert_true(result["ok"] == false, "wrong player (not active) is rejected")
	assert_equal(result["error"], "not_your_turn", "error is 'not_your_turn'")
	assert_equal(engine2.phase, "awaiting_category", "phase unchanged on error")

	# Wrong category
	var engine3 = GameEngine.new(_test_cards, 42)
	engine3.deal_hands()
	offered = engine3.get_offered_categories()
	result = engine3.submit_category_and_card(1, "invalid_category", valid_card_id)
	assert_true(result["ok"] == false, "invalid category is rejected")
	assert_equal(result["error"], "category_not_offered", "error is 'category_not_offered'")

	# Card not in hand
	var engine4 = GameEngine.new(_test_cards, 42)
	engine4.deal_hands()
	offered = engine4.get_offered_categories()
	result = engine4.submit_category_and_card(1, offered[0], "nonexistent_card")
	assert_true(result["ok"] == false, "card not in hand is rejected")
	assert_equal(result["error"], "card_not_in_hand", "error is 'card_not_in_hand'")


func test_submit_response_validation() -> void:
	print("\n=== Submit Response Validation Tests ===")
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()

	var offered = engine.get_offered_categories()
	var p1_cards = engine.hands[1]
	var p2_cards = engine.hands[2]

	# Player 1 submits category
	var result = engine.submit_category_and_card(1, offered[0], p1_cards[0].get("id"))
	assert_true(result["ok"], "player 1 can submit category")

	# Player 1 tries to respond (wrong player)
	result = engine.submit_response_card(1, p1_cards[1].get("id"))
	assert_true(result["ok"] == false, "active player cannot respond to themselves")
	assert_equal(result["error"], "not_your_turn", "error is 'not_your_turn'")

	# Player 2 tries non-existent card
	result = engine.submit_response_card(2, "nonexistent")
	assert_true(result["ok"] == false, "nonexistent card rejected")
	assert_equal(result["error"], "card_not_in_hand", "error is 'card_not_in_hand'")


func test_full_non_tie_round() -> void:
	print("\n=== Full Non-Tie Round Tests ===")
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()

	var initial_p1_hand_size = engine.hands[1].size()
	var initial_p2_hand_size = engine.hands[2].size()

	engine.get_offered_categories()
	# Force the offer so the test isn't at the mercy of which 3 of the 7
	# categories the RNG happened to pick this run.
	engine.current_offered_categories = ["most_oscars", "first_published", "box_office"]

	# Use "most_oscars" category and play high-oscar card vs low-oscar card
	var high_oscar = _force_card_into_hand(engine, 1, "card_a")
	var low_oscar = _force_card_into_hand(engine, 2, "card_b")
	initial_p1_hand_size = engine.hands[1].size()
	initial_p2_hand_size = engine.hands[2].size()

	if high_oscar.is_empty() or low_oscar.is_empty():
		fail_test("test setup: couldn't find required cards for non-tie test")
		return

	var result = engine.submit_category_and_card(1, "most_oscars", high_oscar.get("id"))
	assert_true(result["ok"], "player 1 submits high oscar card for most_oscars")

	result = engine.submit_response_card(2, low_oscar.get("id"))
	assert_true(result["ok"], "player 2 submits low oscar card")

	var round_result = result["result"]
	assert_equal(round_result["winner"], 1, "high oscar (5) beats low oscar (0)")
	assert_equal(round_result["is_tie"], false, "not a tie")
	assert_equal(engine.scores[1], 1, "winner gets 1 point")
	assert_equal(engine.scores[2], 0, "loser gets 0 points")
	assert_equal(engine.hands[1].size(), initial_p1_hand_size - 1, "player 1 loses one card")
	assert_equal(engine.hands[2].size(), initial_p2_hand_size - 1, "player 2 loses one card")
	assert_equal(engine.active_player, 2, "active player alternates to player 2")
	assert_equal(engine.phase, "awaiting_category", "phase resets to awaiting_category")
	assert_equal(engine.last_round_result, round_result, "last_round_result is stored")
	assert_equal(round_result["player_1_card"]["title"], "High Oscar Film", "result includes full player_1_card for client-side reveal")
	assert_equal(round_result["player_2_card"]["title"], "Low Oscar Film", "result includes full player_2_card for client-side reveal")
	assert_equal(round_result["active_player"], 1, "result records who was active this round (player 1 initiated it here)")


func test_null_handling() -> void:
	print("\n=== Null Handling Tests ===")

	# Test: null box_office vs real box_office
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()

	var null_box = _force_card_into_hand(engine, 1, "card_i")  # null box_office
	var real_box = _force_card_into_hand(engine, 2, "card_j")  # real box_office: 100000
	engine.current_offered_categories = ["box_office", "most_oscars", "first_published"]

	if null_box.is_empty() or real_box.is_empty():
		fail_test("test setup: couldn't find null/real box_office cards")
		return

	var result = engine.submit_category_and_card(1, "box_office", null_box.get("id"))
	assert_true(result["ok"], "can submit null box_office card")

	result = engine.submit_response_card(2, real_box.get("id"))
	assert_true(result["ok"], "can submit real box_office card")

	var round_result = result["result"]
	assert_equal(round_result["winner"], 2, "real box_office beats null")
	assert_equal(round_result["is_tie"], false, "not a tie")

	# Test: both null budget -> tie
	var engine2 = GameEngine.new(_test_cards, 43)
	engine2.deal_hands()

	var null_budget_1 = _force_card_into_hand(engine2, 1, "card_k")
	var null_budget_2 = _force_card_into_hand(engine2, 2, "card_l")
	engine2.current_offered_categories = ["highest_budget", "most_oscars", "first_published"]

	if null_budget_1.is_empty() or null_budget_2.is_empty():
		fail_test("test setup: couldn't find both null budget cards")
		return

	result = engine2.submit_category_and_card(1, "highest_budget", null_budget_1.get("id"))
	assert_true(result["ok"], "can submit null budget card")

	result = engine2.submit_response_card(2, null_budget_2.get("id"))
	assert_true(result["ok"], "can submit another null budget card")

	round_result = result["result"]
	assert_equal(round_result["winner"], 0, "both null budgets tie")
	assert_equal(round_result["is_tie"], true, "is_tie is true")


func _decisive(seed: int, offered: Array, cat: String, id1: String, id2: String) -> Dictionary:
	var engine = GameEngine.new(_test_cards, seed)
	engine.deal_hands()
	engine.get_offered_categories()
	engine.current_offered_categories = offered
	var c1 = _force_card_into_hand(engine, 1, id1)
	var c2 = _force_card_into_hand(engine, 2, id2)
	var r = engine.submit_category_and_card(1, cat, c1.get("id"))
	if not r["ok"]:
		return {"error": r["error"]}
	r = engine.submit_response_card(2, c2.get("id"))
	return r.get("result", {"error": r.get("error", "?")})


func test_new_categories() -> void:
	print("\n=== New Categories (audience / director oscars / director age) ===")

	# CATEGORY tables know the five new keys.
	assert_equal(GameEngine.CATEGORIES.size(), 12, "CATEGORIES now has 12 entries")
	for key in ["highest_audience_score", "director_oscars", "oldest_director", "youngest_director", "profit_cost_ratio"]:
		assert_true(GameEngine.CATEGORY_FIELD.has(key), "%s in CATEGORY_FIELD" % key)
		assert_true(GameEngine.HIGHER_WINS.has(key), "%s in HIGHER_WINS" % key)
		assert_true(GameEngine.CATEGORY_GROUP.has(key), "%s in CATEGORY_GROUP" % key)
	assert_equal(GameEngine.CATEGORY_GROUP["director_oscars"], "awards", "director_oscars -> awards group")
	assert_equal(GameEngine.CATEGORY_GROUP["highest_audience_score"], "acclaim", "audience -> acclaim group")
	assert_equal(GameEngine.CATEGORY_GROUP["oldest_director"], "people", "oldest_director -> people group")

	var offered := ["highest_audience_score", "director_oscars", "oldest_director"]

	# highest_audience_score: 92 beats 65.
	var res := _decisive(11, offered, "highest_audience_score", "card_a", "card_b")
	assert_equal(res.get("winner"), 1, "audience 92 beats 65")

	# director_oscars: 4 beats 0.
	res = _decisive(12, offered, "director_oscars", "card_f", "card_b")
	assert_equal(res.get("winner"), 1, "director_oscars 4 beats 0")

	# oldest_director: age 70 beats age 35.
	res = _decisive(13, offered, "oldest_director", "card_f", "card_d")
	assert_equal(res.get("winner"), 1, "oldest_director 70 beats 35")

	# youngest_director: age 35 beats age 70 (lower wins).
	res = _decisive(14, ["youngest_director", "director_oscars", "box_office"], "youngest_director", "card_d", "card_f")
	assert_equal(res.get("winner"), 1, "youngest_director 35 beats 70")

	# Null director age loses to a real one (like box_office null-handling).
	res = _decisive(15, offered, "oldest_director", "card_i", "card_j")
	assert_equal(res.get("winner"), 2, "null director age loses to a real age")

	# Both null director age -> tie.
	res = _decisive(16, offered, "oldest_director", "card_i", "card_k")
	assert_equal(res.get("winner"), 0, "both null director age -> tie")
	assert_equal(res.get("is_tie"), true, "is_tie true when both director ages null")

	# profit_cost_ratio: money group, higher wins, null-aware like box_office.
	assert_equal(GameEngine.CATEGORY_GROUP["profit_cost_ratio"], "money", "profit_cost_ratio -> money group")
	assert_true("profit_cost_ratio" in GameEngine.NULLABLE_CATEGORIES, "profit_cost_ratio is nullable")

	var pcr_offered := ["profit_cost_ratio", "director_oscars", "oldest_director"]
	res = _decisive(17, pcr_offered, "profit_cost_ratio", "card_h", "card_g")
	assert_equal(res.get("winner"), 1, "profit_cost_ratio 4900% beats 25%")

	res = _decisive(18, pcr_offered, "profit_cost_ratio", "card_e", "card_a")
	assert_equal(res.get("winner"), 2, "negative profit_cost_ratio (-20%) loses to positive (100%)")

	res = _decisive(19, pcr_offered, "profit_cost_ratio", "card_i", "card_j")
	assert_equal(res.get("winner"), 2, "null profit_cost_ratio loses to a real value")

	res = _decisive(20, pcr_offered, "profit_cost_ratio", "card_i", "card_k")
	assert_equal(res.get("winner"), 0, "both null profit_cost_ratio -> tie")


func test_tie_round() -> void:
	print("\n=== Tie Round Tests ===")
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()

	var initial_reserve_size = engine.reserve.size()
	var initial_p1_hand_size = engine.hands[1].size()
	var initial_p2_hand_size = engine.hands[2].size()
	var initial_active = engine.active_player

	# Play two cards that tie on a category
	var tie_card_1 = _force_card_into_hand(engine, 1, "card_m")  # oscar_won: 2
	var tie_card_2 = _force_card_into_hand(engine, 2, "card_n")  # oscar_won: 2
	initial_p1_hand_size = engine.hands[1].size()
	initial_p2_hand_size = engine.hands[2].size()
	engine.current_offered_categories = ["most_oscars", "first_published", "box_office"]

	if tie_card_1.is_empty() or tie_card_2.is_empty():
		fail_test("test setup: couldn't find tie cards")
		return

	var result = engine.submit_category_and_card(1, "most_oscars", tie_card_1.get("id"))
	assert_true(result["ok"], "player 1 submits first tie card")

	result = engine.submit_response_card(2, tie_card_2.get("id"))
	assert_true(result["ok"], "player 2 submits second tie card")

	var round_result = result["result"]
	assert_equal(round_result["winner"], 0, "tie is detected")
	assert_equal(round_result["is_tie"], true, "is_tie flag is true")
	assert_equal(engine.scores[1], 0, "no points awarded on tie")
	assert_equal(engine.scores[2], 0, "no points awarded on tie")
	assert_equal(engine.active_player, initial_active, "active_player unchanged after tie")

	# Check reserve drawing
	if initial_reserve_size > 0:
		assert_equal(engine.hands[1].size(), initial_p1_hand_size, "player 1 hand size restored after redraw")
		assert_equal(engine.hands[2].size(), initial_p2_hand_size, "player 2 hand size restored after redraw")
	else:
		assert_equal(engine.hands[1].size(), initial_p1_hand_size - 1, "player 1 loses card with empty reserve")


func test_game_exhaust_and_winner() -> void:
	print("\n=== Game Exhaustion and Winner Tests ===")

	# Play enough non-tie rounds to exhaust a hand
	var engine = GameEngine.new(_test_cards, 99)
	engine.deal_hands()

	var round_count = 0
	var max_rounds = 20

	while not engine.is_game_over() and round_count < max_rounds:
		var offered = engine.get_offered_categories()
		if offered.is_empty():
			offered = engine.get_offered_categories()

		var active_hand = engine.hands[engine.active_player]
		var other_player = 3 - engine.active_player
		var other_hand = engine.hands[other_player]

		if active_hand.is_empty() or other_hand.is_empty():
			break

		# Pick first card from active player
		var active_card = active_hand[0]
		var result = engine.submit_category_and_card(engine.active_player, offered[0], active_card.get("id"))

		if not result["ok"]:
			break

		# Pick first card from responder
		var resp_card = other_hand[0]
		result = engine.submit_response_card(other_player, resp_card.get("id"))

		if not result["ok"]:
			break

		round_count += 1

	assert_true(engine.is_game_over(), "game ends when a hand is exhausted")

	# Check winner matches higher score
	var winner = engine.get_winner()
	if engine.scores[1] > engine.scores[2]:
		assert_equal(winner, 1, "winner is player 1 when they have higher score")
	elif engine.scores[2] > engine.scores[1]:
		assert_equal(winner, 2, "winner is player 2 when they have higher score")
	else:
		assert_equal(winner, 0, "winner is 0 (draw) when scores are equal")


func test_bot_player() -> void:
	print("\n=== Bot Player Tests ===")

	var card_a = _find_card_by_id(_test_cards, "card_a")  # oscars_won: 5, highest in pool
	var card_b = _find_card_by_id(_test_cards, "card_b")  # oscars_won: 0, lowest
	var card_f = _find_card_by_id(_test_cards, "card_f")  # oscars_won: 3, mid-high
	var card_i = _find_card_by_id(_test_cards, "card_i")  # box_office_usd: null

	assert_true(BotPlayer.percentile(card_a, "most_oscars", _test_cards) > 0.9,
		"highest oscar count in pool scores a very high percentile")
	assert_equal(BotPlayer.percentile(card_i, "box_office", _test_cards), 0.0,
		"a null field always scores percentile 0.0 (matches engine's null-always-loses rule)")

	var move = BotPlayer.choose_active_move(
		["most_oscars", "longest_runtime", "highest_budget"], [card_a, card_b], _test_cards
	)
	assert_equal(move["category"], "most_oscars", "bot picks the category with the best percentile match")
	assert_equal(move["card_id"], "card_a", "bot picks the card that gives that best percentile")

	var behind_pick = BotPlayer.choose_response_card("most_oscars", [card_a, card_b, card_f], _test_cards, 0, 5)
	assert_equal(behind_pick, "card_a", "when behind on points, bot plays its strongest card")

	var even_pick = BotPlayer.choose_response_card("most_oscars", [card_a, card_b, card_f], _test_cards, 5, 0)
	assert_equal(even_pick, "card_f", "when not behind, bot plays its median-strength card, not its best")


func test_resolve_timeout_awaiting_category() -> void:
	print("\n=== Resolve Timeout (awaiting_category) ===")
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()
	engine.get_offered_categories()

	var active = engine.active_player          # the player on the clock
	var opponent = 3 - active
	var active_hand_before = engine.hands[active].size()
	var opp_hand_before = engine.hands[opponent].size()

	var result = engine.resolve_timeout(active)

	assert_equal(result["timeout"], true, "result flagged as timeout")
	assert_equal(result["timed_out_player"], active, "records who timed out")
	assert_equal(result["winner"], opponent, "opponent wins the category")
	assert_equal(engine.scores[opponent], 1, "opponent gets the point")
	assert_equal(engine.scores[active], 0, "timed-out player gets nothing")
	assert_equal(engine.hands[active].size(), active_hand_before - 1, "timed-out player loses one random card")
	assert_equal(engine.hands[opponent].size(), opp_hand_before, "opponent keeps their whole hand")
	assert_equal(engine.active_player, opponent, "active player flips, like a decisive round")
	assert_equal(engine.phase, "awaiting_category", "phase resets to awaiting_category")
	assert_equal(engine.chosen_category, "", "chosen_category cleared")


func test_resolve_timeout_awaiting_response() -> void:
	print("\n=== Resolve Timeout (awaiting_response) ===")
	var engine = GameEngine.new(_test_cards, 7)
	engine.deal_hands()
	engine.get_offered_categories()
	engine.current_offered_categories = ["most_oscars", "first_published", "box_office"]

	var active = engine.active_player
	var responder = 3 - active
	var active_card = engine.hands[active][0].get("id")
	var res = engine.submit_category_and_card(active, "most_oscars", active_card)
	assert_true(res["ok"], "active player commits a card")
	assert_equal(engine.phase, "awaiting_response", "now awaiting response")

	var active_hand_before = engine.hands[active].size()
	var responder_hand_before = engine.hands[responder].size()

	var result = engine.resolve_timeout(responder)

	assert_equal(result["timeout"], true, "result flagged as timeout")
	assert_equal(result["winner"], active, "active player wins the category")
	assert_equal(engine.scores[active], 1, "active player gets the point")
	assert_equal(engine.hands[active].size(), active_hand_before - 1, "active player's committed card leaves their hand")
	assert_equal(engine.hands[responder].size(), responder_hand_before - 1, "responder loses one random card")
	assert_equal(engine.active_player, responder, "active player flips")
	assert_equal(engine.phase, "awaiting_category", "phase resets")
	assert_true(not result["player_%d_card" % active].is_empty(), "active player's played card is in the result")


func test_round_history() -> void:
	print("\n=== Round History Tests ===")

	# Test 1: decisive round adds entry
	var engine = GameEngine.new(_test_cards, 42)
	engine.deal_hands()
	engine.get_offered_categories()
	engine.current_offered_categories = ["box_office", "most_oscars", "first_published"]

	var money_card_1 = _force_card_into_hand(engine, 1, "card_a")  # has box_office
	var money_card_2 = _force_card_into_hand(engine, 2, "card_b")

	if money_card_1.is_empty() or money_card_2.is_empty():
		fail_test("test setup: couldn't find required cards for round_history test")
		return

	var result = engine.submit_category_and_card(1, "box_office", money_card_1.get("id"))
	assert_true(result["ok"], "player 1 submits box_office card")

	result = engine.submit_response_card(2, money_card_2.get("id"))
	assert_true(result["ok"], "player 2 responds")

	assert_equal(engine.round_history.size(), 1, "round_history has 1 entry after decisive round")
	assert_equal(engine.round_history[0]["category"], "box_office", "entry records the category")
	assert_equal(engine.round_history[0]["chooser"], 1, "entry records player 1 as chooser")

	var group_picks = engine.group_pick_counts(1)
	assert_equal(group_picks["money"], 1, "group_pick_counts returns money:1 for player 1")
	assert_equal(group_picks["time"], 0, "group_pick_counts returns time:0")
	assert_equal(group_picks["awards"], 0, "group_pick_counts returns awards:0")

	assert_equal(engine.pick_count(1), 1, "pick_count returns 1 for player 1")
	assert_equal(engine.pick_count(2), 0, "pick_count returns 0 for player 2")

	# Test 2: tie round adds nothing
	var engine2 = GameEngine.new(_test_cards, 42)
	engine2.deal_hands()
	engine2.get_offered_categories()

	var tie_card_1 = _force_card_into_hand(engine2, 1, "card_m")  # oscar_won: 2
	var tie_card_2 = _force_card_into_hand(engine2, 2, "card_n")  # oscar_won: 2
	engine2.current_offered_categories = ["most_oscars", "first_published", "box_office"]

	result = engine2.submit_category_and_card(1, "most_oscars", tie_card_1.get("id"))
	assert_true(result["ok"], "player 1 submits tie card")

	result = engine2.submit_response_card(2, tie_card_2.get("id"))
	assert_true(result["ok"], "player 2 submits tie card")

	assert_equal(result["result"]["is_tie"], true, "result is a tie")
	assert_equal(engine2.round_history.size(), 0, "round_history is still empty after tie")

	# Test 3: timeout in awaiting_category adds nothing
	var engine3 = GameEngine.new(_test_cards, 42)
	engine3.deal_hands()
	engine3.get_offered_categories()

	result = engine3.resolve_timeout(engine3.active_player)
	assert_equal(engine3.round_history.size(), 0, "round_history empty after timeout in awaiting_category (no category used)")

	# Test 4: timeout in awaiting_response adds entry
	var engine4 = GameEngine.new(_test_cards, 7)
	engine4.deal_hands()
	engine4.get_offered_categories()
	engine4.current_offered_categories = ["most_oscars", "first_published", "box_office"]

	var active = engine4.active_player
	var active_card = engine4.hands[active][0].get("id")
	result = engine4.submit_category_and_card(active, "most_oscars", active_card)
	assert_true(result["ok"], "active player commits card for timeout test")

	var responder = 3 - active
	result = engine4.resolve_timeout(responder)

	assert_equal(engine4.round_history.size(), 1, "round_history has 1 entry after timeout in awaiting_response")
	assert_equal(engine4.round_history[0]["category"], "most_oscars", "timeout entry records the category")
	assert_equal(engine4.round_history[0]["chooser"], active, "timeout entry records active player as chooser")


func _find_card_by_id(hand: Array, card_id: String):
	for card in hand:
		if card.get("id") == card_id:
			return card
	return null


# Shuffle placement (which hand/reserve a card lands in) depends on the RNG
# seed, so round-resolution tests that need a SPECIFIC card in a SPECIFIC
# player's hand inject it directly rather than relying on where deal_hands()
# happened to put it. This only exercises resolve_round()/state logic, not
# dealing, which is already covered by test_deal_hands().
func _force_card_into_hand(engine: GameEngine, player_id: int, card_id: String) -> Dictionary:
	var existing = _find_card_by_id(engine.hands[player_id], card_id)
	if existing != null:
		return existing
	var card = _find_card_by_id(_test_cards, card_id)
	if card == null:
		return {}
	engine.hands[player_id].append(card)
	return card


func test_cube_rules() -> void:
	print("\n=== CubeRules Tests ===")
	var known := {}
	for i in range(1, 121):
		known["card_%03d" % i] = true

	# empty input -> legal "use everything"
	var empty := CubeRules.sanitize([], known)
	assert_true(bool(empty.ok) and (empty.ids as Array).is_empty(), "empty cube is ok, no ids")

	# below MIN_SIZE -> rejected
	var small_ids: Array = []
	for i in range(1, 50):
		small_ids.append("card_%03d" % i)
	var small := CubeRules.sanitize(small_ids, known)
	assert_true(not bool(small.ok) and str(small.error) == "cube_too_small", "sub-100 cube rejected")

	# exactly MIN_SIZE distinct valid -> ok
	var ok_ids: Array = []
	for i in range(1, CubeRules.MIN_SIZE + 1):
		ok_ids.append("card_%03d" % i)
	var okc := CubeRules.sanitize(ok_ids, known)
	assert_true(bool(okc.ok), "exactly MIN_SIZE cube accepted")
	assert_equal((okc.ids as Array).size(), CubeRules.MIN_SIZE, "sanitized id count == MIN_SIZE")

	# dedupe + drop unknowns, still counts distinct-valid against MIN_SIZE
	var messy: Array = ["card_001", "card_001", "not_a_card", ""]
	for i in range(2, CubeRules.MIN_SIZE + 1):
		messy.append("card_%03d" % i)
	messy.append("card_050")  # duplicate of one already added
	var cleaned := CubeRules.sanitize(messy, known)
	assert_true(bool(cleaned.ok), "messy cube with 100 distinct valid ids accepted")
	assert_equal((cleaned.ids as Array).size(), CubeRules.MIN_SIZE, "duplicates and unknowns removed")
	assert_true("not_a_card" not in (cleaned.ids as Array), "unknown id dropped")

	# dupes/unknowns that pull the distinct count under 100 -> rejected
	var thin: Array = ["not_a_card"]
	for i in range(1, CubeRules.MIN_SIZE):  # 99 distinct
		thin.append("card_%03d" % i)
		thin.append("card_%03d" % i)  # each twice
	var thinc := CubeRules.sanitize(thin, known)
	assert_true(not bool(thinc.ok), "99 distinct valid (with dupes/unknowns) still rejected")

	# filter_pool: [] -> everything; a list -> that subset in source order
	var all_cards := CardLoader.load_cards("res://data/cards.json")
	assert_equal(CubeRules.filter_pool(all_cards, []).size(), all_cards.size(), "filter_pool([]) is the full set")
	var subset := CubeRules.filter_pool(all_cards, ["card_003", "card_001", "nope"])
	assert_equal(subset.size(), 2, "filter_pool keeps only known ids")
	assert_equal(str(subset[0]["id"]), "card_001", "filter_pool preserves source order, not arg order")
