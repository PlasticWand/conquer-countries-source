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
