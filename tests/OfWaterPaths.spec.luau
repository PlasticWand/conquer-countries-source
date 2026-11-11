-- OpenFront port, Phase C: ship paths through the full water chain
-- (minimap, shore coercion, smoothing, component check, hierarchical A*).
-- tests/fixtures/openfront/water-paths.json was dumped by OpenFront v0.35.2's
-- own PathFinding.Water on World and Black Sea at full size: 250
-- shore-to-shore queries and 40 four-source queries per map, each recorded as
-- length + hash (+ the whole path when short). Maps are read from the
-- reference clone; skipped when it is absent.
return function(t)
	local EngineConfig = t.require("OpenFront.EngineConfig")
	local Game = t.require("OpenFront.Game")
	local GameMap = t.require("OpenFront.GameMap")
	local PathFinding = t.require("OpenFront.Pathfinding.PathFinding")

	local ROOT = "../reference/openfront-v0.35.2/resources/maps"

	local function imul(a: number, b: number): number
		local aHi, aLo = bit32.rshift(a, 16), bit32.band(a, 0xffff)
		local bHi, bLo = bit32.rshift(b, 16), bit32.band(b, 0xffff)
		return ((((aHi * bLo + aLo * bHi) % 65536) * 65536) + aLo * bLo) % 4294967296
	end
	local function mix(h: number, v: number): number
		return imul(bit32.bxor(h, v % 4294967296), 0x01000193)
	end

	for _, case in t.json(t.readFile("tests/fixtures/openfront/water-paths.json")) do
		t.test(`{case.map}: {#case.queries} water paths match OpenFront`, function()
			local dir = `{ROOT}/{case.map}`
			if not t.isFile(dir .. "/map.bin") then
				print(`  (skipped {case.map}: reference maps not available)`)
				return
			end
			local manifest = t.json(t.readFile(dir .. "/manifest.json"))
			local function load(key: string, file: string): any
				local m = manifest[key]
				return GameMap.new(m.width, m.height, buffer.fromstring(t.readFile(`{dir}/{file}`)), m.num_land_tiles)
			end
			local config = EngineConfig.new({
				gameMap = "World",
				gameMapSize = "Normal",
				gameMode = "Free For All",
				gameType = "Public",
				difficulty = "Medium",
				bots = 0,
				nations = "disabled",
			}, false)
			local game = Game.new({}, {}, load("map", "map.bin"), load("map4x", "map4x.bin"), config)
			for i, q in case.queries do
				local stepper = PathFinding.Stepper.new(PathFinding.sharedWaterChain(game), game)
				local p = stepper:findPath(q.from, q.to)
				local len = if p then #p else -1
				if len ~= q.len then
					error(`query {i} ({typeof(q.from) == "table" and "multi" or q.from} -> {q.to}): length {len}, expected {q.len}`)
				end
				if p then
					if q.path then
						for k, tile in q.path do
							if p[k] ~= tile then
								error(`query {i}: tile {k} is {p[k]}, expected {tile}`)
							end
						end
					end
					local h = 2166136261
					for _, tile in p do
						h = mix(h, tile)
					end
					t.eq(h, q.hash, `query {i} path hash`)
				end
			end
		end)
	end
end
