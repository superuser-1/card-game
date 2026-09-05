# Plan: Landing Page, Accounts, Elo Ladder, Points & Rewards

Status: **IMPLEMENTED 2026-09-02** (WS0–WS8). Headless-verified: engine tests +
`server_store_test` (73 assertions) green; solo smoke; real 2-process PvP match
(Elo ±20 persisted); server bot-fill after 15s. Remaining polish noted in §4 and
in the "not done yet" list at the bottom. Owner split followed
`feedback-haiku-delegation`: Sonnet did `net_node.gd` + glue + all test runs;
Haiku built the 10 UI/scene files and the first `ServerStore` pass.

Decisions locked with the user (2026-09-02, do not re-ask):

| Topic | Decision |
|---|---|
| Backend/persistence | **Extend the headless Godot `--server`** with a local store (plain JSON files behind a `ServerStore` module). SQLite is a later drop-in. |
| Multiplayer dev flow | **Server-side bot fill**: client connects to a real `--server`, enters a queue; if no human pairs within `BOT_FILL_SECONDS`, the server seats a bot in slot 2. |
| Auth | **Username + password now.** Real register/login screen before the menu; server stores salted, iterated hashes. `auth_provider` field reserved for Steam/Discord/Google/Apple later. |
| Bot matches & ranking | **Write, but flagged.** Bot-filled multiplayer games update Elo/points and match history, each record carries `is_bot_match=true` so the ladder view filters them and they can be wiped pre-launch. Singleplayer is always unranked. |

Sensible defaults chosen without asking (flagged for later tuning):

- Elo: `START_ELO=1000`; K = 40 for first 10 games (provisional), 20 up to 30 games, 10 after.
- Points: win `+10`, loss `+3`, draw `+5`.
- Ladder: single global ladder, rank by account Elo. `season_id` field reserved, unused.
- Rewards: **data model + catalog stub only this pass.** No shop UI (user said "maybe later").
- Password hash: salted + 200k-round iterated SHA-256 (pure GDScript, see WS1). **Not production-grade** — replace with Argon2id/bcrypt via a native addon before any real launch.

---

## 1. Architecture changes

### 1.1 Client scene flow (new)

Today `main.gd` instantiates `client/game_ui.tscn` directly for the plain-client
role and there is no menu. New flow for the **plain client role only** (the
`--solo` / `--bot` / `--server` test roles are untouched and still bypass all of
this):

```
main.gd (plain client)
  -> connects Net to server
  -> if a saved session token resumes OK  -> main_menu.tscn
     else                                 -> login_screen.tscn
login_screen  -> (on auth ok) -> main_menu.tscn
main_menu buttons:
  Singleplayer -> starts LOCAL solo GameEngine -> game_ui.tscn   (unranked)
  Multiplayer  -> queue_screen.tscn -> (match_found) -> game_ui.tscn
                                    -> (match_ended) -> match_result_screen.tscn -> main_menu
  Options      -> options_modal (overlay, does not leave the screen)
  Deckbuilder  -> deckbuilder_screen.tscn -> main_menu
  Ladder       -> ladder_screen.tscn -> main_menu   (5th enton the menu; small)
```

Navigation helper: `Session.goto("res://client/<scene>.tscn")` wraps
`get_tree().change_scene_to_file`. `Net` and `Session` are autoloads and survive
scene swaps.

### 1.2 New autoload: `Session` (`client/session.gd`, registered as `Session`)

Holds cross-scene client state:

```gdscript
var token: String = ""                 # server session token, also saved to user://flickbattle/session.cfg
var account: Dictionary = {}           # last account snapshot from server (see shape in 2.3)
var settings: Dictionary = {}          # loaded from user://flickbattle/settings.cfg

func load_settings() -> void           # ConfigFile -> settings dict, with defaults
func save_settings() -> void
func apply_settings() -> void          # master volume bus, fullscreen mode
func set_account(a: Dictionary) -> void
func save_token(t: String) -> void / load_token() -> String / clear() -> void
func goto(scene_path: String) -> void
func open_options() -> void            # adds options_modal.tscn under a CanvasLayer on the root viewport
```

Settings keys + defaults: `master_volume=0.8` (0..1), `fullscreen=false`,
`sp_reveal_mode=false` (Singleplayer only: if true, solo starts with opponent
card visible; Multiplayer is always hidden).

### 1.3 Server: multi-match + auth gate (`net/net_node.gd`, major refactor — Sonnet)

`Net` currently holds a single `engine` and pairs the first two raw peers. New
model:

- **Auth gate.** A freshly connected peer is `unauthenticated`. It may only call
  `_rpc_auth_*`. All other server RPCs reject an unauthenticated sender. On auth
  success the server records `peer_id -> account_id` and `peer_id -> token`.
- **`Match` inner structure** (plain Dictionary or small class), one per active game:
  `{ id:int, engine:GameEngine, seats:{1:<peer_id|BOT>, 2:<peer_id|BOT>},
     account_ids:{1:int|0, 2:int|0}, is_bot_match:bool, ended:bool }`.
  `Net` keeps `_matches: Dictionary` (id -> Match) and `_peer_to_match: Dictionary`.
- RPC handlers (`_rpc_submit_*`) resolve the sender's Match via `_peer_to_match`,
  then act on that match's `engine`. `_broadcast_state()` becomes
  `_broadcast_match(match)`.
- **`MatchQueue`.** `_rpc_enqueue_match` adds `{account_id, elo, since_ms}` to a
  queue (reject if already queued or in a match). A `_tick_matchmaking()` timer
  (every 1.0s) pairs the longest-waiting entry with the nearest-Elo other entry
  inside a window that widens with wait time: `window = 50 + 25 * floor(wait_s/5)`,
  cap 400. If the longest-waiting entry has waited `>= BOT_FILL_SECONDS` (15s)
  and still no partner, create a bot match for it. On pair/bot-fill: build a
  `Match`, `engine.deal_hands()`, send `match_found` + assignments + first state.
- **Bot fill** reuses `rules/bot_player.gd` exactly like solo mode does today; a
  server-side timer drives the bot's moves (lift the `_maybe_trigger_bot`
  /`_bot_choose_*` logic out of the solo path so both share it, keyed by match).
- **Match end.** When `engine` reports `game_over`, server:
  1. computes Elo + points deltas via `ServerStore` (skip entirely if
     singleplayer — but singleplayer never runs on the server, so in practice
     "every server match writes a record"; `is_bot_match` set from the seat map),
  2. `ServerStore.record_match(...)` (persists match + updated accounts),
  3. sends `match_ended` to each human seat with their personalised summary
     (see 2.3), 4. tears down the Match.
- **State replay for late subscribers.** Because scenes swap, `game_ui` may
  `_ready()` *after* `match_found`/first `state_updated`. Add
  `Net.replay_state()` (client-side): re-emits the cached `player_assigned` +
  last `state_updated`. `game_ui._ready()` calls it.
- **Disconnect.** Unchanged policy (abort match) but now per-match: mark
  `ended`, notify the remaining human, and — if the game had a clear
  leader/there was real play — optionally award the disconnect as a loss to the
  leaver. MVP: keep current "just abort, no rating change" and leave a `TODO`.

### 1.4 Server: persistence module (`server/server_store.gd` — Haiku, WS1)

Pure GDScript, no Node deps (mirrors `rules/` style). JSON files under
`user://flickbattle/`: `accounts.json` = `{ "accounts": [ ... ] }`,
`matches.json` = `{ "matches": [ ... ] }`. Load into memory on `open()`, rewrite
the whole file on each mutation (fine for the scale we need; SQLite later).

---

## 2. Data model & API contract

Both client and server code against this. It is fully specified here so the
Haiku UI workstreams don't need the netcode refactor to land first.

### 2.1 Persisted account record (server-only fields marked ⛔ never sent to client)

```
id: int                 # autoincrement
username: String        # unique, case-insensitive, 3..20 chars [A-Za-z0-9_]
display_name: String    # defaults to username; editable later
auth_provider: String   # "password" now; reserved: "steam"|"discord"|"google"|"apple"
⛔ pw_salt: String (hex)
⛔ pw_hash: String (hex)
⛔ pw_iterations: int
elo: int                # START_ELO
games: int              # total ranked games finished (drives provisional K)
wins: int
losses: int
draws: int
points: int             # soft currency
owned_rewards: Array[String]   # reward ids
season_id: int          # reserved, always 1 for now
created_ts: int (unix)
```

### 2.2 Persisted match record

```
id: int
ts: int (unix)
account_1_id: int
account_2_id: int       # 0 if that seat was a bot
winner: int             # 0 draw, 1, or 2
elo_1_before, elo_1_after, elo_2_before, elo_2_after: int
points_1_delta, points_2_delta: int
is_bot_match: bool
```

### 2.3 Wire shapes (server -> client)

`account_snapshot` (safe subset): `{ id, username, display_name, elo, games,
wins, losses, draws, points, owned_rewards, is_provisional }` where
`is_provisional = games < 10`.

`auth_result`: `{ ok:bool, error:String, token:String, account:account_snapshot }`

`match_found`: `{ match_id:int, your_seat:int (1|2), opponent_name:String,
opponent_elo:int, is_bot_match:bool }`

`match_ended`: `{ outcome:String ("win"|"loss"|"draw"), your_score:int,
opponent_score:int, ranked:bool, elo_before:int, elo_after:int,
elo_delta:int, points_delta:int, points_total:int, new_rank:int }`

`ladder_data`: `{ rows:[ { rank:int, display_name:String, elo:int, wins:int,
losses:int, is_you:bool } ], your_rank:int, your_row_included:bool }`

`profile_data`: `{ account:account_snapshot, recent_matches:[ { outcome, elo_delta,
opponent_name, is_bot_match, ts } ] }`

### 2.4 `Net` client-facing API (methods + signals — the contract)

Wrapper methods on `Net` (client calls these; they `rpc_id(1, ...)` or act
locally in solo):

```
Net.auth_register(username, password)
Net.auth_login(username, password)
Net.auth_resume(token)
Net.enqueue_match()
Net.cancel_queue()
Net.request_ladder(limit := 50, offset := 0)
Net.request_profile()
Net.start_singleplayer(reveal := false)   # local GameEngine, no server, no rating
Net.submit_category_and_card(category, card_id)   # existing, now match-routed
Net.submit_response_card(card_id)                 # existing, now match-routed
Net.replay_state()                                # re-emit cached assignment+state
```

New signals on `Net` (client side):

```
signal auth_completed(result: Dictionary)      # auth_result shape
signal queue_updated(state: String, elapsed_s: float)   # "searching"|"cancelled"
signal match_found(info: Dictionary)
signal match_ended(summary: Dictionary)
signal ladder_received(data: Dictionary)
signal profile_received(data: Dictionary)
# existing, unchanged: state_updated, error_received, player_assigned
```

### 2.5 `ServerStore` API (WS1)

```gdscript
class_name ServerStore
extends RefCounted

func open(dir := "user://flickbattle/") -> void            # loads/creates json files

# --- auth ---
func username_taken(username: String) -> bool
func create_account(username: String, password: String) -> Dictionary
        # -> { ok, error, account }   ; hashes password, assigns id, START_ELO
func verify_login(username: String, password: String) -> Dictionary
        # -> { ok, error, account }
func get_account(id: int) -> Dictionary                    # {} if missing
func account_snapshot(account: Dictionary) -> Dictionary   # safe subset (2.3)

# --- password hashing (pure, also unit-tested directly) ---
static func hash_password(password: String, salt_hex := "") -> Dictionary
        # salt = 16 random bytes if not supplied.
        # digest = SHA256( salt_bytes + utf8(password) ); then SHA256(digest) x (ITERATIONS-1); ITERATIONS = 200000
        # -> { salt: hex, hash: hex, iterations: int }
static func verify_password(password: String, salt_hex: String, hash_hex: String, iterations: int) -> bool

# --- elo / points ---
static func expected_score(my_elo: int, opp_elo: int) -> float   # 1/(1+10^((opp-my)/400))
static func k_factor(games_played: int) -> int                   # 40 / 20 / 10
static func apply_result(elo_a: int, games_a: int, elo_b: int, games_b: int, winner: int) -> Dictionary
        # winner in {0,1,2}. -> { elo_a_after, elo_b_after, delta_a, delta_b }
        # score_a = 1.0 win / 0.0 loss / 0.5 draw
static func points_delta(outcome: String) -> int                 # "win"->10 "loss"->3 "draw"->5

# --- match write ---
func record_match(a1_id: int, a2_id: int, winner: int, score1: int, score2: int, is_bot_match: bool) -> Dictionary
        # loads both accounts (a2_id==0 => bot, treat as fixed START_ELO opponent, don't write a bot account),
        # computes elo+points+W/L/D, increments games, persists accounts.json + appends matches.json,
        # -> the persisted match record (2.2)

# --- ladder / profile ---
func ladder(limit: int, offset: int, viewer_id: int) -> Dictionary   # ladder_data shape (2.3)
func rank_of(account_id: int) -> int                                 # 1-based, by elo desc, tie-break id asc
func recent_matches(account_id: int, limit := 10) -> Array
```

Constants in `ServerStore`: `START_ELO := 1000`, `PROVISIONAL_GAMES := 10`,
`HASH_ITERATIONS := 200000`.

### 2.6 Rewards catalog stub (`data/rewards.json` — WS1 creates the file)

```json
{ "rewards": [
  { "id": "sleeve_classic",  "type": "sleeve",    "name": "Classic Sleeve",   "cost": 0 },
  { "id": "sleeve_noir",     "type": "sleeve",    "name": "Noir Sleeve",      "cost": 150 },
  { "id": "back_reel",       "type": "card_back", "name": "Film Reel Back",   "cost": 200 },
  { "id": "avatar_director", "type": "avatar",    "name": "Director Avatar",  "cost": 300 }
] }
```

No shop UI this pass. `owned_rewards` defaults to `["sleeve_classic"]`.

---

## 3. Workstreams & ownership

### Sonnet (critical path / judgment)

- **WS0 — Server refactor.** `net/net_node.gd`: auth gate, `peer -> account`
  map, `Match` structure, `_matches`/`_peer_to_match`, per-match RPC routing,
  `MatchQueue` + `_tick_matchmaking`, bot-fill (shared bot driver with solo),
  match-end -> `ServerStore.record_match` -> `match_ended`, `replay_state()`.
  Update `_rpc_*` auth checks. Consumes `ServerStore` (WS1) — can stub it until
  WS1 lands.
- **WS8 — Glue.** Register `Session` autoload in `project.godot`; `main.gd`
  plain-client routing (token resume -> menu/login); `game_ui._ready()` calls
  `Net.replay_state()` and handles `match_ended` -> result screen; wire the
  server boot (`--server`) to `ServerStore.open()`. Update `tests/bot_client.gd`
  and `scripts/run_local.*` to authenticate (register a random user) then
  `enqueue_match()`; verify two bot clients pair, and one bot client + bot-fill
  works.
- **Testing.** Run the full headless suite myself after each Haiku piece lands
  (per `feedback-haiku-delegation` — never trust the agent's self-report).

### Haiku (mechanical, each a self-contained background agent)

- **WS1 — `server/server_store.gd` + `tests/server_store_test.gd` + `data/rewards.json`.**
  Implement exactly the API in 2.5. Tests must cover: create/duplicate
  username, login ok/wrong-password, `hash_password` determinism with fixed
  salt, `verify_password` true/false, `expected_score` symmetry (~0.5 equal),
  `apply_result` zero-sum-ish & K by games, `points_delta`, `record_match`
  updates both accounts + W/L/D + games + appends one match row, bot match
  (`a2_id=0`) writes no bot account, `rank_of` ordering, `ladder` shape +
  `is_you`. Headless runnable via the existing `tests/test_runner.gd` pattern.
- **WS2 — `client/login_screen.tscn/.gd`.** Two modes (Login / Register toggle),
  username + password fields, error label, submit calls `Net.auth_login` /
  `Net.auth_register`, on `auth_completed{ok}` -> `Session.set_account` +
  `Session.save_token` + `Session.goto(main_menu)`. Disable submit while
  in-flight.
- **WS3 — `client/main_menu.tscn/.gd`.** Title + account chip (display_name,
  Elo, "Rank #N" from a `Net.request_profile()` on load, points). Five buttons:
  Singleplayer (`Net.start_singleplayer(Session.settings.sp_reveal_mode)` then
  `Session.goto(game_ui)`), Multiplayer (`Session.goto(queue_screen)`), Ladder
  (`Session.goto(ladder_screen)`), Deckbuilder (`Session.goto(deckbuilder_screen)`),
  Options (`Session.open_options()`). Logout link -> `Session.clear()` ->
  login_screen.
- **WS4 — `client/options_modal.tscn/.gd`.** Overlay Panel (CanvasLayer, dim
  background, Close). Controls: Master Volume `HSlider` -> `Session.settings.master_volume`,
  Fullscreen `CheckButton`, "Reveal opponent card in Singleplayer" `CheckButton`
  -> `sp_reveal_mode`, read-only display-name label. On any change:
  `Session.save_settings()` + `Session.apply_settings()`. Empty-state note label
  "More options coming soon."
- **WS5 — `client/deckbuilder_screen.tscn/.gd`.** Loads `data/cards.json` via
  `CardLoader`, shows a scrollable `GridContainer` of `CardView` instances
  (reuse `client/card_view.tscn`, `disabled=true`, small scale). Header:
  "Full Collection — N cards". Left panel lists one deck: "Full Collection
  (auto)" selected, non-editable. Back button. Comment `# deck editing/saving:
  future milestone`.
- **WS6 — `client/ladder_screen.tscn/.gd`.** On `_ready` -> `Net.request_ladder(50)`.
  On `ladder_received` fill a table (`rank`, `display_name`, `elo`, `W-L`),
  highlight the row where `is_you`. Show "Your rank: #N" header. Back button.
  Loading + empty states.
- **WS7 — `client/queue_screen.tscn/.gd` + `client/match_result_screen.tscn/.gd`.**
  Queue: on `_ready` -> `Net.enqueue_match()`, animate "Searching…" + elapsed
  seconds from `queue_updated`, Cancel -> `Net.cancel_queue()` -> main_menu; on
  `match_found` -> `Session.goto(game_ui)`. Result: reads a
  `Session`-stashed `match_ended` summary, shows outcome banner, score,
  `Elo ±X (new N)`, `Points +X`, `Rank #N` (hide Elo/points lines when
  `ranked=false`), buttons "Find Another" (-> queue) and "Main Menu".

### Dependency order for spawning

1. Now, parallel: **WS1**, **WS4**, **WS5** (zero dependency on the netcode).
2. Sonnet starts **WS0** immediately (stubbing `ServerStore`).
3. After WS0 compiles + the contract in §2.4 is confirmed stable: spawn
   **WS2, WS3, WS6, WS7** (they only need the §2.4 signal/method names, which
   are frozen above).
4. Sonnet **WS8** glue + integrate WS1, then full headless test pass, then a
   manual 2-client run.

---

## 4. Out of scope for this step (explicit)

- Real OAuth (Steam/Discord/Google/Apple) — schema reserved only.
- Rewards shop UI / spending points.
- Deck building & saving (decks stay "whole `cards.json`").
- SQLite / real DB, password KDF hardening (Argon2/bcrypt), rate-limiting,
  email/recovery.
- Seasons / ladder resets, decay, leaderboards beyond top-N + self.
- Reconnect/resume; disconnect still just aborts the match (no forfeit rating).
- Mobile/responsive layout for the new screens (desktop-first per project note).

## 5b. Later additions (2026-09-02)

- **Give Up button** on the game canvas (`game_ui.tscn` `%ExitButton` + `%ForfeitDialog`).
  `Net.forfeit_match()` → server `_finish_match(m, forced_winner = other seat)` → the
  quitter is recorded as the loser (Elo/points adjust), normal `match_ended` summary
  flows to both → result screen. Solo forfeit is unranked. Verified headless.
- **30s per-turn clock.** `GameEngine.resolve_timeout(timed_out_player)`: the player on
  the clock forfeits the current category (opponent scores), loses one random card from
  hand, round then advances like a normal decisive round (active flips, round++, game-over
  check). Server enforces it via a 1s tick in `net_node.gd` (`_tick_turn_timers` →
  `_apply_timeout`); bots are never put on the clock. State carries `turn_seconds_left`
  + `on_clock_player`; `game_ui` shows a countdown and a "ran out of time" reveal.
  Dev override: `--turn-seconds=N` CLI user arg. 2 engine unit tests + headless
  idle-client integration test.
- Hand-fan reordering is allowed at all times except during the round-reveal animation…
  now also *during* it (per user request): reveal renders the hand draggable, and the
  drop handlers guard on `_revealing` so only a re-order (never a move) can happen.

## 5c. Avatars + client-relative table (2026-09-02)

- **Avatars.** Square images in `assets/avatars/` (`avatar_female_01..06.png`,
  `avatar_male_01..06.png`, `default.png`, `bot.png`) — auto-discovered by
  `client/avatars.gd` (`class_name Avatars`), the lookup/list helper. Accounts
  carry an `avatar` id (`ServerStore.create_account` 3rd arg + snapshot), which
  is now **empty until chosen**. Registration no longer picks an avatar; instead
  `main_menu.gd` raises `client/avatar_picker.tscn` in mandatory mode (no cancel,
  via `picker.configure(false)`) as a first-login onboarding step whenever
  `Avatars.needs_choice(account.avatar)` — i.e. at first login or for any account
  with no/stale avatar. The pick is saved with `Net.set_avatar()` →
  `_rpc_set_avatar` → `ServerStore.set_avatar()`, confirmed back on the
  `Net.avatar_updated` signal.
- **In-game player panels.** `game_ui.tscn` `TableRow` now has `LeftPlayerPanel` /
  `RightPlayerPanel` (avatar + name + "Elo N"). LEFT is always this client's
  player, RIGHT the opponent. `match_found` payload gained `your_name/your_avatar/
  your_elo` + `opponent_avatar`; the queue screen stashes it in
  `Session.last_match_info` for `game_ui` to read on load; solo emits a minimal
  `match_found` too.
- **Client-relative card sides.** The table layout is now per-viewer: your card is
  always the LEFT one (left of the category), the opponent's always RIGHT —
  regardless of who started the round. `game_ui.gd` `_play_resolution_sequence` /
  `_render_table` / `_on_response_card_dropped` key off `_my_player_id` instead of
  `result.active_player`.

## 5. Done vs. not-done-yet (post-implementation)

Done & verified: `Session` autoload; `server/server_store.gd` + tests + `data/rewards.json`;
`net/net_node.gd` full rewrite (auth gate, N concurrent matches, matchmaking queue,
bot-fill, match-end rating write, `replay_state`); `main.gd` routing; `game_ui.gd`
now navigates to the result screen on `match_ended`; `tests/bot_client.gd` is
auth-aware; 10 new client scenes (login, main_menu, options_modal, deckbuilder,
ladder, queue, match_result).

Not wired up / thin follow-ups:
- Singleplayer "reveal opponent card" setting is saved but `GameEngine`/`game_ui`
  don't actually render a revealed opponent card yet.
- Password hashing is dev-grade (200k SHA-256 rounds, pure GDScript). Replace with
  Argon2id/bcrypt addon before launch.
- `scripts/run_local.*` still just launches server + 2 raw clients; players now hit
  the login screen first (fine, just no auto-login for those).
- Disconnect mid-match: still a plain abort, no forfeit Elo. `TODO` marked in
  `net_node.gd`.
- Rewards: catalog + `owned_rewards`/`points` fields exist; no shop UI, no spending.
- Deckbuilder shows the full collection read-only; no deck create/save.
