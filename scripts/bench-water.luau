-- lune run scripts/bench-water [atTick] [save|check]
-- The nation AI's boat-target cost (Bruno, 2026-11-08: choppy mid-late game
-- and when a nuke lands; the slowest server ticks were
-- AiAttackBehavior._findNearestIslandEnemy -> canBuildTransportShip ->
-- SpatialQuery.closestShoreByWater). Plays a full-size World match to atTick
-- (default 3000), then for the three largest nations asks
-- canBuildTransportShip toward every other player's first shore tile, as
-- _findNearestIslandEnemy would, timing each pathfinding layer (inclusive).
-- `save` writes every answer to tests/fixtures/WaterBench.answers.json;
-- `check` compares against it, so a speed-up must give identical answers.
-- Lune timings: relative, not Roblox server numbers.

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local Runner = Harness.require(Shared.OpenFront.Runner)
local TransportShipUtils = Harness.require(Shared.OpenFront.TransportShipUtils)
local SpatialQuery = Harness.require(Shared.OpenFront.Pathfinding.SpatialQuery)

local atTick = tonumber(process.args[1]) or 3000
local mode = process.args[2]
local Maps = Harness.mount("src/maps", "OpenFrontMaps")
local ANSWERS = "tests/fixtures/WaterBench.answers.json"

local stats: { [string]: { n: number, ms: number, max: number } } = {}
local function wrap(prefix: string, mod: any, keys: { string }?)
	for key, fn in mod do
		if type(fn) == "function" and key ~= "new" and (keys == nil or table.find(keys, key)) then
			local label = prefix .. "." .. key
			mod[key] = function(...)
				local t = os.clock()
				local r = table.pack(fn(...))
				local d = (os.clock() - t) * 1000
				local s = stats[label]
				if s == nil then
					s = { n = 0, ms = 0, max = 0 }
					stats[label] = s
				end
				s.n += 1
				s.ms += d
				s.max = math.max(s.max, d)
				return table.unpack(r, 1, r.n)
			end
		end
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
for _ = 1, atTick do
	runner:step()
end

local P = Shared.OpenFront.Pathfinding
local T = Harness.require(P.Transformers)
wrap("SpatialQuery", SpatialQuery)
wrap("MiniMap", T.MiniMap, { "findPath" })
wrap("ShoreCoercing", T.ShoreCoercing, { "findPath" })
wrap("Smoothing", T.Smoothing, { "findPath", "_smooth" })
wrap("ComponentCheck", T.ComponentCheck, { "findPath" })
wrap("HPA", Harness.require(P.AStarWaterHierarchical))
wrap("AbstractGraphAStar", Harness.require(P.AbstractGraphAStar), { "findPath", "_search" })
wrap("AStarWaterBounded", Harness.require(P.AStarWaterBounded), { "findPath", "searchBounded" })

local nations = {}
for _, p in game:players() do
	if p:type() == "NATION" and p:isAlive() then
		table.insert(nations, p)
	end
end
table.sort(nations, function(a, b)
	return a:numTilesOwned() > b:numTilesOwned()
end)

local answers: { string } = {}
local total = os.clock()
local calls, slowest = 0, 0
for i = 1, math.min(3, #nations) do
	local owner = nations[i]
	for _, p in game:players() do
		if p ~= owner and p:isAlive() then
			-- Their first shore border tile, as a landing to try.
			local shore = nil
			for _, t in p:borderTiles():values() do
				if game:isShore(t) then
					shore = t
					break
				end
			end
			if shore then
				owner._shoreByWater = nil -- every query fresh, as in a war
				local t = os.clock()
				local r = TransportShipUtils.canBuildTransportShip(game, owner, shore)
				local d = (os.clock() - t) * 1000
				calls += 1
				slowest = math.max(slowest, d)
				table.insert(answers, `{owner:id()}>{shore}={r}`)
			end
		end
	end
end
total = (os.clock() - total) * 1000
print(string.format("%d queries from the 3 largest nations (%s): %.0f ms total, %.2f ms each, slowest %.1f ms", calls, table.concat({ nations[1]:numTilesOwned(), nations[2]:numTilesOwned(), nations[3]:numTilesOwned() }, "/"), total, total / calls, slowest))
local rows = {}
for label, s in stats do
	table.insert(rows, { label = label, s = s })
end
table.sort(rows, function(a, b)
	return a.s.ms > b.s.ms
end)
for _, r in rows do
	print(string.format("  %-40s total %8.1f ms  n=%6d  max %7.1f ms", r.label, r.s.ms, r.s.n, r.s.max))
end

if mode == "save" then
	fs.writeFile(ANSWERS, serde.encode("json", answers))
	print(`saved {#answers} answers to {ANSWERS}`)
elseif mode == "check" then
	local saved = serde.decode("json", fs.readFile(ANSWERS))
	local diff = 0
	for i, a in answers do
		if saved[i] ~= a then
			diff += 1
			if diff <= 5 then
				print(`  differs: {saved[i]} -> {a}`)
			end
		end
	end
	print(if diff == 0 and #saved == #answers then `identical: {#answers} answers` else `DIFFERENT: {diff} of {#answers} (saved {#saved})`)
end
