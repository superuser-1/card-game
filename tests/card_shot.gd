extends Node
## Dev-only: render CardView / TableCardView / CategoryView side by side with
## short, long and pathological titles so the caption-fit + uniform-frame work
## can be eyeballed.
##   godot --path . tests/card_shot.tscn   -> user://card_shot.png

const CARD_VIEW := preload("res://client/card_view.tscn")
const CATEGORY_VIEW := preload("res://client/category_view.tscn")
const TABLE_CARD := preload("res://client/table_card_view.tscn")

func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(2480, 460))
	RenderingServer.set_default_clear_color(Color(0.13, 0.14, 0.17))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	row.position = Vector2(30, 40)
	add_child(row)

	var titles := [
		{"title": "Her", "director": "Spike Jonze"},
		{"title": "War and Peace - UdSSR 4 Parts", "director": "Sergei Bondarchuk"},
		{"title": "Captain America: The Winter Soldier", "director": "Anthony Russo and Joe Russo"},
		{"title": "Puella Magi Madoka Magica the Movie Part III Rebellion", "director": "Akiyuki Shinbo"},
	]
	for t in titles:
		var c := CARD_VIEW.instantiate()
		row.add_child(c)
		c.set_card(t, true)

	var cats := ["box_office", "highest_audience_score", "profit_cost_ratio", "director_oscars"]
	for key in cats:
		var cv := CATEGORY_VIEW.instantiate()
		row.add_child(cv)
		cv.set_category(key, true)

	# TableCardView needs a couple of frames + its flip to populate the face.
	var tc := TABLE_CARD.instantiate()
	row.add_child(tc)
	await get_tree().process_frame
	tc.flip_to_face_up(titles[3], "$2,717,503,922", "")

	await get_tree().create_timer(0.8).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://card_shot.png")
	print("SHOT: ", ProjectSettings.globalize_path("user://card_shot.png"))
	get_tree().quit()
