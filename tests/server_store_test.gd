extends SceneTree


var _test_count = 0
var _fail_count = 0
var _dir: String
var _fresh_seq = 0


func _initialize() -> void:
	# Create unique temp directory for this test run
	_dir = "user://flickbattle_test_%d/" % Time.get_ticks_usec()

	# Run all tests
	test_create_account_validation()
	test_create_account_success()
	test_create_account_duplicate()
	test_verify_login()
	test_hash_password_deterministic()
	test_verify_password()
	test_expected_score()
	test_k_factor()
	test_apply_result_win()
	test_apply_result_draw()
	test_points_delta()
	test_record_match_normal()
	test_record_match_bot()
	test_rank_and_ladder()
	test_recent_matches()
	test_quest_progress_and_daily_reset()

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


func assert_almost_equal(actual: float, expected: float, tolerance: float, message: String) -> void:
	if abs(actual - expected) < tolerance:
		pass_test(message)
	else:
		fail_test("%s (expected ~%f, got %f, diff=%f)" % [message, expected, actual, abs(actual - expected)])


func fresh() -> ServerStore:
	## Fresh ServerStore in its own isolated sub-directory so tests never
	## see each other's accounts/matches.
	_fresh_seq += 1
	var s = ServerStore.new()
	s.open("%s%d/" % [_dir, _fresh_seq])
	return s


func test_create_account_validation() -> void:
	print("\n=== Account Creation Validation ===")
	var s = fresh()

	# DEV: min username/password length is currently 1 (see ServerStore consts).
	var result = s.create_account("a", "b")
	assert_equal(result.ok, true, "Accept length-1 username and password (dev config)")

	# Username with a space is still rejected (charset rule).
	result = s.create_account("hi mom", "password123")
	assert_equal(result.ok, false, "Reject username with space")
	assert_equal(result.error, "bad_username", "Error is 'bad_username' for space")

	# Over-long username still rejected.
	result = s.create_account("a234567890123456789012", "password123")
	assert_equal(result.ok, false, "Reject username longer than 20")
	assert_equal(result.error, "bad_username", "Error is 'bad_username' for over-long name")

	# Empty password still rejected.
	result = s.create_account("Bob", "")
	assert_equal(result.ok, false, "Reject empty password")
	assert_equal(result.error, "bad_password", "Error is 'bad_password' for empty")


func test_create_account_success() -> void:
	print("\n=== Account Creation Success ===")
	var s = fresh()

	var result = s.create_account("Alice", "secret1")
	assert_equal(result.ok, true, "Account creation succeeds for Alice")
	assert_equal(result.account.get("username"), "Alice", "Username is 'Alice'")
	assert_equal(result.account.get("elo"), 1000, "New account elo is START_ELO (1000)")
	assert_equal(result.account.get("games"), 0, "New account games is 0")
	assert_equal(result.account.get("owned_rewards"), ["sleeve_classic"], "New account owns sleeve_classic")
	assert_equal(result.account.get("avatar"), "", "New account has no avatar until the onboarding picker sets one")

	var withav = s.create_account("Zed", "secret1", "avatar_male_01")
	assert_equal(withav.account.get("avatar"), "avatar_male_01", "avatar arg is stored")
	assert_equal(s.account_snapshot(withav.account).get("avatar"), "avatar_male_01", "snapshot carries avatar")

	var set_res = s.set_avatar(int(result.account.get("id")), "avatar_female_03")
	assert_equal(set_res.ok, true, "set_avatar succeeds for an existing account")
	assert_equal(set_res.account.get("avatar"), "avatar_female_03", "set_avatar stores the new id")
	assert_equal(s.get_account(int(result.account.get("id"))).get("avatar"), "avatar_female_03", "set_avatar persists to the account")
	assert_equal(s.set_avatar(999, "avatar_female_03").ok, false, "set_avatar rejects an unknown account")
	assert_equal(s.set_avatar(int(result.account.get("id")), "").ok, false, "set_avatar rejects an empty id")


func test_create_account_duplicate() -> void:
	print("\n=== Account Duplicate Check ===")
	var s = fresh()

	# Create first Alice
	s.create_account("Alice", "secret1")

	# Try to create alice (lowercase) - should fail due to case-insensitive check
	var result = s.create_account("alice", "secret2")
	assert_equal(result.ok, false, "Reject duplicate username (case-insensitive)")
	assert_equal(result.error, "username_taken", "Error is 'username_taken'")


func test_verify_login() -> void:
	print("\n=== Verify Login ===")
	var s = fresh()

	# Create account
	s.create_account("Alice", "secret1")

	# Test successful login
	var result = s.verify_login("Alice", "secret1")
	assert_equal(result.ok, true, "verify_login succeeds with correct credentials")

	# Test wrong password
	result = s.verify_login("Alice", "wrong")
	assert_equal(result.error, "bad_credentials", "Wrong password returns 'bad_credentials'")

	# Test nonexistent user
	result = s.verify_login("nobody", "x")
	assert_equal(result.error, "no_such_user", "Nonexistent user returns 'no_such_user'")


func test_hash_password_deterministic() -> void:
	print("\n=== Hash Password Deterministic ===")
	var salt_hex = "00112233445566778899aabbccddeeff"

	# Hash same password twice with same salt
	var hash1 = ServerStore.hash_password("pw", salt_hex)
	var hash2 = ServerStore.hash_password("pw", salt_hex)

	assert_equal(hash1.hash, hash2.hash, "Same password and salt produce same hash")
	assert_equal(hash1.salt, salt_hex, "Salt is preserved")

	# Different salt produces different hash
	var hash3 = ServerStore.hash_password("pw", "")
	assert_true(hash3.hash != hash1.hash, "Different salt produces different hash")


func test_verify_password() -> void:
	print("\n=== Verify Password ===")
	var hash_result = ServerStore.hash_password("hunter2")

	# Correct password
	var is_valid = ServerStore.verify_password("hunter2", hash_result.salt, hash_result.hash, hash_result.iterations)
	assert_equal(is_valid, true, "Correct password verifies")

	# Wrong password (case sensitive)
	is_valid = ServerStore.verify_password("Hunter2", hash_result.salt, hash_result.hash, hash_result.iterations)
	assert_equal(is_valid, false, "Wrong password (case mismatch) fails verification")


func test_expected_score() -> void:
	print("\n=== Expected Score ===")

	var score = ServerStore.expected_score(1000, 1000)
	assert_almost_equal(score, 0.5, 0.001, "expected_score(1000,1000) is ~0.5")

	score = ServerStore.expected_score(1400, 1000)
	assert_true(score > 0.9, "expected_score(1400,1000) > 0.9")

	score = ServerStore.expected_score(1000, 1400)
	assert_true(score < 0.1, "expected_score(1000,1400) < 0.1")

	var score_a = ServerStore.expected_score(1200, 1300)
	var score_b = ServerStore.expected_score(1300, 1200)
	assert_almost_equal(score_a + score_b, 1.0, 0.001, "expected_score(a,b) + expected_score(b,a) is ~1.0")


func test_k_factor() -> void:
	print("\n=== K Factor ===")

	assert_equal(ServerStore.k_factor(0), 40, "k_factor(0) == 40")
	assert_equal(ServerStore.k_factor(9), 40, "k_factor(9) == 40")
	assert_equal(ServerStore.k_factor(10), 20, "k_factor(10) == 20")
	assert_equal(ServerStore.k_factor(29), 20, "k_factor(29) == 20")
	assert_equal(ServerStore.k_factor(30), 10, "k_factor(30) == 10")


func test_apply_result_win() -> void:
	print("\n=== Apply Result (Win) ===")

	var result = ServerStore.apply_result(1000, 0, 1000, 0, 1)
	assert_equal(result.delta_a, 20, "Winner gains +20 (round(40*(1-0.5)))")
	assert_equal(result.delta_b, -20, "Loser loses -20")
	assert_equal(result.elo_a_after, 1020, "Winner elo becomes 1020")
	assert_equal(result.elo_b_after, 980, "Loser elo becomes 980")


func test_apply_result_draw() -> void:
	print("\n=== Apply Result (Draw) ===")

	var result = ServerStore.apply_result(1000, 50, 1000, 50, 0)
	assert_equal(result.delta_a, 0, "Draw with equal elo gives 0 (k=10, score-e=0)")
	assert_equal(result.delta_b, 0, "Draw with equal elo gives 0")


func test_points_delta() -> void:
	print("\n=== Points Delta ===")

	assert_equal(ServerStore.points_delta("win"), 10, "Win gives 10 points")
	assert_equal(ServerStore.points_delta("loss"), 3, "Loss gives 3 points")
	assert_equal(ServerStore.points_delta("draw"), 5, "Draw gives 5 points")
	assert_equal(ServerStore.points_delta("x"), 0, "Unknown outcome gives 0 points")


func test_record_match_normal() -> void:
	print("\n=== Record Match (Normal) ===")
	var s = fresh()

	# Create Alice and Bob
	var alice_result = s.create_account("Alice", "secret1")
	var alice = alice_result.account
	var bob_result = s.create_account("Bob", "secret2")
	var bob = bob_result.account

	# Record match: Alice wins
	var match = s.record_match(alice.id, bob.id, 1, 5, 3, false)

	# Reload accounts
	var alice_reloaded = s.get_account(alice.id)
	var bob_reloaded = s.get_account(bob.id)

	assert_equal(alice_reloaded.elo, 1020, "Alice elo is 1020 after win")
	assert_equal(alice_reloaded.wins, 1, "Alice wins is 1")
	assert_equal(alice_reloaded.games, 1, "Alice games is 1")
	assert_equal(alice_reloaded.points, 10, "Alice points is 10 (win delta)")

	assert_equal(bob_reloaded.elo, 980, "Bob elo is 980 after loss")
	assert_equal(bob_reloaded.losses, 1, "Bob losses is 1")
	assert_equal(bob_reloaded.points, 3, "Bob points is 3 (loss delta)")

	assert_equal(match.is_bot_match, false, "Match is_bot_match is false")
	assert_equal(match.winner, 1, "Match winner is 1")


func test_record_match_bot() -> void:
	print("\n=== Record Match (Bot) ===")
	var s = fresh()

	# Create Alice
	var alice_result = s.create_account("Alice", "secret1")
	var alice = alice_result.account

	# Count accounts before bot match
	var accounts_before = s._accounts.size()

	# Record bot match: Alice loses to bot
	var match = s.record_match(alice.id, 0, 2, 2, 4, true)

	# Verify no new account created
	assert_equal(s._accounts.size(), accounts_before, "No account created for bot (id 0)")

	# Check Alice's stats
	var alice_reloaded = s.get_account(alice.id)
	assert_equal(alice_reloaded.losses, 1, "Alice losses is 1")
	assert_equal(alice_reloaded.points, 3, "Alice points is 3 (loss delta)")
	assert_equal(alice_reloaded.games, 1, "Alice games is 1")

	# Check match record
	assert_equal(match.is_bot_match, true, "Match is_bot_match is true")
	assert_equal(match.account_2_id, 0, "Match account_2_id is 0 (bot)")


func test_rank_and_ladder() -> void:
	print("\n=== Rank and Ladder ===")
	var s = fresh()

	# Create 3 accounts
	var alice_result = s.create_account("Alice", "secret1")
	var alice = alice_result.account
	var bob_result = s.create_account("Bob", "secret2")
	var bob = bob_result.account
	var charlie_result = s.create_account("Charlie", "secret3")
	var charlie = charlie_result.account

	# Record matches to spread elo
	# Alice beats Bob (Alice 1020, Bob 980)
	s.record_match(alice.id, bob.id, 1, 5, 3, false)

	# Charlie beats Bob (Charlie 1020, Bob 950)
	s.record_match(charlie.id, bob.id, 1, 5, 3, false)

	# Alice beats Charlie (Alice 1030, Charlie 1010)
	s.record_match(alice.id, charlie.id, 1, 5, 3, false)

	# Verify rank_of returns correct 1-based ranks
	var alice_rank = s.rank_of(alice.id)
	var charlie_rank = s.rank_of(charlie.id)
	var bob_rank = s.rank_of(bob.id)

	assert_equal(alice_rank, 1, "Alice (highest elo) has rank 1")
	assert_equal(charlie_rank, 2, "Charlie has rank 2")
	assert_equal(bob_rank, 3, "Bob (lowest elo) has rank 3")

	# Test ladder
	var ladder = s.ladder(10, 0, alice.id)

	assert_equal(ladder.rows.size(), 3, "Ladder has 3 rows")
	assert_equal(ladder.your_rank, 1, "Your rank is 1")
	assert_equal(ladder.your_row_included, true, "Your row is included")

	# Check first row is Alice with rank 1 and is_you true
	var first_row = ladder.rows[0]
	assert_equal(first_row.rank, 1, "First row rank is 1")
	assert_equal(first_row.is_you, true, "First row is_you is true")
	assert_equal(first_row.display_name, "Alice", "First row display_name is Alice")

	# Check second row is Charlie
	var second_row = ladder.rows[1]
	assert_equal(second_row.rank, 2, "Second row rank is 2")
	assert_equal(second_row.is_you, false, "Second row is_you is false")
	assert_equal(second_row.display_name, "Charlie", "Second row display_name is Charlie")


func test_recent_matches() -> void:
	print("\n=== Recent Matches ===")
	var s = fresh()

	# Create Alice and Bob
	var alice_result = s.create_account("Alice", "secret1")
	var alice = alice_result.account
	var bob_result = s.create_account("Bob", "secret2")
	var bob = bob_result.account

	# Record: Alice beats Bob
	s.record_match(alice.id, bob.id, 1, 5, 3, false)

	# Record: Alice loses to Bot (will have higher match id, so comes first in recent_matches)
	s.record_match(alice.id, 0, 2, 2, 4, true)

	# Get Alice's recent matches
	var matches = s.recent_matches(alice.id)

	assert_equal(matches.size(), 2, "Alice has 2 recent matches")

	# Most recent first (bot match)
	var first_match = matches[0]
	assert_equal(first_match.outcome, "loss", "Most recent match outcome is 'loss'")
	assert_equal(first_match.opponent_name, "Bot", "Most recent match opponent is 'Bot'")
	assert_equal(first_match.is_bot_match, true, "Most recent match is_bot_match is true")

	# Second match (vs Bob)
	var second_match = matches[1]
	assert_equal(second_match.outcome, "win", "Second match outcome is 'win'")
	assert_equal(second_match.opponent_name, "Bob", "Second match opponent is 'Bob'")
	assert_equal(second_match.is_bot_match, false, "Second match is_bot_match is false")


func test_quest_progress_and_daily_reset() -> void:
	print("\n=== Quest Progress and Daily Reset ===")
	var s = fresh()

	# Find two different days that both have "win_1" in their active_ids
	var day_a = ""
	var day_b = ""
	for d in range(1, 61):
		var date_str = "2026-01-%02d" % d
		var active = QuestSystem.daily_quest_ids(date_str)
		if "win_1" in active:
			if day_a == "":
				day_a = date_str
			elif day_b == "" and date_str != day_a:
				day_b = date_str
				break

	assert_true(day_a != "", "Found a day with win_1 active")
	assert_true(day_b != "", "Found a different day with win_1 active")

	# Test 1: Apply progress on day_a
	s.create_account("Q", "p")
	var id = s._accounts[0].id
	var ctx = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 2,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var q_res = s.apply_quest_progress(id, ctx, day_a)
	assert_equal(q_res["points_awarded"], 10, "First win awards 10 quest points")
	assert_equal(q_res["completed"].size(), 1, "First win completes one quest")
	assert_equal(q_res["completed"][0]["id"], "win_1", "Completed quest is win_1")
	assert_equal(q_res["points_total"], 10, "Points total is 10")

	# Check persisted shape
	var account = s.get_account(id)
	var quests_norm = account.get("quests", {})
	assert_equal(quests_norm["day"], day_a, "Persisted day matches day_a")
	assert_equal(quests_norm["active_ids"].size(), 3, "active_ids has 3 quests")
	assert_equal(quests_norm["state"]["win_1"]["completed"], true, "win_1 is persisted as completed")

	# Test 2: Second win same day_a
	var q_res2 = s.apply_quest_progress(id, ctx, day_a)
	assert_equal(q_res2["points_awarded"], 0, "Second win awards 0 new points (win_1 already done)")
	assert_equal(q_res2["completed"].size(), 0, "Second win completes no new quests")

	# Test 3: Apply progress on day_b (different day) - state resets
	var q_res3 = s.apply_quest_progress(id, ctx, day_b)
	assert_equal(q_res3["points_awarded"], 10, "After day roll to day_b, win_1 completes again (+10)")
	assert_equal(q_res3["points_total"], 20, "Points total is now 20 (10 + 10)")
	var account_day_b = s.get_account(id)
	assert_equal(account_day_b.get("quests", {}).get("day", ""), day_b, "Day is updated to day_b")

	# Test 4: Unknown account
	var q_res4 = s.apply_quest_progress(9999, ctx, day_a)
	assert_equal(q_res4["completed"].size(), 0, "Unknown account returns no completions")
	assert_equal(q_res4["points_awarded"], 0, "Unknown account returns 0 points")
	assert_equal(q_res4["points_total"], 0, "Unknown account returns 0 total")
