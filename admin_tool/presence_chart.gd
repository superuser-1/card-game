extends Control
## Minimal hand-drawn line chart for the admin tool's Stats tab — a plain
## Control's _draw() override, no charting library (keeps the tool
## dependency-free). samples: Array of {ts:int, count:int}, oldest first.

var samples: Array = []

const MARGIN_LEFT := 34.0
const MARGIN_BOTTOM := 20.0
const MARGIN_TOP := 14.0
const MARGIN_RIGHT := 10.0
const LINE_COLOR := Color(0.35, 0.75, 1.0)
const FILL_COLOR := Color(0.35, 0.75, 1.0, 0.15)
const AXIS_COLOR := Color(1, 1, 1, 0.25)
const LABEL_COLOR := Color(1, 1, 1, 0.65)


func set_samples(new_samples: Array) -> void:
	samples = new_samples
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	var plot_bottom := h - MARGIN_BOTTOM
	draw_line(Vector2(MARGIN_LEFT, plot_bottom), Vector2(w - MARGIN_RIGHT, plot_bottom), AXIS_COLOR, 1.0)
	draw_line(Vector2(MARGIN_LEFT, MARGIN_TOP), Vector2(MARGIN_LEFT, plot_bottom), AXIS_COLOR, 1.0)

	var font := ThemeDB.fallback_font
	if samples.size() < 2:
		draw_string(font, Vector2(MARGIN_LEFT + 8, h * 0.5), "No data yet for this range.", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, LABEL_COLOR)
		return

	var max_count := 1
	var min_ts: int = int(samples[0].get("ts", 0))
	var max_ts: int = int(samples[-1].get("ts", 0))
	for s in samples:
		max_count = maxi(max_count, int(s.get("count", 0)))
	var ts_span := maxi(1, max_ts - min_ts)

	var plot_w := w - MARGIN_LEFT - MARGIN_RIGHT
	var plot_h := plot_bottom - MARGIN_TOP

	var points := PackedVector2Array()
	for s in samples:
		var t := int(s.get("ts", 0))
		var c := int(s.get("count", 0))
		var x := MARGIN_LEFT + (float(t - min_ts) / float(ts_span)) * plot_w
		var y := plot_bottom - (float(c) / float(max_count)) * plot_h
		points.append(Vector2(x, y))

	# Light fill under the line so the shape reads at a glance.
	var fill := PackedVector2Array(points)
	fill.append(Vector2(points[-1].x, plot_bottom))
	fill.append(Vector2(points[0].x, plot_bottom))
	draw_colored_polygon(fill, FILL_COLOR)
	draw_polyline(points, LINE_COLOR, 2.0, true)

	draw_string(font, Vector2(4, MARGIN_TOP + 10), str(max_count), HORIZONTAL_ALIGNMENT_LEFT, MARGIN_LEFT - 6, 11, LABEL_COLOR)
	draw_string(font, Vector2(4, plot_bottom + 4), "0", HORIZONTAL_ALIGNMENT_LEFT, MARGIN_LEFT - 6, 11, LABEL_COLOR)
