extends SceneTree


var _test_count = 0
var _fail_count = 0


func _initialize() -> void:
	test_catalog_integrity()
	test_catalog_thresholds_increasing()
	test_catalog_three_tiers()
	test_catalog_rewards_valid()
	test_evaluate_single_tier()
	test_evaluate_two_tiers()
	test_evaluate_idempotent()
	test_rows_shape()

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


func test_catalog_integrity() -> void:
	print("\n=== Catalog Integrity ===")
	var ids := {}
	for ach in AchievementSystem.CATALOG:
		var id := str(ach.id)
		if ids.has(id):
			fail_test("duplicate id: %s" % id)
		else:
			ids[id] = true
	assert_equal(ids.size(), AchievementSystem.CATALOG.size(), "all achievement ids are unique")


func test_catalog_thresholds_increasing() -> void:
	print("\n=== Thresholds Strictly Increasing ===")
	for ach in AchievementSystem.CATALOG:
		var tiers: Array = ach.get("tiers", [])
		var last_threshold := 0
		for i in range(tiers.size()):
			var tier: Dictionary = tiers[i]
			var threshold := int(tier.get("threshold", 0))
			if threshold <= last_threshold:
				fail_test("achievement %s tier %d threshold (%d) not > previous (%d)" % [ach.id, i, threshold, last_threshold])
				return
			last_threshold = threshold
		pass_test("achievement %s thresholds strictly increasing" % ach.id)


func test_catalog_three_tiers() -> void:
	print("\n=== Three Tiers Per Achievement ===")
	for ach in AchievementSystem.CATALOG:
		var tiers: Array = ach.get("tiers", [])
		assert_equal(tiers.size(), 3, "achievement %s has exactly 3 tiers" % ach.id)


func test_catalog_rewards_valid() -> void:
	print("\n=== Catalog Rewards Valid ===")
	for ach in AchievementSystem.CATALOG:
		var tiers: Array = ach.get("tiers", [])
		for tier_idx in range(tiers.size()):
			var tier: Dictionary = tiers[tier_idx]
			var reward := str(tier.get("reward", ""))
			if reward != "":
				var def := ShopCatalog.def_for(reward)
				assert_true(not def.is_empty(), "achievement %s tier %d reward '%s' exists in ShopCatalog" % [ach.id, tier_idx, reward])
				if not def.is_empty():
					assert_equal(str(def.get("source")), "achievement", "reward %s has source='achievement'" % reward)


func test_evaluate_single_tier() -> void:
	print("\n=== Evaluate Single Tier ===")
	var stats := {"games": 10}
	var unlocked := {}
	var result := AchievementSystem.evaluate(stats, unlocked)

	assert_true(result["newly"].size() > 0, "games:10 unlocks at least one achievement tier")
	assert_true(int(result["points_awarded"]) > 0, "unlocking a tier awards points")
	assert_true(result["unlocked"].size() > 0, "unlocked dict is updated")


func test_evaluate_two_tiers() -> void:
	print("\n=== Evaluate Two Tiers in One Call ===")
	# Simulate a large stat jump that crosses two tiers
	var stats := {"wins": 1000}
	var unlocked := {}
	var result := AchievementSystem.evaluate(stats, unlocked)

	# At wins=1000, should cross all tiers of the winner achievement
	var winner_unlocks := []
	for newly in result["newly"]:
		if str(newly.get("id")) == "winner":
			winner_unlocks.append(newly)

	assert_true(winner_unlocks.size() >= 2, "wins:1000 should cross at least 2 tiers of winner achievement")
	if winner_unlocks.size() >= 2:
		pass_test("evaluate can cross multiple tiers in one call")


func test_evaluate_idempotent() -> void:
	print("\n=== Evaluate Idempotency ===")
	var stats := {"games": 10}
	var unlocked := {}

	var result1 := AchievementSystem.evaluate(stats, unlocked)
	var points1 := int(result1["points_awarded"])
	unlocked = result1["unlocked"]

	var result2 := AchievementSystem.evaluate(stats, unlocked)
	var points2 := int(result2["points_awarded"])

	assert_equal(points2, 0, "second evaluate with unchanged stats awards 0 points (idempotent)")
	assert_equal(result2["newly"].size(), 0, "second evaluate has no new unlocks (idempotent)")


func test_rows_shape() -> void:
	print("\n=== Rows Shape ===")
	var stats := {"games": 50, "wins": 50}
	var unlocked := {"veteran": 1}  # Silver tier
	var rows := AchievementSystem.rows(stats, unlocked)

	assert_true(rows.size() > 0, "rows returns non-empty array")
	for row in rows:
		assert_true(row.has("id"), "each row has 'id'")
		assert_true(row.has("name"), "each row has 'name'")
		assert_true(row.has("current_value"), "each row has 'current_value'")
		assert_true(row.has("tiers_done"), "each row has 'tiers_done'")
		assert_true(row.has("next_threshold"), "each row has 'next_threshold'")
		assert_true(row.has("maxed"), "each row has 'maxed'")
		pass_test("row %s has all required fields" % row.get("id"))
