extends Control
## Read-only collection view. For now the only "deck" is the entire card
## database, shown non-editable. Deck creation / saving / per-deck card
## selection is a future milestone — intentionally not built here.

const CARD_VIEW_SCENE := preload("res://client/card_view.tscn")
const CARD_DISPLAY_SCALE := 0.62
const MAIN_MENU := "res://client/main_menu.tscn"

@onready var _grid: GridContainer = %CardGrid
@onready var _header: Label = %HeaderLabel
@onready var _back: Button = %BackButton


func _ready() -> void:
	_back.pressed.connect(func(): Session.goto(MAIN_MENU))

	var cards := CardLoader.load_cards("res://data/cards.json")

	if cards.is_empty():
		_header.text = "Deckbuilder — no cards found"
		return

	_header.text = "Deckbuilder — Full Collection (%d cards)" % cards.size()

	# Each card is wrapped in a Control container scaled to CARD_DISPLAY_SCALE.
	# This allows the grid to maintain consistent item sizing while displaying
	# cards at a smaller scale than their native CARD_SIZE (240x340). The wrapper
	# Control has custom_minimum_size set to the scaled size, and the CardView
	# child is scaled within it. This approach keeps the grid layout clean and
	# allows easy adjustment of the scale constant without modifying CardView itself.
	for card: Dictionary in cards:
		var wrapper := Control.new()
		wrapper.custom_minimum_size = CardView.CARD_SIZE * CARD_DISPLAY_SCALE
		var card_view: CardView = CARD_VIEW_SCENE.instantiate()
		wrapper.add_child(card_view)
		_grid.add_child(wrapper)
		# set_card touches @onready node refs, so it must run only after the
		# CardView is in the tree and its _ready() has resolved them.
		card_view.scale = Vector2(CARD_DISPLAY_SCALE, CARD_DISPLAY_SCALE)
		card_view.set_card(card)
		card_view.disabled = true
