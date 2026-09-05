extends Control

const TOURNAMENT_CREATION_MODAL := preload("res://client/tournament_creation_modal.tscn")


func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	%CreateTournamentButton.pressed.connect(_open_tournament_creation)


func _open_tournament_creation() -> void:
	var layer := CanvasLayer.new()
	layer.name = "TournamentCreationLayer"
	layer.layer = 100
	var modal: Control = TOURNAMENT_CREATION_MODAL.instantiate()
	modal.tree_exited.connect(layer.queue_free)
	layer.add_child(modal)
	add_child(layer)


func _toast(msg: String) -> void:
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.anchor_left = 0.4
	box.anchor_right = 0.4
	box.anchor_top = 0.86
	box.anchor_bottom = 0.86
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.07, 0.92)
	sb.border_color = Color(1, 1, 1, 0.15)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(10)
	box.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = msg
	lbl.add_theme_font_size_override("font_size", 15)
	box.add_child(lbl)
	add_child(box)

	box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(box, "modulate:a", 1.0, 0.15)
	tw.tween_interval(1.4)
	tw.tween_property(box, "modulate:a", 0.0, 0.4)
	await tw.finished
	box.queue_free()
