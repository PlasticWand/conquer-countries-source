-- lune run scripts/bench-openfront [MapModule] [Normal|Compact] [tribes] [ticks]
-- Server-cost benchmark for the OpenFront port: a tribes-only match on an
-- imported map, timing load, the spawn phase and ms per tick.
local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local OF = Shared.OpenFront
local EngineConfig = Harness.require(OF.EngineConfig)
local Game = Harness.require(OF.Game)
local MapLoader = Harness.require(OF.MapLoader)
local SpawnTimerExecution = Harness.require(OF.Executions.SpawnTimerExecution)
local TribeSpawner = Harness.require(OF.Executions.TribeSpawner)
local WinCheckExecution = Harness.require(OF.Executions.WinCheckExecution)

-- Until transport ships are ported (Phase C), boat attempts are stubbed to
-- "no boat" here, so this measures land play only. Remove once boats exist.
local AiAttackBehavior = Harness.require(OF.Executions.AiAttackBehavior)
if not pcall(function() return OF.Executions.TransportShipExecution end) then
	AiAttackBehavior._sendBoatAttackToNearbyTerraNullius = function()
		return false
	end
	AiAttackBehavior._sendBoatAttack = function()
		return false
	end
end

local mapName = process.args[1] or "World"
local size = process.args[2] or "Normal"
local tribes = tonumber(process.args[3]) or 400
local ticks = tonumber(process.args[4]) or 600

local t0 = os.clock()
local Maps = Harness.mount("src/maps", "OpenFrontMaps")
local data = MapLoader.loadTerrainMap(Maps[mapName], size)
local loadMs = (os.clock() - t0) * 1000
local config = EngineConfig.new({ gameMap = mapName, gameMapSize = size, gameMode = "Free For All", gameType = "Public", difficulty = "Medium", bots = tribes }, false)
local game = Game.new({}, {}, data.gameMap, data.miniGameMap, config)
game:addExecution(SpawnTimerExecution.new())
game:addExecution(table.unpack(TribeSpawner.new(game, "bench", {}):spawnTribes(tribes)))
game:addExecution(WinCheckExecution.new())
local times = {}
local spawnMs = 0
-- Replication estimate: changed tiles per tick, encoded as runs of one owner
-- (owner u16 + count varint) with tile-index deltas as varints.
local changedPerTick, bytesPerTick = {}, {}
local function varintLen(n: number): number
	local len = 1
	while n >= 128 do
		n //= 128
		len += 1
	end
	return len
end
local map = game:map()
for i = 1, ticks do
	local s = os.clock()
	game:executeNextTick()
	local ms = (os.clock() - s) * 1000
	local changed = game:drainTileUpdates()
	local seen, byOwner, owners = {}, {}, {}
	for _, tile in changed do
		if not seen[tile] then
			seen[tile] = true
			local o = map:tileState(tile)
			if byOwner[o] == nil then
				byOwner[o] = {}
				table.insert(owners, o)
			end
			table.insert(byOwner[o], tile)
		end
	end
	local bytes, unique = 0, 0
	for _, o in owners do
		local list = byOwner[o]
		table.sort(list)
		unique += #list
		bytes += 2 + varintLen(#list)
		local prev = 0
		for _, tile in list do
			bytes += varintLen(tile - prev)
			prev = tile
		end
	end
	table.insert(changedPerTick, unique)
	table.insert(bytesPerTick, bytes)
	if game:inSpawnPhase() then
		spawnMs += ms
	else
		table.insert(times, ms)
	end
end
table.sort(times)
local function pct(p) return times[math.max(1, math.ceil(#times * p))] or 0 end
local alive, tiles = 0, 0
for _, p in game:players() do alive += 1; tiles += p:numTilesOwned() end
print(string.format("%s %s %dx%d, %d tribes: load %.0f ms, spawn phase %.0f ms total", mapName, size, data.gameMap:width(), data.gameMap:height(), tribes, loadMs, spawnMs))
local function stats(list)
	local sorted = table.clone(list)
	table.sort(sorted)
	local sum = 0
	for _, v in list do sum += v end
	return sum / #list, sorted[math.ceil(#sorted * 0.95)], sorted[#sorted]
end
local ca, c95, cmax = stats(changedPerTick)
local ba, b95, bmax = stats(bytesPerTick)
print(string.format("changed tiles/tick: mean %.0f, p95 %d, max %d; encoded bytes/tick: mean %.0f (%.1f KB/s), p95 %d, max %d", ca, c95, cmax, ba, ba * 10 / 1024, b95, bmax))
print(string.format("playing ticks %d: p50 %.1f ms, p95 %.1f ms, max %.1f ms; alive %d, owned %.1f%% of land", #times, pct(0.5), pct(0.95), times[#times] or 0, alive, 100 * tiles / data.gameMap:numLandTiles()))
