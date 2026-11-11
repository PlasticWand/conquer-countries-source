-- lune run tests/OfServerProfile [ticks] [plain|trace|wrap] [deep|paths]: where the server tick goes on the
-- public setup (full World, 400 tribes, the map's nations), by function.
-- Wraps every function of the listed modules with an inclusive timer, so
-- nested calls count in both. Prints a fingerprint of the final state, so an
-- optimisation can show it changed nothing. Not part of the suite.
local process = require("@lune/process")
local Harness = require("./harness")
local Shared = Harness.shared()
local OF = Shared.OpenFront
local Runner = Harness.require(OF.Runner)
local Maps = Harness.mount("src/maps", "OpenFrontMaps")

local TICKS = tonumber(process.args[1]) or 1500
-- "plain" skips the wrappers, for true tick times.
local PLAIN = process.args[2] == "plain" or process.args[2] == "trace"

local stats: { [string]: { calls: number, ms: number, max: number } } = {}
-- "spikes" (4th argument) also lists the slowest ticks with the functions
-- that took the most time inside each.
local SPIKES = process.args[4] == "spikes"
local tickStats: { [string]: number } = {}
local function wrap(label: string, module: any)
	if PLAIN then
		return
	end
	for name, fn in module do
		if type(fn) == "function" and name ~= "new" and name ~= "__index" then
			local key = label .. "." .. name
			module[name] = function(...)
				local s = os.clock()
				local r = table.pack(fn(...))
				local ms = (os.clock() - s) * 1000
				local st = stats[key]
				if st == nil then
					st = { calls = 0, ms = 0, max = 0 }
					stats[key] = st
				end
				st.calls += 1
				st.ms += ms
				st.max = math.max(st.max, ms)
				if SPIKES then
					tickStats[key] = (tickStats[key] or 0) + ms
				end
				return table.unpack(r, 1, r.n)
			end
		end
	end
end

local Ex = OF.Executions
wrap("AiAttack", Harness.require(Ex.AiAttackBehavior))
wrap("Attack", Harness.require(Ex.AttackExecution))
wrap("NationStructure", Harness.require(Ex.Nation.NationStructureBehavior))
wrap("NationUtils", Harness.require(Ex.Nation.NationUtils))
wrap("ExecUtil", Harness.require(Ex.Util))
wrap("Nation", Harness.require(Ex.NationExecution))
wrap("Tribe", Harness.require(Ex.TribeExecution))
wrap("Transport", Harness.require(Ex.TransportShipExecution))
wrap("Player", Harness.require(Ex.PlayerExecution))
for _, name in { "BotAnnexation", "NationAllianceBehavior", "NationMIRVBehavior", "NationNukeBehavior", "NationWarshipBehavior", "SharedWaterCache" } do
	wrap(name, Harness.require(Ex.Nation[name]))
end
wrap("TransportUtils", Harness.require(OF.TransportShipUtils))
-- "deep" also wraps the engine (Game, Player, Attack, heap, config), at a
-- larger timer cost on their hot calls.
if process.args[3] == "deep" then
	for _, name in { "Game", "Player", "Attack", "FlatBinaryHeap", "EngineConfig", "UnitGrid", "PseudoRandom" } do
		wrap("E." .. name, Harness.require(OF[name]))
	end
end
-- "paths" wraps the pathfinding modules.
if process.args[3] == "paths" then
	for _, name in { "AStar", "AStarWater", "AStarWaterBounded", "AStarWaterHierarchical", "AbstractGraph", "AbstractGraphAStar", "PathFinding", "SpatialQuery" } do
		local m = Harness.require(OF.Pathfinding[name])
		wrap("P." .. name, m)
		for key, inner in m do
			if type(inner) == "table" and key ~= "__index" then
				wrap("P." .. name .. "." .. key, inner)
			end
		end
	end
end

local runner = Runner.new({
	gameID = "bench-studio",
	nameBudgetMs = 4,
	mapFolder = Maps.World,
	gameConfig = {
		gameMap = "World",
		gameMapSize = "Normal",
		gameMode = "Free For All",
		gameType = "Public",
		difficulty = "Medium",
		bots = 400,
		nations = "default",
	},
})
runner:start()

-- Fingerprint: every tile's owner, then each player's troops and gold.
local function fingerprint(): number
	local game = runner.game
	local h = 0
	for t = 0, game:width() * game:height() - 1 do
		h = (h * 31 + game:ownerID(t)) % 2147483647
	end
	for _, p in game:allPlayers() do
		h = (h * 31 + math.floor(p:troops()) + math.floor(p:gold() % 1000003)) % 2147483647
	end
	return h
end
-- "trace" prints the fingerprint every 25 ticks, to find a divergence.
local TRACE = process.args[2] == "trace"

local samples = {}
local total = 0
local slowest: { { tick: number, ms: number, top: string } } = {}
for _ = 1, TICKS do
	table.clear(tickStats)
	local s = os.clock()
	runner:step()
	local ms = (os.clock() - s) * 1000
	total += ms
	table.insert(samples, ms)
	if TRACE and #samples % 25 == 0 then
		print(`{#samples}:{fingerprint()}`)
	end
	if SPIKES then
		local parts = {}
		for key, v in tickStats do
			table.insert(parts, { key = key, ms = v })
		end
		table.sort(parts, function(a, b)
			return a.ms > b.ms
		end)
		local top = {}
		for i = 1, math.min(6, #parts) do
			table.insert(top, string.format("%s %.0f", parts[i].key, parts[i].ms))
		end
		table.insert(slowest, { tick = #samples, ms = ms, top = table.concat(top, ", ") })
	end
end
if SPIKES then
	table.sort(slowest, function(a, b)
		return a.ms > b.ms
	end)
	for i = 1, math.min(15, #slowest) do
		local r = slowest[i]
		print(string.format("tick %4d %6.1f ms: %s", r.tick, r.ms, r.top))
	end
end
table.sort(samples)
print(string.format("%d ticks: mean %.1f ms, p50 %.1f, p95 %.1f, max %.1f", TICKS, total / TICKS, samples[math.floor(TICKS * 0.5)], samples[math.floor(TICKS * 0.95)], samples[TICKS]))

local rows = {}
for key, st in stats do
	table.insert(rows, { key = key, st = st })
end
table.sort(rows, function(a, b)
	return a.st.ms > b.st.ms
end)
print(string.format("%-58s %9s %10s %9s %9s", "function", "calls", "total ms", "ms/tick", "max ms"))
for i = 1, math.min(45, #rows) do
	local r = rows[i]
	print(string.format("%-58s %9d %10.0f %9.2f %9.2f", r.key, r.st.calls, r.st.ms, r.st.ms / TICKS, r.st.max))
end

print(string.format("fingerprint after %d ticks: %d (%d players alive)", TICKS, fingerprint(), #runner.game:players()))
