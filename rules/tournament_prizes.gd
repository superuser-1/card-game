class_name TournamentPrizes
## Pure rules for tournament prize pools — no Node / ServerStore / ShopCatalog
## dependency (item prices come in as a Callable) so it unit-tests in isolation
## and is safe to call from both the client (live cost preview in the creation
## modal) and the server (authoritative escrow + payout). Like CubeRules /
## TournamentSystem, the client's numbers are only a hint; sanitize() on the
## server is what actually charges the wallet.
##
## A prize spec is { "<bucket>": { "points": int>=0, "items": [shop_id, …] } },
## carrying only "set" buckets (points or items non-empty).

## Rank buckets, earliest first. The "no gaps" rule keys off this order.
const BUCKETS := ["1", "2", "3", "4_8", "9_16"]

## How many placement slots each bucket covers. Cost is charged per slot and the
## payout grants the bucket prize to every player who lands in it, so escrow ==
## total payout.
const SLOTS := {"1": 1, "2": 1, "3": 2, "4_8": 4, "9_16": 8}

## Human labels for UI. The bracket has no bronze match, so the two semifinal
## losers share 3rd/4th; keys stay short ("3", "4_8") but the LABELS reflect the
## real placement ranges (2 / 4 / 8 players).
const LABELS := {"1": "1st", "2": "2nd", "3": "3rd–4th", "4_8": "5th–8th", "9_16": "9th–16th"}


## Clean an untrusted prize spec and price it.
##   raw       : Dictionary (bucket -> {points, items}) from a client
##   price_of  : Callable(shop_id: String) -> int  — the item's points price, or
##               a NEGATIVE number if it is not a buyable shop item
## Returns { ok: bool, error: String, prizes: Dictionary, cost: int }.
##   - empty / all-empty spec       -> { ok, "", {}, 0 }
##   - unknown bucket key            -> ok=false, "prize_bad_bucket"
##   - item id that isn't buyable    -> ok=false, "prize_bad_item"
##   - a set bucket with an earlier
##     bucket left unset             -> ok=false, "prize_gap"
static func sanitize(raw, price_of: Callable) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {"ok": true, "error": "", "prizes": {}, "cost": 0}

	var clean := {}
	for key in raw.keys():
		var bucket := str(key)
		if bucket not in BUCKETS:
			return {"ok": false, "error": "prize_bad_bucket", "prizes": {}, "cost": 0}
		var v = raw[key]
		if typeof(v) != TYPE_DICTIONARY:
			continue
		var points: int = max(0, int(v.get("points", 0)))
		var items: Array = []
		var seen := {}
		for entry in (v.get("items", []) if v.get("items", []) is Array else []):
			var id := str(entry)
			if id == "" or seen.has(id):
				continue
			if int(price_of.call(id)) < 0:
				return {"ok": false, "error": "prize_bad_item", "prizes": {}, "cost": 0}
			seen[id] = true
			items.append(id)
		if points == 0 and items.is_empty():
			continue   # bucket not actually "set"
		clean[bucket] = {"points": points, "items": items}

	# No gaps: every bucket before a set one must also be set.
	var hit_set := false
	for i in range(BUCKETS.size() - 1, -1, -1):
		var b: String = BUCKETS[i]
		if clean.has(b):
			hit_set = true
		elif hit_set:
			return {"ok": false, "error": "prize_gap", "prizes": {}, "cost": 0}

	var cost := 0
	for b in clean:
		var per_slot: int = int(clean[b].points)
		for id in clean[b].items:
			per_slot += int(price_of.call(id))
		cost += int(SLOTS[b]) * per_slot

	return {"ok": true, "error": "", "prizes": clean, "cost": cost}


## Cost of an already-sanitized prize spec (same math as sanitize()).
static func cost_of(prizes: Dictionary, price_of: Callable) -> int:
	var cost := 0
	for b in prizes:
		if b not in BUCKETS:
			continue
		var per_slot: int = int(prizes[b].get("points", 0))
		for id in prizes[b].get("items", []):
			per_slot += max(0, int(price_of.call(id)))
		cost += int(SLOTS[b]) * per_slot
	return cost


## One-line human summary of a prize spec, e.g.
##   "Prizes — 1st: ◈500 + Athena · 2nd: ◈200 · 3rd: ◈100"
## `name_of.call(shop_id)` -> the item's display name.
static func summary_line(prizes: Dictionary, name_of: Callable) -> String:
	if prizes.is_empty():
		return ""
	var parts := []
	for b in BUCKETS:
		if not prizes.has(b):
			continue
		var p: Dictionary = prizes[b]
		var bits := []
		if int(p.get("points", 0)) > 0:
			bits.append("◈%d" % int(p.points))
		for id in p.get("items", []):
			bits.append(str(name_of.call(id)))
		parts.append("%s: %s" % [LABELS.get(b, b), " + ".join(bits)])
	return "Prizes — " + "  ·  ".join(parts)


## Which prize bucket a participant's finish falls in, or "" for none.
##   eliminated_round : 0 for the champion, else the round they lost in
##   total_rounds     : t.rounds.size()
static func bucket_for_placement(eliminated_round: int, total_rounds: int) -> String:
	if total_rounds <= 0:
		return ""
	if eliminated_round == 0:
		return "1"
	match total_rounds - eliminated_round:
		0: return "2"
		1: return "3"
		2: return "4_8"
		3: return "9_16"
	return ""
