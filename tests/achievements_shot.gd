extends Node
## Dev-only: render the achievements screen with a fake account so the tile
## layout can be eyeballed without a server.
##   godot --path . tests/achievements_shot.tscn  -> user://achievements_shot.png

func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 950))

	Session.account = {
		"display_name": "PlayerOne",
		"owned_rewards": ["sleeve_classic", "30_ranked_losses_avatar"],
		"stats": {
			"wins": 7, "losses": 35, "tournaments_won": 1,
			"tournaments_created": 3, "quests_completed": 6,
		},
		"achievements": {"unlocked": {
			"ranked_win_1": 0, "ranked_win_5": 0,
			"ranked_loss_1": 0, "ranked_loss_5": 0, "ranked_loss_10": 0, "ranked_loss_30": 0,
			"tourney_win_1": 0,
			"quests_completed_5": 0,
		}},
	}
	Session.token = "debug"

	var screen: Control = load("res://client/achievements_screen.tscn").instantiate()
	add_child(screen)

	await get_tree().create_timer(0.6).timeout
	get_viewport().get_texture().get_image().save_png("user://achievements_shot.png")
	print("SHOT: ", ProjectSettings.globalize_path("user://achievements_shot.png"))

	# Scroll down to the ranked-loss ladder so the reward-badge tiles are visible.
	var sc := screen.find_child("ScrollContainer", true, false)
	if sc:
		sc.scroll_vertical = 1080
		await get_tree().create_timer(0.3).timeout
		get_viewport().get_texture().get_image().save_png("user://achievements_shot_rewards.png")
		print("SHOT2: ", ProjectSettings.globalize_path("user://achievements_shot_rewards.png"))

	get_tree().quit()
