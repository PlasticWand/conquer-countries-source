-- lune run scripts/measure-net [lastTick] [gameType]
-- What each player receives (audit 2026-11): a full-size World match with
-- Medium nations and 400 tribes (as bench-nukes sets it up), one idle human.
-- Every tick the real Replication path runs (collect, then forViewer for the
-- human), and the delta's size on the wire is estimated field by field. At
-- minutes 1, 5 and 15 (ticks 600, 3000, 9000) it prints, for the 200 ticks
-- around each: bytes a second by field, the largest single tick, the cost of
-- collect/forViewer in ms, the snapshot's size by field, and the Lua heap.
--
-- Wire sizes follow Roblox's remote encoding as the community measured it
-- (not an official spec): 9 bytes a call; number 9; boolean 2; string and
-- buffer 2 + length (3 + length from 128 bytes); table 2 + its entries, a
-- dictionary entry being key + value. Buffers are also shown zlib-compressed,
-- as a stand-in for whatever Roblox's transport saves.
-- Lune timings: relative, not Roblox server numbers.

local process = require("@lune/process")
local serde = require("@lune/serde")
local Harness = require("../tests/harness")
local Shared = Harness.shared()
local Runner = Harness.require(Shared.OpenFront.Runner)
local Replication = Harness.require(Shared.OpenFront.Replication)

local lastTick = tonumber(process.args[1]) or 9100
local gameType = process.args[2] or "Singleplayer"
local Maps = Harness.mount("src/maps", "OpenFrontMaps")

local function varint(n: number): number
	local b = 1
	while n >= 128 do
		n //= 128
		b += 1
	end
	return b
end

local function wire(v: any): number
	local t = type(v)
	if t == "number" then
		return 9
	elseif t == "boolean" then
		return 2
	elseif t == "string" then
		return 1 + varint(#v) + #v
	elseif t == "buffer" then
		return 1 + varint(buffer.len(v)) + buffer.len(v)
	elseif t == "table" then
		local n = #v
		local total = 0
		if n > 0 then
			for i = 1, n do
				total += wire(v[i])
			end
			return 1 + varint(n) + total
		end
		local count = 0
		for k, x in v do
			count += 1
			total += wire(k) + wire(x)
		end
		return 1 + varint(count) + total
	end
	return 1
end

local function zlen(b: buffer): number
	if buffer.len(b) == 0 then
		return 0
	end
	return #serde.compress("zlib", buffer.tostring(b))
end

local runner = Runner.new({
	gameID = "bench-nukes",
	mapFolder = Maps.World,
	gameConfig = {
		gameMap = "World",
		gameMode = "Free For All",
		gameType = gameType,
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

local function kb(n: number): string
	return string.format("%.1f", n / 1024)
end

local function snapshotReport(tick: number)
	local t = os.clock()
	local snap = replicator:snapshot("1")
	local ms = (os.clock() - t) * 1000
	local rows = {}
	local total = 9
	for k, v in snap do
		local s = wire(k) + wire(v)
		total += s
		table.insert(rows, { k = k, s = s })
	end
	table.sort(rows, function(a, b)
		return a.s > b.s
	end)
	local parts = {}
	for i = 1, math.min(8, #rows) do
		table.insert(parts, `{rows[i].k} {kb(rows[i].s)}`)
	end
	print(`  snapshot at tick {tick}: {kb(total)} KB in {string.format("%.0f", ms)} ms (tileState zlib {kb(zlen(snap.tileState))} KB); {table.concat(parts, ", ")}`)
	print(`    units {#snap.units}, plans {#snap.plans}, railroads {#snap.railroads}, players {#snap.roster}`)
end

local WINDOWS = { { name = "minute 1", at = 600 }, { name = "minute 5", at = 3000 }, { name = "minute 15", at = 9000 } }
local HALF = 100
local window = nil
local acc: { [string]: number } = {}
local accZ = 0
local ticksIn = 0
local worst, worstTick = 0, 0
local collectMs, viewerMs, stepMs = {}, {}, {}
local counts = { stats = 0, units = 0, tileBytes = 0, names = 0 }

local function mean(list: { number }): (number, number)
	local sum, max = 0, 0
	for _, v in list do
		sum += v
		max = math.max(max, v)
	end
	return if #list > 0 then sum / #list else 0, max
end

local function flush(w: { name: string, at: number })
	local rows = {}
	local total = 0
	for k, s in acc do
		total += s
		table.insert(rows, { k = k, s = s })
	end
	table.sort(rows, function(a, b)
		return a.s > b.s
	end)
	local perSec = 10 / ticksIn
	print(`{w.name} (ticks {w.at - HALF + 1}..{w.at + HALF}): {kb(total * perSec)} KB/s to one player, worst tick {kb(worst)} KB (tick {worstTick})`)
	local parts = {}
	for _, r in rows do
		table.insert(parts, `{r.k} {kb(r.s * perSec)}`)
	end
	print(`  KB/s by field: {table.concat(parts, ", ")}`)
	print(`  tiles buffer zlib: {kb(accZ * perSec)} KB/s; per tick: stats rows {string.format("%.0f", counts.stats / ticksIn)}, unit records {string.format("%.0f", counts.units / ticksIn)}, ticks with names {counts.names}`)
	local sm, sx = mean(stepMs)
	local cm, cx = mean(collectMs)
	local vm, vx = mean(viewerMs)
	print(string.format("  ms per tick, mean (max): runner.step %.1f (%.0f), collect %.2f (%.1f), forViewer x1 %.3f (%.2f); live units %d; alive players %d", sm, sx, cm, cx, vm, vx, #game:units(), #game:players()))
	print(string.format("  server Lua heap (no forced GC): %.0f MB", gcinfo() / 1024))
	snapshotReport(w.at + HALF)
end

for tick = 1, lastTick do
	local t0 = os.clock()
	runner:step()
	local t1 = os.clock()
	local public = replicator:collect()
	local t2 = os.clock()
	local messages = game:drainMessages()
	local delta = replicator:forViewer(public, "1", messages)
	local t3 = os.clock()
	if window == nil then
		for _, w in WINDOWS do
			if tick == w.at - HALF + 1 then
				window = w
				acc, accZ, ticksIn, worst, worstTick = {}, 0, 0, 0, 0
				collectMs, viewerMs, stepMs = {}, {}, {}
				counts = { stats = 0, units = 0, tileBytes = 0, names = 0 }
			end
		end
	end
	if window ~= nil then
		local total = 9
		for k, v in delta do
			local s = wire(k) + wire(v)
			total += s
			acc[k] = (acc[k] or 0) + s
		end
		acc["(call)"] = (acc["(call)"] or 0) + 9
		accZ += zlen(delta.tiles)
		ticksIn += 1
		if total > worst then
			worst, worstTick = total, tick
		end
		-- (wire format 2: stats are packed rows; before it they were a list)
		local stats = delta.stats
		counts.stats += if type(stats) == "buffer" then buffer.len(stats) // Replication.STAT_ROW elseif stats then #stats else 0
		counts.units += #delta.units
		if delta.names then
			counts.names += 1
		end
		table.insert(stepMs, (t1 - t0) * 1000)
		table.insert(collectMs, (t2 - t1) * 1000)
		table.insert(viewerMs, (t3 - t2) * 1000)
		if tick == window.at + HALF then
			flush(window)
			window = nil
		end
	end
end
