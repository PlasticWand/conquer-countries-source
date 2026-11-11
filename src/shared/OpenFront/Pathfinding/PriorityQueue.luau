--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/algorithms/PriorityQueue.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Two queues for the pathfinders: a binary min-heap with float32 priorities
-- (stored first, then compared, like the original's Float32Array), and an
-- integer bucket queue. Slots are 0-based buffers, as in the original.

local PriorityQueue = {}

local MinHeap = {}
MinHeap.__index = MinHeap

export type MinHeap = typeof(setmetatable(
	{} :: { heap: buffer, priorities: buffer, size: number, capacity: number },
	MinHeap
))

function MinHeap.new(capacity: number): MinHeap
	return setmetatable({
		heap = buffer.create(capacity * 4),
		priorities = buffer.create(capacity * 4),
		size = 0,
		capacity = capacity,
	}, MinHeap)
end

function MinHeap.push(self: MinHeap, node: number, priority: number)
	if self.size >= self.capacity then
		-- The original logs this as a bug and grows.
		local newCap = self.capacity * 2
		local h, p = buffer.create(newCap * 4), buffer.create(newCap * 4)
		buffer.copy(h, 0, self.heap, 0, self.capacity * 4)
		buffer.copy(p, 0, self.priorities, 0, self.capacity * 4)
		self.heap, self.priorities, self.capacity = h, p, newCap
	end
	local heap, pri = self.heap, self.priorities
	local i = self.size
	self.size += 1
	buffer.writei32(heap, i * 4, node)
	buffer.writef32(pri, i * 4, priority)
	-- Bubble up
	while i > 0 do
		local parent = bit32.rshift(i - 1, 1)
		local pp, pi = buffer.readf32(pri, parent * 4), buffer.readf32(pri, i * 4)
		if pp <= pi then
			break
		end
		local tmpNode = buffer.readi32(heap, parent * 4)
		buffer.writei32(heap, parent * 4, buffer.readi32(heap, i * 4))
		buffer.writef32(pri, parent * 4, pi)
		buffer.writei32(heap, i * 4, tmpNode)
		buffer.writef32(pri, i * 4, pp)
		i = parent
	end
end

function MinHeap.pop(self: MinHeap): number
	local heap, pri = self.heap, self.priorities
	local result = buffer.readi32(heap, 0)
	self.size -= 1
	local size = self.size
	if size > 0 then
		buffer.writei32(heap, 0, buffer.readi32(heap, size * 4))
		buffer.writef32(pri, 0, buffer.readf32(pri, size * 4))
		-- Bubble down
		local i = 0
		while true do
			local left = i * 2 + 1
			local right = left + 1
			local smallest = i
			if left < size and buffer.readf32(pri, left * 4) < buffer.readf32(pri, smallest * 4) then
				smallest = left
			end
			if right < size and buffer.readf32(pri, right * 4) < buffer.readf32(pri, smallest * 4) then
				smallest = right
			end
			if smallest == i then
				break
			end
			local tmpNode, tmpPri = buffer.readi32(heap, smallest * 4), buffer.readf32(pri, smallest * 4)
			buffer.writei32(heap, smallest * 4, buffer.readi32(heap, i * 4))
			buffer.writef32(pri, smallest * 4, buffer.readf32(pri, i * 4))
			buffer.writei32(heap, i * 4, tmpNode)
			buffer.writef32(pri, i * 4, tmpPri)
			i = smallest
		end
	end
	return result
end

function MinHeap.isEmpty(self: MinHeap): boolean
	return self.size == 0
end

function MinHeap.clear(self: MinHeap)
	self.size = 0
end

PriorityQueue.MinHeap = MinHeap

-- Bucket queue: O(1) push/pop for integer priorities. Buckets are reused
-- across clears by stamping instead of wiping. Pop takes the newest entry of
-- the lowest bucket (LIFO), as in the original.
local BucketQueue = {}
BucketQueue.__index = BucketQueue

export type BucketQueue = typeof(setmetatable(
	{} :: {
		buckets: { [number]: { number } },
		bucketSizes: { [number]: number },
		bucketStamp: { [number]: number },
		stamp: number,
		minBucket: number,
		maxBucket: number,
		size: number,
	},
	BucketQueue
))

function BucketQueue.new(maxPriority: number): BucketQueue
	local maxBucket = maxPriority + 1
	return setmetatable({
		buckets = {},
		bucketSizes = {},
		bucketStamp = {},
		stamp = 0,
		minBucket = maxBucket,
		maxBucket = maxBucket,
		size = 0,
	}, BucketQueue)
end

-- JS `x | 0` for the small non-negative priorities used here.
local function toInt32(x: number): number
	local n = if x < 0 then math.ceil(x) else math.floor(x)
	n %= 4294967296
	return if n >= 2147483648 then n - 4294967296 else n
end

function BucketQueue.push(self: BucketQueue, node: number, priority: number)
	local bucket = math.min(toInt32(priority), self.maxBucket - 1)
	local list = self.buckets[bucket]
	if list == nil then
		list = {}
		self.buckets[bucket] = list
	end
	local size = if self.bucketStamp[bucket] == self.stamp then (self.bucketSizes[bucket] or 0) else 0
	list[size + 1] = node
	self.bucketSizes[bucket] = size + 1
	self.bucketStamp[bucket] = self.stamp
	self.size += 1
	if bucket < self.minBucket then
		self.minBucket = bucket
	end
end

function BucketQueue.pop(self: BucketQueue): number
	while self.minBucket < self.maxBucket do
		local b = self.minBucket
		if self.bucketStamp[b] == self.stamp then
			local size = self.bucketSizes[b] or 0
			if size > 0 then
				self.bucketSizes[b] = size - 1
				self.size -= 1
				return self.buckets[b][size]
			end
		end
		self.minBucket += 1
	end
	return -1
end

function BucketQueue.isEmpty(self: BucketQueue): boolean
	return self.size == 0
end

function BucketQueue.clear(self: BucketQueue)
	self.stamp += 1
	self.minBucket = self.maxBucket
	self.size = 0
end

PriorityQueue.BucketQueue = BucketQueue

return PriorityQueue
