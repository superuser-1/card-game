extends SceneTree


var _test_count = 0
var _fail_count = 0

# Fake price table: two buyable items, everything else "not buyable" (-1).
var _prices := {"athena": 5, "frame_neon": 5}
var _price_of := func(id): return int(_prices.get(id, -1))


func _initialize() -> void:
	test_sanitize_empty()
	test_sanitize_full_cost()
	test_sanitize_drops_empty_bucket()
	test_sanitize_prize_gap()
	test_sanitize_bad_bucket()
	test_sanitize_bad_item()
	test_sanitize_too_many_items()
	test_sanitize_dedupes_items()
	test_cost_of()
	test_bucket_for_placement()

	if _fail_count == 0:
		print("ALL TESTS PASSED")
		quit(0)
	else:
		print("TESTS FAILED: %d" % _fail_count)
		quit(1)


func ok(c: bool, m: String) -> void:
	_test_count += 1
	if c:
		print("PASS: %s" % m)
	else:
		_fail_count += 1
		print("FAIL: %s" % m)


func eq(a, b, m: String) -> void:
	ok(a == b, "%s (expected %s, got %s)" % [m, str(b), str(a)])


func test_sanitize_empty() -> void:
	print("\n=== sanitize: empty ===")
	var r = TournamentPrizes.sanitize({}, _price_of)
	ok(r.ok and r.prizes.is_empty() and r.cost == 0, "empty spec -> ok, no prizes, cost 0")
	var r2 = TournamentPrizes.sanitize({"1": {"points": 0, "items": []}}, _price_of)
	ok(r2.ok and r2.prizes.is_empty(), "all-empty bucket dropped")


func test_sanitize_full_cost() -> void:
	print("\n=== sanitize: full 5-bucket cost ===")
	# 1: 500 pts                 slots 1 -> 500
	# 2: 200 pts                 slots 1 -> 200
	# 3: 100 pts + athena(5)     slots 2 -> 2*105 = 210
	# 4_8: 50 pts                slots 4 -> 200
	# 9_16: athena(5)+neon(5)    slots 8 -> 8*10 = 80
	var spec := {
		"1": {"points": 500, "items": []},
		"2": {"points": 200, "items": []},
		"3": {"points": 100, "items": ["athena"]},
		"4_8": {"points": 50, "items": []},
		"9_16": {"points": 0, "items": ["athena", "frame_neon"]},
	}
	var r = TournamentPrizes.sanitize(spec, _price_of)
	ok(r.ok, "full spec is legal")
	eq(r.cost, 500 + 200 + 210 + 200 + 80, "cost = per-slot sum")
	eq(r.prizes.size(), 5, "all five buckets kept")
	eq(r.prizes["9_16"].points, 0, "points coerced/kept at 0")


func test_sanitize_drops_empty_bucket() -> void:
	print("\n=== sanitize: negative points clamp ===")
	var r = TournamentPrizes.sanitize({"1": {"points": -99, "items": ["athena"]}}, _price_of)
	eq(r.prizes["1"].points, 0, "negative points clamped to 0")
	eq(r.cost, 5, "cost is just the item price")


func test_sanitize_prize_gap() -> void:
	print("\n=== sanitize: prize_gap ===")
	var r = TournamentPrizes.sanitize({"1": {"points": 100, "items": []}, "3": {"points": 50, "items": []}}, _price_of)
	eq(r.error, "prize_gap", "bucket 3 set with bucket 2 empty -> prize_gap")
	var r2 = TournamentPrizes.sanitize({"1": {"points": 100, "items": []}, "2": {"points": 50, "items": []}}, _price_of)
	ok(r2.ok, "contiguous 1+2 is fine")


func test_sanitize_bad_bucket() -> void:
	print("\n=== sanitize: prize_bad_bucket ===")
	var r = TournamentPrizes.sanitize({"first": {"points": 10, "items": []}}, _price_of)
	eq(r.error, "prize_bad_bucket", "unknown bucket key rejected")


func test_sanitize_bad_item() -> void:
	print("\n=== sanitize: prize_bad_item ===")
	var r = TournamentPrizes.sanitize({"1": {"points": 0, "items": ["frame_champion"]}}, _price_of)
	eq(r.error, "prize_bad_item", "non-buyable item rejected")
	var r2 = TournamentPrizes.sanitize({"1": {"points": 0, "items": ["nope"]}}, _price_of)
	eq(r2.error, "prize_bad_item", "unknown item rejected")


func test_sanitize_too_many_items() -> void:
	print("\n=== sanitize: prize_too_many_items ===")
	var tbl := {"a": 5, "b": 5, "c": 5, "d": 5}
	var _pf := func(id): return int(tbl.get(id, -1))
	var r = TournamentPrizes.sanitize({"1": {"points": 0, "items": ["a", "b", "c", "d"]}}, _pf)
	eq(r.error, "prize_too_many_items", "more than MAX_ITEMS_PER_BUCKET rejected")
	var r2 = TournamentPrizes.sanitize({"1": {"points": 0, "items": ["a", "b", "c"]}}, _pf)
	ok(r2.ok, "exactly MAX_ITEMS_PER_BUCKET is fine")
	# dupes don't count toward the cap
	var r3 = TournamentPrizes.sanitize({"1": {"points": 0, "items": ["a", "a", "b", "b", "c", "c"]}}, _pf)
	ok(r3.ok and (r3.prizes["1"].items as Array).size() == 3, "duplicates collapse under the cap")


func test_sanitize_dedupes_items() -> void:
	print("\n=== sanitize: dedupe items ===")
	var r = TournamentPrizes.sanitize({"1": {"points": 0, "items": ["athena", "athena", ""]}}, _price_of)
	ok(r.ok, "dupes/blank are cleaned, not rejected")
	eq((r.prizes["1"].items as Array).size(), 1, "athena kept once")
	eq(r.cost, 5, "charged once")


func test_cost_of() -> void:
	print("\n=== cost_of ===")
	var prizes := {"1": {"points": 100, "items": ["athena"]}, "2": {"points": 50, "items": []}}
	eq(TournamentPrizes.cost_of(prizes, _price_of), 105 + 50, "cost_of matches sanitize math")


func test_bucket_for_placement() -> void:
	print("\n=== bucket_for_placement ===")
	# A 32-player bracket has 5 rounds.
	eq(TournamentPrizes.bucket_for_placement(0, 5), "1", "champion -> 1")
	eq(TournamentPrizes.bucket_for_placement(5, 5), "2", "lost the final -> 2")
	eq(TournamentPrizes.bucket_for_placement(4, 5), "3", "lost the semis -> 3")
	eq(TournamentPrizes.bucket_for_placement(3, 5), "4_8", "lost the quarters -> 4_8")
	eq(TournamentPrizes.bucket_for_placement(2, 5), "9_16", "lost the round of 16 -> 9_16")
	eq(TournamentPrizes.bucket_for_placement(1, 5), "", "lost the round of 32 -> no bucket")
	eq(TournamentPrizes.bucket_for_placement(0, 0), "", "no rounds -> no bucket")
	# A tiny 3-round bracket: champion, final loser, semis losers, nothing beyond.
	eq(TournamentPrizes.bucket_for_placement(3, 3), "2", "3-round: final loser -> 2")
	eq(TournamentPrizes.bucket_for_placement(2, 3), "3", "3-round: semi loser -> 3")
	eq(TournamentPrizes.bucket_for_placement(1, 3), "4_8", "3-round: round-1 loser -> 4_8")
