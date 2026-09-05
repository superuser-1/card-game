class_name QuestArt
extends RefCounted
## Quest tile art: res://assets/quests/<quest_id>.png (win_3.png, perfect_win.png,
## money_game.png, ...). "default.png" is the fallback for a quest with no art
## yet. Drop PNGs in that folder — no code change needed.

const DIR := "res://assets/quests/"
const DEFAULT_ID := "default"

static func path_for(quest_id: String) -> String:
	if quest_id != "" and ResourceLoader.exists(DIR + quest_id + ".png"):
		return DIR + quest_id + ".png"
	return DIR + DEFAULT_ID + ".png"

static func texture_for(quest_id: String) -> Texture2D:
	var p := path_for(quest_id)
	return load(p) if ResourceLoader.exists(p) else null
