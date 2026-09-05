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
##   master_volume : float 0..1   (default 0.8)
##   fullscreen    : bool         (default false)
##   sp_reveal_mode: bool         (default false) — Singleplayer only; if true,
##                                the solo match starts with the opponent card
##                                visible. Multiplayer is always hidden.
var settings: Dictionary = {}

## Set right before a forced-logout goto(login_screen) so login_screen.gd can
## show *why* the player landed back there instead of silently reloading a
## blank form. Read-and-clear by login_screen._ready().
var kicked_message: String = ""

## Stash for the match-end summary so match_result_screen can read it after the
## scene swap (signals aren't queued for scenes that load later). Set by
## whoever handles Net.match_ended; cleared by the result screen once shown.
var last_match_summary: Dictionary = {}

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
	"fullscreen": false,
	"sp_reveal_mode": false,
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
	Net.kicked.connect(_on_kicked)


## The server connection just dropped — most commonly because this account
## just logged in from somewhere else and the server enforces one live
## connection per account (see Net._bind_session). Whatever screen this
## client happens to be on, force it back to the login form rather than
## leaving a stale, un-authenticated screen sitting there looking normal
## while every RPC it fires silently goes nowhere.
func _on_kicked() -> void:
	if not is_logged_in():
		return
	clear()
	kicked_message = "Disconnected — this account may have signed in elsewhere. Please log in again."
	goto("res://client/login_screen.tscn")


# --- account / token ---------------------------------------------------------

func set_account(a: Dictionary) -> void:
	account = a.duplicate(true)


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
## so this only NAVIGATES for tournament matches (non-empty tournament_ctx),
## but tracks current_match_id for every match_found.
func _on_tournament_match_found(info: Dictionary) -> void:
	current_match_id = int(info.get("match_id", 0))
	if (info.get("tournament_ctx", {}) as Dictionary).is_empty():
		return
	last_match_info = info
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
	var vol: float = clampf(float(settings.get("master_volume", 0.8)), 0.0, 1.0)
	var master_bus := AudioServer.get_bus_index("Master")
	if master_bus != -1:
		AudioServer.set_bus_volume_db(master_bus, linear_to_db(vol) if vol > 0.0 else -80.0)
		AudioServer.set_bus_mute(master_bus, vol <= 0.0)

	var want_fullscreen: bool = bool(settings.get("fullscreen", false))
	var mode := DisplayServer.window_get_mode()
	var is_fullscreen := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if want_fullscreen and not is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not want_fullscreen and is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)


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
