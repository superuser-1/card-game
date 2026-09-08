extends Node
## Autoload singleton (registered as "MusicPlayer"). Owns one persistent
## AudioStreamPlayer on the "Music" bus that survives scene swaps, so moving
## between the login screen and the menus doesn't restart the track.
##
## Each screen calls the matching play_*() in its _ready(); if that track is
## already the one playing it's a no-op. The Music bus sends to Master, so the
## master volume / mute / mute-when-unfocused logic in session.gd already
## covers it; music_volume in Session.settings is the independent cap applied
## to the Music bus itself (see Session.apply_settings).

const MENU_THEME_PATH := "res://assets/sounds/the_mountain-epic-main_menue_theme.mp3"
const GAME_THEME_PATH := "res://assets/sounds/kulakovka-game_screen_theme.mp3"

var _player: AudioStreamPlayer
var _current_path := ""


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = &"Music"
	add_child(_player)
	# Safety net in case the stream isn't flagged to loop after import.
	_player.finished.connect(_on_finished)


## Menu / login theme. Called from login_screen and main_menu _ready().
func play_menu() -> void:
	_play(MENU_THEME_PATH)


## In-match theme. Called from game_ui _ready().
func play_game() -> void:
	_play(GAME_THEME_PATH)


func stop() -> void:
	_current_path = ""
	_player.stream = null
	_player.stop()


func _play(path: String) -> void:
	if path == _current_path and _player.playing:
		return
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("MusicPlayer: could not load %s" % path)
		return
	# MP3/Ogg import may not carry a loop flag — force it so the theme repeats.
	if stream is AudioStreamMP3 or stream is AudioStreamOggVorbis:
		stream.loop = true
	_current_path = path
	_player.stream = stream
	_player.play()


func _on_finished() -> void:
	if _current_path != "" and _player.stream != null:
		_player.play()
