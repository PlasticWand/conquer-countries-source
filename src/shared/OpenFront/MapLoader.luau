--!strict
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/game/TerrainMapLoader.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Loads an imported map (scripts/import-openfront-map.luau) into GameMaps.
--   - Normal size plays map.bin with map4x as the minimap.
--   - Compact plays map4x with map16x, and halves nation coordinates and
--     team spawn areas, as OpenFront does.
-- `folder` is the map's module (init) with its chunk children.

local GameMap = require(script.Parent.GameMap)
local TileMap = require(script.Parent.Parent.TileMap)

local MapLoader = {}

export type TerrainMapData = {
	name: string,
	nations: { any },
	additionalNations: { any },
	gameMap: GameMap.GameMap,
	miniGameMap: GameMap.GameMap,
	teamGameSpawnAreas: any?,
}

-- One size's terrain bytes as a fresh buffer.
function MapLoader.readTerrain(folder: any, size: string): (buffer, any)
	local manifest = require(folder) :: any
	local meta = manifest.sizes[size]
	assert(meta, `map has no {size} size`)
	local width, height, chunkSize = meta.width, meta.height, meta.chunkSize
	local out = buffer.create(width * height)
	for _, ref in meta.chunks do
		local chunk = require(folder[ref.module]) :: any
		local data = TileMap.decodeChunk(chunk)
		local x0, y0 = ref.cx * chunkSize, ref.cy * chunkSize
		for row = 0, chunk.h - 1 do
			buffer.copy(out, (y0 + row) * width + x0, data, row * chunk.w, chunk.w)
		end
	end
	return out, meta
end

local function genTerrain(folder: any, size: string): GameMap.GameMap
	local terrain, meta = MapLoader.readTerrain(folder, size)
	return GameMap.new(meta.width, meta.height, terrain, meta.numLandTiles)
end

-- TerrainMapLoader.ts loadTerrainMap. `mapSize` is "Normal" or "Compact".
function MapLoader.loadTerrainMap(folder: any, mapSize: string): TerrainMapData
	return MapLoader.fromManifest(require(folder) :: any, mapSize, function(key: string): GameMap.GameMap
		return genTerrain(folder, key)
	end)
end

-- The same from a manifest (OpenFront's manifest.json shape) and a function
-- that builds the "map", "map4x" or "map16x" GameMap, so tests can load
-- maps straight from the reference clone.
function MapLoader.fromManifest(manifest: any, mapSize: string, gen: (string) -> GameMap.GameMap): TerrainMapData
	local compact = mapSize == "Compact"
	local gameMap = gen(if compact then "map4x" else "map")
	local miniMap = gen(if compact then "map16x" else "map4x")

	local function scaleNations(list: { any }): { any }
		local outList = {}
		for _, n in list do
			local copy = table.clone(n)
			if compact and n.coordinates ~= nil then
				copy.coordinates = { math.floor(n.coordinates[1] / 2), math.floor(n.coordinates[2] / 2) }
			end
			table.insert(outList, copy)
		end
		return outList
	end

	local areas = manifest.teamGameSpawnAreas
	if compact and areas then
		local scaled = {}
		for key, list in areas do
			local s = {}
			for _, a in list do
				table.insert(s, {
					x = math.floor(a.x / 2),
					y = math.floor(a.y / 2),
					width = math.max(1, math.floor(a.width / 2)),
					height = math.max(1, math.floor(a.height / 2)),
				})
			end
			scaled[key] = s
		end
		areas = scaled
	end

	return {
		name = manifest.name,
		nations = scaleNations(manifest.nations or {}),
		additionalNations = scaleNations(manifest.additionalNations or {}),
		gameMap = gameMap,
		miniGameMap = miniMap,
		teamGameSpawnAreas = areas,
	}
end

return MapLoader
