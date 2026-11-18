--!strict
-- Headless image sink: real rectangular buffer copies, no native/GPU claim.
local fs, luau = require("@lune/fs"), require("@lune/luau")
local Harness = luau.load(fs.readFile("tests/harness.luau"))()
local root = Harness.mount("src/client/Map/OpenFront", "OpenFront")
local H = {Core = Harness.require(root.RasterCore), Terrain = Harness.require(root.TerrainColors),
	Political = Harness.require(root.PoliticalColors), Colors = Harness.require(root.PlayerColors), ColorMath = Harness.require(root.ColorMath)}
function H.sink(width: number, height: number): any
	local s: any = {images = {}, writes = {}, destroyed = 0, allocatedBytes = 0}
	s.backend = {write = function(page, x, y, w, h, pixels)
		assert(page.width <= 1024 and page.height <= 1024 and x >= 0 and y >= 0 and x + w <= page.width and y + h <= page.height)
		assert(buffer.len(pixels) == w * h * 4)
		local image = s.images[page.id]
		if not image then image = {page = page, pixels = buffer.create(page.width * page.height * 4)}; s.images[page.id] = image; s.allocatedBytes += buffer.len(image.pixels) end
		for row = 0, h - 1 do buffer.copy(image.pixels, ((y + row) * page.width + x) * 4, pixels, row * w * 4, w * 4) end
		table.insert(s.writes, page.id)
	end, destroy = function() s.destroyed += 1; table.clear(s.images); table.clear(s.writes); s.allocatedBytes = 0 end}
	s.pixel = function(x: number, y: number): number
		assert(x >= 0 and y >= 0 and x < width and y < height)
		local id = math.floor(y / 1024) * math.ceil(width / 1024) + math.floor(x / 1024) + 1
		local image = s.images[id]
		return if image then buffer.readu32(image.pixels, ((y - image.page.y) * image.page.width + x - image.page.x) * 4) else 0
	end
	return s
end
function H.drain(core: any, budget: number?): {number}
	local times = {}
	while H.Core.hasPending(core) do
		assert(#times < 100000, "raster queue failed to drain")
		local result = H.Core.step(core, budget or 2)
		table.insert(times, result.ms)
	end
	return times
end
function H.adapter(): any
	Harness.shared() -- SceneOverlay reads the shared strike presentation specs
	local roblox = require("@lune/roblox")
	local V2, U2 = roblox.Vector2, roblox.UDim2
	local objects, images, writes = {}, {}, {}
	local function signal(): any
		local listeners = {}
		return {Connect = function(_, callback)
			local slot = {callback = callback, connected = true}; table.insert(listeners, slot)
			return {Disconnect = function() slot.connected = false end}
		end, Fire = function(_, ...)
			for _, slot in table.clone(listeners) do if slot.connected then slot.callback(...) end end
		end}
	end
	local function instance(class: string): any
		local o: any = {ClassName = class, AbsoluteSize = V2.new(844, 390), AbsolutePosition = V2.new(17, 42), signals = {}, Destroying = signal(), destroyed = false}
		o.GetPropertyChangedSignal = function(_, key) o.signals[key] = o.signals[key] or signal(); return o.signals[key] end
		o.Destroy = function() if o.destroyed then return end; o.destroyed = true; o.Destroying:Fire() end
		table.insert(objects, o); return o
	end
	local render = signal()
	local env: any = {objects = objects, images = images, writes = writes, render = render, failAllocation = false}
	local asset = {CreateEditableImage = function(_, options)
		if env.failAllocation then return nil end
		assert(options.Size.X <= 1024 and options.Size.Y <= 1024)
		local image: any = {Size = options.Size, destroyed = false}
		image.WritePixelsBuffer = function(_, pos, size, pixels)
			assert(not image.destroyed and pos.X + size.X <= image.Size.X and pos.Y + size.Y <= image.Size.Y)
			assert(buffer.len(pixels) == size.X * size.Y * 4); table.insert(writes, image)
		end
		image.Destroy = function() image.destroyed = true end
		table.insert(images, image); return image
	end}
	local module = luau.load(fs.readFile("src/client/Map/OpenFront/EditableRenderer.luau"), {debugName = "EditableRenderer",
		environment = {script = root.EditableRenderer, require = Harness.require,
			game = {GetService = function(_, service) if service == "AssetService" then return asset elseif service == "RunService" then return {RenderStepped = render}
				elseif service == "UserInputService" then return {TouchEnabled=false} end; error(service) end},
			Instance = {new = instance}, Vector2 = V2, UDim2 = U2, Color3 = roblox.Color3, Enum = roblox.Enum, Content = {fromObject = function(o) return o end}},
		injectGlobals = true})()
	env.Renderer, env.parent = module, instance("Frame")
	return env
end
return H
