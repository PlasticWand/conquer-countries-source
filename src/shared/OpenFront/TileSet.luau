--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/game/TileSet.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- An insertion-ordered set of tile refs with JS Set iteration semantics,
-- which the simulation's tie-breaking depends on:
--   - iteration runs in insertion order
--   - entries added during iteration are visited
--   - entries deleted during iteration are skipped
--   - delete + re-add moves a value to the end
-- The original uses typed arrays and open addressing for memory. Here a dense
-- array with tombstones plus a value -> slot map gives the same order.
-- Compaction is deferred while iterating, as in the original.

local TileSet = {}
TileSet.__index = TileSet

local TOMBSTONE = -1

export type TileSet = typeof(setmetatable(
	{} :: {
		dense: { number },
		slot: { [number]: number },
		denseLen: number,
		size_: number,
		iterDepth: number,
	},
	TileSet
))

function TileSet.new(values: { number }?): TileSet
	local self = setmetatable({ dense = {}, slot = {}, denseLen = 0, size_ = 0, iterDepth = 0 }, TileSet)
	if values then
		for _, v in values do
			self:add(v)
		end
	end
	return self
end

function TileSet.size(self: TileSet): number
	return self.size_
end

function TileSet.has(self: TileSet, value: number): boolean
	return self.slot[value] ~= nil
end

function TileSet.add(self: TileSet, value: number): TileSet
	if self.slot[value] ~= nil then
		return self
	end
	if self.iterDepth == 0 and self.denseLen >= 64 and self.denseLen - self.size_ > self.size_ then
		self:_compact()
	end
	local i = self.denseLen + 1
	self.denseLen = i
	self.dense[i] = value
	self.slot[value] = i
	self.size_ += 1
	return self
end

function TileSet.delete(self: TileSet, value: number): boolean
	local i = self.slot[value]
	if i == nil then
		return false
	end
	self.slot[value] = nil
	self.dense[i] = TOMBSTONE
	self.size_ -= 1
	if self.iterDepth == 0 and self.denseLen >= 64 and self.denseLen - self.size_ > self.size_ * 2 then
		self:_compact()
	end
	return true
end

function TileSet.clear(self: TileSet)
	self.dense = {}
	self.slot = {}
	self.denseLen = 0
	self.size_ = 0
end

-- Calls fn(tile) for each live entry in order. denseLen is re-read every step
-- so entries appended during the walk are visited.
function TileSet.forEach(self: TileSet, fn: (number) -> ())
	self.iterDepth += 1
	local ok, err = pcall(function()
		local i = 1
		while i <= self.denseLen do
			local v = self.dense[i]
			if v ~= TOMBSTONE then
				fn(v)
			end
			i += 1
		end
	end)
	self.iterDepth -= 1
	if not ok then
		error(err, 0)
	end
end

-- A snapshot of the live entries in order (cheap callers that don't mutate).
function TileSet.values(self: TileSet): { number }
	local out = table.create(self.size_)
	local n = 0
	for i = 1, self.denseLen do
		local v = self.dense[i]
		if v ~= TOMBSTONE then
			n += 1
			out[n] = v
		end
	end
	return out
end

-- Util.ts calculateBoundingBox over the live entries of a map `width`
-- wide, without copying them: minX, minY, maxX, maxY (the empty-set
-- infinities when empty).
function TileSet.boundingBox(self: TileSet, width: number): (number, number, number, number)
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local dense = self.dense
	for i = 1, self.denseLen do
		local v = dense[i]
		if v ~= TOMBSTONE then
			local x, y = v % width, v // width
			if x < minX then
				minX = x
			end
			if x > maxX then
				maxX = x
			end
			if y < minY then
				minY = y
			end
			if y > maxY then
				maxY = y
			end
		end
	end
	return minX, minY, maxX, maxY
end

-- Rewrites dense storage without tombstones, preserving insertion order.
function TileSet._compact(self: TileSet)
	local dense = table.create(self.size_)
	local n = 0
	for i = 1, self.denseLen do
		local v = self.dense[i]
		if v ~= TOMBSTONE then
			n += 1
			dense[n] = v
			self.slot[v] = n
		end
	end
	self.dense = dense
	self.denseLen = n
end

return TileSet
