--!strict
-- Fixed synthetic overlay workload on real World terrain. Unpaced desktop
-- Lua/property timings exclude native layout, uploads, GPU and phone hardware.
local fs, luau, rb, serde = require("@lune/fs"), require("@lune/luau"), require("@lune/roblox"), require("@lune/serde")
local source = fs.readFile("tests/OpenFrontEffectsHarness.luau")
source = source:gsub("local o: any = {ClassName=class", "local values: any = {ClassName=class")
source = source:gsub("o.GetPropertyChangedSignal=function", [[local o: any = setmetatable({}, {__index=values,__newindex=function(_,key,value)
	if type(value)~='function' then env.propertyWrites=(env.propertyWrites or 0)+1 end
	values[key]=value
end})
o.GetPropertyChangedSignal=function]])
source = source:gsub("node==root.BuildPreviewController or node==root.MapInput then",
	"node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then")
local make = luau.load(source)()
local flagArt = luau.load(fs.readFile("src/client/Ui/FlagArt.luau"))()
local terrain = buffer.fromstring(fs.readFile("../reference/openfront-v0.35.2/resources/maps/world/map.bin"))
local w, h = 2000, 1000
local function quantile(values, fraction)
	if #values == 0 then return 0 end
	table.sort(values)
	return values[math.clamp(math.ceil(#values * fraction), 1, #values)]
end
for _, viewport in {{874, 402}, {844, 390}, {667, 375}} do
	local e, roster = make(), {}
	local state = e.client()
	state.width, state.height, state.you, state.startTick, state.tick = w, h, 1, 200, 2000
	state.tileState = buffer.create(w * h * 2)
	state.players, state.rosterOrder, state.names, state.units = {}, {}, {}, {}
	for id = 1, 473 do
		local kind = if id == 1 then "HUMAN" elseif id <= 73 then "NATION" else "BOT"
		local x, y = (id - 1) % 43 * 46 + 20, math.floor((id - 1) / 43) * 87 + 20
		state.players[id] = {id = `p{id}`, smallID = id, name = `Player {id}`, displayName = `Player {id}`,
			type = kind, troops = 100000, alive = true, tiles = 1000, allies = {}, embargoes = {}, flag = "us"}
		state.rosterOrder[id], state.names[id] = id, {x = x, y = y, size = 20}
		roster[id] = {id = `p{id}`, smallID = id, playerType = kind}
	end
	for tile = 0, w * h - 1 do
		local byte = buffer.readu8(terrain, tile)
		if bit32.btest(byte, 128) and bit32.band(byte, 31) ~= 31 then
			buffer.writeu16(state.tileState, tile * 2, 1 + math.floor((tile % w) / 46) % 43 + math.floor(math.floor(tile / w) / 87) % 11 * 43)
		end
	end
	local kinds = {"City", "Port", "Factory", "Defense Post", "SAM Launcher", "Missile Silo"}
	for id = 1, 150 do
		state.units[id] = {id = id, type = kinds[(id - 1) % 6 + 1], owner = id % 473 + 1,
			tile = id * 12347 % (w * h), active = true, level = 1}
	end
	for id = 151, 250 do
		state.units[id] = {id = id, type = if id <= 240 then "Transport" else "Atom Bomb", owner = id % 473 + 1,
			tile = id * 12347 % (w * h), lastTile = id * 12347 % (w * h), active = true, level = 1, targetTile = 300000 + id}
	end
	local parent = e.instance("Frame")
	parent.AbsoluteSize = rb.Vector2.new(viewport[1], viewport[2])
	parent.AbsolutePosition = rb.Vector2.new(24, 18) -- explicit offset; no assumed Roblox inset
	local r = e.Renderer.new(parent, terrain, w, h, {autoStep = false, firstPaint = "full"})
	r.flagArt = flagArt; r:setRoster(roster); r:applyTileStates(state.tileState); r:attachState(state)
	repeat e.now += 1 / 60; r:step() until r:isReady()
	local function frame(i)
		e.now += 1 / 60
		if i % 6 == 0 then
			state.tick += 1
			local moved = {}
			for id = 151, 250 do
				local u = state.units[id]; u.lastTile, u.tile = u.tile, (u.tile + 1) % (w * h)
				table.insert(moved, id)
			end
			state.UnitsMoved:Fire(moved, state.tick)
			for _, p in state.players do p.troops += 1 end
			state.StatsChanged:Fire(); state.TickApplied:Fire(state.tick)
		end
		local start = os.clock(); r:step(); return (os.clock() - start) * 1000
	end
	for _, mode in {"fit", "zoom4"} do
		if mode == "zoom4" then r:goTo(1000, 500, 4); for _ = 1, 1000 do e.render:Fire(.016); if not r.goToTarget then break end end end
		for i = 1, 120 do frame(i) end
		e.propertyWrites = 0; r:resetTimings()
		local samples, allocated = {}, #e.objects
		for i = 1, 600 do table.insert(samples, frame(i)) end
		local names, flags, structures, mobiles, gui, namePixels, flagHeights, structurePixels = 0, 0, 0, 0, 0, {}, {}, {}
		for _, v in r.scene.nameViews do
			if v.root.Visible then
				names += 1; table.insert(namePixels, v.pixels)
				if v.flag and v.flag.Visible then flags += 1; table.insert(flagHeights, v.flagH or v.flag.Size.Y.Offset * v.scale.Scale) end
			end
		end
		for _, v in r.scene.unitViews do
			if v.root.Visible then
				if v.structure then structures += 1; table.insert(structurePixels, v.root.Size.X.Offset) else mobiles += 1 end
			end
		end
		for _, o in e.objects do
			if not o.destroyed and (o.ClassName == "Frame" or o.ClassName == "ImageLabel" or o.ClassName == "TextLabel") then gui += 1 end
		end
		local metrics = r:metrics()
		print(serde.encode("json", {viewport = viewport, mode = mode, scenario = "World, 473 fixed size-20 anchors/flags, 150 structures, 100 mobiles including 10 nukes, 10Hz updates; 120 warmup + 600 unpaced logical frames",
			stepP50Ms = quantile(samples, .5), stepP95Ms = quantile(samples, .95), stepMaxMs = quantile(samples, 1),
			propertyWrites = e.propertyWrites, newInstances = #e.objects - allocated, liveMapGui = gui,
			visibleNames = names, visibleFlags = flags, visibleStructures = structures, visibleMobiles = mobiles,
			namePixelsP50 = quantile(namePixels, .5), flagHeightP50 = quantile(flagHeights, .5), structurePixelsP50 = quantile(structurePixels, .5), metrics = metrics}))
	end
	r:destroy()
	for _, image in e.images do assert(image.destroyed, "native image leaked") end
	for _, o in e.objects do if o ~= parent and o ~= e.mapGui then assert(o.destroyed, "map object leaked") end end
end
