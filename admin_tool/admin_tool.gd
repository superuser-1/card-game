extends Control
## Standalone admin tool window — a SEPARATE lightweight UI from the game
## client, launched via `godot -- --admin-tool [--address=IP]` (see main.gd),
## reusing the same Net/Session autoloads and ENet connection the game client
## uses (same one-connection-per-account server, same auth RPCs) rather than
## a whole second Godot project. No game art, no menu chrome.
##
## Every admin action here is a thin call into a Net RPC wrapper, which is
## itself a thin dispatcher into a plain ServerStore method server-side (see
## server/server_store.gd's "admin tools" section and net_node.gd's "Admin
## tools" section). If this ever needs to become a website instead of a PC
## tool, the server-side logic doesn't change — only the transport (HTTP
## instead of ENet RPCs) and this front-end would be replaced.

var _selected_account_id := 0
var _selected_tournament_id := 0
var _selected_live_ranked_match_id := 0
var _selected_custom_in_progress_match_id := 0

## Set right before opening %ConfirmDialog; run if the user presses OK.
## Cleared either way once the dialog closes.
var _pending_confirm: Callable = Callable()

## Cached full row lists from the last server fetch, so the search fields
## can filter client-side without another round trip.
var _tournament_rows: Array = []
var _live_ranked_rows: Array = []
var _custom_lobby_rows: Array = []
var _custom_in_progress_rows: Array = []

var _stats_range_hours := 24

var _template_rows: Array = []
var _prize_catalog_rows: Array = []
var _selected_template_id := 0


func _ready() -> void:
	DisplayServer.window_set_title("Flick Battle — Admin Tool")
	DisplayServer.window_set_size(Vector2i(900, 720))

	Net.auth_completed.connect(_on_auth_completed)
	Net.error_received.connect(_on_net_error)
	Net.admin_search_result.connect(_on_admin_search_result)
	Net.admin_account_detail.connect(_on_admin_account_detail)
	Net.admin_action_result.connect(_on_admin_action_result)
	Net.admin_online_list.connect(_on_admin_online_list)
	Net.admin_log_received.connect(_on_admin_log_result)
	Net.admin_account_activity.connect(_on_admin_account_activity)
	Net.admin_tournament_list.connect(_on_admin_tournament_list)
	Net.admin_tournament_detail.connect(_on_admin_tournament_detail)
	Net.admin_live_ranked_list.connect(_on_admin_live_ranked_list)
	Net.admin_custom_games_list.connect(_on_admin_custom_games_list)
	Net.admin_presence_stats.connect(_on_admin_presence_stats)
	Net.admin_template_list.connect(_on_admin_template_list)
	Net.admin_prize_catalog.connect(_on_admin_prize_catalog)
	Net.kicked.connect(_on_kicked)
	Net.force_logout.connect(_on_force_logout)

	%LoginButton.pressed.connect(_on_login_pressed)
	%PasswordField.text_submitted.connect(func(_t): _on_login_pressed())
	%LogoutButton.pressed.connect(_on_logout_pressed)

	%SearchButton.pressed.connect(_on_search_pressed)
	%SearchField.text_submitted.connect(func(_t): _on_search_pressed())
	%ResultsList.item_selected.connect(_on_result_selected)
	%BanButton.pressed.connect(_on_ban_pressed)
	%UnbanButton.pressed.connect(_on_unban_pressed)
	%SetEloButton.pressed.connect(_on_set_elo_pressed)
	%AdjustPointsButton.pressed.connect(_on_adjust_points_pressed)

	%RefreshOnlineButton.pressed.connect(func(): Net.admin_list_online())
	%RefreshLogButton.pressed.connect(func(): Net.admin_recent_actions(100))

	%TournamentSearchField.text_changed.connect(func(_t): _render_tournament_list())
	%RefreshTournamentsButton.pressed.connect(_on_refresh_tournaments_pressed)
	%TournamentList.item_selected.connect(_on_tournament_selected)
	%RollbackButton.pressed.connect(_on_rollback_pressed)

	%LiveRankedSearchField.text_changed.connect(func(_t): _render_live_ranked_list())
	%RefreshLiveRankedButton.pressed.connect(func(): Net.admin_list_live_ranked())
	%LiveRankedList.item_selected.connect(func(i): _selected_live_ranked_match_id = int(_filtered_live_ranked()[i].get("match_id", 0)))
	%ForceEndRankedButton.pressed.connect(_on_force_end_ranked_pressed)

	%LiveCustomSearchField.text_changed.connect(func(_t): _render_custom_games())
	%RefreshLiveCustomButton.pressed.connect(func(): Net.admin_list_custom_games())
	%CustomInProgressList.item_selected.connect(func(i): _selected_custom_in_progress_match_id = int(_filtered_custom_in_progress()[i].get("match_id", 0)))
	%ForceEndCustomButton.pressed.connect(_on_force_end_custom_pressed)

	%PlanCreateNowButton.pressed.connect(_on_plan_create_now_pressed)
	%PlanSaveTemplateButton.pressed.connect(_on_plan_save_template_pressed)
	%PlanTemplatesList.item_selected.connect(func(i): _selected_template_id = int(_template_rows[i].get("id", 0)))
	%PlanToggleActiveButton.pressed.connect(_on_plan_toggle_active_pressed)
	%PlanDeleteTemplateButton.pressed.connect(_on_plan_delete_template_pressed)
	%PlanPrizeCatalogList.item_selected.connect(_on_plan_catalog_item_selected)

	%Range24hButton.pressed.connect(func(): _set_stats_range(24, %Range24hButton))
	%Range7dButton.pressed.connect(func(): _set_stats_range(24 * 7, %Range7dButton))
	%Range30dButton.pressed.connect(func(): _set_stats_range(24 * 30, %Range30dButton))

	%Tabs.tab_changed.connect(_on_tab_changed)
	%LiveRefreshTimer.timeout.connect(_on_live_refresh_tick)
	%ConfirmDialog.confirmed.connect(_on_confirm_dialog_confirmed)
	%ConfirmDialog.canceled.connect(func(): _pending_confirm = Callable())

	%ConnLabel.text = "Connecting..."
	var connected: bool = await _ensure_connected()
	if not connected:
		%ConnLabel.text = "Could not reach server."
		return
	%ConnLabel.text = ""

	var saved := Session.load_token()
	if saved != "":
		%ConnLabel.text = "Resuming session..."
		Net.auth_resume(saved)


func _ensure_connected() -> bool:
	var mp := multiplayer.multiplayer_peer
	if mp == null:
		return false
	if mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		return true
	while mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		await get_tree().process_frame
	return mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


# --- auth ----------------------------------------------------------------

func _on_login_pressed() -> void:
	var username: String = %UsernameField.text.strip_edges()
	var password: String = %PasswordField.text
	if username == "" or password == "":
		%LoginErrorLabel.text = "Enter a username and password."
		return
	%LoginErrorLabel.text = ""
	%ConnLabel.text = "Signing in..."
	Net.auth_login(username, password)


func _on_auth_completed(result: Dictionary) -> void:
	%ConnLabel.text = ""
	if not bool(result.get("ok", false)):
		Session.clear()
		var error: String = result.get("error", "")
		if error == "banned":
			%LoginErrorLabel.text = "This account is suspended."
		elif error == "session_expired":
			%LoginErrorLabel.text = "Session expired — please log in again."
		else:
			%LoginErrorLabel.text = "Sign-in failed (%s)." % error
		return

	Session.set_account(result.get("account", {}))
	Session.save_token(result.get("token", ""))
	# account_snapshot() never exposes is_admin (a player's own client has no
	# use for it) — the real gate is server-side on every admin RPC, so probe
	# with a harmless read: admin_online_list on success, or an explicit
	# not_admin admin_action_result if this account isn't an admin.
	Net.admin_list_online()


func _on_logout_pressed() -> void:
	Session.clear()
	%LiveRefreshTimer.stop()
	%MainPanel.visible = false
	%LoginPanel.visible = true
	%UsernameField.text = ""
	%PasswordField.text = ""
	%LoginErrorLabel.text = ""


func _on_kicked() -> void:
	Session.clear()
	%LiveRefreshTimer.stop()
	%MainPanel.visible = false
	%LoginPanel.visible = true
	%LoginErrorLabel.text = "Disconnected from server."


func _on_force_logout(reason: String) -> void:
	%LoginErrorLabel.text = reason


func _on_net_error(msg: String) -> void:
	%ConnLabel.text = ""
	%LoginErrorLabel.text = msg


# --- accounts --------------------------------------------------------------

func _on_search_pressed() -> void:
	Net.admin_search_accounts(%SearchField.text.strip_edges())


func _on_admin_search_result(rows: Array) -> void:
	# First reply to land after login also means this account IS an admin —
	# reveal the tool now if we're still sitting on the login panel.
	_show_main_panel()
	%ResultsList.clear()
	%ResultsList.set_meta("rows", rows)
	for row in rows:
		var banned_tag := " [BANNED]" if bool(row.get("banned", false)) else ""
		%ResultsList.add_item("%s (#%d) elo=%d%s" % [
			str(row.get("username", "?")), int(row.get("id", 0)), int(row.get("elo", 0)), banned_tag
		])


func _on_result_selected(index: int) -> void:
	var rows: Array = %ResultsList.get_meta("rows", [])
	if index < 0 or index >= rows.size():
		return
	_selected_account_id = int(rows[index].get("id", 0))
	Net.admin_get_account(_selected_account_id)
	Net.admin_get_account_activity(_selected_account_id)


func _on_admin_account_detail(account: Dictionary) -> void:
	if account.is_empty():
		%DetailLabel.text = "Account not found."
		return
	var lines := [
		"#%d  %s" % [int(account.get("id", 0)), str(account.get("username", ""))],
		"Elo: %d (peak %d)" % [int(account.get("elo", 0)), int(account.get("peak_elo", 0))],
		"Record: %d-%d-%d over %d games" % [
			int(account.get("wins", 0)), int(account.get("losses", 0)),
			int(account.get("draws", 0)), int(account.get("games", 0))
		],
		"Points: %d" % int(account.get("points", 0)),
		"Admin: %s" % ("yes" if bool(account.get("is_admin", false)) else "no"),
	]
	if bool(account.get("banned", false)):
		lines.append("BANNED — reason: %s" % str(account.get("ban_reason", "")))
		lines.append("Banned by %s" % str(account.get("banned_by", "")))
	%DetailLabel.text = "\n".join(lines)

	var equipped := []
	for slot in [["avatar", "Avatar"], ["frame", "Frame"], ["background", "Background"], ["table_background", "Table"], ["sleeve", "Sleeve"], ["title", "Title"]]:
		var val := str(account.get(slot[0], ""))
		if val != "":
			equipped.append("%s: %s" % [slot[1], val])
	var owned: Array = account.get("owned_rewards", [])
	var cosmetics_lines := []
	if not equipped.is_empty():
		cosmetics_lines.append("Equipped:\n  " + "\n  ".join(equipped))
	cosmetics_lines.append("Owned cosmetics (%d):\n  %s" % [owned.size(), "\n  ".join(owned) if not owned.is_empty() else "(none)"])
	%CosmeticsLabel.text = "\n\n".join(cosmetics_lines)


func _on_admin_account_activity(activity: Dictionary) -> void:
	%MatchHistoryList.clear()
	for m in (activity.get("matches", []) as Array):
		var when := Time.get_datetime_string_from_unix_time(int(m.get("ts", 0)), true)
		%MatchHistoryList.add_item("%s  %s vs %s  score %d-%d  elo %+d  points %+d" % [
			when, str(m.get("outcome", "")).to_upper(), str(m.get("opponent_name", "")),
			int(m.get("your_score", 0)), int(m.get("opponent_score", 0)),
			int(m.get("elo_delta", 0)), int(m.get("points_delta", 0)),
		])

	%TournamentHistoryList.clear()
	for t in (activity.get("tournaments", []) as Array):
		var when := Time.get_datetime_string_from_unix_time(int(t.get("start_ts", 0)), true)
		var rb := " [ROLLED BACK]" if bool(t.get("rolled_back", false)) else ""
		%TournamentHistoryList.add_item("%s  %s  placement=%s  prize=%d pts%s" % [
			when, str(t.get("name", "")), str(t.get("placement_bucket", "-")),
			int(t.get("prize_points", 0)), rb,
		])

	%RewardLogList.clear()
	for r in (activity.get("rewards", []) as Array):
		var when := Time.get_datetime_string_from_unix_time(int(r.get("ts", 0)), true)
		var items: Array = r.get("items", [])
		%RewardLogList.add_item("%s  [%s]  +%d pts  %s" % [
			when, str(r.get("source", "")), int(r.get("points", 0)),
			(", ".join(items) if not items.is_empty() else "-"),
		])

	%AchievementLogList.clear()
	for a in (activity.get("achievements", []) as Array):
		var when := Time.get_datetime_string_from_unix_time(int(a.get("ts", 0)), true)
		%AchievementLogList.add_item("%s  %s — %s (+%d pts)" % [
			when, str(a.get("name", a.get("id", ""))), str(a.get("tier_name", "")), int(a.get("points", 0)),
		])

	%ShopLogList.clear()
	for s in (activity.get("shop", []) as Array):
		var when := Time.get_datetime_string_from_unix_time(int(s.get("ts", 0)), true)
		%ShopLogList.add_item("%s  %s  -%d pts" % [when, str(s.get("item_id", "")), int(s.get("price", 0))])

	%PointsLedgerList.clear()
	for p in (activity.get("points_ledger", []) as Array):
		var when := Time.get_datetime_string_from_unix_time(int(p.get("ts", 0)), true)
		var delta := int(p.get("delta", 0))
		var details := str(p.get("details", ""))
		%PointsLedgerList.add_item("%s  [%s]  %+d pts  (balance %d)%s" % [
			when, str(p.get("source", "")), delta, int(p.get("balance_after", 0)),
			("  " + details) if details != "" else "",
		])


func _on_ban_pressed() -> void:
	if _selected_account_id == 0:
		return
	_confirm("Ban this account? Reason: \"%s\"" % %ReasonField.text.strip_edges(), func():
		Net.admin_ban(_selected_account_id, %ReasonField.text.strip_edges())
	)


func _on_unban_pressed() -> void:
	if _selected_account_id == 0:
		return
	Net.admin_unban(_selected_account_id)


func _on_set_elo_pressed() -> void:
	if _selected_account_id == 0:
		return
	var text: String = %NewEloField.text.strip_edges()
	if not text.is_valid_int():
		%StatusLabel.text = "Enter a whole-number elo value."
		return
	Net.admin_set_elo(_selected_account_id, int(text))


func _on_adjust_points_pressed() -> void:
	if _selected_account_id == 0:
		return
	var text: String = %PointsDeltaField.text.strip_edges()
	if not text.is_valid_int():
		%StatusLabel.text = "Enter a whole-number points delta (e.g. -50)."
		return
	Net.admin_adjust_points(_selected_account_id, int(text))


func _on_admin_action_result(result: Dictionary) -> void:
	var action: String = result.get("action", "")
	if not bool(result.get("ok", false)):
		var error: String = result.get("error", "")
		if error == "not_admin":
			# The probe call after login (or any later call) came back denied —
			# this account has no admin rights. Kick back to the login form.
			Session.clear()
			%MainPanel.visible = false
			%LoginPanel.visible = true
			%LoginErrorLabel.text = "This account does not have admin rights."
			return
		%StatusLabel.text = "%s failed: %s" % [action, error]
		return

	%StatusLabel.text = "%s: OK" % action
	var account: Dictionary = result.get("account", {})
	if not account.is_empty():
		_on_admin_account_detail(account)
		if int(account.get("id", 0)) == _selected_account_id:
			%ReasonField.text = ""
			%NewEloField.text = ""
			%PointsDeltaField.text = ""

	match action:
		"rollback_tournament":
			if _selected_tournament_id != 0:
				Net.admin_get_tournament(_selected_tournament_id)
			Net.admin_list_tournaments(int(%TournamentDaysField.text.strip_edges()) if %TournamentDaysField.text.strip_edges().is_valid_int() else 30)
		"force_end_match":
			Net.admin_list_live_ranked()
			Net.admin_list_custom_games()
		"create_tournament":
			%StatusLabel.text = "Tournament created."
			Net.admin_list_tournaments(int(%TournamentDaysField.text.strip_edges()) if %TournamentDaysField.text.strip_edges().is_valid_int() else 30)
		"create_template", "delete_template", "set_template_active":
			Net.admin_list_templates()


# --- online / log ------------------------------------------------------------

func _on_admin_online_list(rows: Array) -> void:
	_show_main_panel()
	%OnlineList.clear()
	for row in rows:
		%OnlineList.add_item("%s (#%d) elo=%d" % [
			str(row.get("username", "?")), int(row.get("id", 0)), int(row.get("elo", 0))
		])


func _on_admin_log_result(rows: Array) -> void:
	%LogList.clear()
	for row in rows:
		var when := Time.get_datetime_string_from_unix_time(int(row.get("ts", 0)), true)
		%LogList.add_item("%s  %s  %s -> account #%d  %s" % [
			when, str(row.get("admin", "")), str(row.get("action", "")),
			int(row.get("account_id", 0)), str(row.get("details", ""))
		])


# --- tournaments -------------------------------------------------------------

func _on_refresh_tournaments_pressed() -> void:
	var text: String = %TournamentDaysField.text.strip_edges()
	var days := int(text) if text.is_valid_int() else 30
	Net.admin_list_tournaments(days)


func _on_admin_tournament_list(rows: Array) -> void:
	_tournament_rows = rows
	_render_tournament_list()


func _filtered_tournaments() -> Array:
	var q: String = %TournamentSearchField.text.strip_edges().to_lower()
	if q == "":
		return _tournament_rows
	return _tournament_rows.filter(func(t): return str(t.get("name", "")).to_lower().contains(q))


func _render_tournament_list() -> void:
	%TournamentList.clear()
	for t in _filtered_tournaments():
		var when := Time.get_datetime_string_from_unix_time(int(t.get("start_ts", 0)), true)
		var rb := " [ROLLED BACK]" if bool(t.get("rolled_back", false)) else ""
		%TournamentList.add_item("%s  %s  %s  %d players  %d pts pool%s" % [
			when, str(t.get("name", "")), str(t.get("status", "")),
			int(t.get("participant_count", 0)), int(t.get("prize_pool_points", 0)), rb,
		])


func _on_tournament_selected(index: int) -> void:
	var rows := _filtered_tournaments()
	if index < 0 or index >= rows.size():
		return
	_selected_tournament_id = int(rows[index].get("id", 0))
	Net.admin_get_tournament(_selected_tournament_id)


func _on_admin_tournament_detail(t: Dictionary) -> void:
	if t.is_empty():
		%TournamentDetailLabel.text = "Tournament not found."
		return
	var lines := [
		"#%d  %s  (%s)" % [int(t.get("id", 0)), str(t.get("name", "")), str(t.get("status", ""))],
		"Bracket size %d, %s, availability %s" % [
			int(t.get("bracket_size", 0)),
			"Bo%d" % int(t.get("match_format", 1)), str(t.get("availability", "open")),
		],
		"Prizes paid: %s" % ("yes" if bool(t.get("prizes_paid", false)) else "no"),
	]
	if bool(t.get("rolled_back", false)):
		lines.append("ROLLED BACK by %s" % str(t.get("rolled_back_by", "")))
	%TournamentDetailLabel.text = "\n".join(lines)

	%ParticipantsList.clear()
	for p in (t.get("participants", []) as Array):
		%ParticipantsList.add_item("%s (#%d)  placement=%s  prize=%d pts  items=%s" % [
			str(p.get("username", "")), int(p.get("account_id", 0)),
			str(p.get("placement_bucket", "-")) if str(p.get("placement_bucket", "")) != "" else "-",
			int(p.get("prize_points", 0)),
			(", ".join(p.get("prize_items", [])) if not (p.get("prize_items", []) as Array).is_empty() else "-"),
		])


func _on_rollback_pressed() -> void:
	if _selected_tournament_id == 0:
		return
	_confirm("Roll back prize payouts for tournament #%d? This claws back the points/items it granted." % _selected_tournament_id, func():
		Net.admin_rollback_tournament(_selected_tournament_id)
	)


# --- live ranked ---------------------------------------------------------

func _filtered_live_ranked() -> Array:
	var q: String = %LiveRankedSearchField.text.strip_edges().to_lower()
	if q == "":
		return _live_ranked_rows
	return _live_ranked_rows.filter(func(m):
		return str(m.get("seat1_username", "")).to_lower().contains(q) or str(m.get("seat2_username", "")).to_lower().contains(q)
	)


func _on_admin_live_ranked_list(rows: Array) -> void:
	_live_ranked_rows = rows
	_render_live_ranked_list()


func _render_live_ranked_list() -> void:
	%LiveRankedList.clear()
	for m in _filtered_live_ranked():
		%LiveRankedList.add_item(_match_row_text(m))


func _match_row_text(m: Dictionary) -> String:
	var elapsed := int(Time.get_unix_time_from_system()) - int(m.get("created_ts", 0))
	return "#%d  %s (elo %d) %d - %d %s (elo %d)  Bo%d  %s  %dm ago" % [
		int(m.get("match_id", 0)),
		str(m.get("seat1_username", "")), int(m.get("seat1_elo", 0)),
		int(m.get("score1", 0)), int(m.get("score2", 0)),
		str(m.get("seat2_username", "")), int(m.get("seat2_elo", 0)),
		int(m.get("match_format", 1)),
		"[bot]" if bool(m.get("is_bot_match", false)) else "",
		maxi(0, elapsed) / 60,
	]


func _on_force_end_ranked_pressed() -> void:
	if _selected_live_ranked_match_id == 0:
		return
	var mid := _selected_live_ranked_match_id
	_confirm("Force-end match #%d? No result will be recorded for either player." % mid, func():
		Net.admin_force_end_match(mid)
	)


# --- live custom -----------------------------------------------------------

func _filtered_custom_lobbies() -> Array:
	var q: String = %LiveCustomSearchField.text.strip_edges().to_lower()
	if q == "":
		return _custom_lobby_rows
	return _custom_lobby_rows.filter(func(l):
		return str(l.get("name", "")).to_lower().contains(q) or str(l.get("creator_username", "")).to_lower().contains(q)
	)


func _filtered_custom_in_progress() -> Array:
	var q: String = %LiveCustomSearchField.text.strip_edges().to_lower()
	if q == "":
		return _custom_in_progress_rows
	return _custom_in_progress_rows.filter(func(m):
		return str(m.get("seat1_username", "")).to_lower().contains(q) or str(m.get("seat2_username", "")).to_lower().contains(q)
	)


func _on_admin_custom_games_list(data: Dictionary) -> void:
	_custom_lobby_rows = data.get("lobbies", [])
	_custom_in_progress_rows = data.get("in_progress", [])
	_render_custom_games()


func _render_custom_games() -> void:
	%CustomLobbiesList.clear()
	for l in _filtered_custom_lobbies():
		var elapsed := int(Time.get_unix_time_from_system()) - int(l.get("created_ts", 0))
		%CustomLobbiesList.add_item("%s  host=%s  Bo%d  waiting %dm" % [
			str(l.get("name", "")), str(l.get("creator_username", "")),
			int(l.get("match_format", 1)), maxi(0, elapsed) / 60,
		])
	%CustomInProgressList.clear()
	for m in _filtered_custom_in_progress():
		%CustomInProgressList.add_item(_match_row_text(m))


func _on_force_end_custom_pressed() -> void:
	if _selected_custom_in_progress_match_id == 0:
		return
	var mid := _selected_custom_in_progress_match_id
	_confirm("Force-end custom match #%d? No result will be recorded for either player." % mid, func():
		Net.admin_force_end_match(mid)
	)


# --- stats -----------------------------------------------------------------

func _set_stats_range(hours: int, pressed_button: Button) -> void:
	_stats_range_hours = hours
	for b in [%Range24hButton, %Range7dButton, %Range30dButton]:
		b.button_pressed = (b == pressed_button)
	Net.admin_get_presence_stats(hours)


func _on_admin_presence_stats(rows: Array) -> void:
	%PresenceChart.set_samples(rows)
	if rows.is_empty():
		%StatsSummaryLabel.text = "No presence data yet for this range."
		return
	var peak := 0
	var total := 0
	for r in rows:
		var c := int(r.get("count", 0))
		peak = maxi(peak, c)
		total += c
	%StatsSummaryLabel.text = "Peak online: %d   Average: %.1f   (%d samples)" % [peak, float(total) / rows.size(), rows.size()]


# --- plan tournaments (one-off + recurring templates) -----------------------

## Reads the 5 bucket rows into the {bucket: {points, items}} shape the
## server's TournamentPrizes.sanitize() expects. Empty buckets are omitted —
## the server rejects a "gap" (a set bucket after an unset earlier one), so
## leaving a later bucket blank while filling an earlier one is fine, but not
## the reverse.
func _gather_prize_spec() -> Dictionary:
	var spec := {}
	var buckets := [
		["1", %PlanPrize1PointsField, %PlanPrize1ItemsField],
		["2", %PlanPrize2PointsField, %PlanPrize2ItemsField],
		["3", %PlanPrize3PointsField, %PlanPrize3ItemsField],
		["4_8", %PlanPrize4_8PointsField, %PlanPrize4_8ItemsField],
		["9_16", %PlanPrize9_16PointsField, %PlanPrize9_16ItemsField],
	]
	for row in buckets:
		var bucket: String = row[0]
		var points_field: LineEdit = row[1]
		var items_field: LineEdit = row[2]
		var points_text := points_field.text.strip_edges()
		var points := int(points_text) if points_text.is_valid_int() else 0
		var items := []
		for raw_id in items_field.text.split(",", false):
			var id := raw_id.strip_edges()
			if id != "":
				items.append(id)
		if points > 0 or not items.is_empty():
			spec[bucket] = {"points": points, "items": items}
	return spec


func _selected_weekdays() -> Array:
	var boxes := [%PlanWeekday0, %PlanWeekday1, %PlanWeekday2, %PlanWeekday3, %PlanWeekday4, %PlanWeekday5, %PlanWeekday6]
	var days := []
	for i in range(boxes.size()):
		if boxes[i].button_pressed:
			days.append(i)
	return days


## HH:MM (24h, UTC) -> minutes since midnight, or -1 if malformed.
func _parse_time_of_day(text: String) -> int:
	var parts := text.strip_edges().split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1
	var h := int(parts[0])
	var m := int(parts[1])
	if h < 0 or h > 23 or m < 0 or m > 59:
		return -1
	return h * 60 + m


func _availability_string() -> String:
	match int(%PlanAvailabilityOption.selected):
		1: return "semi_private"
		2: return "private"
		_: return "open"


func _on_plan_create_now_pressed() -> void:
	var name: String = %PlanNameField.text.strip_edges()
	if name == "":
		%StatusLabel.text = "Enter a tournament name."
		return
	var start_hours_text: String = %PlanStartInHoursField.text.strip_edges()
	if start_hours_text != "" and not start_hours_text.is_valid_float():
		%StatusLabel.text = "Enter a whole/decimal number of hours for 'Start in N hours', or leave it blank for the default (24)."
		return
	var start_hours := float(start_hours_text) if start_hours_text.is_valid_float() else 24.0
	var check_in_text: String = %PlanCheckInWindowMinutesField.text.strip_edges()
	var check_in_minutes := int(check_in_text) if check_in_text.is_valid_int() else 30

	var now := int(Time.get_unix_time_from_system())
	var start_ts := now + int(start_hours * 3600.0)
	var check_in_open_ts := start_ts - check_in_minutes * 60
	# Signup runs from creation (now) until check-in opens — same simplified
	# shape the recurring scheduler uses, for consistent behavior between the
	# two creation paths.
	var signup_close_ts := check_in_open_ts

	var bracket_text: String = %PlanBracketSizeField.text.strip_edges()
	Net.admin_create_tournament_now({
		"name": name,
		"bracket_size": int(bracket_text) if bracket_text.is_valid_int() else 32,
		"match_format": 3 if int(%PlanFormatOption.selected) == 1 else 1,
		"allow_small": %PlanAllowSmallCheck.button_pressed,
		"availability": _availability_string(),
		"password": %PlanPasswordField.text,
		"signup_close_ts": signup_close_ts,
		"check_in_open_ts": check_in_open_ts,
		"start_ts": start_ts,
		"prize_spec": _gather_prize_spec(),
	})


func _on_plan_save_template_pressed() -> void:
	var name: String = %PlanNameField.text.strip_edges()
	if name == "":
		%StatusLabel.text = "Enter a tournament name."
		return
	var weekdays := _selected_weekdays()
	if weekdays.is_empty():
		%StatusLabel.text = "Pick at least one weekday for the recurring template."
		return
	var time_of_day := _parse_time_of_day(%PlanTimeOfDayField.text)
	if time_of_day < 0:
		%StatusLabel.text = "Enter the time of day as HH:MM (24h, UTC)."
		return
	var check_in_text: String = %PlanCheckInWindowMinutesField.text.strip_edges()
	var signup_text: String = %PlanSignupWindowHoursField.text.strip_edges()
	var bracket_text: String = %PlanBracketSizeField.text.strip_edges()

	Net.admin_create_template({
		"name": name,
		"weekdays": weekdays,
		"time_of_day_minutes": time_of_day,
		"bracket_size": int(bracket_text) if bracket_text.is_valid_int() else 32,
		"match_format": 3 if int(%PlanFormatOption.selected) == 1 else 1,
		"allow_small": %PlanAllowSmallCheck.button_pressed,
		"availability": _availability_string(),
		"password": %PlanPasswordField.text,
		"signup_window_hours": int(signup_text) if signup_text.is_valid_int() else 24,
		"check_in_window_minutes": int(check_in_text) if check_in_text.is_valid_int() else 30,
		"prize_spec": _gather_prize_spec(),
	})


func _on_admin_template_list(rows: Array) -> void:
	_template_rows = rows
	_render_template_list()


func _render_template_list() -> void:
	%PlanTemplatesList.clear()
	for t in _template_rows:
		var days := ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
		var day_names := []
		for d in (t.get("weekdays", []) as Array):
			day_names.append(days[int(d)])
		var minutes := int(t.get("time_of_day_minutes", 0))
		var time_str := "%02d:%02d" % [minutes / 60, minutes % 60]
		var active_tag := "" if bool(t.get("active", false)) else " [PAUSED]"
		var last := int(t.get("last_created_start_ts", 0))
		var last_str := Time.get_datetime_string_from_unix_time(last, true) if last > 0 else "never"
		%PlanTemplatesList.add_item("#%d  %s  [%s @ %s UTC]  last fired: %s%s" % [
			int(t.get("id", 0)), str(t.get("name", "")), ", ".join(day_names), time_str, last_str, active_tag,
		])


func _on_plan_toggle_active_pressed() -> void:
	if _selected_template_id == 0:
		return
	var t := _template_rows.filter(func(x): return int(x.get("id", 0)) == _selected_template_id)
	var currently_active := bool(t[0].get("active", false)) if not t.is_empty() else false
	Net.admin_set_template_active(_selected_template_id, not currently_active)


func _on_plan_delete_template_pressed() -> void:
	if _selected_template_id == 0:
		return
	var tid := _selected_template_id
	_confirm("Delete this recurring template? Already-created tournaments from it are unaffected.", func():
		Net.admin_delete_template(tid)
	)


## Routes to the matching client-side cosmetic lookup (all four are plain
## RefCounted static classes, safe to call from this admin tool the same way
## net_node.gd already calls Avatars.sanitize()/Frames.sanitize()/etc.).
func _texture_for_catalog_item(type: String, id: String) -> Texture2D:
	match type:
		"avatar": return Avatars.texture_for(id)
		"frame": return Frames.texture_for(id)
		"background": return Backgrounds.texture_for(id)
		"table_background": return TableBackgrounds.texture_for(id)
		"sleeve": return Sleeves.texture_for(id)
		_: return null


func _on_admin_prize_catalog(rows: Array) -> void:
	_prize_catalog_rows = rows
	%PlanPrizeCatalogList.clear()
	for item in rows:
		var type := str(item.get("type", ""))
		var id := str(item.get("id", ""))
		var idx: int = %PlanPrizeCatalogList.add_item("%s  [%s/%s]  id: %s" % [
			str(item.get("name", "")), type, str(item.get("source", "")), id,
		])
		var tex := _texture_for_catalog_item(type, id)
		if tex != null:
			%PlanPrizeCatalogList.set_item_icon(idx, tex)


func _on_plan_catalog_item_selected(index: int) -> void:
	if index < 0 or index >= _prize_catalog_rows.size():
		return
	var id := str(_prize_catalog_rows[index].get("id", ""))
	DisplayServer.clipboard_set(id)
	%StatusLabel.text = "Copied '%s' to clipboard — paste it into a prize items field." % id


# --- confirmation dialog ----------------------------------------------------

func _confirm(message: String, on_confirmed: Callable) -> void:
	_pending_confirm = on_confirmed
	%ConfirmDialog.dialog_text = message
	%ConfirmDialog.popup_centered()


func _on_confirm_dialog_confirmed() -> void:
	if _pending_confirm.is_valid():
		_pending_confirm.call()
	_pending_confirm = Callable()


# --- tabs / auto-refresh -----------------------------------------------------

func _on_tab_changed(_tab: int) -> void:
	var current: Control = %Tabs.get_current_tab_control()
	if current == null:
		return
	match current.name:
		"Tournaments":
			%LiveRefreshTimer.stop()
			if _tournament_rows.is_empty():
				_on_refresh_tournaments_pressed()
		"LiveRanked":
			Net.admin_list_live_ranked()
			%LiveRefreshTimer.start()
		"LiveCustom":
			Net.admin_list_custom_games()
			%LiveRefreshTimer.start()
		"Stats":
			%LiveRefreshTimer.stop()
			Net.admin_get_presence_stats(_stats_range_hours)
		"PlanTournaments":
			%LiveRefreshTimer.stop()
			Net.admin_list_prize_catalog()
			Net.admin_list_templates()
		_:
			%LiveRefreshTimer.stop()


func _on_live_refresh_tick() -> void:
	var current: Control = %Tabs.get_current_tab_control()
	if current == null:
		return
	match current.name:
		"LiveRanked":
			Net.admin_list_live_ranked()
		"LiveCustom":
			Net.admin_list_custom_games()


func _show_main_panel() -> void:
	if %MainPanel.visible:
		return
	%LoginPanel.visible = false
	%MainPanel.visible = true
	%WelcomeLabel.text = "Signed in as %s" % str(Session.account.get("username", ""))
	Net.admin_recent_actions(100)
