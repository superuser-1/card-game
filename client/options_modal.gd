extends Control
## Modal overlay for game options (volume, fullscreen, singleplayer reveal mode).
## Instantiated by Session.open_options() under a CanvasLayer.

@onready var volume_slider: HSlider = %VolumeSlider
@onready var fullscreen_toggle: CheckButton = %FullscreenToggle
@onready var reveal_toggle: CheckButton = %RevealToggle
@onready var close_button: Button = %CloseButton
@onready var account_line: Label = %AccountLine


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Load current settings into controls
	volume_slider.value = Session.settings.master_volume
	fullscreen_toggle.button_pressed = Session.settings.fullscreen
	reveal_toggle.button_pressed = Session.settings.sp_reveal_mode

	# Populate account display
	if Session.account.is_empty():
		account_line.text = "Not signed in"
	else:
		account_line.text = "Signed in as %s" % Session.account.get("display_name", "guest")

	# Connect signal handlers
	volume_slider.value_changed.connect(_on_volume_changed)
	fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)
	reveal_toggle.toggled.connect(_on_reveal_toggled)
	close_button.pressed.connect(_on_close)


func _on_volume_changed(value: float) -> void:
	Session.settings["master_volume"] = value
	Session.save_settings()
	Session.apply_settings()


func _on_fullscreen_toggled(pressed: bool) -> void:
	Session.settings["fullscreen"] = pressed
	Session.save_settings()
	Session.apply_settings()


func _on_reveal_toggled(pressed: bool) -> void:
	Session.settings["sp_reveal_mode"] = pressed
	Session.save_settings()
	Session.apply_settings()


func _on_close() -> void:
	## Tear down the overlay. Modal is a child of CanvasLayer "OptionsModalLayer"
	## on the root; free the layer (and modal with it), or fall back to freeing self.
	var layer := get_tree().root.get_node_or_null("OptionsModalLayer")
	if layer:
		layer.queue_free()
	else:
		queue_free()


func _unhandled_input(event: InputEvent) -> void:
	## Allow closing with ui_cancel action (Escape key by default).
	if event.is_action_pressed("ui_cancel"):
		_on_close()
		get_viewport().set_input_as_handled()
