# Plan: Achievement System

Status: **SPEC — ready for implementation.** All open questions resolved with the
user 2026-09-05 (§7). Owner split per `feedback-haiku-delegation`: Sonnet writes
this spec + runs every headless test pass; Haiku writes the files to spec.
Sibling feature: `PLAN_shop.md` — this plan reuses its `ShopCatalog` (for reward
items) and the `ServerStore.grant_reward` helper (PLAN_shop §3).

---

## 0. Decisions locked with the user (2026-09-05, do not re-ask)

| Topic | Decision |
|---|---|
| Stat scope | **Ranked human-vs-human matches only** (`not m.is_bot_match`, real opponent). Bot-fill, solo, and friend/custom games never move a stat. Same anti-farm gate as quests. Tournament counters are the one exception (they come from the bracket flow, which is always human). |
| Structure | **Tiered.** One achievement has 3 thresholds (Bronze / Silver / Gold), each with its own points + optional cosmetic reward. |
| Rewards can grant items | Yes — a tier's `reward` is a `ShopCatalog` id with `source == "achievement"`, granted into `owned_rewards`. Not every tier needs an item; most give points only, the **Gold** tier usually also gives a cosmetic. |
| History seeding | **None.** Achievement progress starts at 0 for everyone at launch and only counts matches *going forward*. Do **not** seed `stats` from the historical `account["games"]/["wins"]/…` totals. |
| Catalog values | The §1 thresholds / points / tier rewards ship **as written** for now — a starting set the user tunes later (data edit to `CATALOG`, no code change). |
| Stat list | The §2 list is the full set for this pass. More stats get added "later down the line". |
| Menu placement | Standalone **Achievements** `TextureButton` next to `OptionsButton` (see PLAN_shop §5.3). |

Sensible defaults chosen without asking (flag in §7 if you want them tuned):

- **Auto-award on unlock**, no claim button — points + item land the instant the
  threshold is crossed, at match end (or tournament end). Surfaced on the
  match-result screen exactly like quest completions.
- **Server UTC** for any timestamps stored (`achievements.unlocked[id] = unix_ts`).
- **Points from achievement payouts do NOT feed `points_earned_total`** (avoids a
  self-referential loop with the "High Roller" achievement). Match + quest points
  do.
- **No loss-based achievements.** Group-win achievements carry the quest's
  `min_picks >= 2` guard; streak/perfect achievements carry the `your_score >= 7`
  guard. Co-op throw-farming stays an accepted, unmitigated risk (same note as
  quests).

---

## 1. Achievement catalog

`stat` = the `account["stats"]` key the achievement watches. Tiers are strictly
increasing thresholds; index 0/1/2 render as Bronze/Silver/Gold.

| id | name | stat | Bronze | Silver | Gold | Gold reward |
|---|---|---|---|---|---|---|
| `veteran` | Veteran | `games` | 10 (20p) | 100 (100p) | 1000 (500p) | `frame_veteran` |
| `winner` | Winner | `wins` | 10 (20p) | 100 (150p) | 1000 (750p) | `avatar_champion` |
| `on_fire` | On Fire | `win_streak_best` | 3 (20p) | 5 (60p) | 10 (200p) | `sleeve_flame` |
| `perfectionist` | Perfectionist | `perfect_wins` | 1 (30p) | 10 (120p) | 50 (400p) | — |
| `tycoon` | Tycoon | `money_games_won` | 5 (30p) | 25 (100p) | 100 (300p) | — |
| `historian` | Historian | `time_games_won` | 5 (30p) | 25 (100p) | 100 (300p) | — |
| `laureate` | Laureate | `awards_games_won` | 5 (30p) | 25 (100p) | 100 (300p) | — |
| `competitor` | Competitor | `tournaments_played` | 1 (20p) | 10 (100p) | 50 (400p) | — |
| `champion` | Champion | `tournaments_won` | 1 (100p) | 5 (300p) | 25 (1000p) | `frame_champion` |
| `high_roller` | High Roller | `points_earned_total` | 1000 (0p) | 10000 (100p) | 100000 (500p) | — |

"group games won" reuses `GameEngine.CATEGORY_GROUP` + `group_pick_counts(seat)` —
counts a win where **all** of this player's ≥2 own category picks were in that
group (identical rule to the `money_game` / `time_game` quests).

`data/achievements.json` — reference mirror, **not loaded by code**.

---

## 2. Stats — `account["stats"]`

New dict on the account, lazily backfilled (same pattern as `quests`). All keys
default `0`. Mutated **only** server-side.

| key | when it moves (ranked human match end, unless noted) |
|---|---|
| `games` | every match |
| `wins` / `losses` / `draws` | by outcome |
| `win_streak_current` | +1 on win, → 0 on loss/draw |
| `win_streak_best` | `max(best, current)` after each update |
| `perfect_wins` | win with `opp_score == 0 && your_score >= 7` |
| `money_games_won` / `time_games_won` / `awards_games_won` | group-win rule above |
| `tournaments_played` | +1 per player who **checked in**, when a tournament reaches `running` (tournament flow, not match end) |
| `tournaments_won` | +1 for the tournament `winner_account_id` on completion |
| `points_earned_total` | += every **match** and **quest** points delta (not achievement payouts) |

> **`stats.games/wins/...` are separate counters from the existing top-level
> `account["games"]/["wins"]/...`** — those already count bot-fill matches
> (`record_match` runs for bot matches), which the locked scope excludes. Per §0,
> `stats` is **not** seeded from those totals — every account starts at 0.

---

## 3. New file: `server/achievement_system.gd`

Pure logic, `class_name AchievementSystem extends RefCounted`. No Node/scene/disk
deps (mirrors `server/quest_system.gd`).

```gdscript
class_name AchievementSystem
extends RefCounted

const CATALOG: Array = [ ... §1 ... ]   # each: {id, name, stat, tiers:[{threshold, points, reward}]}
const TIER_NAMES := ["Bronze", "Silver", "Gold"]

static func def_for(id: String) -> Dictionary

## unlocked: { achid: highest_tier_index_reached }  (missing key => -1)
## Returns:
##   {"unlocked": Dictionary,              -- updated
##    "newly":   Array of {id, name, tier_index, tier_name, points, reward},
##    "points_awarded": int,
##    "reward_ids": Array of String}       -- non-empty tier rewards, for grant_reward
static func evaluate(stats: Dictionary, unlocked: Dictionary) -> Dictionary

## Display rows for the client screen — current stat value, tiers done,
## next threshold, whether maxed.
static func rows(stats: Dictionary, unlocked: Dictionary) -> Array
```

`evaluate` walks every catalog entry, compares `stats[stat]` against each tier
above the currently-recorded index, and can cross **multiple tiers in one call**
(e.g. a batch stat jump) — each crossed tier contributes its own points + reward
and its own `newly` row.

---

## 4. Integration — `server/server_store.gd` + `net/net_node.gd`

### 4.1 `ServerStore.apply_match_stats(account_id, ctx) -> Dictionary`

`ctx` is the **same dict** `net_node` already builds for quests
(`outcome`, `your_score`, `opp_score`, `your_group_picks`, `your_pick_count`).

```
account := get_account(account_id)
stats := _ensure_stats(account)          # lazy backfill
_bump_match_counters(stats, ctx)         # games, w/l/d, streak, perfect, group wins
_bump(stats, "points_earned_total", <match points delta for this seat>)
var res := AchievementSystem.evaluate(stats, account["achievements"]["unlocked"])
account["achievements"]["unlocked"] = res["unlocked"]
grant_reward(account, res["points_awarded"], res["reward_ids"])   # PLAN_shop §3
_save_accounts()
return {"achievement_unlocks": res["newly"], "achievement_points": res["points_awarded"]}
```

Called from `net_node._finish_match`, in the existing non-solo `else` branch,
**inside the `if not bool(m.is_bot_match)` block**, right after
`apply_quest_progress`. The two unlock lists are merged into the per-seat
`summary`:

```gdscript
summary["achievement_unlocks"] = q_stat_res["achievement_unlocks"]
summary["achievement_points"]  = int(q_stat_res["achievement_points"])
```

`match_result_screen.gd` renders an "Achievements" block under the existing quest
block (name + tier badge + "+N pts" + reward chip).

### 4.2 Tournament counters

New `ServerStore.apply_tournament_stat(account_id, key)` (`key` ∈
`"tournaments_played" | "tournaments_won"`): bump, `AchievementSystem.evaluate`,
`grant_reward`, persist, return `res["newly"]`.

Call sites in `net/net_node.gd`:
- when a tournament transitions to `running` → for each checked-in participant,
  `apply_tournament_stat(id, "tournaments_played")`
- in the tournament-completion path where `winner_account_id` is set →
  `apply_tournament_stat(winner_id, "tournaments_won")`

Unlocks here are **out of band** (no match summary). If the player's peer is
connected, push `_rpc_achievements_unlocked.rpc_id(peer, newly)` →
`signal achievements_unlocked(list)` → a small toast in `main_menu.gd`.
Otherwise it is already persisted and simply shows as unlocked next time they
open the Achievements screen.

### 4.3 Snapshot

`account_snapshot` gains `"stats"` and `"achievements"` (it already carries
`quests` rows). The client computes display rows itself via
`AchievementSystem.rows(snapshot.stats, snapshot.achievements.unlocked)` — no
dedicated fetch RPC, same approach as the shop catalog.

### 4.4 Account shape additions (`create_account` + lazy backfill)

```gdscript
"stats": {},                       # _ensure_stats fills defaults on first touch
"achievements": {"unlocked": {}},  # { achid: highest_tier_index }
```

---

## 5. Client

### 5.1 New: `client/achievements_screen.gd` + `.tscn`

Full screen, same chrome as `ladder_screen`. Scrollable grid, one card per
catalog entry:

- art via new `client/achievement_art.gd` (mirror of `client/quest_art.gd`) →
  `res://assets/achievements/<id>.png`, `default.png` fallback
- name + current tier badge (Bronze/Silver/Gold or "—")
- progress bar: `stat_value / next_threshold` with `value / threshold` label
- on the final tier: reward preview chip (uses `Sleeves/Frames/...texture_for`)
- fully maxed → greyed card + "COMPLETE"

Rows come straight from `AchievementSystem.rows(...)` off `Session.account`.

### 5.2 Menu entry

**Achievements** `TextureButton` in `client/main_menu.tscn`, anchored bottom-left
next to the **Shop** button (which sits next to `OptionsButton`) — see
PLAN_shop §5.3 for the exact offsets and the art-fallback pattern.
`pressed` → `change_scene_to_file("res://client/achievements_screen.tscn")`.

### 5.3 Toast

`main_menu.gd` grows a lightweight `_show_achievement_toast(list)` bound to
`Net.achievements_unlocked` for the out-of-band tournament case.

---

## 6. Tests (Sonnet runs headless, all must stay green)

- **New `tests/achievement_system_test.gd`**:
  - catalog integrity — unique ids, strictly-increasing thresholds, 3 tiers each,
    every non-empty `reward` resolves in `ShopCatalog` with `source == "achievement"`
  - `evaluate` crosses one tier → correct `newly` row + points + no reward when
    tier reward is `""`
  - `evaluate` crosses **two tiers in one call** → both rows, summed points, both
    reward ids
  - re-`evaluate` with unchanged stats → empty `newly`, 0 points (idempotent)
  - `rows` shape — value, tiers_done, next_threshold, maxed flag
- **Extend `tests/server_store_test.gd`**:
  - `apply_match_stats` — win bumps `games`+`wins`+`win_streak_current`;
    loss resets streak; `win_streak_best` monotonic
  - perfect-win guard (`opp==0 && your>=7`); forfeit (your==3) does **not** count
  - group-win counter uses the ≥2-own-picks rule
  - an unlock actually credits `points` and appends the reward id to
    `owned_rewards` (via `grant_reward`)
  - `points_earned_total` moves on match/quest points but **not** on the
    achievement payout itself
  - `apply_tournament_stat` bumps + unlocks `competitor` / `champion`
  - lazy backfill: an account with no `stats` / `achievements` key survives
    `account_snapshot` and `apply_match_stats`
- **`tests/bot_client.gd`** already supports `--idle` / `--forfeit`; no new flags
  needed — the ranked-human two-process PvP path in the existing suite exercises
  `apply_match_stats` end to end.

---

## 7. Open questions — resolved 2026-09-05

1. Menu placement → standalone button next to `OptionsButton` (§0, §5.2).
2. Seed stats from history → **no**, start from 0 going forward (§0).
3. Catalog values → ship §1 as written, tune later (§0).
4. Tier count → 3 tiers everywhere (Bronze/Silver/Gold).
5. Stat list → §2 as written, more later (§0).

One default chosen without a specific answer, easy to change: `tournaments_played`
increments when a tournament enters `running` for each **checked-in** participant
(a no-show who checked in but never played still gets the credit). Switch to
"≥1 bracket match actually played" if you'd rather.

---

## 8. Milestones

| # | Scope | Ships |
|---|---|---|
| **M1** | `AchievementSystem`, `stats` + `achievements` account fields, `apply_match_stats` wired into `_finish_match`, snapshot changes, `achievements_screen` + menu button, result-screen block, all match-driven achievements, §6 tests | Every non-tournament achievement live |
| **M2** | `apply_tournament_stat` + tournament-flow call sites + `achievements_unlocked` push + menu toast | `competitor` / `champion` live |
