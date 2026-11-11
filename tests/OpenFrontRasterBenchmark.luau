--!strict
-- lune run tests/OpenFrontRasterBenchmark [referenceRoot] [giant]
-- Raw map loading and synthetic confirmed-state setup are excluded from timings.
-- Sink copies pixels like WritePixelsBuffer but cannot measure native/GPU/phone cost.
local fs, luau, serde, process = require("@lune/fs"), require("@lune/luau"), require("@lune/serde"), require("@lune/process")
local H = luau.load(fs.readFile("tests/OpenFrontRasterHarness.luau"))()
local Core = H.Core
local root = process.args[1] or "../reference/openfront-v0.35.2"
local function stats(times: {number}): any
	if #times == 0 then return {} end
	local sorted = table.clone(times); table.sort(sorted)
	local total = 0; for _, v in sorted do total += v end
	return {p50 = sorted[math.max(1, math.ceil(#sorted * .5))], p95 = sorted[math.max(1, math.ceil(#sorted * .95))], max = sorted[#sorted], cpuMs = total, frames = #times}
end
local function run(dir: string, size: string)
	local manifest = serde.decode("json", fs.readFile(`{root}/resources/maps/{dir}/manifest.json`))
	local meta = manifest[size]; local w, h = meta.width, meta.height
	local terrain = buffer.fromstring(fs.readFile(`{root}/resources/maps/{dir}/{size}.bin`))
	local sink = H.sink(w, h)
	local started = os.clock(); local core = Core.new(terrain, w, h, sink.backend); local constructMs = (os.clock() - started) * 1000
	local cold = stats(H.drain(core))
	local roster = {{id = "human", smallID = 1, playerType = "HUMAN"}}
	for id = 2, 400 do table.insert(roster, {id = `tribe-{id}`, smallID = id, playerType = "BOT"}) end
	started = os.clock(); Core.setRoster(core, roster); local rosterMs = (os.clock() - started) * 1000
	local states, land = buffer.create(w * h * 2), {}
	for tile = 0, w * h - 1 do
		local tb = buffer.readu8(terrain, tile)
		if bit32.btest(tb, 128) and bit32.band(tb, 31) ~= 31 then
			local x, y = tile % w, math.floor(tile / w)
			buffer.writeu16(states, tile * 2, 1 + math.floor(x / 50) % 40 + math.floor(y / 100) % 10 * 40)
			table.insert(land, tile)
		end
	end
	local relations = buffer.create(1024 * 1024)
	Core.setRelations(core, {size = 1024, data = relations}); Core.setLocalPlayer(core, 1)
	started = os.clock(); Core.applyTileStates(core, states); local snapshotMs = (os.clock() - started) * 1000
	local repaint = stats(H.drain(core))
	local updateTimes, frameTimes, totalTimes, maxBacklog, tick = {}, {}, {}, 0, 0
	core.maxUploadAgeFrames = 0
	local firstPainted, firstUploaded = core.paintedPixels, core.uploadedBytes
	for frame = 1, 360 do
		local dispatchMs = 0
		if frame % 6 == 1 then
			tick += 1
			local changed = {}; local first = (tick * 733) % math.max(1, #land - 1200) + 1
			for i = first, math.min(#land, first + 1199) do
				local tile = land[i]; buffer.writeu16(states, tile * 2, 1 + tick % 400); table.insert(changed, tile)
			end
			started = os.clock(); Core.applyTileStates(core, states, changed); dispatchMs = (os.clock() - started) * 1000; table.insert(updateTimes, dispatchMs)
		end
		started = os.clock()
		if frame == 121 then Core.setHover(core, 12) elseif frame == 241 then Core.setHover(core, 0) end
		local hoverMs = (os.clock() - started) * 1000
		maxBacklog = math.max(maxBacklog, core.pending)
		local result = Core.step(core); table.insert(frameTimes, result.ms)
		table.insert(totalTimes, dispatchMs + hoverMs + result.ms)
		table.clear(sink.writes)
	end
	local tail = stats(H.drain(core))
	local metrics = Core.metrics(core)
	print(serde.encode("json", {map = dir, size = size, width = w, height = h, constructMs = constructMs, rosterMs = rosterMs,
		snapshotMs = snapshotMs, terrainBuild = cold, politicalFullRepaint = repaint, update1200 = stats(updateTimes), frame = stats(frameTimes), dispatchAndRender = stats(totalTimes),
		maxBacklogBlocks = maxBacklog, drainAfter360 = tail, churnPaintedPixels = core.paintedPixels - firstPainted,
		churnUploadBytes = core.uploadedBytes - firstUploaded, memory = metrics, mockNativePixelBytes = sink.allocatedBytes,
		callerBufferBytes = buffer.len(terrain) + buffer.len(states) + buffer.len(relations)}))
	Core.destroy(core)
end
run("world", "map"); run("world", "map4x")
if process.args[2] == "giant" then run("giantworldmap", "map") end
