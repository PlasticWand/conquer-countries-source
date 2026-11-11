--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/algorithms/AStar.WaterHierarchical.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Hierarchical water pathfinding on the minimap:
--   - Short trips search a 3×3-cluster window directly.
--   - Others route over the abstract graph, then stitch bounded A* segments
--     between gateways. Segments are cached on the graph per direction.
--   - Multi-source queries try sources within 120 tiles first, then pick the
--     winning source on the abstract graph.
-- Smoothing is a separate transformer.

local AStarWaterBounded = require(script.Parent.AStarWaterBounded)
local AbstractGraph = require(script.Parent.AbstractGraph)
local AbstractGraphAStar = require(script.Parent.AbstractGraphAStar)

local SHORT_PATH_THRESHOLD = 120
local SHORT_PATH_PADDING = 10

local AStarWaterHierarchical = {}
AStarWaterHierarchical.__index = AStarWaterHierarchical

export type AStarWaterHierarchical = typeof(setmetatable(
	{} :: {
		map: any,
		graph: AbstractGraph.AbstractGraph,
		cachePaths: boolean,
		tileBFS: AbstractGraph.BFSGrid,
		abstractAStar: AbstractGraphAStar.AbstractGraphAStar,
		localAStar: AStarWaterBounded.AStarWaterBounded,
		localAStarMultiCluster: AStarWaterBounded.AStarWaterBounded,
		localAStarShortPath: AStarWaterBounded.AStarWaterBounded,
	},
	AStarWaterHierarchical
))

function AStarWaterHierarchical.new(map: any, graph: AbstractGraph.AbstractGraph, options: { cachePaths: boolean? }?): AStarWaterHierarchical
	local clusterSize = graph.clusterSize
	local multi = clusterSize * 3
	local shortSize = 260 -- 2 * (120 + padding 10)
	return setmetatable({
		map = map,
		graph = graph,
		cachePaths = options ~= nil and options.cachePaths == true,
		tileBFS = AbstractGraph.BFSGrid.new(map:width() * map:height()),
		abstractAStar = AbstractGraphAStar.new(graph),
		localAStar = AStarWaterBounded.new(map, clusterSize * clusterSize),
		localAStarMultiCluster = AStarWaterBounded.new(map, multi * multi),
		localAStarShortPath = AStarWaterBounded.new(map, shortSize * shortSize),
	}, AStarWaterHierarchical)
end

-- Swap in a rebuilt graph, keeping the map-sized scratch buffers.
function AStarWaterHierarchical.setGraph(self: AStarWaterHierarchical, graph: AbstractGraph.AbstractGraph)
	self.graph = graph
	self.abstractAStar = AbstractGraphAStar.new(graph)
end

function AStarWaterHierarchical.findPath(self: AStarWaterHierarchical, from: number | { number }, to: number): { number }?
	if type(from) == "table" then
		return self:_findPathMultiSource(from, to)
	end
	return self:findPathSingle(from :: number, to)
end

-- SourceResolver.getClusterNode: the node in the tile's cluster closest by
-- Manhattan distance (first on a tie).
function AStarWaterHierarchical._getClusterNode(self: AStarWaterHierarchical, tile: number): AbstractGraph.AbstractNode?
	local map, graph = self.map, self.graph
	local x, y = map:x(tile), map:y(tile)
	local cluster = graph:getCluster(x // graph.clusterSize, y // graph.clusterSize)
	if cluster == nil or #cluster.nodeIds == 0 then
		return nil
	end
	local best, bestDist = nil, math.huge
	for _, id in cluster.nodeIds do
		local node = graph:getNode(id)
		if node then
			local dist = math.abs(node.x - x) + math.abs(node.y - y)
			if dist < bestDist then
				bestDist = dist
				best = node
			end
		end
	end
	return best
end

function AStarWaterHierarchical._findPathMultiSource(self: AStarWaterHierarchical, sources: { number }, target: number): { number }?
	local short = self:_tryShortPathMultiSource(sources, target)
	if short then
		return short
	end
	local targetNode = self:_getClusterNode(target)
	if targetNode == nil then
		return nil
	end
	-- Closest source per node, nodes in first-seen order (JS Map order).
	local order: { number } = {}
	local nodeToSource: { [number]: number } = {}
	local nodeToDist: { [number]: number } = {}
	local map, graph = self.map, self.graph
	-- Conquest (audit F5, same answers): _getClusterNode for every source
	-- looked its cluster and nodes up again (a coast is ~1,000 shore tiles in
	-- a few dozen clusters). Each cluster's live nodes are listed once per
	-- call, in the cluster's order, and the closest is chosen as there (the
	-- first on a tie).
	local width, size = map:width(), graph.clusterSize
	local clusterNodes: { [number]: { AbstractGraph.AbstractNode } } = {}
	local function nearestNode(tile: number): (AbstractGraph.AbstractNode?, number)
		local x, y = tile % width, tile // width
		local cx, cy = x // size, y // size
		local key = cy * 65536 + cx
		local nodes = clusterNodes[key]
		if nodes == nil then
			-- (no cluster, or none of its nodes live: an empty list, no node)
			local list = {}
			local cluster = graph:getCluster(cx, cy)
			if cluster ~= nil then
				for _, id in cluster.nodeIds do
					local node = graph:getNode(id)
					if node then
						table.insert(list, node)
					end
				end
			end
			nodes = list
			clusterNodes[key] = list
		end
		local best, bestDist = nil, math.huge
		for _, node in nodes do
			local dist = math.abs(node.x - x) + math.abs(node.y - y)
			if dist < bestDist then
				bestDist = dist
				best = node
			end
		end
		return best, bestDist
	end
	for _, source in sources do
		local node, dist = nearestNode(source)
		if node ~= nil then
			local prev = nodeToDist[node.id]
			if prev == nil or dist < prev then
				if prev == nil then
					table.insert(order, node.id)
				end
				nodeToSource[node.id] = source
				nodeToDist[node.id] = dist
			end
		end
	end
	if #order == 0 then
		return nil
	end
	local nodePath = self.abstractAStar:findPath(order, targetNode.id)
	if nodePath == nil then
		return nil
	end
	return self:findPathSingle(nodeToSource[nodePath[1]], target)
end

function AStarWaterHierarchical._tryShortPathMultiSource(self: AStarWaterHierarchical, sources: { number }, target: number): { number }?
	local map = self.map
	local candidates = {}
	for _, s in sources do
		if map:manhattanDist(s, target) <= SHORT_PATH_THRESHOLD then
			table.insert(candidates, s)
		end
	end
	if #candidates == 0 then
		return nil
	end
	local toX, toY = map:x(target), map:y(target)
	local minX, maxX, minY, maxY = toX, toX, toY, toY
	for _, s in candidates do
		local sx, sy = map:x(s), map:y(s)
		minX, maxX = math.min(minX, sx), math.max(maxX, sx)
		minY, maxY = math.min(minY, sy), math.max(maxY, sy)
	end
	return self.localAStarShortPath:searchBounded(candidates, target, {
		minX = math.max(0, minX - SHORT_PATH_PADDING),
		maxX = math.min(map:width() - 1, maxX + SHORT_PATH_PADDING),
		minY = math.max(0, minY - SHORT_PATH_PADDING),
		maxY = math.min(map:height() - 1, maxY + SHORT_PATH_PADDING),
	})
end

local function append(path: { number }, segment: { number }, from: number)
	for i = from, #segment do
		table.insert(path, segment[i])
	end
end

function AStarWaterHierarchical.findPathSingle(self: AStarWaterHierarchical, from: number, to: number): { number }?
	local map, graph = self.map, self.graph
	local clusterSize = graph.clusterSize
	if map:manhattanDist(from, to) <= clusterSize then
		local localPath = self:_findLocalPath(from, to, map:x(from) // clusterSize, map:y(from) // clusterSize, true)
		if localPath then
			return localPath
		end
	end
	local startNode = self:_findNearestNode(from)
	local endNode = self:_findNearestNode(to)
	if startNode == nil or endNode == nil then
		return nil
	end
	if startNode.id == endNode.id then
		return self:_findLocalPath(from, to, startNode.x // clusterSize, startNode.y // clusterSize, true)
	end
	local nodePath = self.abstractAStar:findPath(startNode.id, endNode.id)
	if nodePath == nil then
		return nil
	end

	local initialPath: { number } = {}
	-- 1. Start to the first node
	local firstNode = graph:getNode(nodePath[1]) :: AbstractGraph.AbstractNode
	local startSegment =
		self:_findLocalPath(from, firstNode.tile, map:x(from) // clusterSize, map:y(from) // clusterSize, false)
	if startSegment == nil then
		return nil
	end
	append(initialPath, startSegment, 1)
	-- 2. Through the abstract nodes
	for i = 1, #nodePath - 1 do
		local fromNodeId, toNodeId = nodePath[i], nodePath[i + 1]
		local edge = graph:getEdgeBetween(fromNodeId, toNodeId)
		if edge == nil then
			return nil
		end
		local cached = if self.cachePaths then graph:getCachedPath(edge.id, fromNodeId) else nil
		if cached and #cached > 0 then
			append(initialPath, cached, 2)
		else
			local fromTile = (graph:getNode(fromNodeId) :: AbstractGraph.AbstractNode).tile
			local toTile = (graph:getNode(toNodeId) :: AbstractGraph.AbstractNode).tile
			local segment = self:_findLocalPath(fromTile, toTile, edge.clusterX, edge.clusterY, false)
			if segment == nil then
				return nil
			end
			append(initialPath, segment, 2)
			if self.cachePaths then
				graph:setCachedPath(edge.id, fromNodeId, segment)
			end
		end
	end
	-- 3. The last node to the end
	local lastNode = graph:getNode(nodePath[#nodePath]) :: AbstractGraph.AbstractNode
	local endSegment = self:_findLocalPath(lastNode.tile, to, map:x(to) // clusterSize, map:y(to) // clusterSize, false)
	if endSegment == nil then
		return nil
	end
	append(initialPath, endSegment, 2)
	return initialPath
end

-- BFS through water from `tile` for one of its cluster's gateway nodes.
function AStarWaterHierarchical._findNearestNode(self: AStarWaterHierarchical, tile: number): AbstractGraph.AbstractNode?
	local map, graph = self.map, self.graph
	local clusterSize = graph.clusterSize
	local x, y = map:x(tile), map:y(tile)
	local clusterX, clusterY = x // clusterSize, y // clusterSize
	local minX, minY = clusterX * clusterSize, clusterY * clusterSize
	local maxX = math.min(map:width() - 1, minX + clusterSize - 1)
	local maxY = math.min(map:height() - 1, minY + clusterSize - 1)
	local cluster = graph:getCluster(clusterX, clusterY)
	if cluster == nil or #cluster.nodeIds == 0 then
		return nil
	end
	local candidates = {}
	for _, id in cluster.nodeIds do
		table.insert(candidates, graph:getNode(id) :: AbstractGraph.AbstractNode)
	end
	return self.tileBFS:search(map:width(), map:height(), tile, clusterSize * clusterSize, function(t: number): boolean
		return map:isWater(t)
	end, function(t: number, _dist: number): any
		local tx, ty = map:x(t), map:y(t)
		for _, node in candidates do
			if node.x == tx and node.y == ty then
				return node
			end
		end
		if tx < minX or tx > maxX or ty < minY or ty > maxY then
			return false -- reject
		end
		return nil
	end)
end

function AStarWaterHierarchical._findLocalPath(
	self: AStarWaterHierarchical,
	from: number,
	to: number,
	clusterX: number,
	clusterY: number,
	multiCluster: boolean
): { number }?
	local map = self.map
	local clusterSize = self.graph.clusterSize
	local minX, minY, maxX, maxY
	if multiCluster then
		-- 3×3 clusters centred on the starting cluster
		minX = math.max(0, (clusterX - 1) * clusterSize)
		minY = math.max(0, (clusterY - 1) * clusterSize)
		maxX = math.min(map:width() - 1, (clusterX + 2) * clusterSize - 1)
		maxY = math.min(map:height() - 1, (clusterY + 2) * clusterSize - 1)
	else
		minX = clusterX * clusterSize
		minY = clusterY * clusterSize
		maxX = math.min(map:width() - 1, minX + clusterSize - 1)
		maxY = math.min(map:height() - 1, minY + clusterSize - 1)
	end
	local astar = if multiCluster then self.localAStarMultiCluster else self.localAStar
	local path = astar:searchBounded(from, to, { minX = minX, maxX = maxX, minY = minY, maxY = maxY })
	if path == nil or #path == 0 then
		return nil
	end
	-- Bounded A* clamps endpoints to the box; restore the exact tiles.
	if path[1] ~= from then
		table.insert(path, 1, from)
	end
	if path[#path] ~= to then
		table.insert(path, to)
	end
	return path
end

return AStarWaterHierarchical
