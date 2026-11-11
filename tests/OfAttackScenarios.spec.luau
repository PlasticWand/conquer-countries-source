-- OpenFront port, Phase A gate: AttackExecution end to end on real maps.
-- tests/fixtures/openfront/attack-scenarios.json was produced by running
-- OpenFront v0.35.2's own AttackScenarios.test.ts scenarios under vitest,
-- with a per-tick trace added (every tick to 60, then every 10th):
--   [tick, attacker troops, defender troops, attacker tiles, defender tiles, troops in flight]
-- Like OpenFront's runScenario, no PlayerExecution runs, so troops don't
-- regrow and the numbers isolate the attack itself. Everything must match
-- exactly. Numbers are stored as %.17g strings: Lune's JSON decoder can
-- round long decimals off by one ulp, tonumber() is exact. The world and giantworldmap scenarios read OpenFront's test maps
-- from the reference clone and are skipped when it is absent.
return function(t)
	local EngineConfig = t.require("OpenFront.EngineConfig")
	local Game = t.require("OpenFront.Game")
	local GameMap = t.require("OpenFront.GameMap")
	local AttackExecution = t.require("OpenFront.Executions.AttackExecution")

	local REFERENCE_MAPS = "../reference/openfront-v0.35.2/tests/testdata/maps"

	local function mapDir(name: string): string?
		local local_ = `tests/fixtures/openfront/maps/{name}`
		if t.isFile(local_ .. "/map.bin") then
			return local_
		end
		if t.isFile(`{REFERENCE_MAPS}/{name}/map.bin`) then
			return `{REFERENCE_MAPS}/{name}`
		end
		return nil
	end

	local mapCache: { [string]: { width: number, height: number, land: number, bytes: string } } = {}
	local function loadMap(name: string): any?
		local dir = mapDir(name)
		if dir == nil then
			return nil
		end
		local m = mapCache[name]
		if m == nil then
			local manifest = t.json(t.readFile(dir .. "/manifest.json"))
			m = {
				width = manifest.map.width,
				height = manifest.map.height,
				land = manifest.map.num_land_tiles,
				bytes = t.readFile(dir .. "/map.bin"),
			}
			mapCache[name] = m
		end
		-- A fresh terrain buffer per game; the game owns it.
		return GameMap.new(m.width, m.height, buffer.fromstring(m.bytes), m.land)
	end

	local function sig(x: number): number
		return tonumber(string.format("%.4g", x)) :: number
	end

	local function conquerRect(game: any, player: any, r: any)
		local map = game:map()
		for y = r.y, r.y + r.h - 1 do
			for x = r.x, r.x + r.w - 1 do
				local tile = map:ref(x, y)
				if map:isLand(tile) and not map:isImpassable(tile) then
					player:conquer(tile)
				end
			end
		end
	end

	local function runScenario(s: any, gameMap: any): (any, { { number } })
		-- tests/util/Setup.ts + TestConfig/UseRealAttackLogic: spawn immunity off.
		local config = EngineConfig.new({
			gameMapSize = "Normal",
			gameMode = "Free For All",
			gameType = "Singleplayer",
			difficulty = "Medium",
			nations = "default",
			bots = 0,
		}, false)
		config.spawnImmunityDuration = function()
			return 0
		end
		config.nationSpawnImmunityDuration = function()
			return 0
		end
		local terraNullius = s.defender == "terraNullius"
		local defenderSide = if terraNullius then nil else s.defender
		local game = Game.new({
			{ name = "attacker", playerType = s.attacker.type or "HUMAN", id = "attacker" },
			{ name = "defender", playerType = (defenderSide and defenderSide.type) or "HUMAN", id = "defender" },
		}, {}, gameMap, nil, config)
		game:endSpawnPhase()
		local attacker = game:player("attacker")
		local defender = game:player("defender")

		local function area(r: any): number
			return r.w * r.h
		end
		local attackerFirst = defenderSide == nil or area(s.attacker.rect) >= area(defenderSide.rect)
		if attackerFirst then
			conquerRect(game, attacker, s.attacker.rect)
		end
		if defenderSide then
			conquerRect(game, defender, defenderSide.rect)
			defender:setTroops(defenderSide.troops)
			if defenderSide.traitor then
				defender:markTraitor()
			end
			for _, xy in defenderSide.defensePosts or {} do
				defender:buildUnit("Defense Post", game:ref(xy[1], xy[2]), {})
			end
		end
		if not attackerFirst then
			conquerRect(game, attacker, s.attacker.rect)
		end
		attacker:setTroops(s.attacker.troops)
		if s.attacker.traitor then
			attacker:markTraitor()
		end

		local targetID = if defenderSide == nil then nil else defender:id()
		local attackerTroopsBefore = attacker:troops()
		local defenderTroopsBefore = defender:troops()
		local attackerTilesBefore = attacker:numTilesOwned()
		local defenderTiles = if defenderSide == nil then 0 else defender:numTilesOwned()

		game:addExecution(AttackExecution.new(s.attackTroops, attacker, targetID))

		local maxTicks = s.maxTicks or 3000
		local ticks = 0
		local trace = {}
		repeat
			game:executeNextTick()
			ticks += 1
			if ticks <= 60 or ticks % 10 == 0 then
				local inFlight = 0
				for _, a in attacker:outgoingAttacks() do
					inFlight += a:troops()
				end
				table.insert(trace, {
					ticks,
					attacker:troops(),
					defender:troops(),
					attacker:numTilesOwned(),
					defender:numTilesOwned(),
					inFlight,
				})
			end
		until not (#attacker:outgoingAttacks() > 0 and ticks < maxTicks)

		local inFlight = 0
		for _, a in attacker:outgoingAttacks() do
			inFlight += a:troops()
		end
		local attackerTroopsLost = attackerTroopsBefore - attacker:troops() - inFlight
		local defenderTroopsLost = defenderTroopsBefore - defender:troops()
		local tilesConquered = attacker:numTilesOwned() - attackerTilesBefore
		local seconds = ticks / 10
		return {
			finished = #attacker:outgoingAttacks() == 0,
			ticks = ticks,
			attackerTiles = attackerTilesBefore,
			defenderTiles = defenderTiles,
			tilesConquered = tilesConquered,
			attackerTroopsLost = attackerTroopsLost,
			defenderTroopsLost = defenderTroopsLost,
			tilesPerSecond = sig(tilesConquered / seconds),
			attackerLossPerSecond = sig(attackerTroopsLost / seconds),
			defenderLossPerSecond = sig(defenderTroopsLost / seconds),
			attackerLossPerTile = sig(if tilesConquered == 0 then 0 else attackerTroopsLost / tilesConquered),
			defenderLossPerTile = sig(if tilesConquered == 0 then 0 else defenderTroopsLost / tilesConquered),
			defenderEliminated = defenderSide ~= nil and not defender:isAlive(),
		},
			trace
	end

	local cases = t.json(t.readFile("tests/fixtures/openfront/attack-scenarios.json"))
	local METRICS = {
		"finished",
		"ticks",
		"attackerTiles",
		"defenderTiles",
		"tilesConquered",
		"attackerTroopsLost",
		"defenderTroopsLost",
		"tilesPerSecond",
		"attackerLossPerSecond",
		"defenderLossPerSecond",
		"attackerLossPerTile",
		"defenderLossPerTile",
		"defenderEliminated",
	}

	for _, case in cases do
		t.test(case.name, function()
			local gameMap = loadMap(case.scenario.map)
			if gameMap == nil then
				print(`  (skipped {case.name}: map {case.scenario.map} not available)`)
				return
			end
			local metrics, trace = runScenario(case.scenario, gameMap)
			-- Trace first: it shows the tick where play diverges.
			for i, want in case.trace do
				local got = trace[i]
				if got == nil then
					error(`trace ends early at row {i} (tick {want[1]})`)
				end
				for k = 1, 6 do
					local expected = tonumber(want[k]) :: number
					if got[k] ~= expected then
						error(
							`tick {want[1]} column {k}: expected {want[k]}, got {string.format("%.17g", got[k])}`
						)
					end
				end
			end
			t.eq(#trace, #case.trace, "trace length")
			for _, key in METRICS do
				local want, got = case.metrics[key], metrics[key]
				if type(want) == "string" then
					want = tonumber(want)
				end
				if got ~= want then
					error(`{key}: expected {tostring(want)}, got {tostring(got)}`)
				end
			end
		end)
	end
end
