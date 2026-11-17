-- Hub and match servers over one store (LobbyDirectory, MatchHost,
-- LobbyStore.localstore): scheduling under a lock, Quick Play seats, the
-- line, the Studio stand-in, and a match server's arrivals, start and end.
return function(t)
	local P = t.require("PublicLobbies")
	local LobbyStore = t.require("LobbyStore")
	local LobbyDirectory = t.require("LobbyDirectory")
	local MatchHost = t.require("MatchHost")

	local function world()
		local w: any = { now = 10000, sent = {}, made = 0, sendResult = true, sendError = nil }
		w.clock = function()
			return w.now
		end
		w.store = LobbyStore.localstore(w.clock)
		return w
	end

	local function hub(w: any, name: string, size: number?): any
		local ids = 0
		local store = table.clone(w.store)
		-- each hub is its own lock owner
		store.lock = function(lockName: string, ttl: number)
			return w.store.lock(lockName, ttl, name)
		end
		return LobbyDirectory.new({
			store = store,
			teleport = {
				reserve = function()
					w.made += 1
					return `code{w.made}`, `psid{w.made}`
				end,
				send = function(players: { any }, code: string, data: any)
					table.insert(w.sent, { players = players, code = code, data = data })
					return w.sendResult, w.sendError
				end,
			},
			config = function(kind: string)
				return {
					gameMap = if kind == "world" then "World" else "Europe",
					gameMode = if kind == "team" then "Team" else "Free For All",
					playerTeams = if kind == "team" then 4 else nil,
					maxPlayers = 12,
				}
			end,
			now = w.clock,
			rand = function()
				return 0.5
			end,
			newId = function()
				ids += 1
				return `{name}-{ids}`
			end,
			worldAvailable = true,
			serverSize = function()
				return size
			end,
			uidOf = function(p: any)
				return p.uid
			end,
		})
	end

	local function players(...: string): { any }
		local out = {}
		for _, u in { ... } do
			table.insert(out, { uid = u })
		end
		return out
	end

	t.test("one hub at a time schedules a lobby of each kind; the others list them", function()
		local w = world()
		local a, b = hub(w, "A"), hub(w, "B", 8)
		a:refresh()
		b:refresh()
		t.eq(#w.store.list(), 4, "ffa, world, blitz and team, made once")
		t.eq(w.made, 4)
		local kinds = {}
		for _, l in b:lobbies() do
			kinds[l.kind] = l
		end
		t.ok(kinds.ffa and kinds.world and kinds.blitz and kinds.team, "B lists all four")
		t.eq(kinds.team.config.playerTeams, 4)
		t.eq(kinds.world.config.gameMap, "World")
		t.eq(#b:view(), 4)
		t.eq(b:view()[1].code, nil, "clients never see access codes")
		-- a hub with a smaller server caps the seats it creates
		w.now += 200
		b:refresh()
		for _, l in b:lobbies() do
			if l.created == w.now then
				t.eq(l.max, 8, "capped at the server size")
			end
		end
	end)

	t.test("Quick Play seats a party in the soonest lobby of its kind and teleports it", function()
		local w = world()
		local a = hub(w, "A")
		a:refresh()
		local ok, reason, l = a:joinPublic(players("1", "2"), "team", { party = { key = "p", uids = { "1", "2" }, leader = "1" } })
		t.ok(ok, reason)
		t.eq(l and l.kind, "team")
		t.eq(w.store.get(l.id).players, 2)
		t.eq(#w.sent, 1)
		t.eq(w.sent[1].data.lobby, l.id)
		t.eq(w.sent[1].data.party.leader, "1")
		t.eq(w.sent[1].code, l.code)
	end)

	t.test("a free-for-all join takes World's lobby when it starts sooner", function()
		local w = world()
		local a = hub(w, "A")
		a:refresh()
		local ok, _, l = a:joinPublic(players("1"), "ffa")
		t.ok(ok)
		local soonest = math.huge
		for _, x in a:lobbies() do
			if x.kind == "ffa" or x.kind == "world" then
				soonest = math.min(soonest, x.starts)
			end
		end
		t.eq(l and l.starts, soonest)
	end)

	t.test("full lobbies: NO_ROOM, the line waits, then seats in the next lobby", function()
		local w = world()
		local a = hub(w, "A")
		a:refresh()
		local big = {}
		for i = 1, 12 do
			table.insert(big, { uid = `t{i}` })
		end
		t.ok((a:joinPublic(big, "team")), "fills the team lobby")
		local ok, reason = a:joinPublic(players("x"), "team")
		t.ok(not ok)
		t.eq(reason, LobbyDirectory.NO_ROOM)
		local seated: any = nil
		a:enqueue({
			key = "x",
			kind = "team",
			since = w.now,
			members = function()
				return players("x"), nil
			end,
			done = function(okay: boolean, why: string?, lobby: any)
				seated = { ok = okay, why = why, lobby = lobby }
			end,
		})
		a:serveQueue()
		t.eq(seated, nil, "still waiting")
		t.ok(a:queued("x") ~= nil)
		-- the next refresh opens another team lobby (a full one doesn't count)
		w.now += 5
		a:refresh()
		a:serveQueue()
		t.ok(seated and seated.ok, "seated")
		t.eq(a:queued("x"), nil)
		-- the line gives up after QUEUE_MAX_S
		local gone: any = nil
		a:enqueue({ key = "y", kind = "team", since = w.now - LobbyDirectory.QUEUE_MAX_S - 1, members = function()
			return players("y"), nil
		end, done = function(okay: boolean, why: string?)
			gone = why
		end })
		a:serveQueue()
		t.eq(gone, "timeout")
	end)

	t.test("Studio: send reports 'studio', the seats stay and the lobby comes back", function()
		local w = world()
		w.sendResult, w.sendError = false, "studio"
		local a = hub(w, "A")
		a:refresh()
		local ok, reason, l = a:joinPublic(players("1"), "ffa")
		t.ok(not ok)
		t.eq(reason, "studio")
		t.ok(l ~= nil)
		t.eq(w.store.get((l :: any).id).players, 1, "the seat stays for the local match")
		-- a real teleport failure gives the seat back
		w.sendError = "boom"
		local _, why, l2 = a:joinPublic(players("2"), "team")
		t.eq(why, "boom")
		t.eq(w.store.get((l2 :: any).id).players, 0)
	end)

	t.test("open lobbies nobody joined are dropped after their start", function()
		local w = world()
		local a = hub(w, "A")
		a:refresh()
		local first = #w.store.list()
		w.now += P.LOBBY_OPEN_S + LobbyDirectory.STALE_AFTER_S + 1
		a:refresh()
		for _, l in w.store.list() do
			t.ok(l.starts > w.now - LobbyDirectory.STALE_AFTER_S, `{l.id} is fresh`)
		end
		t.ok(first == 4)
	end)

	t.test("match server: finds its lobby, holds the start for arrivals, frees lapsed seats, goes live, ends", function()
		local w = world()
		local a = hub(w, "A")
		a:refresh()
		local ok, reason, l = a:joinPublic(players("1", "2", "3"), "ffa")
		t.ok(ok, reason)
		local lobby = l :: any
		local host = MatchHost.new({ store = w.store, psid = lobby.psid, now = w.clock })
		t.eq(host:startsIn(), nil, "unknown until found")
		t.ok(host:lookup())
		t.eq(host.lobby and host.lobby.id, lobby.id)
		-- player 1 arrives just before the start: the start waits for their client
		w.now = lobby.starts - 2
		host:setRoster({ "1" })
		t.eq(host:startsIn(), MatchHost.MIN_WAIT_AFTER_FIRST_S)
		-- 2 arrived and left, 3 never came: both seats go back after ARRIVE_S
		host:setRoster({ "1", "2" })
		host:setRoster({ "1" })
		w.now = lobby.created + P.ARRIVE_S + 100
		host:_sync()
		t.eq(w.store.get(lobby.id).players, 1)
		t.eq(host.released, 2)
		host:start(1)
		local rec = w.store.get(lobby.id)
		t.eq(rec.status, "started")
		a:refresh()
		local live = nil
		for _, v in a:view() do
			if v.id == lobby.id then
				live = v
			end
		end
		t.ok(live and live.live and live.watchable, "listed to watch")
		local seen, _, sl = a:spectate({ uid = "9" }, lobby.id)
		t.ok(seen)
		t.eq(sl and sl.id, lobby.id)
		t.eq(w.sent[#w.sent].data.spectate, true)
		host:finish()
		t.eq(w.store.get(lobby.id), nil)
	end)
end
