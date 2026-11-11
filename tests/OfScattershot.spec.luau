-- Conquest's Arsenal, second round (docs/design/ARSENAL_V2.md): the
-- Scattershot, through the real runner on compact World.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local HudModel = t.require("OpenFront.HudModel")
	local NukeExecution = t.require("OpenFront.Executions.NukeExecution")
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

	-- Ada and Bea in a public match, past the spawn phase; Ada has a silo.
	local function start(extra: boolean, adaWeapons: { [string]: boolean }?): (any, any, any)
		local runner = Runner.new({
			gameID = "scattershot-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				extraWeapons = extra,
				spawnImmunityDuration = 0, -- bombs need it over
			},
		})
		runner:addHuman("1001", "Ada", nil, { weapons = adaWeapons })
		runner:addHuman("1002", "Bea")
		runner:start()
		local game = runner.game
		local map = game:map()
		runner:intent("1001", { type = "spawn", tile = landNear(map, 520, 140) })
		runner:intent("1002", { type = "spawn", tile = landNear(map, 600, 140) })
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
		ada:buildUnit("Missile Silo", ada:tiles():values()[1], {})
		return runner, ada, game:playerByClientID("1002")
	end

	t.test("the Scattershot needs extra weapons and the unlock; RoWorld's 3.75M", function()
		local runner, ada = start(true, nil)
		ada:addGold(100_000_000)
		local bea = runner.game:playerByClientID("1002")
		t.eq(ada:canBuild("Scattershot", bea:tiles():values()[1]), false, "locked without the unlock")

		runner, ada = start(false, { scattershot = true })
		ada:addGold(100_000_000)
		bea = runner.game:playerByClientID("1002")
		t.eq(ada:canBuild("Scattershot", bea:tiles():values()[1]), false, "off unless the match has extra weapons")

		runner, ada = start(true, { scattershot = true })
		ada:addGold(100_000_000)
		bea = runner.game:playerByClientID("1002")
		t.eq(runner.game:unitInfo("Scattershot").cost(runner.game, ada), 3_750_000, "RoWorld's price")
		t.ok(ada:canBuild("Scattershot", bea:tiles():values()[1]) ~= false, "launchable from a silo once unlocked")
		local snap = Replication.newReplicator(runner):snapshot("1001")
		t.eq(snap.arsenal.weapons.scattershot, true, "the viewer learns it's unlocked")
		t.eq(snap.costs.Scattershot, 3_750_000, "and its price")
	end)

	t.test("it launches with 4 to 6 warheads 28 to 46 tiles round the aim, never on its own side", function()
		local runner, ada, bea = start(true, { scattershot = true })
		local game = runner.game
		ada:addGold(100_000_000)
		local aim = bea:tiles():values()[1]
		local gold = ada:gold()
		runner:intent("1001", { type = "build_unit", unit = "Scattershot", tile = aim })
		local carriers, warheads = 0, {}
		for _ = 1, 4 do
			runner:step()
			carriers = math.max(carriers, #game:units("Scattershot"))
			for _, u in game:units("MIRV Warhead") do
				warheads[u:id()] = u:targetTile()
			end
		end
		t.eq(carriers, 1, "the bomb itself flies")
		t.ok(math.abs(gold - ada:gold() - 3_750_000) < 5_000, "paid once (less a few ticks' income)")
		local n = 0
		for _, target in warheads do
			n += 1
			local d = math.sqrt(game:euclideanDistSquared(aim, target))
			t.ok(d >= NukeExecution.SCATTER_NEAR - 1 and d <= NukeExecution.SCATTER_FAR + 1, `warhead {d} tiles out`)
			t.ok(game:owner(target) ~= ada, "never on the launcher's land")
		end
		t.ok(n >= 1 and n <= NukeExecution.SCATTER_MAX, `{n} warheads`)
		-- They all come down.
		for _ = 1, 600 do
			runner:step()
		end
		t.eq(#game:units("Scattershot") + #game:units("MIRV Warhead"), 0, "everything landed")
	end)

	t.test("the Arsenal's items follow OpenFront's ten, keyed by their place in the fly-out", function()
		local runner = start(true, { megaNuke = true, scattershot = true, artillery = true })
		local ClientState = t.require("OpenFront.ClientState")
		local state = ClientState.new()
		state:applySnapshot(Replication.newReplicator(runner):snapshot("1001"))
		local types, keys = {}, {}
		for _, item in HudModel.buildItems(state) do
			table.insert(types, item.type)
			table.insert(keys, item.key)
		end
		t.eq(types[11], "Mega Nuke")
		t.eq(types[12], "Scattershot")
		t.eq(types[13], "Artillery")
		t.eq(keys[11], "1", "first in the ARSENAL fly-out")
		t.eq(keys[13], "3")
		t.eq(keys[10], "0", "OpenFront's ten keep theirs")
	end)
end
