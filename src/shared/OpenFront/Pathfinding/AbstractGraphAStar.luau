--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/algorithms/AStar.AbstractGraph.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A* over the abstract water graph (node ids), single- or multi-source. Like
-- the original, gScore is float32: a tentative score is compared at full
-- precision against the stored float32, then stored rounded.

local AbstractGraph = require(script.Parent.AbstractGraph)
local PriorityQueue = require(script.Parent.PriorityQueue)

local AbstractGraphAStar = {}
AbstractGraphAStar.__index = AbstractGraphAStar

export type AbstractGraphAStar = typeof(setmetatable(
	{} :: {
		stamp: number,
		numNodes: number,
		closedStamp: buffer,
		gScoreStamp: buffer,
		gScore: buffer,
		cameFrom: buffer,
		startNode: buffer,
		queue: PriorityQueue.MinHeap,
		graph: AbstractGraph.AbstractGraph,
		heuristicWeight: number,
		maxIterations: number,
	},
	AbstractGraphAStar
))

function AbstractGraphAStar.new(
	graph: AbstractGraph.AbstractGraph,
	config: { heuristicWeight: number?, maxIterations: number? }?
): AbstractGraphAStar
	local n = graph.nodeCount
	local size = math.max(n, 1)
	return setmetatable({
		stamp = 1,
		numNodes = n,
		closedStamp = buffer.create(size * 4),
		gScoreStamp = buffer.create(size * 4),
		gScore = buffer.create(size * 4),
		cameFrom = buffer.create(size * 4),
		startNode = buffer.create(size * 4),
		-- One push per directed edge relaxation, at worst.
		queue = PriorityQueue.MinHeap.new(math.max(1, n + graph.edgeCount * 2)),
		graph = graph,
		heuristicWeight = (config and config.heuristicWeight) or 1,
		maxIterations = (config and config.maxIterations) or 100_000,
	}, AbstractGraphAStar)
end

function AbstractGraphAStar.findPath(self: AbstractGraphAStar, start: number | { number }, goal: number): { number }?
	if type(start) == "table" then
		return self:_findPathMultiSource(start, goal)
	end
	return self:_search({ start :: number }, goal, false)
end

function AbstractGraphAStar._findPathMultiSource(self: AbstractGraphAStar, startIds: { number }, goalId: number): { number }?
	if #startIds == 0 then
		return nil
	end
	if #startIds == 1 then
		return self:_search({ startIds[1] }, goalId, false)
	end
	return self:_search(startIds, goalId, true)
end

-- One search body for both forms; `multi` also tracks each node's origin
-- start (the single form skips unknown starts by returning nil instead).
function AbstractGraphAStar._search(self: AbstractGraphAStar, startIds: { number }, goalId: number, multi: boolean): { number }?
	self.stamp += 1
	if self.stamp > 0xffffffff then
		buffer.fill(self.closedStamp, 0, 0)
		buffer.fill(self.gScoreStamp, 0, 0)
		self.stamp = 1
	end
	local stamp = self.stamp
	local graph = self.graph
	local closedStamp, gScoreStamp, gScore, cameFrom, startNode =
		self.closedStamp, self.gScoreStamp, self.gScore, self.cameFrom, self.startNode
	local queue = self.queue
	local weight = self.heuristicWeight

	local goalNode = graph:getNode(goalId)
	if goalNode == nil then
		return nil
	end
	local goalX, goalY = goalNode.x, goalNode.y
	if not multi then
		if graph:getNode(startIds[1]) == nil then
			return nil
		end
	end
	queue:clear()
	for _, startId in startIds do
		local node = graph:getNode(startId)
		if node then
			buffer.writef32(gScore, startId * 4, 0)
			buffer.writeu32(gScoreStamp, startId * 4, stamp)
			buffer.writei32(cameFrom, startId * 4, -1)
			if multi then
				buffer.writei32(startNode, startId * 4, startId)
			end
			queue:push(startId, weight * (math.abs(node.x - goalX) + math.abs(node.y - goalY)))
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
			if current == goalId then
				return self:_buildPathFromGoal(goalId)
			end
			local currentG = buffer.readf32(gScore, current * 4)
			local currentStart = if multi then buffer.readi32(startNode, current * 4) else 0
			for _, edge in graph:getNodeEdges(current) do
				local neighbor = graph:getOtherNode(edge, current)
				if buffer.readu32(closedStamp, neighbor * 4) ~= stamp then
					local tentativeG = currentG + edge.cost
					if
						buffer.readu32(gScoreStamp, neighbor * 4) ~= stamp
						or tentativeG < buffer.readf32(gScore, neighbor * 4)
					then
						buffer.writei32(cameFrom, neighbor * 4, current)
						buffer.writef32(gScore, neighbor * 4, tentativeG)
						buffer.writeu32(gScoreStamp, neighbor * 4, stamp)
						if multi then
							buffer.writei32(startNode, neighbor * 4, currentStart)
						end
						local neighborNode = graph:getNode(neighbor)
						if neighborNode then
							queue:push(
								neighbor,
								tentativeG + weight * (math.abs(neighborNode.x - goalX) + math.abs(neighborNode.y - goalY))
							)
						end
					end
				end
			end
		end
	end
	return nil
end

function AbstractGraphAStar._buildPathFromGoal(self: AbstractGraphAStar, goalId: number): { number }?
	local path = {}
	local current = goalId
	local maxLen = self.numNodes
	while current ~= -1 do
		if current < 0 or current >= maxLen then
			return nil
		end
		table.insert(path, current)
		if #path > maxLen then
			return nil
		end
		current = buffer.readi32(self.cameFrom, current * 4)
	end
	local n = #path
	for i = 1, n // 2 do
		path[i], path[n - i + 1] = path[n - i + 1], path[i]
	end
	return path
end

return AbstractGraphAStar
