--!strict
local fs, luau, serde = require("@lune/fs"), require("@lune/luau"), require("@lune/serde")
local H = luau.load(fs.readFile("tests/OpenFrontRasterHarness.luau"))()
local Core, Terrain = H.Core, H.Terrain
local roster = {{id = "human", smallID = 1, playerType = "HUMAN", cosmetics = {color = {color = "#773399"}}},
	{id = "nation", smallID = 2, playerType = "NATION", cosmetics = {color = {color = "#51aa77"}}}}
local function setup(w: number, h: number): any
	local terrain, states = buffer.create(w * h), buffer.create(w * h * 2)
	buffer.fill(terrain, 0, 128)
	local sink = H.sink(w, h)
	local core = Core.new(terrain, w, h, sink.backend)
	Core.setRoster(core, roster)
	return {core = core, sink = sink, terrain = terrain, states = states}
end
return function(t: any)
	t.test("OpenFront terrain matches copied TS for all byte values and live/fallback/override colours", function()
		local g = serde.decode("json", fs.readFile("tests/fixtures/OpenFrontTerrain.json"))
		for _, case in g.cases do
			local colors = if type(case.colors) == "table" then case.colors else nil
			local lut = Terrain.palette(colors)
			for i, expected in case.pixels do t.eq(buffer.readu8(lut, i - 1), expected, `terrain byte/channel {i}`) end
		end
		local bytes = buffer.create(256); for i = 0, 255 do buffer.writeu8(bytes, i, i) end
		t.eq(buffer.tostring(Terrain.buildTerrainRGBA(bytes, 16, 16, Terrain.defaults)), buffer.tostring(Terrain.palette(Terrain.defaults)))
		t.eq(Terrain.hexToRgb(" #4785b5 ")[3], 181); t.eq(Terrain.hexToRgb("#123"), nil)
	end)
	t.test("OpenFront full World and Giant page layouts preserve every source pixel", function()
		for _, dims in {{2000, 1000, 2}, {4108, 1948, 10}, {1024, 1024, 1}, {1025, 1, 2}} do
			local w, h = dims[1], dims[2]
			local sink = H.sink(w, h); local s = Core.new(buffer.create(w * h), w, h, sink.backend)
			t.eq(#s.pages, dims[3]); t.eq(Core.metrics(s).stride, 1)
			local area = 0; for _, p in s.pages do t.ok(p.width <= 1024 and p.height <= 1024); area += p.width * p.height end
			t.eq(area, w * h); Core.destroy(s)
		end
	end)
	t.test("OpenFront page scheduler touches at most one displayed image per step and drains fairly", function()
		local a = setup(1025, 64)
		local first = Core.step(a.core, 1e9, 1e9)
		t.eq(first.page, 1); for _, id in a.sink.writes do t.eq(id, 1) end
		table.clear(a.sink.writes)
		local second = Core.step(a.core, 1e9, 1e9)
		t.eq(second.page, 2); t.eq(a.core.pending, 0)
		for _, id in a.sink.writes do t.eq(id, 2) end
		t.eq(a.sink.pixel(1023, 63), a.sink.pixel(1024, 63)); Core.destroy(a.core)
	end)
	t.test("OpenFront dirty deltas across image/row/block boundaries equal a fresh full repaint", function()
		local a, b = setup(1027, 39), setup(1027, 39)
		for tile = 0, 1027 * 39 - 1 do buffer.writeu16(a.states, tile * 2, if tile % 1027 < 1024 then 1 else 2) end
		Core.applyTileStates(a.core, a.states); H.drain(a.core)
		local changed = {0, 31, 32, 1023, 1024, 1026, 1027, 1027 * 38 + 1026}
		for _, tile in changed do buffer.writeu16(a.states, tile * 2, 2 + 16384) end
		local data = buffer.create(9); buffer.writeu8(data, 5, 2); buffer.writeu8(data, 7, 2)
		Core.setRelations(a.core, {size = 3, data = data}); Core.setHover(a.core, 2)
		Core.applyTileStates(a.core, a.states, changed); H.drain(a.core)
		Core.setRelations(b.core, {size = 3, data = data}); Core.setHover(b.core, 2)
		Core.applyTileStates(b.core, a.states); H.drain(b.core)
		for y = 0, 38 do for x = 0, 1026 do t.eq(a.sink.pixel(x, y), b.sink.pixel(x, y), `delta pixel {x}/{y}`) end end
		local before = a.core.pending; Core.applyTileStates(a.core, a.states, {}); t.eq(a.core.pending, before)
		Core.destroy(a.core); Core.destroy(b.core)
	end)
	t.test("OpenFront political compositor matches shared shader equations including fallout and checker", function()
		local a = setup(19, 17)
		for tile = 0, 322 do
			local state = if tile % 19 < 9 then 1 else 2
			if tile % 7 == 0 then state += 16384 end
			if tile % 37 == 0 then state += 8192 end
			buffer.writeu16(a.states, tile * 2, state)
		end
		Core.applyTileStates(a.core, a.states); Core.setHover(a.core, 1)
		local data = buffer.create(9); buffer.writeu8(data, 5, 1); buffer.writeu8(data, 7, 1)
		Core.setRelations(a.core, {size = 3, data = data}); H.drain(a.core)
		local function owner(x: number, y: number): number
			if x < 0 or y < 0 or x >= 19 or y >= 17 then return 0 end
			return bit32.band(buffer.readu16(a.states, (y * 19 + x) * 2), 4095)
		end
		for y = 0, 16 do for x = 0, 18 do
			local id = owner(x, y); local raw = buffer.readu16(a.states, (y * 19 + x) * 2)
			local neighbours = {}; for _, d in {{0, -1}, {0, 1}, {-1, 0}, {1, 0}} do
				local other = owner(x + d[1], y + d[2]); table.insert(neighbours, {owner = other, relation = if other > 0 and other ~= id then 1 else 0})
			end
			local flags = H.Political.border(id, neighbours, id == 1, x, y, owner)
			local e = a.core.palette[id]
			local c = H.Political.rgba({owner = id, x = x, y = y, defended = bit32.btest(raw, 16384), hovered = id == 1, fallout = bit32.btest(raw, 8192)}, e.fill, e.border, flags)
			local packed = a.sink.pixel(x, y)
			for channel, base in {190, 220, 138} do
				local value = ({c.r, c.g, c.b})[channel]
				local expected = math.clamp(math.floor(value * 255 * c.a + base * (1 - c.a) + .5), 0, 255)
				t.eq(bit32.band(bit32.rshift(packed, (channel - 1) * 8), 255), expected)
			end
		end end
		Core.destroy(a.core)
	end)
	t.test("OpenFront interrupted block restarts after a confirmed delta and owns input buffers", function()
		local a, b = setup(32, 32), setup(32, 32)
		buffer.fill(a.states, 0, 0); buffer.writeu16(a.states, 0, 1)
		Core.applyTileStates(a.core, a.states)
		Core.step(a.core, 1e9, 1); t.ok(a.core.job ~= nil)
		buffer.writeu16(a.states, 0, 2 + 8192); Core.applyTileStates(a.core, a.states, {0})
		Core.applyTileStates(b.core, a.states)
		-- Mutation without apply cannot affect either renderer.
		buffer.writeu16(a.states, 0, 1); buffer.writeu8(a.terrain, 0, 31)
		H.drain(a.core); H.drain(b.core)
		for y = 0, 31 do for x = 0, 31 do t.eq(a.sink.pixel(x, y), b.sink.pixel(x, y)) end end
		Core.destroy(a.core); Core.destroy(b.core)
	end)
	t.test("OpenFront pattern pixels LUT budget terrain edits and own-border override remain source-driven", function()
		local a = setup(32, 32)
		local bits = buffer.create(1); buffer.writeu8(bits, 0, 10)
		local players = {{id = "p", smallID = 1, playerType = "HUMAN", cosmetics = {pattern = {colorPalette = {primaryColor = "#ff0000", secondaryColor = "#0000ff"}}},
			pattern = {width = 2, height = 2, scale = 0, bytes = bits}}}
		Core.setRoster(a.core, players); Core.setLocalPlayer(a.core, 1); a.core.paintLimit = 0
		buffer.writeu8(bits, 0, 0)
		for tile = 0, 1023 do buffer.writeu16(a.states, tile * 2, 1) end
		Core.applyTileStates(a.core, a.states); H.drain(a.core)
		t.ok(a.sink.pixel(10, 10) ~= a.sink.pixel(11, 10)); t.eq(a.sink.pixel(0, 0), 4294901760)
		t.eq(a.core.paintBytes, 0)
		local before = a.sink.pixel(10, 10); buffer.writeu8(a.terrain, 10 * 32 + 10, 128 + 64)
		Core.applyTerrain(a.core, a.terrain, {10 * 32 + 10}); H.drain(a.core); t.ok(a.sink.pixel(10, 10) ~= before)
		Core.destroy(a.core)
	end)
	t.test("OpenFront allocation sink errors preserve pending work and destruction is idempotent", function()
		local a = setup(33, 34)
		local write = a.core.sink.write; a.core.sink.write = function() error("allocation denied") end
		t.errors(function() Core.step(a.core, 1e9) end); t.ok(a.core.pending > 0)
		a.core.sink.write = write; H.drain(a.core)
		Core.destroy(a.core); Core.destroy(a.core); t.eq(a.sink.destroyed, 1); t.eq(a.sink.allocatedBytes, 0)
		t.eq(Core.metrics(a.core).cpuBufferBytes, 0)
		t.errors(function() Core.applyTileStates(a.core, a.states) end)
		t.errors(function() Core.new(buffer.create(0), 0, 1, a.sink.backend) end)
	end)
	t.test("OpenFront Roblox adapter schedules one image and camera seams stay closed without pixel writes", function()
		local env = H.adapter(); local renderer = env.Renderer.new(env.parent, buffer.create(1025 * 35), 1025, 35, {autoStep = false})
		renderer:step(1e9, 1e9); t.eq(#env.images, 1)
		renderer:step(1e9, 1e9); t.eq(#env.images, 2)
		local writes = #env.writes
		local view = table.clone(renderer.camera); view.scale = 1.37
		renderer:setCamera(view); renderer:pan(21, 13); renderer:zoom(300, 100, -100)
		view.scale = 8 -- no alias to the supplied view
		t.ok(renderer.camera.scale ~= 8); t.eq(#env.writes, writes)
		local left, right = renderer.displays[1].label, renderer.displays[2].label
		t.eq(left.Position.X.Offset + left.Size.X.Offset, right.Position.X.Offset)
		renderer:destroy(); renderer:destroy()
		for _, image in env.images do t.eq(image.destroyed, true) end
		t.eq(renderer.root.destroyed, true)
	end)
	t.test("OpenFront Roblox allocation refusal stops auto scheduling and releases the controller", function()
		local env = H.adapter(); env.failAllocation = true
		local errors = {}
		local renderer = env.Renderer.new(env.parent, buffer.create(64), 8, 8, {onError = function(err) table.insert(errors, err) end})
		env.render:Fire(); t.eq(renderer.destroyed, true); t.eq(#errors, 1)
		env.render:Fire(); t.eq(#errors, 1); t.eq(#env.images, 0)
		t.ok(renderer.lastError:find("allocation failed", 1, true) ~= nil)
		local second = H.adapter()
		local partial = second.Renderer.new(second.parent, buffer.create(1025), 1025, 1, {autoStep = false})
		partial:step(1e9, 1e9); t.eq(#second.images, 1)
		second.failAllocation = true; t.errors(function() partial:step(1e9, 1e9) end)
		t.eq(second.images[1].destroyed, true); t.eq(partial.destroyed, true)
	end)
end
