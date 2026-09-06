extends Control

# Captured on entry: the match we're showing results for was a local bot game,
# not a ranked networked one. "Play again" then restarts singleplayer directly
# instead of dropping into the matchmaking queue, and leaving hands the Net
# state back to a plain client (see Net.end_singleplayer).
var _was_solo := false


func _ready() -> void:
	_was_solo = Net.is_solo

	var s: Dictionary = Session.last_match_summary
	Session.last_match_summary = {}

	if s.is_empty():
		_show_empty_state()
	else:
		_show_result(s)

	%AgainButton.pressed.connect(_on_again)
	%MenuButton.pressed.connect(_on_menu)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_menu()
		get_viewport().set_input_as_handled()


func _on_again() -> void:
	if _was_solo:
		# Straight into a fresh bot game — no queue, we're already local.
		Net.start_singleplayer(bool(Session.settings.get("sp_reveal_mode", false)))
		Session.goto("res://client/game_ui.tscn")
	else:
		Session.goto("res://client/queue_screen.tscn")


func _on_menu() -> void:
	if _was_solo:
		Net.end_singleplayer()
	Session.goto("res://client/main_menu.tscn")


func _show_empty_state() -> void:
	%OutcomeLabel.text = "Match Over"
	%EloLabel.visible = false
	%PointsLabel.visible = false
	%RankLabel.visible = false
	%QuestLabel.visible = false
	%AchievementLabel.visible = false


func _show_result(s: Dictionary) -> void:
	var outcome: String = str(s.get("outcome", ""))
	var outcome_map: Dictionary = {"win": "Victory", "loss": "Defeat", "draw": "Draw"}
	%OutcomeLabel.text = outcome_map.get(outcome, "Match Over")

	var match_format: int = int(s.get("match_format", 1))
	if match_format > 1:
		var games_won: int = int(s.get("games_won", 0))
		var games_won_opponent: int = int(s.get("games_won_opponent", 0))
		%ScoreLabel.text = "You %d — %d Opponent  (Best of %d)" % [games_won, games_won_opponent, match_format]
	else:
		var your_score: int = int(s.get("your_score", 0))
		var opponent_score: int = int(s.get("opponent_score", 0))
		%ScoreLabel.text = "You %d — %d Opponent" % [your_score, opponent_score]

	var is_ranked: bool = bool(s.get("ranked", false))
	if is_ranked:
		var elo_delta: int = int(s.get("elo_delta", 0))
		var elo_after: int = int(s.get("elo_after", 0))
		%EloLabel.text = "Elo %+d  (now %d)" % [elo_delta, elo_after]

		var points_delta: int = int(s.get("points_delta", 0))
		var points_total: int = int(s.get("points_total", 0))
		var qpts: int = int(s.get("quest_points", 0))
		if qpts > 0:
			%PointsLabel.text = "Points +%d  (+%d quests · total %d)" % [points_delta, qpts, points_total]
		else:
			%PointsLabel.text = "Points +%d  (total %d)" % [points_delta, points_total]

		var apts: int = int(s.get("achievement_points", 0))
		if apts > 0:
			%PointsLabel.text += "  (+%d achievements)" % apts

		var qc: Array = s.get("quest_completions", [])
		if qc.is_empty():
			%QuestLabel.visible = false
		else:
			var parts := []
			for q in qc:
				parts.append("%s  +%d" % [str(q.get("name", "Quest")), int(q.get("points", 0))])
			%QuestLabel.text = "Quests complete — " + "  ·  ".join(parts)

		var ac: Array = s.get("achievement_unlocks", [])
		if ac.is_empty():
			%AchievementLabel.visible = false
		else:
			var aparts := []
			for a in ac:
				var tn := str(a.get("tier_name", ""))
				var label := "%s (%s)" % [str(a.get("name", "Achievement")), tn] if tn != "" else str(a.get("name", "Achievement"))
				aparts.append("%s  +%d" % [label, int(a.get("points", 0))])
			%AchievementLabel.visible = true
			%AchievementLabel.text = "Achievements — " + "  ·  ".join(aparts)

		var new_rank: int = int(s.get("new_rank", 0))
		%RankLabel.text = "Rank #%d" % new_rank
	else:
		%EloLabel.visible = false
		%PointsLabel.text = "Unranked game"
		%RankLabel.visible = false
		%QuestLabel.visible = false
		%AchievementLabel.visible = false
