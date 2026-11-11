-- OpenFront port, Phase C gate: whole tribes-only matches on real maps with
-- water, so tribes launch transport ships, land and attack from beachheads.
-- tests/fixtures/openfront/real-map-tribes.json was recorded from OpenFront
-- v0.35.2's own engine (openfront-run/tests/conquest/RealMapTribeTrace):
-- World and Black Sea at compact size, the game hash every tick (it
-- includes every unit) and each player's tiles, troops and gold every 50
-- ticks. Maps come from the reference clone; skipped when it is absent.
return function(t)
	local EngineConfig = t.require("OpenFront.EngineConfig")
	local Game = t.require("OpenFront.Game")
	local GameMap = t.require("OpenFront.GameMap")
	local SpawnTimerExecution = t.require("OpenFront.Executions.SpawnTimerExecution")
	local TribeSpawner = t.require("OpenFront.Executions.TribeSpawner")
	local WinCheckExecution = t.require("OpenFront.Executions.WinCheckExecution")

	local ROOT = "../reference/openfront-v0.35.2/resources/maps"

	for _, case in t.json(t.readFile("tests/fixtures/openfront/real-map-tribes.json")) do
		t.test(`{case.map} {case.size}, {case.bots} tribes, {case.ticks} ticks (boats)`, function()
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
			local game = Game.new({}, {}, load(if compact then "map4x" else "map"), load(if compact then "map16x" else "map4x"), config)
			game:addExecution(SpawnTimerExecution.new())
			game:addExecution(table.unpack(TribeSpawner.new(game, "conquest-real", {}):spawnTribes(case.bots)))
			game:addExecution(WinCheckExecution.new())
			local nextSample = 1
			for tick = 0, case.ticks - 1 do
				game:executeNextTick()
				local want = tonumber(case.hashes[tick + 1])
				if game:hash() ~= want then
					-- Find the first player that differs, for a useful message.
					local detail = ""
					local sample = case.samples[nextSample - 1]
					if sample then
						detail = ` (last matching sample tick {sample.tick})`
					end
					error(`tick {tick} hash: expected {case.hashes[tick + 1]}, got {string.format("%.17g", game:hash())}{detail}`)
				end
				local sample = case.samples[nextSample]
				if sample and sample.tick == tick then
					nextSample += 1
					local players = game:allPlayers()
					t.eq(#players, #sample.players, `tick {tick} player count`)
					for i, p in sample.players do
						local got = players[i]
						t.eq(got:id(), p[1], `tick {tick} player {i} id`)
						t.eq(got:numTilesOwned(), p[2], `tick {tick} {p[1]} tiles`)
						t.eq(got:troops(), tonumber(p[3]), `tick {tick} {p[1]} troops`)
						t.eq(got:gold(), tonumber(p[4]), `tick {tick} {p[1]} gold`)
					end
				end
			end
		end)
	end
end
