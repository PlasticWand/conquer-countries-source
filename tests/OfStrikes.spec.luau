-- Conquest's Arsenal, second round (docs/design/ARSENAL_V2.md): Air Strike,
-- Railgun and Rapid Reload, through the real runner on compact World.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local StrikeExecution = t.require("OpenFront.Executions.StrikeExecution")
	local LauncherExecution = t.require("OpenFront.Executions.LauncherExecution")
	local Config = t.require("OpenFront.Config")
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

	-- Ada and Bea in a public match, 80 tiles apart, past the spawn phase.
	local function start(adaWeapons: { [string]: boolean }?): (any, any, any)
		local runner = Runner.new({
			gameID = "strikes-test",
			mapFolder = Maps.World,
			gameConfig = {
				gameMap = "World",
				gameMapSize = "Compact",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
				extraWeapons = true,
				spawnImmunityDuration = 0,
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
		return runner, game:playerByClientID("1001"), game:playerByClientID("1002")
	end

	local function finished(player: any, unitType: string, tile: number): any
		local unit = player:buildUnit(unitType, tile, {})
		player.mg:addExecution(LauncherExecution.new(unit))
		return unit
	end

	t.test("RoWorld's prices; locked without the unlock", function()
		local runner, ada, bea = start(nil)
		local game = runner.game
		ada:addGold(100_000_000)
		local own = ada:tiles():values()[1]
		t.eq(ada:canBuild("Airfield", own), false, "no Airfield without Air Strike")
		t.eq(ada:canBuild("Railgun", own), false, "no Railgun without it")
		runner, ada, bea = start({ airStrike = true, railgun = true })
		game = runner.game
		ada:addGold(100_000_000)
		own = ada:tiles():values()[1]
		t.eq(game:unitInfo("Airfield").cost(game, ada), 500_000)
		t.eq(game:unitInfo("Railgun").cost(game, ada), 2_500_000)
		t.eq(game:unitInfo("Air Strike").cost(game, ada), 0, "the strike itself is free")
		ada:buildUnit("Airfield", own, {})
		t.eq(game:unitInfo("Airfield").cost(game, ada), 1_000_000, "+500K each")
		local snap = Replication.newReplicator(runner):snapshot("1001")
		t.eq(snap.arsenal.weapons.airStrike, true)
		t.eq(snap.costs.Railgun, 2_500_000)
		t.ok(bea ~= nil)
	end)

	t.test("an air strike leaves the nearest loaded Airfield in reach, then it rearms", function()
		local runner, ada, bea = start({ airStrike = true })
		local game = runner.game
		local target = bea:tiles():values()[1]
		t.eq(ada:canBuild("Air Strike", target), false, "no Airfield yet")
		local field = finished(ada, "Airfield", ada:tiles():values()[1])
		t.ok(ada:canBuild("Air Strike", target) ~= false, "Bea is within 156 tiles")
		t.eq(ada:canBuild("Air Strike", ada:tiles():values()[2]), false, "never your own land")
		runner:intent("1001", { type = "build_unit", unit = "Air Strike", tile = target })
		local flying = 0
		for _ = 1, 5 do
			runner:step()
			flying = math.max(flying, #game:units("Air Strike"))
		end
		t.eq(flying, 1, "a visible strike in flight")
		t.ok(field:isInCooldown(), "the Airfield rearms")
		t.eq(ada:canBuild("Air Strike", target), false, "one strike at a time")
		for _ = 1, LauncherExecution.RELOAD.Airfield + 5 do
			runner:step()
		end
		t.ok(not field:isInCooldown(), "ready again after 30 s")
	end)

	t.test("a strike kills min(tiles x per tile, a share) of each enemy army and damages its buildings", function()
		local runner, ada, bea = start({ airStrike = true, railgun = true })
		local game = runner.game
		local target = bea:tiles():values()[1]
		local city = bea:buildUnit("City", target, {})
		bea:setTroops(1_000_000)
		StrikeExecution.impact(game, ada, "Air Strike", target)
		local lost = 1_000_000 - bea:troops()
		t.ok(lost > 0 and lost <= 60_000, `at most 6% ({lost})`)
		t.eq(city:health(), 1000 - 600, "600 to the city")
		local adaTroops = ada:troops()
		StrikeExecution.impact(game, ada, "Railgun Shot", ada:tiles():values()[1])
		t.eq(ada:troops(), adaTroops, "never its own side")
		StrikeExecution.impact(game, ada, "Railgun Shot", target)
		t.eq(city:isActive(), false, "a railgun knocks a level-1 city down")
	end)

	t.test("Rapid Reload halves every reload", function()
		local runner, ada = start({ rapidReload = true, railgun = true })
		local _, bea = runner, runner.game:playerByClientID("1002")
		t.eq(Config.rapidReload(ada, 300), 150)
		t.eq(Config.rapidReload(bea, 300), 300, "only for its owner")
		t.eq(LauncherExecution.reloadTicks("Railgun", ada), 125)
	end)
end
