--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/algorithms/AStar.ts and AStar.Rail.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Generic A* over integer nodes through an adapter, with a bucket queue.
-- RailAdapter lays railroads on the minimap: land is cost 1, water and
-- shoreline 6, each turn +3, and water is entered only from or to a
-- shoreline tile.

local PriorityQueue = require(script.Parent.PriorityQueue)

export type Adapter = {
	neighbors: (self: any, node: number, out: { number }) -> number,
	cost: (self: any, from: number, to: number, prev: number?) -> number,
	heuristic: (self: any, node: number, goal: number) -> number,
	numNodes: (self: any) -> number,
	maxPriority: (self: any) -> number,
	maxNeighbors: (self: any) -> number,
}

local AStar = {}
AStar.__index = AStar

export type AStar = typeof(setmetatable(
	{} :: {
		stamp: number,
		closedStamp: buffer,
		gScoreStamp: buffer,
		gScore: buffer,
		cameFrom: buffer,
		queue: PriorityQueue.BucketQueue,
		adapter: any,
		neighborBuffer: { number },
		maxIterations: number,
	},
	AStar
))

function AStar.new(adapter: any, maxIterations: number?): AStar
	local n = adapter:numNodes()
	return setmetatable({
		stamp = 1,
		closedStamp = buffer.create(math.max(1, n) * 4),
		gScoreStamp = buffer.create(math.max(1, n) * 4),
		gScore = buffer.create(math.max(1, n) * 4),
		cameFrom = buffer.create(math.max(1, n) * 4),
		queue = PriorityQueue.BucketQueue.new(adapter:maxPriority()),
		adapter = adapter,
		neighborBuffer = table.create(adapter:maxNeighbors(), 0),
		maxIterations = maxIterations or 500_000,
	}, AStar)
end

function AStar.findPath(self: AStar, start: number | { number }, goal: number): { number }?
	self.stamp += 1
	if self.stamp > 0xffffffff then
		buffer.fill(self.closedStamp, 0, 0)
		buffer.fill(self.gScoreStamp, 0, 0)
		self.stamp = 1
	end
	local stamp = self.stamp
	local adapter = self.adapter
	local closedStamp, gScoreStamp, gScore, cameFrom = self.closedStamp, self.gScoreStamp, self.gScore, self.cameFrom
	local queue = self.queue
	local nbuf = self.neighborBuffer
	queue:clear()
	local starts: { number } = if type(start) == "number" then { start } else start :: { number }
	for _, s in starts do
		buffer.writeu32(gScore, s * 4, 0)
		buffer.writeu32(gScoreStamp, s * 4, stamp)
		buffer.writei32(cameFrom, s * 4, -1)
		queue:push(s, adapter:heuristic(s, goal))
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
				return self:_buildPath(goal)
			end
			local currentG = buffer.readu32(gScore, current * 4)
			local prev = buffer.readi32(cameFrom, current * 4)
			local count = adapter:neighbors(current, nbuf)
			for i = 1, count do
				local neighbor = nbuf[i]
				if buffer.readu32(closedStamp, neighbor * 4) ~= stamp then
					-- Uint32Array stores wrap modulo 2^32, as in the original.
					local tentativeG = (currentG + adapter:cost(current, neighbor, if prev == -1 then nil else prev)) % 4294967296
					if buffer.readu32(gScoreStamp, neighbor * 4) ~= stamp or tentativeG < buffer.readu32(gScore, neighbor * 4) then
						buffer.writei32(cameFrom, neighbor * 4, current)
						buffer.writeu32(gScore, neighbor * 4, tentativeG)
						buffer.writeu32(gScoreStamp, neighbor * 4, stamp)
						queue:push(neighbor, tentativeG + adapter:heuristic(neighbor, goal))
					end
				end
			end
		end
	end
	return nil
end

function AStar._buildPath(self: AStar, goal: number): { number }
	local path = {}
	local current = goal
	while current ~= -1 do
		table.insert(path, current)
		current = buffer.readi32(self.cameFrom, current * 4)
	end
	local n = #path
	for i = 1, n // 2 do
		path[i], path[n - i + 1] = path[n - i + 1], path[i]
	end
	return path
end

-- AStar.Rail.ts -----------------------------------------------------------------------

local WATER_PENALTY = 5
local HEURISTIC_WEIGHT = 2
local DIRECTION_CHANGE_PENALTY = 3

local RailAdapter = {}
RailAdapter.__index = RailAdapter

function RailAdapter.new(gameMap: any): any
	local w, h = gameMap:width(), gameMap:height()
	return setmetatable({ gameMap = gameMap, width = w, height = h, _numNodes = w * h }, RailAdapter)
end

function RailAdapter.numNodes(self: any): number
	return self._numNodes
end

function RailAdapter.maxNeighbors(_self: any): number
	return 4
end

function RailAdapter.maxPriority(self: any): number
	local maxCost = 1 + WATER_PENALTY + DIRECTION_CHANGE_PENALTY
	return HEURISTIC_WEIGHT * (self.width + self.height) * maxCost
end

function RailAdapter._isTraversable(self: any, to: number, fromShoreline: boolean, isImpassable: boolean): boolean
	if isImpassable then
		return false
	end
	if not self.gameMap:isWater(to) then
		return true
	end
	return fromShoreline or self.gameMap:isShoreline(to)
end

function RailAdapter.neighbors(self: any, node: number, out: { number }): number
	local count = 0
	local w = self.width
	local x = node % w
	local fromShoreline = self.gameMap:isShoreline(node)
	local isImpassable = self.gameMap:isImpassable(node)
	local function try(n: number)
		if self:_isTraversable(n, fromShoreline, isImpassable) then
			count += 1
			out[count] = n
		end
	end
	if node >= w then
		try(node - w)
	end
	if node < self._numNodes - w then
		try(node + w)
	end
	if x ~= 0 then
		try(node - 1)
	end
	if x ~= w - 1 then
		try(node + 1)
	end
	return count
end

function RailAdapter.cost(self: any, from: number, to: number, prev: number?): number
	local penalized = self.gameMap:isWater(to) or self.gameMap:isShoreline(to)
	local c = if penalized then 1 + WATER_PENALTY else 1
	if prev ~= nil and from - prev ~= to - from then
		c += DIRECTION_CHANGE_PENALTY
	end
	return c
end

function RailAdapter.heuristic(self: any, node: number, goal: number): number
	local w = self.width
	return HEURISTIC_WEIGHT * (math.abs(node % w - goal % w) + math.abs(node // w - goal // w))
end

AStar.RailAdapter = RailAdapter

return AStar
