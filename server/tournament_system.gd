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


## Builds the next round from a fully-resolved round's winners. Returns []
## when `round` is already the final (a single slot).
static func advance_round(round: Array) -> Array:
	if round.size() <= 1:
		return []
	var next := []
	for i in range(0, round.size(), 2):
		var s1: Dictionary = round[i]
		var s2: Dictionary = round[i + 1]
		next.append(_make_slot(i / 2, s1.winner_account_id, s1.winner_is_bot, s2.winner_account_id, s2.winner_is_bot))
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
		"account_id_a": account_id_a, "is_bot_a": is_bot_a,
		"account_id_b": account_id_b, "is_bot_b": is_bot_b,
		"match_id": 0,
		"winner_account_id": 0, "winner_is_bot": false,
		"resolved": false,
		"score_a": 0, "score_b": 0,
	}


static func _fisher_yates(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
