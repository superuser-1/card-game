class_name TitleSystem
extends RefCounted
## Player titles, shown under the display name. Two distinct sources:
## - Elo-tiered: automatic, tracks the account's current `elo` live, and can
##   only ever show/be worn at the elo it belongs to (see ELO_TIERS below).
## - Granted: ShopCatalog items with type "title", earned via achievements,
##   tournaments, or the shop (same grant_reward/purchase paths as any other
##   cosmetic) — once owned, always available regardless of elo.
##
## account["title"] stores the player's current pick: "" (or any elo-tier id
## that no longer matches their live elo) means "auto — show my current elo
## tier"; anything else is a granted title id they chose to wear instead.
## ServerStore reconciles the stored field back to "" whenever elo moves the
## account out of a previously-picked elo tier (see ServerStore._reconcile_title).

## PLACEHOLDER — thresholds/names are a first pass the user will replace.
## Ascending by min_elo; tier_for_elo() picks the highest one the rating clears.
const ELO_TIERS: Array = [
	{"min_elo": 0,    "id": "elo_newbie",              "name": "Newbie"},
	{"min_elo": 1100, "id": "elo_accomplished_critic", "name": "Accomplished Critic"},
	{"min_elo": 1200, "id": "elo_grandmaster",         "name": "Grandmaster"},
]


static func tier_for_elo(elo: int) -> Dictionary:
	var best: Dictionary = ELO_TIERS[0]
	for tier in ELO_TIERS:
		if elo >= int(tier.min_elo):
			best = tier
	return best


static func elo_tier_id_for(elo: int) -> String:
	return str(tier_for_elo(elo).id)


static func is_elo_tier_id(id: String) -> bool:
	for tier in ELO_TIERS:
		if str(tier.id) == id:
			return true
	return false


## Display text for whatever `title_id` (an account's "title" field) resolves
## to right now, given its live elo. "" or a stale elo-tier id both fall back
## to the current elo tier's name.
static func display_name(title_id: String, elo: int) -> String:
	if title_id == "" or is_elo_tier_id(title_id):
		return str(tier_for_elo(elo).name)
	var def := ShopCatalog.def_for(title_id)
	return str(def.get("name", title_id)) if not def.is_empty() else ""


## Every title id this account may currently pick: "" (its live elo tier,
## first/default entry) plus every title-type reward it owns.
static func available_titles(elo: int, owned_rewards: Array) -> Array:
	var out := [{"id": "", "name": str(tier_for_elo(elo).name)}]
	for id in owned_rewards:
		var id_str := str(id)
		var def := ShopCatalog.def_for(id_str)
		if not def.is_empty() and str(def.type) == "title":
			out.append({"id": id_str, "name": str(def.name)})
	return out


## "" (auto) and the account's own live elo-tier id are both always valid —
## the latter matters when something stores the literal tier id rather than
## "" (e.g. a future admin tool), since at the moment it's stored the two are
## equivalent; it only stops being valid once elo moves the account to a
## different tier, at which point ServerStore._reconcile_title resets it.
static func is_available(title_id: String, elo: int, owned_rewards: Array) -> bool:
	if title_id == "" or title_id == elo_tier_id_for(elo):
		return true
	for t in available_titles(elo, owned_rewards):
		if str(t.id) == title_id:
			return true
	return false
