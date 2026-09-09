class_name CardLoader


# Cards flagged `streaming_release` are direct-to-streaming titles (Netflix
# originals etc.) whose theatrical box office is a token awards run or nothing —
# not a meaningful stat — so they are kept out of every playable pool. Pass
# include_streaming = true only for data tooling that needs the full list.
static func load_cards(path: String = "res://data/cards.json", include_streaming: bool = false) -> Array:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("CardLoader: Failed to open file at %s" % path)
		return []

	var json_string = file.get_as_text()
	var json = JSON.parse_string(json_string)

	if json == null:
		push_error("CardLoader: Failed to parse JSON from %s" % path)
		return []

	if not json is Dictionary or not json.has("cards"):
		push_error("CardLoader: JSON does not contain a 'cards' key")
		return []

	var cards = json["cards"]
	if not cards is Array:
		push_error("CardLoader: 'cards' key is not an array")
		return []

	# JSON numbers parse as float; every numeric card stat is a whole number,
	# so coerce them to int here — one place — for clean display (no "1994.0")
	# and integer comparisons everywhere downstream. Nullable fields stay null.
	const INT_FIELDS := [
		"release_year", "runtime_minutes", "oscars_won", "box_office_usd", "budget_usd",
		"audience_score", "director_oscars_won", "director_birth_year", "director_age_at_release",
		"profit_cost_ratio_pct",
	]
	for card in cards:
		if card is Dictionary:
			for f in INT_FIELDS:
				if card.get(f) != null:
					card[f] = int(card[f])

	if include_streaming:
		return cards

	var playable: Array = []
	for card in cards:
		if card is Dictionary and bool(card.get("streaming_release", false)):
			continue
		playable.append(card)
	return playable
