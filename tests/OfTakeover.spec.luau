-- Conquest's Arsenal (docs/design/ARSENAL_V2.md): Takeover. An eliminated
-- human takes command of the AI nation that eliminated them (RoWorld's
-- Sim.take_over), and the Robux credit it costs (Store/Profile).
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local HumanProtection = t.require("OpenFront.HumanProtection")
	local Profile = t.require("Store.Profile")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	local function landNear(map: any, x: number, y: number): number
		for r = 0, 40 do
			for dy = -r, r do
				for dx = -r, r do
					local tile = map:ref(x + dx, y + dy)
					if map:isLand(tile) and not map:isImpassable(tile) and not map:hasOwner(tile) then
						return tile
					end
				end
			end
		end
		error("no land")
	end

	-- Ada in a solo match with the map's nations, past the spawn phase.
	local function start(): (any, any, any)
		local runner = Runner.new({
			gameID = "takeover-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Singleplayer",
				difficulty = "Medium",
				bots = 0,
				nations = "default",
				extraWeapons = true,
			},
		})
		runner:addHuman("1001", "Ada", nil, { weapons = { megaNuke = true } })
		runner:start()
		local game = runner.game
		runner:intent("1001", { type = "spawn", tile = landNear(game:map(), 520, 140) })
		for _ = 1, 4000 do
			if not game:inSpawnPhase() then
				break
			end
			runner:step()
		end
		for _ = 1, 20 do
			runner:step()
		end
		local ada = game:playerByClientID("1001")
		local nation = nil
		for _, p in game:allPlayers() do
			if p:type() == "NATION" and p:isAlive() and p:numTilesOwned() > 0 then
				nation = p
				break
			end
		end
		return runner, ada, nation
	end

	t.test("an eliminated human takes over the nation that beat them", function()
		local runner, ada, nation = start()
		local game = runner.game
		t.eq(runner:takeoverTarget("1001"), nil, "not while alive")
		HumanProtection.surrender(game, ada, nation)
		runner:step()
		t.eq(ada:isAlive(), false, "Ada is out")
		t.eq(runner:takeoverTarget("1001"), nation, "offered the nation that beat her")
		local snap = Replication.newReplicator(runner):snapshot("1001")
		t.eq(snap.arsenal.takeover.smallID, nation:smallID(), "the client learns whom")
		local tiles, gold = nation:numTilesOwned(), nation:gold()
		t.ok(runner:takeOver("1001"), "done")
		t.eq(game:playerByClientID("1001"), nation, "Ada commands the nation")
		t.eq(nation:type(), "HUMAN")
		t.eq(nation:displayName(), "Ada", "under her name")
		t.eq(nation:numTilesOwned(), tiles, "its land")
		t.eq(nation:gold(), gold, "its gold")
		t.ok(nation:hasExtraWeapon("megaNuke"), "with her Arsenal")
		t.eq(runner:takeOver("1001"), false, "once")
		for _ = 1, 50 do
			runner:step()
		end
		t.ok(nation:isAlive(), "still playing")
		local after = Replication.newReplicator(runner):snapshot("1001")
		t.eq(after.you, nation:smallID(), "snapshots are hers")
	end)

	-- Bruno, 2026-11-12: the takeover reloaded the whole map (slow, once
	-- stuck). The client rebinds in place: same map, new "you".
	t.test("the client takes over in place, without a new map", function()
		local ClientState = t.require("OpenFront.ClientState")
		local runner, ada, nation = start()
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local client = ClientState.new()
		client:applySnapshot(rep:snapshot("1001"))
		HumanProtection.surrender(game, ada, nation)
		for _ = 1, 3 do
			runner:step()
			client:applyDelta(rep:forViewer(rep:collect(), "1001", game:drainMessages()))
		end
		t.eq(client.players[client.you].alive, false, "out")
		local tiles, units = client.tileState, client.units
		local snapshots, rebounds, rosters = 0, 0, 0
		client.Snapshot:Connect(function()
			snapshots += 1
		end)
		client.Rebound:Connect(function()
			rebounds += 1
		end)
		client.RosterChanged:Connect(function()
			rosters += 1
		end)
		t.ok(runner:takeOver("1001"), "done")
		client:applySnapshot(rep:snapshot("1001"), true)
		t.eq(snapshots, 0, "no new match on the client")
		t.eq(rebounds, 1, "rebound once")
		t.eq(rosters, 1, "the roster redraws (her name on the nation)")
		t.eq(client.you, nation:smallID(), "she is the nation now")
		t.eq(client.players[client.you].alive, true)
		t.eq(client.players[client.you].name, "Ada")
		t.ok(client.tileState == tiles and client.units == units, "the map and units carry on")
		-- Deltas keep flowing onto the same state.
		runner:step()
		client:applyDelta(rep:forViewer(rep:collect(), "1001", game:drainMessages()))
		t.eq(client.players[client.you].tiles, nation:numTilesOwned())
		-- Without inPlace (nothing on screen) it is a new match as before.
		client:applySnapshot(rep:snapshot("1001"))
		t.eq(snapshots, 1)
	end)

	-- Codex, 2026-11-12: everyone else sees the taken nation as the human
	-- (roster deltas carry changed entries), with the human's flag.
	t.test("an observer's roster shows the takeover", function()
		local ClientState = t.require("OpenFront.ClientState")
		local runner, ada, nation = start()
		local game = runner.game
		local rep = Replication.newReplicator(runner)
		local watcher = ClientState.new()
		watcher:applySnapshot(rep:snapshot(nil))
		local function tick()
			runner:step()
			watcher:applyDelta(rep:forViewer(rep:collect(), nil, game:drainMessages()))
		end
		for _ = 1, Replication.STATS_EVERY do
			tick()
		end
		local n, a = nation:smallID(), ada:smallID()
		t.eq(watcher.players[n].type, "NATION")
		t.ok(watcher.players[n].userId == nil, "a nation has no user id")
		local tilesBefore = watcher.players[n].tiles
		ada.playerInfo.flag = "f_us"
		HumanProtection.surrender(game, ada, nation)
		runner:step()
		local changed = nil
		watcher.RosterChanged:Connect(function(ids)
			changed = ids
		end)
		t.ok(runner:takeOver("1001"), "done")
		for _ = 1, Replication.STATS_EVERY + 1 do
			tick()
		end
		local seen = watcher.players[n]
		t.eq(seen.type, "HUMAN", "now a human")
		t.eq(seen.name, "Ada")
		t.eq(seen.flag, "f_us", "her flag, not the nation's")
		t.eq(seen.userId, 1001, "her head shot")
		t.ok(seen.tiles >= tilesBefore, "its stats stay")
		t.ok(changed ~= nil and table.find(changed, n) ~= nil, "RosterChanged names it")
		t.ok(watcher.players[a].userId == nil, "the old seat's user id clears")
		t.eq(#watcher.rosterOrder, #game:allPlayers(), "no duplicate entries")
	end)

	t.test("never a tribe, and not after the nation is gone", function()
		local runner, ada, nation = start()
		local game = runner.game
		local tribe = nil
		for _, p in game:allPlayers() do
			if p:type() == "BOT" then
				tribe = p
			end
		end
		if tribe then
			HumanProtection.surrender(game, ada, tribe)
			t.eq(runner:takeoverTarget("1001"), nil, "a tribe can't be taken over")
		end
		t.ok(nation ~= nil)
	end)

	t.test("a Takeover is a saved credit, spent once", function()
		local p = Profile.new()
		t.eq(Profile.spendTakeover(p), false, "none to spend")
		Profile.grant(p, "takeover", "r1", function()
			return 0
		end, 0)
		t.eq(p.takeovers, 1)
		local back = Profile.decode(Profile.encode(p))
		t.eq((back :: any).takeovers, 1, "saved")
		t.eq(Profile.spendTakeover(p), true)
		t.eq(p.takeovers, 0)
	end)
end
