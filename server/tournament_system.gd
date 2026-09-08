class_name TournamentSystem
extends RefCounted
## Pure single-elimination bracket logic for the Tournament feature. No Node
## or ServerStore dependency — everything here is a deterministic function of
## its arguments (given the same rng_seed, generate_bracket always produces
## the same layout), so it can be unit-tested in isolation and is safe to call
## from Net's server-authoritative tick.
##
## A "slot" is one matchup within one round:
##   {slot_index, account_id_a, account_id_b, is_bot_a, is_bot_b,
##    match_id, winner_account_id, winner_is_bot, resolved, score_a, score_b}
## account_id 0 with is_bot_*=true means "a bot occupies this side" — bots
## have no real account, so `winner_account_id` alone can't distinguish "a bot
## won" from "unresolved"; winner_is_bot exists specifically to remove that
## ambiguity.

const MIN_BRACKET_SIZE := 32  # UI-suggested default; admin can override smaller for dev/testing

## Hard floor of REAL checked-in players for a non-dev tournament to fire. Below
## this at start time the tournament is cancelled instead of run — tournament
## matches count toward quests/achievements, so a thinly-attended tournament
## must not become a farm. Not admin-configurable. Dev-bot tournaments bypass it.
const MIN_TOURNAMENT_PLAYERS := 32

## Wall-clock backstop for a single tournament match, per match_format. If a
## match outlives this the tournament tick force-resolves it (winner = whoever
## leads on games won, then on card score, then a coin flip) so one hung or
## broken game can't freeze the whole bracket forever — every unresolved slot
## blocks the round. Sized WAY above any legitimate game: hitting it means
## something is wrong, not that someone is playing slowly.
##
##   per round  ~ 2 * 30s turn clocks + 7s reveal                       = 67 s
##   per game   ~ (7 hand + 6 very generous tie) rounds * 67s
##                 + 15s deal / inter-game                              ~ 886 s
##   per match  ~ max_games * per-game
##                 + 2 * 60s reconnect grace (whole-series budget)
##                 + 60s buffer
##   max_games is 1 / 3 / 5 for Bo1 / Bo3 / Bo5.
const MATCH_HARD_CAP_MS := {
	1: 1066000,   # Bo1  ~18 min
	3: 2838000,   # Bo3  ~47 min
	5: 4610000,   # Bo5  ~77 min
}


static func match_hard_cap_ms(match_format: int) -> int:
	return int(MATCH_HARD_CAP_MS.get(match_format, int(MATCH_HARD_CAP_MS[1])))


## Breather between tournament rounds — the next round's matches are not
## dispatched until this many seconds after the previous round fully resolves,
## so players can step away. See net_node._maybe_advance_round; dev override
## --tournament-intermission-seconds=N.
const INTERMISSION_SECONDS := 120


static func next_power_of_2(n: int) -> int:
	var p := 1
	while p < n:
		p *= 2
	return p


## `allow_small` bypasses the 32 floor (dev/testing override) but bracket size
## is always coerced to a power of 2, minimum 2.
static func resolve_bracket_size(requested: int, allow_small: bool) -> int:
	var floor_size := 2 if allow_small else MIN_BRACKET_SIZE
	return next_power_of_2(max(requested, floor_size))


## Builds round 0 from a tournament's participant records + bracket_size.
## `participants` = Array of {account_id, checked_in, ...} (only `checked_in`
## participants play as themselves; anyone else — never signed up, or signed
## up but missed check-in — is replaced by a bot slot). Deterministic for a
## given (participants, bracket_size, rng_seed) triple.
static func generate_bracket(participants: Array, bracket_size: int, rng_seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var real := []
	for p in participants:
		if bool(p.get("checked_in", false)):
			real.append(int(p.account_id))
	_fisher_yates(real, rng)

	var slots := []
	for acc_id in real:
		slots.append({"account_id": acc_id, "is_bot": false})
	while slots.size() < bracket_size:
		slots.append({"account_id": 0, "is_bot": true})
	# Defensive: should never trigger (bot-fill always tops up to exactly
	# bracket_size), but never silently drop a real participant.
	if slots.size() > bracket_size:
		slots = slots.slice(0, bracket_size)
	_fisher_yates(slots, rng)

	var round0 := []
	for i in range(0, bracket_size, 2):
		round0.append(_make_slot(i / 2, slots[i].account_id, slots[i].is_bot, slots[i + 1].account_id, slots[i + 1].is_bot))
	return round0


## Round 0 for a REAL (bot-free) tournament: the checked-in account ids,
## shuffled, paired two at a time. An odd count leaves one player unpaired —
## they get an `is_bye` slot (see _make_bye_slot), resolved from creation, i.e.
## a free pass into the next round. Deterministic for a given
## (checked_in_ids, rng_seed). Unlike generate_bracket() there are no bot slots
## and the result is NOT padded to a power of two.
static func generate_bracket_shrink(checked_in_ids: Array, rng_seed: int) -> Array:
	var ids := checked_in_ids.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	_fisher_yates(ids, rng)

	var round0 := []
	var i := 0
	while i + 1 < ids.size():
		round0.append(_make_slot(round0.size(), int(ids[i]), false, int(ids[i + 1]), false))
		i += 2
	if i < ids.size():
		round0.append(_make_bye_slot(round0.size(), int(ids[i])))
	return round0


## Builds the next round from a fully-resolved round's winners (taken in slot
## order; a bye slot already carries its winner). Returns [] once a single
## winner remains.
##
## When `rng_seed` is non-zero the winners are re-shuffled before pairing, with
## the seed offset by `next_round_index` so each round's bye lands on a fresh
## random player. `rng_seed == 0` (the default, used by callers/tests that pass
## nothing) keeps the legacy positional pairing — winner of slot 0 meets winner
## of slot 1, etc.
static func advance_round(round: Array, rng_seed := 0, next_round_index := 0) -> Array:
	var winners := []
	for s in round:
		winners.append({"acc": int(s.winner_account_id), "is_bot": bool(s.winner_is_bot)})
	if winners.size() <= 1:
		return []
	if rng_seed != 0:
		var rng := RandomNumberGenerator.new()
		rng.seed = rng_seed + next_round_index
		_fisher_yates(winners, rng)

	var next := []
	var i := 0
	while i + 1 < winners.size():
		next.append(_make_slot(next.size(), winners[i].acc, winners[i].is_bot, winners[i + 1].acc, winners[i + 1].is_bot))
		i += 2
	if i < winners.size():
		var w = winners[i]
		if bool(w.is_bot):
			# Only reachable on the dev-bot power-of-two path, which never has
			# an odd winner count — kept defensive, not a real "bye".
			next.append(_make_slot(next.size(), 0, true, 0, true))
		else:
			next.append(_make_bye_slot(next.size(), int(w.acc)))
	return next


static func is_bot_vs_bot(slot: Dictionary) -> bool:
	return bool(slot.is_bot_a) and bool(slot.is_bot_b)


## Instant random-winner resolution for a bot-vs-bot slot (dev-bot-tournament
## fake results). Both sides are bot (account_id 0), so which "side" wins is
## not semantically distinct — either way a bot placeholder advances.
static func resolve_bot_vs_bot(slot: Dictionary, rng: RandomNumberGenerator) -> void:
	slot.resolved = true
	slot.winner_is_bot = true
	slot.winner_account_id = 0
	rng.randi_range(0, 1)  # consumed for parity with a real coin-flip; result unused, see note above


static func round_fully_resolved(round: Array) -> bool:
	for slot in round:
		if not bool(slot.resolved):
			return false
	return true


static func is_tournament_complete(rounds: Array) -> bool:
	return not rounds.is_empty() and rounds[-1].size() == 1 and bool(rounds[-1][0].resolved)


static func _make_slot(slot_index: int, account_id_a: int, is_bot_a: bool, account_id_b: int, is_bot_b: bool) -> Dictionary:
	return {
		"slot_index": slot_index,
		"is_bye": false,
		"account_id_a": account_id_a, "is_bot_a": is_bot_a,
		"account_id_b": account_id_b, "is_bot_b": is_bot_b,
		"match_id": 0,
		"winner_account_id": 0, "winner_is_bot": false,
		"resolved": false,
		"score_a": 0, "score_b": 0,
	}


## A one-player slot: this player sits the round out and advances for free.
## `resolved` + `winner_account_id` are set at creation so the tick loop skips
## it and round_fully_resolved()/is_tournament_complete() already count it.
static func _make_bye_slot(slot_index: int, account_id: int) -> Dictionary:
	return {
		"slot_index": slot_index,
		"is_bye": true,
		"account_id_a": account_id, "is_bot_a": false,
		"account_id_b": 0, "is_bot_b": false,
		"match_id": 0,
		"winner_account_id": account_id, "winner_is_bot": false,
		"resolved": true,
		"score_a": 0, "score_b": 0,
	}


static func _fisher_yates(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
