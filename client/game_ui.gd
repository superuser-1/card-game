extends Control
## Client UI. Pure renderer of server state — holds no game logic of its own.
## Choosing/responding is always a drag: the active player drags a card onto
## one of the 3 offered CategoryViews (submitting category+card together;
## the other two simply aren't rendered again once the server moves past
## awaiting_category). The responder drags a card onto that SAME single
## category once it's been served to them, instead of clicking.

@onready var _status_label: Label = %StatusLabel
@onready var _score_label: Label = %ScoreLabel
@onready var _turn_timer_label: Label = %TurnTimerLabel
@onready var _round_cap_label: Label = %RoundCapLabel
@onready var _exit_button: Button = %ExitButton
@onready var _forfeit_dialog: ConfirmationDialog = %ForfeitDialog
@onready var _admin_ended_dialog: AcceptDialog = %AdminEndedDialog
@onready var _category_box: HBoxContainer = %CategoryBox
@onready var _hand_box: Control = %HandBox
@onready var _table_label: Label = %TableLabel
@onready var _last_round_label: Label = %LastRoundLabel
@onready var _left_card_slot: Control = %LeftCardSlot
@onready var _right_card_slot: Control = %RightCardSlot
@onready var _left_avatar: TextureRect = %LeftAvatar
@onready var _left_frame: TextureRect = %LeftFrame
@onready var _left_bg: TextureRect = %LeftBg
@onready var _left_name: Label = %LeftName
@onready var _left_elo: Label = %LeftElo
@onready var _left_stars: Label = %LeftStars
@onready var _right_avatar: TextureRect = %RightAvatar
@onready var _right_frame: TextureRect = %RightFrame
@onready var _right_bg: TextureRect = %RightBg
@onready var _right_name: Label = %RightName
@onready var _right_elo: Label = %RightElo
@onready var _right_stars: Label = %RightStars

const CARD_VIEW_SCENE := preload("res://client/card_view.tscn")
const CATEGORY_VIEW_SCENE := preload("res://client/category_view.tscn")
const TABLE_CARD_SCENE := preload("res://client/table_card_view.tscn")

# Pacing for the round-resolution choreography (see _play_resolution_sequence):
# left card appears face down, beat, right card appears, beat, flip left,
# beat, flip right, beat, color the values, beat, attack + destroy, point
# award, beat, then the table clears for the next round.
const BEAT_SHORT := 0.525
const BEAT_MEDIUM := 0.9
# Beat where both cards sit face down after the responder commits, before the
# flip — so both players actually see the card backs.
const REVEAL_HOLD := 0.5

# Hand fan layout. Cards are scaled down from their native CardView.CARD_SIZE
# and spread by HAND_MAX_SPACING_SCALE of their (scaled) width by default,
# but that spacing shrinks — down to HAND_MIN_SPACING_SCALE, i.e. more
# overlap — as needed so any hand size still fits _hand_box's width instead
# of running off-screen.
const HAND_CARD_SCALE := 0.62
const HAND_MAX_SPACING_SCALE := 0.62
const HAND_MIN_SPACING_SCALE := 0.22
const HAND_MAX_ROTATION_DEG := 10.0
const HAND_ARC_LIFT_PX := 22.0    # how much higher the center card sits vs the edges
const HAND_BOX_HEIGHT_FALLBACK := 224.0    # matches HandBox's anchored height in game_ui.tscn

# Card-draw choreography. Any card that appears in own_hand for the first time
# — the whole opening hand, or the single card pulled from the reserve after a
# tie — flies in from off the right edge, angled, and eases into its fan slot,
# with the draw sound firing as it starts to move. DEAL_STAGGER spaces out the
# opening seven; a lone tie redraw plays with no delay. The sound is a WAV
# (not MP3) so playback starts on the attack with no decoder priming lag.
const DRAW_SOUND := preload("res://assets/sounds/card_draw.wav")
# Round-resolution stingers. ATTACK plays on the winner card's lunge; WIN/LOSS
# play once the round is decided, picked per this client's own outcome.
const ATTACK_SOUND := preload("res://assets/sounds/boxing_sound.wav")
const ROUND_WIN_SOUND := preload("res://assets/sounds/star_win_sound.wav")
const ROUND_LOSS_SOUND := preload("res://assets/sounds/game_loss.wav")

# Per-sound level trim, in decibels. 0 = the file's own level, -6 ≈ half as
# loud, +6 ≈ twice. Adjust here to balance the mix; everything also rides the
# master volume from the options screen.
const DRAW_DB := +6.0
const ATTACK_DB := -3.0
const ROUND_WIN_DB := -7.0
const ROUND_LOSS_DB := -7.0
const DEAL_STAGGER := 0.14
const DEAL_TWEEN := 0.60
const DEAL_ENTRY_TILT := 22.0    # extra degrees a card carries while flying in
const DEAL_ENTRY_SCALE := 0.82   # fraction of rest scale at the start of the flight

# Maps each category key to the card field it compares, for the reveal panel.
# Mirrors GameEngine.CATEGORY_FIELD.
const CATEGORY_FIELD := {
	"most_oscars": "oscars_won",
	"first_published": "release_year",
	"box_office": "box_office_usd",
	"longest_runtime": "runtime_minutes",
	"shortest_runtime": "runtime_minutes",
	"highest_budget": "budget_usd",
	"lowest_budget": "budget_usd",
	"highest_audience_score": "audience_score",
	"director_oscars": "director_oscars_won",
	"oldest_director": "director_age_at_release",
	"youngest_director": "director_age_at_release",
	"profit_cost_ratio": "profit_cost_ratio_pct",
}

# Categories about the director, not the film — the reveal caption shows the
# director name(s) instead of the movie title for these.
const DIRECTOR_CATEGORIES := ["oldest_director", "youngest_director", "director_oscars"]

var _my_player_id := 0
var _latest_state: Dictionary = {}
var _last_shown_result: Dictionary = {}
var _revealing := false

# Locally-ticked mirror of the server's per-turn clock. Re-synced from
# `turn_seconds_left` on every state broadcast; counted down in _process
# between broadcasts so the label moves smoothly.
var _client_turn_left := -1.0
# unix s this tournament round is force-resolved if unfinished (from the match's
# tournament_ctx); 0 for non-tournament games. Shown as a slow countdown under
# the turn clock so a long round has a visible ceiling.
var _round_deadline_ts := 0
var _forfeiting := false
var _hand_render_id := 0

# Purely a client-side display preference — the server doesn't know or care
# what order your hand is drawn in. Holds card ids in the order the player
# has dragged them into; reconciled against each new own_hand on every
# render (see _reordered_hand) since server broadcasts happen independently
# of any reordering the player has done.
var _hand_order: Array = []

# card_id -> its live CardView node, so drag-hover reordering can reposition
# existing cards in place (tweened) instead of rebuilding the whole hand on
# every mouse-move while dragging.
var _hand_card_views: Dictionary = {}
var _hand_box_width: float = 0.0
var _hand_box_height: float = 0.0

# Every card id ever seen in own_hand. A card in a fresh render whose id isn't
# here is a genuine draw (opening deal or post-tie reserve pull) and gets the
# fly-in + draw sound; cards already listed just snap to their slot. Cards
# are unique across the deck, so ids are only ever added, never revisited.
var _seen_hand_ids: Dictionary = {}

# Non-empty while a reorder drag is actively hovering over a target — the
# hypothetical order if it were dropped right now. Committed to _hand_order
# on a successful drop, discarded otherwise (see _on_hand_drag_ended).
var _live_preview_order: Array = []

# The face-down/face-up card shown on the table this round, if any. Placed
# in real time as each side commits (_ensure_left/right_card_face_down),
# not just as a burst once the round is fully resolved — the server resolves
# atomically the instant the responder commits, so there's no separate
# broadcast for "opponent has responded but not yet resolved"; the RESPONDER
# still gets to see their own card appear immediately though, since they
# know what they just dragged without needing to wait on the network.
var _left_table_card: TableCardView = null
var _right_table_card: TableCardView = null

# Card-back (sleeve) ids for the face-down table cards. Left is always mine,
# right is the opponent's — set from the match_found payload / Session account.
var _my_sleeve := ""
var _opp_sleeve := ""

# Single shared player for the card-draw sound. One voice on purpose: calling
# play() again while it's still sounding restarts it from the top, so every
# draw in a fast burst gets a clean, audible attack — the newest draw always
# wins the voice instead of a pile of overlapping copies smearing together.
var _draw_sfx: AudioStreamPlayer = null


const MATCH_RESULT_SCENE := "res://client/match_result_screen.tscn"
const TOURNAMENT_BRACKET_SCENE := "res://client/tournament_bracket_screen.tscn"
const MATCH_SUMMARY_PANEL := preload("res://client/match_summary_panel.tscn")

func _ready() -> void:
	Net.player_assigned.connect(_on_player_assigned)
	Net.state_updated.connect(_on_state_updated)
	Net.error_received.connect(_on_error_received)
	Net.match_ended.connect(_on_match_ended)
	Net.match_found.connect(_apply_match_info)
	Net.match_force_ended.connect(_on_match_force_ended)

	MusicPlayer.play_game()

	_draw_sfx = AudioStreamPlayer.new()
	_draw_sfx.stream = DRAW_SOUND
	_draw_sfx.volume_db = DRAW_DB
	_draw_sfx.bus = &"SFX"
	add_child(_draw_sfx)

	_exit_button.pressed.connect(func(): _forfeit_dialog.popup_centered())
	_forfeit_dialog.confirmed.connect(_on_forfeit_confirmed)
	_admin_ended_dialog.confirmed.connect(_on_admin_ended_confirmed)
	_admin_ended_dialog.canceled.connect(_on_admin_ended_confirmed)

	# Networked: match_found already fired before this scene loaded — read the
	# stash. Solo: the stash is empty and Net.match_found fires just after.
	if not Session.last_match_info.is_empty():
		_apply_match_info(Session.last_match_info)
	else:
		_apply_match_info({})

	_status_label.text = "Connecting..."
	# The UI is loaded via a scene swap after the match already started, so
	# ask Net to re-emit the assignment + latest state we missed. No-op (and
	# harmless) in singleplayer, where the UI is in the tree before the deal.
	Net.replay_state()
	# So drag-hover hit-testing falls through to GameUI's own _can_drop_data
	# (the empty-space fallback) in gaps within the hand not covered by any
	# CardView, instead of _hand_box itself swallowing the hit and rejecting
	# the drop there.
	_hand_box.mouse_filter = Control.MOUSE_FILTER_IGNORE


## ESC raises the Give Up confirmation — same as the exit button. Once a
## forfeit is already in flight (button disabled) or the dialog is up, it's
## a no-op; the dialog handles its own ESC-to-dismiss.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if not _forfeit_dialog.visible and not _exit_button.disabled:
		_forfeit_dialog.popup_centered()
	get_viewport().set_input_as_handled()


func _on_player_assigned(player_id: int) -> void:
	_my_player_id = player_id
	_status_label.text = "You are Player %d. Waiting for opponent..." % player_id


## Fills the two player panels. LEFT is always this client's player, RIGHT is
## always the opponent — matching the client-relative card layout (your card
## is always left of the category). "Your" side prefers the live Session
## account; falls back to the match_found payload, then to neutral defaults
## (e.g. the --solo CLI role, which has no login).
func _apply_match_info(info: Dictionary) -> void:
	_round_deadline_ts = int((info.get("tournament_ctx", {}) as Dictionary).get("round_deadline_ts", 0))
	var acc: Dictionary = Session.account
	var my_name: String = str(acc.get("display_name", info.get("your_name", "You")))
	var my_elo: int = int(acc.get("elo", info.get("your_elo", 0)))
	var my_avatar: String = str(acc.get("avatar", ""))
	if my_avatar == "":
		my_avatar = str(info.get("your_avatar", ""))
	var my_frame: String = str(acc.get("frame", ""))
	if my_frame == "" and not acc.has("frame"):
		my_frame = str(info.get("your_frame", ""))
	var my_bg: String = str(acc.get("background", ""))
	if my_bg == "" and not acc.has("background"):
		my_bg = str(info.get("your_background", ""))
	var my_sleeve: String = str(acc.get("sleeve", ""))
	if my_sleeve == "" and not acc.has("sleeve"):
		my_sleeve = str(info.get("your_sleeve", ""))

	_left_name.text = my_name
	_left_elo.text = "Elo %d" % my_elo if my_elo > 0 else ""
	_left_avatar.texture = Avatars.texture_for(my_avatar)
	_left_frame.texture = Frames.texture_for(my_frame)
	_left_bg.texture = Backgrounds.texture_for(my_bg)

	_my_sleeve = my_sleeve
	if _left_table_card != null:
		_left_table_card.set_sleeve(_my_sleeve)

	if info.is_empty():
		_right_name.text = ""
		_right_elo.text = ""
		_right_avatar.texture = Avatars.texture_for(Avatars.DEFAULT_ID)
		_right_frame.texture = null
		_right_bg.texture = null
		return

	_opp_sleeve = str(info.get("opponent_sleeve", ""))
	if _right_table_card != null:
		_right_table_card.set_sleeve(_opp_sleeve)

	_right_name.text = str(info.get("opponent_name", "Opponent"))
	var opp_elo: int = int(info.get("opponent_elo", 0))
	_right_elo.text = "Elo %d" % opp_elo if opp_elo > 0 else ""
	_right_avatar.texture = Avatars.texture_for(str(info.get("opponent_avatar", "")))
	_right_frame.texture = Frames.texture_for(str(info.get("opponent_frame", "")))
	_right_bg.texture = Backgrounds.texture_for(str(info.get("opponent_background", "")))


func _on_error_received(message: String) -> void:
	_status_label.text = "Error: " + message


## An admin force-ended this match server-side (net_node.gd's
## admin_force_end_match) — no result was recorded, so there's no
## match_ended summary to route to the result screen; just tell the player
## and send them home.
func _on_match_force_ended() -> void:
	_admin_ended_dialog.popup_centered()


func _on_admin_ended_confirmed() -> void:
	Session.goto("res://client/main_menu.tscn")


func _on_forfeit_confirmed() -> void:
	if _forfeiting:
		return
	_forfeiting = true
	_exit_button.disabled = true
	_status_label.text = "Giving up..."
	Net.forfeit_match()


func _process(_delta: float) -> void:
	_update_round_cap_label()
	if _latest_state.is_empty():
		return
	var on_clock: int = int(_latest_state.get("on_clock_player", 0))
	# The round-resolution choreography locks the board so the next player
	# can't act yet; the server freezes its own turn clock for the same window
	# (net_node REVEAL_PAUSE_SECONDS / TIMEOUT_PAUSE_SECONDS). Hold the local
	# mirror too — otherwise the displayed number runs ahead of the server and
	# the next player looks like they lost their first several seconds to the
	# animation. _on_state_updated re-syncs _client_turn_left from the server
	# on the next broadcast, which re-aligns the two once play resumes.
	if on_clock == 0 or _revealing:
		_turn_timer_label.text = ""
		return
	if _client_turn_left > 0.0:
		_client_turn_left = maxf(0.0, _client_turn_left - _delta)
	var who: String = "Your" if on_clock == _my_player_id else "Opponent's"
	# Truncate (not ceil) so the last whole second reads "0 s" — the server
	# fires somewhere inside that second, so it looks like it resolves at zero.
	_turn_timer_label.text = "%s turn — %d s" % [who, int(_client_turn_left)]


## Slow countdown to this tournament round's hard-cap deadline, shown under the
## turn clock. Non-tournament games have no deadline and hide the label.
func _update_round_cap_label() -> void:
	if _round_deadline_ts <= 0:
		_round_cap_label.visible = false
		return
	var left := _round_deadline_ts - int(Time.get_unix_time_from_system())
	if left > 0:
		_round_cap_label.text = "Round time limit: %d:%02d" % [left / 60, left % 60]
	else:
		_round_cap_label.text = "Round time limit reached — resolving…"
	_round_cap_label.visible = true


func _on_match_ended(summary: Dictionary) -> void:
	# Stash for the result screen (signals aren't queued across a scene swap),
	# then navigate — but only after any in-progress round-reveal choreography
	# has finished, so the final round still plays out on screen.
	var ending_match_id := int(summary.get("match_id", 0))
	Session.last_match_summary = summary
	Session.queue_achievement_toasts(summary.get("achievement_unlocks", []))
	await _wait_for_reveal_to_finish()
	var tournament_ctx: Dictionary = summary.get("tournament_ctx", {})
	if not tournament_ctx.is_empty() and bool(summary.get("unfinished", false)):
		# The match didn't finish through play (hit the tournament hard cap, or
		# both players dropped) — the bracket result was decided on score. Give
		# the player a beat to read why before the bracket screen takes over.
		_status_label.text = "Match ended early — bracket result decided on score."
		await get_tree().create_timer(3.0).timeout
		if not is_inside_tree():
			return  # Session's global listener already swapped us into the next round
	if not tournament_ctx.is_empty():
		# The server can create and push the NEXT tournament round's
		# match_found while we were still mid-reveal above — Session's global
		# listener already jumped us straight into that new match. Don't stomp
		# back over it by navigating to the bracket screen for a match that's
		# already stale.
		if Session.current_match_id != 0 and Session.current_match_id != ending_match_id:
			return
		if ResourceLoader.exists(TOURNAMENT_BRACKET_SCENE):
			Session.last_match_info = {}
			Session.goto(TOURNAMENT_BRACKET_SCENE)
			return
	_show_result_overlay(summary)


## End-of-match summary as an overlay on the finished board, so the final card
## layout stays visible behind it. The full-screen match_result_screen is only
## a fallback now (no board to overlay).
func _show_result_overlay(summary: Dictionary) -> void:
	if get_node_or_null("ResultOverlay") != null:
		return
	var was_solo := Net.is_solo

	_exit_button.disabled = true

	var layer := CanvasLayer.new()
	layer.name = "ResultOverlay"
	layer.layer = 80
	add_child(layer)

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.03, 0.05, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)

	var panel: MatchSummaryPanel = MATCH_SUMMARY_PANEL.instantiate()
	center.add_child(panel)
	panel.set_again_label("Play Again" if was_solo else "Find Another")
	panel.render(summary)
	panel.again_pressed.connect(func() -> void:
		if was_solo:
			Net.start_singleplayer()
			Session.goto("res://client/game_ui.tscn")
		else:
			Session.goto("res://client/queue_screen.tscn"))
	panel.menu_pressed.connect(func() -> void:
		if was_solo:
			Net.end_singleplayer()
		Session.goto("res://client/main_menu.tscn"))


func _wait_for_reveal_to_finish() -> void:
	while _revealing:
		await get_tree().process_frame


func _on_state_updated(state: Dictionary) -> void:
	# Always store the newest state first. In solo mode there's no network
	# latency, so the bot can commit its next move (a second state_updated)
	# while an earlier call to this function is still asleep inside the
	# await below — if that still-sleeping call were to blindly overwrite
	# _latest_state with its own now-stale local `state` param once it wakes
	# up, the UI would silently revert to showing the game a step behind
	# where the server actually is. Storing here, and having the reveal
	# below read back through _latest_state instead of its own `state`
	# param, means whichever update arrived last always wins.
	_latest_state = state

	var tsl: float = float(state.get("turn_seconds_left", -1.0))
	if tsl >= 0.0:
		_client_turn_left = tsl

	if _revealing:
		return

	var incoming_result: Dictionary = state.get("last_round_result", {})
	var is_fresh_result := not incoming_result.is_empty() and incoming_result != _last_shown_result

	if is_fresh_result:
		_last_shown_result = incoming_result
		_last_round_label.text = _build_reveal_text(incoming_result)
		if incoming_result.get("timeout", false):
			_revealing = true
			_render_hand(state.get("own_hand", []), true)
			await _play_timeout_sequence(incoming_result)
			_revealing = false
			_render()
			return
		# During the choreographed reveal the next round's categories/cards must
		# not become playable — that's enforced by _render() short-circuiting on
		# _revealing (so no fresh drop targets are built) plus the _revealing
		# guards in the drop handlers. The HAND itself stays draggable though,
		# so the player can keep re-arranging their fan (a purely cosmetic,
		# client-side order) while the animation plays. Deliberately NOT
		# clearing the category tile here — it stays visible through the reveal
		# and only clears at the very end of the sequence.
		_revealing = true
		_render_hand(state.get("own_hand", []), true)
		await _play_resolution_sequence(incoming_result)
		_revealing = false

	_render()


func _clear_table() -> void:
	for child in _category_box.get_children():
		child.queue_free()


func _render() -> void:
	var s := _latest_state
	if s.is_empty():
		return

	_score_label.text = "You: %d   Opponent: %d   Round %d" % [
		s.own_score, s.opponent_score, s.round_number
	]
	_render_series_stars(s)

	var am_active: bool = s.active_player == _my_player_id
	var awaiting_category: bool = s.phase == "awaiting_category"
	var awaiting_response: bool = s.phase == "awaiting_response"
	var already_committed: bool = s.your_card_committed

	if awaiting_category and am_active:
		_status_label.text = "Your turn: drag a card onto a category."
	elif awaiting_category and not am_active:
		_status_label.text = "Opponent is choosing a category..."
	elif awaiting_response and already_committed:
		_status_label.text = "Waiting for opponent's response..."
	elif awaiting_response and not already_committed:
		_status_label.text = "Category: %s — drag a card onto it to respond." % s.chosen_category
	else:
		_status_label.text = "Phase: %s" % s.phase

	if s.chosen_category != "":
		_table_label.text = "Chosen category: %s" % s.chosen_category
	else:
		_table_label.text = ""

	# Deliberately reading _last_shown_result (the client's own record of the
	# last round it actually revealed) rather than s.last_round_result — the
	# server clears its own copy the instant the NEXT round's category gets
	# chosen (see game_engine.gd submit_category_and_card), which happens at
	# unpredictable timing depending on how fast the next active player
	# acts. Reading the server's live copy made this panel disappear at that
	# same unpredictable moment instead of persisting until a new result
	# actually exists to replace it.
	if not _last_shown_result.is_empty():
		_last_round_label.text = _build_reveal_text(_last_shown_result)
	else:
		_last_round_label.text = ""

	if _revealing:
		return

	# Hand cards are ALWAYS draggable outside the reveal choreography so the
	# player can re-arrange their fan while waiting for the opponent (the fan
	# order is a purely client-side cosmetic preference). Actually *playing* a
	# card stays gated: the drop targets (CategoryView tiles) are only created
	# in _render_table() when it's this player's move, so a drag when it isn't
	# your turn can only land back in the hand (a re-order) or nowhere (a
	# reject shake). The reveal path re-renders the hand with draggable=false.
	_render_table()
	_render_hand(s.own_hand, true)


## A Bo3/Bo5 match plays as a series of full 7-card games — each finished game
## is one star next to the winner's avatar, filled left-to-right as games are
## won. Hidden entirely for a plain Bo1 match, where there's only ever one
## game and a star row would be redundant with the outcome screen.
func _render_series_stars(s: Dictionary) -> void:
	var games_to_win: int = int(s.get("games_to_win", 1))
	if games_to_win <= 1:
		_left_stars.visible = false
		_right_stars.visible = false
		return
	var series_wins: Dictionary = s.get("series_wins", {})
	var my_wins: int = int(series_wins.get(_my_player_id, 0))
	var opp_wins: int = int(series_wins.get(3 - _my_player_id, 0))
	_left_stars.visible = true
	_right_stars.visible = true
	_left_stars.text = _star_string(my_wins, games_to_win)
	_right_stars.text = _star_string(opp_wins, games_to_win)


func _star_string(games_won: int, games_to_win: int) -> String:
	var out := ""
	for i in range(games_to_win):
		out += "★" if i < games_won else "☆"
	return out


func _play_timeout_sequence(result: Dictionary) -> void:
	var timed_out: int = int(result.get("timed_out_player", 0))
	if timed_out == _my_player_id:
		_status_label.text = "You ran out of time — category forfeited, one card lost."
	else:
		_status_label.text = "Opponent ran out of time — you take the category."
	# No lunge on a timeout, but it still resolves a category — same win/loss
	# stinger as a played-out round.
	var i_won_cat: bool = int(result.get("winner", 0)) == _my_player_id
	_play_sfx(ROUND_WIN_SOUND if i_won_cat else ROUND_LOSS_SOUND, ROUND_WIN_DB if i_won_cat else ROUND_LOSS_DB)
	await get_tree().create_timer(BEAT_MEDIUM * 2.0).timeout
	_clear_table()
	_clear_table_cards()


func _build_reveal_text(result: Dictionary) -> String:
	if result.get("timeout", false):
		var who: String = "You" if int(result.get("timed_out_player", 0)) == _my_player_id else "Opponent"
		var cat: String = str(result.get("category", ""))
		var head: String = cat if cat != "" else "No category chosen"
		return "%s\n%s ran out of time\n(category forfeited)" % [head, who]
	var c1: Dictionary = result.player_1_card
	var c2: Dictionary = result.player_2_card
	var category: String = result.category
	return "%s\n%s\n%s\nvs\n%s\n%s" % [
		category,
		_reveal_caption(category, c1), _format_value(category, c1),
		_reveal_caption(category, c2), _format_value(category, c2),
	]


## Caption shown above the value on a revealed card: the movie title normally,
## the director name(s) for the director-based categories.
func _reveal_caption(category: String, card: Dictionary) -> String:
	if category in DIRECTOR_CATEGORIES:
		return str(card.get("director", card.get("title", "")))
	return str(card.get("title", ""))


func _format_value(category: String, card: Dictionary) -> String:
	var field: String = CATEGORY_FIELD.get(category, "")
	var value = card.get(field)
	if value == null:
		return "N/A"
	if field in ["box_office_usd", "budget_usd"]:
		return "$" + _format_thousands(int(value))
	if field == "runtime_minutes":
		return "%d min" % int(value)
	if field == "director_age_at_release":
		return "%d yrs" % int(value)
	if field == "audience_score":
		return "%d / 100" % int(value)
	if field == "profit_cost_ratio_pct":
		return "%+d%%" % int(value)
	# release_year / oscars_won / director_oscars_won — whole numbers; never
	# render them as "1994.0".
	if value is int or value is float:
		return str(int(value))
	return str(value)


func _format_thousands(value: int) -> String:
	var digits := str(value)
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i != 0:
			out = "," + out
	return out


## The round-resolution choreography. By this point the left card is
## normally already sitting face down (placed in real time as soon as the
## category was chosen — see _ensure_left_card_face_down) and, for the
## responder's own view, the right card usually is too (placed optimistically
## the instant they dropped their response). This only needs to fill in
## whichever of those didn't already happen — chiefly the active player's
## first-ever look at the opponent's card, which has no earlier real-time
## moment since the server resolves atomically the instant the responder
## commits — then flips both, colors them win/lose (or tied), plays the
## winner "attacking" the loser which breaks apart, shows a point-award
## popup, and finally clears the whole table (category tile included) for
## the next round.
func _play_resolution_sequence(result: Dictionary) -> void:
	# Client-relative sides: MY card is always the left one, the opponent's the
	# right one — regardless of who started the round.
	var left_card: Dictionary = result.player_1_card if _my_player_id == 1 else result.player_2_card
	var right_card: Dictionary = result.player_2_card if _my_player_id == 1 else result.player_1_card
	var category: String = result.category

	if _left_table_card == null:
		_ensure_left_card_face_down()
		await get_tree().create_timer(BEAT_SHORT).timeout
	if _right_table_card == null:
		_ensure_right_card_face_down()
		await get_tree().create_timer(BEAT_SHORT).timeout

	var left_view := _left_table_card
	var right_view := _right_table_card

	# Hold on both face-down cards for a beat so both players see the backs
	# before the reveal starts (the server resolves the instant the responder
	# commits, so without this the flip begins immediately).
	await get_tree().create_timer(REVEAL_HOLD).timeout

	# A card-handling click as each card turns over, same sound as drawing.
	_play_draw_sfx()
	await left_view.flip_to_face_up(left_card, _format_value(category, left_card), _reveal_caption(category, left_card))
	await get_tree().create_timer(BEAT_SHORT).timeout
	_play_draw_sfx()
	await right_view.flip_to_face_up(right_card, _format_value(category, right_card), _reveal_caption(category, right_card))

	await get_tree().create_timer(BEAT_MEDIUM).timeout

	if result.is_tie:
		left_view.set_outcome_color(TableCardView.TIE_COLOR)
		right_view.set_outcome_color(TableCardView.TIE_COLOR)
		await get_tree().create_timer(BEAT_MEDIUM).timeout
		await left_view.play_calm_fade_out()
		await right_view.play_calm_fade_out()
	else:
		var left_wins: bool = result.winner == _my_player_id
		var winner_view: TableCardView = left_view if left_wins else right_view
		var loser_view: TableCardView = right_view if left_wins else left_view
		winner_view.set_outcome_color(TableCardView.WIN_COLOR)
		loser_view.set_outcome_color(TableCardView.LOSE_COLOR)

		await get_tree().create_timer(BEAT_MEDIUM).timeout

		var i_won: bool = result.winner == _my_player_id
		_play_sfx(ATTACK_SOUND, ATTACK_DB)
		await winner_view.play_attack(loser_view.global_position)
		await loser_view.play_destroyed()

		_play_sfx(ROUND_WIN_SOUND if i_won else ROUND_LOSS_SOUND, ROUND_WIN_DB if i_won else ROUND_LOSS_DB)
		_play_point_award_popup(i_won)
		await get_tree().create_timer(BEAT_MEDIUM).timeout
		await winner_view.play_calm_fade_out()

	_clear_table()
	_clear_table_cards()


## A floating "+1" that pops up near the score line for whoever just won the
## round, then drifts up and fades — self-contained, frees itself when done.
func _play_point_award_popup(i_won: bool) -> void:
	var popup := Label.new()
	popup.text = "+1"
	popup.add_theme_font_size_override("font_size", 28)
	popup.add_theme_color_override("font_color", TableCardView.WIN_COLOR if i_won else Color(0.8, 0.8, 0.8))
	popup.modulate.a = 0.0
	add_child(popup)
	popup.global_position = _score_label.global_position + Vector2(_score_label.size.x * 0.5, -8.0)

	var tween := create_tween()
	tween.tween_property(popup, "modulate:a", 1.0, 0.225)
	tween.parallel().tween_property(popup, "position:y", popup.position.y - 30.0, 1.35).set_trans(Tween.TRANS_SINE)
	tween.tween_interval(0.45)
	tween.tween_property(popup, "modulate:a", 0.0, 0.45)
	await tween.finished
	popup.queue_free()


func _render_table() -> void:
	_clear_table()
	var s := _latest_state
	var am_active: bool = s.active_player == _my_player_id
	var awaiting_category: bool = s.phase == "awaiting_category"
	var awaiting_response: bool = s.phase == "awaiting_response"
	var already_committed: bool = s.your_card_committed

	if awaiting_category and am_active:
		# The 3 offered choices, as drop targets. Dropping a card on one
		# submits category+card together; the other two simply aren't
		# rendered again once the server moves past awaiting_category.
		for category: String in s.offered_categories:
			var view: CategoryView = CATEGORY_VIEW_SCENE.instantiate()
			_category_box.add_child(view)
			view.set_category(category, true)
			view.card_dropped.connect(func(card_id: String): _on_category_card_dropped(category, card_id))
	elif s.chosen_category != "":
		# Category's already locked in for this round — served to the
		# responder as a drop target too (same drag-a-card-onto-it gesture);
		# still shown on the active player's own screen, just not interactive
		# there since they've already committed their card.
		var view: CategoryView = CATEGORY_VIEW_SCENE.instantiate()
		_category_box.add_child(view)
		var i_must_respond: bool = not am_active and awaiting_response and not already_committed
		view.set_category(s.chosen_category, i_must_respond)
		if i_must_respond:
			view.card_dropped.connect(_on_response_card_dropped)

	# Real-time face-down placement: left as soon as a category's chosen (a
	# mystery card to the responder, since hidden mode means they don't know
	# its contents yet — but a card-back placeholder is fine to show either
	# way), right the moment *I* commit my response. The active player's own
	# view of the right slot has no equivalent real-time moment — the server
	# resolves atomically the instant the responder commits, so for them it
	# only ever appears as part of the reveal burst (_play_resolution_sequence).
	if s.chosen_category != "":
		if am_active:
			# I chose the category, so my committed card sits on my (left) side.
			_ensure_left_card_face_down()
		else:
			# The opponent chose — their face-down card is on the right. Mine
			# joins on the left the moment I've responded.
			_ensure_right_card_face_down()
			if already_committed:
				_ensure_left_card_face_down()
	else:
		_clear_table_cards()


func _ensure_left_card_face_down() -> void:
	if _left_table_card != null:
		return
	_left_table_card = TABLE_CARD_SCENE.instantiate()
	_left_card_slot.add_child(_left_table_card)
	_left_table_card.show_face_down()
	_left_table_card.set_sleeve(_my_sleeve)


func _ensure_right_card_face_down() -> void:
	if _right_table_card != null:
		return
	_right_table_card = TABLE_CARD_SCENE.instantiate()
	_right_card_slot.add_child(_right_table_card)
	_right_table_card.show_face_down()
	_right_table_card.set_sleeve(_opp_sleeve)


func _clear_table_cards() -> void:
	if _left_table_card:
		_left_table_card.queue_free()
		_left_table_card = null
	if _right_table_card:
		_right_table_card.queue_free()
		_right_table_card = null


func _on_category_card_dropped(category: String, card_id: String) -> void:
	# A leftover category tile can still be under the cursor during the reveal
	# choreography — never let a drop there fire a real move mid-animation.
	if _revealing:
		return
	_ensure_left_card_face_down()  # instant feedback, don't wait on the round-trip
	_play_draw_sfx()               # same soft thud as drawing — a card hitting the table
	Net.submit_category_and_card(category, card_id)


func _on_response_card_dropped(card_id: String) -> void:
	if _revealing:
		return
	# My card — always my (left) side, even though I'm the responder here.
	_ensure_left_card_face_down()  # instant feedback, don't wait on the round-trip
	_play_draw_sfx()
	Net.submit_response_card(card_id)


## Reconciles _hand_order against the server's current hand: keeps existing
## ids in the order the player last arranged them, drops ids no longer in
## hand (played/discarded), and appends any ids that are new (e.g. a tie
## redraw) at the end. Returns the actual card dicts in that order.
func _reordered_hand(hand: Array) -> Array:
	var by_id := {}
	for card: Dictionary in hand:
		by_id[card.id] = card

	var new_order: Array = []
	for id in _hand_order:
		if by_id.has(id):
			new_order.append(id)
	for card: Dictionary in hand:
		if not new_order.has(card.id):
			new_order.append(card.id)

	_hand_order = new_order
	return new_order.map(func(id): return by_id[id])


## Computes where slot `index` of `n` total cards belongs, in _hand_box's
## local space. Pulled out of _render_hand so the live drag-reorder preview
## (_apply_live_positions) can reuse the exact same math to tween EXISTING
## cards to their hypothetical new slots, instead of duplicating it.
func _hand_slot_transform(index: int, n: int) -> Dictionary:
	var card_size: Vector2 = CardView.CARD_SIZE * HAND_CARD_SCALE
	var available_width := _hand_box_width - 16.0

	# Cards overlap as much as needed (down to HAND_MIN_SPACING_SCALE) so the
	# whole hand always fits available_width, however many cards there are.
	var spacing := card_size.x * HAND_MAX_SPACING_SCALE
	if n > 1:
		var natural_width := spacing * (n - 1) + card_size.x
		if natural_width > available_width:
			spacing = max((available_width - card_size.x) / float(n - 1), card_size.x * HAND_MIN_SPACING_SCALE)

	var total_width: float = spacing * (n - 1) + card_size.x if n > 1 else card_size.x
	var start_x: float = (_hand_box_width - total_width) / 2.0
	var mid: float = float(n - 1) / 2.0
	var baseline_y: float = _hand_box_height - 15.0

	var t: float = (index - mid) / max(mid, 1.0)  # -1 (leftmost) .. 1 (rightmost)
	# Where we WANT this card's visible center to land (spacing is based on
	# the scaled/visual footprint, which is correct for this part).
	var visible_center_x := start_x + card_size.x / 2.0 + index * spacing
	# But CardView's pivot.x sits at the NATIVE half-width (120), not the
	# scaled one (~74) — since the pivot doesn't move under scaling, the
	# actual rendered center is position.x + native_half_width. Without this
	# compensation every card's true center lands (native_half - scaled_half)
	# = ~46px right of intended, shifting the whole fan off-center uniformly.
	var x := visible_center_x - CardView.CARD_SIZE.x / 2.0
	var visible_bottom_y := baseline_y - HAND_ARC_LIFT_PX * (1.0 - t * t)  # center card sits highest
	# CardView's pivot_offset is (CARD_SIZE.x/2, CARD_SIZE.y) — bottom-
	# center, at full native size, so rotation/scale reads as swinging from
	# where a hand would hold the card (see card_view.gd _ready()). Because
	# that pivot sits at the FULL native height rather than the vertical
	# center, position.y is NOT where the card visibly ends up: under
	# HAND_CARD_SCALE, the pivot math shifts the rendered card down by
	# CARD_SIZE.y * (1 - HAND_CARD_SCALE) relative to a naive assumption of
	# position == visible top-left. Subtracting the full CARD_SIZE.y here
	# compensates so visible_bottom_y is genuinely where the card's bottom
	# edge ends up, instead of rendering ~340px lower than intended (in
	# practice, off the bottom of the window).
	var y := visible_bottom_y - CardView.CARD_SIZE.y
	var rot_deg: float = lerp(-HAND_MAX_ROTATION_DEG, HAND_MAX_ROTATION_DEG, float(index) / max(n - 1, 1))
	return {"pos": Vector2(x, y), "rot_deg": rot_deg}


## Reorder-drag hover/drop detection. Godot's hit-testing only ever calls
## _can_drop_data on the SINGLE topmost Control under the cursor — it does
## NOT fall back to the parent if that control declines — so this root-level
## handler only actually fires for gaps within _hand_box not covered by any
## CardView (empty space past either end, or between widely-spaced cards;
## see _hand_box.mouse_filter = IGNORE in _ready()). The much more common
## case — cursor over some card — is handled by whichever CardView Godot's
## hit-test finds, forwarding here via reorder_hover_anywhere/
## reorder_drop_anywhere (connected per-card in _render_hand). Either way,
## the actual insertion index is computed purely from the cursor's X
## position against each slot's geometry (_update_reorder_preview), not from
## which specific card triggered the callback — that's what makes this
## robust against the heavy overlap/z-ordering in the hand fan, where a card
## mostly covered by its neighbor could otherwise silently steal the hover.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary and data.get("type") == "hand_card"):
		return false
	var dragged_id: String = data.card_id
	if not (_hand_order.has(dragged_id) or _live_preview_order.has(dragged_id)):
		return false
	if not _hand_box.get_global_rect().has_point(get_global_mouse_position()):
		return false
	_update_reorder_preview(dragged_id)
	return true


func _drop_data(_at_position: Vector2, _data: Variant) -> void:
	_commit_reorder_preview()


func _on_card_reorder_hover_anywhere(dragged_id: String) -> void:
	if _hand_box.get_global_rect().has_point(get_global_mouse_position()):
		_update_reorder_preview(dragged_id)


func _on_card_reorder_drop_anywhere(_dragged_id: String) -> void:
	_commit_reorder_preview()


func _commit_reorder_preview() -> void:
	# Only reached on an actual drop landing inside the hand (a bad drop reverts
	# via _on_hand_drag_ended instead), so it's the right place for the
	# card-set-down click — same sound as drawing or playing a card.
	_play_draw_sfx()
	if not _live_preview_order.is_empty():
		_hand_order = _live_preview_order
	_live_preview_order = []
	_reflow_after_reorder()


## After a hand re-order commits or reverts: normally a full _render(), but
## during the reveal choreography _render() short-circuits before it touches
## the hand, so re-lay-out just the fan directly instead.
func _reflow_after_reorder() -> void:
	if _revealing:
		if not _latest_state.is_empty():
			_render_hand(_latest_state.get("own_hand", []), true)
	elif not _reflow_hand_in_place(_hand_order):
		_render()  # bookkeeping fell out of sync (e.g. hand changed mid-drag) — full rebuild as a fallback


## Re-tweens every existing hand card to its slot in `order`, without freeing
## and reinstantiating any CardView. A reorder-drag never changes which cards
## are in hand, only their order, so the nodes (and the dragged card's own,
## untouched-during-drag position) just need to glide to their new spots —
## unlike the full _render_hand() rebuild this replaces, which used to visibly
## hitch on every single card release (destroy + reinstantiate every card,
## plus a one-frame layout wait). Returns false if the node bookkeeping
## doesn't match `order` 1:1, so the caller can fall back to a full render.
func _reflow_hand_in_place(order: Array) -> bool:
	var n := order.size()
	if n != _hand_card_views.size():
		return false
	for i in range(n):
		var id = order[i]
		var card_view: CardView = _hand_card_views.get(id)
		if card_view == null:
			return false
		var t := _hand_slot_transform(i, n)
		card_view.tween_to_hand_transform(t.pos, t.rot_deg, HAND_CARD_SCALE, i)
	return true


## Computes where `dragged_id` would land if dropped at the cursor's current
## X position — comparing against the OTHER cards' slot centers, as if they
## were laid out without the dragged card — and if that's different from
## what's currently previewed, tweens every other card to its new slot.
func _update_reorder_preview(dragged_id: String) -> void:
	var base: Array = _live_preview_order if not _live_preview_order.is_empty() else _hand_order
	var others: Array = base.duplicate()
	others.erase(dragged_id)

	var cursor_local_x: float = get_global_mouse_position().x - _hand_box.global_position.x

	var insert_index := others.size()
	for i in range(others.size()):
		var slot := _hand_slot_transform(i, others.size())
		var center_x: float = slot.pos.x + CardView.CARD_SIZE.x / 2.0
		if cursor_local_x < center_x:
			insert_index = i
			break

	var hypothetical: Array = others.duplicate()
	hypothetical.insert(insert_index, dragged_id)

	if hypothetical == _live_preview_order:
		return  # no change from the current preview; skip redundant re-tweening

	_live_preview_order = hypothetical
	_apply_live_positions(_live_preview_order, dragged_id)


func _apply_live_positions(order: Array, dragged_card_id: String) -> void:
	var n := order.size()
	for i in range(n):
		var id = order[i]
		if id == dragged_card_id:
			continue
		var card_view: CardView = _hand_card_views.get(id)
		if card_view == null:
			continue
		var t := _hand_slot_transform(i, n)
		card_view.tween_to_hand_transform(t.pos, t.rot_deg, HAND_CARD_SCALE, i)


## Fires when ANY drag started from a hand card ends, successful or not. If
## a live-preview reorder was showing but never got committed (dropped
## somewhere else, or not at all), revert to the last confirmed order.
func _on_hand_drag_ended() -> void:
	if _live_preview_order.is_empty():
		return
	_live_preview_order = []
	_reflow_after_reorder()


func _render_hand(hand: Array, draggable: bool) -> void:
	_hand_render_id += 1
	var my_render_id := _hand_render_id

	for child in _hand_box.get_children():
		child.queue_free()
	_hand_card_views.clear()
	_live_preview_order = []

	var n := hand.size()
	if n == 0:
		return

	var ordered_hand := _reordered_hand(hand)

	# Which of these cards are being drawn for the first time (opening deal or a
	# post-tie reserve pull). Recorded now, before the frame wait / possible
	# abandon below, so a superseded render can't make the same card animate
	# twice — worst case it snaps in silently on the next render instead.
	var fresh_ids: Dictionary = {}
	var fresh_seq := 0
	for c: Dictionary in ordered_hand:
		var cid: String = str(c.get("id", ""))
		if not _seen_hand_ids.has(cid):
			fresh_ids[cid] = fresh_seq
			fresh_seq += 1
		_seen_hand_ids[cid] = true

	# _hand_box's size (and its position within the not-yet-laid-out VBox)
	# isn't trustworthy on the very first render — that one is triggered
	# synchronously during startup (main.gd adds the UI, then immediately
	# calls Net.start_solo(), which broadcasts the first state before Godot
	# has run a single container layout pass), so _hand_box.size still reads
	# whatever placeholder value it had before any real window size was
	# communicated (observed as a bogus square (1280,1280) root Control).
	# Waiting one frame guarantees layout has actually settled.
	await get_tree().process_frame

	if my_render_id != _hand_render_id:
		return  # a newer render started while we were waiting; abandon this one

	_hand_box_width = _hand_box.size.x if _hand_box.size.x > 0.0 else get_viewport_rect().size.x
	_hand_box_height = _hand_box.size.y if _hand_box.size.y > 0.0 else HAND_BOX_HEIGHT_FALLBACK

	for i in range(n):
		var card: Dictionary = ordered_hand[i]
		var card_view: CardView = CARD_VIEW_SCENE.instantiate()
		_hand_box.add_child(card_view)
		card_view.set_card(card)
		if draggable:
			card_view.draggable = true
		else:
			card_view.disabled = true
		card_view.drag_ended.connect(_on_hand_drag_ended)
		card_view.reorder_hover_anywhere.connect(_on_card_reorder_hover_anywhere)
		card_view.reorder_drop_anywhere.connect(_on_card_reorder_drop_anywhere)
		_hand_card_views[card.id] = card_view

		var t := _hand_slot_transform(i, n)
		# Seed the resting transform either way — hover/reorder read it back —
		# then, for a freshly drawn card, override the live transform and fly
		# it in from the right.
		card_view.set_hand_transform(t.pos, t.rot_deg, HAND_CARD_SCALE, i)
		var cid: String = str(card.get("id", ""))
		if fresh_ids.has(cid):
			_animate_card_draw_in(card_view, t.pos, t.rot_deg, HAND_CARD_SCALE, i, int(fresh_ids[cid]) * DEAL_STAGGER)


## Fire the card-draw sound. Restarts the shared player from the top if it's
## still sounding from the previous draw, so each draw in the opening burst
## reads as its own distinct click rather than smearing into the last.
func _play_draw_sfx() -> void:
	if _draw_sfx == null:
		return
	_draw_sfx.play()


## One-shot playback of a spaced-out effect (the round-resolution stingers).
## Throwaway player per call, frees itself when done; SFX bus so the options
## volume/mute still applies. Unlike the draw sound these never machine-gun, so
## a fresh voice each time is fine and lets the lunge + outcome overlap.
func _play_sfx(stream: AudioStream, volume_db := 0.0) -> void:
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	player.bus = &"SFX"
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


## Fly a freshly drawn card in from just off the right edge of the hand area,
## carrying an extra tilt and slightly undersized, easing into the resting
## slot transform already seeded by set_hand_transform(). `delay` staggers the
## opening deal; the draw sound fires the instant this card starts moving.
func _animate_card_draw_in(card: CardView, rest_pos: Vector2, rest_rot_deg: float, rest_scale: float, z: int, delay: float) -> void:
	if not is_instance_valid(card):
		return

	var origin := Vector2(_hand_box_width + CardView.CARD_SIZE.x * 0.5, rest_pos.y + 48.0)
	card.z_index = z
	card.position = origin
	card.rotation_degrees = rest_rot_deg + DEAL_ENTRY_TILT
	card.scale = Vector2(rest_scale * DEAL_ENTRY_SCALE, rest_scale * DEAL_ENTRY_SCALE)
	card.modulate.a = 0.0

	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if not is_instance_valid(card):
			return

	_play_draw_sfx()

	var tween := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "position", rest_pos, DEAL_TWEEN)
	tween.tween_property(card, "rotation_degrees", rest_rot_deg, DEAL_TWEEN)
	tween.tween_property(card, "scale", Vector2(rest_scale, rest_scale), DEAL_TWEEN)
	tween.tween_property(card, "modulate:a", 1.0, DEAL_TWEEN * 0.45)
