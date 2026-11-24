-- The Campaign Pass (Store/Pass, Profile.passOf/passMatch/passClaim;
-- Bruno, 2026-11-23).
return function(t)
	local Pass = t.require("Store.Pass")
	local Profile = t.require("Store.Profile")
	local Catalog = t.require("Store.Catalog")

	local DAY = 86400
	local T0 = Pass.EPOCH + 2 * DAY + 3600 -- season 1, its third day
	local function roll(): number
		return 0.5
	end
	local function match(minutes: number, won: boolean, placement: number?, public: boolean?): any
		return { won = won, placement = placement or 5, players = 20, minutes = minutes, difficulty = if public then nil else "Medium" }
	end

	t.test("seasons are 30 days from the epoch; none before it", function()
		t.eq(Pass.season(Pass.EPOCH - 1), nil)
		local n, starts, ends = Pass.season(T0)
		t.eq(n, 1)
		t.eq(starts, Pass.EPOCH)
		t.eq(ends, Pass.EPOCH + 30 * DAY)
		t.eq((Pass.season(Pass.EPOCH + 30 * DAY)), 2, "the next starts at once")
	end)

	t.test("tiers every 1,000 XP, capped at 30", function()
		t.eq(Pass.tier(0), 0)
		t.eq(Pass.tier(999), 0)
		t.eq(Pass.tier(1000), 1)
		local tier, into = Pass.tier(2500)
		t.eq(tier, 2)
		t.eq(into, 500)
		t.eq(Pass.tier(1e9), 30)
	end)

	t.test("a match pays 20 XP a minute, plus a win and the top tenth", function()
		t.eq(Pass.xpForMatch({ minutes = 0.5, won = true, top = true, public = false }), 0, "under a minute: nothing")
		t.eq(Pass.xpForMatch({ minutes = 10, won = false, top = false, public = false }), 200)
		t.eq(Pass.xpForMatch({ minutes = 10, won = true, top = true, public = false }), 550)
		t.eq(Pass.xpForMatch({ minutes = 90, won = false, top = false, public = false }), 800, "40 minutes at most")
	end)

	t.test("three daily and three weekly missions, the same for everyone, no repeats", function()
		local a, b = Pass.dailyMissions(T0), Pass.dailyMissions(T0 + 60)
		t.eq(#a, 3)
		for i = 1, 3 do
			t.eq(a[i].id, b[i].id, "stable within the day")
		end
		t.ok(a[1].id ~= a[2].id and a[2].id ~= a[3].id and a[1].id ~= a[3].id, "no repeats")
		t.eq(#Pass.weeklyMissions(T0), 3)
	end)

	t.test("matches add XP and complete missions once; the day resets them", function()
		local p = Profile.new()
		local gained = Profile.passMatch(p, match(10, false), T0)
		t.ok(gained >= 200, "at least the match's own XP")
		-- Play enough to finish every daily mission whatever was dealt.
		for _ = 1, 4 do
			Profile.passMatch(p, match(10, true, 1, true), T0)
		end
		local s = Profile.passOf(p, T0) :: any
		for _, m in Pass.dailyMissions(T0) do
			t.eq(s.daily[m.id], m.goal, m.id .. " done")
		end
		local before = s.xp
		local again = Profile.passMatch(p, match(10, false), T0)
		t.eq(again, 200, "done missions don't pay twice")
		t.eq(s.xp, before + 200)
		Profile.passOf(p, T0 + DAY)
		t.eq(next(s.daily), nil, "a new day starts the dailies over")
	end)

	t.test("claims: reached, once, premium only when bought", function()
		local p = Profile.new()
		t.eq(select(2, Profile.passClaim(p, "free", 1, roll, T0)), "locked")
		local s = Profile.passOf(p, T0) :: any
		s.xp = 5000
		local g = Profile.passClaim(p, "free", 1, roll, T0) :: any
		t.eq(g.stars, 1000)
		t.eq(p.stars, 1000)
		t.eq(select(2, Profile.passClaim(p, "free", 1, roll, T0)), "claimed")
		t.eq(select(2, Profile.passClaim(p, "premium", 5, roll, T0)), "premium", "premium not bought")
		Profile.grant(p, "campaignPass", "pass1", roll, T0)
		t.ok(s.premium)
		local first = Profile.passClaim(p, "premium", 1, roll, T0) :: any
		t.eq(first.items[1], Pass.ITEMS.recruit, "a title")
		t.eq(first.stars, 3000, "and stars")
		local flag = Profile.passClaim(p, "premium", 5, roll, T0) :: any
		t.eq(flag.items[1], Pass.ITEMS.flag1, "the exclusive flag")
		t.ok(p.owned[Pass.ITEMS.flag1])
		local crate = Profile.passClaim(p, "free", 5, roll, T0) :: any
		t.eq(#crate.items, 1, "a crate's item")
		t.eq(select(2, Profile.passClaim(p, "free", 31, roll, T0)), "tier")
	end)

	t.test("a new season starts the pass over; the pass is saved", function()
		local p = Profile.new()
		Profile.passMatch(p, match(10, true), T0)
		Profile.grant(p, "campaignPass", "pass1", roll, T0)
		local back = Profile.decode(Profile.encode(p)) :: any
		t.eq(back.pass.xp, (p.pass :: any).xp, "saved XP")
		t.ok(back.pass.premium, "saved premium")
		local view = Profile.view(back, true, false, false, T0) :: any
		t.eq(view.pass.season, 1)
		t.eq(#view.pass.daily, 3)
		local nextSeason = Pass.EPOCH + 31 * DAY
		local s2 = Profile.passOf(back, nextSeason) :: any
		t.eq(s2.season, 2)
		t.eq(s2.xp, 0)
		t.eq(s2.premium, false, "premium is per season")
	end)

	t.test("the pass's exclusive items exist and never come from crates", function()
		for _, id in Pass.ITEMS do
			local c = Catalog.get(id)
			t.ok(c ~= nil, id .. " exists")
			t.eq(Catalog.crateable(c :: any), false, id .. " not in crates")
		end
		t.eq((Catalog.product("campaignPass") :: any).price, 199)
		-- every reward's items exist
		for _, track in { Pass.FREE, Pass.PREMIUM } do
			for tier, r in track do
				for _, id in r.items or {} do
					t.ok(Catalog.get(id) ~= nil, `tier {tier}: {id}`)
				end
			end
		end
		t.eq(Pass.name(1), "OPERATION IRON ROAD")
	end)
end
