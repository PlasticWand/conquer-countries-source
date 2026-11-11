-- Conquest's Arsenal, second round (docs/design/ARSENAL_V2.md): Artillery
-- and structure health, through the real runner on compact World.
return function(t)
	local Runner = t.require("OpenFront.Runner")
	local Replication = t.require("OpenFront.Replication")
	local ArtilleryExecution = t.require("OpenFront.Executions.ArtilleryExecution")
	local ArtilleryShellExecution = t.require("OpenFront.Executions.ArtilleryShellExecution")
	local StructureDamage = t.require("OpenFront.StructureDamage")
	local Maps = t.mount("src/maps", "OpenFrontMaps")

	-- Land near (x, y), searching outward.
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

	-- Ada and Bea in a public match, 30 tiles apart, past the spawn phase.
	local function start(extra: boolean, adaWeapons: { [string]: boolean }?): (any, any, any)
		local runner = Runner.new({
			gameID = "artillery-test",
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
			},
		})
		runner:addHuman("1001", "Ada", nil, { weapons = adaWeapons })
		runner:addHuman("1002", "Bea")
		runner:start()
		local game = runner.game
		local map = game:map()
		runner:intent("1001", { type = "spawn", tile = landNear(map, 520, 140) })
		runner:intent("1002", { type = "spawn", tile = landNear(map, 550, 140) })
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

	t.test("Artillery needs the match's extra weapons and the unlock; RoWorld's price", function()
		local runner, ada = start(true, nil)
		local game = runner.game
		ada:addGold(10_000_000)
		local own = ada:tiles():values()[1]
		t.eq(ada:canBuild("Artillery", own), false, "locked without the unlock")

		runner, ada = start(false, { artillery = true })
		ada:addGold(10_000_000)
		t.eq(runner.game:playerByClientID("1001"):canBuild("Artillery", ada:tiles():values()[1]), false, "off unless the match has extra weapons")

		runner, ada = start(true, { artillery = true })
		game = runner.game
		ada:addGold(10_000_000)
		local cost = game:unitInfo("Artillery").cost
		t.eq(cost(game, ada), 150_000, "first battery")
		t.ok(ada:canBuild("Artillery", ada:tiles():values()[1]) ~= false, "buildable once unlocked")
		ada:buildUnit("Artillery", ada:tiles():values()[1], {})
		t.eq(cost(game, ada), 300_000, "+150K for each owned")
		local snap = Replication.newReplicator(runner):snapshot("1001")
		t.eq(snap.arsenal.weapons.artillery, true, "the viewer learns it's unlocked")
		t.eq(snap.costs.Artillery, 300_000, "and its price")
	end)

	t.test("a shell kills 2.88% of the army hit (clamped) and spares its own side", function()
		local runner, ada, bea = start(true, { artillery = true })
		local game = runner.game
		local beaTile, adaTile = bea:tiles():values()[1], ada:tiles():values()[1]
		bea:setTroops(1_000_000)
		ArtilleryShellExecution.impact(game, ada, beaTile)
		t.eq(bea:troops(), 1_000_000 - 19_200, "capped at 19,200")
		bea:setTroops(100_000)
		ArtilleryShellExecution.impact(game, ada, beaTile)
		t.eq(bea:troops(), 100_000 - 2_880, "2.88%")
		bea:setTroops(10_000)
		ArtilleryShellExecution.impact(game, ada, beaTile)
		t.eq(bea:troops(), 10_000 - 1_440, "at least 1,440")
		local adaTroops = ada:troops()
		ArtilleryShellExecution.impact(game, ada, adaTile)
		t.eq(ada:troops(), adaTroops, "never its own")
	end)

	t.test("structures lose a level at 0 health, or are destroyed at level 1", function()
		local runner, ada, bea = start(true, { artillery = true })
		local game = runner.game
		local tiles = bea:tiles():values()
		local city = bea:buildUnit("City", tiles[1], {})
		t.eq(city:health(), 1000, "health only with extra weapons")
		city:increaseLevel()
		for _ = 1, 7 do
			StructureDamage.damage(city, ArtilleryShellExecution.DAMAGE, ada)
		end
		t.ok(city:isActive(), "a level 2 city survives")
		t.eq(city:level(), 1, "losing a level")
		t.eq(city:health(), 1000, "and whole again")
		for _ = 1, 7 do
			StructureDamage.damage(city, ArtilleryShellExecution.DAMAGE, ada)
		end
		t.eq(city:isActive(), false, "destroyed at level 1")

		local off = start(false, nil)
		local plain = off.game:playerByClientID("1002")
		local c2 = plain:buildUnit("City", plain:tiles():values()[1], {})
		t.eq(c2:hasHealth(), false, "no structure health without the Arsenal: OpenFront's")
	end)

	t.test("a battery aims at the nearest enemy structure in range first (RoWorld's)", function()
		local runner, ada, bea = start(true, { artillery = true })
		local game = runner.game
		local adaTile = ada:tiles():values()[1]
		local battery = ada:buildUnit("Artillery", adaTile, {})
		local exe = ArtilleryExecution.new(battery)
		exe:init(game, game:ticks())
		-- Bea's nearest and farthest tiles in range.
		local near, far, nd, fd = nil, nil, math.huge, -1
		for _, tile in bea:tiles():values() do
			local d = game:euclideanDistSquared(adaTile, tile)
			if d <= ArtilleryExecution.RANGE ^ 2 then
				if d < nd then
					near, nd = tile, d
				end
				if d > fd then
					far, fd = tile, d
				end
			end
		end
		t.ok(near ~= nil and far ~= near, "Bea has land in range")
		bea:buildUnit("City", far, {})
		t.eq(exe:_target(adaTile), far, "the city, not random land")
		bea:buildUnit("Defense Post", near, {})
		t.eq(exe:_target(adaTile), near, "the nearer of two")
		ada:buildUnit("City", adaTile, {})
		t.eq(exe:_target(adaTile), near, "never its own")
	end)

	t.test("a finished battery shells enemy land in range by itself", function()
		local runner, ada, bea = start(true, { artillery = true })
		local game = runner.game
		-- Bea's land within range of a battery on Ada's tile closest to her.
		local best, bestD = nil, math.huge
		local beaTile = bea:tiles():values()[1]
		for _, tile in ada:tiles():values() do
			local d = game:euclideanDistSquared(tile, beaTile)
			if d < bestD then
				best, bestD = tile, d
			end
		end
		t.ok(bestD <= ArtilleryExecution.RANGE ^ 2, `Bea in range ({math.sqrt(bestD)} tiles)`)
		local battery = ada:buildUnit("Artillery", best, {})
		game:addExecution(ArtilleryExecution.new(battery))
		local impacts, onBea = {}, 0
		local impact = ArtilleryShellExecution.impact
		ArtilleryShellExecution.impact = function(mg: any, shooter: any, tile: number)
			table.insert(impacts, game:ticks())
			if mg:owner(tile) == bea then
				onBea += 1
			end
			return impact(mg, shooter, tile)
		end
		local shells, t0 = 0, game:ticks()
		for _ = 1, 400 do
			runner:step()
			shells = math.max(shells, #game:units("Artillery Shell"))
		end
		ArtilleryShellExecution.impact = impact
		t.ok(shells > 0, "a shell is a visible unit in flight")
		local rep = Replication.newReplicator(runner)
		ArtilleryShellExecution.impact = impact
		game:addExecution(ArtilleryShellExecution.new(ada, best, beaTile))
		runner:step()
		runner:step()
		local snap = rep:snapshot("1002")
		local seen = false
		for _, u in snap.units do
			if u.type == "Artillery Shell" then
				seen = true
				t.eq(u.sourceTile, best, "its record names the battery's tile")
			end
		end
		t.ok(seen, "the enemy sees the shell coming")
		t.ok(onBea >= 3, `it hit Bea's land ({onBea} of {#impacts} shells)`)
		local first = impacts[1] - t0
		t.ok(#impacts <= math.ceil((400 - ArtilleryExecution.GAP_MIN) / ArtilleryExecution.GAP_MIN) + 1, "no faster than one shot every 4 s")
		t.ok(first >= ArtilleryExecution.GAP_MIN, "a new battery waits a gap first")
	end)
end
