--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/algorithms/AStar.Water.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Whole-map weighted A* over water, used when a map's water graph is too
-- small for the hierarchical search (fewer than 100 nodes). Like the
-- bounded search, but with a heavier shore penalty (1000 within 3 tiles)
-- and heuristic weight 5.

local PriorityQueue = require(script.Parent.PriorityQueue)

local LAND_MASK = 0x80
local MAGNITUDE_MASK = 0x1f
local COST_SCALE = 100
local BASE_COST = 1 * COST_SCALE

local function getMagnitudePenalty(magnitude: number): number
	if magnitude < 3 then
		return 10 * COST_SCALE
	elseif magnitude <= 10 then
		return 0
	end
	return 1 * COST_SCALE
end

local AStarWater = {}
AStarWater.__index = AStarWater

export type AStarWater = typeof(setmetatable(
	{} :: {
		stamp: number,
		closedStamp: buffer,
		gScoreStamp: buffer,
		gScore: buffer,
		cameFrom: buffer,
		queue: PriorityQueue.MinHeap,
		terrain: buffer,
		width: number,
		numNodes: number,
		heuristicWeight: number,
		maxIterations: number,
	},
	AStarWater
))

function AStarWater.new(map: any, config: { heuristicWeight: number?, maxIterations: number? }?): AStarWater
	local n = map:width() * map:height()
	return setmetatable({
		stamp = 1,
		closedStamp = buffer.create(n * 4),
		gScoreStamp = buffer.create(n * 4),
		gScore = buffer.create(n * 4),
		cameFrom = buffer.create(n * 4),
		queue = PriorityQueue.MinHeap.new(n),
		terrain = map.terrain,
		width = map:width(),
		numNodes = n,
		heuristicWeight = (config and config.heuristicWeight) or 5,
		maxIterations = (config and config.maxIterations) or 1_000_000,
	}, AStarWater)
end

function AStarWater.findPath(self: AStarWater, start: number | { number }, goal: number): { number }?
	self.stamp += 1
	if self.stamp > 0xffffffff then
		buffer.fill(self.closedStamp, 0, 0)
		buffer.fill(self.gScoreStamp, 0, 0)
		self.stamp = 1
	end
	local stamp = self.stamp
	local width, numNodes, terrain = self.width, self.numNodes, self.terrain
	local closedStamp, gScoreStamp, gScore, cameFrom = self.closedStamp, self.gScoreStamp, self.gScore, self.cameFrom
	local queue = self.queue
	local weight = self.heuristicWeight
	local goalX, goalY = goal % width, goal // width
	queue:clear()
	local starts: { number } = if type(start) == "number" then { start } else start :: { number }
	local s0 = starts[1]
	local dxGoal, dyGoal = goalX - s0 % width, goalY - s0 // width
	local crossNorm = math.max(1, math.abs(dxGoal) + math.abs(dyGoal))
	local function crossTieBreaker(nx: number, ny: number): number
		local cross = math.abs(dxGoal * (ny - goalY) - dyGoal * (nx - goalX))
		return math.floor((cross * (COST_SCALE - 1)) / crossNorm / crossNorm)
	end
	for _, s in starts do
		buffer.writeu32(gScore, s * 4, 0)
		buffer.writeu32(gScoreStamp, s * 4, stamp)
		buffer.writei32(cameFrom, s * 4, -1)
		queue:push(s, weight * BASE_COST * (math.abs(s % width - goalX) + math.abs(s // width - goalY)))
	end
	local function relax(current: number, currentG: number, neighbor: number, nx: number, ny: number)
		local nt = buffer.readu8(terrain, neighbor)
		if buffer.readu32(closedStamp, neighbor * 4) ~= stamp and (neighbor == goal or bit32.band(nt, LAND_MASK) == 0) then
			local tentativeG = currentG + BASE_COST + getMagnitudePenalty(bit32.band(nt, MAGNITUDE_MASK))
			if buffer.readu32(gScoreStamp, neighbor * 4) ~= stamp or tentativeG < buffer.readu32(gScore, neighbor * 4) then
				buffer.writei32(cameFrom, neighbor * 4, current)
				buffer.writeu32(gScore, neighbor * 4, tentativeG)
				buffer.writeu32(gScoreStamp, neighbor * 4, stamp)
				local h = weight * BASE_COST * (math.abs(nx - goalX) + math.abs(ny - goalY))
				queue:push(neighbor, tentativeG + h + crossTieBreaker(nx, ny))
			end
		end
	end
	local iterations = self.maxIterations
	while not queue:isEmpty() do
		iterations -= 1
		if iterations <= 0 then
			return nil
		end
		local current = queue:pop()
		if buffer.readu32(closedStamp, current * 4) ~= stamp then
			buffer.writeu32(closedStamp, current * 4, stamp)
			if current == goal then
				local path = {}
				local c = goal
				while c ~= -1 do
					table.insert(path, c)
					c = buffer.readi32(cameFrom, c * 4)
				end
				local n = #path
				for i = 1, n // 2 do
					path[i], path[n - i + 1] = path[n - i + 1], path[i]
				end
				return path
			end
			local currentG = buffer.readu32(gScore, current * 4)
			local cx, cy = current % width, current // width
			if current >= width then
				relax(current, currentG, current - width, cx, cy - 1)
			end
			if current < numNodes - width then
				relax(current, currentG, current + width, cx, cy + 1)
			end
			if cx ~= 0 then
				relax(current, currentG, current - 1, cx - 1, cy)
			end
			if cx ~= width - 1 then
				relax(current, currentG, current + 1, cx + 1, cy)
			end
		end
	end
	return nil
end

return AStarWater
