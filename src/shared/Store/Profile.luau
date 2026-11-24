--!strict
-- A player's saved record for the RoFront-level pass: stars, matches,
-- cosmetics and Arsenal unlocks, what they wear, their settings, and the
-- purchases already granted (so a receipt is never granted twice). Pure: the
-- server's Store adapter saves it (ProfileStore, session-locked) and calls it.
-- Tuning values are Prototype defaults; docs/design/store-items.md lists them.

local Pass = require(script.Parent.Pass)
local Catalog = require(script.Parent.Catalog)
local FlagShop = require(script.Parent.FlagShop)
local PlayerSettings = require(script.Parent.Parent.PlayerSettings)

local Profile = {}

Profile.SCHEMA = 1
Profile.MAX_RECEIPTS = 200
Profile.CRATE_STARS = 2500 -- a crate for stars
Profile.DUPLICATE_STARS = 1000 -- given instead when a crate has nothing left to give
Profile.STARTER_DUPLICATE_STARS = 5000 -- for a starter pack item already owned
Profile.CRATE_ODDS = {
	{ rarity = "common", percent = 62 },
	{ rarity = "rare", percent = 25 },
	{ rarity = "epic", percent = 10 },
	{ rarity = "legendary", percent = 3 },
}
-- Stars per match: per minute played (up to MAX_MINUTES), for placing in
-- the top tenth, and for winning; solo scales by difficulty, public by 1.25.
Profile.STARS_PER_MINUTE = 60
Profile.MAX_MINUTES = 40
Profile.TOP_STARS = 400
Profile.WIN_STARS = 1000
Profile.DIFFICULTY_SCALE = { Easy = 0.5, Medium = 1, Hard = 1.5, Impossible = 2 }
Profile.PUBLIC_SCALE = 1.25

local TUTORIAL_STATES = { started = true, done = true, skipped = true, left = true }
local MAX_TIPS, MAX_TIP_ID = 32, 24

export type Record = {
	stars: number,
	matches: number,
	wins: number,
	owned: { [string]: boolean },
	equipped: { [string]: string }, -- Catalog.SLOTS -> item id
	settings: PlayerSettings.Settings,
	firstCrateUsed: boolean,
	receipts: { string },
	pendingFlag: string?,
	-- Takeovers bought and not yet used (the Arsenal's Takeover, 25 R$ a use).
	takeovers: number,
	-- Ever paid Robux (the starter pack is for those who haven't).
	paid: boolean,
	-- The starter pack's offer, from the first time it was on their screen
	-- (os.time): a real deadline, never restarted.
	starter: { started: number, ends: number, used: boolean? }?,
	-- A General's (the subscription's) last UTC day whose crate was given.
	generalDay: number,
	-- The tutorial (Shared/Tutorial): "started", "done", "skipped" or "left";
	-- nil for a player who never began it.
	tutorial: string?,
	-- Coach tips already shown (ids), and whether the tutorial's stars were paid.
	tipsSeen: { [string]: boolean },
	tutorialPaid: boolean,
	-- The launch event's free starter pack was claimed (Catalog.LAUNCH_GIFT).
	giftClaimed: boolean,
	-- Invite rewards (Catalog.REFERRAL). As the invited: who invited them
	-- (a userId, set once on a brand-new profile) and whether their first
	-- match has credited that inviter. As the inviter: the UTC day of the
	-- last friends paid for and how many that day.
	referredBy: number?,
	referralCredited: boolean,
	referralDay: number,
	referralsToday: number,
	-- The UTC day (os.time() // 86400) a daily deal was last bought: one a
	-- day, so the Arsenal shows no second deal that day (Catalog.todaysDeal).
	dealDay: number,
	-- The free crate (Bruno, 2026-11-16: one per player, new or returning,
	-- after their first match) was opened.
	freeCrateUsed: boolean,
	-- In-match boosts bought and not yet used (Bruno, 2026-11-23): War Chest,
	-- Instant Rearm and Second Spawn credits, by Profile.BOOSTS key.
	boosts: { [string]: number },
	-- Star Boost: seconds of play left at double stars (an hour a purchase).
	starBoostLeft: number,
	-- The Campaign Pass (Store/Pass) for the season it was last touched in.
	pass: PassState?,
	-- Gifts (2026-11-23): whom the player picked before the gift's prompt,
	-- and gifts bought but not yet in the friend's mailbox (the server
	-- delivers them, then removes them here).
	pendingGift: { to: number, product: string, at: number }?,
	giftsOut: { { to: number, product: string, id: string } },
}

export type PassState = {
	season: number,
	xp: number,
	premium: boolean,
	free: { [number]: boolean }, -- tiers claimed on the free track
	paid: { [number]: boolean }, -- and on the premium track
	day: number, -- the UTC day the daily counters are for
	daily: { [string]: number }, -- mission id -> progress
	week: number,
	weekly: { [string]: number },
}

export type MatchResult = {
	won: boolean,
	placement: number, -- 1 = the biggest at the end
	players: number, -- everyone who took part
	minutes: number,
	difficulty: string?, -- solo; nil = public
}

function Profile.new(): Record
	return {
		stars = 0,
		matches = 0,
		wins = 0,
		owned = {},
		equipped = {},
		settings = PlayerSettings.defaults(),
		firstCrateUsed = false,
		receipts = {},
		pendingFlag = nil,
		takeovers = 0,
		paid = false,
		starter = nil,
		generalDay = 0,
		tutorial = nil,
		tipsSeen = {},
		tutorialPaid = false,
		giftClaimed = false,
		referredBy = nil,
		referralCredited = false,
		referralDay = 0,
		referralsToday = 0,
		dealDay = 0,
		freeCrateUsed = false,
		boosts = {},
		starBoostLeft = 0,
		pass = nil,
		pendingGift = nil,
		giftsOut = {},
	}
end

-- Gift products and what the friend gets (Profile.receiveGift).
Profile.GIFTS = table.freeze({
	giftCrate3 = { crates = 3 },
	giftCrate5 = { crates = 5 },
	giftPass = { pass = true },
})
-- A pick older than this no longer names the friend (the gift goes to the
-- buyer instead).
Profile.GIFT_PICK_S = 30 * 60

-- The player picks whom their next gift is for, just before its prompt.
function Profile.pickGift(p: Record, product: string, to: number, now: number): boolean
	if Profile.GIFTS[product] == nil or type(to) ~= "number" or to <= 0 then
		return false
	end
	p.pendingGift = { to = to, product = product, at = now }
	return true
end

-- What a gift gives its receiver: crates, or the season's pass premium
-- (five crates instead for someone who has it).
function Profile.receiveGift(p: Record, product: string, roll: () -> number, now: number): Grant
	local grant: Grant = { kind = "gift", items = {}, stars = 0 }
	local g = Profile.GIFTS[product]
	if g == nil then
		return grant
	end
	local crates = g.crates or 0
	if g.pass then
		local s = Profile.passOf(p, now)
		if s and not s.premium then
			s.premium = true
			grant.kind = "giftPass"
		else
			crates = 5
		end
	end
	for _ = 1, crates do
		local item = Profile.openCrate(p, roll)
		if item then
			table.insert(grant.items, item.id)
		else
			p.stars += Profile.DUPLICATE_STARS
			grant.stars += Profile.DUPLICATE_STARS
		end
	end
	return grant
end

-- The in-match boosts (2026-11-23): product key -> what a credit is called.
-- Each purchase saves one credit, spent when the match applies it.
Profile.BOOSTS = table.freeze({ warChest = true, rearm = true, secondSpawn = true })
-- Star Boost: an hour of play at double stars a purchase (stacking; on top
-- of 2x Stars, so 4x with both).
Profile.STAR_BOOST_S = 3600

function Profile.starsFor(result: MatchResult, double: boolean): number
	local minutes = math.clamp(result.minutes, 0, Profile.MAX_MINUTES)
	if minutes < 1 then
		return 0
	end
	local stars = minutes * Profile.STARS_PER_MINUTE
	if result.placement <= math.max(1, math.ceil(result.players / 10)) then
		stars += Profile.TOP_STARS
	end
	if result.won then
		stars += Profile.WIN_STARS
	end
	local scale = if result.difficulty then (Profile.DIFFICULTY_SCALE[result.difficulty] or 1) else Profile.PUBLIC_SCALE
	return math.floor(stars * scale) * (if double then 2 else 1)
end

-- Applies a finished match; returns the stars it paid.
function Profile.applyMatch(p: Record, result: MatchResult, double: boolean, general: boolean?): number
	local stars = Profile.starsFor(result, double)
	-- Star Boost doubles again the stars of the minutes it covers, and those
	-- minutes come off it.
	if stars > 0 and p.starBoostLeft > 0 then
		local seconds = math.clamp(result.minutes, 0, Profile.MAX_MINUTES) * 60
		local boosted = math.min(seconds, p.starBoostLeft)
		stars += math.floor(stars * boosted / seconds)
		p.starBoostLeft = math.max(0, math.floor(p.starBoostLeft - boosted))
	end
	-- A General gets half again (of the stars before 2x Stars).
	if general then
		stars += math.floor(Profile.starsFor(result, false) * Catalog.SUBSCRIPTION.starsBonus)
	end
	p.stars += stars
	p.matches += 1
	if result.won then
		p.wins += 1
	end
	return stars
end

-- Unlocks an Arsenal weapon for stars. False and nothing spent if it is
-- owned, Robux-only or too dear.
function Profile.unlockWithStars(p: Record, weaponId: string): (boolean, string?)
	local w = Catalog.weapon(weaponId)
	if w == nil or w.stars == nil then
		return false, "unknown"
	end
	if p.owned[weaponId] then
		return false, "owned"
	end
	if p.stars < w.stars then
		return false, "stars"
	end
	p.stars -= w.stars
	p.owned[weaponId] = true
	return true, nil
end

-- A crate: a rarity by CRATE_ODDS, then an item of it you don't own (any
-- unowned crate item if that rarity is complete). `roll` returns [0, 1).
-- Nil when there is nothing left to give.
function Profile.openCrate(p: Record, roll: () -> number): Catalog.Cosmetic?
	local byRarity: { [string]: { Catalog.Cosmetic } } = {}
	local any: { Catalog.Cosmetic } = {}
	for _, c in Catalog.cosmetics() do
		if Catalog.crateable(c) and not p.owned[c.id] then
			byRarity[c.rarity] = byRarity[c.rarity] or {}
			table.insert(byRarity[c.rarity], c)
			table.insert(any, c)
		end
	end
	if #any == 0 then
		return nil
	end
	local r = roll() * 100
	local rarity = "common"
	for _, odds in Profile.CRATE_ODDS do
		r -= odds.percent
		if r < 0 then
			rarity = odds.rarity
			break
		end
	end
	local pool = byRarity[rarity] or any
	local item = pool[math.floor(roll() * #pool) + 1]
	p.owned[item.id] = true
	return item
end

-- The free crate (Bruno, 2026-11-16): once per player, kept until opened,
-- from the end of their first match (the tutorial counts), so it never
-- interrupts the tutorial. Normal crate odds; the first bought crate's
-- discount stays.
function Profile.freeCrateReady(p: Record): boolean
	return not p.freeCrateUsed and p.matches >= 1
end

-- Opens the free crate: the item, or nil and why ("used", "later"). A player
-- who owns every crate item gets DUPLICATE_STARS instead ("complete").
function Profile.openFreeCrate(p: Record, roll: () -> number): (Catalog.Cosmetic?, string?)
	if p.freeCrateUsed then
		return nil, "used"
	end
	if not Profile.freeCrateReady(p) then
		return nil, "later"
	end
	p.freeCrateUsed = true
	local item = Profile.openCrate(p, roll)
	if item == nil then
		p.stars += Profile.DUPLICATE_STARS
		return nil, "complete"
	end
	return item, nil
end

-- A crate for stars.
function Profile.crateWithStars(p: Record, roll: () -> number): (Catalog.Cosmetic?, string?)
	if p.stars < Profile.CRATE_STARS then
		return nil, "stars"
	end
	local item = Profile.openCrate(p, roll)
	if item == nil then
		return nil, "complete"
	end
	p.stars -= Profile.CRATE_STARS
	return item, nil
end

function Profile.equip(p: Record, kind: string, id: string?): boolean
	if not table.find(Catalog.SLOTS, kind) then
		return false
	end
	if id ~= nil then
		local c = Catalog.get(id)
		if c == nil or c.kind ~= kind or not p.owned[id] then
			return false
		end
	end
	(p.equipped :: any)[kind] = id
	return true
end

-- The Flag Shop: the flag a player is about to buy (checked when the
-- receipt arrives). False if it isn't on sale or is already theirs.
function Profile.chooseFlag(p: Record, flagId: string, now: number): boolean
	local c = Catalog.get(flagId)
	if c == nil or c.kind ~= "flag" or p.owned[flagId] or not FlagShop.onSale(now, flagId) then
		return false
	end
	p.pendingFlag = flagId
	return true
end

export type Grant = { kind: string, items: { string }, stars: number }

-- Grants a Robux purchase once: `purchaseId` is the receipt's PurchaseId.
-- Returns the grant, or nil if this purchase was granted before.
function Profile.grant(p: Record, productKey: string, purchaseId: string, roll: () -> number, now: number): Grant?
	if table.find(p.receipts, purchaseId) then
		return nil
	end
	local grant: Grant = { kind = productKey, items = {}, stars = 0 }
	local function crate()
		local item = Profile.openCrate(p, roll)
		if item then
			table.insert(grant.items, item.id)
		else
			p.stars += Profile.DUPLICATE_STARS
			grant.stars += Profile.DUPLICATE_STARS
		end
	end
	if productKey == Catalog.STARTER.product then
		-- The starter pack: each item, or stars for one already owned.
		for _, id in Catalog.STARTER.items do
			if p.owned[id] then
				p.stars += Profile.STARTER_DUPLICATE_STARS
				grant.stars += Profile.STARTER_DUPLICATE_STARS
			else
				p.owned[id] = true
				table.insert(grant.items, id)
			end
		end
		local s: { started: number, ends: number, used: boolean? } = p.starter or { started = now, ends = now, used = nil }
		s.used = true
		p.starter = s
	elseif Profile.BOOSTS[productKey] then
		p.boosts[productKey] = (p.boosts[productKey] or 0) + 1
	elseif productKey == "starBoost" then
		p.starBoostLeft += Profile.STAR_BOOST_S
	elseif Profile.GIFTS[productKey] then
		-- A gift: into the outbox for the friend picked, or, with no fresh
		-- pick for this product, to the buyer.
		local pick = p.pendingGift
		p.pendingGift = nil
		if pick and pick.product == productKey and now - pick.at <= Profile.GIFT_PICK_S then
			table.insert(p.giftsOut, { to = pick.to, product = productKey, id = purchaseId })
			grant.kind = "giftSent"
		else
			local own = Profile.receiveGift(p, productKey, roll, now)
			grant.items, grant.stars = own.items, own.stars
		end
	elseif productKey == "campaignPass" then
		-- The premium track for the season it was bought in.
		local s = Profile.passOf(p, now)
		if s then
			s.premium = true
		end
	elseif productKey == "takeover" then
		-- One use, saved until a nation next eliminates the player.
		p.takeovers += 1
	elseif productKey == "crate1" then
		crate()
	elseif productKey == "crateFirst" then
		p.firstCrateUsed = true
		crate()
	elseif productKey == "crate3" then
		crate()
		crate()
		crate()
	elseif productKey == "crate5" then
		-- Bruno, 2026-11-23: a 5-pack at 179 (the single crate is hidden).
		for _ = 1, 5 do
			crate()
		end
	elseif productKey == "flagRare" or productKey == "flagEpic" or productKey == "flagLegendary" then
		-- The flag chosen in the shop; if it no longer fits (sold out, owned,
		-- another rarity), another unowned flag of that tier on sale; else stars.
		local chosen = p.pendingFlag
		p.pendingFlag = nil
		local c = if chosen then Catalog.get(chosen) else nil
		if c and not p.owned[c.id] and Catalog.flagProduct(c.rarity) == productKey then
			p.owned[c.id] = true
			table.insert(grant.items, c.id)
		else
			local offers = FlagShop.offers(now)
			local all = table.clone(offers.daily)
			if offers.event then
				for _, id in offers.event.flags do
					table.insert(all, id)
				end
			end
			local found = nil
			for _, id in all do
				local f = Catalog.get(id)
				if f and not p.owned[id] and Catalog.flagProduct(f.rarity) == productKey then
					found = id
					break
				end
			end
			if found then
				p.owned[found] = true
				table.insert(grant.items, found)
			else
				p.stars += Profile.DUPLICATE_STARS * 2
				grant.stars += Profile.DUPLICATE_STARS * 2
			end
		end
	elseif Catalog.starPack(productKey) then
		-- A star pack (Catalog.STAR_PACKS).
		local pack = Catalog.starPack(productKey) :: Catalog.StarPack
		p.stars += pack.stars
		grant.stars += pack.stars
	elseif Catalog.dealWeapon(productKey) then
		-- A daily deal: its weapon for good (paid, so whatever the day now),
		-- or stars at the deal's price if it's owned meanwhile.
		local w = Catalog.dealWeapon(productKey) :: Catalog.Weapon
		p.dealDay = math.max(p.dealDay, now // 86400)
		if p.owned[w.id] then
			p.stars += w.stars or Profile.DUPLICATE_STARS
			grant.stars += w.stars or Profile.DUPLICATE_STARS
		else
			p.owned[w.id] = true
			table.insert(grant.items, w.id)
		end
	else
		local unlocked = false
		for _, w in Catalog.ARSENAL do
			if w.product == productKey then
				p.owned[w.id] = true
				table.insert(grant.items, w.id)
				unlocked = true
			end
		end
		if not unlocked then
			return nil -- unknown product: not granted, the receipt stays open
		end
	end
	p.paid = true
	table.insert(p.receipts, purchaseId)
	while #p.receipts > Profile.MAX_RECEIPTS do
		table.remove(p.receipts, 1)
	end
	return grant
end

-- A Robux receipt, start to finish: grants it once (Profile.grant) and says
-- whether Roblox may be told it is done. That is only ever after `save`
-- succeeded in a session that can save: a session that can't (its profile
-- failed to load, or its lock was lost) never confirms, so Roblox offers the
-- receipt again in a session that can keep it. Returns (confirm, grant):
-- `grant` is what this call gave, nil if nothing new.
function Profile.processReceipt(p: Record, canSave: boolean, productKey: string, purchaseId: string, roll: () -> number, now: number, save: () -> boolean): (boolean, Grant?)
	if table.find(p.receipts, purchaseId) then
		-- Granted before: confirm once it is saved.
		return canSave and save(), nil
	end
	local grant = Profile.grant(p, productKey, purchaseId, roll, now)
	if grant == nil then
		return false, nil
	end
	return canSave and save(), grant
end

-- Which Arsenal weapons a player may use in a match (engine keys).
function Profile.weapons(p: Record): { [string]: boolean }
	local out = {}
	for _, w in Catalog.ARSENAL do
		if w.weapon and p.owned[w.id] then
			out[w.weapon] = true
		end
	end
	return out
end

export type View = {
	stars: number,
	matches: number,
	wins: number,
	owned: { string },
	equipped: { [string]: string },
	settings: PlayerSettings.Settings,
	cratePrice: number, -- Robux: 15 for the first crate, then 49
	crateKey: string,
	saved: boolean,
	doubleStars: boolean,
	starter: string?, -- Profile.starterState
	starterLeft: number?, -- seconds, when this view was made
	gift: string?, -- Profile.giftState
	giftLeft: number?, -- seconds until the launch event ends, when this view was made
	takeovers: number,
	general: boolean, -- subscribed (the server asks Roblox)
	tutorial: string?,
	tipsSeen: { string },
	dealDay: number?, -- the UTC day a daily deal was last bought
	freeCrate: boolean?, -- the free crate is waiting to be opened
	boosts: { [string]: number }, -- in-match boost credits
	starBoostLeft: number, -- seconds of double-star play left
	pass: { [string]: any }?, -- the Campaign Pass (passView)
}

local function tipList(p: Record): { string }
	local out = {}
	for id in p.tipsSeen do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

function Profile.view(p: Record, saved: boolean, doubleStars: boolean, general: boolean?, now: number?): View
	local owned = {}
	for id in p.owned do
		table.insert(owned, id)
	end
	table.sort(owned)
	local first = not p.firstCrateUsed
	local crate = Catalog.product(if first then "crateFirst" else "crate1") :: Catalog.Product
	local starter, starterLeft = Profile.starterState(p, now or os.time())
	local gift, giftLeft = Profile.giftState(p, now or os.time())
	return {
		stars = p.stars,
		matches = p.matches,
		wins = p.wins,
		owned = owned,
		equipped = table.clone(p.equipped),
		settings = table.clone(p.settings),
		cratePrice = crate.price,
		crateKey = crate.key,
		saved = saved,
		doubleStars = doubleStars or p.owned.b_double == true,
		starter = starter,
		starterLeft = starterLeft,
		gift = gift,
		giftLeft = giftLeft,
		takeovers = p.takeovers,
		general = general == true,
		tutorial = p.tutorial,
		tipsSeen = tipList(p),
		dealDay = if p.dealDay > 0 then p.dealDay else nil,
		freeCrate = if Profile.freeCrateReady(p) then true else nil,
		boosts = table.clone(p.boosts),
		starBoostLeft = p.starBoostLeft,
		pass = Profile.passView(p, now or os.time()),
	}
end

-- Stored form -----------------------------------------------------------------------------

local function isCount(v: any): boolean
	return type(v) == "number" and v >= 0 and v < 1e13 and v == math.floor(v)
end

function Profile.encode(p: Record): { [string]: any }
	local owned = {}
	for id in p.owned do
		table.insert(owned, id)
	end
	table.sort(owned)
	return {
		schema = Profile.SCHEMA,
		stars = p.stars,
		matches = p.matches,
		wins = p.wins,
		owned = owned,
		equipped = table.clone(p.equipped),
		settings = table.clone(p.settings),
		firstCrateUsed = p.firstCrateUsed,
		receipts = table.clone(p.receipts),
		pendingFlag = p.pendingFlag,
		takeovers = p.takeovers,
		paid = p.paid,
		starter = if p.starter then table.clone(p.starter) else nil,
		generalDay = p.generalDay,
		tutorial = p.tutorial,
		tipsSeen = tipList(p),
		tutorialPaid = p.tutorialPaid,
		giftClaimed = if p.giftClaimed then true else nil,
		referredBy = p.referredBy,
		referralCredited = if p.referralCredited then true else nil,
		referralDay = if p.referralDay > 0 then p.referralDay else nil,
		referralsToday = if p.referralsToday > 0 then p.referralsToday else nil,
		dealDay = if p.dealDay > 0 then p.dealDay else nil,
		freeCrateUsed = if p.freeCrateUsed then true else nil,
		boosts = if next(p.boosts) then table.clone(p.boosts) else nil,
		starBoostLeft = if p.starBoostLeft > 0 then p.starBoostLeft else nil,
		pendingGift = if p.pendingGift then table.clone(p.pendingGift) else nil,
		giftsOut = if #p.giftsOut > 0 then table.clone(p.giftsOut) else nil,
		pass = if p.pass then {
			season = p.pass.season,
			xp = p.pass.xp,
			premium = if p.pass.premium then true else nil,
			free = (function()
				local out = {}
				for t in p.pass.free do
					table.insert(out, t)
				end
				return out
			end)(),
			paid = (function()
				local out = {}
				for t in p.pass.paid do
					table.insert(out, t)
				end
				return out
			end)(),
			day = p.pass.day,
			daily = table.clone(p.pass.daily),
			week = p.pass.week,
			weekly = table.clone(p.pass.weekly),
		} else nil,
	}
end

-- A stored record back into a profile; nil and a reason if it can't be read.
-- Unknown owned ids are kept (a rollback must not delete them).
function Profile.decode(record: any): (Record?, string?)
	if type(record) ~= "table" or type(record.schema) ~= "number" then
		return nil, "corrupt"
	end
	if record.schema > Profile.SCHEMA then
		return nil, "newerSchema"
	end
	if not (isCount(record.stars) and isCount(record.matches) and isCount(record.wins)) then
		return nil, "corrupt"
	end
	if type(record.owned) ~= "table" or #record.owned > 2000 or type(record.receipts) ~= "table" then
		return nil, "corrupt"
	end
	local p = Profile.new()
	p.stars, p.matches, p.wins = record.stars, record.matches, record.wins
	for _, id in record.owned do
		if type(id) ~= "string" or #id > 64 then
			return nil, "corrupt"
		end
		p.owned[id] = true
	end
	for _, r in record.receipts do
		if type(r) == "string" and #r <= 128 then
			table.insert(p.receipts, r)
		end
	end
	if type(record.equipped) == "table" then
		for _, kind in Catalog.SLOTS do
			local id = record.equipped[kind]
			if type(id) == "string" then
				Profile.equip(p, kind, id)
			end
		end
	end
	p.settings = PlayerSettings.sanitize(record.settings)
	p.firstCrateUsed = record.firstCrateUsed == true
	p.pendingFlag = if type(record.pendingFlag) == "string" then record.pendingFlag else nil
	p.takeovers = if isCount(record.takeovers) then record.takeovers else 0
	if type(record.boosts) == "table" then
		for key: string in Profile.BOOSTS :: any do
			local n = record.boosts[key]
			if isCount(n) and n > 0 then
				p.boosts[key] = n
			end
		end
	end
	p.starBoostLeft = if isCount(record.starBoostLeft) then record.starBoostLeft else 0
	local pg = record.pendingGift
	if type(pg) == "table" and isCount(pg.to) and isCount(pg.at) and type(pg.product) == "string" and Profile.GIFTS[pg.product] then
		p.pendingGift = { to = pg.to, product = pg.product, at = pg.at }
	end
	if type(record.giftsOut) == "table" then
		for _, g in record.giftsOut do
			if type(g) == "table" and isCount(g.to) and type(g.product) == "string" and Profile.GIFTS[g.product] and type(g.id) == "string" and #g.id <= 128 then
				table.insert(p.giftsOut, { to = g.to, product = g.product, id = g.id })
			end
		end
	end
	local ps = record.pass
	if type(ps) == "table" and isCount(ps.season) and isCount(ps.xp) and isCount(ps.day) and isCount(ps.week) then
		local s: PassState = { season = ps.season, xp = ps.xp, premium = ps.premium == true, free = {}, paid = {}, day = ps.day, daily = {}, week = ps.week, weekly = {} }
		for _, field in { "free", "paid" } do
			if type(ps[field]) == "table" then
				for _, t in ps[field] do
					if isCount(t) and t >= 1 and t <= Pass.TIERS then
						(s :: any)[field][t] = true
					end
				end
			end
		end
		for _, field in { "daily", "weekly" } do
			if type(ps[field]) == "table" then
				for id, n in ps[field] do
					if type(id) == "string" and #id <= 32 and isCount(n) then
						(s :: any)[field][id] = n
					end
				end
			end
		end
		p.pass = s
	end
	-- Records from before `paid` count any receipt.
	p.paid = record.paid == true or #p.receipts > 0
	local s = record.starter
	if type(s) == "table" and isCount(s.started) and isCount(s.ends) then
		p.starter = { started = s.started, ends = s.ends, used = if s.used == true then true else nil }
	end
	p.generalDay = if isCount(record.generalDay) then record.generalDay else 0
	p.tutorial = if type(record.tutorial) == "string" and TUTORIAL_STATES[record.tutorial] then record.tutorial else nil
	if type(record.tipsSeen) == "table" then
		for _, id in record.tipsSeen do
			if type(id) == "string" and #id <= MAX_TIP_ID and #record.tipsSeen <= MAX_TIPS then
				p.tipsSeen[id] = true
			end
		end
	end
	p.tutorialPaid = record.tutorialPaid == true
	p.giftClaimed = record.giftClaimed == true
	p.referredBy = if isCount(record.referredBy) and record.referredBy > 0 then record.referredBy else nil
	p.referralCredited = record.referralCredited == true
	p.referralDay = if isCount(record.referralDay) then record.referralDay else 0
	p.referralsToday = if isCount(record.referralsToday) then record.referralsToday else 0
	p.dealDay = if isCount(record.dealDay) then record.dealDay else 0
	p.freeCrateUsed = record.freeCrateUsed == true
	return p, nil
end

-- The tutorial (Shared/Tutorial) ----------------------------------------------------------

-- Saves where the tutorial got to ("started", "done", "skipped", "left").
-- True if it changed the record. A finished tutorial never goes back to
-- "started".
function Profile.setTutorial(p: Record, how: string): boolean
	if not TUTORIAL_STATES[how] or p.tutorial == how then
		return false
	end
	if how == "started" and p.tutorial ~= nil then
		return false
	end
	p.tutorial = how
	return true
end

-- A coach tip was shown (or its lesson done). True if it changed the record.
function Profile.tipSeen(p: Record, id: string): boolean
	if #id == 0 or #id > MAX_TIP_ID or p.tipsSeen[id] then
		return false
	end
	local n = 0
	for _ in p.tipsSeen do
		n += 1
	end
	if n >= MAX_TIPS then
		return false
	end
	p.tipsSeen[id] = true
	return true
end

-- The tutorial's stars, once per player: what was paid now (0 if already).
function Profile.payTutorial(p: Record, stars: number): number
	if p.tutorialPaid then
		return 0
	end
	p.tutorialPaid = true
	p.stars += stars
	return stars
end

-- The starter pack's offer for this player at `now`: "ready" (never shown;
-- its clock starts when it is), "active" (running, `left` seconds to go), or
-- nil (not for them: they've paid Robux, haven't played yet, own it all, or
-- it ended or was bought).
function Profile.starterState(p: Record, now: number): (string?, number?)
	-- Never sold while the launch event gives it away.
	if Profile.giftState(p, now) ~= nil then
		return nil, nil
	end
	local s = p.starter
	if s then
		if s.used or now > s.ends then
			return nil, nil
		end
		return "active", s.ends - now
	end
	if p.paid or p.matches <= 0 then
		return nil, nil
	end
	for _, id in Catalog.STARTER.items do
		if not p.owned[id] then
			return "ready", Catalog.STARTER.durationS
		end
	end
	return nil, nil
end

-- The offer is on the player's screen: its clock starts (once). True if it
-- changed the record.
function Profile.starterSeen(p: Record, now: number): boolean
	if Profile.starterState(p, now) ~= "ready" then
		return false
	end
	p.starter = { started = now, ends = now + Catalog.STARTER.durationS }
	return true
end

-- The launch event's free starter pack (Catalog.LAUNCH_GIFT) for this player
-- at `now`: "claimable" and the seconds until the event ends, or nil (the
-- event is off or over, they claimed it, or they own every item already).
function Profile.giftState(p: Record, now: number): (string?, number?)
	local event = Catalog.LAUNCH_GIFT
	if event.startsAt <= 0 or now < event.startsAt or now >= event.startsAt + event.durationS or p.giftClaimed then
		return nil, nil
	end
	for _, id in Catalog.STARTER.items do
		if not p.owned[id] then
			return "claimable", event.startsAt + event.durationS - now
		end
	end
	return nil, nil
end

-- Claims the launch gift: the starter pack's items they don't own yet, once.
-- Also closes the paid starter offer. Nil if it isn't claimable.
function Profile.claimGift(p: Record, now: number): Grant?
	if Profile.giftState(p, now) ~= "claimable" then
		return nil
	end
	local grant: Grant = { kind = "launchGift", items = {}, stars = 0 }
	for _, id in Catalog.STARTER.items do
		if not p.owned[id] then
			p.owned[id] = true
			table.insert(grant.items, id)
		end
	end
	p.giftClaimed = true
	local s: { started: number, ends: number, used: boolean? } = p.starter or { started = now, ends = now, used = nil }
	s.used = true
	p.starter = s
	return grant
end

-- A General's crate for UTC day `day`, once a day: true if it's due (and
-- now marked given).
function Profile.generalDue(p: Record, day: number): boolean
	if p.generalDay >= day then
		return false
	end
	p.generalDay = day
	return true
end

-- Invite rewards (Catalog.REFERRAL) -------------------------------------------------------

-- Records who invited this player: only on a brand-new profile (no match
-- played), once, never themselves. True if it was recorded.
function Profile.setReferrer(p: Record, inviterId: number, selfId: number): boolean
	if p.referredBy ~= nil or p.matches > 0 or not isCount(inviterId) or inviterId <= 0 or inviterId == selfId then
		return false
	end
	p.referredBy = inviterId
	return true
end

-- After an invited player's match is counted (the caller checks it was long
-- enough): the inviter to credit, once. Nil otherwise.
function Profile.referralDue(p: Record): number?
	if p.referredBy == nil or p.referralCredited or p.matches < 1 then
		return nil
	end
	p.referralCredited = true
	return p.referredBy
end

-- The inviter collects `pending` friends' credits on UTC day `day`: pays
-- up to the day's limit and returns (stars paid, credits left for later).
function Profile.payReferrals(p: Record, pending: number, day: number): (number, number)
	if not isCount(pending) or pending <= 0 then
		return 0, 0
	end
	if p.referralDay ~= day then
		p.referralDay, p.referralsToday = day, 0
	end
	local n = math.min(pending, math.max(0, Catalog.REFERRAL.perDay - p.referralsToday))
	p.referralsToday += n
	local stars = n * Catalog.REFERRAL.stars
	p.stars += stars
	return stars, pending - n
end

-- The Campaign Pass ----------------------------------------------------------------------

-- The player's pass for the season `now` falls in: a fresh one when the
-- season changed; the daily and weekly counters start over with their
-- period. Nil before the first season.
function Profile.passOf(p: Record, now: number): PassState?
	local season = Pass.season(now)
	if season == nil then
		return nil
	end
	local s = p.pass
	if s == nil or s.season ~= season then
		s = { season = season, xp = 0, premium = false, free = {}, paid = {}, day = Pass.day(now), daily = {}, week = Pass.week(now), weekly = {} }
		p.pass = s
	end
	assert(s)
	if s.day ~= Pass.day(now) then
		s.day, s.daily = Pass.day(now), {}
	end
	if s.week ~= Pass.week(now) then
		s.week, s.weekly = Pass.week(now), {}
	end
	return s
end

-- A finished match's XP: the match itself, and every mission it completes
-- (each pays once). Returns the XP gained and the missions done.
function Profile.passMatch(p: Record, result: MatchResult, now: number): (number, { string })
	local s = Profile.passOf(p, now)
	if s == nil then
		return 0, {}
	end
	local stats: Pass.MatchStats = {
		minutes = result.minutes,
		won = result.won,
		top = result.placement <= math.max(1, math.ceil(result.players / 10)),
		public = result.difficulty == nil,
	}
	local gained = Pass.xpForMatch(stats)
	local done = {}
	local function count(missions: { Pass.Mission }, progress: { [string]: number })
		for _, m in missions do
			local before = progress[m.id] or 0
			if before < m.goal then
				local after = math.min(m.goal, before + Pass.statOf(stats, m.stat))
				progress[m.id] = after
				if after >= m.goal then
					gained += m.xp
					table.insert(done, m.id)
				end
			end
		end
	end
	count(Pass.dailyMissions(now), s.daily)
	count(Pass.weeklyMissions(now), s.weekly)
	s.xp += gained
	return gained, done
end

-- Claims tier `tier` of `track` ("free" or "premium"): reached, not yet
-- claimed, premium bought for the premium track. Returns what it gave, or
-- nil and a reason ("season", "tier", "locked", "premium", "claimed").
function Profile.passClaim(p: Record, track: string, tier: number, roll: () -> number, now: number): (Grant?, string?)
	local s = Profile.passOf(p, now)
	if s == nil then
		return nil, "season"
	end
	local reward = Pass.reward(track, tier)
	if reward == nil then
		return nil, "tier"
	end
	if Pass.tier(s.xp) < tier then
		return nil, "locked"
	end
	if track == "premium" and not s.premium then
		return nil, "premium"
	end
	local claimed = if track == "premium" then s.paid else s.free
	if claimed[tier] then
		return nil, "claimed"
	end
	claimed[tier] = true
	local grant: Grant = { kind = "pass", items = {}, stars = 0 }
	if reward.stars then
		p.stars += reward.stars
		grant.stars += reward.stars
	end
	local items: { string } = reward.items or {}
	for _, id in items do
		if p.owned[id] then
			p.stars += Profile.DUPLICATE_STARS
			grant.stars += Profile.DUPLICATE_STARS
		else
			p.owned[id] = true
			table.insert(grant.items, id)
		end
	end
	for _ = 1, reward.crates or 0 do
		local item = Profile.openCrate(p, roll)
		if item then
			table.insert(grant.items, item.id)
		else
			p.stars += Profile.DUPLICATE_STARS
			grant.stars += Profile.DUPLICATE_STARS
		end
	end
	return grant
end

-- What the client shows of the pass: progress, tiers claimed, today's and
-- this week's missions with their progress.
function Profile.passView(p: Record, now: number): { [string]: any }?
	local s = Profile.passOf(p, now)
	if s == nil then
		return nil
	end
	local _, _, ends = Pass.season(now)
	local function list(claimed: { [number]: boolean }): { number }
		local out = {}
		for t in claimed do
			table.insert(out, t)
		end
		table.sort(out)
		return out
	end
	local function missions(ms: { Pass.Mission }, progress: { [string]: number }): { { [string]: any } }
		local out = {}
		for _, m in ms do
			table.insert(out, { id = m.id, text = m.text, goal = m.goal, xp = m.xp, progress = progress[m.id] or 0 })
		end
		return out
	end
	return {
		season = s.season,
		endsAt = ends,
		xp = s.xp,
		premium = s.premium,
		free = list(s.free),
		paid = list(s.paid),
		daily = missions(Pass.dailyMissions(now), s.daily),
		weekly = missions(Pass.weeklyMissions(now), s.weekly),
		dailyEndsAt = (Pass.day(now) + 1) * 86400,
	}
end

-- Spends one saved in-match boost credit (Profile.BOOSTS); false when there's none.
function Profile.spendBoost(p: Record, key: string): boolean
	local n = p.boosts[key] or 0
	if not Profile.BOOSTS[key] or n <= 0 then
		return false
	end
	if n > 1 then
		p.boosts[key] = n - 1
	else
		p.boosts[key] = nil :: any
	end
	return true
end

-- Puts a spent boost credit back (applying it failed).
function Profile.refundBoost(p: Record, key: string)
	if Profile.BOOSTS[key] then
		p.boosts[key] = (p.boosts[key] or 0) + 1
	end
end

-- Spends one saved Takeover; false when there's none.
function Profile.spendTakeover(p: Record): boolean
	if p.takeovers <= 0 then
		return false
	end
	p.takeovers -= 1
	return true
end

return Profile
