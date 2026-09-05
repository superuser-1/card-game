extends Node
## Dev-only: render the main menu with a fake logged-in account and dump a PNG
## so layout can be eyeballed without standing up a server.
##   godot --path . tests/menu_shot.tscn   -> user://menu_shot.png

func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))

	Session.account = {
		"display_name": "PlayerOne", "elo": 1042,
		"wins": 7, "losses": 3, "draws": 1, "points": 88,
		"avatar": "avatar_female_02",
		"quests": [
			{"id": "money_game", "name": "Win a Money Game", "progress": 0, "target": 1, "points": 40, "completed": false},
			{"id": "perfect_loss", "name": "Lose a Game 0–7", "progress": 0, "target": 1, "points": 60, "completed": false},
			{"id": "win_3", "name": "Win 3 Games", "progress": 3, "target": 3, "points": 40, "completed": true},
		],
	}
	Session.token = "debug"

	var menu: Control = load("res://client/main_menu.tscn").instantiate()
	add_child(menu)

	await get_tree().create_timer(0.7).timeout

	# also capture the multiplayer submenu
	if menu.has_method("_show_multiplayer"):
		menu._show_multiplayer()
		await get_tree().create_timer(0.5).timeout
		get_viewport().get_texture().get_image().save_png("user://menu_shot_mp.png")
		print("SHOT-MP: ", ProjectSettings.globalize_path("user://menu_shot_mp.png"))
		menu._show_main()
		await get_tree().process_frame

	var img := get_viewport().get_texture().get_image()
	img.save_png("user://menu_shot.png")
	print("SHOT: ", ProjectSettings.globalize_path("user://menu_shot.png"))
	get_tree().quit()
