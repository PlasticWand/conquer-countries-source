-- Public lobbies across servers (PublicLobbies rules, LobbyStore.localstore):
-- seats, the schedule, demand, decoding and the store's take/release/expiry.
return function(t)
	local P = t.require("PublicLobbies")
	local LobbyStore = t.require("LobbyStore")

	local function lobby(id: string, kind: string, starts: number, players: number?, max: number?): any
		return {
			id = id,
			kind = kind,
			config = { gameMap = "World", gameMode = "Free For All", maxPlayers = max or 10 },
			max = max or 10,
			starts = starts,
			created = starts - 90,
			players = players or 0,
			status = "open",
		}
	end

	t.test("a free-for-all join takes World's seats too; World and team only their own", function()
		t.eq(table.concat(P.takesFrom("ffa"), ","), "ffa,world")
		t.eq(table.concat(P.takesFrom("world"), ","), "world")
		t.eq(table.concat(P.takesFrom("team"), ","), "team")
		t.eq(#P.kinds(true), 3)
		t.eq(#P.kinds(false), 2)
	end)

	t.test("seats: fit, taken once per user, given back only from the ledger", function()
		local now = 1000
		local l = lobby("a", "ffa", now + 60, 8, 10)
		local spec = P.takeSpec("ffa", 2, { "1", "2" }, now)
		t.ok(P.fits(l, spec), "two fit in 8/10")
		t.ok(not P.fits(l, P.takeSpec("ffa", 3, { "1", "2", "3" }, now)), "three don't")
		t.ok(not P.fits(l, P.takeSpec("team", 1, { "1" }, now)), "wrong kind")
		t.ok(not P.fits(lobby("b", "ffa", now + 5), spec), "closes JOIN_CLOSE_S before the start")
		t.ok(not P.fits(lobby("c", "ffa", now + P.MAX_AHEAD_S + 1), spec), "a start too far ahead is a wrong clock")
		local s = P.seated(l, spec)
		t.eq(s.players, 10)
		t.eq(s.seats["1"], now)
		t.eq(l.players, 8, "the original is unchanged")
		local r, n = P.released(s, { "2", "9" })
		t.eq(n, 1)
		t.eq(r.players, 9)
		t.eq(r.seats["2"], nil)
		local started = table.clone(s)
		started.status = "started"
		local _, none = P.released(started, { "1" })
		t.eq(none, 0, "no seats back once started")
	end)

	t.test("lapsed seats: left after arriving, or never arrived in ARRIVE_S", function()
		local l = lobby("a", "ffa", 2000)
		l.seats = { ["1"] = 1000, ["2"] = 1000, ["3"] = 1000, ["4"] = 1025 }
		local out = P.lapsedSeats(l, { ["1"] = true }, { ["2"] = true }, 1000 + P.ARRIVE_S)
		t.eq(table.concat(out, ","), "2,3")
	end)

	t.test("the schedule keeps one joinable lobby per kind, within the open window", function()
		local now = 5000
		local starts = P.missingStarts({}, now, "ffa", 1)
		t.eq(#starts, 1)
		t.eq(starts[1], now + P.MIN_LEAD_S)
		-- one far enough out: nothing to add
		t.eq(#P.missingStarts({ lobby("a", "ffa", now + 60) }, now, "ffa", 1), 0)
		-- the only one is about to start: the next follows an interval after it
		local next = P.missingStarts({ lobby("a", "ffa", now + 10) }, now, "ffa", 1)
		t.eq(next[1], now + 10 + P.LOBBY_INTERVAL_S)
		-- a full one doesn't count
		t.eq(#P.missingStarts({ lobby("a", "ffa", now + 60, 10, 10) }, now, "ffa", 1), 1)
		-- other kinds don't count
		t.eq(#P.missingStarts({ lobby("a", "team", now + 60) }, now, "ffa", 1), 1)
	end)

	t.test("demand opens more lobbies, closer together, up to MAX_OPEN_PER_KIND", function()
		local now = 5000
		local busy = {}
		-- 12 full lobbies in two minutes: a lobby's worth of joins every 10 s
		for i = 1, 12 do
			local l = lobby(`d{i}`, "ffa", now - 9 * i, 10, 10)
			l.created = now - 9 * i
			table.insert(busy, l)
		end
		local d = P.demand(busy, now, "ffa")
		t.ok(d.rate > 0.4, `rate {d.rate}`)
		local starts = P.missingStarts({}, now, "ffa", 1, d)
		t.ok(#starts > 1 and #starts <= P.MAX_OPEN_PER_KIND, `{#starts} lobbies`)
		for i = 2, #starts do
			local gap = starts[i] - starts[i - 1]
			t.ok(gap >= P.MIN_INTERVAL_S and gap <= P.LOBBY_INTERVAL_S, `gap {gap}`)
			t.ok(starts[i] <= now + P.LOBBY_OPEN_S, "within the open window")
		end
	end)

	t.test("World's lobby staggers away from a free-for-all start", function()
		local now = 5000
		local starts = P.missingStarts({}, now, "world", 1, nil, { now + P.MIN_LEAD_S + 3 })
		t.eq(starts[1], now + P.MIN_LEAD_S + 3 + P.WORLD_STAGGER_S)
	end)

	t.test("decode keeps a clean record and refuses junk", function()
		t.eq(P.decode(nil), nil)
		t.eq(P.decode({ id = "a", starts = 1, max = 5, kind = "ffa" }), nil, "no config")
		t.eq(P.decode({ id = "a", starts = 1, max = 5, kind = "bogus", config = { gameMap = "World" } }), nil, "unknown kind")
		local l = P.decode({
			id = "a",
			kind = "team",
			starts = 100,
			max = 999,
			players = -3,
			status = "weird",
			config = { gameMap = "Europe", playerTeams = 4, nested = { x = { deep = 1 } }, overtime = { enabled = true }, disabledUnits = { "City" }, [5] = "x" },
			seats = { ["1"] = 10, [2] = 5, ["toolongtoolongtoolongtoolong"] = 1 },
		}) :: any
		t.eq(l.max, 200)
		t.eq(l.players, 0)
		t.eq(l.status, "open")
		t.eq(l.config.gameMap, "Europe")
		t.eq(l.config.playerTeams, 4)
		t.eq(l.config.overtime.enabled, true, "small tables kept (OpenFront's overtime)")
		t.eq(l.config.disabledUnits[1], "City")
		t.eq(next(l.config.nested), nil, "deeper tables dropped")
		t.eq(l.seats["1"], 10)
		t.eq(l.seats["toolongtoolongtoolongtoolong"], nil)
		t.eq(P.decode({ id = "b", kind = "ffa", starts = 1, max = 5, config = { gameMap = "World" }, seats = {} }).seats ~= nil, true)
	end)

	t.test("the client view hides the access code and server id", function()
		local l = lobby("a", "ffa", 1100, 3, 10)
		l.code, l.psid = "secret", "psid"
		local v = P.publicView(l, 1000)
		t.eq(v.code, nil)
		t.eq(v.psid, nil)
		t.eq(v.startsIn, 100)
		t.eq(v.players, 3)
		t.eq(v.mapType, "World")
		t.ok(v.joinable)
		l.status, l.beat = "started", 1150
		t.ok(P.watchable(l, 1200))
		t.ok(not P.watchable(l, 1150 + P.LIVE_STALE_S + 1), "a silent match server drops off")
	end)

	t.test("local store: take seats the soonest lobby that fits; release; expiry; locks", function()
		local now = 1000
		local store = LobbyStore.localstore(function()
			return now
		end)
		store.put(lobby("late", "ffa", now + 80), 300)
		store.put(lobby("soon", "world", now + 40, 9, 10), 300)
		store.put(lobby("team", "team", now + 30), 300)
		local got = store.take(P.takeSpec("ffa", 1, { "1" }, now))
		t.eq(got and got.id, "soon", "a free-for-all join takes World's sooner lobby")
		t.eq(store.get("soon").players, 10)
		local again = store.take(P.takeSpec("ffa", 1, { "2" }, now))
		t.eq(again and again.id, "late", "World's is full now")
		local after, n = store.release("soon", { "1" })
		t.eq(n, 1)
		t.eq(after.players, 9)
		t.eq(store.get("soon").players, 9)
		-- a party that doesn't fit anywhere gets nothing
		t.eq(store.take(P.takeSpec("team", 11, { "a" }, now)), nil)
		-- server id binding
		store.bindPsid("ps1", "late", 300)
		t.eq(store.lobbyForPsid("ps1").id, "late")
		-- locks: one owner at a time until it lapses
		t.ok(store.lock("scheduler", 20, "hubA"))
		t.ok(not store.lock("scheduler", 20, "hubB"))
		t.ok(store.lock("scheduler", 20, "hubA"), "the holder renews")
		now += 21
		t.ok(store.lock("scheduler", 20, "hubB"), "a lapsed lock passes on")
		-- records expire
		now += 300
		t.eq(store.get("late"), nil)
		t.eq(#store.list(), 0)
	end)
end
