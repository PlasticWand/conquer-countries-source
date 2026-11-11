--!strict
-- Headless pixel preview only, not a Studio screenshot or simulation result.
-- lune run tests/OpenFrontRasterPreview <referenceRoot> <outputPrefix>
-- Outputs raw RGBA; encode as PNG externally without changing pixel colours.
local fs, luau, serde, process = require("@lune/fs"), require("@lune/luau"), require("@lune/serde"), require("@lune/process")
local H = luau.load(fs.readFile("tests/OpenFrontRasterHarness.luau"))()
local root = assert(process.args[1], "referenceRoot required")
local prefix = assert(process.args[2], "outputPrefix required")
local manifest = serde.decode("json", fs.readFile(`{root}/resources/maps/world/manifest.json`))
local w, h = manifest.map.width, manifest.map.height
local terrain = buffer.fromstring(fs.readFile(`{root}/resources/maps/world/map.bin`))
local sink = H.sink(w, h); local core = H.Core.new(terrain, w, h, sink.backend)
local function export(suffix: string)
	local rgba = buffer.create(w * h * 4)
	for _, image in sink.images do
		local page = image.page
		for row = 0, page.height - 1 do buffer.copy(rgba, ((page.y + row) * w + page.x) * 4, image.pixels, row * page.width * 4, page.width * 4) end
	end
	fs.writeFile(prefix .. suffix .. ".rgba", buffer.tostring(rgba))
end
H.drain(core); export("-terrain")
local states, players = buffer.create(w * h * 2), {}
for id = 1, 16 do
	table.insert(players, {id = `preview-{id}`, smallID = id, playerType = if id == 1 then "HUMAN" else "NATION"})
	local n = manifest.nations[1 + math.floor((id - 1) * #manifest.nations / 16)]
	local cx, cy = n.coordinates[1], n.coordinates[2]
	local radius = 28 + id % 4 * 7
	for y = math.max(0, cy - radius), math.min(h - 1, cy + radius) do
		for x = math.max(0, cx - radius), math.min(w - 1, cx + radius) do
			local tile = y * w + x; local tb = buffer.readu8(terrain, tile)
			if (x - cx) ^ 2 + (y - cy) ^ 2 <= radius ^ 2 and bit32.btest(tb, 128) and bit32.band(tb, 31) ~= 31 then
				buffer.writeu16(states, tile * 2, id)
			end
		end
	end
end
H.Core.setRoster(core, players); H.Core.setLocalPlayer(core, 1); H.Core.setHover(core, 4)
H.Core.applyTileStates(core, states); H.drain(core); export("-political")
H.Core.destroy(core)
print(serde.encode("json", {width = w, height = h, prefix = prefix, warning = "headless CPU raster; fake confirmed discs, no native display proof"}))
