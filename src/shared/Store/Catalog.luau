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
export type Cosmetic = { id: string, kind: "skin" | "flag" | "title" | "name" | "conquest" | "blast", name: string, rarity: Rarity, set: string? }

-- What a player can wear at once: one of each kind (Profile.equip), sent
-- into matches (Store.loadout, the roster).
Catalog.SLOTS = { "skin", "flag", "title", "name", "conquest", "blast" }

-- Cosmetics beyond skins and flags (Campaign Pass season 1, 2026-11-23):
-- titles under your name, match effects others see, a gold name. Earned
-- from the pass; drawn in matches once the map shows them.
Catalog.EXTRAS = {
	{ id = "t_recruit", kind = "title", name = "Recruit", rarity = "rare", set = "campaign" },
	{ id = "t_veteran", kind = "title", name = "Veteran", rarity = "epic", set = "campaign" },
	{ id = "t_warlord", kind = "title", name = "Warlord", rarity = "legendary", set = "campaign" },
	{ id = "t_soldier", kind = "title", name = "Soldier", rarity = "rare", set = "campaign" },
	{ id = "x_conquest_gold", kind = "conquest", name = "Gold Conquest Flash", rarity = "epic", set = "campaign" },
	{ id = "x_blast_ironroad", kind = "blast", name = "Iron Road Blast", rarity = "legendary", set = "campaign" },
	{ id = "n_gold", kind = "name", name = "Gold Name", rarity = "legendary", set = "campaign" },
} :: { Cosmetic }

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
for _, s in Skins.CAMPAIGN do
	local c: Cosmetic = { id = s.id, kind = "skin", name = s.name, rarity = s.rarity, set = "campaign" }
	table.insert(cosmetics, c)
	byId[c.id] = c
end
for _, f in FlagList do
	local c: Cosmetic = { id = f.id, kind = "flag", name = f.name, rarity = f.rarity :: Rarity, set = f.set }
	table.insert(cosmetics, c)
	byId[c.id] = c
end

for _, c in Catalog.EXTRAS do
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
		return set ~= "general" and set ~= "campaign" -- subscribers' and the pass's: never in crates
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
		stars = 16000,
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
		stars = 30000,
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
		stars = 16000,
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
		stars = 50000,
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
		stars = 100000,
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
		stars = 8000,
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
		stars = 8000,
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
		stars = 16000,
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
		stars = 30000,
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
	{ key = "crate5", kind = "product", name = "5 Cosmetic Crates", price = 179, desc = "Five crates: skins or country flags you don't own yet. Odds are shown in game." },
	{ key = "crateFirst", kind = "product", name = "First Crate", price = 15, desc = "Your first cosmetic crate at a discount. Once per player." },
	{ key = "flagRare", kind = "product", name = "Rare Flag", price = 49, desc = "The rare flag you picked in the Flag Shop, yours to keep." },
	{ key = "flagEpic", kind = "product", name = "Epic Flag", price = 99, desc = "The epic flag you picked in the Flag Shop, yours to keep." },
	{ key = "flagLegendary", kind = "product", name = "Legendary Flag", price = 149, desc = "The legendary flag you picked in the Flag Shop, yours to keep." },
	{ key = "unlockReinforce", kind = "product", name = "Arsenal: Reinforcements", price = 79, desc = "Unlock Reinforcements for good: troops for gold, every 30 seconds." },
	{ key = "unlockMega", kind = "product", name = "Arsenal: Mega Nuke", price = 129, desc = "Unlock the Mega Nuke for good: twice an Atom Bomb's blast radius." },
	{ key = "unlockScatter", kind = "product", name = "Arsenal: Scattershot", price = 129, desc = "Unlock the Scattershot for good: an Atom Bomb with 4 to 6 warheads around it." },
	{ key = "starterPack", kind = "product", name = "Starter Pack", price = 39, desc = "Mega Nuke, Scattershot and 2x Stars for good. Once per player, for a limited time." },
	{ key = "takeover", kind = "product", name = "Takeover", price = 25, desc = "Take command of the AI nation that eliminated you: its land, army, gold and buildings." },
	-- In-match boosts (Bruno, 2026-11-23: names, prices and limits approved).
	{ key = "warChest", kind = "product", name = "War Chest", price = 25, desc = "Gold now in your match: three minutes of your income, at least 500K. Once every two minutes." },
	{ key = "rearm", kind = "product", name = "Instant Rearm", price = 15, desc = "Every silo, SAM, battery, airfield and railgun of yours reloads at once. Once a minute." },
	{ key = "secondSpawn", kind = "product", name = "Second Spawn", price = 25, desc = "Wiped out in a match's first five minutes? Start again at a spot you pick, with starting troops. Once a match." },
	{ key = "starBoost", kind = "product", name = "Star Boost", price = 19, desc = "Double stars for an hour of play, on top of 2x Stars." },
	-- The Campaign Pass's premium track for the current season (Bruno, 2026-11-23).
	{ key = "campaignPass", kind = "product", name = "Campaign Pass", price = 199, desc = "This season's premium rewards: exclusive skins and flags, crates and stars." },
	-- Gifts for a friend in your party (Bruno, 2026-11-23: 3 crates, 5 crates, the pass).
	{ key = "giftCrate3", kind = "product", name = "Gift: 3 Cosmetic Crates", price = 119, desc = "Three crates for the friend you picked. They open them next time they play." },
	{ key = "giftCrate5", kind = "product", name = "Gift: 5 Cosmetic Crates", price = 179, desc = "Five crates for the friend you picked. They open them next time they play." },
	{ key = "giftPass", kind = "product", name = "Gift: Campaign Pass", price = 199, desc = "This season's Campaign Pass premium for the friend you picked." },
	{ key = "unlockAirStrike", kind = "product", name = "Arsenal: Air Strike", price = 199, desc = "Unlock Air Strikes for good: airfields that bomb a 15-tile circle up to 156 tiles away." },
	{ key = "unlockRailgun", kind = "product", name = "Arsenal: Railgun", price = 349, desc = "Unlock the Railgun for good: hits anywhere on the map and knocks buildings down a level." },
	{ key = "unlockRapidReload", kind = "product", name = "Arsenal: Rapid Reload", price = 129, desc = "Every reload of yours takes half as long: silos, SAMs, Artillery, Airfields and Railguns." },
	{ key = "unlockCoastal", kind = "product", name = "Arsenal: Coastal Battery", price = 49, desc = "Unlock the Coastal Battery for good: shore guns that sink enemy boats within 40 tiles." },
	{ key = "unlockSabotage", kind = "product", name = "Arsenal: Sabotage", price = 79, desc = "Unlock Sabotage for good: switch off an enemy building (a SAM, silo, gun or port) for 30 seconds." },
	{ key = "unlockFieldWorks", kind = "product", name = "Arsenal: Field Works", price = 49, desc = "Unlock Field Works for good: earthworks near a front that defend like a defense post for 60 seconds." },
	{ key = "unlockParatroopers", kind = "product", name = "Arsenal: Paratroopers", price = 129, desc = "Unlock Paratroopers for good: fly troops from a city up to 120 tiles away to attack behind the front." },
	{ key = "unlockArtillery", kind = "product", name = "Arsenal: Artillery", price = 79, desc = "Unlock Artillery for good: batteries that shell every enemy within 45 tiles." },
	{ key = "doubleStars", kind = "pass", name = "2x Stars", price = 199, desc = "Every match pays double stars, forever." },
	-- Daily deals, 40% off (Bruno, 2026-11-16; Catalog.dealOf picks one a day).
	{ key = "dealReinforce", kind = "product", name = "Deal: Reinforcements", price = 47, desc = "Today's deal: unlock Reinforcements for good, 40% off." },
	{ key = "dealMega", kind = "product", name = "Deal: Mega Nuke", price = 77, desc = "Today's deal: unlock Mega Nuke for good, 40% off." },
	{ key = "dealScatter", kind = "product", name = "Deal: Scattershot", price = 77, desc = "Today's deal: unlock Scattershot for good, 40% off." },
	{ key = "dealArtillery", kind = "product", name = "Deal: Artillery", price = 47, desc = "Today's deal: unlock Artillery for good, 40% off." },
	{ key = "dealAirStrike", kind = "product", name = "Deal: Air Strike", price = 119, desc = "Today's deal: unlock Air Strike for good, 40% off." },
	{ key = "dealRailgun", kind = "product", name = "Deal: Railgun", price = 209, desc = "Today's deal: unlock Railgun for good, 40% off." },
	{ key = "dealRapidReload", kind = "product", name = "Deal: Rapid Reload", price = 77, desc = "Today's deal: unlock Rapid Reload for good, 40% off." },
	{ key = "dealCoastal", kind = "product", name = "Deal: Coastal Battery", price = 29, desc = "Today's deal: unlock Coastal Battery for good, 40% off." },
	{ key = "dealSabotage", kind = "product", name = "Deal: Sabotage", price = 47, desc = "Today's deal: unlock Sabotage for good, 40% off." },
	{ key = "dealFieldWorks", kind = "product", name = "Deal: Field Works", price = 29, desc = "Today's deal: unlock Field Works for good, 40% off." },
	{ key = "dealParatroopers", kind = "product", name = "Deal: Paratroopers", price = 77, desc = "Today's deal: unlock Paratroopers for good, 40% off." },
	-- Star packs (Bruno, 2026-11-16; Catalog.STAR_PACKS).
	{ key = "stars10k", kind = "product", name = "10,000 Stars", price = 29, desc = "10,000 stars to spend in the Arsenal and the Locker." },
	{ key = "stars35k", kind = "product", name = "35,000 Stars", price = 89, desc = "35,000 stars to spend in the Arsenal and the Locker." },
	{ key = "stars100k", kind = "product", name = "100,000 Stars", price = 219, desc = "100,000 stars to spend in the Arsenal and the Locker." },
	{ key = "stars300k", kind = "product", name = "300,000 Stars", price = 599, desc = "300,000 stars to spend in the Arsenal and the Locker." },
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
	regular = 129 + 129 + 199, -- Mega Nuke, Scattershot, 2x Stars (2026-11-23 prices)
})

-- The launch event (Bruno, 2026-11-13): for 7 days everyone who plays may
-- claim the starter pack's items free, once ("[🎁 LAUNCH GIFT]" in the
-- title). `startsAt` is the UTC os.time() it opens; 0 = off. Runs 2026-11-14
-- 00:00 UTC to 2026-11-21 00:00 UTC (7 PM EST Nov 13 to 7 PM EST Nov 20).
Catalog.LAUNCH_GIFT = table.freeze({
	startsAt = 1794614400,
	durationS = 7 * 24 * 3600,
})

-- Invite rewards (2026-11-15 review, Bruno: "Do them all"): stars for the
-- inviter when a brand-new player they invited plays a match of at least
-- `minMinutes`, at most `perDay` friends a UTC day (more wait for the next).
Catalog.REFERRAL = table.freeze({
	stars = 1000,
	perDay = 5,
	minMinutes = 3,
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

-- Star packs (Bruno, 2026-11-16: "Star top-ups", these four): Robux for
-- stars, offered on an Arsenal card for what it's short. Smaller packs cost
-- more a star (2.9 R$ per 1K down to 2.0).
export type StarPack = { key: string, stars: number, price: number }
Catalog.STAR_PACKS = table.freeze({
	table.freeze({ key = "stars10k", stars = 10000, price = 29 }),
	table.freeze({ key = "stars35k", stars = 35000, price = 89 }),
	table.freeze({ key = "stars100k", stars = 100000, price = 219 }),
	table.freeze({ key = "stars300k", stars = 300000, price = 599 }),
}) :: { StarPack }

-- The daily deal (Bruno, 2026-11-16: "Daily deal", 40% off): each player has
-- one Arsenal unlock they don't own at a discount each UTC day, its own
-- "deal" product (Catalog.dealProduct).
Catalog.DEAL = table.freeze({ off = 0.4 })

-- A weapon's deal product key ("unlockArtillery" -> "dealArtillery").
function Catalog.dealProduct(w: Weapon): string?
	local key = w.product
	if key == nil or string.sub(key, 1, 6) ~= "unlock" then
		return nil
	end
	return "deal" .. string.sub(key, 7)
end

-- The smallest star pack that covers `short` stars, or nil when none does.
function Catalog.starPackFor(short: number): StarPack?
	if short <= 0 then
		return nil
	end
	for _, pack in Catalog.STAR_PACKS do
		if pack.stars >= short then
			return pack
		end
	end
	return nil
end

-- The weapon on a deal for player `userId` on UTC day `day` (os.time() //
-- 86400): one of the Arsenal unlocks with a deal product they don't own,
-- picked the same way on the client and the server; nil when they own all.
function Catalog.dealOf(userId: number, day: number, owned: { [string]: boolean }): Weapon?
	local candidates = {}
	for _, w in Catalog.ARSENAL do
		if Catalog.dealProduct(w) and not owned[w.id] then
			table.insert(candidates, w)
		end
	end
	if #candidates == 0 then
		return nil
	end
	local h = ((math.abs(userId) % 1000003) * 7919 + day * 104729) % #candidates
	return candidates[h + 1]
end

-- Today's deal for a player (Catalog.dealOf), or nil once they've bought a
-- deal today (`boughtDay`, Profile's dealDay): one deal a day.
function Catalog.todaysDeal(userId: number, now: number, owned: { [string]: boolean }, boughtDay: number?): Weapon?
	local day = now // 86400
	if boughtDay == day then
		return nil
	end
	return Catalog.dealOf(userId, day, owned)
end

-- A deal product's weapon.
function Catalog.dealWeapon(productKey: string): Weapon?
	for _, w in Catalog.ARSENAL do
		if Catalog.dealProduct(w) == productKey then
			return w
		end
	end
	return nil
end

-- A star pack by its product key.
function Catalog.starPack(productKey: string): StarPack?
	for _, pack in Catalog.STAR_PACKS do
		if pack.key == productKey then
			return pack
		end
	end
	return nil
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
