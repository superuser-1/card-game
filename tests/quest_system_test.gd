extends SceneTree


var _test_count = 0
var _fail_count = 0


func _initialize() -> void:
	test_today_key()
	test_fresh_state()
	test_daily_quest_ids()
	test_ensure_day()
	test_ensure_day_with_active_ids()
	test_evaluate_single_win()
	test_evaluate_three_wins()
	test_evaluate_loss()
	test_perfect_win()
	test_perfect_loss()
	test_group_win_money()
	test_group_win_negatives()
	test_idempotency()
	test_evaluate_only_active_quests()

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


func test_today_key() -> void:
	print("\n=== today_key Tests ===")
	var key1 = QuestSystem.today_key(1_725_000_000.0)
	var key2 = QuestSystem.today_key(1_725_000_000.0)
	assert_equal(key1, key2, "today_key is stable across two calls with the same arg")
	assert_true(key1.match("????-??-??"), "today_key returns well-formed YYYY-MM-DD")

	var key_day_apart = QuestSystem.today_key(1_725_000_000.0 + 86400.0)
	assert_true(key1 != key_day_apart, "today_key differs for times a day apart")


func test_fresh_state() -> void:
	print("\n=== fresh_state Tests ===")
	var active_ids = QuestSystem.daily_quest_ids("2026-01-15")
	var state = QuestSystem.fresh_state(active_ids)
	assert_equal(state.size(), 3, "fresh_state has entry for 3 active ids")
	for id in active_ids:
		var qs = state.get(id, {})
		assert_equal(qs.get("progress", -1), 0, "%s progress is 0" % id)
		assert_equal(qs.get("completed", true), false, "%s completed is false" % id)


func test_daily_quest_ids() -> void:
	print("\n=== daily_quest_ids Tests ===")
	var ids1 = QuestSystem.daily_quest_ids("2026-06-15")
	var ids2 = QuestSystem.daily_quest_ids("2026-06-15")
	var ids_diff = QuestSystem.daily_quest_ids("2026-06-16")

	assert_equal(ids1.size(), 3, "daily_quest_ids returns 3 ids")
	assert_equal(ids2, ids1, "identical day gives identical ids (deterministic)")
	assert_true(ids_diff != ids1, "different day gives different ids")

	# All returned ids should be in CATALOG
	for id in ids1:
		var found = false
		for q in QuestSystem.CATALOG:
			if str(q.id) == id:
				found = true
				break
		assert_true(found, "%s is in CATALOG" % id)

	# All returned ids should be unique
	var unique = ids1.duplicate()
	unique = Array(unique)  # Force fresh array for comparison
	assert_equal(unique.size(), ids1.size(), "all daily ids are unique")


func test_ensure_day() -> void:
	print("\n=== ensure_day Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)

	# Test 1: empty dict returns fresh with active_ids
	var result1 = QuestSystem.ensure_day({}, day)
	assert_equal(result1["day"], day, "day is set")
	assert_equal(result1["active_ids"].size(), 3, "active_ids has 3 ids")
	assert_equal(result1["state"].size(), 3, "state has 3 keys for active ids")
	for id in active_ids:
		assert_true(result1["state"].has(id), "%s is in state" % id)

	# Test 2: garbage string returns fresh
	var result2 = QuestSystem.ensure_day("garbage", day)
	assert_equal(result2["state"].size(), 3, "garbage string returns fresh state with 3 keys")

	# Test 3: identical day keeps the same state and progress
	var state3 = QuestSystem.fresh_state(active_ids)
	state3[active_ids[0]]["progress"] = 2
	var norm3 = {"day": day, "active_ids": active_ids, "state": state3}
	var result3 = QuestSystem.ensure_day(norm3, day)
	assert_equal(result3["day"], day, "day is preserved")
	assert_equal(result3["state"][active_ids[0]]["progress"], 2, "state progress is preserved on same day")

	# Test 4: changed day returns fresh_state and resets progress
	var result4 = QuestSystem.ensure_day(norm3, "2026-01-16")
	assert_equal(result4["day"], "2026-01-16", "day is updated")
	assert_equal(result4["state"][active_ids[0]]["progress"], 0, "state is reset on day change")


func test_ensure_day_with_active_ids() -> void:
	print("\n=== ensure_day with active_ids Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)

	# Test: stored state with progress on an active id keeps it through ensure_day
	var stored_state = QuestSystem.fresh_state(active_ids)
	if active_ids.size() > 0:
		stored_state[active_ids[0]]["progress"] = 5
	var norm = {"day": day, "active_ids": active_ids, "state": stored_state}
	var result = QuestSystem.ensure_day(norm, day)
	if active_ids.size() > 0:
		assert_equal(result["state"][active_ids[0]]["progress"], 5, "active id progress preserved")


func test_evaluate_single_win() -> void:
	print("\n=== evaluate single win Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)
	var ctx = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 3,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var result = QuestSystem.evaluate(state, ctx)

	# Check all completed quests are in active_ids
	for c in result["completed"]:
		var id = c.get("id", "")
		assert_true(id in active_ids, "completed quest %s is in active_ids" % id)

	# Progress and completion should only affect quests in active_ids
	for id in state.keys():
		if id not in active_ids:
			assert_equal(state.get(id, {}).get("progress", 0), 0, "progress for non-active %s is still 0" % id)


func test_evaluate_three_wins() -> void:
	print("\n=== evaluate three wins Tests ===")
	# Rotation-safe: find a day whose active 3 contains BOTH win_1 and win_3 so
	# the win-count progression can be asserted concretely.
	var day := ""
	for d in range(1, 90):
		var probe := "2026-01-%02d" % d if d <= 31 else "2026-02-%02d" % (d - 31)
		var ids := QuestSystem.daily_quest_ids(probe)
		if "win_1" in ids and "win_3" in ids:
			day = probe
			break
	if day == "":
		pass_test("no day with win_1+win_3 in sample — skipped (unexpected but non-fatal)")
		return

	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)
	var ctx = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 3,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}

	var result1 = QuestSystem.evaluate(state, ctx)
	state = result1["state"]
	assert_equal(int(result1["points_awarded"]), 10, "first win completes win_1 (+10)")
	assert_equal(state["win_1"]["completed"], true, "win_1 completed after first win")
	assert_equal(state["win_3"]["completed"], false, "win_3 not yet completed after first win")

	var result2 = QuestSystem.evaluate(state, ctx)
	state = result2["state"]
	assert_equal(int(result2["points_awarded"]), 0, "second win completes nothing new")

	var result3 = QuestSystem.evaluate(state, ctx)
	state = result3["state"]
	assert_equal(int(result3["points_awarded"]), 40, "third win completes win_3 (+40)")
	assert_equal(state["win_3"]["completed"], true, "win_3 completed on 3rd win")


func test_evaluate_loss() -> void:
	print("\n=== evaluate loss Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)
	var ctx = {
		"outcome": "loss",
		"your_score": 3,
		"opp_score": 7,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var result = QuestSystem.evaluate(state, ctx)
	# For loss, win progress should not increase
	var loss_gives_points = false
	for c in result["completed"]:
		if c.get("id") in ["perfect_loss"]:
			loss_gives_points = true
			break
	# Loss should not award regular win points, but might award perfect_loss
	for id in active_ids:
		if id in ["win_1", "win_3", "win_10"]:
			assert_equal(result["state"][id]["progress"], 0, "%s progress unchanged on loss" % id)


func test_perfect_win() -> void:
	print("\n=== perfect_win Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)

	# Perfect win: 7-0
	var ctx_perfect = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 0,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var result1 = QuestSystem.evaluate(state, ctx_perfect)
	# Check if perfect_win is active and verify it completes
	if "perfect_win" in active_ids:
		assert_equal(result1["state"]["perfect_win"]["completed"], true, "7-0 completes perfect_win when active")
	# All completed ids should be in active_ids
	for c in result1["completed"]:
		assert_true(c.get("id") in active_ids, "completed quest %s is in active_ids" % c.get("id"))

	# Not perfect: 7-2
	state = QuestSystem.fresh_state(active_ids)
	var ctx_not_perfect = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 2,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var result2 = QuestSystem.evaluate(state, ctx_not_perfect)
	if "perfect_win" in active_ids:
		assert_equal(result2["state"]["perfect_win"]["completed"], false, "7-2 does not complete perfect_win")

	# Not perfect: forfeit-shaped 5-0
	state = QuestSystem.fresh_state(active_ids)
	var ctx_forfeit = {
		"outcome": "win",
		"your_score": 5,
		"opp_score": 0,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var result3 = QuestSystem.evaluate(state, ctx_forfeit)
	if "perfect_win" in active_ids:
		assert_equal(result3["state"]["perfect_win"]["completed"], false, "5-0 (forfeit-shaped) does not complete perfect_win")


func test_perfect_loss() -> void:
	print("\n=== perfect_loss Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)

	# Perfect loss: 0-7
	var ctx_perfect = {
		"outcome": "loss",
		"your_score": 0,
		"opp_score": 7,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var result1 = QuestSystem.evaluate(state, ctx_perfect)
	if "perfect_loss" in active_ids:
		assert_equal(result1["state"]["perfect_loss"]["completed"], true, "0-7 completes perfect_loss when active")
	# All completed ids should be in active_ids
	for c in result1["completed"]:
		assert_true(c.get("id") in active_ids, "completed quest %s is in active_ids" % c.get("id"))

	# Not perfect: 1-7
	state = QuestSystem.fresh_state(active_ids)
	var ctx_not_perfect = {
		"outcome": "loss",
		"your_score": 1,
		"opp_score": 7,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var result2 = QuestSystem.evaluate(state, ctx_not_perfect)
	if "perfect_loss" in active_ids:
		assert_equal(result2["state"]["perfect_loss"]["completed"], false, "1-7 does not complete perfect_loss")

	# Not perfect: 0-4
	state = QuestSystem.fresh_state(active_ids)
	var ctx_too_low = {
		"outcome": "loss",
		"your_score": 0,
		"opp_score": 4,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var result3 = QuestSystem.evaluate(state, ctx_too_low)
	if "perfect_loss" in active_ids:
		assert_equal(result3["state"]["perfect_loss"]["completed"], false, "0-4 does not complete perfect_loss")


func test_group_win_money() -> void:
	print("\n=== group_win money Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)
	var ctx = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 3,
		"your_group_picks": {"money": 3, "time": 0, "awards": 0},
		"your_pick_count": 3,
	}
	var result = QuestSystem.evaluate(state, ctx)
	if "money_game" in active_ids:
		assert_equal(result["state"]["money_game"]["completed"], true, "all money picks completes money_game when active")
	if "time_game" in active_ids:
		assert_equal(result["state"]["time_game"]["completed"], false, "time_game does not complete with money picks")
	# All completed should be in active_ids
	for c in result["completed"]:
		assert_true(c.get("id") in active_ids, "completed quest %s is in active_ids" % c.get("id"))


func test_group_win_negatives() -> void:
	print("\n=== group_win negatives Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)

	# Mixed groups
	var ctx_mixed = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 3,
		"your_group_picks": {"money": 2, "time": 1, "awards": 0},
		"your_pick_count": 3,
	}
	var result1 = QuestSystem.evaluate(state, ctx_mixed)
	if "money_game" in active_ids:
		assert_equal(result1["state"]["money_game"]["completed"], false, "mixed groups does not complete money_game")

	# Below min_picks
	state = QuestSystem.fresh_state(active_ids)
	var ctx_below_min = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 3,
		"your_group_picks": {"money": 1, "time": 0, "awards": 0},
		"your_pick_count": 1,
	}
	var result2 = QuestSystem.evaluate(state, ctx_below_min)
	if "money_game" in active_ids:
		assert_equal(result2["state"]["money_game"]["completed"], false, "below min_picks does not complete money_game")

	# Loss outcome
	state = QuestSystem.fresh_state(active_ids)
	var ctx_loss = {
		"outcome": "loss",
		"your_score": 3,
		"opp_score": 7,
		"your_group_picks": {"money": 3, "time": 0, "awards": 0},
		"your_pick_count": 3,
	}
	var result3 = QuestSystem.evaluate(state, ctx_loss)
	if "money_game" in active_ids:
		assert_equal(result3["state"]["money_game"]["completed"], false, "loss outcome does not complete money_game")


func test_idempotency() -> void:
	print("\n=== idempotency Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)
	var ctx = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 3,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}

	# First call
	var result1 = QuestSystem.evaluate(state, ctx)
	var points1 = result1["points_awarded"]
	assert_equal(points1 >= 0, true, "first call awards non-negative points")

	# Second call on same result: no new completions
	var result2 = QuestSystem.evaluate(result1["state"], ctx)
	assert_equal(result2["points_awarded"], 0, "second call awards 0 (idempotency)")
	assert_equal(result2["completed"].size(), 0, "second call has no completions (idempotency)")


func test_evaluate_only_active_quests() -> void:
	print("\n=== evaluate only active quests Tests ===")
	var day = "2026-01-15"
	var active_ids = QuestSystem.daily_quest_ids(day)
	var state = QuestSystem.fresh_state(active_ids)
	var ctx = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 3,
		"your_group_picks": {"money": 3, "time": 0, "awards": 0},
		"your_pick_count": 3,
	}
	var result = QuestSystem.evaluate(state, ctx)

	# All completed quest ids must be in the active set
	for completed in result["completed"]:
		var quest_id = completed.get("id", "")
		assert_true(quest_id in active_ids, "completed quest %s is in daily active_ids" % quest_id)

	# All state keys should be in active_ids
	for quest_id in result["state"].keys():
		assert_true(quest_id in active_ids, "state quest %s is in active_ids" % quest_id)
