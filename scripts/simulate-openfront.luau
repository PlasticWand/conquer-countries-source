-- lune run scripts/simulate-openfront [Map] [Difficulty] [matches] [maxTicks] [tribes] [Normal|Compact]
-- Plays whole OpenFront-port matches headless through the real Runner: the
-- map's nations (as OpenFront's createGameRunner makes them) plus tribes, no
-- humans, until WinCheckExecution names a winner or maxTicks pass. Each match
-- uses a different gameID, so a different PRNG seed.
-- Prints per match: ticks to the win (or none), the winner and its land share,
-- the leader's share every 1000 ticks, nations alive, and ms per tick.
-- Flags the degenerate outcomes the Phase D gate asks about: a stall (no
-- tile changed owner for STALL_TICKS), runaway growth (one player above
-- RUNAWAY of the land before RUNAWAY_TICK) and the same winner every match.
-- Lune is slower than Roblox (ms per tick here is only for comparisons).

local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local OF = Shared.OpenFront
local Runner = Harness.require(OF.Runner)

local mapName = process.args[1] or "World"
local difficulty = process.args[2] or "Medium"
local matches = tonumber(process.args[3]) or 3
local maxTicks = tonumber(process.args[4]) or 30000
local tribes = tonumber(process.args[5]) or 100
local size = process.args[6] or "Compact"

local STALL_TICKS = 3000
local RUNAWAY = 0.5
local RUNAWAY_TICK = 3000

local Maps = Harness.mount("src/maps", "OpenFrontMaps")
local folder = (Maps :: any)[mapName]
assert(folder, `no map {mapName} in src/maps`)

local winners: { [string]: number } = {}
for m = 1, matches do
	local gameID = string.format("sim%05d", m)
	local runner = Runner.new({
		gameID = gameID,
		mapFolder = folder,
		gameConfig = {
			gameMap = mapName,
			gameMapSize = size,
			gameMode = "Free For All",
			gameType = "Public",
			difficulty = difficulty,
			bots = tribes,
			nations = "default",
		},
	})
	runner:start()
	local game = runner.game
	local landTotal = 0
	do
		local map = game:map()
		for tile = 0, map:width() * map:height() - 1 do
			if map:isLand(tile) then
				landTotal += 1
			end
		end
	end

	local started = os.clock()
	local lastOwned, lastChange = -1, 0
	local curve = {}
	local flags = {}
	local function leader(): (any, number)
		local best, bestTiles = nil, -1
		for _, p in game:players() do
			if p:numTilesOwned() > bestTiles then
				best, bestTiles = p, p:numTilesOwned()
			end
		end
		return best, bestTiles
	end
	local tick = 0
	while tick < maxTicks and game:getWinner() == nil do
		local ok, err = pcall(runner.step, runner)
		if not ok then
			table.insert(flags, `ERROR at tick {game:ticks()}: {err}`)
			break
		end
		tick += 1
		if tick % 100 == 0 then
			-- Stall: total owned land unchanged (a cheap proxy: the leader's
			-- and everyone's tiles summed).
			local owned = 0
			for _, p in game:players() do
				owned += p:numTilesOwned()
			end
			if owned ~= lastOwned then
				lastOwned, lastChange = owned, tick
			elseif tick - lastChange >= STALL_TICKS and not flags.stall then
				flags.stall = true
				table.insert(flags, `stall: no land changed hands from tick {lastChange} to {tick}`)
			end
		end
		if tick % 1000 == 0 then
			local p, tiles = leader()
			local share = tiles / landTotal
			table.insert(curve, string.format("%d:%.0f%%", tick, share * 100))
			if tick <= RUNAWAY_TICK and share > RUNAWAY and not flags.runaway then
				flags.runaway = true
				table.insert(flags, string.format("runaway: %s held %.0f%% at tick %d", p:name(), share * 100, tick))
			end
		end
	end
	local elapsed = os.clock() - started
	local winner = game:getWinner()
	local alive, nations = 0, 0
	for _, p in game:allPlayers() do
		if p:type() == "NATION" then
			nations += 1
			if p:isAlive() then
				alive += 1
			end
		end
	end
	local winnerText = "none"
	if winner ~= nil then
		local name = if type(winner) == "table" and winner.name then winner:name() else tostring(winner)
		local tiles = if type(winner) == "table" and winner.numTilesOwned then winner:numTilesOwned() else 0
		winnerText = string.format("%s (%.0f%% of land)", name, 100 * tiles / landTotal)
		winners[name] = (winners[name] or 0) + 1
	end
	print(string.format(
		"match %d (%s %s %s, %d tribes): %s after %d ticks (%.1f min game time); nations alive %d/%d; %.1f ms/tick",
		m, mapName, size, difficulty, tribes, winnerText, tick, tick / 600, alive, nations, 1000 * elapsed / math.max(1, tick)
	))
	print("  leader share: " .. table.concat(curve, " "))
	for _, f in flags do
		print("  FLAG " .. f)
	end
end
for name, n in winners do
	if n == matches and matches > 1 then
		print(`FLAG same winner every match: {name}`)
	end
end
