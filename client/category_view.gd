class_name CategoryView
extends PanelContainer
## A category drop target. When shown as one of the 3 offered choices it
## accepts a dragged hand card (see CardView._get_drag_data) and emits
## card_dropped with that card's id — the caller (game_ui.gd) is the one that
## actually submits the move. When shown as the single already-chosen
## category (served to the responder, or lingering on the active player's own
## screen) it's just a display, not a drop target.

signal card_dropped(card_id: String)

const DISPLAY_NAME := {
	"most_oscars": "Most Oscars",
	"first_published": "First Published",
	"box_office": "Box Office",
	"longest_runtime": "Longest Runtime",
	"shortest_runtime": "Shortest Runtime",
	"highest_budget": "Highest Budget",
	"lowest_budget": "Lowest Budget",
	"highest_audience_score": "Highest Audience Score",
	"director_oscars": "Director Oscar Wins",
	"oldest_director": "Oldest Director",
	"youngest_director": "Youngest Director",
	"profit_cost_ratio": "Profit to Cost Ratio",
}

@onready var _icon_rect: TextureRect = %IconRect
@onready var _name_label: Label = %NameLabel
@onready var _highlight_border: Control = %HighlightBorder

var category_key: String = ""
var is_drop_target: bool = false
var _highlight_tween: Tween


# Caption geometry inside the art frame — twin of CardView's constants (the
# scene reuses the card frame). Box height matches NameLabel.custom_minimum_size.
const NAME_WRAP_PX := 180.0
const NAME_BOX_PX := 88.0

func set_category(key: String, accepts_drops: bool) -> void:
	category_key = key
	is_drop_target = accepts_drops
	LabelFit.fit(_name_label, DISPLAY_NAME.get(key, key), NAME_WRAP_PX, NAME_BOX_PX, 22, 15)

	var icon_path := "res://assets/categories/%s.png" % key
	_icon_rect.texture = load(icon_path) if ResourceLoader.exists(icon_path) else null
	modulate = Color(1, 1, 1, 1) if accepts_drops else Color(1, 1, 1, 0.85)


func _can_drop_data(_at_position: Vector2, data) -> bool:
	return is_drop_target and data is Dictionary and data.get("type") == "hand_card"


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	card_dropped.emit(data.card_id)


func _ready() -> void:
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func _on_mouse_entered() -> void:
	if is_drop_target and get_viewport().gui_is_dragging():
		_start_highlight()


func _on_mouse_exited() -> void:
	_stop_highlight()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_stop_highlight()


func _start_highlight() -> void:
	_highlight_border.visible = true
	_highlight_border.modulate.a = 0.5
	if _highlight_tween:
		_highlight_tween.kill()
	_highlight_tween = create_tween().set_loops()
	_highlight_tween.tween_property(_highlight_border, "modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_SINE)
	_highlight_tween.tween_property(_highlight_border, "modulate:a", 0.5, 0.5).set_trans(Tween.TRANS_SINE)


func _stop_highlight() -> void:
	if _highlight_tween:
		_highlight_tween.kill()
		_highlight_tween = null
	_highlight_border.visible = false
