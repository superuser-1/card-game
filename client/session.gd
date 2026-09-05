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

## Stash for the match-end summary so match_result_screen can read it after the
## scene swap (signals aren't queued for scenes that load later). Set by
## whoever handles Net.match_ended; cleared by the result screen once shown.
var last_match_summary: Dictionary = {}

## Same idea for the match_found payload (player names / avatars / elo): the
## queue screen stashes it here right before swapping to the game scene, which
## then reads it on _ready since the signal already fired.
var last_match_info: Dictionary = {}

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
