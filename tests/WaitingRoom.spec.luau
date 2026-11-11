-- The waiting room on a public match's own server (WaitingRoom): what it says
-- before the match, LEAVE closing near the start, and the way back after.
return function(t)
	local WaitingRoom = t.require("WaitingRoom")

	t.test("nothing heard yet: getting ready, LEAVE offered", function()
		local v = WaitingRoom.view(nil, 0)
		t.eq(v.kicker, "PUBLIC MATCH")
		t.eq(v.status, "Getting the match ready…")
		t.eq(v.clock, nil)
		t.eq(v.leave, true)
		-- the server's empty room (lobby record not found yet) reads the same
		t.eq(WaitingRoom.view({}, 0).status, "Getting the match ready…")
	end)

	t.test("a free-for-all lobby counts down between pushes and lists who is here", function()
		local room = { mapName = "Four Islands", players = 3, capacity = 20, seconds = 42, names = { "Paxel", "Ada", "Bea" } }
		local v = WaitingRoom.view(room, 0)
		t.eq(v.kicker, "PUBLIC MATCH")
		t.eq(v.title, "FOUR ISLANDS")
		t.eq(v.status, "Match starts in")
		t.eq(v.clock, "0:42")
		t.eq(v.count, "3 / 20 players")
		t.eq(v.names, "Paxel, Ada and Bea")
		t.eq(v.leave, true)
		t.eq(WaitingRoom.view(room, 10.5).clock, "0:32")
	end)

	t.test("a team game says so; one name alone; many names end in +N more", function()
		local v = WaitingRoom.view({ mapName = "Pangaea", mode = "4 teams", players = 1, capacity = 20, seconds = 30, names = { "Paxel" } }, 0)
		t.eq(v.kicker, "TEAM GAME  ·  4 TEAMS")
		t.eq(v.names, "Paxel")
		local names = {}
		for i = 1, 11 do
			table.insert(names, `P{i}`)
		end
		t.eq(WaitingRoom.view({ mapName = "World", names = names, seconds = 30 }, 0).names, "P1, P2, P3, P4, P5, P6, P7, P8 +3 more")
	end)

	t.test("LEAVE closes in the last seconds and when the server says the match is starting", function()
		local room = { mapName = "World", players = 1, capacity = 25, seconds = 10, names = { "Paxel" } }
		t.eq(WaitingRoom.view(room, 6).leave, true)
		local late = WaitingRoom.view(room, 10 - WaitingRoom.LEAVE_LOCK_S)
		t.eq(late.leave, false)
		t.eq(late.status, "Starting…")
		local told = WaitingRoom.view({ mapName = "World", seconds = 20, starting = true }, 0)
		t.eq(told.leave, false)
		t.eq(told.status, "Starting…")
	end)

	t.test("returning: no LEAVE; BACK TO LOBBY once the teleport is overdue", function()
		local v = WaitingRoom.returning(0)
		t.eq(v.title, "BACK TO THE LOBBY")
		t.eq(v.leave, false)
		t.eq(v.retry, false)
		t.eq(WaitingRoom.returning(WaitingRoom.RETRY_AFTER_S).retry, true)
	end)

	t.test("a match server is a reserved server, not a player's private one", function()
		t.eq(WaitingRoom.isMatchServer("", 0), false) -- a public server (a hub)
		t.eq(WaitingRoom.isMatchServer("abc", 0), true)
		t.eq(WaitingRoom.isMatchServer("abc", 1642763318), false) -- someone's private server
	end)

	t.test("the countdown never steps back up for jitter, but follows a moved start", function()
		local Model = t.require("WaitingRoom")
		t.eq(Model.smooth(9.2, 9.6), 9.2, "half a second high: keep counting")
		t.eq(Model.smooth(9.2, 8.9), 8.9, "lower: take it")
		t.eq(Model.smooth(9.2, 30), 30, "the start moved: take it")
		t.eq(Model.smooth(nil, 10), 10)
	end)
end
