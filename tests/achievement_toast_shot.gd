extends Node
## Dev-only: render the main menu with a queued achievement-unlock toast and
## dump PNGs at slide-in / hold / slide-out so the animation can be eyeballed
## without a server.
##   godot --path . tests/achievement_toast_shot.tscn
##   -> user://toast_in.png, toast_hold.png, toast_out.png

func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))

	Session.account = {
		"display_name": "PlayerOne", "elo": 1042,
		"wins": 51, "losses": 12, "draws": 1, "points": 640,
		"avatar": "avatar_female_02",
		"quests": [],
	}
	Session.token = "debug"
	Session.pending_achievement_toasts = [
		{"id": "ranked_win_50", "name": "50 Ranked Wins", "tier_name": "", "points": 150, "reward": ""},
		{"id": "ranked_loss_30", "name": "30 Ranked Losses", "tier_name": "", "points": 100, "reward": "30_ranked_losses_avatar"},
		{"id": "tourney_win_1", "name": "1 Tournament Win", "tier_name": "", "points": 100, "reward": ""},
		{"id": "quests_completed_5", "name": "5 Quests Completed", "tier_name": "", "points": 50, "reward": ""},
	]

	var menu: Control = load("res://client/main_menu.tscn").instantiate()
	add_child(menu)

	await get_tree().create_timer(0.35).timeout
	_shot("toast_in")            # card 1 sliding in
	await get_tree().create_timer(1.2).timeout
	_shot("toast_hold")          # card 1 held
	await get_tree().create_timer(5.4).timeout
	_shot("toast_2")             # card 2 (queue advanced)
	await get_tree().create_timer(5.8).timeout
	_shot("toast_3")             # card 3 — confirms the whole queue drains

	get_tree().quit()


func _shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://%s.png" % name)
	print("SHOT %s: %s" % [name, ProjectSettings.globalize_path("user://%s.png" % name)])
