-- OpenFront port, Phase A gate: a whole tribes-only match at exact parity.
-- tests/fixtures/openfront/tribe-match.json was recorded by running OpenFront
-- v0.35.2's own engine (openfront-run/tests/conquest/TribeMatchTrace.test.ts):
--   - spawn timer, TribeSpawner (gameID "conquest-test") and win check
--   - Public FFA on Medium, on its all-land test maps
--   - the game hash every tick, and every player's tiles, troops and gold
--     every 25 ticks
-- This covers SpawnExecution, PlayerExecution (growth, gold, surrounded
-- land), TribeExecution, AiAttackBehavior and AttackExecution together.
return function(t)
	local EngineConfig = t.require("OpenFront.EngineConfig")
	local Game = t.require("OpenFront.Game")
	local GameMap = t.require("OpenFront.GameMap")
	local SpawnTimerExecution = t.require("OpenFront.Executions.SpawnTimerExecution")
	local TribeSpawner = t.require("OpenFront.Executions.TribeSpawner")
	local WinCheckExecution = t.require("OpenFront.Executions.WinCheckExecution")

	local function loadMap(name: string): any
		local dir = `tests/fixtures/openfront/maps/{name}`
		local manifest = t.json(t.readFile(dir .. "/manifest.json"))
		return GameMap.new(
			manifest.map.width,
			manifest.map.height,
			buffer.fromstring(t.readFile(dir .. "/map.bin")),
			manifest.map.num_land_tiles
		)
	end

	for _, case in t.json(t.readFile("tests/fixtures/openfront/tribe-match.json")) do
		t.test(`{case.map} with {case.bots} tribes, {case.ticks} ticks`, function()
			-- tests/util/Setup.ts defaults, with the real EngineConfig.
			local config = EngineConfig.new({
				gameMap = "Asia",
				gameMapSize = "Normal",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				nations = "default",
				donateGold = false,
				donateTroops = false,
				bots = case.bots,
				infiniteGold = false,
				infiniteTroops = false,
				instantBuild = false,
				randomSpawn = false,
			}, false)
			local game = Game.new({}, {}, loadMap(case.map), nil, config)
			game:addExecution(SpawnTimerExecution.new())
			game:addExecution(table.unpack(TribeSpawner.new(game, "conquest-test", {}):spawnTribes(case.bots)))
			game:addExecution(WinCheckExecution.new())

			local nextSample = 1
			for tick = 0, case.ticks - 1 do
				game:executeNextTick()
				local sample = case.samples[nextSample]
				if sample and sample.tick == tick then
					nextSample += 1
					local players = game:allPlayers()
					t.eq(#players, #sample.players, `tick {tick} player count`)
					for i, want in sample.players do
						local p = players[i]
						local got = { p:id(), p:name(), p:numTilesOwned(), p:troops(), p:gold() }
						local exp = { want[1], want[2], want[3], tonumber(want[4]), tonumber(want[5]) }
						for k = 1, 5 do
							if got[k] ~= exp[k] then
								error(`tick {tick} player {want[1]} field {k}: expected {exp[k]}, got {got[k]}`)
							end
						end
					end
				end
				local want = tonumber(case.hashes[tick + 1])
				if game:hash() ~= want then
					error(`tick {tick} hash: expected {case.hashes[tick + 1]}, got {string.format("%.17g", game:hash())}`)
				end
			end
			local winner = game:getWinner()
			t.eq(if winner then winner:id() else nil, case.winner, "winner")
		end)
	end
end
