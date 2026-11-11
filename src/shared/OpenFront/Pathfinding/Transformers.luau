--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/transformers/{ComponentCheckTransformer,SmoothingWaterTransformer,ShoreCoercingTransformer,MiniMapTransformer}.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Wrappers around a pathfinder (anything with findPath(from, to)), chained
-- outermost-last by PathFinding.luau:
--   - ComponentCheck: drop sources in another water body.
--   - Smoothing: line-of-sight shortening and endpoint refinement.
--   - ShoreCoercing: start and end on shore tiles via their best water
--     neighbour.
--   - MiniMap: search on the half-size map, then scale the path up.

local AStarWaterBounded = require(script.Parent.AStarWaterBounded)

export type PathFinder = { findPath: (self: any, from: number | { number }, to: number) -> { number }? }

local Transformers = {}

-- JS Math.round (halves toward +infinity).
local function jsRound(x: number): number
	return math.floor(x + 0.5)
end

local function asList(from: number | { number }): { number }
	return if type(from) == "number" then { from } else from :: { number }
end

local function oneOrList(list: { number }): number | { number }
	return if #list == 1 then list[1] else list
end

-- ComponentCheckTransformer ----------------------------------------------------

local ComponentCheck = {}
ComponentCheck.__index = ComponentCheck
Transformers.ComponentCheck = ComponentCheck

function ComponentCheck.new(inner: PathFinder, getComponent: (number) -> number): any
	return setmetatable({ inner = inner, getComponent = getComponent }, ComponentCheck)
end

function ComponentCheck.findPath(self: any, from: number | { number }, to: number): { number }?
	local toComponent = self.getComponent(to)
	local valid = {}
	for _, f in asList(from) do
		if self.getComponent(f) == toComponent then
			table.insert(valid, f)
		end
	end
	if #valid == 0 then
		return nil
	end
	return self.inner:findPath(oneOrList(valid), to)
end

-- SmoothingWaterTransformer ----------------------------------------------------

local ENDPOINT_REFINEMENT_TILES = 50
local LOCAL_ASTAR_MAX_AREA = 100 * 100
local LOS_MIN_MAGNITUDE_PASS1 = 2
local LOS_MIN_MAGNITUDE_PASS2 = 3
local MAGNITUDE_MASK = 0x1f
local LAND_BIT = 0x80 -- GameMap's IS_LAND

local Smoothing = {}
Smoothing.__index = Smoothing
Transformers.Smoothing = Smoothing

function Smoothing.new(inner: PathFinder, map: any, isTraversable: ((number) -> boolean)?): any
	return setmetatable({
		inner = inner,
		map = map,
		mapWidth = map:width(),
		localAStar = AStarWaterBounded.new(map, LOCAL_ASTAR_MAX_AREA),
		terrain = map.terrain,
		plainWater = isTraversable == nil,
		isTraversable = isTraversable or function(t: number): boolean
			return map:isWater(t)
		end,
	}, Smoothing)
end

function Smoothing.findPath(self: any, from: number | { number }, to: number): { number }?
	local path = self.inner:findPath(from, to)
	return if path then self:_smooth(path) else nil
end

function Smoothing._smooth(self: any, path: { number }): { number }
	if #path <= 2 then
		return path
	end
	local smoothed = self:_losSmooth(path, LOS_MIN_MAGNITUDE_PASS1)
	smoothed = self:_refineEndpoints(smoothed)
	return self:_losSmooth(smoothed, LOS_MIN_MAGNITUDE_PASS2)
end

function Smoothing._losSmooth(self: any, path: { number }, minMagnitude: number): { number }
	-- Indices below are 0-based like the original; path[i + 1] reads them.
	local n = #path
	local result = { path[1] }
	local current = 0
	while current < n - 1 do
		local lo, hi = current + 1, n - 1
		local farthest = lo
		while lo <= hi do
			local mid = (lo + hi) // 2
			if self:_canSee(path[current + 1], path[mid + 1], minMagnitude) then
				farthest = mid
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
		if farthest > current + 1 then
			local trace = self:_tracePath(path[current + 1], path[farthest + 1])
			if trace then
				for i = 2, #trace - 1 do
					table.insert(result, trace[i])
				end
			end
		end
		current = farthest
		if current < n - 1 then
			table.insert(result, path[current + 1])
		end
	end
	table.insert(result, path[n])
	return result
end

function Smoothing._refineEndpoints(self: any, path: { number }): { number }
	if #path <= 2 then
		return path
	end
	local result = path
	local startEndIdx = self:_findTileAtDistance(path, 0, ENDPOINT_REFINEMENT_TILES, true)
	if startEndIdx > 1 then
		local seg = self:_refineSegment(path[1], path[startEndIdx + 1])
		if seg and #seg > 0 then
			local newResult = {}
			for i = 1, #seg - 1 do
				table.insert(newResult, seg[i])
			end
			for i = startEndIdx + 1, #result do
				table.insert(newResult, result[i])
			end
			result = newResult
		end
	end
	local endStartIdx = self:_findTileAtDistance(result, #result - 1, ENDPOINT_REFINEMENT_TILES, false)
	if endStartIdx < #result - 2 then
		local seg = self:_refineSegment(result[#result], result[endStartIdx + 1])
		if seg and #seg > 0 then
			local newResult = {}
			for i = 1, endStartIdx do
				table.insert(newResult, result[i])
			end
			for i = #seg, 1, -1 do
				table.insert(newResult, seg[i])
			end
			result = newResult
		end
	end
	return result
end

function Smoothing._findTileAtDistance(self: any, path: { number }, startIdx: number, distance: number, forward: boolean): number
	local cum = 0
	local idx = startIdx
	if forward then
		while idx < #path - 1 and cum < distance do
			cum += self:_manhattan(path[idx + 1], path[idx + 2])
			idx += 1
		end
	else
		while idx > 0 and cum < distance do
			cum += self:_manhattan(path[idx + 1], path[idx])
			idx -= 1
		end
	end
	return idx
end

function Smoothing._refineSegment(self: any, from: number, to: number): { number }?
	local map = self.map
	local x0, y0, x1, y1 = map:x(from), map:y(from), map:x(to), map:y(to)
	local padding = 10
	return self.localAStar:searchBounded(from, to, {
		minX = math.max(0, math.min(x0, x1) - padding),
		maxX = math.min(map:width() - 1, math.max(x0, x1) + padding),
		minY = math.max(0, math.min(y0, y1) - padding),
		maxY = math.min(map:height() - 1, math.max(y0, y1) + padding),
	})
end

function Smoothing._canSee(self: any, from: number, to: number, minMagnitude: number): boolean
	local w = self.mapWidth
	local terrain = self.terrain
	local isTraversable = self.isTraversable
	-- Conquest (audit F5, same answers): with the default test (water), the
	-- land bit is read here rather than through a call per tile.
	local plain = self.plainWater
	local x0, y0, x1, y1 = from % w, from // w, to % w, to // w
	local dx, dy = math.abs(x1 - x0), math.abs(y1 - y0)
	local sx = if x0 < x1 then 1 else -1
	local sy = if y0 < y1 then 1 else -1
	local err = dx - dy
	local x, y = x0, y0
	local iterations = 0
	while true do
		iterations += 1
		if iterations - 1 > 100000 then
			return false
		end
		local tile = y * w + x
		if not (if plain then bit32.band(buffer.readu8(terrain, tile), LAND_BIT) == 0 else isTraversable(tile)) then
			return false
		end
		if bit32.band(buffer.readu8(terrain, tile), MAGNITUDE_MASK) < minMagnitude then
			return false
		end
		if x == x1 and y == y1 then
			return true
		end
		local e2 = 2 * err
		local moveX, moveY = e2 > -dy, e2 < dx
		if moveX and moveY then
			-- Diagonal move: check the intermediate tile
			x += sx
			err -= dy
			local mid = y * w + x
			if not (if plain then bit32.band(buffer.readu8(terrain, mid), LAND_BIT) == 0 else isTraversable(mid)) or bit32.band(buffer.readu8(terrain, mid), MAGNITUDE_MASK) < minMagnitude then
				-- Try the other corner
				x -= sx
				err += dy
				y += sy
				err += dx
				local alt = y * w + x
				if not (if plain then bit32.band(buffer.readu8(terrain, alt), LAND_BIT) == 0 else isTraversable(alt)) or bit32.band(buffer.readu8(terrain, alt), MAGNITUDE_MASK) < minMagnitude then
					return false
				end
				x += sx
				err -= dy
			else
				y += sy
				err += dx
			end
		else
			if moveX then
				x += sx
				err -= dy
			end
			if moveY then
				y += sy
				err += dx
			end
		end
	end
end

function Smoothing._tracePath(self: any, from: number, to: number): { number }?
	local w = self.mapWidth
	local terrain = self.terrain
	local isTraversable = self.isTraversable
	-- Conquest (audit F5, same answers): with the default test (water), the
	-- land bit is read here rather than through a call per tile.
	local plain = self.plainWater
	local x0, y0, x1, y1 = from % w, from // w, to % w, to // w
	local tiles = {}
	local dx, dy = math.abs(x1 - x0), math.abs(y1 - y0)
	local sx = if x0 < x1 then 1 else -1
	local sy = if y0 < y1 then 1 else -1
	local err = dx - dy
	local x, y = x0, y0
	local iterations = 0
	while true do
		iterations += 1
		if iterations - 1 > 100000 then
			return nil
		end
		local tile = y * w + x
		if not (if plain then bit32.band(buffer.readu8(terrain, tile), LAND_BIT) == 0 else isTraversable(tile)) then
			return nil
		end
		table.insert(tiles, tile)
		if x == x1 and y == y1 then
			break
		end
		local e2 = 2 * err
		local moveX, moveY = e2 > -dy, e2 < dx
		if moveX and moveY then
			x += sx
			err -= dy
			local mid = y * w + x
			if not (if plain then bit32.band(buffer.readu8(terrain, mid), LAND_BIT) == 0 else isTraversable(mid)) then
				x -= sx
				err += dy
				y += sy
				err += dx
				local alt = y * w + x
				if not (if plain then bit32.band(buffer.readu8(terrain, alt), LAND_BIT) == 0 else isTraversable(alt)) then
					return nil
				end
				table.insert(tiles, alt)
				x += sx
				err -= dy
			else
				table.insert(tiles, mid)
				y += sy
				err += dx
			end
		else
			if moveX then
				x += sx
				err -= dy
			end
			if moveY then
				y += sy
				err += dx
			end
		end
	end
	return tiles
end

function Smoothing._manhattan(self: any, a: number, b: number): number
	local w = self.mapWidth
	return math.abs(a % w - b % w) + math.abs(a // w - b // w)
end

-- ShoreCoercingTransformer -----------------------------------------------------

local ShoreCoercing = {}
ShoreCoercing.__index = ShoreCoercing
Transformers.ShoreCoercing = ShoreCoercing

function ShoreCoercing.new(inner: PathFinder, map: any): any
	return setmetatable({ inner = inner, map = map, nbuf = { 0, 0, 0, 0 }, nbuf2 = { 0, 0, 0, 0 } }, ShoreCoercing)
end

function ShoreCoercing.findPath(self: any, from: number | { number }, to: number): { number }?
	local map = self.map
	local waterToOriginal: { [number]: number } = {}
	local waterFrom = {}
	for _, f in asList(from) do
		if map:isWater(f) then
			table.insert(waterFrom, f)
			-- A raw water source overrides an earlier shore that coerced here.
			waterToOriginal[f] = nil
		else
			local water = self:_bestWaterNeighbor(f)
			if water ~= -1 then
				table.insert(waterFrom, water)
				waterToOriginal[water] = f
			end
		end
	end
	if #waterFrom == 0 then
		return nil
	end
	local waterTo, originalTo = to, -1
	if not map:isWater(to) then
		waterTo = self:_bestWaterNeighbor(to)
		if waterTo == -1 then
			return nil
		end
		originalTo = to
	end
	local path = self.inner:findPath(oneOrList(waterFrom), waterTo)
	if path == nil or #path == 0 then
		return nil
	end
	local originalShore = waterToOriginal[path[1]]
	if originalShore ~= nil then
		table.insert(path, 1, originalShore)
	end
	if originalTo ~= -1 and path[#path] ~= originalTo then
		table.insert(path, originalTo)
	end
	return path
end

-- The water neighbour with the most water neighbours (first on a tie).
function ShoreCoercing._bestWaterNeighbor(self: any, tile: number): number
	local map = self.map
	local best, maxScore = -1, -1
	local nbuf, nbuf2 = self.nbuf, self.nbuf2
	local n = map:neighbors4(tile, nbuf)
	for i = 1, n do
		local nb = nbuf[i]
		if map:isWater(nb) then
			local score = 0
			local m = map:neighbors4(nb, nbuf2)
			for j = 1, m do
				if map:isWater(nbuf2[j]) then
					score += 1
				end
			end
			if score > maxScore then
				maxScore = score
				best = nb
			end
		end
	end
	return best
end

-- MiniMapTransformer -------------------------------------------------------------

local MiniMap = {}
MiniMap.__index = MiniMap
Transformers.MiniMap = MiniMap

function MiniMap.new(inner: PathFinder, map: any, miniMap: any): any
	return setmetatable({ inner = inner, map = map, miniMap = miniMap }, MiniMap)
end

function MiniMap.findPath(self: any, from: number | { number }, to: number): { number }?
	local map, mini = self.map, self.miniMap
	local fromList = asList(from)
	local miniFrom = {}
	for _, f in fromList do
		table.insert(miniFrom, mini:ref(map:x(f) // 2, map:y(f) // 2))
	end
	local miniTo = mini:ref(map:x(to) // 2, map:y(to) // 2)
	local path = self.inner:findPath(oneOrList(miniFrom), miniTo)
	if path == nil or #path == 0 then
		return nil
	end
	local upscaled = self:_upscalePath(path)
	local srcRef: number? = nil
	if type(from) == "table" then
		if #upscaled > 0 then
			local sx, sy = map:x(upscaled[1]), map:y(upscaled[1])
			local minDist = math.huge
			for _, f in from :: { number } do
				local d = math.abs(map:x(f) - sx) + math.abs(map:y(f) - sy)
				if d < minDist then
					minDist = d
					srcRef = f
				end
			end
		end
	else
		srcRef = from :: number
	end
	return self:_fixExtremes(upscaled, to, srcRef)
end

-- Scale up, interpolating so consecutive tiles stay adjacent.
function MiniMap._upscalePath(self: any, path: { number }): { number }
	local mini, main = self.miniMap, self.map
	local out = {}
	for i = 1, #path - 1 do
		local curX, curY = mini:x(path[i]) * 2, mini:y(path[i]) * 2
		local nextX, nextY = mini:x(path[i + 1]) * 2, mini:y(path[i + 1]) * 2
		table.insert(out, main:ref(curX, curY))
		local dx, dy = nextX - curX, nextY - curY
		local steps = math.max(math.abs(dx), math.abs(dy))
		for step = 1, steps - 1 do
			table.insert(out, main:ref(jsRound(curX + (dx * step) / steps), jsRound(curY + (dy * step) / steps)))
		end
	end
	if #path > 0 then
		local last = path[#path]
		table.insert(out, main:ref(mini:x(last) * 2, mini:y(last) * 2))
	end
	return out
end

function MiniMap._fixExtremes(_self: any, upscaled: { number }, dst: number, src: number?): { number }
	if src ~= nil then
		local srcIndex = table.find(upscaled, src)
		if srcIndex == nil then
			table.insert(upscaled, 1, src)
		elseif srcIndex ~= 1 then
			upscaled = table.move(upscaled, srcIndex, #upscaled, 1, {})
		end
	end
	local dstIndex = table.find(upscaled, dst)
	if dstIndex == nil then
		table.insert(upscaled, dst)
	elseif dstIndex ~= #upscaled then
		upscaled = table.move(upscaled, 1, dstIndex, 1, {})
	end
	return upscaled
end

return Transformers
