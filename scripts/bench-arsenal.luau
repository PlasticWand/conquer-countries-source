-- lune run scripts/bench-arsenal [atTick] [perPlayer]
-- Server cost of the Arsenal with a lot of it in play (audit 2026-11). The
-- bench-nukes World match is played to atTick (default 3000). Then the ten
-- largest nations are given every Arsenal unlock and plenty of gold (their own
-- AI is switched off, so only these orders spend it), and each
-- orders `perPlayer` (default 20) Artillery, Coastal Batteries, Airfields and
-- Railguns on its own land through the real ConstructionExecution. After the
-- builds finish, for 600 ticks each of them fires an Air Strike and a
-- Railgun shot, drops Paratroopers, lights a Sabotage and digs Field Works
-- every 50 ticks. Prints runner:step ms for the 300 ticks before and for
-- the 600 loaded ticks, the Arsenal units alive, each Arsenal execution's own
-- tick time (inclusive), and Replication.collect's cost before and during.
-- Lune timings: relative, not Roblox server numbers.

local process = require("@lune/process")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local Runner = Harness.require(Shared.OpenFront.Runner)
local Replication = Harness.require(Shared.OpenFront.Replication)
local ArsenalUnits = Harness.require(Shared.OpenFront.ArsenalUnits)
local Ex = Shared.OpenFront.Executions
local Construction = Harness.require(Ex.ConstructionExecution)

local atTick = tonumber(process.args[1]) or 3000
local perPlayer = tonumber(process.args[2]) or 20
local Maps = Harness.mount("src/maps", "OpenFrontMaps")

local stats: { [string]: { n: number, ms: number, max: number } } = {}
local measuring = false
for _, name in { "ArtilleryExecution", "ArtilleryShellExecution", "CoastalBatteryExecution", "ShellExecution", "LauncherExecution", "StrikeExecution", "ParatroopersExecution", "SabotageExecution", "FieldWorksExecution", "SAMLauncherExecution", "DefensePostExecution", "PlayerExecution" } do
	local ok, mod = pcall(function()
		return Harness.require(Ex[name])
	end)
	if ok and type(mod) == "table" and type(mod.tick) == "function" then
		local fn = mod.tick
		local s = { n = 0, ms = 0, max = 0 }
		stats[name] = s
		mod.tick = function(...)
			if not measuring then
				return fn(...)
			end
			local t = os.clock()
			fn(...)
			local d = (os.clock() - t) * 1000
			s.n += 1
			s.ms += d
			if d > s.max then
				s.max = d
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
		extraWeapons = true,
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
local replicator = Replication.newReplicator(runner)

local function summary(list: { number }): string
	local sorted = table.clone(list)
	table.sort(sorted)
	local sum = 0
	for _, v in sorted do
		sum += v
	end
	return string.format("mean %.1f  p95 %.1f  max %.1f ms", sum / #sorted, sorted[math.max(1, math.ceil(#sorted * 0.95))], sorted[#sorted])
end

local function run(ticks: number, each: ((number) -> ())?): ({ number }, { number })
	local step, collect = {}, {}
	for i = 1, ticks do
		if each then
			each(i)
		end
		local t0 = os.clock()
		runner:step()
		local t1 = os.clock()
		replicator:collect()
		game:drainMessages()
		table.insert(step, (t1 - t0) * 1000)
		table.insert(collect, (os.clock() - t1) * 1000)
	end
	return step, collect
end

run(atTick - 300)
local beforeStep, beforeCollect = run(300)
print(`tick {atTick}: before, runner.step {summary(beforeStep)}; collect {summary(beforeCollect)}; units {#game:units()}`)

local nations = {}
for _, p in game:players() do
	if p:type() == "NATION" and p:isAlive() then
		table.insert(nations, p)
	end
end
table.sort(nations, function(a, b)
	return a:numTilesOwned() > b:numTilesOwned()
end)
local armed = {}
for i = 1, math.min(10, #nations) do
	local p = nations[i]
	local info = table.clone(p.playerInfo)
	local weapons = {}
	for _, key in ArsenalUnits.KEYS do
		weapons[key] = true
	end
	weapons.rapidReload = nil
	info.weapons = weapons
	p.playerInfo = info
	p:addGold(10_000_000_000)
	table.insert(armed, p)
end
-- Their AI stops (like a human's nation): with that much gold a nation's own
-- AI would fill the sky with bombs and the bench would measure those.
for _, e in game.execs do
	if e.nation ~= nil and e.player ~= nil and table.find(armed, e.player) then
		e.active = false
	end
end

-- Every 7th own tile in turn, so builds spread over the land; shore tiles for
-- the Coastal Battery. The engine's own canBuild decides.
local function order(p: any, unitType: string, want: number)
	local tiles = p:tiles():values()
	local placed = 0
	for i = 1, #tiles, 7 do
		if placed >= want then
			break
		end
		local tile = tiles[i]
		if (unitType ~= "Coastal Battery" or map:isShore(tile)) and p:canBuild(unitType, tile) ~= false then
			game:addExecution(Construction.new(p, unitType, tile))
			placed += 1
			-- (one order a tick each, so spacing rules see the last one)
			runner:step()
			replicator:collect()
			game:drainMessages()
		end
	end
end
for _, p in armed do
	for _, unitType in { "Artillery", "Coastal Battery", "Airfield", "Railgun" } do
		order(p, unitType, perPlayer)
	end
end
run(200) -- builds finish (15 s at most)

local function count(unitType: string): number
	return #game:units(unitType)
end
print(`armed {#armed} nations; alive now: Artillery {count("Artillery")}, Coastal Battery {count("Coastal Battery")}, Airfield {count("Airfield")}, Railgun {count("Railgun")}`)

local function enemyTile(p: any, i: number): number?
	local best = nil
	for k = 1, #nations do
		local other = nations[(i + k) % #nations + 1]
		if other ~= p and other:isAlive() and not p:isFriendly(other) and other:numTilesOwned() > 0 then
			best = other:tiles():values()[1]
			break
		end
	end
	return best
end

measuring = true
local fired = { strikes = 0 }
local step, collect = run(600, function(i: number)
	if i % 50 ~= 1 then
		return
	end
	for k, p in armed do
		if p:isAlive() then
			local target = enemyTile(p, k + i)
			if target then
				for _, unitType in { "Air Strike", "Railgun Shot", "Paratroopers", "Sabotage" } do
					game:addExecution(Construction.new(p, unitType, target, nil, nil, if unitType == "Paratroopers" then p:troops() * 0.2 else nil))
				end
				fired.strikes += 1
			end
			local own = p:borderTiles():values()[1]
			if own then
				game:addExecution(Construction.new(p, "Field Works", own))
			end
		end
	end
end)
measuring = false
print(`loaded 600 ticks: runner.step {summary(step)}; collect {summary(collect)}; units {#game:units()}`)
print(`  orders sent: {fired.strikes} rounds of Air Strike, Railgun Shot, Paratroopers, Sabotage and Field Works`)
print(`  alive at the end: Artillery {count("Artillery")}, Coastal Battery {count("Coastal Battery")}, Airfield {count("Airfield")}, Railgun {count("Railgun")}, Field Works {count("Field Works")}`)
local rows = {}
for name, s in stats do
	table.insert(rows, { name = name, s = s })
end
table.sort(rows, function(a, b)
	return a.s.ms > b.s.ms
end)
print("  execution tick time over the loaded ticks: ms per tick (calls per tick, slowest call ms)")
for _, r in rows do
	print(string.format("    %-28s %7.3f  (%.1f, %.2f)", r.name, r.s.ms / 600, r.s.n / 600, r.s.max))
end
