--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/game/GameMapImpl.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The tile grid. A TileRef is the 0-based row-major index y*width+x, exactly
-- as in OpenFront. Terrain is one byte per tile, in OpenFront's map-file
-- layout:
--   bit 7 land, bit 6 shoreline, bit 5 ocean, bits 0-4 magnitude (31 = impassable)
-- State is a u16 per tile:
--   bits 0-11 owner smallID (0 = nobody), bit 13 fallout, bit 14 defence bonus
-- Neighbour order matches OpenFront (north, south, west, east), because
-- conquest order depends on it. Out-arrays are 1-based; the count is returned.
-- Snapshots and the terrain-edit diff are not ported yet (Phase A uses none).

local GameTypes = require(script.Parent.GameTypes)
local TerrainType = GameTypes.TerrainType

local IS_LAND = 0x80
local SHORELINE = 0x40
local OCEAN = 0x20
local MAGNITUDE_MASK = 0x1f
local IMPASSABLE_MAGNITUDE = 31

local PLAYER_ID_MASK = 0xfff
local FALLOUT = 0x2000 -- bit 13
local DEFENSE_BONUS = 0x4000 -- bit 14

local GameMap = {}
GameMap.__index = GameMap
GameMap.PLAYER_ID_MASK = PLAYER_ID_MASK
-- For hot loops that read the buffers directly (Game._updateBorders,
-- AttackExecution._addNeighbors, Player.nearby).
GameMap.IS_LAND = IS_LAND
GameMap.MAGNITUDE_MASK = MAGNITUDE_MASK
GameMap.IMPASSABLE_MAGNITUDE = IMPASSABLE_MAGNITUDE
GameMap.FALLOUT = FALLOUT

export type GameMap = typeof(setmetatable(
	{} :: {
		terrain: buffer,
		state: buffer,
		width_: number,
		height_: number,
		numLandTiles_: number,
		numTilesWithFallout_: number,
		waterVersion_: number,
	},
	GameMap
))

-- GameMapImpl constructor. `terrain` is taken over, not copied.
function GameMap.new(width: number, height: number, terrain: buffer, numLandTiles: number): GameMap
	if buffer.len(terrain) ~= width * height then
		error(`Terrain data length {buffer.len(terrain)} doesn't match dimensions {width}x{height}`)
	end
	return setmetatable({
		terrain = terrain,
		state = buffer.create(width * height * 2),
		width_ = width,
		height_ = height,
		numLandTiles_ = numLandTiles,
		numTilesWithFallout_ = 0,
		waterVersion_ = 0,
	}, GameMap)
end

function GameMap.numTilesWithFallout(self: GameMap): number
	return self.numTilesWithFallout_
end

function GameMap.ref(self: GameMap, x: number, y: number): number
	if not self:isValidCoord(x, y) then
		error(`Invalid coordinates: {x},{y}`)
	end
	return y * self.width_ + x
end

function GameMap.isValidRef(self: GameMap, ref: number): boolean
	return ref == math.floor(ref) and ref >= 0 and ref < self.width_ * self.height_
end

function GameMap.x(self: GameMap, ref: number): number
	return ref % self.width_
end

function GameMap.y(self: GameMap, ref: number): number
	return ref // self.width_
end

function GameMap.width(self: GameMap): number
	return self.width_
end

function GameMap.height(self: GameMap): number
	return self.height_
end

function GameMap.numLandTiles(self: GameMap): number
	return self.numLandTiles_
end

function GameMap.isValidCoord(self: GameMap, x: number, y: number): boolean
	return x == math.floor(x) and y == math.floor(y) and x >= 0 and x < self.width_ and y >= 0 and y < self.height_
end

-- Terrain getters ----------------------------------------------------------------

function GameMap.terrainByte(self: GameMap, ref: number): number
	return buffer.readu8(self.terrain, ref)
end

function GameMap.isLand(self: GameMap, ref: number): boolean
	return bit32.band(buffer.readu8(self.terrain, ref), IS_LAND) ~= 0
end

function GameMap.isImpassable(self: GameMap, ref: number): boolean
	local b = buffer.readu8(self.terrain, ref)
	return bit32.band(b, IS_LAND) ~= 0 and bit32.band(b, MAGNITUDE_MASK) == IMPASSABLE_MAGNITUDE
end

function GameMap.isOcean(self: GameMap, ref: number): boolean
	return bit32.band(buffer.readu8(self.terrain, ref), OCEAN) ~= 0
end

function GameMap.isShoreline(self: GameMap, ref: number): boolean
	return bit32.band(buffer.readu8(self.terrain, ref), SHORELINE) ~= 0
end

function GameMap.isOceanShore(self: GameMap, ref: number): boolean
	if not self:isLand(ref) then
		return false
	end
	local w = self.width_
	local x = ref % w
	if x ~= 0 and self:isOcean(ref - 1) then
		return true
	end
	if x ~= w - 1 and self:isOcean(ref + 1) then
		return true
	end
	if ref >= w and self:isOcean(ref - w) then
		return true
	end
	if ref < (self.height_ - 1) * w and self:isOcean(ref + w) then
		return true
	end
	return false
end

function GameMap.magnitude(self: GameMap, ref: number): number
	return bit32.band(buffer.readu8(self.terrain, ref), MAGNITUDE_MASK)
end

function GameMap.waterVersion(self: GameMap): number
	return self.waterVersion_
end

-- Conquest addition (not in OpenFront): the areas a railroad can join, as a
-- u32 label per tile (0 for impassable tiles). It follows AStar.RailAdapter's
-- moves: out of a passable tile into land, or into water from or to a
-- shoreline tile. Between passable tiles that relation is symmetric, so tiles
-- with different labels have no rail path, and the rail search can say so
-- without exhausting its iterations (a ~0.15 s server stall per failed search
-- in Luau). Rebuilt when the water changes.
function GameMap.railComponents(self: GameMap): buffer
	local cache = (self :: any)._railComponents
	if cache and cache.version == self.waterVersion_ then
		return cache.labels
	end
	local terrain = self.terrain
	local w, n = self.width_, self.width_ * self.height_
	local labels = buffer.create(n * 4)
	local queue = buffer.create(n * 4)
	local function passable(b: number): boolean
		return not (bit32.band(b, IS_LAND) ~= 0 and bit32.band(b, MAGNITUDE_MASK) == IMPASSABLE_MAGNITUDE)
	end
	local nextLabel = 0
	for start = 0, n - 1 do
		if buffer.readu32(labels, start * 4) == 0 and passable(buffer.readu8(terrain, start)) then
			nextLabel += 1
			buffer.writeu32(labels, start * 4, nextLabel)
			local head, tail = 0, 1
			buffer.writeu32(queue, 0, start)
			while head < tail do
				local a = buffer.readu32(queue, head * 4)
				head += 1
				local aShore = bit32.band(buffer.readu8(terrain, a), SHORELINE) ~= 0
				local x = a % w
				for k = 1, 4 do
					local b = -1
					if k == 1 then
						if a >= w then b = a - w end
					elseif k == 2 then
						if a < n - w then b = a + w end
					elseif k == 3 then
						if x ~= 0 then b = a - 1 end
					elseif x ~= w - 1 then
						b = a + 1
					end
					if b >= 0 and buffer.readu32(labels, b * 4) == 0 then
						local tb = buffer.readu8(terrain, b)
						if passable(tb) and (bit32.band(tb, IS_LAND) ~= 0 or aShore or bit32.band(tb, SHORELINE) ~= 0) then
							buffer.writeu32(labels, b * 4, nextLabel)
							buffer.writeu32(queue, tail * 4, b)
							tail += 1
						end
					end
				end
			end
		end
	end
	;(self :: any)._railComponents = { version = self.waterVersion_, labels = labels }
	return labels
end

-- Lake water: no land, no ocean, no shoreline, magnitude 0.
function GameMap.setWater(self: GameMap, ref: number)
	if not self:isLand(ref) or self:isImpassable(ref) then
		return
	end
	self.waterVersion_ += 1
	buffer.writeu8(self.terrain, ref, 0)
	self.numLandTiles_ -= 1
end

function GameMap.setShorelineBit(self: GameMap, ref: number)
	buffer.writeu8(self.terrain, ref, bit32.bor(buffer.readu8(self.terrain, ref), SHORELINE))
end

function GameMap.clearShorelineBit(self: GameMap, ref: number)
	buffer.writeu8(self.terrain, ref, bit32.band(buffer.readu8(self.terrain, ref), bit32.bnot(SHORELINE)))
end

function GameMap.setOcean(self: GameMap, ref: number)
	buffer.writeu8(self.terrain, ref, bit32.bor(buffer.readu8(self.terrain, ref), OCEAN))
end

function GameMap.setMagnitude(self: GameMap, ref: number, value: number)
	local b = buffer.readu8(self.terrain, ref)
	buffer.writeu8(
		self.terrain,
		ref,
		bit32.bor(bit32.band(b, bit32.bnot(MAGNITUDE_MASK)), bit32.band(value, MAGNITUDE_MASK))
	)
end

-- State ------------------------------------------------------------------------

function GameMap.ownerID(self: GameMap, ref: number): number
	return bit32.band(buffer.readu16(self.state, ref * 2), PLAYER_ID_MASK)
end

function GameMap.hasOwner(self: GameMap, ref: number): boolean
	return self:ownerID(ref) ~= 0
end

function GameMap.setOwnerID(self: GameMap, ref: number, playerId: number)
	if playerId > PLAYER_ID_MASK then
		error(`Player ID {playerId} exceeds maximum value {PLAYER_ID_MASK}`)
	end
	local s = buffer.readu16(self.state, ref * 2)
	buffer.writeu16(self.state, ref * 2, bit32.bor(bit32.band(s, bit32.bnot(PLAYER_ID_MASK)), playerId))
end

function GameMap.hasFallout(self: GameMap, ref: number): boolean
	return bit32.band(buffer.readu16(self.state, ref * 2), FALLOUT) ~= 0
end

function GameMap.setFallout(self: GameMap, ref: number, value: boolean)
	local s = buffer.readu16(self.state, ref * 2)
	local existing = bit32.band(s, FALLOUT) ~= 0
	if value and not existing then
		self.numTilesWithFallout_ += 1
		buffer.writeu16(self.state, ref * 2, bit32.bor(s, FALLOUT))
	elseif not value and existing then
		self.numTilesWithFallout_ -= 1
		buffer.writeu16(self.state, ref * 2, bit32.band(s, bit32.bnot(FALLOUT)))
	end
end

-- True when the tile touches the map boundary or an impassable tile.
function GameMap.isOnEdgeOfMap(self: GameMap, ref: number): boolean
	local w = self.width_
	local x = ref % w
	if x == 0 or x == w - 1 or ref < w or ref >= (self.height_ - 1) * w then
		return true
	end
	return self:isImpassable(ref - 1) or self:isImpassable(ref + 1) or self:isImpassable(ref - w) or self:isImpassable(ref + w)
end

function GameMap.isBorder(self: GameMap, ref: number): boolean
	local w = self.width_
	local x = ref % w
	local owner = self:ownerID(ref)
	if x ~= 0 and self:ownerID(ref - 1) ~= owner then
		return true
	end
	if x ~= w - 1 and self:ownerID(ref + 1) ~= owner then
		return true
	end
	if ref >= w and self:ownerID(ref - w) ~= owner then
		return true
	end
	if ref < (self.height_ - 1) * w and self:ownerID(ref + w) ~= owner then
		return true
	end
	return false
end

function GameMap.hasDefenseBonus(self: GameMap, ref: number): boolean
	return bit32.band(buffer.readu16(self.state, ref * 2), DEFENSE_BONUS) ~= 0
end

function GameMap.setDefenseBonus(self: GameMap, ref: number, value: boolean)
	local s = buffer.readu16(self.state, ref * 2)
	buffer.writeu16(self.state, ref * 2, if value then bit32.bor(s, DEFENSE_BONUS) else bit32.band(s, bit32.bnot(DEFENSE_BONUS)))
end

function GameMap.tileState(self: GameMap, ref: number): number
	return buffer.readu16(self.state, ref * 2)
end

-- Helpers ------------------------------------------------------------------------

function GameMap.isWater(self: GameMap, ref: number): boolean
	return not self:isLand(ref)
end

function GameMap.isShore(self: GameMap, ref: number): boolean
	return self:isLand(ref) and self:isShoreline(ref)
end

function GameMap.cost(self: GameMap, ref: number): number
	return if self:magnitude(ref) < 10 then 2 else 1
end

function GameMap.terrainType(self: GameMap, ref: number): number
	if self:isLand(ref) then
		local magnitude = self:magnitude(ref)
		if magnitude >= IMPASSABLE_MAGNITUDE then
			return TerrainType.Impassable
		elseif magnitude < 10 then
			return TerrainType.Plains
		elseif magnitude < 20 then
			return TerrainType.Highland
		end
		return TerrainType.Mountain
	end
	return TerrainType.Ocean
end

-- Order: north, south, west, east.
function GameMap.neighbors(self: GameMap, ref: number): { number }
	local out = {}
	local n = self:neighbors4(ref, out)
	for i = n + 1, #out do
		out[i] = nil
	end
	return out
end

function GameMap.forEachNeighbor(self: GameMap, ref: number, callback: (number) -> ())
	local w = self.width_
	local x = ref % w
	if ref >= w then
		callback(ref - w)
	end
	if ref < (self.height_ - 1) * w then
		callback(ref + w)
	end
	if x ~= 0 then
		callback(ref - 1)
	end
	if x ~= w - 1 then
		callback(ref + 1)
	end
end

-- Writes up to four neighbours into out[1..n] and returns n.
function GameMap.neighbors4(self: GameMap, ref: number, out: { number }): number
	local w = self.width_
	local x = ref % w
	local n = 0
	if ref >= w then
		n += 1
		out[n] = ref - w
	end
	if ref < (self.height_ - 1) * w then
		n += 1
		out[n] = ref + w
	end
	if x ~= 0 then
		n += 1
		out[n] = ref - 1
	end
	if x ~= w - 1 then
		n += 1
		out[n] = ref + 1
	end
	return n
end

-- Order: west column (NW, W, SW), N, S, east column (NE, E, SE).
function GameMap.neighbors8(self: GameMap, ref: number, out: { number }): number
	local w = self.width_
	local x = ref % w
	local hasN = ref >= w
	local hasS = ref < (self.height_ - 1) * w
	local n = 0
	local function push(v: number)
		n += 1
		out[n] = v
	end
	if x ~= 0 then
		if hasN then
			push(ref - 1 - w)
		end
		push(ref - 1)
		if hasS then
			push(ref - 1 + w)
		end
	end
	if hasN then
		push(ref - w)
	end
	if hasS then
		push(ref + w)
	end
	if x ~= w - 1 then
		if hasN then
			push(ref + 1 - w)
		end
		push(ref + 1)
		if hasS then
			push(ref + 1 + w)
		end
	end
	return n
end

function GameMap.forEachNeighborWithDiag(self: GameMap, ref: number, callback: (number) -> ())
	local out = {}
	local n = self:neighbors8(ref, out)
	for i = 1, n do
		callback(out[i])
	end
end

function GameMap.manhattanDist(self: GameMap, c1: number, c2: number): number
	return math.abs(self:x(c1) - self:x(c2)) + math.abs(self:y(c1) - self:y(c2))
end

function GameMap.euclideanDistSquared(self: GameMap, c1: number, c2: number): number
	local x = self:x(c1) - self:x(c2)
	local y = self:y(c1) - self:y(c2)
	return x * x + y * y
end

-- Tiles within `radius` (Euclidean) of `tile`, in OpenFront's insertion
-- order (column by column).
function GameMap.circleSearch(self: GameMap, tile: number, radius: number, filter: ((number, number) -> boolean)?): { number }
	local cx, cy = self:x(tile), self:y(tile)
	local tiles = {}
	local minX = math.max(0, cx - radius)
	local maxX = math.min(self.width_ - 1, cx + radius)
	local minY = math.max(0, cy - radius)
	local maxY = math.min(self.height_ - 1, cy + radius)
	local r2 = radius * radius
	for i = minX, maxX do
		for j = minY, maxY do
			local t = j * self.width_ + i
			local d2 = self:euclideanDistSquared(tile, t)
			if d2 <= r2 and (filter == nil or filter(t, d2)) then
				table.insert(tiles, t)
			end
		end
	end
	return tiles
end

-- Flood fill from `tile` through tiles passing `filter`. Returns the tiles in
-- OpenFront's insertion order and a membership set.
function GameMap.bfs(self: GameMap, tile: number, filter: (GameMap, number) -> boolean): ({ number }, { [number]: true })
	local seen: { [number]: true } = {}
	local order = {}
	local q = {}
	if filter(self, tile) then
		seen[tile] = true
		table.insert(order, tile)
		table.insert(q, tile)
	end
	local w = self.width_
	local southLimit = (self.height_ - 1) * w
	local function visit(n: number)
		if not seen[n] and filter(self, n) then
			seen[n] = true
			table.insert(order, n)
			table.insert(q, n)
		end
	end
	while #q > 0 do
		local curr = table.remove(q) :: number -- pop: depth-first, like JS q.pop()
		local x = curr % w
		if curr >= w then
			visit(curr - w)
		end
		if curr < southLimit then
			visit(curr + w)
		end
		if x ~= 0 then
			visit(curr - 1)
		end
		if x ~= w - 1 then
			visit(curr + 1)
		end
	end
	return order, seen
end

-- GameMapImpl.ts euclDistFN / manhattanDistFN: distance filters for bfs.
function GameMap.euclDistFN(root: number, dist: number, center: boolean?): (GameMap, number) -> boolean
	local dist2 = dist * dist
	if not center then
		return function(gm: GameMap, n: number): boolean
			return gm:euclideanDistSquared(root, n) <= dist2
		end
	end
	return function(gm: GameMap, n: number): boolean
		-- the root's centre becomes the corner of four tiles
		local rootX = gm:x(root) - 0.5
		local rootY = gm:y(root) - 0.5
		local dx = gm:x(n) - rootX
		local dy = gm:y(n) - rootY
		return dx * dx + dy * dy <= dist2
	end
end

function GameMap.manhattanDistFN(root: number, dist: number, center: boolean?): (GameMap, number) -> boolean
	if not center then
		return function(gm: GameMap, n: number): boolean
			return gm:manhattanDist(root, n) <= dist
		end
	end
	return function(gm: GameMap, n: number): boolean
		local rootX = gm:x(root) - 0.5
		local rootY = gm:y(root) - 0.5
		return math.abs(gm:x(n) - rootX) + math.abs(gm:y(n) - rootY) <= dist
	end
end

return GameMap
