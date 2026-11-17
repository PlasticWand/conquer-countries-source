-- The RoFront-level pass's store: skins, the Flag Shop rotation, crates,
-- receipts, the Arsenal and the saved record.
return function(t)
	local Skins = t.require("Store.Skins")
	local Catalog = t.require("Store.Catalog")
	local FlagShop = t.require("Store.FlagShop")
	local FlagList = t.require("Store.FlagList") :: { { id: string, set: string } }
	local Profile = t.require("Store.Profile")

	local function rolls(list: { number }): () -> number
		local i = 0
		return function()
			i += 1
			return list[(i - 1) % #list + 1]
		end
	end

	t.test("skins: every pattern is a rectangle and becomes a renderer mask", function()
		for _, s in Skins.LIST do
			local w = #s.rows[1]
			for _, row in s.rows do
				t.eq(#row, w, s.id .. " rows are all as wide")
			end
			local m = Skins.mask(s.id) :: any
			t.eq(m.width, w)
			t.eq(m.height, #s.rows)
			t.ok(buffer.len(m.bytes) >= math.ceil(w * #s.rows / 8))
		end
		local m = Skins.mask("s_checker") :: any
		-- "##.." first row: bits 0 and 1 set.
		t.eq(bit32.band(buffer.readu8(m.bytes, 0), 0x0f), 0x03)
	end)

	t.test("catalog: skins and flags with rarities; crates never give shop-only flags", function()
		local skins, flags, own = 0, 0, 0
		for _, c in Catalog.cosmetics() do
			t.ok(table.find(Catalog.RARITIES, c.rarity) ~= nil, c.id)
			if c.kind == "skin" then
				skins += 1
			else
				flags += 1
				if c.set ~= "country" then
					own += 1
					t.eq(Catalog.crateable(c), false, c.id .. " is sold in the Flag Shop only")
				end
			end
		end
		t.ok(skins >= 12 and flags >= 200 and own >= 12, `{skins} skins, {flags} flags, {own} own`)
		for _, p in Catalog.PRODUCTS do
			t.ok(p.price > 0 and #p.name <= 50, p.key)
		end
	end)

	t.test("Flag Shop: the same offers everywhere on a UTC day, new ones the next day", function()
		local day = 1792195200 + 3 * 86400 + 5000 -- Halloween 2026, mid-day
		local a = FlagShop.offers(day)
		local b = FlagShop.offers(day + 3600)
		t.eq(#a.daily, FlagShop.DAILY_COUNT)
		for i = 1, #a.daily do
			t.eq(a.daily[i], b.daily[i], "same day, same flags")
		end
		t.ok(a.event ~= nil and #a.event.flags >= 6, "Halloween is on")
		t.eq(a.nextDailyAt % 86400, 0, "the rotation turns at midnight UTC")
		local seen = {}
		for _, id in a.daily do
			t.ok(not seen[id], "no flag twice")
			seen[id] = true
		end
		-- (20 days on: 30 would be Thanksgiving's opening day.)
		local later = FlagShop.offers(day + 20 * 86400)
		t.eq(later.event, nil, "the event ends")
		t.ok(FlagShop.onSale(day, a.daily[1]))
	end)

	t.test("Thanksgiving: a week before the 4th Thursday of November to the Tuesday after, every year", function()
		local day = FlagShop._dayNumber
		-- US Thanksgiving: 2026-11-26, 2027-11-25, 2028-11-23.
		for _, c in { { 2026, 26 }, { 2027, 25 }, { 2028, 23 } } do
			local e = FlagShop.thanksgiving(c[1])
			t.eq(e.startsAt, day(c[1], 11, c[2] - 7) * 86400, `{c[1]} starts a week before`)
			t.eq(e.endsAt, day(c[1], 11, c[2] + 6) * 86400, `{c[1]} ends after the Tuesday`)
		end
		t.eq(day(1970, 1, 1), 0)
		t.eq(day(2026, 11, 11) * 86400, 1794355200, "today")
		local tg = 0
		for _, f in FlagList do
			if f.set == "thanksgiving" then
				tg += 1
			end
		end
		t.eq(tg, 6, "six Thanksgiving flags")
		local during = FlagShop.offers(day(2026, 11, 26) * 86400 + 3600)
		t.ok(during.event ~= nil and during.event.set == nil and during.event.name == "Thanksgiving" and #during.event.flags == 6, "on Thanksgiving Day")
		t.eq((during.event :: any).stamp, "stamp_thanksgiving")
		t.eq(FlagShop.offers(day(2026, 11, 18) * 86400 + 3600).event, nil, "not yet on the 18th")
		t.ok(FlagShop.offers(day(2026, 12, 1) * 86400 + 80000).event ~= nil, "still on Tuesday Dec 1")
		t.eq(FlagShop.offers(day(2026, 12, 2) * 86400 + 60).event, nil, "gone on Dec 2")
		t.ok(FlagShop.offers(day(2027, 11, 20) * 86400).event ~= nil, "back next year")
		t.eq(Catalog.crateable(Catalog.get("o_horn_of_plenty") :: any), false, "Flag Shop only")
	end)

	t.test("Today's flags: every daily flag once a cycle, never two days running", function()
		local pool = 0
		for _, f in FlagList do
			if f.set == "daily" then
				pool += 1
			end
		end
		local days = pool // FlagShop.DAILY_COUNT
		t.ok(days >= 3, "a pool of at least three days")
		local start = (1792195200 // 86400) // days * days -- the first day of a cycle
		for c = 0, 2 do
			local seen, count = {}, 0
			for d = 0, days - 1 do
				for _, id in FlagShop.daily(start + c * days + d) do
					t.eq(seen[id], nil, "once a cycle")
					seen[id] = true
					count += 1
				end
			end
			t.eq(count, days * FlagShop.DAILY_COUNT)
		end
		for d = start, start + 4 * days do
			local today = {}
			for _, id in FlagShop.daily(d) do
				today[id] = true
			end
			for _, id in FlagShop.daily(d + 1) do
				t.eq(today[id], nil, "not two days running")
			end
		end
	end)

	t.test("crates: odds by rarity, never an item you own, stars when complete", function()
		local p = Profile.new()
		local first = Profile.openCrate(p, rolls({ 0.99, 0 })) :: any
		t.eq(first.rarity, "legendary", "a roll of 99 lands in the top 3%")
		local common = Profile.openCrate(p, rolls({ 0.1, 0 })) :: any
		t.eq(common.rarity, "common")
		t.ok(p.owned[first.id] and p.owned[common.id])
		for _ = 1, 400 do
			Profile.openCrate(p, rolls({ 0.5, 0.3 }))
		end
		t.eq(Profile.openCrate(p, rolls({ 0.5 })), nil, "nothing left to give")
		local g = Profile.grant(p, "crate1", "r1", rolls({ 0.5 }), 0) :: any
		t.eq(g.stars, Profile.DUPLICATE_STARS, "a complete collection gets stars instead")
	end)

	t.test("receipts: a purchase is granted once; first crate is used up", function()
		local p = Profile.new()
		t.eq(Profile.view(p, true, false).cratePrice, 15, "first crate discount")
		local g = Profile.grant(p, "crateFirst", "abc", rolls({ 0.2, 0.4 }), 0) :: any
		t.eq(#g.items, 1)
		t.eq(Profile.grant(p, "crateFirst", "abc", rolls({ 0.2 }), 0), nil, "the same receipt again grants nothing")
		t.eq(Profile.view(p, true, false).cratePrice, 49)
		local three = Profile.grant(p, "crate3", "def", rolls({ 0.2, 0.4, 0.6, 0.8 }), 0) :: any
		t.eq(#three.items, 3)
		t.eq(Profile.grant(p, "nonsense", "ghi", rolls({ 0.1 }), 0), nil, "unknown products stay unclaimed")
		local mega = Profile.grant(p, "unlockMega", "jkl", rolls({ 0.1 }), 0) :: any
		t.eq(mega.items[1], "w_mega")
		t.eq(Profile.weapons(p).megaNuke, true)
	end)

	t.test("Flag Shop purchase: the chosen flag, else another of that tier on sale, else stars", function()
		local now = 1792195200 + 86400
		local offers = FlagShop.offers(now)
		local p = Profile.new()
		local pick = offers.daily[1]
		t.ok(Profile.chooseFlag(p, pick, now))
		local tier = Catalog.flagProduct((Catalog.get(pick) :: any).rarity)
		local g = Profile.grant(p, tier, "f1", rolls({ 0.1 }), now) :: any
		t.eq(g.items[1], pick)
		t.eq(Profile.chooseFlag(p, pick, now), false, "owned now")
		t.eq(Profile.chooseFlag(p, "f_fr", now), false, "country flags come from crates")
	end)

	t.test("stars per match and the Arsenal's star prices", function()
		t.eq(Profile.starsFor({ won = false, placement = 50, players = 100, minutes = 0.5 }, false), 0, "under a minute pays nothing")
		local solo = Profile.starsFor({ won = true, placement = 1, players = 100, minutes = 20, difficulty = "Hard" }, false)
		t.eq(solo, math.floor((20 * 60 + 400 + 1000) * 1.5))
		t.eq(Profile.starsFor({ won = true, placement = 1, players = 100, minutes = 20, difficulty = "Hard" }, true), solo * 2, "2x Stars")
		local p = Profile.new()
		t.eq(select(2, Profile.unlockWithStars(p, "w_reinforce")), "stars")
		p.stars = 35000
		t.ok(Profile.unlockWithStars(p, "w_reinforce"))
		t.eq(p.stars, 5000, "30,000 stars (doubled 2026-11-16)")
		t.eq(select(2, Profile.unlockWithStars(p, "w_reinforce")), "owned")
		t.eq(select(2, Profile.unlockWithStars(p, "b_double")), "unknown", "2x Stars is Robux only")
	end)

	t.test("a receipt is confirmed to Roblox only after it is saved", function()
		local roll = function(): number
			return 0.5
		end
		-- A session that can save: confirmed on the first call, one save.
		local p = Profile.new()
		local saves = 0
		local function save(): boolean
			saves += 1
			return true
		end
		local confirm, grant = Profile.processReceipt(p, true, "takeover", "r1", roll, 0, save)
		t.eq(confirm, true)
		t.ok(grant ~= nil, "granted")
		t.eq(p.takeovers, 1)
		t.eq(saves, 1)
		-- The save fails: not confirmed; asked again, it is saved and confirmed
		-- without a second grant.
		local q = Profile.new()
		local works = false
		local function flaky(): boolean
			return works
		end
		confirm, grant = Profile.processReceipt(q, true, "takeover", "r2", roll, 0, flaky)
		t.eq(confirm, false, "not confirmed while unsaved")
		t.ok(grant ~= nil)
		works = true
		confirm, grant = Profile.processReceipt(q, true, "takeover", "r2", roll, 0, flaky)
		t.eq(confirm, true)
		t.eq(grant, nil, "no second grant")
		t.eq(q.takeovers, 1)
		-- A session that can't save (its profile failed to load): never
		-- confirmed, however often Roblox asks (audit F8: the second ask used
		-- to confirm, and the purchase was lost on leaving).
		local u = Profile.new()
		local asked = 0
		local function never(): boolean
			asked += 1
			return true
		end
		confirm, grant = Profile.processReceipt(u, false, "takeover", "r3", roll, 0, never)
		t.eq(confirm, false)
		t.ok(grant ~= nil, "they still get it for this session")
		confirm, grant = Profile.processReceipt(u, false, "takeover", "r3", roll, 0, never)
		t.eq(confirm, false, "asked again: still not confirmed")
		t.eq(grant, nil)
		t.eq(asked, 0, "an unsaved session never tries to save")
		t.eq(u.takeovers, 1)
		-- An unknown product stays open.
		t.eq(select(1, Profile.processReceipt(Profile.new(), true, "nope", "r4", roll, 0, save)), false)
	end)

	t.test("the saved record round-trips and rejects junk", function()
		local p = Profile.new()
		p.stars = 1234
		p.owned.s_waves = true
		Profile.equip(p, "skin", "s_waves")
		table.insert(p.receipts, "r9")
		local back = Profile.decode(Profile.encode(p)) :: any
		t.eq(back.stars, 1234)
		t.eq(back.equipped.skin, "s_waves")
		t.eq(back.receipts[1], "r9")
		t.eq(Profile.equip(back, "skin", "s_plaid"), false, "can't wear what you don't own")
		t.eq(select(2, Profile.decode({ schema = 99 })), "newerSchema")
		t.eq(select(2, Profile.decode({ schema = 1, stars = -1, matches = 0, wins = 0, owned = {}, receipts = {} })), "corrupt")
	end)

	t.test("the tutorial: its state, tips seen and stars, saved and read back", function()
		local p = Profile.new()
		t.eq(Profile.view(p, true, false).tutorial, nil)
		t.ok(Profile.setTutorial(p, "started"))
		t.ok(not Profile.setTutorial(p, "bogus"))
		t.ok(Profile.setTutorial(p, "done"))
		t.ok(not Profile.setTutorial(p, "started"), "a finished tutorial never starts again")
		t.ok(Profile.tipSeen(p, "expand"))
		t.ok(not Profile.tipSeen(p, "expand"))
		t.ok(not Profile.tipSeen(p, string.rep("x", 40)))
		t.eq(Profile.payTutorial(p, 1000), 1000)
		t.eq(Profile.payTutorial(p, 1000), 0, "once per player")
		t.eq(p.stars, 1000)
		local back = Profile.decode(Profile.encode(p)) :: any
		t.eq(back.tutorial, "done")
		t.ok(back.tipsSeen.expand)
		t.ok(back.tutorialPaid)
		t.eq(Profile.view(back, true, false).tipsSeen[1], "expand")
		-- records from before the tutorial read as never begun
		local old = Profile.decode({ schema = 1, stars = 5, matches = 2, wins = 0, owned = {}, receipts = {}, tutorial = "weird" }) :: any
		t.eq(old.tutorial, nil)
		t.ok(not old.tutorialPaid)
	end)

	t.test("star packs and daily deals: the smallest pack that covers, one deal a day, grants", function()
		t.eq(Catalog.starPackFor(0), nil, "nothing short")
		t.eq((Catalog.starPackFor(5000) :: any).key, "stars10k")
		t.eq((Catalog.starPackFor(32000) :: any).key, "stars35k")
		t.eq((Catalog.starPackFor(300000) :: any).key, "stars300k")
		t.eq(Catalog.starPackFor(300001), nil, "past the biggest pack: unlock instead")
		for _, pack in Catalog.STAR_PACKS do
			t.ok(Catalog.product(pack.key) ~= nil, pack.key .. " is a product")
		end
		-- every unlock has its deal product at 40% off
		for _, w in Catalog.ARSENAL do
			local deal = Catalog.dealProduct(w)
			if deal then
				local regular = Catalog.product(w.product :: string) :: any
				local p = Catalog.product(deal) :: any
				t.ok(p ~= nil, deal .. " is a product")
				t.eq(p.price, math.floor(regular.price * 0.6 + 0.5), deal .. " is 40% off")
				t.eq((Catalog.dealWeapon(deal) :: any).id, w.id)
			end
		end
		-- the same deal for a player all day, never one they own, others differ
		local owned = { w_reinforce = true }
		local a = Catalog.dealOf(1642763318, 20408, owned) :: any
		t.eq((Catalog.dealOf(1642763318, 20408, owned) :: any).id, a.id, "stable for the day")
		t.ok(a.id ~= "w_reinforce", "never owned")
		local seen = {}
		for day = 20408, 20430 do
			seen[(Catalog.dealOf(1642763318, day, owned) :: any).id] = true
		end
		local n = 0
		for _ in seen do
			n += 1
		end
		t.ok(n >= 4, `deals change from day to day ({n} different)`)
		local all = {}
		for _, w in Catalog.ARSENAL do
			all[w.id] = true
		end
		t.eq(Catalog.dealOf(1, 1, all), nil, "nothing left to offer")
		-- receipts: a pack's stars, a deal's weapon (stars if owned meanwhile)
		local p = Profile.new()
		local before = p.stars
		local g = Profile.grant(p, "stars35k", "r1", function() return 0 end, 0) :: any
		t.eq(p.stars - before, 35000)
		t.eq(g.stars, 35000)
		g = Profile.grant(p, "dealArtillery", "r2", function() return 0 end, 0) :: any
		t.ok(p.owned.w_artillery == true, "the deal's weapon")
		t.eq(g.items[1], "w_artillery")
		local stars = p.stars
		g = Profile.grant(p, "dealArtillery", "r3", function() return 0 end, 0) :: any
		t.ok(p.stars > stars, "owned meanwhile: stars instead")
		t.eq(Profile.grant(p, "dealArtillery", "r3", function() return 0 end, 0), nil, "a receipt only once")
		-- one deal a day: buying it records the day, and no second deal shows
		local q = Profile.new()
		local now = 20408 * 86400 + 3600
		t.ok(Catalog.todaysDeal(7, now, q.owned, nil) ~= nil, "a deal before buying")
		local todays = Catalog.todaysDeal(7, now, q.owned, nil) :: any
		Profile.grant(q, Catalog.dealProduct(todays) :: string, "d1", function() return 0 end, now)
		t.eq(q.dealDay, 20408)
		local v = Profile.view(q, true, false, false, now) :: any
		t.eq(v.dealDay, 20408)
		t.eq(Catalog.todaysDeal(7, now, q.owned, v.dealDay), nil, "no second deal today")
		t.ok(Catalog.todaysDeal(7, now + 86400, q.owned, v.dealDay) ~= nil, "a new deal tomorrow")
		local back = Profile.decode(Profile.encode(q)) :: any
		t.eq(back.dealDay, 20408, "saved")
	end)

	t.test("the free crate: once, after the first match, normal crate, saved", function()
		local p = Profile.new()
		local roll = function() return 0 end
		t.eq((Profile.view(p, true, false, false, 0) :: any).freeCrate, nil, "not before a match (the tutorial)")
		local item, why = Profile.openFreeCrate(p, roll)
		t.eq(item, nil)
		t.eq(why, "later")
		p.matches = 1
		t.eq((Profile.view(p, true, false, false, 0) :: any).freeCrate, true, "waiting after the first match")
		local stars = p.stars
		item, why = Profile.openFreeCrate(p, roll)
		t.ok(item ~= nil and p.owned[(item :: any).id] == true, "an item, owned")
		t.eq(p.stars, stars, "costs nothing")
		t.ok(not p.firstCrateUsed, "the first bought crate's discount stays")
		t.eq((Profile.view(p, true, false, false, 0) :: any).freeCrate, nil, "gone once opened")
		item, why = Profile.openFreeCrate(p, roll)
		t.eq(why, "used", "only once")
		local back = Profile.decode(Profile.encode(p)) :: any
		t.eq(back.freeCrateUsed, true, "saved")
		-- a returning player (old record, no field) gets it too
		local old = Profile.encode(Profile.new()) :: any
		old.matches = 30
		local q = Profile.decode(old) :: any
		t.ok(Profile.freeCrateReady(q), "returning players get one")
	end)
end
