-- OpenFront port, Phase C gate: structures. Scripted humans spawn on the
-- coast beside tribes, expand, and build cities, ports and defence posts in
-- a cycle around their spawn, upgrade their first city and scrap a post.
-- tests/fixtures/openfront/structures.json was recorded from OpenFront
-- v0.35.2's own engine (openfront-run/tests/conquest/StructureTrace) with
-- the same script: the game hash every tick, and every 50 ticks each
-- player's tiles, troops and gold and every unit's id, type, tile, owner,
-- level, construction flag and health. A third case builds silos and SAMs
-- and fires atom bombs, hydrogen bombs and a MIRV at the other humans;
-- another builds warships that fight, capture trade ships and are moved;
-- another builds factories, so stations, railroads and trains run. Maps come from the reference clone;
-- skipped when it is absent.
return function(t)
	local AttackExecution = t.require("OpenFront.Executions.AttackExecution")
	local ConstructionExecution = t.require("OpenFront.Executions.ConstructionExecution")
	local DeleteUnitExecution = t.require("OpenFront.Executions.DeleteUnitExecution")
	local MoveWarshipExecution = t.require("OpenFront.Executions.MoveWarshipExecution")
	local RecomputeRailClusterExecution = t.require("OpenFront.Executions.RecomputeRailClusterExecution")
	local EngineConfig = t.require("OpenFront.EngineConfig")
	local Game = t.require("OpenFront.Game")
	local GameMap = t.require("OpenFront.GameMap")
	local SpawnExecution = t.require("OpenFront.Executions.SpawnExecution")
	local SpawnTimerExecution = t.require("OpenFront.Executions.SpawnTimerExecution")
	local TribeSpawner = t.require("OpenFront.Executions.TribeSpawner")
	local UpgradeStructureExecution = t.require("OpenFront.Executions.UpgradeStructureExecution")
	local WinCheckExecution = t.require("OpenFront.Executions.WinCheckExecution")

	local ROOT = "../reference/openfront-v0.35.2/resources/maps"
	local OFFSETS = {
		{ 0, 0 }, { 20, 0 }, { 0, 20 }, { -20, 0 }, { 0, -20 }, { 20, 20 },
		{ -20, -20 }, { 20, -20 }, { -20, 20 }, { 40, 0 }, { 0, 40 }, { -40, 0 },
	}

	local function fmt(x: number): string
		return string.format("%.17g", x)
	end

	for _, case in t.json(t.readFile("tests/fixtures/openfront/structures.json")) do
		t.test(`{case.map} {case.size}: {table.concat(case.cycle, ", ")} beside {case.bots} tribes, {case.ticks} ticks`, function()
			local dir = `{ROOT}/{case.map}`
			if not t.isFile(dir .. "/map.bin") then
				print(`  (skipped {case.map}: reference maps not available)`)
				return
			end
			local manifest = t.json(t.readFile(dir .. "/manifest.json"))
			local function load(key: string): any
				local m = manifest[key]
				return GameMap.new(m.width, m.height, buffer.fromstring(t.readFile(`{dir}/{key}.bin`)), m.num_land_tiles)
			end
			local compact = case.size == "Compact"
			local config = EngineConfig.new({
				gameMap = case.gameMap,
				gameMapSize = case.size,
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = case.bots,
				nations = "disabled",
			}, false)
			local humans = {}
			for i = 0, #case.seeds - 1 do
				table.insert(humans, { name = `Human{i}`, playerType = "HUMAN", clientID = `client{i}`, id = `human{i}` })
			end
			local map = load(if compact then "map4x" else "map")
			local game = Game.new(humans, {}, map, load(if compact then "map16x" else "map4x"), config)
			local w = map:width()
			local spawns = {}
			for i, seed in case.seeds do
				local tile = seed[2] * w + seed[1]
				while not (map:isLand(tile) and map:isShore(tile)) do
					tile += 1
				end
				spawns[i] = tile
				t.eq(tile, case.spawns[i], `spawn {i}`)
			end
			game:addExecution(SpawnTimerExecution.new())
			game:addExecution(table.unpack(TribeSpawner.new(game, "conquest-structures", {}):spawnTribes(case.bots)))
			game:addExecution(WinCheckExecution.new())
			if case.rail then
				game:addExecution(RecomputeRailClusterExecution.new(game:railNetwork()))
			end
			for i, h in humans do
				game:addExecution(SpawnExecution.new("conquest-structures", h, spawns[i], true))
			end
			-- Warship targets: the first water tile at or after each spawn.
			local waters = {}
			for i, s0 in spawns do
				local tile = s0
				while not map:isWater(tile) do
					tile += 1
				end
				waters[i] = tile
			end

			local granted, attempts = {}, {}
			local nextSample = 1
			for tick = 0, case.ticks - 1 do
				if not game:inSpawnPhase() then
					for idx, h in humans do
						local i = idx - 1
						if game:hasPlayer(h.id) then
							local p = game:player(h.id)
							if p:isAlive() then
								if not granted[idx] then
									granted[idx] = true
									p:addGold(case.grant or 3_000_000)
								end
								if tick % 40 == i * 5 then
									game:addExecution(AttackExecution.new(p:troops() * 0.25, p, nil, nil))
								end
								if tick % 150 == 20 + i * 7 then
									local unitType = case.cycle[(tick // 150) % #case.cycle + 1]
									attempts[idx] = (attempts[idx] or -1) + 1
									local off = OFFSETS[attempts[idx] % #OFFSETS + 1]
									local x = math.min(w - 1, math.max(0, spawns[idx] % w + off[1]))
									local y = math.min(map:height() - 1, math.max(0, spawns[idx] // w + off[2]))
									game:addExecution(ConstructionExecution.new(p, unitType, y * w + x))
								end
								if tick % 400 == 100 + i then
									local city = p:units("City")[1]
									if city then
										game:addExecution(UpgradeStructureExecution.new(p, city:id(), 1))
									end
								end
								for _, n in case.nukes or {} do
									if n[1] == tick and n[2] == i then
										game:addExecution(ConstructionExecution.new(p, n[3], spawns[n[4] + 1]))
									end
								end
								for _, wt in case.warships or {} do
									if tick == wt + i * 3 then
										game:addExecution(ConstructionExecution.new(p, "Warship", waters[idx]))
									end
								end
								if case.moveAt ~= nil and tick == case.moveAt + i then
									local ids = {}
									for _, u in p:units("Warship") do
										table.insert(ids, u:id())
									end
									game:addExecution(MoveWarshipExecution.new(p, ids, waters[idx % #humans + 1]))
								end
								if case.deleteCityAt ~= nil and tick == case.deleteCityAt + i then
									local city = p:units("City")[1]
									if city then
										game:addExecution(DeleteUnitExecution.new(p, city:id()))
									end
								end
								if tick == 1800 + i then
									local post = p:units("Defense Post")[1]
									if post then
										game:addExecution(DeleteUnitExecution.new(p, post:id()))
									end
								end
							end
						end
					end
				end
				game:executeNextTick()
				-- Samples first: on a mismatch they say more than the hash.
				local sample = case.samples[nextSample]
				if sample and sample.tick == tick then
					nextSample += 1
					local units = game:units()
					t.eq(#units, #sample.units, `tick {tick} unit count`)
					for k, want in sample.units do
						local u = units[k]
						local got = { u:id(), u:type(), u:tile(), u:owner():id(), u:level(), if u:isUnderConstruction() then 1 else 0, fmt(u:health()) }
						t.eq(table.concat(got, " "), `{want[1]} {want[2]} {want[3]} {want[4]} {want[5]} {want[6]} {fmt(tonumber(want[7]) :: number)}`, `tick {tick} unit {k}`)
					end
					local players = game:allPlayers()
					t.eq(#players, #sample.players, `tick {tick} player count`)
					for k, p in sample.players do
						local got = players[k]
						t.eq(got:id(), p[1], `tick {tick} player {k} id`)
						t.eq(got:numTilesOwned(), p[2], `tick {tick} {p[1]} tiles`)
						t.eq(got:troops(), tonumber(p[3]), `tick {tick} {p[1]} troops`)
						t.eq(got:gold(), tonumber(p[4]), `tick {tick} {p[1]} gold`)
					end
				end
				if game:hash() ~= tonumber(case.hashes[tick + 1]) then
					error(`tick {tick} hash: expected {case.hashes[tick + 1]}, got {fmt(game:hash())}`)
				end
			end
		end)
	end
end
