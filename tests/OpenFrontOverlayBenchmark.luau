--!strict
-- Headless GUI-property benchmark. This excludes Roblox layout/render/GPU.
local fs, luau, roblox = require("@lune/fs"), require("@lune/luau"), require("@lune/roblox")
local Harness = luau.load(fs.readFile("tests/harness.luau"))()
local root = Harness.mount("src/client/Map/OpenFront", "OpenFront")
local V2, U2 = roblox.Vector2, roblox.UDim2
local count = 0
local objects = {}
local function instance(class: string): any
	count += 1
	local o: any = {ClassName = class, Visible = true, destroyed = false}
	o.Destroy = function() o.destroyed = true end
	o.FindFirstChild = function(_, name)
		for _, child in objects do if child.Parent==o and child.Name==name and not child.destroyed then return child end end
		return nil
	end
	table.insert(objects,o)
	return o
end
local image = {WritePixelsBuffer = function(_, _pos, size, pixels)
	assert(buffer.len(pixels) == size.X * size.Y * 4)
end, Destroy = function() end}
local nativeEnv = {
		game = {GetService = function(_, name)
			if name == "EncodingService" then return luau.load(fs.readFile('tests/OpenFrontEncodingHarness.luau'))() end
			assert(name == "AssetService"); return {CreateEditableImage = function() return image end}
		end},
		Instance = {new = instance}, Vector2 = V2, UDim = roblox.UDim, UDim2 = U2, Color3 = roblox.Color3, Enum = roblox.Enum,
		Content = {fromObject = function(o) return o end}}
local nativeModules = {}
local function loadNative(node: any): any
	if node ~= root.SceneOverlay and node ~= root.EffectOverlay and node ~= root.NameStatusOverlay then return Harness.require(node) end
	if nativeModules[node] then return nativeModules[node] end
	local env = table.clone(nativeEnv); env.script,env.require = node,loadNative
	local module = luau.load(fs.readFile(node.path),{environment=env,injectGlobals=true})()
	nativeModules[node] = module; return module
end
local Scene = loadNative(root.SceneOverlay)
local width, height = 2000, 1000
local terrain = buffer.create(width * height)
local state = buffer.create(width * height * 2)
local palette = {}
for id = 1, 10 do palette[id] = {fill = {r = .2 + id * .05, g = .55, b = .4}, border = {r = .8, g = .8, b = .8}} end
local camera = {width = width, height = height, viewportWidth = 844, viewportHeight = 390,
	left = 0, top = 0, offsetX = (width - 844) / 8, offsetY = (height - 390) / 8, scale = 4}
local core = Harness.require(root.RasterCore).new(terrain,width,height,{write=function() end,destroy=function() end})
core.tileState,core.palette,core.localPlayer = state,palette,1
local renderer = {root = instance("Frame"), camera = camera, core = core}
local scene = Scene.new(renderer)
scene:setLocalPlayer(1)
local roster, anchors = {}, {}
for id = 1, 400 do
	local x, y = (id - 1) % 40 * 50 + 25, math.floor((id - 1) / 40) * 100 + 50
	roster[id] = {smallID = id, id = `tribe-{id}`, name = `Tribe {id}`, displayName = `Tribe {id}`,
		alive = true, troops = 100000 + id * 37, type = "BOT"}
	anchors[id] = {x = x, y = y, size = 20}
end
scene:setRoster(roster)
scene:setNameAnchors(anchors)
local units = {}
local kinds = {"City", "Port", "Factory", "Defense Post", "SAM Launcher", "Missile Silo"}
for id = 1, 150 do
	local x, y = 880 + id % 30 * 8, 435 + math.floor(id / 30) * 15
	units[id] = {id = id, type = kinds[id % 6 + 1], owner = id % 10 + 1,
		tile = y * width + x, lastTile = y * width + x, level = id % 4 + 1,
		active = true, health = nil, underConstruction = false}
end
local mobiles = {"Transport", "Trade Ship", "Warship", "Shell", "SAMMissile", "Atom Bomb", "Hydrogen Bomb", "MIRV Warhead", "Train"}
for id = 151, 250 do
	local x, y = 890 + id % 25 * 8, 465 + math.floor((id - 150) / 25) * 12
	units[id] = {id = id, type = mobiles[id % #mobiles + 1], owner = id % 10 + 1,
		tile = y * width + x, lastTile = y * width + x - 1, level = 1, active = true,
		trainType = "Engine", health = 80, maxHealth = 100, warship = {veterancy = 2},
		targetTile = (y + 10) * width + x, waitTicks = 0}
end
scene:setUnits(units)
local track = {}
for x = 880, 1100 do table.insert(track, 500 * width + x) end
scene:setRailroads({[1] = track})
local samples = {}
for frame = 1, 240 do
	local t0 = os.clock()
	scene:step()
	samples[frame] = (os.clock() - t0) * 1000
	if frame % 6 == 0 then
		for id = 151, 250 do units[id].lastTile = units[id].tile; units[id].tile += 1 end
		scene:setTick(frame)
	end
end
table.sort(samples)
local function percentile(p: number): number return samples[math.ceil(p * #samples)] end
print(`OpenFront GUI-property harness, full World; 150 structures, 100 mobiles, 400 name anchors, one 221-tile rail; 844×390 @4px/tile`)
print(string.format("p50 %.3f ms, p95 %.3f ms, max %.3f ms; instances %d, rail segments %d, atlas 0.38 MiB",
	percentile(.5), percentile(.95), samples[#samples], count, scene:metrics().railSegments))
camera.scale, camera.offsetX, camera.offsetY = 6, (width - 844) / 12, (height - 390) / 12
scene:setCamera()
local detail = {}
for frame = 1, 90 do
	local t0 = os.clock(); scene:step(); detail[frame] = (os.clock() - t0) * 1000
end
table.sort(detail)
print(string.format("rail detail @6px/tile, same 221-tile rail: p50 %.3f ms, p95 %.3f ms, max %.3f ms; visible rail cells %d, instances %d",
	detail[45], detail[86], detail[#detail], scene:metrics().visibleRailSegments, count))
camera.scale, camera.offsetX, camera.offsetY = 4, (width - 844) / 8, (height - 390) / 8
scene:setCamera()
-- Current production fallback until authoritative name anchors arrive.
for y = 0, height - 1 do for x = 0, width - 1 do
	local owner = math.floor(x / 50) + math.floor(y / 100) * 40 + 1
	buffer.writeu16(state, (y * width + x) * 2, owner)
end end
scene.nameAnchorMode, scene.namesDirty, scene.nameScan = "local", true, nil
local fallback = {}
local frame = 0
repeat
	frame += 1
	assert(frame <= 1000, "name fallback failed to complete")
	local t0 = os.clock(); scene:step(); fallback[frame] = (os.clock() - t0) * 1000
until scene.nameScan == nil and frame >= 180
table.sort(fallback)
print(string.format("with 400-player local largest-border name scan: p50 %.3f ms, p95 %.3f ms, max %.3f ms; completed in %d frames",
	fallback[math.ceil(#fallback*.5)], fallback[math.ceil(#fallback*.95)], fallback[#fallback], frame))
-- Presentation-only stress; these explicit confirmed-death fixtures do not
-- establish that the current Replication adapter delivers inactive records.
local effects=scene.effects
local bonuses={}
for i=1,25 do
	effects.state:deadUnit({type='Hydrogen Bomb',tile=width*(490+i%5)+990+i%10,reachedTarget=true},0)
	table.insert(bonuses,{tile=width*500+1000,gold=25000})
end
effects.state:bonuses(bonuses,0)
local atlasStart=os.clock(); effects:prepare()
local atlasMs=(os.clock()-atlasStart)*1000
local fxSamples,maxNew,peakViews={},0,0
for i=1,120 do
	local before=count
	local start=os.clock(); effects:step(i*1000/60); fxSamples[i]=(os.clock()-start)*1000
	-- Rings create their stroke/corner with the view, so count view roots.
	local views=#effects.sprites+#effects.rings+#effects.popups+#effects.glows
	maxNew=math.max(maxNew,views-peakViews); peakViews=math.max(peakViews,views)
	assert(count-before<=75,'FX view creation budget exceeded')
end
table.sort(fxSamples)
effects:step(10000)
assert(#effects.state.sprites==0 and #effects.state.shockwaves==0 and #effects.state.popups==0)
print(string.format('25 simultaneous hydrogen impacts + 25 bonuses, GUI shim only: atlas %.3f ms, p50 %.3f ms, p95 %.3f ms, max %.3f ms; peak pooled views %d, max new views/frame %d; expired at 10s',
	atlasMs,fxSamples[60],fxSamples[114],fxSamples[120],peakViews,maxNew))
scene:destroy()
