extends Control

func _ready() -> void:
	%BackButton.pressed.connect(func(): Session.goto("res://client/main_menu.tscn"))
	_render_achievements()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Session.goto("res://client/main_menu.tscn")
		get_viewport().set_input_as_handled()


func _render_achievements() -> void:
	# Clear existing cards
	for c in %AchievementsBox.get_children():
		c.queue_free()

	var stats: Dictionary = Session.account.get("stats", {})
	var unlocked: Dictionary = Session.account.get("achievements", {}).get("unlocked", {})
	var rows := AchievementSystem.rows(stats, unlocked)

	if rows.is_empty():
		var label := Label.new()
		label.text = "No achievements yet."
		%AchievementsBox.add_child(label)
		return

	for row in rows:
		_add_achievement_card(row)


func _add_achievement_card(row: Dictionary) -> void:
	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(200, 240)

	# Art
	var art := TextureRect.new()
	art.custom_minimum_size = Vector2(200, 100)
	art.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	art.texture = AchievementArt.texture_for(str(row.get("id", "")))
	card.add_child(art)

	# Name
	var name_label := Label.new()
	name_label.text = str(row.get("name", ""))
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.custom_minimum_size.x = 200
	card.add_child(name_label)

	# Tier badge
	var tiers_done := int(row.get("tiers_done", 0))
	var tier_total := int(row.get("tier_total", 3))
	var maxed := bool(row.get("maxed", false))
	var tier_label := Label.new()
	tier_label.add_theme_font_size_override("font_size", 10)
	if maxed:
		# Single-tier milestones read better as "UNLOCKED" than "COMPLETE".
		tier_label.text = "UNLOCKED" if tier_total <= 1 else "COMPLETE"
	elif tier_total <= 1:
		tier_label.text = "LOCKED"
	elif tiers_done > 0:
		tier_label.text = AchievementSystem.TIER_NAMES[tiers_done - 1]
	else:
		tier_label.text = "—"
	card.add_child(tier_label)

	# Progress bar
	if not maxed:
		var current := int(row.get("current_value", 0))
		var next_threshold := int(row.get("next_threshold", 0))
		var progress_label := Label.new()
		if next_threshold > 0:
			var pct := int(float(current) / float(next_threshold) * 100.0)
			progress_label.text = "%d / %d" % [current, next_threshold]
		else:
			progress_label.text = "%d" % current
		progress_label.add_theme_font_size_override("font_size", 10)
		card.add_child(progress_label)

	# Reward preview (on final tier)
	var reward_on_final := str(row.get("reward_on_final", ""))
	if reward_on_final != "" and tiers_done >= 2:  # Show on Silver+ tiers
		var reward_label := Label.new()
		reward_label.text = "Reward: %s" % reward_on_final
		reward_label.add_theme_font_size_override("font_size", 9)
		card.add_child(reward_label)

	if maxed:
		card.modulate = Color(0.7, 0.7, 0.7, 1.0)

	%AchievementsBox.add_child(card)
