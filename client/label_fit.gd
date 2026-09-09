class_name LabelFit
extends RefCounted
## Fit arbitrary-length text into a fixed-size caption box.
##
## Card titles and director credits vary wildly in length ("Her" vs "Puella
## Magi Madoka Magica the Movie Part III Rebellion") but the caption boxes on
## CardView / TableCardView / CategoryView are a fixed pixel height. So we:
##   1. try the text at `max_size`, dropping the font one point at a time,
##   2. stop at the largest size whose word-wrapped block fits `box_height_px`,
##   3. if it still overflows at `min_size`, trim trailing words and append an
##      ellipsis until it fits.
##
## `wrap_width_px` / `box_height_px` are passed in rather than read off the
## label: the label's real size isn't known until its container lays out,
## which is a frame or more after set_card(). The caption box is a fixed
## fraction of the (fixed-size) card, so callers just hand us the constants —
## and they set the label's `custom_minimum_size.y` to the same box height so
## the row reserves exactly this space and never reflows.
##
## Wrapping is measured with TextParagraph (what Label uses internally), so
## the line count matches what actually renders.

## Sets `label.text` and a font_size override so the word-wrapped text fits
## within `box_height_px` at `wrap_width_px`. Assumes the label word-wraps
## (autowrap_mode = WORD or WORD_SMART) and is center-aligned.
static func fit(
	label: Label,
	text: String,
	wrap_width_px: float,
	box_height_px: float,
	max_size: int,
	min_size: int,
) -> void:
	var font := label.get_theme_font(&"font")
	if font == null:
		font = ThemeDB.fallback_font
	if text.strip_edges() == "":
		label.text = text
		return
	# Label advances each wrapped line by font height + the "line_spacing"
	# theme constant (3px by default); TextParagraph's line count alone misses
	# that, which is enough to clip the last line of a tight fit.
	var line_spacing := float(label.get_theme_constant(&"line_spacing"))

	for size in range(max_size, min_size - 1, -1):
		if _block_height(font, text, wrap_width_px, size, line_spacing) <= box_height_px:
			label.add_theme_font_size_override(&"font_size", size)
			label.text = text
			return

	# Still too tall even at min_size — shrink the string, not the font.
	label.add_theme_font_size_override(&"font_size", min_size)
	label.text = _ellipsize(font, text, wrap_width_px, box_height_px, min_size, line_spacing)


static func _block_height(font: Font, text: String, width: float, size: int, line_spacing: float) -> float:
	var tp := TextParagraph.new()
	tp.width = width
	tp.alignment = HORIZONTAL_ALIGNMENT_CENTER
	tp.add_string(text, font, size)
	return tp.get_line_count() * (font.get_height(size) + line_spacing)


static func _ellipsize(font: Font, text: String, width: float, max_h: float, size: int, line_spacing: float) -> String:
	var trimmed := text.strip_edges()
	while trimmed.length() > 1:
		var candidate := trimmed + "…"
		if _block_height(font, candidate, width, size, line_spacing) <= max_h:
			return candidate
		var cut := trimmed.rstrip(" ").rfind(" ")
		if cut > 0:
			trimmed = trimmed.substr(0, cut)
		else:
			trimmed = trimmed.substr(0, trimmed.length() - 1)
	return "…"
