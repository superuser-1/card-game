extends Node
## Bootstrap entry point. Role is chosen by an explicit command-line flag,
## never auto-detected, so there's never ambiguity about who is authoritative.
##
## Server:      godot --headless -- --server [--port=8910]
## Client:      godot -- [--address=127.0.0.1] [--port=8910]
## Solo vs bot: godot -- --solo   (single process, no networking, plays Player 2)
## Bot client:  godot --headless -- --bot [--address=127.0.0.1] [--port=8910]
##   (headless auto-playing NETWORK client, for network smoke-testing — see
##   tests/bot_client.gd. Not to be confused with --solo's BotPlayer opponent.)
## Custom-game test: godot --headless -- --custom-game-test --role=host|guest|guest2 --game-name=X
##   (headless auto-playing client that drives the friend-invite custom-game
##   flow — create/join/full-lobby-rejection — see tests/custom_game_bot_client.gd.)

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port := NetConfig.DEFAULT_PORT
	var address := NetConfig.DEFAULT_ADDRESS
	var is_server := false
	var is_bot := false
	var is_solo := false
	var is_solo_test := false
	var is_drag_test := false
	var is_custom_game_test := false

	for arg: String in args:
		if arg == "--server":
			is_server = true
		elif arg == "--bot":
			is_bot = true
		elif arg == "--custom-game-test":
			is_custom_game_test = true
		elif arg == "--solo":
			is_solo = true
		elif arg == "--solo-test":
			is_solo = true
			is_solo_test = true
		elif arg == "--drag-test":
			is_solo = true
			is_drag_test = true
		elif arg.begins_with("--port="):
			port = int(arg.substr("--port=".length()))
		elif arg.begins_with("--address="):
			address = arg.substr("--address=".length())

	if is_server:
		Net.start_server(port)
	elif is_bot:
		Net.start_client(address, port)
		add_child(preload("res://tests/bot_client.gd").new())
	elif is_custom_game_test:
		Net.start_client(address, port)
		add_child(preload("res://tests/custom_game_bot_client.gd").new())
	elif is_solo:
		# UI (or the headless test driver) must be in the tree — so its
		# _ready() connects Net's signals — BEFORE start_solo() fires the
		# initial player_assigned/state_updated; those signals aren't queued
		# for late subscribers.
		var ui := preload("res://client/game_ui.tscn").instantiate()
		add_child(ui)
		if is_solo_test:
			# Also run the auto-play driver alongside the real UI — lets the
			# resolution-sequence animation etc. actually execute (driven by
			# the same Net signals the UI listens to) so it can be watched or
			# checked for runtime errors without needing real mouse input.
			add_child(preload("res://tests/solo_smoke_test.gd").new())
		elif is_drag_test:
			# Injects REAL input events to exercise the actual drag-and-drop
			# code path (_get_drag_data etc.), which solo-test's direct
			# Net.submit_* calls never touch.
			add_child(preload("res://tests/drag_smoke_test.gd").new())
		Net.start_solo()
	else:
		# Plain client: connect, then hand off to the login screen (which
		# resumes a saved session token if there is one, else shows the form).
		# The in-game UI is reached later via a scene swap once a match starts.
		Net.start_client(address, port)
		get_tree().change_scene_to_file("res://client/login_screen.tscn")
