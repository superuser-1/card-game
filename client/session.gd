extends Node
## Autoload singleton (registered as "Session"), present in the plain-client
## role only in practice but harmless everywhere. Holds the cross-scene client
## state that must survive get_tree().change_scene_to_file() calls: the logged-in
## account snapshot, the server session token, and user settings.
##
## Scene navigation goes through goto() so every screen has one consistent way
## to move; the options overlay goes through open_options() so any screen can
## raise it without embedding its own copy.

const OPTIONS_MODAL_SCENE := "res://client/options_modal.tscn"

## Per-instance profile, from a `--profile=NAME` command-line user arg. Lets
## two clients launched on the same machine (see scripts/run_local) keep
## SEPARATE saved sessions/settings instead of sharing one file — without it,
## the second client auto-resumes the first client's token and the server's
## one-connection-per-account rule kicks the first client off.
var _profile := ""
var SESSION_PATH := "user://flickbattle/session.cfg"
var SETTINGS_PATH := "user://flickbattle/settings.cfg"

## Last account snapshot pushed from the server. Shape (safe subset, never has
## password material):
##   { id:int, username:String, display_name:String, elo:int, games:int,
##     wins:int, losses:int, draws:int, points:int, owned_rewards:Array,
##     is_provisional:bool, quests:Array }
var account: Dictionary = {}

## Server-issued session token; also mirrored to SESSION_PATH for auto-resume.
var token: String = ""

## Loaded settings, with defaults applied. Keys:
##   master_volume  : float 0..1  (default 0.8)  — Master bus gain
##   sfx_volume     : float 0..1  (default 0.8)  — SFX bus gain
##   muted          : bool        (default false) — hard mute, independent of sliders
##   mute_unfocused : bool        (default false) — silence audio while the window
##                                 is not the active app
##   fullscreen     : bool        (default false)
##   borderless     : bool        (default false) — borderless windowed; ignored
##                                 while fullscreen is on
##   vsync          : bool        (default true)
##   fps_cap        : int         (default 0)     — 0 means uncapped
var settings: Dictionary = {}

## Whether the OS window currently has focus — tracked so mute_unfocused can
## drop/restore audio without fighting the user's explicit mute/volume choices.
var _app_focused: bool = true

## Set right before a forced-logout goto(login_screen) so login_screen.gd can
## show *why* the player landed back there instead of silently reloading a
## blank form. Read-and-clear by login_screen._ready().
var kicked_message: String = ""

## True between a Net.force_logout signal and the server_disconnected that
## follows it — tells _on_kicked the drop is a deliberate server sign-out (wipe
## the token) rather than a network blip (keep it and auto-resume).
var _deliberate_kick: bool = false

## Stash for the match-end summary so match_result_screen can read it after the
## scene swap (signals aren't queued for scenes that load later). Set by
## whoever handles Net.match_ended; cleared by the result screen once shown.
var last_match_summary: Dictionary = {}

## Achievement unlocks not yet shown as a main-menu toast. Filled from match
## summaries (game_ui) and out-of-band tournament pushes (Net.achievements_
## unlocked, wired below); drained + cleared by main_menu each time it loads.
## Each entry: {id, name, tier_name, points, reward}.
var pending_achievement_toasts: Array = []

## Same idea for the match_found payload (player names / avatars / elo): the
## queue screen stashes it here right before swapping to the game scene, which
## then reads it on _ready since the signal already fired.
var last_match_info: Dictionary = {}

## Non-zero while this client is checked into a tournament (set on a
## successful Net.tournament_check_in reply, cleared on elimination/victory/
## the tournament completing — see Net's tournament_checked_in/
## tournament_updated signals). Used client-side to block Singleplayer, since
## solo has no server RPC for the check-in lock to gate.
var active_tournament_id: int = 0

## Live tournament snapshots this account has a stake in, keyed by tournament
## id — the main menu renders one narrow status card per entry. Populated by
## Net.tournament_joined/my_tournament_status, kept fresh by
## tournament_checked_in/tournament_updated. An entry is removed once that
## tournament completes/cancels, this account is eliminated in an actual
## match, or it never checked in and was replaced by a bot for missing
## check-in (see _tournament_has_my_stake).
var my_tournaments: Dictionary = {}

const _DEFAULT_SETTINGS := {
	"master_volume": 0.8,
	"sfx_volume": 0.8,
	"muted": false,
	"mute_unfocused": false,
	"fullscreen": false,
	"borderless": false,
	"vsync": true,
	"fps_cap": 0,
}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute("user://flickbattle")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile="):
			_profile = arg.substr("--profile=".length()).strip_edges()
	if _profile != "":
		SESSION_PATH = "user://flickbattle/session_%s.cfg" % _profile
		SETTINGS_PATH = "user://flickbattle/settings_%s.cfg" % _profile
		print("Session: using profile '%s'" % _profile)
	load_settings()
	apply_settings()
	load_token()

	Net.tournament_joined.connect(_on_tournament_joined)
	Net.tournament_withdrawn.connect(_on_tournament_withdrawn)
	Net.tournament_checked_in.connect(_on_tournament_checked_in)
	Net.tournament_updated.connect(_on_tournament_updated)
	Net.my_tournament_status.connect(_on_my_tournament_status)
	Net.match_found.connect(_on_tournament_match_found)
	Net.achievements_unlocked.connect(queue_achievement_toasts)
	Net.kicked.connect(_on_kicked)
	Net.force_logout.connect(_on_force_logout)


## The server connection just dropped — most commonly because this account
## just logged in from somewhere else and the server enforces one live
## connection per account (see Net._bind_session). Whatever screen this
## client happens to be on, force it back to the login form rather than
## leaving a stale, un-authenticated screen sitting there looking normal
## while every RPC it fires silently goes nowhere.
func _on_kicked() -> void:
	if not is_logged_in():
		return
	if _deliberate_kick:
		_deliberate_kick = false
		clear()
		if kicked_message == "":
			kicked_message = "Disconnected — this account may have signed in elsewhere. Please log in again."
		goto("res://client/login_screen.tscn")
		return
	# Unexpected drop — keep the saved token so login_screen auto-resumes and
	# the server can drop us straight back into the held match (see
	# net_node RECONNECT_GRACE_SECONDS / _try_rejoin_match).
	kicked_message = "Connection lost — reconnecting…"
	goto("res://client/login_screen.tscn")


## The server is deliberately ending this session (account signed in elsewhere).
## Flag it so the imminent _on_kicked wipes the token instead of reconnecting.
func _on_force_logout(reason: String) -> void:
	_deliberate_kick = true
	if reason != "":
		kicked_message = reason


# --- account / token ---------------------------------------------------------

func set_account(a: Dictionary) -> void:
	account = a.duplicate(true)


## Append achievement-unlock rows to the pending main-menu toast queue,
## skipping any already queued (same id + tier). Safe to call with [] or junk.
func queue_achievement_toasts(list: Array) -> void:
	for e in list:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var key := "%s@%s" % [str(e.get("id", "")), str(e.get("tier_index", e.get("tier_name", "")))]
		var seen := false
		for q in pending_achievement_toasts:
			if "%s@%s" % [str(q.get("id", "")), str(q.get("tier_index", q.get("tier_name", "")))] == key:
				seen = true
				break
		if not seen:
			pending_achievement_toasts.append(e)


func save_token(t: String) -> void:
	token = t
	var cfg := ConfigFile.new()
	cfg.set_value("session", "token", t)
	cfg.save(SESSION_PATH)


func load_token() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SESSION_PATH) == OK:
		token = str(cfg.get_value("session", "token", ""))
	return token


func clear() -> void:
	account = {}
	token = ""
	var cfg := ConfigFile.new()
	cfg.set_value("session", "token", "")
	cfg.save(SESSION_PATH)


func is_logged_in() -> bool:
	return not account.is_empty()


# --- tournament lock tracking (Session, not a screen, so it survives scene
# swaps between the bracket/wait screen, the game screen, and back) ---

## The match_id of whatever match we were last told to join — set here for
## every match_found regardless of kind. game_ui's tournament-match-ended
## handler compares against this before navigating to the bracket screen: the
## server can create + push the next tournament round's match_found while the
## current game screen is still mid-reveal-animation, so by the time that
## delayed navigation would fire, a NEWER match may have already taken over.
## Without this guard, the stale "go to the bracket screen" call would stomp
## back over the already-correct "go to the new game" navigation.
var current_match_id: int = 0

## A tournament round can start while the player is on ANY screen (main menu,
## the tournament list, mid-browse elsewhere) — not just the bracket/wait
## screen, which only exists (and only listens for match_found itself) once
## the player has navigated there. Session is the one thing alive the whole
## time, so it's the reliable place to catch "your tournament match is ready"
## and jump into the game regardless of what's currently on screen. Ranked/
## solo match_found already navigates fine via queue_screen/start_singleplayer,
## so this only NAVIGATES for tournament matches (non-empty tournament_ctx).
## It always stashes last_match_info + current_match_id though: solo fires
## match_found synchronously from start_singleplayer BEFORE game_ui exists to
## catch it, so Session is the only listener alive in time to keep the payload
## (opponent avatar/frame/bg) for game_ui._ready to read.
func _on_tournament_match_found(info: Dictionary) -> void:
	current_match_id = int(info.get("match_id", 0))
	last_match_info = info
	# Tournament matches always need Session to navigate (a round can fire from
	# any screen). A ranked/custom match_found normally arrives on the queue
	# screen, which does its own transition — but on a RECONNECT it arrives on
	# the login or menu screen instead, and Session is the only listener alive
	# to catch it. So navigate from here too, but ONLY from a real client
	# screen: the --solo / --bot roles run under res://main.tscn with no scene
	# navigation at all (game_ui is added as a child there), and swapping the
	# scene out from under them would kill the match / test driver.
	var cur := get_tree().current_scene
	var path := cur.scene_file_path if cur else ""
	if not path.begins_with("res://client/"):
		return
	if path == "res://client/queue_screen.tscn" or path == "res://client/game_ui.tscn":
		return
	goto("res://client/game_ui.tscn")


## Answer to Net.request_my_tournament() — called on menu load/relogin since
## my_tournaments/active_tournament_id are otherwise only ever populated
## reactively by signals fired during THIS session (a fresh process, or a
## relog, would otherwise show no status cards at all despite real signups).
func _on_my_tournament_status(tournaments: Array) -> void:
	my_tournaments.clear()
	# Trust this fetch completely, including the negative case: if the server
	# says "no live tournaments" (or none of them are still a live run for
	# this account — e.g. one got orphaned/stuck server-side and self-healed
	# without us hearing about it), any previously-set lock must be dropped
	# rather than left lingering from earlier in the session.
	active_tournament_id = 0
	var my_id := int(account.get("id", 0))
	for t in tournaments:
		my_tournaments[int(t.get("id", 0))] = t
		if _tournament_is_my_live_run(t):
			for p in (t.get("participants", []) as Array):
				if int(p.get("account_id", -1)) == my_id and bool(p.get("checked_in", false)):
					active_tournament_id = int(t.get("id", 0))
					break


func _on_tournament_joined(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		var t: Dictionary = result.get("tournament", {})
		my_tournaments[int(t.get("id", 0))] = t


func _on_tournament_withdrawn(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		var t: Dictionary = result.get("tournament", {})
		my_tournaments.erase(int(t.get("id", 0)))


func _on_tournament_checked_in(result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		var t: Dictionary = result.get("tournament", {})
		active_tournament_id = int(t.get("id", 0))
		my_tournaments[int(t.get("id", 0))] = t


func _on_tournament_updated(tournament: Dictionary) -> void:
	var tid := int(tournament.get("id", 0))
	# Deliberately unconditional (erase/assign are no-ops if tid wasn't
	# already tracked) — the lock check below must still run even if this
	# tournament somehow isn't tracked as a card, so a desync between the two
	# can't leave the gameplay lock stuck forever.
	if _tournament_card_still_relevant(tournament):
		my_tournaments[tid] = tournament
	else:
		my_tournaments.erase(tid)
	if active_tournament_id == tid and not _tournament_is_my_live_run(tournament):
		active_tournament_id = 0


## Whether to keep showing a status card for this tournament at all — an
## eliminated player still sees their card (with an "Eliminated" notice, see
## main_menu.gd) until the tournament itself wraps up, so this is deliberately
## more permissive than _tournament_is_my_live_run below.
func _tournament_card_still_relevant(tournament: Dictionary) -> bool:
	var status := str(tournament.get("status", ""))
	if status == "completed" or status == "cancelled":
		return false
	var my_id := int(account.get("id", 0))
	for p in (tournament.get("participants", []) as Array):
		if int(p.get("account_id", -1)) == my_id:
			return true
	return false


## False once this account no longer has a LIVE, playable run in this
## tournament: it's completed/cancelled, this account was eliminated in an
## actual match, or this account never checked in and was replaced by a bot
## for round 1. Used to release the check-in gameplay lock (active_tournament_id)
## — independent of whether the status card itself is still shown.
func _tournament_is_my_live_run(tournament: Dictionary) -> bool:
	var status := str(tournament.get("status", ""))
	if status == "completed" or status == "cancelled":
		return false
	var my_id := int(account.get("id", 0))
	for p in (tournament.get("participants", []) as Array):
		if int(p.get("account_id", -1)) == my_id:
			if int(p.get("eliminated_round", 0)) != 0:
				return false
			if status != "signup" and status != "check_in" and not bool(p.get("checked_in", false)):
				return false
			return true
	return false


# --- settings --------------------------------------------------------------

func load_settings() -> void:
	settings = _DEFAULT_SETTINGS.duplicate(true)
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for key in _DEFAULT_SETTINGS.keys():
		if cfg.has_section_key("settings", key):
			settings[key] = cfg.get_value("settings", key)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for key in settings.keys():
		cfg.set_value("settings", key, settings[key])
	cfg.save(SETTINGS_PATH)


func apply_settings() -> void:
	var master_vol: float = clampf(float(settings.get("master_volume", 0.8)), 0.0, 1.0)
	var sfx_vol: float = clampf(float(settings.get("sfx_volume", 0.8)), 0.0, 1.0)
	var master_bus := AudioServer.get_bus_index("Master")
	if master_bus != -1:
		AudioServer.set_bus_volume_db(master_bus, linear_to_db(master_vol) if master_vol > 0.0 else -80.0)
	var sfx_bus := AudioServer.get_bus_index("SFX")
	if sfx_bus != -1:
		AudioServer.set_bus_volume_db(sfx_bus, linear_to_db(sfx_vol) if sfx_vol > 0.0 else -80.0)
	_refresh_master_mute()

	# Window mode: fullscreen wins; otherwise windowed, with the borderless flag
	# tracking the setting.
	var want_fullscreen: bool = bool(settings.get("fullscreen", false))
	var want_borderless: bool = bool(settings.get("borderless", false))
	var mode := DisplayServer.window_get_mode()
	var is_fullscreen := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if want_fullscreen and not is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not want_fullscreen and is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if not want_fullscreen:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, want_borderless)

	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if bool(settings.get("vsync", true)) else DisplayServer.VSYNC_DISABLED
	)
	Engine.max_fps = maxi(0, int(settings.get("fps_cap", 0)))


## Master bus mute is the OR of the explicit "muted" setting, a zeroed master
## slider, and (when mute_unfocused is on) the window not being focused.
func _refresh_master_mute() -> void:
	var master_bus := AudioServer.get_bus_index("Master")
	if master_bus == -1:
		return
	var muted: bool = bool(settings.get("muted", false))
	var zeroed: bool = float(settings.get("master_volume", 0.8)) <= 0.0
	var focus_muted: bool = bool(settings.get("mute_unfocused", false)) and not _app_focused
	AudioServer.set_bus_mute(master_bus, muted or zeroed or focus_muted)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_app_focused = false
		_refresh_master_mute()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_app_focused = true
		_refresh_master_mute()


# --- navigation ----------------------------------------------------------

func goto(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)


func open_options() -> void:
	if get_tree().root.has_node("OptionsModalLayer"):
		return
	var layer := CanvasLayer.new()
	layer.name = "OptionsModalLayer"
	layer.layer = 128
	var modal: Node = load(OPTIONS_MODAL_SCENE).instantiate()
	layer.add_child(modal)
	get_tree().root.add_child(layer)
