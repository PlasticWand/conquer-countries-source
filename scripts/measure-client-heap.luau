-- lune run scripts/measure-client-heap [touch]
-- How much Lua heap the match's client side holds (audit 2026-11; Bruno's
-- iPhone shows 430-456 MB "lua" all match). Builds the real map renderer on
-- the full World map through the renderer tests' harness (fake Instances,
-- tests/OpenFrontEffectsHarness.luau), with 473 players, 600 units and every
-- land tile owned, runs it to ready and for 600 frames of a busy match, and
-- prints the Lua heap at each stage beside the renderer's own byte counts.
-- `touch` asks for the phone's 2x coast art instead of the desktop's 4x.
-- Limits: fake Instances are Lua tables here (real ones are not Lua heap), so
-- this is an upper bound for the renderer; the HUD and menus are not built.

local fs, luau, rb = require("@lune/fs"), require("@lune/luau"), require("@lune/roblox")
local process = require("@lune/process")

local function heap(): number
	return gcinfo() / 1024
end

local h0 = heap()
local make = luau.load(fs.readFile("tests/OpenFrontEffectsHarness.luau"))()
local terrain = buffer.fromstring(fs.readFile("../reference/openfront-v0.35.2/resources/maps/world/map.bin"))
local e = make()
if process.args[1] == "touch" then
	-- (the renderer picks its coast scale from the touch flag)
	pcall(function()
		e.touch = true
	end)
end
local h1 = heap()
local state = e.client()
state.width, state.height, state.you, state.startTick, state.tick = 2000, 1000, 1, 0, 2000
state.tileState = buffer.create(2000 * 1000 * 2)
state.names, state.players, state.rosterOrder, state.units = {}, {}, {}, {}
local roster = {}
local N = 473
for id = 1, N do
	local kind = if id == 1 then "HUMAN" elseif id <= 73 then "NATION" else "BOT"
	state.players[id] = { id = `p{id}`, smallID = id, name = `Player {id}`, displayName = `Player {id}`, type = kind, troops = 100000, alive = true, tiles = 1000, allies = {}, embargoes = {} }
	state.rosterOrder[id] = id
	roster[id] = { id = `p{id}`, smallID = id, playerType = kind }
	state.names[id] = { x = (id - 1) % 30 * 65 + 30, y = math.floor((id - 1) / 30) * 60 + 30, size = 12 }
end
for tile = 0, 2000000 - 1 do
	if bit32.btest(buffer.readu8(terrain, tile), 128) then
		buffer.writeu16(state.tileState, tile * 2, 1 + (math.floor(tile / 2000 / 40) * 19 + math.floor(tile % 2000 / 60)) % N)
	end
end
local kinds = { "City", "Port", "Factory", "Defense Post", "SAM Launcher", "Missile Silo" }
for id = 1, 600 do
	local tile = (25 + math.floor((id - 1) / 30) * 48) * 2000 + 25 + (id - 1) % 30 * 65
	state.units[id] = {
		id = id,
		type = if id <= 480 then kinds[(id - 1) % 6 + 1] else (if id <= 590 then "Trade Ship" else "Atom Bomb"),
		owner = (id - 1) % N + 1,
		tile = tile,
		lastTile = tile,
		active = true,
		level = 1,
		underConstruction = false,
		targetTile = tile + 10,
		missileTimerQueue = {},
	}
end
local h2 = heap()
local parent = e.instance("Frame")
parent.AbsoluteSize = rb.Vector2.new(if process.args[1] == "touch" then 844 else 1530, if process.args[1] == "touch" then 390 else 613)
local r = e.Renderer.new(parent, terrain, 2000, 1000, { autoStep = false, firstPaint = "full" })
r:setRoster(roster)
r:applyTileStates(state.tileState)
r:attachState(state)
local frames = 0
repeat
	e.now += 1 / 60
	r:step()
	frames += 1
until r:isReady() or frames > 20000
local h3 = heap()
-- A busy stretch: 3,000 ownership changes and every ship moving, six times a second.
for i = 1, 600 do
	e.now += 1 / 60
	if i % 6 == 0 then
		state.tick += 1
		local moved = {}
		for id = 481, 600 do
			local u = state.units[id]
			u.lastTile, u.tile = u.tile, (u.tile + 1) % 2000000
			table.insert(moved, id)
		end
		state.UnitsMoved:Fire(moved, state.tick)
		local refs = {}
		for k = 1, 3000 do
			local tile = (i * 7919 + k * 104729) % 2000000
			if bit32.btest(buffer.readu8(terrain, tile), 128) then
				buffer.writeu16(state.tileState, tile * 2, 1 + (i + k) % N)
				table.insert(refs, tile)
			end
		end
		r:applyTileStates(state.tileState, refs)
	end
	r:step()
end
local h4 = heap()
local m = r:metrics()
local function mb(key: string): string
	return string.format("%.1f", (m[key] or 0) / 1048576)
end
print(string.format("Lua heap, MB: start %.0f; harness loaded %.0f; state built %.0f; renderer ready %.0f (after %d frames); after 600 busy frames %.0f", h0, h1, h2, h3, frames, h4))
print(string.format("  renderer adds about %.0f MB at ready and %.0f MB after the busy stretch (no forced GC, so this includes garbage not yet collected)", h3 - h2, h4 - h2))
print(`  renderer's own counts, MB: cpu buffers {mb("cpuBufferBytes")}, coast cpu {mb("coastCpuBufferBytes")}, raster backing {mb("rasterBackingBytes")}, coast native {mb("coastNativePixelBytes")}, structure atlas {mb("structureAtlasPixelBytes")}`)
print(`  views: units {m.unitViews}, names {m.nameViews}, map gui objects {m.mapGuiObjects}`)
