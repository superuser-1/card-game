# Plan: In-Game Shop

Status: **SPEC — awaiting a few open-question confirmations (§7), otherwise ready.**
Owner split per `feedback-haiku-delegation`: Sonnet writes this spec + runs every
headless test pass; Haiku writes the files to spec. Sibling feature:
`PLAN_achievements.md` (shares the reward-granting plumbing in §3).

---

## 0. Decisions locked with the user (2026-09-05, do not re-ask)

| Topic | Decision |
|---|---|
| Currency | **Single pool.** Shop debits `account["points"]` — the same pool earned from matches + quests. No second currency. Spending points does **not** touch Elo/rank. |
| Legacy cosmetics | **Old art stays free.** Every avatar/frame/background currently auto-scanned from its asset folder remains freely equippable. The shop only ever sells **new** items added from now on. **No migration, no retroactive gating.** |

Sensible defaults chosen without asking (flag in §7 if you want them tuned):

- **No refunds, no re-buy.** A purchase is permanent; owning an item forever.
- **Prices are hand-set per item** in the catalog (no rarity-tier auto-pricing).
- **Static catalog.** No sales / rotating featured slots this pass.
- **Catalog is not secret.** Prices are shipped in a shared `class_name` module
  the client reads directly (same as `Avatars`/`Frames`). The server is the sole
  authority on the *debit* — it never trusts a client-sent price.

---

## 1. Ownership model

An id is **premium** *iff* it appears in `ShopCatalog.CATALOG`.

| id kind | equippable when |
|---|---|
| **legacy** (folder-scanned, not in catalog) | always — current behaviour, unchanged |
| **premium** (in catalog) | only if the id is in `account["owned_rewards"]` |

`owned_rewards` stays a **flat, type-prefixed id list** (already seeded
`["sleeve_classic"]`). Free/default ids for each slot are implicitly owned and
never appear in the catalog.

Premium art lives in the **same asset folders** as legacy art (the `list_ids()`
scanners already pick it up). The shop screen and the avatar picker annotate any
id that `ShopCatalog.is_premium(id)` with a lock badge until it is owned.

---

## 2. New file: `server/shop_catalog.gd`

Pure logic, `class_name ShopCatalog extends RefCounted`. No Node/scene/disk deps
(mirrors `server/quest_system.gd`). Used by **both** server and client.

```gdscript
class_name ShopCatalog
extends RefCounted

# type ∈ "avatar" | "frame" | "background" | "sleeve"
# source ∈ "shop" (buyable) | "achievement" (granted only, price ignored)
const CATALOG: Array = [
    {"id": "avatar_gold_reel", "type": "avatar",     "name": "Gold Reel",      "price": 500, "source": "shop"},
    {"id": "avatar_director",  "type": "avatar",     "name": "The Director",   "price": 750, "source": "shop"},
    {"id": "frame_neon",       "type": "frame",      "name": "Neon",          "price": 300, "source": "shop"},
    {"id": "frame_gilded",     "type": "frame",      "name": "Gilded",        "price": 600, "source": "shop"},
    {"id": "bg_starfield",     "type": "background", "name": "Starfield",     "price": 300, "source": "shop"},
    {"id": "bg_red_carpet",    "type": "background", "name": "Red Carpet",    "price": 450, "source": "shop"},
    {"id": "sleeve_noir",      "type": "sleeve",     "name": "Noir",          "price": 400, "source": "shop"},
    {"id": "sleeve_technicolor","type": "sleeve",    "name": "Technicolor",   "price": 400, "source": "shop"},
    # --- achievement-only (see PLAN_achievements.md §1); not buyable ---
    {"id": "frame_champion",   "type": "frame",      "name": "Champion",      "price": 0,   "source": "achievement"},
    {"id": "frame_veteran",    "type": "frame",      "name": "Veteran",       "price": 0,   "source": "achievement"},
    {"id": "avatar_champion",  "type": "avatar",     "name": "Grand Champion","price": 0,   "source": "achievement"},
    {"id": "sleeve_flame",     "type": "sleeve",     "name": "Flame",         "price": 0,   "source": "achievement"},
]

const TYPES: Array[String] = ["avatar", "frame", "background", "sleeve"]

static func def_for(id: String) -> Dictionary          # {} if unknown
static func is_premium(id: String) -> bool             # id in catalog
static func is_buyable(id: String) -> bool             # in catalog AND source == "shop"
static func ids_of_type(t: String) -> Array
```

`data/shop_catalog.json` — a reference mirror for humans, **not loaded by code**
(same convention as `data/quests.json`).

---

## 3. Shared reward plumbing — `server/server_store.gd`

One helper both features call. Idempotent on items (no double-append), credits
points once.

```gdscript
## Credit `points_award` into account["points"] and grant every id in
## `item_ids` the account does not already own. Persists. Returns
## {"points_total": int, "granted": Array of newly-owned ids}.
func grant_reward(account: Dictionary, points_award: int, item_ids: Array) -> Dictionary
```

Also new: **`account["sleeve"]`** field (equipped card back; `""` = the default
`card_back1`). Added to `create_account`, `account_snapshot`, and lazily
backfilled anywhere an older account is read (same treatment `frame`/`background`
got).

---

## 4. Purchase + equip: `server/server_store.gd` and RPC layer

### 4.1 `ServerStore.purchase(account_id, item_id) -> Dictionary`

```
def := ShopCatalog.def_for(item_id)
reject "no_such_item"      if def.is_empty()
reject "not_for_sale"      if def.source != "shop"
reject "already_owned"     if item_id in account.owned_rewards
reject "insufficient"      if account.points < def.price
account.points -= def.price
account.owned_rewards.append(item_id)
_save_accounts()
return {"ok": true, "error": "", "account": account}
```

### 4.2 Equip gating

`set_avatar` / `set_frame` / `set_background` and the **new `set_sleeve`** each
gain, before writing:

```
if ShopCatalog.is_premium(id) and id not in account.owned_rewards:
    return {"ok": false, "error": "not_owned", "account": {}}
```

Legacy (non-catalog) ids skip the check entirely — unchanged behaviour. `""`
(un-equip) stays valid for frame/background/sleeve.

### 4.3 RPCs — `net/net_node.gd`

| client call | server handler | reply signal |
|---|---|---|
| `Net.shop_purchase(id)` | `_rpc_shop_purchase` — auth-gated, calls `ServerStore.purchase`, replies with fresh `account_snapshot` on ok, `_rpc_receive_error` on failure | `shop_purchase_result(account)` |
| `Net.set_sleeve(id)` | `_rpc_set_sleeve` — mirror of `_rpc_set_frame`, runs `Sleeves.sanitize` + the §4.2 gate | `sleeve_updated(account)` |

No `shop_list` RPC — the client reads `ShopCatalog.CATALOG` directly and derives
owned/affordable from `Session.account`. Catalog reordering ships as a code
change, which is fine at this scale.

---

## 5. Client

### 5.1 New: `client/sleeves.gd`

`class_name Sleeves` — byte-for-byte the shape of `client/frames.gd`.
`DIR := "res://assets/cards/sleeves/"`, `NONE_ID := "classic"` resolving to the
existing `res://assets/cards/card_back1.png` (special-cased in `path_for`).

**Gameplay wiring (sub-task, flag to user):** `client/table_card_view.tscn`
hard-codes `card_back1.png`. To show each player's own equipped sleeve on their
faced-down cards, the sleeve id must ride in the `match_found` payload for both
seats (exactly how `your_avatar`/`opponent_avatar`/`frame` were added — see
`project_flick_battle` "avatars + client-relative table" update) and
`game_ui.gd` must pass it into `table_card_view`. Listed as **Milestone 2** below
so the shop can ship and be visible on the profile portrait first.

### 5.2 New: `client/shop_screen.gd` + `.tscn`

Full screen, same chrome as `ladder_screen` / `deckbuilder_screen`. Top bar shows
the live points balance. Tabs = `ShopCatalog.TYPES`. Each tab is a grid of tiles:

- preview art (`Avatars/Frames/Backgrounds/Sleeves.texture_for(id)`)
- name + price
- state button: **Buy** (affordable) / **Buy** greyed (can't afford) /
  **Owned** / **Equipped**
- Buy → `Net.shop_purchase(id)`; on `shop_purchase_result` refresh
  `Session.account`, repaint, flash the tile.
- Owned tile → tapping equips via the matching `Net.set_*` call.

Achievement-source items appear in their type tab with a **"Unlock via
[achievement]"** label instead of a price, no Buy button.

### 5.3 Menu entry

Add a **Shop** button to `%MenuGrid` in `client/main_menu.tscn`, wired like the
existing **Ladder** button (`change_scene_to_file("res://client/shop_screen.tscn")`).
Per `feedback_menu_navigation`, Shop is a leaf screen (like Ladder/Deckbuilder),
**not** a new in-place grid tier — confirm in §7 if you'd rather group
Shop + Achievements + Deckbuilder under one "Collection" sub-grid toggle.

---

## 6. Tests (Sonnet runs headless, all must stay green)

- **New `tests/shop_catalog_test.gd`**: unique ids; every `type` in `TYPES`;
  `price >= 0`; `source == "achievement"` ⇒ `price == 0`; `is_premium` /
  `is_buyable` truth table; `ids_of_type` partition covers the catalog.
- **Extend `tests/server_store_test.gd`**:
  - purchase happy path (points debited, id appended, snapshot correct)
  - `insufficient` when `points < price`, no mutation
  - `already_owned` rejected, no double-charge
  - `not_for_sale` on an `achievement`-source id
  - `grant_reward` — points credited once, items deduped
  - equip a premium id **not** owned → `not_owned`
  - equip a premium id **owned** → ok
  - equip a legacy (non-catalog) id → ok (regression guard for §4.2)
  - `set_sleeve` happy path + un-equip with `""`
- **Extend `tests/menu_shot.gd`** (optional) to include the shop screen in the
  screenshot sweep for a visual check.

---

## 7. Open questions for the user

1. **Menu placement** — Shop as its own button on the main grid (assumed), or
   fold Shop + Achievements + Deckbuilder into a single "Collection" sub-grid?
2. **Launch catalog** — the §2 list is a placeholder. Do you have specific
   premium avatars/frames/backgrounds/sleeves + prices in mind, or should I ship
   this set as a starting point for you to tune?
3. **Sleeve default id** — OK to call the free card back `classic` and map it to
   the existing `card_back1.png`? (Matches the `sleeve_classic` already seeded in
   `owned_rewards`.)
4. **Sleeve-in-gameplay** — ship as Milestone 2 (portrait/shop first, faced-down
   card art second), or does the sleeve need to render on the table from day one?
5. **Price ceiling sanity** — points earn rate is win +10 / loss +3 / draw +5
   plus up to ~390/day from quests. Are 300–750-point cosmetics the right
   magnitude, or do you want them pricier/cheaper?

---

## 8. Milestones

| # | Scope | Ships |
|---|---|---|
| **M1** | `ShopCatalog`, `grant_reward`, `sleeve` field, `purchase` + equip gating + `set_sleeve` RPCs, `Sleeves` class, `shop_screen`, Shop menu button, all §6 tests | Buyable cosmetics that show on the profile portrait |
| **M2** | Sleeve id in `match_found` payload + `table_card_view` wiring | Equipped card backs visible in-match |
