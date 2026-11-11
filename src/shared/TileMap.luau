--!strict
-- Loads a generated tile map (CONTRACT.md section 2): a manifest module whose
-- children are 128x128 terrain chunk modules. Terrain decodes straight into
-- one u8 buffer, row-major over the whole map. Server and client share this.

local Base64 = require(script.Parent.Base64)
local Crc32 = require(script.Parent.Crc32)

export type MapLabel = { text: string, tile: number, kind: string }

export type Manifest = {
	schemaVersion: number,
	mapId: string,
	mapVersion: number,
	width: number,
	height: number,
	chunkSize: number,
	chunks: { { cx: number, cy: number, module: string } },
	biomeChunks: { { cx: number, cy: number, module: string } }?, -- art only
	rowAreaWeight: { number }?,
	labels: { MapLabel },
	generator: { script: string, version: number, seed: number? },
}

export type TerrainChunk = {
	cx: number,
	cy: number,
	w: number,
	h: number,
	encoding: string,
	data: string,
	decodedLength: number,
	checksum: number,
}

export type TileMap = {
	manifest: Manifest,
	mapId: string,
	mapVersion: number,
	width: number,
	height: number,
	tileCount: number,
	terrain: buffer, -- u8 per tile: 0 water, 1 plains, 2 highland, 3 mountain
	-- u8 per tile, TileMap.BIOME. Art only: the renderer colours land by it;
	-- gameplay never reads it. Absent on maps generated without one.
	biome: buffer?,
	landCount: number,
}

local SCHEMA_VERSION = 1

local TileMap = {}

TileMap.SCHEMA_VERSION = SCHEMA_VERSION
TileMap.WATER = 0
TileMap.PLAINS = 1
TileMap.HIGHLAND = 2
TileMap.MOUNTAIN = 3
TileMap.MAX_TAG = 3

-- Biome codes (art only; water tiles are 0).
TileMap.BIOME = { GRASS = 0, FOREST = 1, JUNGLE = 2, DRY = 3, DESERT = 4, TUNDRA = 5, SNOW = 6 }
TileMap.MAX_BIOME = 6

-- Reads a layer of chunk modules into one width*height u8 buffer.
local function readLayer(folder: any, refs: { { cx: number, cy: number, module: string } }, width: number, height: number, size: number): buffer
	local out = buffer.create(width * height)
	local seen = 0
	for _, ref in refs do
		local chunk: TerrainChunk = require(folder[ref.module]) :: any
		assert(chunk.cx == ref.cx and chunk.cy == ref.cy, "chunk position mismatch")
		local x0, y0 = chunk.cx * size, chunk.cy * size
		assert(chunk.w == math.min(size, width - x0) and chunk.h == math.min(size, height - y0), "chunk size mismatch")
		local data = TileMap.decodeChunk(chunk)
		for row = 0, chunk.h - 1 do
			buffer.copy(out, (y0 + row) * width + x0, data, row * chunk.w, chunk.w)
		end
		seen += 1
	end
	assert(seen == math.ceil(width / size) * math.ceil(height / size), "missing chunks")
	return out
end

-- Decodes one chunk payload into a w*h u8 buffer and verifies it.
function TileMap.decodeChunk(chunk: TerrainChunk): buffer
	local payload = Base64.decode(chunk.data)
	local out: buffer
	if chunk.encoding == "raw" then
		assert(buffer.len(payload) == chunk.decodedLength, "raw chunk length mismatch")
		out = payload
	elseif chunk.encoding == "rle" then
		out = buffer.create(chunk.decodedLength)
		local o = 0
		local i = 0
		local n = buffer.len(payload)
		while i < n do
			local tag = buffer.readu8(payload, i)
			i += 1
			local length = 0
			local shift = 1
			while true do
				assert(i < n, "truncated rle varint")
				local b = buffer.readu8(payload, i)
				i += 1
				length += bit32.band(b, 0x7F) * shift
				if b < 0x80 then
					break
				end
				shift *= 128
			end
			assert(length >= 1 and o + length <= chunk.decodedLength, "rle run out of range")
			buffer.fill(out, o, tag, length)
			o += length
		end
		assert(o == chunk.decodedLength, "rle chunk length mismatch")
	else
		error(`unknown chunk encoding {chunk.encoding}`)
	end
	assert(Crc32.ofBuffer(out) == chunk.checksum, `checksum mismatch in chunk {chunk.cx},{chunk.cy}`)
	return out
end

-- `folder` is the map's ModuleScript (init.luau); its children are the chunks.
function TileMap.load(folder: any): TileMap
	local manifest: Manifest = require(folder) :: any
	assert(manifest.schemaVersion == SCHEMA_VERSION, "unsupported tile map schema")
	local width, height, size = manifest.width, manifest.height, manifest.chunkSize
	local terrain = readLayer(folder, manifest.chunks, width, height, size)
	local biome: buffer? = nil
	local biomeRefs = manifest.biomeChunks
	if biomeRefs then
		local layer = readLayer(folder, biomeRefs, width, height, size)
		for i = 0, width * height - 1 do
			assert(buffer.readu8(layer, i) <= TileMap.MAX_BIOME, "reserved biome code")
		end
		biome = layer
	end
	local landCount = 0
	for i = 0, width * height - 1 do
		local tag = buffer.readu8(terrain, i)
		assert(tag <= TileMap.MAX_TAG, "reserved terrain tag")
		if tag ~= 0 then
			landCount += 1
		end
	end
	return {
		manifest = manifest,
		mapId = manifest.mapId,
		mapVersion = manifest.mapVersion,
		width = width,
		height = height,
		tileCount = width * height,
		terrain = terrain,
		biome = biome,
		landCount = landCount,
	}
end

-- Builds a TileMap from an in-memory terrain buffer (tests and fixtures).
function TileMap.fromTerrain(mapId: string, width: number, height: number, terrain: buffer): TileMap
	local landCount = 0
	for i = 0, width * height - 1 do
		if buffer.readu8(terrain, i) ~= 0 then
			landCount += 1
		end
	end
	return {
		manifest = {
			schemaVersion = SCHEMA_VERSION,
			mapId = mapId,
			mapVersion = 1,
			width = width,
			height = height,
			chunkSize = 128,
			chunks = {},
			labels = {},
			generator = { script = "fixture", version = 1 },
		},
		mapId = mapId,
		mapVersion = 1,
		width = width,
		height = height,
		tileCount = width * height,
		terrain = terrain,
		landCount = landCount,
	}
end

return TileMap
