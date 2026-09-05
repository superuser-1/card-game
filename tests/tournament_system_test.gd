extends SceneTree


var _test_count = 0
var _fail_count = 0


func _initialize() -> void:
	test_next_power_of_2()
	test_resolve_bracket_size()
	test_generate_bracket_determinism()
	test_generate_bracket_real_and_bot_mix()
	test_generate_bracket_all_bots()
	test_advance_round_from_4_slots()
	test_advance_round_from_1_slot()
	test_is_bot_vs_bot()
	test_resolve_bot_vs_bot()
	test_round_fully_resolved()
	test_is_tournament_complete()

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


func test_next_power_of_2() -> void:
	print("\n=== next_power_of_2 Tests ===")
	assert_equal(TournamentSystem.next_power_of_2(1), 1, "next_power_of_2(1) == 1")
	assert_equal(TournamentSystem.next_power_of_2(2), 2, "next_power_of_2(2) == 2")
	assert_equal(TournamentSystem.next_power_of_2(5), 8, "next_power_of_2(5) == 8")
	assert_equal(TournamentSystem.next_power_of_2(32), 32, "next_power_of_2(32) == 32")
	assert_equal(TournamentSystem.next_power_of_2(33), 64, "next_power_of_2(33) == 64")


func test_resolve_bracket_size() -> void:
	print("\n=== resolve_bracket_size Tests ===")
	# 10 with allow_small=false -> 32 (floor is 32)
	var size1 = TournamentSystem.resolve_bracket_size(10, false)
	assert_equal(size1, 32, "resolve_bracket_size(10, false) == 32")

	# 10 with allow_small=true -> 16 (floor is 2, next_power_of_2(10) == 16)
	var size2 = TournamentSystem.resolve_bracket_size(10, true)
	assert_equal(size2, 16, "resolve_bracket_size(10, true) == 16")

	# 40 with allow_small=false -> 64
	var size3 = TournamentSystem.resolve_bracket_size(40, false)
	assert_equal(size3, 64, "resolve_bracket_size(40, false) == 64")

	# 40 with allow_small=true -> 64
	var size4 = TournamentSystem.resolve_bracket_size(40, true)
	assert_equal(size4, 64, "resolve_bracket_size(40, true) == 64")

	# 32 with allow_small=false -> 32
	var size5 = TournamentSystem.resolve_bracket_size(32, false)
	assert_equal(size5, 32, "resolve_bracket_size(32, false) == 32")


func test_generate_bracket_determinism() -> void:
	print("\n=== generate_bracket Determinism Tests ===")
	var participants = [
		{"account_id": 101, "checked_in": true},
		{"account_id": 102, "checked_in": true},
		{"account_id": 103, "checked_in": true},
		{"account_id": 104, "checked_in": true},
		{"account_id": 105, "checked_in": true},
	]
	var bracket_size = 8
	var rng_seed = 12345

	# Generate bracket twice with identical args
	var bracket1 = TournamentSystem.generate_bracket(participants, bracket_size, rng_seed)
	var bracket2 = TournamentSystem.generate_bracket(participants, bracket_size, rng_seed)

	# Compare via JSON stringification for deep equality (Dicts don't == deeply)
	var json1 = JSON.stringify(bracket1)
	var json2 = JSON.stringify(bracket2)
	assert_equal(json1, json2, "generate_bracket with identical args produces identical result")


func test_generate_bracket_real_and_bot_mix() -> void:
	print("\n=== generate_bracket Real+Bot Mix Tests ===")
	var participants = [
		{"account_id": 101, "checked_in": true},
		{"account_id": 102, "checked_in": true},
		{"account_id": 103, "checked_in": true},
		{"account_id": 104, "checked_in": true},
		{"account_id": 105, "checked_in": true},
	]
	var bracket_size = 8
	var rng_seed = 12345

	var bracket = TournamentSystem.generate_bracket(participants, bracket_size, rng_seed)

	# Should have exactly 4 slots (8 participant slots / 2 per matchup)
	assert_equal(bracket.size(), 4, "8-participant bracket has 4 slots")

	# Count all sides: should be 8 total (4 slots * 2 sides each)
	var all_sides = []
	for slot in bracket:
		all_sides.append({"account_id": slot.account_id_a, "is_bot": slot.is_bot_a})
		all_sides.append({"account_id": slot.account_id_b, "is_bot": slot.is_bot_b})

	# Count bot sides (is_bot_* == true, account_id == 0)
	var bot_count = 0
	for side in all_sides:
		if bool(side.is_bot) and int(side.account_id) == 0:
			bot_count += 1

	assert_equal(bot_count, 3, "Exactly 3 bot sides (5 real + 3 bots = 8)")

	# Count real sides: should be 5
	var real_count = 0
	for side in all_sides:
		if not bool(side.is_bot):
			real_count += 1

	assert_equal(real_count, 5, "Exactly 5 real player sides")

	# Verify all 5 real account_ids appear exactly once
	var real_ids = [101, 102, 103, 104, 105]
	for acc_id in real_ids:
		var found = 0
		for side in all_sides:
			if int(side.account_id) == acc_id:
				found += 1
		assert_equal(found, 1, "Account ID %d appears exactly once" % acc_id)


func test_generate_bracket_all_bots() -> void:
	print("\n=== generate_bracket All Bots Tests ===")
	# Empty participants or all checked_in = false
	var participants_empty = []
	var bracket_size = 4
	var rng_seed = 54321

	var bracket = TournamentSystem.generate_bracket(participants_empty, bracket_size, rng_seed)

	# Should have exactly 2 slots (4 participant slots / 2 per matchup)
	assert_equal(bracket.size(), 2, "4-participant bracket has 2 slots")

	# All 4 sides should be bots
	var is_bot_vs_bot_slot0 = TournamentSystem.is_bot_vs_bot(bracket[0])
	var is_bot_vs_bot_slot1 = TournamentSystem.is_bot_vs_bot(bracket[1])

	assert_equal(is_bot_vs_bot_slot0, true, "Slot 0 is bot vs bot")
	assert_equal(is_bot_vs_bot_slot1, true, "Slot 1 is bot vs bot")


func test_advance_round_from_4_slots() -> void:
	print("\n=== advance_round from 4 Slots Tests ===")
	# Manually build a 4-slot round with known winners
	var round0 = [
		{
			"slot_index": 0,
			"account_id_a": 101, "is_bot_a": false,
			"account_id_b": 0, "is_bot_b": true,
			"match_id": 1,
			"winner_account_id": 101, "winner_is_bot": false,
			"resolved": true,
			"score_a": 5, "score_b": 2,
		},
		{
			"slot_index": 1,
			"account_id_a": 102, "is_bot_a": false,
			"account_id_b": 0, "is_bot_b": true,
			"match_id": 2,
			"winner_account_id": 0, "winner_is_bot": true,
			"resolved": true,
			"score_a": 2, "score_b": 5,
		},
		{
			"slot_index": 2,
			"account_id_a": 103, "is_bot_a": false,
			"account_id_b": 104, "is_bot_b": false,
			"match_id": 3,
			"winner_account_id": 103, "winner_is_bot": false,
			"resolved": true,
			"score_a": 6, "score_b": 1,
		},
		{
			"slot_index": 3,
			"account_id_a": 105, "is_bot_a": false,
			"account_id_b": 0, "is_bot_b": true,
			"match_id": 4,
			"winner_account_id": 105, "winner_is_bot": false,
			"resolved": true,
			"score_a": 4, "score_b": 3,
		},
	]

	var round1 = TournamentSystem.advance_round(round0)

	# Should have 2 slots (4 input slots / 2 per output slot)
	assert_equal(round1.size(), 2, "advance_round from 4 slots produces 2 slots")

	# Slot 0 of round1 should have winners from round0[0] and round0[1]
	var slot1_0 = round1[0]
	assert_equal(slot1_0.account_id_a, 101, "Round 1 slot 0 side A is round 0 slot 0 winner (101)")
	assert_equal(slot1_0.is_bot_a, false, "Round 1 slot 0 side A is_bot_a is false")
	assert_equal(slot1_0.account_id_b, 0, "Round 1 slot 0 side B is round 0 slot 1 winner (bot, 0)")
	assert_equal(slot1_0.is_bot_b, true, "Round 1 slot 0 side B is_bot_b is true")

	# Slot 1 of round1 should have winners from round0[2] and round0[3]
	var slot1_1 = round1[1]
	assert_equal(slot1_1.account_id_a, 103, "Round 1 slot 1 side A is round 0 slot 2 winner (103)")
	assert_equal(slot1_1.is_bot_a, false, "Round 1 slot 1 side A is_bot_a is false")
	assert_equal(slot1_1.account_id_b, 105, "Round 1 slot 1 side B is round 0 slot 3 winner (105)")
	assert_equal(slot1_1.is_bot_b, false, "Round 1 slot 1 side B is_bot_b is false")


func test_advance_round_from_1_slot() -> void:
	print("\n=== advance_round from 1 Slot Tests ===")
	# A 1-slot round (the final)
	var final_round = [
		{
			"slot_index": 0,
			"account_id_a": 101, "is_bot_a": false,
			"account_id_b": 103, "is_bot_b": false,
			"match_id": 5,
			"winner_account_id": 101, "winner_is_bot": false,
			"resolved": true,
			"score_a": 7, "score_b": 0,
		},
	]

	var next_round = TournamentSystem.advance_round(final_round)

	# advance_round on a 1-slot round should return empty array
	assert_equal(next_round.size(), 0, "advance_round from 1 slot returns empty array")


func test_is_bot_vs_bot() -> void:
	print("\n=== is_bot_vs_bot Tests ===")
	# Both sides bot
	var bot_vs_bot = {
		"is_bot_a": true, "is_bot_b": true,
		"account_id_a": 0, "account_id_b": 0,
	}
	assert_equal(TournamentSystem.is_bot_vs_bot(bot_vs_bot), true, "is_bot_vs_bot returns true for both sides bot")

	# Only side A bot
	var bot_vs_real = {
		"is_bot_a": true, "is_bot_b": false,
		"account_id_a": 0, "account_id_b": 101,
	}
	assert_equal(TournamentSystem.is_bot_vs_bot(bot_vs_real), false, "is_bot_vs_bot returns false for only side A bot")

	# Only side B bot
	var real_vs_bot = {
		"is_bot_a": false, "is_bot_b": true,
		"account_id_a": 101, "account_id_b": 0,
	}
	assert_equal(TournamentSystem.is_bot_vs_bot(real_vs_bot), false, "is_bot_vs_bot returns false for only side B bot")

	# Both sides real
	var real_vs_real = {
		"is_bot_a": false, "is_bot_b": false,
		"account_id_a": 101, "account_id_b": 102,
	}
	assert_equal(TournamentSystem.is_bot_vs_bot(real_vs_real), false, "is_bot_vs_bot returns false for both sides real")


func test_resolve_bot_vs_bot() -> void:
	print("\n=== resolve_bot_vs_bot Tests ===")
	var slot = {
		"is_bot_a": true, "is_bot_b": true,
		"account_id_a": 0, "account_id_b": 0,
		"resolved": false,
		"winner_account_id": 0, "winner_is_bot": false,
	}

	var rng = RandomNumberGenerator.new()
	rng.seed = 99999

	TournamentSystem.resolve_bot_vs_bot(slot, rng)

	assert_equal(slot.resolved, true, "After resolve_bot_vs_bot, resolved is true")
	assert_equal(slot.winner_is_bot, true, "After resolve_bot_vs_bot, winner_is_bot is true")
	assert_equal(slot.winner_account_id, 0, "After resolve_bot_vs_bot, winner_account_id is 0")


func test_round_fully_resolved() -> void:
	print("\n=== round_fully_resolved Tests ===")
	# All slots resolved
	var round_resolved = [
		{"resolved": true},
		{"resolved": true},
		{"resolved": true},
	]
	assert_equal(TournamentSystem.round_fully_resolved(round_resolved), true, "All-resolved round returns true")

	# One slot unresolved
	var round_partial = [
		{"resolved": true},
		{"resolved": false},
		{"resolved": true},
	]
	assert_equal(TournamentSystem.round_fully_resolved(round_partial), false, "Partial-resolved round returns false")

	# Empty round
	var round_empty = []
	assert_equal(TournamentSystem.round_fully_resolved(round_empty), true, "Empty round returns true (vacuous truth)")


func test_is_tournament_complete() -> void:
	print("\n=== is_tournament_complete Tests ===")
	# Empty rounds array
	var rounds_empty = []
	assert_equal(TournamentSystem.is_tournament_complete(rounds_empty), false, "Empty rounds returns false")

	# Last round has 2 slots (even if both resolved) - not complete
	var rounds_2_final = [
		[{"resolved": true}, {"resolved": true}],
	]
	assert_equal(TournamentSystem.is_tournament_complete(rounds_2_final), false, "Last round with 2 slots returns false")

	# Last round has 1 slot but NOT resolved - not complete
	var rounds_1_unresolved = [
		[{"resolved": false}],
	]
	assert_equal(TournamentSystem.is_tournament_complete(rounds_1_unresolved), false, "Last round with 1 unresolved slot returns false")

	# Last round has 1 slot and IS resolved - complete!
	var rounds_1_resolved = [
		[{"resolved": true, "winner_account_id": 101, "winner_is_bot": false}],
	]
	assert_equal(TournamentSystem.is_tournament_complete(rounds_1_resolved), true, "Last round with 1 resolved slot returns true")

	# Multiple rounds, last has 1 resolved slot
	var rounds_multi = [
		[{"resolved": true}, {"resolved": true}],
		[{"resolved": true}],
	]
	assert_equal(TournamentSystem.is_tournament_complete(rounds_multi), true, "Multiple rounds with 1-slot resolved final returns true")
