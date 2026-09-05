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
	test_tournament_create_validation()
	test_tournament_create_success()
	test_tournament_sign_up()
	test_tournament_check_in()
	test_tournament_persistence()
	test_shop_purchase_happy_path()
	test_shop_purchase_insufficient()
	test_shop_purchase_already_owned()
	test_shop_purchase_not_for_sale()
	test_grant_reward()
	test_equip_premium_not_owned()
	test_equip_premium_owned()
	test_equip_legacy()
	test_set_sleeve()
	test_apply_match_stats()
	test_apply_tournament_stat()

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


func test_tournament_create_validation() -> void:
	print("\n=== Tournament Create Validation ===")
	var s = fresh()

	# Valid creation should succeed
	var now = int(Time.get_unix_time_from_system())
	var result = s.create_tournament(1, "Test Tournament", 32, now, now + 3600, now + 7200, false)
	assert_equal(result.ok, true, "Valid tournament creation succeeds")
	assert_equal(result.tournament.status, "signup", "New tournament has status 'signup'")

	# Empty name after strip_edges
	var result_empty = s.create_tournament(1, "   ", 32, now, now + 3600, now + 7200, false)
	assert_equal(result_empty.ok, false, "Empty name after strip_edges fails")
	assert_equal(result_empty.error, "bad_name", "Error is 'bad_name' for empty")

	# Name over 60 chars
	var long_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 62 chars
	var result_long = s.create_tournament(1, long_name, 32, now, now + 3600, now + 7200, false)
	assert_equal(result_long.ok, false, "Name over 60 chars fails")
	assert_equal(result_long.error, "bad_name", "Error is 'bad_name' for over-long name")

	# signup_close_ts > check_in_open_ts
	var result_schedule1 = s.create_tournament(1, "Bad Schedule", 32, now + 7200, now + 3600, now + 10800, false)
	assert_equal(result_schedule1.ok, false, "signup_close_ts > check_in_open_ts fails")
	assert_equal(result_schedule1.error, "bad_schedule", "Error is 'bad_schedule'")

	# check_in_open_ts >= start_ts
	var result_schedule2 = s.create_tournament(1, "Bad Schedule 2", 32, now, now + 7200, now + 3600, false)
	assert_equal(result_schedule2.ok, false, "check_in_open_ts >= start_ts fails")
	assert_equal(result_schedule2.error, "bad_schedule", "Error is 'bad_schedule'")


func test_tournament_create_success() -> void:
	print("\n=== Tournament Create Success ===")
	var s = fresh()

	var now = int(Time.get_unix_time_from_system())

	# Request 10, allow_small=false -> should be 32
	var result1 = s.create_tournament(1, "Tournament 1", 10, now, now + 3600, now + 7200, false, false)
	assert_equal(result1.ok, true, "Tournament creation with bracket_size coercion succeeds")
	assert_equal(result1.tournament.bracket_size, 32, "Requested 10 + allow_small=false -> stored 32")
	assert_equal(result1.tournament.participants.size(), 0, "New tournament has empty participants")
	assert_equal(result1.tournament.rounds.size(), 0, "New tournament has empty rounds")

	# Request 10, allow_small=true -> should be 16
	var result2 = s.create_tournament(1, "Tournament 2", 10, now, now + 3600, now + 7200, false, true)
	assert_equal(result2.ok, true, "Tournament creation with allow_small=true succeeds")
	assert_equal(result2.tournament.bracket_size, 16, "Requested 10 + allow_small=true -> stored 16")

	# Request 40 (either allow_small) -> should be 64
	var result3 = s.create_tournament(1, "Tournament 3", 40, now, now + 3600, now + 7200, false, false)
	assert_equal(result3.tournament.bracket_size, 64, "Requested 40 + allow_small=false -> stored 64")

	var result4 = s.create_tournament(1, "Tournament 4", 40, now, now + 3600, now + 7200, false, true)
	assert_equal(result4.tournament.bracket_size, 64, "Requested 40 + allow_small=true -> stored 64")

	# Request 32, allow_small=false -> should be 32
	var result5 = s.create_tournament(1, "Tournament 5", 32, now, now + 3600, now + 7200, false, false)
	assert_equal(result5.tournament.bracket_size, 32, "Requested 32 + allow_small=false -> stored 32")


func test_tournament_sign_up() -> void:
	print("\n=== Tournament Sign Up ===")
	var s = fresh()

	# Create two accounts
	s.create_account("Alice", "pass1")
	s.create_account("Bob", "pass2")
	var alice_id = s._accounts[0].id
	var bob_id = s._accounts[1].id

	var now = int(Time.get_unix_time_from_system())

	# Create a tournament with small bracket for easier full-test
	var t_result = s.create_tournament(1, "Test Tournament", 4, now, now + 3600, now + 7200, false, true)
	var tournament_id = t_result.tournament.id

	# Try to sign up non-existent user FIRST (before filling tournament)
	var signup_nouser = s.sign_up(tournament_id, 9999)
	assert_equal(signup_nouser.ok, false, "Sign-up for non-existent user fails")
	assert_equal(signup_nouser.error, "no_such_user", "Error is 'no_such_user'")

	# Sign up Alice successfully
	var signup1 = s.sign_up(tournament_id, alice_id)
	assert_equal(signup1.ok, true, "Alice signs up successfully")
	assert_equal(signup1.tournament.participants.size(), 1, "Participant count is 1")
	assert_equal(signup1.tournament.participants[0].account_id, alice_id, "First participant is Alice")

	# Try duplicate sign-up by Alice
	var signup2 = s.sign_up(tournament_id, alice_id)
	assert_equal(signup2.ok, false, "Duplicate sign-up fails")
	assert_equal(signup2.error, "already_signed_up", "Error is 'already_signed_up'")

	# Sign up Bob successfully
	var signup3 = s.sign_up(tournament_id, bob_id)
	assert_equal(signup3.ok, true, "Bob signs up successfully")
	assert_equal(signup3.tournament.participants.size(), 2, "Participant count is 2")

	# Fill up tournament to bracket_size (4)
	s.create_account("Charlie", "pass3")
	s.create_account("Diana", "pass4")
	var charlie_id = s._accounts[2].id
	var diana_id = s._accounts[3].id

	s.sign_up(tournament_id, charlie_id)
	s.sign_up(tournament_id, diana_id)
	assert_equal(s.get_tournament(tournament_id).participants.size(), 4, "Tournament now full (4/4)")

	# Try to sign up a 5th person
	s.create_account("Eve", "pass5")
	var eve_id = s._accounts[4].id
	var signup_full = s.sign_up(tournament_id, eve_id)
	assert_equal(signup_full.ok, false, "Sign-up to full tournament fails")
	assert_equal(signup_full.error, "tournament_full", "Error is 'tournament_full'")

	# Try to sign up to non-existent tournament
	var signup_notourney = s.sign_up(9999, alice_id)
	assert_equal(signup_notourney.ok, false, "Sign-up to non-existent tournament fails")
	assert_equal(signup_notourney.error, "no_such_tournament", "Error is 'no_such_tournament'")

	# Try to sign up when status is no longer "signup"
	var t = s.get_tournament(tournament_id)
	t.status = "check_in"  # Direct mutation (no public method yet)
	s.persist_tournament(t)
	var signup_closed = s.sign_up(tournament_id, s._accounts[4].id)
	assert_equal(signup_closed.ok, false, "Sign-up to non-signup-status tournament fails")
	assert_equal(signup_closed.error, "signup_closed", "Error is 'signup_closed'")


func test_tournament_check_in() -> void:
	print("\n=== Tournament Check In ===")
	var s = fresh()

	# Create accounts and tournament
	s.create_account("Alice", "pass1")
	s.create_account("Bob", "pass2")
	var alice_id = s._accounts[0].id
	var bob_id = s._accounts[1].id

	var now = int(Time.get_unix_time_from_system())
	var t_result = s.create_tournament(1, "Check-In Tournament", 4, now, now + 3600, now + 7200, false, true)
	var tournament_id = t_result.tournament.id

	# Sign up both
	s.sign_up(tournament_id, alice_id)
	s.sign_up(tournament_id, bob_id)

	# Try to check in while status is still "signup" -> should fail
	var checkin_early = s.check_in(tournament_id, alice_id)
	assert_equal(checkin_early.ok, false, "Check-in while status is signup fails")
	assert_equal(checkin_early.error, "check_in_not_open", "Error is 'check_in_not_open'")

	# Transition tournament to "check_in" status
	var t = s.get_tournament(tournament_id)
	t.status = "check_in"
	s.persist_tournament(t)

	# Now check in should work
	var checkin_alice = s.check_in(tournament_id, alice_id)
	assert_equal(checkin_alice.ok, true, "Check-in succeeds when status is check_in")

	# Verify Alice is checked in
	var alice_participant = null
	for p in checkin_alice.tournament.participants:
		if int(p.account_id) == alice_id:
			alice_participant = p
			break
	assert_equal(alice_participant.checked_in, true, "Alice participant.checked_in is true")

	# Try to check in Alice again -> should fail
	var checkin_duplicate = s.check_in(tournament_id, alice_id)
	assert_equal(checkin_duplicate.ok, false, "Duplicate check-in fails")
	assert_equal(checkin_duplicate.error, "already_checked_in", "Error is 'already_checked_in'")

	# Try to check in Bob (he's signed up)
	var checkin_bob = s.check_in(tournament_id, bob_id)
	assert_equal(checkin_bob.ok, true, "Bob check-in succeeds")

	# Try to check in someone not signed up
	s.create_account("Charlie", "pass3")
	var charlie_id = s._accounts[2].id
	var checkin_notsignedup = s.check_in(tournament_id, charlie_id)
	assert_equal(checkin_notsignedup.ok, false, "Check-in for non-signed-up account fails")
	assert_equal(checkin_notsignedup.error, "not_signed_up", "Error is 'not_signed_up'")

	# Try to check in to non-existent tournament
	var checkin_notourney = s.check_in(9999, alice_id)
	assert_equal(checkin_notourney.ok, false, "Check-in to non-existent tournament fails")
	assert_equal(checkin_notourney.error, "no_such_tournament", "Error is 'no_such_tournament'")


func test_tournament_persistence() -> void:
	print("\n=== Tournament Persistence ===")
	var s1 = fresh()

	# Create an account and tournament in first ServerStore
	s1.create_account("Alice", "pass1")
	var alice_id = s1._accounts[0].id

	var now = int(Time.get_unix_time_from_system())
	var t_result = s1.create_tournament(1, "Persistent Tournament", 32, now, now + 3600, now + 7200, false)
	var t1_id = t_result.tournament.id
	var t1_name = t_result.tournament.name
	var t1_bracket_size = t_result.tournament.bracket_size

	# Sign up Alice in first store
	s1.sign_up(t1_id, alice_id)

	# Verify tournament exists and has 1 participant
	assert_equal(s1.get_tournament(t1_id).participants.size(), 1, "Tournament has 1 participant in s1")

	# Open a FRESH ServerStore on the SAME directory
	var s2 = fresh()

	# s2's fresh() call already increments _fresh_seq, so it will use the SAME directory as s1
	# (actually, no - fresh() creates a new subdirectory based on _fresh_seq)
	# We need to explicitly use the same directory. Let me re-check the test pattern...
	# Actually, looking at the test pattern in the existing file, fresh() creates:
	# _dir + _fresh_seq + "/"
	# So each fresh() call gets a unique directory. To test persistence, I need to
	# open the SAME directory twice without clearing fresh_seq in between.

	# Let me rewrite this part to use the same directory explicitly:
	var persistent_dir = "%spersist_test/" % _dir
	var s2_manual = ServerStore.new()
	s2_manual.open(persistent_dir)

	# First, make s1 use this persistent_dir
	var s1_manual = ServerStore.new()
	s1_manual.open(persistent_dir)

	# Create tournament in s1_manual
	s1_manual.create_account("Alice", "pass1")
	var alice_id_manual = s1_manual._accounts[0].id

	var t_result_manual = s1_manual.create_tournament(1, "Persistent Tournament", 32, now, now + 3600, now + 7200, false)
	var t1_id_manual = t_result_manual.tournament.id
	var t1_name_manual = t_result_manual.tournament.name
	var t1_bracket_size_manual = t_result_manual.tournament.bracket_size

	s1_manual.sign_up(t1_id_manual, alice_id_manual)
	assert_equal(s1_manual.get_tournament(t1_id_manual).participants.size(), 1, "s1_manual tournament has 1 participant")

	# Now open s2 on the SAME directory
	var s2_persistent = ServerStore.new()
	s2_persistent.open(persistent_dir)

	# Check that tournament exists in s2
	var t_from_s2 = s2_persistent.get_tournament(t1_id_manual)
	assert_equal(t_from_s2.name, t1_name_manual, "Tournament name persisted")
	assert_equal(t_from_s2.bracket_size, t1_bracket_size_manual, "Tournament bracket_size persisted")
	assert_equal(t_from_s2.participants.size(), 1, "Tournament participant persisted")

	# Create another tournament in s2 and verify its id is incremented correctly
	var t_result_s2 = s2_persistent.create_tournament(1, "Second Tournament", 16, now, now + 3600, now + 7200, false, true)
	var t2_id = t_result_s2.tournament.id
	assert_equal(t2_id, t1_id_manual + 1, "s2 creates tournament with id incremented correctly past s1's highest")

	# Verify both tournaments visible in s2
	var all_t_s2 = s2_persistent.all_tournaments()
	assert_equal(all_t_s2.size(), 2, "s2 sees both tournaments after fresh open")


func test_shop_purchase_happy_path() -> void:
	print("\n=== Shop Purchase Happy Path ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account = res.account

	# Set up account with enough points
	account["points"] = 100
	s._save_accounts()

	# Purchase item
	var p_res = s.purchase(int(account.id), "aphrodite")
	assert_equal(p_res.ok, true, "Purchase succeeds")
	assert_equal(p_res.account.points, 95, "Points debited correctly (100 - 5)")
	assert_true("aphrodite" in p_res.account.owned_rewards, "Item added to owned_rewards")


func test_shop_purchase_insufficient() -> void:
	print("\n=== Shop Purchase Insufficient Points ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account = res.account
	account["points"] = 2
	s._save_accounts()

	var p_res = s.purchase(int(account.id), "aphrodite")
	assert_equal(p_res.ok, false, "Purchase fails with insufficient points")
	assert_equal(p_res.error, "insufficient", "Error is 'insufficient'")
	assert_equal(account.points, 2, "Points not changed")
	assert_true("aphrodite" not in account.owned_rewards, "Item not added")


func test_shop_purchase_already_owned() -> void:
	print("\n=== Shop Purchase Already Owned ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account = res.account
	account["points"] = 100
	account["owned_rewards"].append("aphrodite")
	s._save_accounts()

	var p_res = s.purchase(int(account.id), "aphrodite")
	assert_equal(p_res.ok, false, "Purchase fails for already-owned item")
	assert_equal(p_res.error, "already_owned", "Error is 'already_owned'")


func test_shop_purchase_not_for_sale() -> void:
	print("\n=== Shop Purchase Not For Sale ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account = res.account
	account["points"] = 100
	s._save_accounts()

	# Try to purchase an achievement-only item
	var p_res = s.purchase(int(account.id), "frame_champion")
	assert_equal(p_res.ok, false, "Purchase fails for non-shop item")
	assert_equal(p_res.error, "not_for_sale", "Error is 'not_for_sale'")


func test_grant_reward() -> void:
	print("\n=== Grant Reward ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account = res.account
	account["points"] = 10
	s._save_accounts()

	var g_res = s.grant_reward(account, 50, ["frame_champion", "sleeve_flame"])
	assert_equal(g_res.points_total, 60, "Points awarded (10 + 50)")
	assert_equal(g_res.granted.size(), 2, "Both items granted")
	assert_true("frame_champion" in account.owned_rewards, "frame_champion added")
	assert_true("sleeve_flame" in account.owned_rewards, "sleeve_flame added")

	# Idempotency test: grant same items again
	var g_res2 = s.grant_reward(account, 10, ["frame_champion", "avatar_champion"])
	assert_equal(g_res2.granted.size(), 1, "Only new item granted (avatar_champion)")
	assert_true("avatar_champion" in account.owned_rewards, "avatar_champion added")


func test_equip_premium_not_owned() -> void:
	print("\n=== Equip Premium Not Owned ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account_id = int(res.account.id)

	# Try to equip premium item not owned
	var eq_res = s.set_avatar(account_id, "aphrodite")
	assert_equal(eq_res.ok, false, "Cannot equip unowned premium avatar")
	assert_equal(eq_res.error, "not_owned", "Error is 'not_owned'")


func test_equip_premium_owned() -> void:
	print("\n=== Equip Premium Owned ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account = res.account
	account["owned_rewards"].append("aphrodite")
	s._save_accounts()

	var eq_res = s.set_avatar(int(account.id), "aphrodite")
	assert_equal(eq_res.ok, true, "Can equip owned premium avatar")
	assert_equal(eq_res.account.avatar, "aphrodite", "Avatar set correctly")


func test_equip_legacy() -> void:
	print("\n=== Equip Legacy (Non-Catalog) ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account_id = int(res.account.id)

	# Legacy avatars (not in ShopCatalog) should equip without ownership check
	var eq_res = s.set_avatar(account_id, "avatar_female_01")
	assert_equal(eq_res.ok, true, "Can equip legacy avatar without ownership")


func test_set_sleeve() -> void:
	print("\n=== Set Sleeve ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account = res.account
	account["owned_rewards"].append("sleeve_noir")
	s._save_accounts()

	var eq_res = s.set_sleeve(int(account.id), "sleeve_noir")
	assert_equal(eq_res.ok, true, "Can set owned premium sleeve")
	assert_equal(eq_res.account.sleeve, "sleeve_noir", "Sleeve set correctly")

	# Unequip with empty string
	var uneq_res = s.set_sleeve(int(account.id), "")
	assert_equal(uneq_res.ok, true, "Can unequip sleeve with empty string")
	assert_equal(uneq_res.account.sleeve, "", "Sleeve cleared")


func test_apply_match_stats() -> void:
	print("\n=== Apply Match Stats ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account_id = int(res.account.id)

	# First match: an ordinary 7-3 win (NOT perfect — opp scored).
	var ctx = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 3,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	var res1 = s.apply_match_stats(account_id, ctx)
	var account = s.get_account(account_id)
	var stats = account.stats

	assert_equal(stats.games, 1, "games incremented to 1")
	assert_equal(stats.wins, 1, "wins incremented to 1")
	assert_equal(stats.win_streak_current, 1, "win_streak_current set to 1")
	assert_equal(stats.win_streak_best, 1, "win_streak_best set to 1")
	assert_equal(int(stats.get("perfect_wins", 0)), 0, "perfect_wins still 0 (opp scored 3)")
	assert_equal(res1.achievement_points, 0, "No achievements unlocked yet")

	# Second match: a true 7-0 perfect win.
	var perfect_ctx = {
		"outcome": "win",
		"your_score": 7,
		"opp_score": 0,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0},
		"your_pick_count": 0,
	}
	s.apply_match_stats(account_id, perfect_ctx)
	stats = s.get_account(account_id).stats
	assert_equal(int(stats.get("perfect_wins", 0)), 1, "perfect_wins set to 1 after a 7-0")
	assert_equal(stats.win_streak_current, 2, "win_streak_current now 2")

	# A loss resets the streak but not the best.
	s.apply_match_stats(account_id, {
		"outcome": "loss", "your_score": 2, "opp_score": 7,
		"your_group_picks": {"money": 0, "time": 0, "awards": 0}, "your_pick_count": 0,
	})
	stats = s.get_account(account_id).stats
	assert_equal(stats.win_streak_current, 0, "streak reset to 0 on loss")
	assert_equal(stats.win_streak_best, 2, "best streak stays at 2")


func test_apply_tournament_stat() -> void:
	print("\n=== Apply Tournament Stat ===")
	var s = fresh()
	var res = s.create_account("Alice", "secret1")
	var account_id = int(res.account.id)

	var res1 = s.apply_tournament_stat(account_id, "tournaments_played")
	var account = s.get_account(account_id)
	assert_equal(account.stats.tournaments_played, 1, "tournaments_played incremented")
	# competitor Bronze threshold IS 1 (PLAN_achievements §1) -> unlocks now.
	assert_equal(res1.size(), 1, "competitor Bronze unlocks on first tournament")
	assert_equal(str(res1[0].id), "competitor", "the unlock is competitor")
	assert_equal(int(account.achievements.unlocked.competitor), 0, "competitor recorded at tier index 0")

	# A second played tournament does not re-unlock Bronze.
	var res_again = s.apply_tournament_stat(account_id, "tournaments_played")
	assert_equal(res_again.size(), 0, "no re-unlock on the second tournament")

	# tournaments_won=1 -> champion Bronze (threshold 1) unlocks.
	var res2 = s.apply_tournament_stat(account_id, "tournaments_won")
	account = s.get_account(account_id)
	assert_equal(account.stats.tournaments_won, 1, "tournaments_won incremented")
	assert_true(account.achievements.unlocked.has("champion"), "champion achievement unlocked")
