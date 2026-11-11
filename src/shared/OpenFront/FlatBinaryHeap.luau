--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/utils/FlatBinaryHeap.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Min-heap of (priority, tile). Priorities are stored as float32, like the
-- original's Float32Array, and a new priority is compared at full precision
-- while sifting up, then rounded when stored. That exact behaviour decides
-- which of two equal-looking tiles an attack takes first. Heap slots are
-- 0-based, as in the original.

local FlatBinaryHeap = {}
FlatBinaryHeap.__index = FlatBinaryHeap

export type FlatBinaryHeap = typeof(setmetatable(
	{} :: {
		pri: buffer, -- float32 per slot
		tiles: { [number]: number }, -- slot -> tile, 0-based
		len: number,
		capacity: number,
	},
	FlatBinaryHeap
))

function FlatBinaryHeap.new(capacity: number?): FlatBinaryHeap
	local cap = capacity or 1024
	return setmetatable({ pri = buffer.create(cap * 4), tiles = {}, len = 0, capacity = cap }, FlatBinaryHeap)
end

-- remove every element without reallocating
function FlatBinaryHeap.clear(self: FlatBinaryHeap)
	self.len = 0
end

function FlatBinaryHeap.size(self: FlatBinaryHeap): number
	return self.len
end

function FlatBinaryHeap.enqueue(self: FlatBinaryHeap, tile: number, priority: number)
	if self.len == self.capacity then
		self:_grow()
	end
	local pri, tiles = self.pri, self.tiles
	local i = self.len
	self.len += 1
	-- sift-up
	while i > 0 do
		local parent = bit32.rshift(i - 1, 1)
		local parentPri = buffer.readf32(pri, parent * 4)
		if priority >= parentPri then
			break
		end
		buffer.writef32(pri, i * 4, parentPri)
		tiles[i] = tiles[parent]
		i = parent
	end
	buffer.writef32(pri, i * 4, priority)
	tiles[i] = tile
end

-- remove and return the lowest-priority tile
function FlatBinaryHeap.dequeue(self: FlatBinaryHeap): number
	if self.len == 0 then
		error("heap empty")
	end
	local pri, tiles = self.pri, self.tiles
	local topTile = tiles[0]
	self.len -= 1
	local len = self.len
	local lastPri = buffer.readf32(pri, len * 4)
	local lastTile = tiles[len]
	-- sift-down
	local i = 0
	while true do
		local left = i * 2 + 1
		if left >= len then
			break
		end
		local right = left + 1
		local leftPri = buffer.readf32(pri, left * 4)
		local child, childPri = left, leftPri
		if right < len then
			local rightPri = buffer.readf32(pri, right * 4)
			if rightPri < leftPri then
				child, childPri = right, rightPri
			end
		end
		if lastPri <= childPri then
			break
		end
		buffer.writef32(pri, i * 4, childPri)
		tiles[i] = tiles[child]
		i = child
	end
	buffer.writef32(pri, i * 4, lastPri)
	tiles[i] = lastTile
	return topTile
end

-- double the underlying storage
function FlatBinaryHeap._grow(self: FlatBinaryHeap)
	local newCap = self.capacity * 2
	local newPri = buffer.create(newCap * 4)
	buffer.copy(newPri, 0, self.pri, 0, self.capacity * 4)
	self.pri = newPri
	self.capacity = newCap
end

return FlatBinaryHeap
