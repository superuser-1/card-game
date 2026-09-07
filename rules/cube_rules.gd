class_name CubeRules
## Shared, side-effect-free rules for "cubes" — player-curated movie catalogues
## used as the card pool for custom games and custom tournaments. Lives in
## rules/ (not the client or the server) because BOTH sides need it and the
## test runner exercises it directly: the client uses it to show a cube's
## legality live in the builder, the server re-runs it as the authority when a
## cube is actually chosen for a match. The client's verdict is only ever a
## hint; sanitize() on the server is what counts.

## Minimum distinct, valid cards for a cube to be usable. No upper limit.
const MIN_SIZE := 100


## Reduce an untrusted id list to a clean, legal cube id list.
##   raw       - ids as received from a client (any order, may repeat, may
##               contain ids that don't exist in this build's card set)
##   known_ids - Dictionary used as a set: {card_id: true} for every real card
## Returns {ok: bool, error: String, ids: Array[String]}:
##   - empty `raw`      -> {ok, "", []}   (caller treats [] as "full collection")
##   - < MIN_SIZE valid -> {ok=false, "cube_too_small", []}
##   - otherwise        -> {ok, "", <deduped, order-preserving, valid ids>}
static func sanitize(raw, known_ids: Dictionary) -> Dictionary:
	var ids: Array = []
	var seen := {}
	for entry in raw:
		var id := str(entry)
		if id == "" or seen.has(id) or not known_ids.has(id):
			continue
		seen[id] = true
		ids.append(id)
	if ids.is_empty():
		return {"ok": true, "error": "", "ids": []}
	if ids.size() < MIN_SIZE:
		return {"ok": false, "error": "cube_too_small", "ids": []}
	return {"ok": true, "error": "", "ids": ids}


## Build the card-dict pool a GameEngine should run on.
##   all_cards - the full card list (CardLoader.load_cards())
##   cube_ids  - sanitized cube ids, or [] for "use everything"
## Cards are returned in `all_cards` order; unknown ids in `cube_ids` are
## silently skipped (sanitize() should have removed them already).
static func filter_pool(all_cards: Array, cube_ids) -> Array:
	if cube_ids == null or (cube_ids is Array and (cube_ids as Array).is_empty()):
		return all_cards
	var want := {}
	for id in cube_ids:
		want[str(id)] = true
	var pool: Array = []
	for c in all_cards:
		if c is Dictionary and want.has(str(c.get("id", ""))):
			pool.append(c)
	return pool


## Set of every real card id, from a card list. Handy for sanitize()'s
## `known_ids` argument.
static func id_set(all_cards: Array) -> Dictionary:
	var s := {}
	for c in all_cards:
		if c is Dictionary and c.has("id"):
			s[str(c["id"])] = true
	return s
