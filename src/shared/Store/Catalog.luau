--!strict
-- What the shops sell (docs/design/rofront-ui-pass.md; prices and products in
-- docs/design/store-items.md). Pure data; Economy and Profile use it.
--   - cosmetics: skins (Store/Skins) and flags (Store/FlagList: OpenFront's
--     country flags and our own art), each with a rarity
--   - the Arsenal: weapons beyond OpenFront, each behind a match config flag
--     (Shared/OpenFront Config: `extraWeapons`), unlocked for good with stars
--     or Robux; plus 2x Stars (a game pass: progression only, no power)
--   - Robux products and passes: `key` names them; their Roblox ids are in
--     Store/Products (written when they are created)

local FlagList = require(script.Parent.FlagList) :: { { id: string, name: string, rarity: string, set: string } }
local Skins = require(script.Parent.Skins)

local Catalog = {}

export type Rarity = "common" | "rare" | "epic" | "legendary"
export type Cosmetic = { id: string, kind: "skin" | "flag", name: string, rarity: Rarity, set: string? }

Catalog.RARITIES = { "common", "rare", "epic", "legendary" }
Catalog.RARITY_NAME = { common = "Common", rare = "Rare", epic = "Epic", legendary = "Legendary" }

local cosmetics: { Cosmetic } = {}
local byId: { [string]: Cosmetic } = {}
for _, s in Skins.LIST do
	local c: Cosmetic = { id = s.id, kind = "skin", name = s.name, rarity = s.rarity }
	table.insert(cosmetics, c)
	byId[c.id] = c
end
for _, s in Skins.GENERAL do
	local c: Cosmetic = { id = s.id, kind = "skin", name = s.name, rarity = s.rarity, set = "general" }
	table.insert(cosmetics, c)
	byId[c.id] = c
end
for _, f in FlagList do
	local c: Cosmetic = { id = f.id, kind = "flag", name = f.name, rarity = f.rarity :: Rarity, set = f.set }
	table.insert(cosmetics, c)
	byId[c.id] = c
end

function Catalog.cosmetics(): { Cosmetic }
	return cosmetics
end

function Catalog.get(id: string): Cosmetic?
	return byId[id]
end

-- What crates can give: every skin and every country flag. Event and daily
-- flags are sold in the Flag Shop only.
function Catalog.crateable(c: Cosmetic): boolean
	local set: string? = c.set
	if c.kind == "skin" then
		return set ~= "general" -- Conquest General's skins: subscribers only
	end
	return set == "country"
end

export type Weapon = {
	id: string,
	name: string,
	desc: string,
	bullets: { string },
	stars: number?, -- star price; nil for Robux-only boosts
	product: string?, -- developer product key (a permanent unlock)
	pass: string?, -- game pass key
	weapon: string?, -- the engine's extra-weapon key (Config.extraWeapons)
	subscription: boolean?, -- Conquest General (Catalog.SUBSCRIPTION), monthly
	icon: string,
}

-- The Arsenal. Each weapon has a counter (docs/design/ARSENAL-2.md):
--   Reinforcements  costs gold, 30 s cooldown, never above your troop limit
--   Mega Nuke       SAMs intercept it; it flies slower than an Atom Bomb, so
--                   the target sees it longer; 2.5M gold
Catalog.ARSENAL = {
	{
		id = "w_reinforce",
		name = "Reinforcements",
		desc = "Troops for gold, on call",
		bullets = { "+20% of your troop limit at once", "Every 30 seconds" },
		stars = 15000,
		product = "unlockReinforce",
		weapon = "reinforcements",
		icon = "troops",
	},
	{
		id = "w_mega",
		name = "Mega Nuke",
		desc = "Twice the blast radius of an Atom Bomb",
		bullets = { "4x the blast area", "2.5M gold a launch" },
		stars = 30000,
		product = "unlockMega",
		weapon = "megaNuke",
		icon = "atom",
	},
	{
		-- RoWorld's Scattershot at RoWorld's price (ARSENAL_V2).
		id = "w_scatter",
		name = "Scattershot",
		desc = "An Atom Bomb with warheads that land around it",
		bullets = { "4 to 6 extra warheads", "3.75M gold a launch" },
		stars = 40000,
		product = "unlockScatter",
		weapon = "scattershot",
		icon = "atom",
	},
	{
		-- The Arsenal's second round (docs/design/ARSENAL_V2.md): RoWorld's
		-- Artillery at RoWorld's price.
		id = "w_artillery",
		name = "Artillery",
		desc = "Shells every enemy in range",
		bullets = { "Fires on its own", "45-tile range" },
		stars = 50000,
		product = "unlockArtillery",
		weapon = "artillery",
		icon = "explosion",
	},
	{
		-- RoWorld's Air Strike at RoWorld's price (ARSENAL_V2).
		id = "w_airstrike",
		name = "Air Strike",
		desc = "Airfields that bomb anything in reach",
		bullets = { "15-tile bombing run", "156-tile reach, rearms in 30 s" },
		stars = 200000,
		product = "unlockAirStrike",
		weapon = "airStrike",
		icon = "explosion",
	},
	{
		-- RoWorld's Railgun at RoWorld's price (ARSENAL_V2).
		id = "w_railgun",
		name = "Railgun",
		desc = "Hits anywhere on the map",
		bullets = { "Knocks a building down a level", "Reloads in 25 s" },
		stars = 500000,
		product = "unlockRailgun",
		weapon = "railgun",
		icon = "explosion",
	},
	{
		-- Our own (ARSENAL_V2, Field Works; Codex's idea, Bruno's price 2026-11-09).
		id = "w_fieldworks",
		name = "Field Works",
		desc = "Dig in where the front is",
		bullets = { "A defence post's effect for 60 s", "Built in 1 s, two at a time" },
		stars = 35000,
		product = "unlockFieldWorks",
		weapon = "fieldWorks",
		icon = "defense",
	},
	{
		-- Our own (ARSENAL_V2, Coastal Battery; Bruno's price 2026-11-09).
		id = "w_coastal",
		name = "Coastal Battery",
		desc = "Shore guns that sink enemy boats",
		bullets = { "One shell sinks a transport", "40-tile range" },
		stars = 75000,
		product = "unlockCoastal",
		weapon = "coastalBattery",
		icon = "port",
	},
	{
		-- Our own (ARSENAL_V2, Sabotage; Bruno's price 2026-11-09).
		id = "w_sabotage",
		name = "Sabotage",
		desc = "Switch off an enemy building",
		bullets = { "Dark for 30 s after a 5 s fuse", "SAMs, silos, guns, ports" },
		stars = 100000,
		product = "unlockSabotage",
		weapon = "sabotage",
		icon = "explosion",
	},
	{
		-- Our own (ARSENAL_V2, Paratroopers; Bruno's price 2026-11-09).
		id = "w_paratroopers",
		name = "Paratroopers",
		desc = "Fly troops behind the front",
		bullets = { "Lands up to 120 tiles away", "SAMs can shoot it down" },
		stars = 150000,
		product = "unlockParatroopers",
		weapon = "paratroopers",
		icon = "troops",
	},
	{
		-- RoWorld's monthly subscription (ARSENAL_V2, 2026-11-08).
		id = "w_general",
		name = "Conquest General",
		desc = "A monthly subscription",
		bullets = { "A crate every day you play", "+50% stars every match", "The month's General skin" },
		subscription = true,
		icon = "star",
	},
	{
		-- RoWorld's Rapid Reload, Robux only (ARSENAL_V2).
		id = "w_rapidreload",
		name = "Rapid Reload",
		desc = "Every reload of yours takes half as long",
		bullets = { "Silos, SAMs, Artillery", "Airfields and Railguns" },
		product = "unlockRapidReload",
		weapon = "rapidReload",
		icon = "explosion",
	},
	{
		id = "b_double",
		name = "2x Stars",
		desc = "Every match pays double stars, forever",
		bullets = { "Double stars", "Every match" },
		pass = "doubleStars",
		icon = "star",
	},
} :: { Weapon }

function Catalog.weapon(id: string): Weapon?
	for _, w in Catalog.ARSENAL do
		if w.id == id then
			return w
		end
	end
	return nil
end

export type Product = { key: string, kind: "product" | "pass", name: string, price: number, desc: string }

-- Every Robux item (created by scripts/create_store.py).
Catalog.PRODUCTS = {
	{ key = "crate1", kind = "product", name = "Cosmetic Crate", price = 49, desc = "A territory skin or a country flag you don't own yet. Odds are shown in game." },
	{ key = "crate3", kind = "product", name = "3 Cosmetic Crates", price = 119, desc = "Three crates: skins or country flags you don't own yet. Odds are shown in game." },
	{ key = "crateFirst", kind = "product", name = "First Crate", price = 15, desc = "Your first cosmetic crate at a discount. Once per player." },
	{ key = "flagRare", kind = "product", name = "Rare Flag", price = 49, desc = "The rare flag you picked in the Flag Shop, yours to keep." },
	{ key = "flagEpic", kind = "product", name = "Epic Flag", price = 99, desc = "The epic flag you picked in the Flag Shop, yours to keep." },
	{ key = "flagLegendary", kind = "product", name = "Legendary Flag", price = 149, desc = "The legendary flag you picked in the Flag Shop, yours to keep." },
	{ key = "unlockReinforce", kind = "product", name = "Arsenal: Reinforcements", price = 79, desc = "Unlock Reinforcements for good: troops for gold, every 30 seconds." },
	{ key = "unlockMega", kind = "product", name = "Arsenal: Mega Nuke", price = 129, desc = "Unlock the Mega Nuke for good: twice an Atom Bomb's blast radius." },
	{ key = "unlockScatter", kind = "product", name = "Arsenal: Scattershot", price = 67, desc = "Unlock the Scattershot for good: an Atom Bomb with 4 to 6 warheads around it." },
	{ key = "starterPack", kind = "product", name = "Starter Pack", price = 39, desc = "Mega Nuke, Scattershot and 2x Stars for good. Once per player, for a limited time." },
	{ key = "takeover", kind = "product", name = "Takeover", price = 25, desc = "Take command of the AI nation that eliminated you: its land, army, gold and buildings." },
	{ key = "unlockAirStrike", kind = "product", name = "Arsenal: Air Strike", price = 349, desc = "Unlock Air Strikes for good: airfields that bomb a 15-tile circle up to 156 tiles away." },
	{ key = "unlockRailgun", kind = "product", name = "Arsenal: Railgun", price = 999, desc = "Unlock the Railgun for good: hits anywhere on the map and knocks buildings down a level." },
	{ key = "unlockRapidReload", kind = "product", name = "Arsenal: Rapid Reload", price = 129, desc = "Every reload of yours takes half as long: silos, SAMs, Artillery, Airfields and Railguns." },
	{ key = "unlockCoastal", kind = "product", name = "Arsenal: Coastal Battery", price = 149, desc = "Unlock the Coastal Battery for good: shore guns that sink enemy boats within 40 tiles." },
	{ key = "unlockSabotage", kind = "product", name = "Arsenal: Sabotage", price = 199, desc = "Unlock Sabotage for good: switch off an enemy building (a SAM, silo, gun or port) for 30 seconds." },
	{ key = "unlockFieldWorks", kind = "product", name = "Arsenal: Field Works", price = 79, desc = "Unlock Field Works for good: earthworks near a front that defend like a defense post for 60 seconds." },
	{ key = "unlockParatroopers", kind = "product", name = "Arsenal: Paratroopers", price = 249, desc = "Unlock Paratroopers for good: fly troops from a city up to 120 tiles away to attack behind the front." },
	{ key = "unlockArtillery", kind = "product", name = "Arsenal: Artillery", price = 99, desc = "Unlock Artillery for good: batteries that shell every enemy within 45 tiles." },
	{ key = "doubleStars", kind = "pass", name = "2x Stars", price = 199, desc = "Every match pays double stars, forever." },
} :: { Product }

-- The starter pack (RoWorld's, docs/design/ARSENAL_V2.md; 2026-11-08): its
-- product, what it unlocks (Arsenal ids), how long the offer runs once first
-- shown, the grace for a prompt opened in time and paid late, and the
-- regular price of its items together (Robux, for the struck-through price).
Catalog.STARTER = table.freeze({
	product = "starterPack",
	items = table.freeze({ "w_mega", "w_scatter", "b_double" }),
	durationS = 48 * 3600,
	graceS = 15 * 60,
	regular = 129 + 67 + 199,
})

-- The launch event (Bruno, 2026-11-13): for 7 days everyone who plays may
-- claim the starter pack's items free, once ("[🎁 LAUNCH GIFT]" in the
-- title). `startsAt` is the UTC os.time() it opens; 0 = off. Runs 2026-11-14
-- 00:00 UTC to 2026-11-21 00:00 UTC (7 PM EST Nov 13 to 7 PM EST Nov 20).
Catalog.LAUNCH_GIFT = table.freeze({
	startsAt = 1794614400,
	durationS = 7 * 24 * 3600,
})

-- RoWorld's monthly subscription, here "Conquest General" (2026-11-08): its
-- Roblox id ("EXP-..."; "" = not created yet, so nothing offers it), the
-- price set on the dashboard, and the perks: a crate every UTC day played,
-- +50 % stars on every match (before 2x Stars).
Catalog.SUBSCRIPTION = table.freeze({
	id = "EXP-6948514243224404559",
	name = "Conquest General",
	robux = 399,
	starsBonus = 0.5,
	-- The General skin of each month ("YYYY-MM", UTC, oldest first); a month
	-- without its own gives the latest before it.
	-- A year ahead (2026-11-11, Bruno: "12 months, my picks").
	skins = table.freeze({
		table.freeze({ month = "2026-11", skin = "g_rank" }),
		table.freeze({ month = "2026-12", skin = "g_eagle" }),
		table.freeze({ month = "2027-01", skin = "g_chevrons" }),
		table.freeze({ month = "2027-02", skin = "g_medal" }),
		table.freeze({ month = "2027-03", skin = "g_shield" }),
		table.freeze({ month = "2027-04", skin = "g_wings" }),
		table.freeze({ month = "2027-05", skin = "g_laurel" }),
		table.freeze({ month = "2027-06", skin = "g_tank" }),
		table.freeze({ month = "2027-07", skin = "g_crown" }),
		table.freeze({ month = "2027-08", skin = "g_blades" }),
		table.freeze({ month = "2027-09", skin = "g_chute" }),
		table.freeze({ month = "2027-10", skin = "g_sight" }),
	}),
})

-- The General skin of the month of unix time `t`.
function Catalog.generalSkin(t: number): string?
	local month = os.date("!%Y-%m", math.floor(t)) :: string
	local skin = nil
	for _, s in Catalog.SUBSCRIPTION.skins do
		if s.month <= month then
			skin = s.skin
		end
	end
	return skin or (if #Catalog.SUBSCRIPTION.skins > 0 then Catalog.SUBSCRIPTION.skins[1].skin else nil)
end

-- Whether General skin `id`'s month has come by unix time `t` (later
-- months stay out of the Locker until then).
function Catalog.generalReleased(id: string, t: number): boolean
	local month = os.date("!%Y-%m", math.floor(t)) :: string
	for _, s in Catalog.SUBSCRIPTION.skins do
		if s.skin == id then
			return s.month <= month
		end
	end
	return false
end

function Catalog.product(key: string): Product?
	for _, p in Catalog.PRODUCTS do
		if p.key == key then
			return p
		end
	end
	return nil
end

-- The Flag Shop's product for a flag of this rarity (common flags are sold as rare).
function Catalog.flagProduct(rarity: string): string
	return if rarity == "legendary" then "flagLegendary" elseif rarity == "epic" then "flagEpic" else "flagRare"
end

return Catalog
