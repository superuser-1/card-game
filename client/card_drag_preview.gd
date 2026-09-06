class_name CardDragPreview
extends Control
## The floating visual that follows the cursor during a card drag. Godot's
## drag manager overwrites THIS node's position every frame to track the
## mouse, so this node itself stays an invisible anchor whose local origin
## (0,0) is always exactly the cursor — that's also its default rotation/
## scale pivot. The actual card visual is a child offset from that origin
## (so the cursor sits at its top-center, not its top-left corner), and
## rotating/scaling this anchor swings the whole card around the cursor.
## Everything below is a spring-damper on rotation driven by horizontal
## mouse velocity, so the card tilts and lags/settles like it has weight.

const ROTATION_FACTOR := 0.0012          # radians of tilt per px/sec of horizontal velocity
const MAX_ROTATION := 0.14               # ~8 degrees, clamps how far it can lean
const SPRING_STIFFNESS := 25.0
const SPRING_DAMPING_PER_SEC := 6.0
const LIFT_SCALE := 1.1                  # slightly bigger, like it's been picked up off the table

# Where card_border1.png's opaque frame sits vs. its transparent interior
# cutout, as fractions of its own size — matches the inset used in
# card_view.tscn/table_card_view.tscn so the art aligns with the frame the
# same way everywhere: no card background showing through the frame's edges,
# and no art spilling past it.
const BORDER_LEFT := 0.0569
const BORDER_TOP := 0.0404
const BORDER_RIGHT := 0.9408
const BORDER_BOTTOM := 0.9684
# The name/year overlay sits in the lower third of the ART region (not the
# whole card) — same convention as card_view.tscn's InfoOverlay.
const OVERLAY_TOP := BORDER_BOTTOM - (BORDER_BOTTOM - BORDER_TOP) / 3.0

var _visual: Control
var _art: TextureRect
var _border: TextureRect
var _backplate: ColorRect
var _name_label: Label
var _director_label: Label

var _art_position: Vector2
var _art_size: Vector2
var _border_size: Vector2
var _overlay_position: Vector2
var _overlay_size: Vector2

var _last_mouse_pos: Vector2
var _angular_velocity := 0.0
var _current_rotation := 0.0


func _init(texture: Texture2D, title: String, director: String) -> void:
	var preview_size := Vector2(90, 130) * 1.36  # 4x the previous (too-small) size
	scale = Vector2(LIFT_SCALE, LIFT_SCALE)

	_visual = Control.new()
	_visual.size = preview_size
	_visual.custom_minimum_size = preview_size
	_visual.position = Vector2(-preview_size.x / 2.0, -preview_size.y / 4.0)
	_visual.clip_contents = true  # belt-and-suspenders: nothing draws outside our small box, period
	add_child(_visual)

	# Art bleeds a few px past the border on every side (then clipped to
	# _visual) so the frame — drawn on top — never leaves a gap where the
	# background shows through the ornate border's inner edge.
	_art_position = Vector2(-4, -4)
	_art_size = preview_size + Vector2(8, 8)
	_border_size = preview_size
	_overlay_position = Vector2(preview_size.x * BORDER_LEFT, preview_size.y * OVERLAY_TOP)
	_overlay_size = Vector2(preview_size.x * (BORDER_RIGHT - BORDER_LEFT), preview_size.y * (BORDER_BOTTOM - OVERLAY_TOP))

	_art = TextureRect.new()
	_art.texture = texture
	_art.position = _art_position
	_art.size = _art_size
	_art.custom_minimum_size = _art_size
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.modulate = Color(1, 1, 1, 0.9)
	_art.clip_contents = true
	_visual.add_child(_art)

	_border = TextureRect.new()
	_border.texture = load("res://assets/cards/card_border1.png")
	_border.size = _border_size
	_border.custom_minimum_size = _border_size
	_border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_border.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_border.stretch_mode = TextureRect.STRETCH_SCALE
	_border.modulate = Color(1, 1, 1, 0.9)
	_visual.add_child(_border)

	_backplate = ColorRect.new()
	_backplate.position = _overlay_position
	_backplate.size = _overlay_size
	_backplate.color = Color(0, 0, 0, 0.55 * 0.9)  # matches the 0.9 modulate the art/border use
	_backplate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_visual.add_child(_backplate)

	_name_label = Label.new()
	_name_label.text = title
	_name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	_name_label.add_theme_font_size_override("font_size", 8)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name_label.clip_text = true
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_visual.add_child(_name_label)

	_director_label = Label.new()
	_director_label.text = director
	_director_label.add_theme_color_override("font_color", Color(0.82, 0.82, 0.82, 1))
	_director_label.add_theme_font_size_override("font_size", 6)
	_director_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_director_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_director_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_visual.add_child(_director_label)

	_layout_overlay_text()


## Splits _overlay_size/_position between the two labels (name on top,
## director below), called both here and again in _ready() (see the note
## there about why sizes/positions need re-asserting after tree entry).
func _layout_overlay_text() -> void:
	var director_h := _overlay_size.y * 0.35
	var name_h := _overlay_size.y - director_h
	_name_label.position = _overlay_position
	_name_label.size = Vector2(_overlay_size.x, name_h)
	_director_label.position = _overlay_position + Vector2(0, name_h)
	_director_label.size = Vector2(_overlay_size.x, director_h)


func _ready() -> void:
	_last_mouse_pos = get_viewport().get_mouse_position()
	# Re-assert every size/position after entering the tree — Control nodes
	# built entirely in code like this one can have their size recomputed
	# once they actually enter the tree (theme defaults, minimum-size
	# recalculation), which silently overrode _art's small inset size before
	# this fix — the art would then render at something close to its full
	# native resolution while still clipped by _visual's small box, reading
	# as "zoomed into the image's top-left corner" instead of the full card.
	_visual.size = _visual.custom_minimum_size
	_art.position = _art_position
	_art.size = _art_size
	_border.size = _border_size
	_backplate.position = _overlay_position
	_backplate.size = _overlay_size
	_layout_overlay_text()

	# Godot auto-swaps the OS cursor to a forbidden/can-drop icon while
	# dragging. This preview only exists for the duration of the drag, so
	# blanking those two cursor shapes here and restoring them on exit hides
	# that icon without touching the cursor at any other time.
	var blank := ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	Input.set_custom_mouse_cursor(blank, Input.CURSOR_FORBIDDEN)
	Input.set_custom_mouse_cursor(blank, Input.CURSOR_CAN_DROP)


func _exit_tree() -> void:
	Input.set_custom_mouse_cursor(null, Input.CURSOR_FORBIDDEN)
	Input.set_custom_mouse_cursor(null, Input.CURSOR_CAN_DROP)


func _process(delta: float) -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	var velocity := (mouse_pos - _last_mouse_pos) / maxf(delta, 1.0 / 240.0)
	_last_mouse_pos = mouse_pos

	var target_rotation: float = clampf(velocity.x * ROTATION_FACTOR, -MAX_ROTATION, MAX_ROTATION)
	_angular_velocity += (target_rotation - _current_rotation) * SPRING_STIFFNESS * delta
	_angular_velocity *= maxf(0.0, 1.0 - SPRING_DAMPING_PER_SEC * delta)
	_current_rotation += _angular_velocity * delta

	rotation = _current_rotation
