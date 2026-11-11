--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/Util.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The pure helpers the engine uses. Gold is a BigInt in OpenFront; here it is
-- an integer-valued number, exact below 2^53, so toInt returns a number.

local DetMath = require(script.Parent.DetMath)

local Util = {}

local MAX_SAFE_INTEGER = 9007199254740991

-- Util.ts within: clamp to [min, max].
function Util.within(value: number, min: number, max: number): number
	return math.min(math.max(value, min), max)
end

-- Util.ts sigmoid
function Util.sigmoid(value: number, decayRate: number, midpoint: number): number
	return 1 / (1 + DetMath.exp(-decayRate * (value - midpoint)))
end

-- Util.ts toInt: floor, with infinities pinned to the safe-integer range.
function Util.toInt(num: number): number
	if num == math.huge then
		return MAX_SAFE_INTEGER
	elseif num == -math.huge then
		return -MAX_SAFE_INTEGER
	end
	return math.floor(num)
end

-- Util.ts simpleHash: Java-style 32-bit string hash, absolute value.
-- charCodeAt reads UTF-16 code units; ids and names here are ASCII, so bytes match.
function Util.simpleHash(str: string): number
	local hash = 0 -- held as a signed 32-bit value, like JS after `& hash`
	for i = 1, #str do
		local h = (hash * 32 - hash + string.byte(str, i)) % 4294967296
		hash = if h >= 2147483648 then h - 4294967296 else h
	end
	return math.abs(hash)
end

-- Util.ts manhattanDistWrapped
function Util.manhattanDistWrapped(x1: number, y1: number, x2: number, y2: number, width: number): number
	local dx = math.abs(x1 - x2)
	dx = math.min(dx, width - dx)
	return dx + math.abs(y1 - y2)
end

-- Array.prototype.sort semantics: stable (ties keep their order). Luau's
-- table.sort isn't, so sorts whose ties matter go through here.
function Util.stableSort<T>(list: { T }, less: (T, T) -> boolean): { T }
	local indexed = table.create(#list)
	for i, v in list do
		indexed[i] = { v = v, i = i }
	end
	table.sort(indexed, function(a, b)
		if less(a.v, b.v) then
			return true
		elseif less(b.v, a.v) then
			return false
		end
		return a.i < b.i
	end)
	local out = table.create(#list)
	for i, e in indexed do
		out[i] = e.v
	end
	return out
end

-- Util.ts findMinimumBy / findClosestBy: the first value with the lowest
-- score among candidates, or nil.
function Util.findMinimumBy<T>(values: { T }, score: (T) -> number, isCandidate: ((T) -> boolean)?): T?
	local best: T? = nil
	local bestScore = math.huge
	for _, value in values do
		if isCandidate == nil or isCandidate(value) then
			local s = score(value)
			if s < bestScore then
				bestScore = s
				best = value
			end
		end
	end
	return best
end
Util.findClosestBy = Util.findMinimumBy

-- Util.ts boundingBoxTiles: the valid tiles on the edge of the square of
-- `radius` around center (top and bottom rows, then the side columns).
function Util.boundingBoxTiles(gm: any, center: number, radius: number): { number }
	local tiles = {}
	local cx, cy = gm:x(center), gm:y(center)
	local minX, maxX, minY, maxY = cx - radius, cx + radius, cy - radius, cy + radius
	for x = minX, maxX do
		if gm:isValidCoord(x, minY) then
			table.insert(tiles, gm:ref(x, minY))
		end
		if gm:isValidCoord(x, maxY) and minY ~= maxY then
			table.insert(tiles, gm:ref(x, maxY))
		end
	end
	for y = minY + 1, maxY - 1 do
		if gm:isValidCoord(minX, y) then
			table.insert(tiles, gm:ref(minX, y))
		end
		if gm:isValidCoord(maxX, y) and minX ~= maxX then
			table.insert(tiles, gm:ref(maxX, y))
		end
	end
	return tiles
end

return Util
