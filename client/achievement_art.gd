class_name AchievementArt
extends RefCounted
## Achievement tile art: res://assets/achievements/<achievement_id>.png (veteran.png,
## winner.png, on_fire.png, ...). "default.png" is the fallback for an achievement
## with no art yet. Drop PNGs in that folder — no code change needed.

const DIR := "res://assets/achievements/"
const DEFAULT_ID := "default"

static func path_for(achievement_id: String) -> String:
	if achievement_id != "" and ResourceLoader.exists(DIR + achievement_id + ".png"):
		return DIR + achievement_id + ".png"
	return DIR + DEFAULT_ID + ".png"

static func texture_for(achievement_id: String) -> Texture2D:
	var p := path_for(achievement_id)
	return load(p) if ResourceLoader.exists(p) else null
