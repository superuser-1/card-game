# Plan: Daily Quest System

Status: **SPEC — ready for implementation.** Owner split per
`feedback-haiku-delegation`: Sonnet wrote this spec + runs every headless test
pass; Haiku writes the files below to spec. No design decisions left open — the
three that mattered were answered by the user (see §0).

---

## 0. Decisions locked with the user (2026-09-04, do not re-ask)

| Topic | Decision |
|---|---|
| Category grouping | Categories carry a **group tag**: `money` = {box_office, highest_budget, lowest_budget}, `time` = {first_published, longest_runtime, shortest_runtime}, `awards` = {most_oscars}. |
| "Only Time / Money categories" quest | **Two separate quests** — one Money-game, one Time-game, 40 pts each. |
| "using only [group]" scope | **Only the categories the player themselves chose** (as the active player who picked the category that round). Opponent picks ignored. Requires **≥ 2** own picks, and *all* of them in the group. |
| Bot-fill matches | **Do NOT count.** Quest progress only in ranked, human-vs-human matches (`is_bot_match == false`). Solo never counts. |

Sensible defaults chosen without asking (flag later if you want them tuned):

- **Daily reset boundary:** server **UTC midnight**. Quest "day" = `YYYY-MM-DD` from
  UTC. Later we can offer a fixed reset hour / per-region reset.
- **Auto-award:** quest points are credited **immediately on completion** at match
  end (no manual "claim" button). The match-result screen shows what was earned.
- **Wins quests stack:** `win_1`, `win_3`, `win_10` are independent. Winning 3
  games completes `win_1` (+10) *and* `win_3` (+40) and leaves `win_10` at 3/10.
  Max daily pool = 10+40+150+50+60+40+40 = **390 pts**.
- **Perfect game = 7–0, hardened:** `perfect_win` needs `outcome==win AND
  opponent_score==0 AND your_score>=7`; `perfect_loss` needs `outcome==loss AND
  your_score==0 AND opponent_score>=7`. The `>=7` guard blocks a forfeit/early-quit
  from registering as a "perfect" result. (Ties redraw from reserve, so a clean
  game can finish slightly above 7 — hence `>=`, not `==`.)

Known accepted risk (tell the user, no mitigation this pass): `perfect_loss`
(0–7, 60 pts) is farmable in ranked with a cooperating partner who throws.
Mitigations (only counts vs higher Elo, cooldown, etc.) are a later tuning pass.

---

## 1. Quest catalog

| id | type | target | points | display name |
|---|---|---|---|---|
| `win_1` | `wins` | 1 | 10 | Win a Game |
| `win_3` | `wins` | 3 | 40 | Win 3 Games |
| `win_10` | `wins` | 10 | 150 | Win 10 Games |
| `perfect_win` | `perfect_win` | 1 | 50 | Win a Perfect Game (7–0) |
| `perfect_loss` | `perfect_loss` | 1 | 60 | Lose a Game 0–7 |
| `money_game` | `group_win` (group `money`, min_picks 2) | 1 | 40 | Win a Money Game |
| `time_game` | `group_win` (group `time`, min_picks 2) | 1 | 40 | Win a Time Game |

---

## 2. New file: `server/quest_system.gd`

Pure logic, `class_name QuestSystem extends RefCounted`. No Node/scene/disk deps
(mirrors `rules/*.gd` + the static helpers in `server/server_store.gd`). The
authoritative server is the only caller.

```gdscript
class_name QuestSystem
extends RefCounted

const CATALOG: Array = [
    {"id": "win_1",        "type": "wins",         "target": 1,  "points": 10,  "name": "Win a Game"},
    {"id": "win_3",        "type": "wins",         "target": 3,  "points": 40,  "name": "Win 3 Games"},
    {"id": "win_10",       "type": "wins",         "target": 10, "points": 150, "name": "Win 10 Games"},
    {"id": "perfect_win",  "type": "perfect_win",  "target": 1,  "points": 50,  "name": "Win a Perfect Game (7–0)"},
    {"id": "perfect_loss", "type": "perfect_loss", "target": 1,  "points": 60,  "name": "Lose a Game 0–7"},
    {"id": "money_game",   "type": "group_win", "group": "money", "min_picks": 2, "target": 1, "points": 40, "name": "Win a Money Game"},
    {"id": "time_game",    "type": "group_win", "group": "time",  "min_picks": 2, "target": 1, "points": 40, "name": "Win a Time Game"},
]

## UTC "YYYY-MM-DD". Pass a fixed unix time in tests; -1 = now.
static func today_key(unix_time: float = -1.0) -> String:
    var t := unix_time if unix_time >= 0.0 else Time.get_unix_time_from_system()
    var d := Time.get_datetime_dict_from_unix_time(int(t))
    return "%04d-%02d-%02d" % [d.year, d.month, d.day]

## { qid: {"progress": 0, "completed": false} } for every catalog entry.
static func fresh_state() -> Dictionary:
    var s := {}
    for q in CATALOG:
        s[q.id] = {"progress": 0, "completed": false}
    return s

## Normalise an account's stored quests dict for `day`. Shape:
##   {"day": String, "state": Dictionary}
## Resets state when the day rolled or the stored shape is missing/garbage;
## otherwise keeps it and backfills any newly-added catalog ids. Never saves.
static func ensure_day(quests, day: String) -> Dictionary:
    if typeof(quests) != TYPE_DICTIONARY \
            or str(quests.get("day", "")) != day \
            or typeof(quests.get("state")) != TYPE_DICTIONARY:
        return {"day": day, "state": fresh_state()}
    var state: Dictionary = quests["state"]
    for q in CATALOG:
        if not state.has(q.id):
            state[q.id] = {"progress": 0, "completed": false}
    return {"day": day, "state": state}

## match_ctx (all keys required):
##   "outcome": "win" | "loss" | "draw"
##   "your_score": int
##   "opp_score": int
##   "your_group_picks": {"money": int, "time": int, "awards": int}
##       -- categories THIS player chose (as active player), bucketed by group
##   "your_pick_count": int   -- total categories THIS player chose
##
## Returns:
##   {"state": Dictionary (deep copy, updated),
##    "completed": Array of {id, name, points}   -- flipped false->true this call,
##    "points_awarded": int}
static func evaluate(state: Dictionary, match_ctx: Dictionary) -> Dictionary:
    var out_state: Dictionary = state.duplicate(true)
    var completed := []
    var points := 0
    for q in CATALOG:
        var qs: Dictionary = out_state[q.id]
        if bool(qs.get("completed", false)):
            continue
        var inc := _progress_for(q, match_ctx)
        if inc > 0:
            qs["progress"] = min(int(qs.get("progress", 0)) + inc, int(q.target))
        if int(qs["progress"]) >= int(q.target):
            qs["completed"] = true
            completed.append({"id": q.id, "name": q.name, "points": int(q.points)})
            points += int(q.points)
    return {"state": out_state, "completed": completed, "points_awarded": points}

static func _progress_for(q: Dictionary, ctx: Dictionary) -> int:
    match str(q.type):
        "wins":
            return 1 if str(ctx.outcome) == "win" else 0
        "perfect_win":
            return 1 if (str(ctx.outcome) == "win" and int(ctx.opp_score) == 0 and int(ctx.your_score) >= 7) else 0
        "perfect_loss":
            return 1 if (str(ctx.outcome) == "loss" and int(ctx.your_score) == 0 and int(ctx.opp_score) >= 7) else 0
        "group_win":
            if str(ctx.outcome) != "win":
                return 0
            var picks: Dictionary = ctx.your_group_picks
            var in_group := int(picks.get(str(q.group), 0))
            if in_group >= int(q.min_picks) and in_group == int(ctx.your_pick_count):
                return 1
            return 0
    return 0
```

---

## 3. `rules/game_engine.gd` — round history + group tags

Add near the other consts:

```gdscript
const CATEGORY_GROUP := {
    "most_oscars": "awards",
    "first_published": "time",
    "longest_runtime": "time",
    "shortest_runtime": "time",
    "box_office": "money",
    "highest_budget": "money",
    "lowest_budget": "money",
}
```

Add a field alongside `last_round_result`:

```gdscript
var round_history: Array  # [{ "category": String, "chooser": int }] — one entry per DECISIVE round (winner or timeout with a category). Ties add nothing.
```

Initialise it to `[]` in **both** `_init()` and `deal_hands()` (same spots that
reset `last_round_result`).

In `resolve_round()` — after `category_used`, `active_player_this_round` etc. are
captured and the round is known non-... (append for every resolved round,
including ties? **No** — only decisive rounds. A tie re-plays the same category
choice; recording ties would double-count group picks). Append only when
`not is_tie`:

```gdscript
if not is_tie:
    round_history.append({"category": category_used, "chooser": active_player_this_round})
```

In `resolve_timeout()` — append only when a category was actually chosen (the
responder timed out; the active player had already picked). When the active
player times out in `awaiting_category`, `category_used == ""` → skip:

```gdscript
if category_used != "":
    round_history.append({"category": category_used, "chooser": active_player_this_round})
```

Add two helpers:

```gdscript
func group_pick_counts(player_id: int) -> Dictionary:
    var counts := {"money": 0, "time": 0, "awards": 0}
    for entry in round_history:
        if int(entry.chooser) == player_id:
            var g := str(CATEGORY_GROUP.get(entry.category, ""))
            if counts.has(g):
                counts[g] += 1
    return counts

func pick_count(player_id: int) -> int:
    var n := 0
    for entry in round_history:
        if int(entry.chooser) == player_id:
            n += 1
    return n
```

`get_state_for_player()` does **not** need to expose `round_history` (server-only
data). Leave the client state dict unchanged.

---

## 4. `server/server_store.gd` — persistence + award

### 4.1 `create_account()`

Add to the `account` dict literal:

```gdscript
"quests": {"day": "", "state": {}},
```

(Empty is fine — `QuestSystem.ensure_day` normalises on first read. Accounts
already on disk without the key are handled the same way; no migration script.)

### 4.2 New method

```gdscript
## Roll the daily reset if needed, then apply ONE finished match's result to this
## account's quests. Mutates + persists the account (adds any earned points to
## account["points"] — the same pool shop purchases spend). Caller MUST only
## invoke this for ranked, non-bot, human matches (see net_node._finish_match).
## Returns:
##   {"completed": Array of {id, name, points},
##    "points_awarded": int,
##    "points_total": int,          -- account points AFTER the award
##    "quests": Array}              -- display rows, same shape as _quest_rows
func apply_quest_progress(account_id: int, match_ctx: Dictionary) -> Dictionary:
    var account := get_account(account_id)
    if account.is_empty():
        push_error("ServerStore.apply_quest_progress: account not found: %d" % account_id)
        return {"completed": [], "points_awarded": 0, "points_total": 0, "quests": []}

    var day := QuestSystem.today_key()
    var normalised := QuestSystem.ensure_day(account.get("quests", {}), day)
    var res := QuestSystem.evaluate(normalised["state"], match_ctx)
    normalised["state"] = res["state"]
    account["quests"] = normalised
    if int(res["points_awarded"]) > 0:
        account["points"] = int(account.get("points", 0)) + int(res["points_awarded"])
    _save_accounts()

    return {
        "completed": res["completed"],
        "points_awarded": int(res["points_awarded"]),
        "points_total": int(account.get("points", 0)),
        "quests": _quest_rows(normalised),
    }
```

### 4.3 Display rows helper

```gdscript
## Flat rows for the client (menu quest panel + result screen). Reads a
## normalised {day, state} dict (from QuestSystem.ensure_day).
func _quest_rows(quests_norm: Dictionary) -> Array:
    var rows := []
    var state: Dictionary = quests_norm.get("state", {})
    for q in QuestSystem.CATALOG:
        var qs: Dictionary = state.get(q.id, {"progress": 0, "completed": false})
        rows.append({
            "id": q.id,
            "name": q.name,
            "progress": int(qs.get("progress", 0)),
            "target": int(q.target),
            "points": int(q.points),
            "completed": bool(qs.get("completed", false)),
        })
    return rows
```

### 4.4 `account_snapshot()`

Add one key (read-only — does not persist a reset; the persisted roll happens
lazily in `apply_quest_progress`):

```gdscript
"quests": _quest_rows(QuestSystem.ensure_day(account.get("quests", {}), QuestSystem.today_key())),
```

---

## 5. `net/net_node.gd` — hook at match end

Only change is inside `_finish_match()`, the **networked** branch
(`else` of `if is_solo or _store == null:`), within the existing
`for seat in [1, 2]:` loop that builds `summary`.

Right after `var after := int(rec.get("elo_%d_after" % seat, 0))` and BEFORE the
`var summary := {...}` literal, insert:

```gdscript
        var quest_completions := []
        var quest_points := 0
        if not bool(m.is_bot_match):
            var q_ctx := {
                "outcome": _outcome_str(winner, seat),
                "your_score": engine.scores[seat],
                "opp_score": engine.scores[3 - seat],
                "your_group_picks": engine.group_pick_counts(seat),
                "your_pick_count": engine.pick_count(seat),
            }
            var q_res := _store.apply_quest_progress(acc_id, q_ctx)
            quest_completions = q_res["completed"]
            quest_points = int(q_res["points_awarded"])
```

Then add three keys to the `summary` dict literal (the existing
`"points_total"` line already re-reads the account, so it now includes quest
points because `apply_quest_progress` ran first — keep that line as is):

```gdscript
        "quest_completions": quest_completions,
        "quest_points": quest_points,
```

In the **solo / no-store** branch's `summary` dict, add the same keys with empty
values so the client always sees a consistent shape:

```gdscript
        "quest_completions": [],
        "quest_points": 0,
```

Nothing else in `net_node.gd` changes. Bot-fill matches reach the networked
branch but `m.is_bot_match` is `true`, so `apply_quest_progress` is never called
for them.

---

## 6. Client display

### 6.1 `client/session.gd`

Doc-comment only: in the `account` shape comment block, add `quests:Array` (rows
of `{id, name, progress, target, points, completed}`) to the listed keys.

### 6.2 `client/match_result_screen.gd` + `.tscn`

**tscn:** add one `Label` node named `QuestLabel` with
`unique_name_in_owner = true`, `theme_override_font_sizes/font_size = 13`,
`horizontal_alignment = 1`, `autowrap_mode = 2`, `text = ""`, placed in
`Panel/ContentMargin/VBox` immediately **after** `PointsLabel`.

**gd:** in `_show_result()`, inside the `if is_ranked:` block:

```gdscript
        var qpts: int = int(s.get("quest_points", 0))
        if qpts > 0:
            %PointsLabel.text = "Points +%d  (+%d quests · total %d)" % [points_delta, qpts, points_total]
        else:
            %PointsLabel.text = "Points +%d  (total %d)" % [points_delta, points_total]

        var qc: Array = s.get("quest_completions", [])
        if qc.is_empty():
            %QuestLabel.visible = false
        else:
            var parts := []
            for q in qc:
                parts.append("%s  +%d" % [str(q.get("name", "Quest")), int(q.get("points", 0))])
            %QuestLabel.text = "Quests complete — " + "  ·  ".join(parts)
```

In the `else` (unranked) branch and `_show_empty_state()`, set
`%QuestLabel.visible = false`.

### 6.3 `client/main_menu.gd` + `client/main_menu.tscn`

**tscn:** in `QuestPanel/QuestVBox`:
- add `unique_name_in_owner = true` to the `QuestVBox` node,
- delete the three placeholder child nodes `Quest1`, `Quest2`, `Quest3` and their
  `Label` children, and delete `QuestNote`. Keep `QuestHeader`.

**gd:** add `_render_quests()` and call it at the end of `_ready()` (after
`_render_account()`) and at the end of `_on_profile()`:

```gdscript
func _render_quests() -> void:
    var vbox := %QuestVBox
    for child in vbox.get_children():
        if child.name != "QuestHeader":
            child.queue_free()
    var rows: Array = Session.account.get("quests", [])
    if rows.is_empty():
        var empty := Label.new()
        empty.text = "Log in to a match to load quests."
        empty.modulate = Color(1, 1, 1, 0.55)
        empty.add_theme_font_size_override("font_size", 12)
        empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        vbox.add_child(empty)
        return
    for r in rows:
        var done: bool = bool(r.get("completed", false))
        var line := Label.new()
        line.text = "%s%s   %d/%d   +%d pts" % [
            ("✓ " if done else "•  "),
            str(r.get("name", "Quest")),
            int(r.get("progress", 0)), int(r.get("target", 1)), int(r.get("points", 0)),
        ]
        line.add_theme_font_size_override("font_size", 13)
        line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        if done:
            line.add_theme_color_override("font_color", Color(0.5, 0.85, 0.5))
        vbox.add_child(line)
```

`Session.account` is populated from `match_found` / profile / auth snapshots,
all of which now carry `quests` via `account_snapshot()`, so the panel fills in
as soon as `Net.request_profile()` returns in `_ready()`.

---

## 7. Tests (Sonnet runs all of these headless after Haiku writes them)

Run pattern (confirmed working, Godot 4.7.2):
`<godot> --path <proj> --headless -s res://tests/<file>.gd`

### 7.1 New: `tests/quest_system_test.gd`

`extends SceneTree`, same `pass_test/fail_test/assert_equal/assert_true`
scaffold as `tests/test_runner.gd`. Cover:

1. `today_key(1_725_000_000.0)` returns a well-formed `YYYY-MM-DD` and is stable
   across two calls with the same arg; two different fixed times a day apart give
   different keys.
2. `fresh_state()` has an entry for every `CATALOG` id; each `{progress:0,
   completed:false}`.
3. `ensure_day`: identical day keeps the same `state` object (mutations visible);
   changed day returns `fresh_state`; `ensure_day({}, day)` and
   `ensure_day("garbage", day)` both return fresh; adding a fake id to CATALOG is
   not testable, but assert `ensure_day` backfills a missing id when handed a
   hand-built state dict missing one entry.
4. `evaluate` — single **win** ctx (`outcome:"win", your_score:7, opp_score:3`):
   `win_1` completed, `points_awarded == 10`, `win_3.progress == 1`,
   `win_10.progress == 1`, `perfect_win` NOT completed.
5. Feed state forward across **3 wins**: after the 3rd, `win_3.completed`,
   cumulative `points_awarded` over the 3 calls == 10 (call 1) + 40 (call 3).
6. **loss** ctx: no wins progress.
7. `perfect_win`: `win / your_score:7 / opp_score:0` → completes (+50);
   `win / 7 / 2` → not; `win / 5 / 0` (forfeit-shaped) → not.
8. `perfect_loss`: `loss / 0 / 7` → completes (+60); `loss / 1 / 7` → not;
   `loss / 0 / 4` → not.
9. `group_win` money: `win`, `your_group_picks {money:3,time:0,awards:0}`,
   `your_pick_count:3` → `money_game` completes (+40), `time_game` does not.
10. `group_win` negatives: `{money:2,time:1}` pick_count 3 → no (mixed);
    `{money:1}` pick_count 1 → no (below min_picks); money picks 3 but
    `outcome:"loss"` → no.
11. Idempotency: run case 4's ctx through `evaluate` twice (feeding state
    forward) — 2nd call `points_awarded == 0`, `completed == []`.

Give the file its own `_initialize()` that runs all tests and
`quit(0/1)` like the others.

### 7.2 New tests in `tests/test_runner.gd`

Add `test_round_history()` and register it in `_initialize()`:

- Fresh engine, `deal_hands()`, force `current_offered_categories =
  ["box_office", "most_oscars", "first_published"]`, force a `money`-group card
  each side via `_force_card_into_hand`, run a full decisive round with player 1
  choosing `box_office`. Assert `engine.round_history ==
  [{"category":"box_office","chooser":1}]`, `engine.group_pick_counts(1) ==
  {"money":1,"time":0,"awards":0}`, `pick_count(1) == 1`, `pick_count(2) == 0`.
- Tie round adds nothing: reuse the `test_tie_round` setup, assert
  `engine.round_history.is_empty()` after the tie.
- `resolve_timeout` in `awaiting_category` (active times out, no category) →
  `round_history` still empty. `resolve_timeout` in `awaiting_response`
  (category was chosen) → one entry with that category and `chooser == the
  active player of that round`.

### 7.3 New test in `tests/server_store_test.gd`

Add `test_quest_progress_and_daily_reset()` and register it:

- `s.create_account("Q","p")`; `apply_quest_progress(id, {outcome:"win",
  your_score:7, opp_score:2, your_group_picks:{money:0,time:0,awards:0},
  your_pick_count:0})` → `points_awarded == 10` (`win_1`), returned
  `completed` contains an entry with `id == "win_1"`, `points_total ==
  10`, and `s.get_account(id).points == 10`.
- Persisted shape: `s.get_account(id).quests.day == QuestSystem.today_key()`,
  `.quests.state.win_1.completed == true`.
- Second win same day → `win_1` NOT in `completed` again, `points_awarded`
  for this call `== 0` unless another quest tripped; `win_3.progress == 2`.
- Force a day roll: `s.get_account(id)["quests"]["day"] = "2000-01-01"`; call
  `apply_quest_progress` with a win again → state reset, `win_1` completes
  again (+10), `points_total == 20`.
- `apply_quest_progress(9999, ...)` (unknown account) → returns the empty
  shape, no crash.

### 7.4 Regression

Re-run `tests/test_runner.gd` and `tests/server_store_test.gd` in full — all
existing assertions must still pass (the engine changes are purely additive; the
`account_snapshot` change adds a key). Also run a solo smoke
(`--solo-test`) to confirm the solo match-end path still builds a valid summary
with the new empty quest keys.

---

## 8. File checklist for Haiku

| File | Action |
|---|---|
| `server/quest_system.gd` | **new** — §2 verbatim |
| `data/quests.json` | **new** — optional mirror of the catalog for reference/designers; not loaded by code this pass. Shape: `{"quests":[ {id,type,target,points,name,group?,min_picks?} ]}`. Keep it in sync with `QuestSystem.CATALOG`. |
| `rules/game_engine.gd` | edit — §3 (const, field, 2 append sites, 2 helpers) |
| `server/server_store.gd` | edit — §4 (`create_account` key, `apply_quest_progress`, `_quest_rows`, `account_snapshot` key) |
| `net/net_node.gd` | edit — §5 (one insert + keys in two `summary` literals) |
| `client/session.gd` | edit — §6.1 doc comment only |
| `client/match_result_screen.gd` | edit — §6.2 |
| `client/match_result_screen.tscn` | edit — §6.2 add `QuestLabel` |
| `client/main_menu.gd` | edit — §6.3 `_render_quests()` |
| `client/main_menu.tscn` | edit — §6.3 QuestVBox unique name + drop placeholders |
| `tests/quest_system_test.gd` | **new** — §7.1 |
| `tests/test_runner.gd` | edit — §7.2 |
| `tests/server_store_test.gd` | edit — §7.3 |

Do **not** touch: `rules/bot_player.gd`, `rules/card_loader.gd`, matchmaking,
Elo, the auth path, `data/cards.json`, `data/rewards.json`.

---

## 9. Follow-up (2026-09-04): daily rotation of 3 + tile art

Directives from the user, layered on §1–§8 (already implemented, test-green).
Same owner split: Sonnet specced + runs tests, Haiku writes.

### 9.1 Decisions

- **3 quests per day, not all 7.** The server picks `DAILY_COUNT = 3` quest ids
  per UTC day, the **same set for every player** that day, **deterministic** from
  the date string (seeded RNG) so it survives restarts and is testable.
  Per-player rotation is a later option, not now.
- **Quest art** lives in `res://assets/quests/` as `<quest_id>.png` — named by
  the quest **id** (`win_1.png`, `win_3.png`, `win_10.png`, `perfect_win.png`,
  `perfect_loss.png`, `money_game.png`, `time_game.png`). The id is the stable
  filename-safe machine name; display names have spaces/parens. `default.png` is
  the fallback (already added as a placeholder — user drops real art later).
- **Menu quest panel** = 3 square-ish tiles: full-bleed art, progress bar pinned
  to the tile bottom, and when complete the art/bar greyed with a green
  "FINISHED" label at the top of the tile.

### 9.2 `server/quest_system.gd`

Add:

```gdscript
const DAILY_COUNT := 3

## The quest definition for an id, or {} if unknown.
static func def_for(id: String) -> Dictionary:
    for q in CATALOG:
        if str(q.id) == id:
            return q
    return {}

## Deterministic per-UTC-day pick of DAILY_COUNT quest ids. Same for everyone on
## a given date; stable across restarts (seeded by the date string). Array order
## is the display order.
static func daily_quest_ids(day: String) -> Array:
    var ids := []
    for q in CATALOG:
        ids.append(str(q.id))
    var rng := RandomNumberGenerator.new()
    rng.seed = hash(day)
    for i in range(ids.size() - 1, 0, -1):
        var j := rng.randi_range(0, i)
        var tmp = ids[i]
        ids[i] = ids[j]
        ids[j] = tmp
    return ids.slice(0, min(DAILY_COUNT, ids.size()))
```

Change `fresh_state` to take the active set:

```gdscript
static func fresh_state(active_ids: Array) -> Dictionary:
    var s := {}
    for id in active_ids:
        s[id] = {"progress": 0, "completed": false}
    return s
```

Rewrite `ensure_day` — normalised shape is now
`{"day": String, "active_ids": Array, "state": Dictionary}`:

```gdscript
static func ensure_day(quests, day: String) -> Dictionary:
    var active_ids := daily_quest_ids(day)
    if typeof(quests) != TYPE_DICTIONARY \
            or str(quests.get("day", "")) != day \
            or typeof(quests.get("state")) != TYPE_DICTIONARY:
        return {"day": day, "active_ids": active_ids, "state": fresh_state(active_ids)}
    # Same day: keep earned progress, reconcile to the current active set.
    var old_state: Dictionary = quests["state"]
    var state := {}
    for id in active_ids:
        state[id] = old_state.get(id, {"progress": 0, "completed": false})
    return {"day": day, "active_ids": active_ids, "state": state}
```

Rewrite `evaluate` to iterate the state's own keys (the 3 active quests) instead
of the full CATALOG, resolving each def via `def_for`:

```gdscript
static func evaluate(state: Dictionary, match_ctx: Dictionary) -> Dictionary:
    var out_state: Dictionary = state.duplicate(true)
    var completed := []
    var points := 0
    for id in out_state.keys():
        var q := def_for(id)
        if q.is_empty():
            continue
        var qs: Dictionary = out_state[id]
        if bool(qs.get("completed", false)):
            continue
        var inc := _progress_for(q, match_ctx)
        if inc > 0:
            qs["progress"] = min(int(qs.get("progress", 0)) + inc, int(q.target))
        if int(qs["progress"]) >= int(q.target):
            qs["completed"] = true
            completed.append({"id": id, "name": q.name, "points": int(q.points)})
            points += int(q.points)
    return {"state": out_state, "completed": completed, "points_awarded": points}
```

`_progress_for` unchanged.

### 9.3 `server/server_store.gd`

- `apply_quest_progress` gains an optional day override for tests; the
  `net_node.gd` caller is unchanged (still `(acc_id, q_ctx)`):

  ```gdscript
  func apply_quest_progress(account_id: int, match_ctx: Dictionary, day_override := "") -> Dictionary:
      ...
      var day := day_override if day_override != "" else QuestSystem.today_key()
      ...
  ```

- `_quest_rows` iterates `active_ids` (ordered) instead of `QuestSystem.CATALOG`:

  ```gdscript
  func _quest_rows(quests_norm: Dictionary) -> Array:
      var rows := []
      var state: Dictionary = quests_norm.get("state", {})
      for id in quests_norm.get("active_ids", []):
          var q := QuestSystem.def_for(id)
          if q.is_empty():
              continue
          var qs: Dictionary = state.get(id, {"progress": 0, "completed": false})
          rows.append({
              "id": id,
              "name": q.name,
              "progress": int(qs.get("progress", 0)),
              "target": int(q.target),
              "points": int(q.points),
              "completed": bool(qs.get("completed", false)),
          })
      return rows
  ```

- `account_snapshot`'s `quests` key form is unchanged; it now yields 3 rows.
- `create_account`'s `"quests"` seed stays `{"day": "", "state": {}}` —
  `ensure_day` fills `active_ids`. No migration.

### 9.4 New: `client/quest_art.gd`

Mirror `client/avatars.gd`:

```gdscript
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
```

### 9.5 `client/main_menu.gd` — tile rendering

Replace `_render_quests()` (from §6.3) with a version that builds 3 tiles into
`%QuestVBox` (keep the `QuestHeader` child; clear the rest each call). Keep
calling it from `_ready()` and `_on_profile()`.

Per row in `Session.account.get("quests", [])` (already just the 3 active):

- **Tile**: `PanelContainer`, `custom_minimum_size = Vector2(0, 150)`,
  `size_flags_vertical = Control.SIZE_EXPAND_FILL`, `clip_contents = true`, a
  `StyleBoxFlat` panel override with `set_corner_radius_all(10)` (reuse the
  `sb_quest` dark-bg/subtle-border look).
- Inside the tile, children stacked on a full-rect area, `mouse_filter = IGNORE`
  on each:
  1. `TextureRect` `Art` — `texture = QuestArt.texture_for(r.id)`,
     `expand_mode = TextureRect.EXPAND_IGNORE_SIZE`,
     `stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED`, fills the tile
     (anchors full rect).
  2. Bottom strip: a `VBoxContainer` anchored bottom-wide (`anchor_top =
     anchor_bottom = 1.0`, `offset_top = -46`, left/right 0), containing:
     - `Label` `NameLabel` — `r.name`, font size 12,
       `autowrap_mode = TextServer.AUTOWRAP_WORD_SMART`, dark
       `theme_override_colors/font_shadow_color` (or a translucent panel behind)
       for legibility over art.
     - `ProgressBar` `Bar` — `min_value = 0`, `max_value = r.target`,
       `value = r.progress`, `show_percentage = false`,
       `custom_minimum_size = Vector2(0, 14)`.
  3. `Label` `FinishedLabel` anchored top-wide, text `"✓ FINISHED"`, font size
     14, `horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER`,
     `theme_override_colors/font_color = Color(0.40, 0.90, 0.45)` — **added only
     when `r.completed`**.
- **Completed styling** (`r.completed`): do NOT `modulate` the whole tile (it
  would dim the green label). Instead:
  - `Art.modulate = Color(1, 1, 1, 0.30)`
  - `NameLabel.modulate = Color(0.65, 0.65, 0.65)`
  - `Bar.modulate = Color(0.65, 0.65, 0.65)`, `Bar.value = r.target`
  - leave `FinishedLabel` green.

Empty `Session.account.quests` → one faint "Quests load after your first match."
label (as in §6.3).

### 9.6 Tests (Sonnet runs)

`tests/quest_system_test.gd` — add:
- `daily_quest_ids("2026-06-15")` → exactly 3 unique ids, all in `CATALOG`;
  identical on a second call; differs for at least one other sampled date.
- `ensure_day({}, day)` → `active_ids.size() == 3`, `state` keys == those 3; a
  stored same-day dict with progress on an active id keeps it through
  `ensure_day`.
- `evaluate` only scores active quests: seed `fresh_state(daily_quest_ids(day))`,
  run a broad win ctx, assert every `completed` id is in that day's active set.

`tests/server_store_test.gd` — rework `test_quest_progress_and_daily_reset`
rotation-safe:
- scan date strings (`"2026-01-%02d"` etc.) for `day_a` whose `daily_quest_ids`
  contains `"win_1"`, and a different `day_b` that also does.
- `apply_quest_progress(id, win_ctx, day_a)` → `win_1` completes,
  `points_awarded == 10`, `points_total == 10`,
  `get_account(id).quests.day == day_a`, `.quests.active_ids.size() == 3`,
  `.quests.state.win_1.completed == true`.
- second call same `day_a` → `win_1` not re-awarded.
- call with `day_b` → state reset to `day_b`'s set, `win_1` completes again
  (+10), `points_total == 20`.
- unknown account id → empty shape, no crash.

`tests/test_runner.gd` — no change.

### 9.7 File checklist (follow-up)

| File | Action |
|---|---|
| `assets/quests/default.png` | already added (placeholder) |
| `server/quest_system.gd` | edit — §9.2 |
| `server/server_store.gd` | edit — §9.3 |
| `client/quest_art.gd` | **new** — §9.4 |
| `client/main_menu.gd` | edit — §9.5 (rewrite `_render_quests`) |
| `tests/quest_system_test.gd` | edit — §9.6 |
| `tests/server_store_test.gd` | edit — §9.6 |

`net/net_node.gd`, `client/match_result_screen.*`, `client/session.gd`,
`rules/game_engine.gd` are unchanged by this follow-up.
