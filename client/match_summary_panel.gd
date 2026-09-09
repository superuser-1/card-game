class_name MatchSummaryPanel
extends PanelContainer
## Shared end-of-match summary card. Used both full-screen
## (match_result_screen) and as an in-board overlay (game_ui). Call
## `render(summary)` once; connect `again_pressed` / `menu_pressed`.
## `again_label` lets the host relabel the primary button ("Play Again" vs
## "Find Another").

signal again_pressed
signal menu_pressed


func _ready() -> void:
	%AgainButton.pressed.connect(func(): again_pressed.emit())
	%MenuButton.pressed.connect(func(): menu_pressed.emit())


func set_again_label(text: String) -> void:
	%AgainButton.text = text


func render(s: Dictionary) -> void:
	if s.is_empty():
		_render_empty()
	else:
		_render_result(s)


func _render_empty() -> void:
	%OutcomeLabel.text = "Match Over"
	for n in ["ScoreLabel", "EloLabel", "PointsLabel", "QuestLabel", "AchievementLabel", "RankLabel"]:
		get_node("Margin/VBox/" + n).visible = false


func _render_result(s: Dictionary) -> void:
	var outcome: String = str(s.get("outcome", ""))
	%OutcomeLabel.text = {"win": "Victory", "loss": "Defeat", "draw": "Draw"}.get(outcome, "Match Over")
	%OutcomeLabel.add_theme_color_override("font_color", {
		"win": Color(0.45, 0.92, 0.5), "loss": Color(0.95, 0.45, 0.45), "draw": Color(0.9, 0.85, 0.5),
	}.get(outcome, Color(1, 1, 1)))

	var match_format: int = int(s.get("match_format", 1))
	if match_format > 1:
		%ScoreLabel.text = "You %d — %d Opponent  (Best of %d,  %d — %d categories)" % [
			int(s.get("games_won", 0)), int(s.get("games_won_opponent", 0)), match_format,
			int(s.get("series_score", 0)), int(s.get("series_score_opponent", 0))]
	else:
		%ScoreLabel.text = "You %d — %d Opponent" % [
			int(s.get("your_score", 0)), int(s.get("opponent_score", 0))]

	if bool(s.get("ranked", false)):
		%EloLabel.text = "Elo %+d  (now %d)" % [int(s.get("elo_delta", 0)), int(s.get("elo_after", 0))]

		var qpts: int = int(s.get("quest_points", 0))
		if qpts > 0:
			%PointsLabel.text = "Points +%d  (+%d quests · total %d)" % [
				int(s.get("points_delta", 0)), qpts, int(s.get("points_total", 0))]
		else:
			%PointsLabel.text = "Points +%d  (total %d)" % [
				int(s.get("points_delta", 0)), int(s.get("points_total", 0))]
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
			%AchievementLabel.text = "Achievements — " + "  ·  ".join(aparts)

		%RankLabel.text = "Rank #%d" % int(s.get("new_rank", 0))
	else:
		%EloLabel.visible = false
		%PointsLabel.text = "Unranked game"
		%QuestLabel.visible = false
		%AchievementLabel.visible = false
		%RankLabel.visible = false
