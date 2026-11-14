-- The starter pack and Conquest General (docs/design/ARSENAL_V2.md;
-- RoWorld's rules): Store/Profile.
return function(t)
	local Profile = t.require("Store.Profile")
	local Catalog = t.require("Store.Catalog")
	local function roll(): number
		return 0
	end

	t.test("the starter pack: for players who've played and never paid, 48 h from first seen", function()
		local p = Profile.new()
		t.eq(Profile.starterState(p, 1000), nil, "not before a first match")
		p.matches = 1
		t.eq(Profile.starterState(p, 1000), "ready", "offered, clock not started")
		t.ok(Profile.starterSeen(p, 1000), "its clock starts")
		t.eq(Profile.starterSeen(p, 2000), false, "once")
		local state, left = Profile.starterState(p, 1000 + 3600)
		t.eq(state, "active")
		t.eq(left, Catalog.STARTER.durationS - 3600)
		t.eq(Profile.starterState(p, 1000 + Catalog.STARTER.durationS + 1), nil, "then gone for good")
		local paid = Profile.new()
		paid.matches = 3
		Profile.grant(paid, "crate1", "r1", roll, 0)
		t.eq(Profile.starterState(paid, 0), nil, "not for someone who paid")
		local back = Profile.decode(Profile.encode(p)) :: any
		t.eq(back.starter.ends, 1000 + Catalog.STARTER.durationS, "the deadline is saved")
	end)

	t.test("buying it unlocks the three items (stars for one already owned) and ends the offer", function()
		local p = Profile.new()
		p.matches = 1
		p.owned.w_mega = true
		Profile.starterSeen(p, 100)
		local grant = Profile.grant(p, "starterPack", "r9", roll, 200) :: any
		t.ok(p.owned.w_scatter and p.owned.b_double, "Scattershot and 2x Stars")
		t.eq(grant.stars, Profile.STARTER_DUPLICATE_STARS, "stars for the Mega Nuke owned")
		t.eq(Profile.starterState(p, 300), nil, "bought: gone")
		t.ok(Profile.view(p, true, false).doubleStars, "2x Stars from the pack counts")
	end)

	t.test("a General gets half again on every match, and one crate a day", function()
		local p = Profile.new()
		local result = { won = false, placement = 5, players = 10, minutes = 10, difficulty = "Medium" }
		local plain = Profile.starsFor(result, false)
		local q = Profile.new()
		t.eq(Profile.applyMatch(q, result, false, true), plain + math.floor(plain * 0.5))
		t.ok(Profile.generalDue(p, 20000), "today's crate")
		t.eq(Profile.generalDue(p, 20000), false, "once a day")
		t.ok(Profile.generalDue(p, 20001), "and tomorrow's")
	end)

	t.test("the General skin: the month's, never from a crate", function()
		local skin = Catalog.generalSkin(os.time({ year = 2026, month = 11, day = 20, hour = 12 }))
		t.eq(skin, "g_rank")
		t.eq(Catalog.generalSkin(os.time({ year = 2027, month = 3, day = 1, hour = 12 })), "g_shield", "March 2027's")
		t.eq(Catalog.generalSkin(os.time({ year = 2028, month = 3, day = 1, hour = 12 })), "g_sight", "the latest before a month without its own")
		-- A year lined up: twelve different skins, all General-only.
		local seen = {}
		for _, s in Catalog.SUBSCRIPTION.skins do
			t.ok(Catalog.get(s.skin) ~= nil, s.skin)
			t.eq(seen[s.skin], nil, "once each")
			seen[s.skin] = true
			t.eq(Catalog.crateable(Catalog.get(s.skin) :: any), false, "never from a crate")
		end
		t.eq(#Catalog.SUBSCRIPTION.skins, 12)
		local nov = os.time({ year = 2026, month = 11, day = 20, hour = 12 })
		t.ok(Catalog.generalReleased("g_rank", nov), "this month's is out")
		t.eq(Catalog.generalReleased("g_eagle", nov), false, "next month's isn't")
		local c = Catalog.get("g_rank") :: any
		t.eq(c.kind, "skin")
		t.eq(Catalog.crateable(c), false, "subscribers only")
		t.eq(Catalog.crateable(Catalog.get("s_stripes") :: any), true)
	end)

	-- The launch event (Bruno, 2026-11-13): the starter pack free for 7 days.
	t.test("the launch gift: everyone may claim the starter pack once while the event runs", function()
		local saved = Catalog.LAUNCH_GIFT
		local starts, days = 10000, 7 * 24 * 3600
		Catalog.LAUNCH_GIFT = table.freeze({ startsAt = starts, durationS = days }) :: any
		local ok, err = pcall(function()
			local fresh = Profile.new()
			t.eq(Profile.giftState(fresh, starts - 1), nil, "not before it opens")
			local state, left = Profile.giftState(fresh, starts + 60)
			t.eq(state, "claimable", "a brand-new player (no match needed)")
			t.eq(left, days - 60, "counts down to the event's end")
			t.eq(Profile.giftState(fresh, starts + days), nil, "over after 7 days")
			t.eq(Profile.claimGift(fresh, starts + days), nil, "nothing to claim after")

			-- While it's claimable the paid offer is hidden; claiming ends it.
			local p = Profile.new()
			p.matches = 2
			p.owned.w_mega = true
			t.eq(Profile.starterState(p, starts + 5), nil, "never sold while it's free")
			local grant = Profile.claimGift(p, starts + 5) :: any
			t.ok(grant ~= nil, "claimed")
			t.eq(#grant.items, 2, "only the items not owned")
			t.eq(grant.stars, 0, "no stars for the owned one: it's free")
			t.ok(p.owned.w_scatter and p.owned.b_double, "Scattershot and 2x Stars")
			t.eq(Profile.claimGift(p, starts + 6), nil, "once")
			t.eq(Profile.giftState(p, starts + 6), nil, "claimed: gone")
			t.eq(Profile.starterState(p, starts + days + 10), nil, "and no paid offer after the event")
			local back = Profile.decode(Profile.encode(p)) :: any
			t.eq(back.giftClaimed, true, "the claim is saved")
			t.eq(Profile.view(p, true, false, false, starts + 6).gift, nil)

			local all = Profile.new()
			for _, id in Catalog.STARTER.items do
				all.owned[id] = true
			end
			t.eq(Profile.giftState(all, starts + 5), nil, "not for someone who owns it all")
		end)
		Catalog.LAUNCH_GIFT = saved
		if not ok then
			error(err, 0)
		end
	end)

	t.test("the launch gift is off by default", function()
		t.eq(Profile.giftState(Profile.new(), os.time()), if Catalog.LAUNCH_GIFT.startsAt > 0 then "claimable" else nil)
	end)
end
