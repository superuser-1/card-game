extends SceneTree
## Dev-only cheat: fake-unlock every achievement for an account so the reward
## flow (avatar picker visibility, achievement-screen reward badges, equipped
## cosmetics) can be tested without grinding the stats.
##
## Run with the local --server STOPPED (it holds accounts.json in memory and
## would overwrite this on its next save), then restart it and log in.
##
##   godot --headless --path . --script tests/grant_achievements.gd -- --user=1
##   godot --headless --path . --script tests/grant_achievements.gd -- --all
##   godot --headless --path . --script tests/grant_achievements.gd -- --user=1 --reset
##
## Flags:
##   --user=NAME   account username (case-insensitive). Repeatable.
##   --all         every non-bot account in the store
##   --reset       instead of granting: wipe stats/achievements and drop every
##                 achievement-source reward from owned_rewards (keeps
##                 shop-bought + legacy cosmetics). Un-equips an achievement
##                 avatar if one was worn.
##   --data=DIR    store dir (default: user://flickbattle/)

func _initialize() -> void:
	var users: Array = []
	var do_all := false
	var do_reset := false
	var data_dir := "user://flickbattle/"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--user="):
			users.append(arg.substr("--user=".length()).strip_edges().to_lower())
		elif arg == "--all":
			do_all = true
		elif arg == "--reset":
			do_reset = true
		elif arg.begins_with("--data="):
			data_dir = arg.substr("--data=".length()).strip_edges()

	if users.is_empty() and not do_all:
		push_error("pass --user=NAME (repeatable) or --all")
		quit(1)
		return

	var store := ServerStore.new()
	store.open(data_dir)

	var targets: Array = []
	for account in store._accounts:
		var uname := str(account.get("username_lower", ""))
		var is_bot := uname.begins_with("bot_")
		if do_all:
			if not is_bot:
				targets.append(account)
		elif uname in users:
			targets.append(account)

	if targets.is_empty():
		push_error("no matching account(s) in %s" % ProjectSettings.globalize_path(data_dir + "accounts.json"))
		quit(1)
		return

	for account in targets:
		if do_reset:
			_reset(account)
			print("RESET   %s  -> owned_rewards=%s  avatar=%s" % [
				account.get("username"), account.get("owned_rewards"), account.get("avatar")])
		else:
			_grant_all(store, account)
			var unlocked_ct := (account["achievements"]["unlocked"] as Dictionary).size()
			print("GRANTED %s  -> %d achievements unlocked, owned_rewards=%s" % [
				account.get("username"), unlocked_ct, account.get("owned_rewards")])

	store._save_accounts()
	print("saved %s" % ProjectSettings.globalize_path(data_dir + "accounts.json"))
	quit(0)


## Push every stat the catalog watches past its highest threshold, then run the
## real evaluate()/grant_reward() so points + reward ids land exactly as they
## would in-game.
func _grant_all(store: ServerStore, account: Dictionary) -> void:
	store._ensure_stats(account)
	var stats: Dictionary = account["stats"]

	var maxes: Dictionary = {}
	for ach in AchievementSystem.CATALOG:
		var key := str(ach.stat)
		for tier in (ach.get("tiers", []) as Array):
			maxes[key] = max(int(maxes.get(key, 0)), int(tier.get("threshold", 0)))
	for key in maxes:
		stats[key] = max(int(stats.get(key, 0)), int(maxes[key]))

	var res := AchievementSystem.evaluate(stats, account["achievements"]["unlocked"])
	account["achievements"]["unlocked"] = res["unlocked"]
	store.grant_reward(account, int(res["points_awarded"]), res["reward_ids"])


func _reset(account: Dictionary) -> void:
	account["stats"] = {}
	account["achievements"] = {"unlocked": {}}
	var kept: Array = []
	for id in (account.get("owned_rewards", []) as Array):
		var def := ShopCatalog.def_for(str(id))
		if def.is_empty() or str(def.get("source", "")) != "achievement":
			kept.append(str(id))
	account["owned_rewards"] = kept
	for slot in ["avatar", "frame", "background", "sleeve"]:
		var cur := str(account.get(slot, ""))
		if cur != "" and ShopCatalog.is_premium(cur) and cur not in kept:
			account[slot] = ""
