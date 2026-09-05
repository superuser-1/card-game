class_name CardArt
extends RefCounted
## Shared movie-art lookup. Art files are named after the movie title itself
## (not the card id) so whoever's adding artwork just needs to know the
## movie's name — no need to cross-reference ids in cards.json, and no
## renumbering headache when cards.json's id assignments shift. Falls back to
## the generic placeholder when no art exists yet for a given movie.

const PLACEHOLDER_PATH := "res://assets/cards/card_000.png"
const ART_DIR := "res://assets/cards/"

## Characters invalid in Windows filenames. Colon is the only one that shows
## up in our current movie titles (e.g. "Dune: Part Two"), but scrubbing the
## full set future-proofs against titles we haven't seen yet.
const INVALID_CHARS := ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]


static func sanitize_title(title: String) -> String:
	var result := title
	for ch in INVALID_CHARS:
		result = result.replace(ch, "")
	return result


## Returns the art path to load for this card: its title-named file if one
## exists, otherwise the shared placeholder.
static func path_for(card: Dictionary) -> String:
	var path := ART_DIR + sanitize_title(str(card.get("title", ""))) + ".png"
	if ResourceLoader.exists(path):
		return path
	return PLACEHOLDER_PATH
