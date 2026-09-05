class_name TableCardView
extends PanelContainer
## A card shown on the table during round resolution (left = active player's
## card, right = responder's, per game_ui.gd's choreography). Starts face
## down, flips to reveal art + the category's value, then can be colored
## win/lose and animated accordingly. Pure animation component — holds no
## game logic, just plays whatever game_ui.gd tells it to.

const CARD_SIZE := Vector2(240, 340)
const FLIP_HALF_TIME := 0.225
const LUNGE_TIME := 0.18   # the "beating" attack motion — deliberately kept at original speed
const DESTROY_TIME := 0.525

const WIN_COLOR := Color(0.36, 0.82, 0.4)
const LOSE_COLOR := Color(0.88, 0.32, 0.32)
const TIE_COLOR := Color(0.85, 0.75, 0.3)

@onready var _back_rect: TextureRect = %BackRect
@onready var _front: Control = %Front
@onready var _art_rect: TextureRect = %ArtRect
@onready var _name_label: Label = %NameLabel
@onready var _value_frame: PanelContainer = %ValueFrame
@onready var _value_label: Label = %ValueLabel

var _base_position: Vector2 = Vector2.ZERO
# The scene's StyleBoxFlat resource is shared across every instance unless
# duplicated — mutating border_color directly on the shared one would recolor
# every TableCardView's backplate at once, not just this card's.
var _value_style: StyleBoxFlat


func _ready() -> void:
	custom_minimum_size = CARD_SIZE
	size = CARD_SIZE
	pivot_offset = CARD_SIZE / 2.0
	_front.visible = false
	_back_rect.visible = true
	_value_label.text = ""

	_value_style = _value_frame.get_theme_stylebox("panel").duplicate()
	_value_frame.add_theme_stylebox_override("panel", _value_style)

	resized.connect(_on_resized)


## Guards against the "renders too big for a moment, then snaps to correct
## size" glitch: PanelContainer can recompute its own minimum size from its
## children (e.g. once NameLabel/ValueLabel actually get real text) on a
## later frame than _ready(), silently growing size past CARD_SIZE with
## nothing to correct it back down. Actively re-asserting here — rather than
## only setting it once in _ready() — means any such resize snaps back
## immediately instead of being visible for a frame or more.
func _on_resized() -> void:
	if size != CARD_SIZE:
		size = CARD_SIZE


func show_face_down() -> void:
	_base_position = position
	modulate = Color(1, 1, 1, 1)
	scale = Vector2(1, 1)
	rotation = 0.0
	_front.visible = false
	_back_rect.visible = true


## Flips face up (a quick scale-X squash-through-zero, like a physical card
## turning over) and reveals the art, a caption, and this category's value.
## `name_text` is the caption above the value — normally the movie title, but
## game_ui passes the director name(s) for the director-based categories. Falls
## back to the card's title when empty.
func flip_to_face_up(card: Dictionary, value_text: String, name_text := "") -> void:
	var tween := create_tween()
	tween.tween_property(self, "scale:x", 0.0, FLIP_HALF_TIME).set_trans(Tween.TRANS_SINE)
	await tween.finished

	_art_rect.texture = load(CardArt.path_for(card))
	_name_label.text = name_text if name_text != "" else str(card.get("title", ""))
	_value_label.text = value_text
	_back_rect.visible = false
	_front.visible = true

	var tween2 := create_tween()
	tween2.tween_property(self, "scale:x", 1.0, FLIP_HALF_TIME).set_trans(Tween.TRANS_SINE)
	await tween2.finished


func set_outcome_color(color: Color) -> void:
	_value_label.add_theme_color_override("font_color", color)
	_value_style.border_color = color


## Winner's "beating" motion: lunge toward the loser and snap back.
func play_attack(target_global_position: Vector2) -> void:
	var start := position
	var direction := (target_global_position - global_position)
	var lunge_offset := direction * 0.35

	var tween := create_tween()
	tween.tween_property(self, "position", start + lunge_offset, LUNGE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "position", start, LUNGE_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tween.finished


## Loser gets "destroyed": violent wobble, shrink, darken, fade out.
func play_destroyed() -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "rotation_degrees", 25.0, DESTROY_TIME * 0.3).set_trans(Tween.TRANS_QUAD)
	tween.chain().tween_property(self, "rotation_degrees", -20.0, DESTROY_TIME * 0.3).set_trans(Tween.TRANS_QUAD)

	var shrink_tween := create_tween()
	shrink_tween.set_parallel(true)
	shrink_tween.tween_property(self, "scale", Vector2(0.05, 0.05), DESTROY_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	shrink_tween.tween_property(self, "modulate", Color(0.3, 0.1, 0.1, 0.0), DESTROY_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await shrink_tween.finished


## Winner just fades out calmly when the table clears (no destroy drama).
func play_calm_fade_out() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, DESTROY_TIME)
	await tween.finished
