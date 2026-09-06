extends SceneTree


var _test_count = 0
var _fail_count = 0


func _initialize() -> void:
	test_catalog_integrity()
	test_catalog_thresholds_increasing()
	test_catalog_tier_counts()
	test_catalog_rewards_valid()
	test_evaluate_single_tier()
	test_evaluate_two_tiers()
	test_evaluate_idempotent()
	test_rows_shape()
	test_milestone_achievements()
	test_catalog_art_present()

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


func test_catalog_tier_counts() -> void:
	print("\n=== Tier Counts Per Achievement ===")
	# Tiered achievements have 3 tiers (Bronze/Silver/Gold); single-tier
	# "milestone" achievements (the user's ranked-win/loss/etc ladders) have 1.
	for ach in AchievementSystem.CATALOG:
		var tiers: Array = ach.get("tiers", [])
		assert_true(tiers.size() == 1 or tiers.size() == 3,
			"achievement %s has 1 or 3 tiers (got %d)" % [ach.id, tiers.size()])


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
	# Simulate a large stat jump that crosses every tier of a 3-tier achievement.
	var stats := {"games": 1000}
	var unlocked := {}
	var result := AchievementSystem.evaluate(stats, unlocked)

	var veteran_unlocks := []
	for newly in result["newly"]:
		if str(newly.get("id")) == "veteran":
			veteran_unlocks.append(newly)

	assert_true(veteran_unlocks.size() >= 2, "games:1000 should cross at least 2 tiers of veteran achievement")
	if veteran_unlocks.size() >= 2:
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
		assert_true(row.has("tier_total"), "each row has 'tier_total'")
		assert_true(row.has("next_threshold"), "each row has 'next_threshold'")
		assert_true(row.has("maxed"), "each row has 'maxed'")
		pass_test("row %s has all required fields" % row.get("id"))


func test_milestone_achievements() -> void:
	print("\n=== Milestone Achievements (user set) ===")

	# A single ranked win unlocks exactly the first rung, no tier name.
	var r1 := AchievementSystem.evaluate({"wins": 1}, {})
	var ids1 := []
	for n in r1["newly"]:
		ids1.append(str(n.get("id")))
	assert_true("ranked_win_1" in ids1, "wins:1 unlocks ranked_win_1")
	assert_true("ranked_win_5" not in ids1, "wins:1 does NOT unlock ranked_win_5")
	for n in r1["newly"]:
		if str(n.get("id")) == "ranked_win_1":
			assert_equal(str(n.get("tier_name")), "", "milestone unlock has empty tier_name")

	# wins:50 crosses the first five rungs in one call.
	var r50 := AchievementSystem.evaluate({"wins": 50}, {})
	var win_ids := []
	for n in r50["newly"]:
		if str(n.get("id")).begins_with("ranked_win_"):
			win_ids.append(str(n.get("id")))
	assert_equal(win_ids.size(), 5, "wins:50 unlocks ranked_win_1/5/10/30/50 (5 rungs)")

	# Losses have their own independent ladder.
	var rl := AchievementSystem.evaluate({"losses": 5}, {})
	var loss_ids := []
	for n in rl["newly"]:
		if str(n.get("id")).begins_with("ranked_loss_"):
			loss_ids.append(str(n.get("id")))
	assert_equal(loss_ids.size(), 2, "losses:5 unlocks ranked_loss_1 + ranked_loss_5")

	# Tournament / quest / creation ladders exist and fire off their stats.
	var rt := AchievementSystem.evaluate(
		{"tournaments_won": 1, "quests_completed": 5, "tournaments_created": 5}, {})
	var mid := {}
	for n in rt["newly"]:
		mid[str(n.get("id"))] = true
	assert_true(mid.has("tourney_win_1"), "tournaments_won:1 unlocks tourney_win_1")
	assert_true(mid.has("quests_completed_5"), "quests_completed:5 unlocks quests_completed_5")
	assert_true(mid.has("tourney_created_5"), "tournaments_created:5 unlocks tourney_created_5")

	# The ranked-loss ladder grants avatar rewards; evaluate must surface the
	# reward id so grant_reward can drop it into owned_rewards.
	var rr := AchievementSystem.evaluate({"losses": 30}, {})
	var loss30: Dictionary = {}
	for n in rr["newly"]:
		if str(n.get("id")) == "ranked_loss_30":
			loss30 = n
	assert_equal(str(loss30.get("reward", "")), "30_ranked_losses_avatar",
		"ranked_loss_30 unlock carries its avatar reward id")
	assert_true("30_ranked_losses_avatar" in rr["reward_ids"], "reward id is in reward_ids")
	assert_equal(str(ShopCatalog.def_for("30_ranked_losses_avatar").get("type", "")), "avatar",
		"the reward is an avatar-type cosmetic")


## Non-fatal: every catalog id should have art at
## res://assets/achievements/<id>.png. Missing art just renders a blank tile,
## so this reports gaps without failing the build.
func test_catalog_art_present() -> void:
	print("\n=== Catalog Art Coverage ===")
	var missing := []
	for ach in AchievementSystem.CATALOG:
		var p := "res://assets/achievements/%s.png" % str(ach.id)
		if not ResourceLoader.exists(p):
			missing.append(str(ach.id))
	if missing.is_empty():
		pass_test("every catalog id has an art file")
	else:
		print("WARNING: %d achievement(s) missing art: %s" % [missing.size(), ", ".join(missing)])
		pass_test("art coverage checked (%d missing, non-fatal)" % missing.size())
