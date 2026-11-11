-- lune run scripts/bench-nukes [atTick] [bomb] [profile]
-- Server tick cost of a nuke landing (Bruno, 2026-11-08: choppy when a nuke
-- or MIRV lands, mid-late game). A full-size World match with Medium nations
-- and tribes is played to atTick (default 3000, five minutes); then the
-- largest nation fires `bomb` (default MIRV; also "Atom Bomb", "Hydrogen
-- Bomb") at the second largest. Prints runner:step ms (mean/p95/max) for the
-- 300 ticks before launch and for each tick from launch until 60 ticks after
-- the last warhead lands, with the ticks above 25 ms listed.
-- With `profile`, every execution's tick and every nation-behaviour function
-- is timed (inclusive, so nested calls count in both) for the 300 ticks
-- before launch and for the landing window; the top 25 of each print.
-- Lune timings: relative, not Roblox server numbers.

local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local Runner = Harness.require(Shared.OpenFront.Runner)
local Construction = Harness.require(Shared.OpenFront.Executions.ConstructionExecution)

local atTick = tonumber(process.args[1]) or 3000
local bomb = process.args[2] or "MIRV"
local Maps = Harness.mount("src/maps", "OpenFrontMaps")
local profiling = process.args[3] == "profile"

-- name -> { n, ms }; `window` names the bucket set being filled.
local buckets: { [string]: { [string]: { n: number, ms: number, max: number } } } = {}
local window = "warmup"
local function wrapModule(prefix: string, mod: any, all: boolean)
	for key, fn in mod do
		if type(fn) == "function" and key ~= "new" and (all or key == "tick") then
			local label = prefix .. "." .. key
			mod[key] = function(...)
				local t = os.clock()
				local r = table.pack(fn(...))
				local b = buckets[window]
				if b then
					local stat = b[label]
					if stat == nil then
						stat = { n = 0, ms = 0, max = 0 }
						b[label] = stat
					end
					local d = (os.clock() - t) * 1000
					stat.n += 1
					stat.ms += d
					if d > stat.max then
						stat.max = d
					end
				end
				return table.unpack(r, 1, r.n)
			end
		end
	end
end
if profiling then
	local ex = Shared.OpenFront.Executions
	for name, node in rawget(ex, "children") do
		if rawget(node, "path") then
			local ok, mod = pcall(Harness.require, node)
			if ok and type(mod) == "table" then
				wrapModule(name, mod, name == "AiAttackBehavior" or name == "Util")
			end
		end
	end
	for name, node in rawget(ex.Nation, "children") do
		if rawget(node, "path") then
			local ok, mod = pcall(Harness.require, node)
			if ok and type(mod) == "table" then
				wrapModule(name, mod, true)
			end
		end
	end
	wrapModule("TransportShipUtils", Harness.require(Shared.OpenFront.TransportShipUtils), true)
	wrapModule("Game", Harness.require(Shared.OpenFront.Game), false)
	local G = Harness.require(Shared.OpenFront.Game)
	for _, key in { "executeNextTick", "conquerPlayer", "conquer" } do
		local fn = G[key]
		if type(fn) == "function" then
			local one = { [key] = fn }
			wrapModule("Game", one, true)
			G[key] = one[key]
		end
	end
end
local function report(name: string, ticks: number)
	local b = buckets[name]
	if b == nil then
		return
	end
	local rows = {}
	for label, stat in b do
		table.insert(rows, { label = label, ms = stat.ms, n = stat.n, max = stat.max })
	end
	table.sort(rows, function(x, y)
		return x.ms > y.ms
	end)
	print(`  top costs, {name} ({ticks} ticks): ms per tick (calls per tick)`)
	for i = 1, math.min(tonumber(process.args[4]) or 25, #rows) do
		local r = rows[i]
		print(string.format("    %-60s %7.2f  (%.1f)", r.label, r.ms / ticks, r.n / ticks))
	end
	table.sort(rows, function(x, y)
		return x.max > y.max
	end)
	print(`  slowest single calls, {name}: ms`)
	for i = 1, math.min(tonumber(process.args[4]) or 20, #rows) do
		local r = rows[i]
		print(string.format("    %-60s %7.1f", r.label, r.max))
	end
end

local runner = Runner.new({
	gameID = "bench-nukes",
	mapFolder = Maps.World,
	gameConfig = {
		gameMap = "World",
		gameMode = "Free For All",
		gameType = "Singleplayer",
		difficulty = "Medium",
		bots = 400,
		nations = "default",
	},
})
runner:addHuman("1", "Idle")
runner:start()
local game = runner.game
local map = game:map()
for tile = map:width() * map:height() - 1, 0, -1 do
	if map:isLand(tile) and not map:isImpassable(tile) and not map:hasOwner(tile) then
		runner:intent("1", { type = "spawn", tile = tile })
		break
	end
end

local function stats(list: { number }): string
	local sorted = table.clone(list)
	table.sort(sorted)
	local sum = 0
	for _, v in sorted do
		sum += v
	end
	if #sorted == 0 then
		return "none"
	end
	return string.format("n=%d mean=%.1f p95=%.1f max=%.1f ms", #sorted, sum / #sorted, sorted[math.max(1, math.ceil(#sorted * 0.95))], sorted[#sorted])
end

local before = {}
for tick = 1, atTick do
	if tick == atTick - 299 then
		window = "before"
		buckets.before = {}
	end
	local t = os.clock()
	runner:step()
	if tick > atTick - 300 then
		table.insert(before, (os.clock() - t) * 1000)
	end
end
print(`tick {atTick}, before launch: {stats(before)}`)
report("before", 300)
window = "after"
buckets.after = {}

local nations = {}
for _, p in game:players() do
	if p:type() == "NATION" and p:isAlive() then
		table.insert(nations, p)
	end
end
table.sort(nations, function(a, b)
	return a:numTilesOwned() > b:numTilesOwned()
end)
local launcher, target = nations[1], nations[2]
for _, sam in game:units("SAM Launcher") do
	if sam:owner() == target then
		sam:delete(false)
	end
end
launcher:addGold(100_000_000)
if #launcher:units("Missile Silo") == 0 then
	launcher:buildUnit("Missile Silo", launcher:tiles():values()[1], {})
end
local cities = target:units("City")
local aim = if #cities > 0 then cities[1]:tile() else target:tiles():values()[1]
print(`{launcher:name()} ({launcher:numTilesOwned()} tiles) fires {bomb} at {target:name()} ({target:numTilesOwned()} tiles)`)
game:addExecution(Construction.new(launcher, bomb, aim))

local after, slow = {}, {}
local quietSince = nil
for tick = 1, 1500 do
	local t = os.clock()
	runner:step()
	local ms = (os.clock() - t) * 1000
	table.insert(after, ms)
	if ms > 25 then
		table.insert(slow, string.format("+%d:%.0f", tick, ms))
	end
	local flying = #game:units(bomb) + #game:units("MIRV Warhead")
	if flying == 0 and tick > 20 then
		quietSince = quietSince or tick
		if tick - quietSince >= 60 then
			break
		end
	else
		quietSince = nil
	end
end
print(`after launch: {stats(after)}; {target:name()} now {target:numTilesOwned()} tiles`)
print(`ticks over 25 ms: {table.concat(slow, " ")}`)
report("after", #after)
