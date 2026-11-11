--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/algorithms/AStar.WaterBounded.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Weighted A* over water inside a rectangle. Cost per step is 100 plus a
-- penalty by distance from shore (magnitude): 300 within 3 tiles, 0 for
-- 3-10, 100 beyond. Ties lean toward the straight start-goal line. Reads
-- terrain bytes directly; the goal may be land (a landing tile).

local PriorityQueue = require(script.Parent.PriorityQueue)

local LAND_MASK = 0x80
local MAGNITUDE_MASK = 0x1f
local COST_SCALE = 100
local BASE_COST = 1 * COST_SCALE

local function getMagnitudePenalty(magnitude: number): number
	if magnitude < 3 then
		return 3 * COST_SCALE -- too close to shore
	elseif magnitude <= 10 then
		return 0 -- sweet spot
	end
	return 1 * COST_SCALE -- deep water
end

-- Conquest: step cost by magnitude (index magnitude + 1), read in the hot loop.
local STEP_COST: { number } = {}
for m = 0, MAGNITUDE_MASK do
	STEP_COST[m + 1] = BASE_COST + getMagnitudePenalty(m)
end

export type SearchBounds = { minX: number, maxX: number, minY: number, maxY: number }

local AStarWaterBounded = {}
AStarWaterBounded.__index = AStarWaterBounded

export type AStarWaterBounded = typeof(setmetatable(
	{} :: {
		stamp: number,
		maxArea: number,
		closedStamp: buffer,
		gScoreStamp: buffer,
		gScore: buffer,
		cameFrom: buffer,
		queue: PriorityQueue.MinHeap,
		terrain: buffer,
		mapWidth: number,
		heuristicWeight: number,
		maxIterations: number,
	},
	AStarWaterBounded
))

function AStarWaterBounded.new(
	map: any,
	maxSearchArea: number,
	config: { heuristicWeight: number?, maxIterations: number? }?
): AStarWaterBounded
	return setmetatable({
		stamp = 1,
		maxArea = maxSearchArea,
		closedStamp = buffer.create(maxSearchArea * 4),
		gScoreStamp = buffer.create(maxSearchArea * 4),
		gScore = buffer.create(maxSearchArea * 4),
		cameFrom = buffer.create(maxSearchArea * 4),
		queue = PriorityQueue.MinHeap.new(maxSearchArea * 4),
		terrain = map.terrain,
		mapWidth = map:width(),
		heuristicWeight = (config and config.heuristicWeight) or 3,
		maxIterations = (config and config.maxIterations) or 100_000,
	}, AStarWaterBounded)
end

function AStarWaterBounded.findPath(self: AStarWaterBounded, start: number | { number }, goal: number): { number }?
	local starts: { number } = if type(start) == "number" then { start } else start :: { number }
	local w = self.mapWidth
	local gx, gy = goal % w, goal // w
	local minX, maxX, minY, maxY = gx, gx, gy, gy
	for _, s in starts do
		local sx, sy = s % w, s // w
		minX, maxX = math.min(minX, sx), math.max(maxX, sx)
		minY, maxY = math.min(minY, sy), math.max(maxY, sy)
	end
	return self:searchBounded(starts, goal, { minX = minX, maxX = maxX, minY = minY, maxY = maxY })
end

function AStarWaterBounded.searchBounded(
	self: AStarWaterBounded,
	start: number | { number },
	goal: number,
	bounds: SearchBounds
): { number }?
	self.stamp += 1
	if self.stamp > 0xffffffff then
		buffer.fill(self.closedStamp, 0, 0)
		buffer.fill(self.gScoreStamp, 0, 0)
		self.stamp = 1
	end
	local stamp = self.stamp
	local mapWidth = self.mapWidth
	local terrain = self.terrain
	local closedStamp, gScoreStamp, gScore, cameFrom = self.closedStamp, self.gScoreStamp, self.gScore, self.cameFrom
	local queue = self.queue
	local weight = self.heuristicWeight
	local minX, maxX, minY, maxY = bounds.minX, bounds.maxX, bounds.minY, bounds.maxY
	local boundsWidth = maxX - minX + 1
	local goalX, goalY = goal % mapWidth, goal // mapWidth
	local boundsHeight = maxY - minY + 1
	local numLocalNodes = boundsWidth * boundsHeight
	if numLocalNodes > self.maxArea then
		return nil
	end

	local function toLocal(tile: number, clamp: boolean): number
		local x, y = tile % mapWidth, tile // mapWidth
		if clamp then
			x = math.max(minX, math.min(maxX, x))
			y = math.max(minY, math.min(maxY, y))
		end
		return (y - minY) * boundsWidth + (x - minX)
	end
	local function toGlobal(localIdx: number): number
		local lx, ly = localIdx % boundsWidth, localIdx // boundsWidth
		return (ly + minY) * mapWidth + (lx + minX)
	end

	local goalLocal = toLocal(goal, true)
	if goalLocal < 0 or goalLocal >= numLocalNodes then
		return nil
	end
	-- Conquest (audit F5, same answers): the queue's heap is worked here
	-- instead of through MinHeap's methods, and a sift moves a hole and
	-- writes the element once, where MinHeap swaps at every step. Both make
	-- the same comparisons on the same float32 priorities, so the heap ends
	-- in the same order and pops the same nodes.
	queue:clear()
	local heap, pri, capacity = queue.heap, queue.priorities, queue.capacity
	local size = 0
	local function push(node: number, priority: number)
		if size >= capacity then
			queue.size = size
			queue:push(node, priority) -- grows (rare: the original logs it as a bug)
			heap, pri, capacity, size = queue.heap, queue.priorities, queue.capacity, queue.size
			return
		end
		local i = size
		size += 1
		buffer.writef32(pri, i * 4, priority)
		local p = buffer.readf32(pri, i * 4) -- (rounded to float32, as stored)
		while i > 0 do
			local parent = bit32.rshift(i - 1, 1)
			local pp = buffer.readf32(pri, parent * 4)
			if pp <= p then
				break
			end
			buffer.writei32(heap, i * 4, buffer.readi32(heap, parent * 4))
			buffer.writef32(pri, i * 4, pp)
			i = parent
		end
		buffer.writei32(heap, i * 4, node)
		buffer.writef32(pri, i * 4, p)
	end
	local function pop(): number
		local result = buffer.readi32(heap, 0)
		size -= 1
		if size > 0 then
			local node, p = buffer.readi32(heap, size * 4), buffer.readf32(pri, size * 4)
			local i = 0
			while true do
				local left = i * 2 + 1
				local right = left + 1
				local smallest, sp = i, p
				if left < size then
					local lp = buffer.readf32(pri, left * 4)
					if lp < sp then
						smallest, sp = left, lp
					end
				end
				if right < size then
					local rp = buffer.readf32(pri, right * 4)
					if rp < sp then
						smallest, sp = right, rp
					end
				end
				if smallest == i then
					break
				end
				buffer.writei32(heap, i * 4, buffer.readi32(heap, smallest * 4))
				buffer.writef32(pri, i * 4, sp)
				i = smallest
			end
			buffer.writei32(heap, i * 4, node)
			buffer.writef32(pri, i * 4, p)
		end
		return result
	end
	local starts: { number } = if type(start) == "number" then { start } else start :: { number }

	-- Cross-product tie-breaker (prefer the straight start-goal line)
	local s0 = starts[1]
	local startX, startY = s0 % mapWidth, s0 // mapWidth
	local dxGoal, dyGoal = goalX - startX, goalY - startY
	local crossNorm = math.max(1, math.abs(dxGoal) + math.abs(dyGoal))

	for _, s in starts do
		local startLocal = toLocal(s, true)
		if startLocal >= 0 and startLocal < numLocalNodes then
			buffer.writeu32(gScore, startLocal * 4, 0)
			buffer.writeu32(gScoreStamp, startLocal * 4, stamp)
			buffer.writei32(cameFrom, startLocal * 4, -1)
			local sx, sy = s % mapWidth, s // mapWidth
			push(startLocal, weight * BASE_COST * (math.abs(sx - goalX) + math.abs(sy - goalY)))
		end
	end

	-- Conquest: the relax step is inlined (the original's per-neighbour
	-- function), same order N, S, W, E and the same priorities.
	local weightCost = weight * BASE_COST
	local tieScale = COST_SCALE - 1
	local iterations = self.maxIterations
	while size > 0 do
		iterations -= 1
		if iterations <= 0 then
			return nil
		end
		local currentLocal = pop()
		if buffer.readu32(closedStamp, currentLocal * 4) ~= stamp then
			buffer.writeu32(closedStamp, currentLocal * 4, stamp)
			if currentLocal == goalLocal then
				return self:_buildPath(goalLocal, toGlobal, numLocalNodes)
			end
			local currentG = buffer.readu32(gScore, currentLocal * 4)
			local cx, cy = currentLocal % boundsWidth + minX, currentLocal // boundsWidth + minY
			local current = cy * mapWidth + cx
			for dir = 1, 4 do
				local neighbor, neighborLocal, nx, ny
				if dir == 1 then
					if cy <= minY then
						continue
					end
					neighbor, neighborLocal, nx, ny = current - mapWidth, currentLocal - boundsWidth, cx, cy - 1
				elseif dir == 2 then
					if cy >= maxY then
						continue
					end
					neighbor, neighborLocal, nx, ny = current + mapWidth, currentLocal + boundsWidth, cx, cy + 1
				elseif dir == 3 then
					if cx <= minX then
						continue
					end
					neighbor, neighborLocal, nx, ny = current - 1, currentLocal - 1, cx - 1, cy
				else
					if cx >= maxX then
						continue
					end
					neighbor, neighborLocal, nx, ny = current + 1, currentLocal + 1, cx + 1, cy
				end
				local slot = neighborLocal * 4
				if buffer.readu32(closedStamp, slot) ~= stamp then
					local neighborTerrain = buffer.readu8(terrain, neighbor)
					if neighbor == goal or bit32.band(neighborTerrain, LAND_MASK) == 0 then
						local tentativeG = currentG + STEP_COST[bit32.band(neighborTerrain, MAGNITUDE_MASK) + 1]
						if buffer.readu32(gScoreStamp, slot) ~= stamp or tentativeG < buffer.readu32(gScore, slot) then
							buffer.writei32(cameFrom, slot, currentLocal)
							buffer.writeu32(gScore, slot, tentativeG)
							buffer.writeu32(gScoreStamp, slot, stamp)
							local cross = math.abs(dxGoal * (ny - goalY) - dyGoal * (nx - goalX))
							push(
								neighborLocal,
								tentativeG
									+ weightCost * (math.abs(nx - goalX) + math.abs(ny - goalY))
									+ math.floor((cross * tieScale) / crossNorm / crossNorm)
							)
						end
					end
				end
			end
		end
	end
	return nil
end

function AStarWaterBounded._buildPath(self: AStarWaterBounded, goalLocal: number, toGlobal: (number) -> number, maxPathLength: number): { number }
	local path = {}
	local current = goalLocal
	local iterations = 0
	while current ~= -1 and iterations < maxPathLength do
		table.insert(path, toGlobal(current))
		current = buffer.readi32(self.cameFrom, current * 4)
		iterations += 1
	end
	-- reverse
	local n = #path
	for i = 1, n // 2 do
		path[i], path[n - i + 1] = path[n - i + 1], path[i]
	end
	return path
end

return AStarWaterBounded
