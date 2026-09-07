class_name CardView
extends PanelContainer

signal pressed
## Emitted on WHICHEVER CardView Godot's hit-testing happens to find under
## the cursor while a hand-card reorder drag is hovering — game_ui.gd
## ignores which specific card this was and recomputes the insertion index
## from the actual cursor position instead. That's deliberate: hand cards
## heavily overlap (with z-ordering to match), so "trust whichever card
## caught the hover" was unreliable — a card mostly covered by its neighbor
## could silently steal it. Godot only calls _can_drop_data on the single
## topmost control under the cursor (it does NOT fall back to the parent if
## that control declines), so this still has to live per-card to reliably
## receive the callback at all — it just no longer trusts `self` as the
## answer to "where."
signal reorder_hover_anywhere(dragged_card_id: String)
signal reorder_drop_anywhere(dragged_card_id: String)
## Emitted on the ORIGINAL (source) card once any drag that started here has
## ended, successful or not — game_ui.gd uses this to know when to revert an
## uncommitted live-preview reorder.
signal drag_ended

const CARD_SIZE := Vector2(240, 340)
const HOVER_SCALE_MULT := 1.18   # grows relative to whatever scale the hand fan gave this card
const HOVER_LIFT_PX := 26.0
const HOVER_TWEEN_TIME := 0.12
const REORDER_TWEEN_TIME := 0.2   # a touch slower than hover — reads as cards "sliding" into place
const DRAGGING_ALPHA := 0.35   # how much the original fades while its preview follows the cursor

@onready var art_rect: TextureRect = %ArtRect
@onready var name_label: Label = %NameLabel
@onready var director_label: Label = %DirectorLabel

var disabled: bool = false:
	set(value):
		disabled = value
		modulate = Color(1, 1, 1, 0.5) if disabled else Color(1, 1, 1, 1)

## When true, this card can be dragged onto a CategoryView drop target
## (the active player choosing a category+card together). When false it's
## click-to-play instead (the responder answering a category that's already
## been chosen — there's nothing to drop it onto).
var draggable: bool = false

## The hover-enlarge/lift animation only makes sense for a card sitting in the
## hand fan (where set_hand_transform() has seeded _base_position/_hand_scale).
## Static grids like the deckbuilder scale the card down directly and never call
## set_hand_transform(), so hovering would tween it to _hand_scale (1.0) and
## leave it stuck enlarged. Those callers set this false.
var hover_enabled: bool = true

var _card: Dictionary = {}

# The fan-layout "rest" transform this card should return to after a hover.
# Rotation pivots around bottom-center (set once in _ready) so scaling and
# rotating both read as the card swinging/growing from where a hand would
# hold it, matching the drag-preview physics in card_drag_preview.gd.
var _hand_scale: float = 1.0
var _base_position: Vector2 = Vector2.ZERO
var _base_rotation_deg: float = 0.0
var _base_z_index: int = 0
var _hover_tween: Tween


func _ready() -> void:
	# Explicit, since our parent (the hand-fan's Control) isn't a Container
	# and won't auto-size us to our minimum size the way HBoxContainer would.
	# Without this we're positioned correctly by set_hand_transform() but
	# render at 0x0 — invisible.
	custom_minimum_size = CARD_SIZE
	size = CARD_SIZE
	pivot_offset = Vector2(CARD_SIZE.x / 2.0, CARD_SIZE.y)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func set_card(card: Dictionary, load_art := true) -> void:
	_card = card
	name_label.text = str(card.get("title", ""))
	director_label.text = str(card.get("director", ""))
	if load_art:
		apply_art()


## Load + assign this card's art. Split out from set_card() so grids with many
## cards can set every card's text up front (cheap) and then stream the art in
## over several frames instead of blocking on ~200 synchronous texture loads.
func apply_art() -> void:
	if _card.is_empty():
		return
	art_rect.texture = load(CardArt.path_for(_card))


## Places this card at its resting spot in the hand fan, instantly. Called
## once per render by game_ui.gd's fan layout; hover animates away from and
## back to whatever was set here.
func set_hand_transform(pos: Vector2, rot_degrees: float, hand_scale: float, z: int) -> void:
	_base_position = pos
	_base_rotation_deg = rot_degrees
	_hand_scale = hand_scale
	_base_z_index = z
	position = pos
	rotation_degrees = rot_degrees
	scale = Vector2(hand_scale, hand_scale)
	z_index = z


## Same as set_hand_transform, but eases into the new spot instead of
## snapping — used for the live drag-reorder preview, so other cards visibly
## slide out of the way instead of jump-cutting.
func tween_to_hand_transform(pos: Vector2, rot_degrees: float, hand_scale: float, z: int) -> void:
	_base_position = pos
	_base_rotation_deg = rot_degrees
	_hand_scale = hand_scale
	_base_z_index = z
	z_index = z

	if _hover_tween:
		_hover_tween.kill()
	_hover_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(self, "position", pos, REORDER_TWEEN_TIME)
	_hover_tween.tween_property(self, "rotation_degrees", rot_degrees, REORDER_TWEEN_TIME)
	_hover_tween.tween_property(self, "scale", Vector2(hand_scale, hand_scale), REORDER_TWEEN_TIME)


func _on_mouse_entered() -> void:
	# Godot keeps tracking mouse_entered/exited even mid-drag (it's the same
	# underlying "control under mouse" bookkeeping that drives _can_drop_data
	# hit-testing), so without this guard, dragging card A over card B fires
	# B's hover-enlarge at the exact same time the reorder-preview is trying
	# to tween B to a new slot — both write _base_position/_hover_tween, so
	# whichever happens to run last wins, which is exactly the inconsistent
	# behavior this was producing. Hover-enlarge only makes sense with a
	# free cursor, not mid-reorder.
	if disabled or not hover_enabled or get_viewport().gui_is_dragging():
		return
	_animate_hover(true)


func _on_mouse_exited() -> void:
	# Deliberately NOT guarded by gui_is_dragging(): if this card was already
	# hover-enlarged right as a drag started elsewhere, we still want it to
	# settle back to its base transform once the cursor actually leaves —
	# otherwise it'd stay stuck visually enlarged for the rest of the drag.
	if not hover_enabled:
		return
	_animate_hover(false)


func _animate_hover(hovering: bool) -> void:
	if _hover_tween:
		_hover_tween.kill()

	var target_scale := _hand_scale * HOVER_SCALE_MULT if hovering else _hand_scale
	var target_pos := _base_position - Vector2(0, HOVER_LIFT_PX) if hovering else _base_position
	var target_rot := 0.0 if hovering else _base_rotation_deg
	z_index = 100 if hovering else _base_z_index

	_hover_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(self, "scale", Vector2(target_scale, target_scale), HOVER_TWEEN_TIME)
	_hover_tween.tween_property(self, "position", target_pos, HOVER_TWEEN_TIME)
	_hover_tween.tween_property(self, "rotation_degrees", target_rot, HOVER_TWEEN_TIME)


func _gui_input(event: InputEvent) -> void:
	if disabled or draggable:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit()


func _get_drag_data(_at_position: Vector2) -> Variant:
	if disabled or not draggable:
		return null

	set_drag_preview(CardDragPreview.new(art_rect.texture, str(_card.get("title", "")), str(_card.get("director", ""))))
	# Fade the original so the drag reads as "this card is being lifted out
	# of the hand," not "a duplicate is following the cursor." Restored in
	# _notification() once the drag ends, whether it succeeded or not — on
	# success this card is about to be removed by the next state update
	# anyway, so restoring is harmless; on failure it needs to look normal
	# again since it's staying put.
	modulate.a = DRAGGING_ALPHA

	return {"type": "hand_card", "card_id": _card.get("id", "")}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	var is_hand_card_drag: bool = draggable and data is Dictionary and data.get("type") == "hand_card" \
		and data.get("card_id") != _card.get("id", "")
	if is_hand_card_drag:
		reorder_hover_anywhere.emit(data.card_id)
	return is_hand_card_drag


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	reorder_drop_anywhere.emit(data.card_id)


func _notification(what: int) -> void:
	# Fires on the ORIGINAL card (still sitting in hand) when a drag that
	# started here ends.
	if what == NOTIFICATION_DRAG_END:
		modulate.a = 1.0
		drag_ended.emit()
		# If it wasn't dropped on a valid target, shake so it reads as
		# "rejected" rather than nothing happening. A successful reorder
		# drop is also not a "real" drag-and-submit, so it's treated the
		# same as a miss here too — no shake either way in that case, since
		# gui_is_drag_successful() is true for ANY accepted drop, including
		# reorder ones, and a reorder isn't a rejection.
		if not get_viewport().gui_is_drag_successful():
			_play_reject_shake()


func _play_reject_shake() -> void:
	var tween := create_tween()
	tween.tween_property(self, "rotation", deg_to_rad(-5.0), 0.1)
	tween.tween_property(self, "rotation", deg_to_rad(5.0), 0.1)
	tween.tween_property(self, "rotation", deg_to_rad(-3.0), 0.1)
	tween.tween_property(self, "rotation", 0.0, 0.1)
