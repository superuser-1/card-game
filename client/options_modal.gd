extends Control
## Modal overlay for game options (audio, display, session actions).
## Instantiated by Session.open_options() under a CanvasLayer.

@onready var volume_slider: HSlider = %VolumeSlider
@onready var sfx_slider: HSlider = %SfxSlider
@onready var music_slider: HSlider = %MusicSlider
@onready var mute_toggle: CheckButton = %MuteToggle
@onready var mute_unfocused_toggle: CheckButton = %MuteUnfocusedToggle
@onready var fullscreen_toggle: CheckButton = %FullscreenToggle
@onready var borderless_toggle: CheckButton = %BorderlessToggle
@onready var vsync_toggle: CheckButton = %VsyncToggle
@onready var fps_cap_option: OptionButton = %FpsCapOption
@onready var logout_button: Button = %LogoutButton
@onready var quit_button: Button = %QuitButton
@onready var close_button: Button = %CloseButton


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Load current settings into controls
	volume_slider.value = Session.settings.get("master_volume", 0.8)
	sfx_slider.value = Session.settings.get("sfx_volume", 0.8)
	music_slider.value = Session.settings.get("music_volume", 0.5)
	mute_toggle.button_pressed = Session.settings.get("muted", false)
	mute_unfocused_toggle.button_pressed = Session.settings.get("mute_unfocused", false)
	fullscreen_toggle.button_pressed = Session.settings.get("fullscreen", false)
	borderless_toggle.button_pressed = Session.settings.get("borderless", false)
	vsync_toggle.button_pressed = Session.settings.get("vsync", true)
	_select_fps_cap(int(Session.settings.get("fps_cap", 0)))

	# Connect signal handlers
	volume_slider.value_changed.connect(_on_volume_changed)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	music_slider.value_changed.connect(_on_music_changed)
	mute_toggle.toggled.connect(_on_bool_setting.bind("muted"))
	mute_unfocused_toggle.toggled.connect(_on_bool_setting.bind("mute_unfocused"))
	fullscreen_toggle.toggled.connect(_on_bool_setting.bind("fullscreen"))
	borderless_toggle.toggled.connect(_on_bool_setting.bind("borderless"))
	vsync_toggle.toggled.connect(_on_bool_setting.bind("vsync"))
	fps_cap_option.item_selected.connect(_on_fps_cap_selected)
	logout_button.pressed.connect(_on_logout)
	quit_button.pressed.connect(_on_quit)
	close_button.pressed.connect(_on_close)


func _select_fps_cap(value: int) -> void:
	for i in fps_cap_option.item_count:
		if fps_cap_option.get_item_id(i) == value:
			fps_cap_option.select(i)
			return
	fps_cap_option.select(0)  # fall back to "Uncapped"


func _apply(key: String, value) -> void:
	Session.settings[key] = value
	Session.save_settings()
	Session.apply_settings()


func _on_volume_changed(value: float) -> void:
	_apply("master_volume", value)


func _on_sfx_changed(value: float) -> void:
	_apply("sfx_volume", value)


func _on_music_changed(value: float) -> void:
	_apply("music_volume", value)


func _on_bool_setting(pressed: bool, key: String) -> void:
	_apply(key, pressed)


func _on_fps_cap_selected(index: int) -> void:
	_apply("fps_cap", fps_cap_option.get_item_id(index))


func _on_logout() -> void:
	_teardown()
	Session.clear()
	Session.goto("res://client/login_screen.tscn")


func _on_quit() -> void:
	get_tree().quit()


func _on_close() -> void:
	_teardown()


func _teardown() -> void:
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
