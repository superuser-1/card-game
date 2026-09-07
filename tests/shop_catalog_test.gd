extends SceneTree


var _test_count = 0
var _fail_count = 0


func _initialize() -> void:
	test_catalog_unique_ids()
	test_catalog_types()
	test_catalog_prices()
	test_achievement_source_price_zero()
	test_def_for()
	test_is_premium()
	test_is_buyable()
	test_ids_of_type()
	test_buyable_ids_of_type()

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


func test_catalog_unique_ids() -> void:
	print("\n=== Catalog Unique IDs ===")
	var ids := {}
	for item in ShopCatalog.CATALOG:
		var id := str(item.id)
		if ids.has(id):
			fail_test("duplicate id: %s" % id)
		else:
			ids[id] = true
	assert_equal(ids.size(), ShopCatalog.CATALOG.size(), "all catalog ids are unique")


func test_catalog_types() -> void:
	print("\n=== Catalog Types ===")
	for item in ShopCatalog.CATALOG:
		var t := str(item.type)
		assert_true(t in ShopCatalog.TYPES, "item %s has valid type '%s'" % [item.id, t])


func test_catalog_prices() -> void:
	print("\n=== Catalog Prices ===")
	for item in ShopCatalog.CATALOG:
		var price := int(item.get("price", 0))
		assert_true(price >= 0, "item %s has non-negative price %d" % [item.id, price])


func test_achievement_source_price_zero() -> void:
	print("\n=== Achievement Source Price Zero ===")
	for item in ShopCatalog.CATALOG:
		if str(item.source) == "achievement":
			var price := int(item.get("price", 0))
			assert_equal(price, 0, "achievement-source item %s has price 0" % item.id)


func test_def_for() -> void:
	print("\n=== def_for ===")
	var def := ShopCatalog.def_for("aphrodite")
	assert_true(not def.is_empty(), "def_for finds aphrodite")
	assert_equal(str(def.get("name")), "Aphrodite", "def_for returns correct name")

	var missing := ShopCatalog.def_for("nonexistent_id")
	assert_true(missing.is_empty(), "def_for returns {} for unknown id")


func test_is_premium() -> void:
	print("\n=== is_premium ===")
	assert_true(ShopCatalog.is_premium("aphrodite"), "aphrodite is premium")
	assert_true(ShopCatalog.is_premium("frame_champion"), "frame_champion (achievement) is premium")
	assert_true(not ShopCatalog.is_premium("nonexistent_id"), "nonexistent_id is not premium")
	assert_true(not ShopCatalog.is_premium(""), "empty id is not premium")


func test_is_buyable() -> void:
	print("\n=== is_buyable ===")
	assert_true(ShopCatalog.is_buyable("aphrodite"), "aphrodite is buyable")
	assert_true(not ShopCatalog.is_buyable("frame_champion"), "frame_champion (achievement source) is not buyable")
	assert_true(not ShopCatalog.is_buyable("nonexistent_id"), "nonexistent_id is not buyable")


func test_ids_of_type() -> void:
	print("\n=== ids_of_type ===")
	var avatars := ShopCatalog.ids_of_type("avatar")
	assert_true(avatars.size() > 0, "avatar type has at least one item")
	assert_true("aphrodite" in avatars, "aphrodite in avatar type")

	var frames := ShopCatalog.ids_of_type("frame")
	assert_true(frames.size() > 0, "frame type has at least one item")
	assert_true("frame_neon" in frames, "frame_neon in frame type")

	var unknown := ShopCatalog.ids_of_type("unknown_type")
	assert_equal(unknown.size(), 0, "unknown type returns empty array")


func test_buyable_ids_of_type() -> void:
	print("\n=== buyable_ids_of_type ===")
	var avatars := ShopCatalog.buyable_ids_of_type("avatar")
	assert_true("aphrodite" in avatars, "buyable avatars include aphrodite")
	assert_true(not ("avatar_champion" in avatars), "buyable avatars exclude achievement reward avatar_champion")
	assert_true(not ("30_ranked_losses_avatar" in avatars), "buyable avatars exclude ranked-loss reward avatars")

	var frames := ShopCatalog.buyable_ids_of_type("frame")
	assert_true("frame_neon" in frames, "buyable frames include frame_neon")
	assert_true(not ("frame_champion" in frames), "buyable frames exclude achievement reward frame_champion")

	# Every id returned must itself be buyable.
	for t in ShopCatalog.TYPES:
		for id in ShopCatalog.buyable_ids_of_type(t):
			assert_true(ShopCatalog.is_buyable(id), "%s is buyable" % id)
