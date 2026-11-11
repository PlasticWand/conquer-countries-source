--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/algorithms/AbstractGraph.ts and BFS.Grid.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The coarse water graph for hierarchical pathfinding, built on the minimap.
--   - The map is cut into 32×32 clusters.
--   - Each water opening on a cluster boundary becomes a gateway node (the
--     middle of the span).
--   - Gateways in the same cluster that reach each other by water inside it
--     are joined by an edge whose cost is the BFS distance.
--   - Node and edge ids are 0-based, as in the original; edges are
--     renumbered by (nodeA, nodeB) after building.

local ConnectedComponents = require(script.Parent.ConnectedComponents)

export type AbstractNode = { id: number, x: number, y: number, tile: number, componentId: number }
export type AbstractEdge = { id: number, nodeA: number, nodeB: number, cost: number, clusterX: number, clusterY: number }
export type Cluster = { x: number, y: number, nodeIds: { number } }

-- BFS.Grid.ts: 4-direction grid BFS with stamp-based visited tracking.
local BFSGrid = {}
BFSGrid.__index = BFSGrid

export type BFSGrid = typeof(setmetatable(
	{} :: { stamp: number, visitedStamp: buffer, queue: buffer, dist: buffer },
	BFSGrid
))

function BFSGrid.new(numNodes: number): BFSGrid
	return setmetatable({
		stamp = 1,
		visitedStamp = buffer.create(numNodes * 4),
		queue = buffer.create(numNodes * 4),
		dist = buffer.create(numNodes * 2),
	}, BFSGrid)
end

-- visitor(node, dist) returns a value to stop with it, nil to explore the
-- node's neighbours, or false to reject the node (the original's null).
function BFSGrid.search(
	self: BFSGrid,
	width: number,
	height: number,
	start: number | { number },
	maxDistance: number,
	isValidNode: (number) -> boolean,
	visitor: (number, number) -> any
): any
	local stamp = self.stamp
	self.stamp += 1
	if self.stamp > 0xffffffff then
		buffer.fill(self.visitedStamp, 0, 0)
		self.stamp = 1
	end
	local visited, queue, distBuf = self.visitedStamp, self.queue, self.dist
	local lastRowStart = (height - 1) * width
	local starts: { number } = if type(start) == "number" then { start } else start :: { number }
	local head, tail = 0, 0
	for _, s in starts do
		buffer.writeu32(visited, s * 4, stamp)
		buffer.writeu16(distBuf, s * 2, 0)
		buffer.writei32(queue, tail * 4, s)
		tail += 1
	end
	local function visit(n: number, nextDist: number)
		if buffer.readu32(visited, n * 4) ~= stamp and isValidNode(n) then
			buffer.writeu32(visited, n * 4, stamp)
			buffer.writeu16(distBuf, n * 2, nextDist % 65536)
			buffer.writei32(queue, tail * 4, n)
			tail += 1
		end
	end
	while head < tail do
		local node = buffer.readi32(queue, head * 4)
		head += 1
		local dist = buffer.readu16(distBuf, node * 2)
		local result = visitor(node, dist)
		if result ~= nil and result ~= false then
			return result
		end
		if result == nil then
			local nextDist = dist + 1
			if nextDist <= maxDistance then
				local x = node % width
				if node >= width then
					visit(node - width, nextDist)
				end
				if node < lastRowStart then
					visit(node + width, nextDist)
				end
				if x ~= 0 then
					visit(node - 1, nextDist)
				end
				if x ~= width - 1 then
					visit(node + 1, nextDist)
				end
			end
		end
	end
	return nil
end

-- AbstractGraph ------------------------------------------------------------------

local AbstractGraph = {}
AbstractGraph.__index = AbstractGraph
AbstractGraph.BFSGrid = BFSGrid
AbstractGraph.CLUSTER_SIZE = 32

export type AbstractGraph = typeof(setmetatable(
	{} :: {
		clusterSize: number,
		clustersX: number,
		clustersY: number,
		_nodes: { [number]: AbstractNode },
		_nodeCount: number,
		_edges: { [number]: AbstractEdge },
		_edgeCount: number,
		_nodeEdgeIds: { [number]: { number } },
		_clusters: { [number]: Cluster },
		_pathCache: { [number]: { number } },
		_waterComponents: ConnectedComponents.ConnectedComponents?,
		nodeCount: number,
		edgeCount: number,
	},
	AbstractGraph
))

function AbstractGraph.new(clusterSize: number, clustersX: number, clustersY: number): AbstractGraph
	return setmetatable({
		clusterSize = clusterSize,
		clustersX = clustersX,
		clustersY = clustersY,
		_nodes = {},
		_nodeCount = 0,
		_edges = {},
		_edgeCount = 0,
		_nodeEdgeIds = {},
		_clusters = {},
		_pathCache = {},
		_waterComponents = nil,
		nodeCount = 0,
		edgeCount = 0,
	}, AbstractGraph)
end

function AbstractGraph.getNode(self: AbstractGraph, id: number): AbstractNode?
	return self._nodes[id]
end

function AbstractGraph.getEdge(self: AbstractGraph, id: number): AbstractEdge?
	return self._edges[id]
end

function AbstractGraph.getNodeEdges(self: AbstractGraph, nodeId: number): { AbstractEdge }
	local ids = self._nodeEdgeIds[nodeId]
	local out = {}
	if ids then
		for _, id in ids do
			local e = self._edges[id]
			if e then
				table.insert(out, e)
			end
		end
	end
	return out
end

function AbstractGraph.getEdgeBetween(self: AbstractGraph, nodeA: number, nodeB: number): AbstractEdge?
	local ids = self._nodeEdgeIds[nodeA]
	if ids == nil then
		return nil
	end
	for _, id in ids do
		local edge = self._edges[id]
		if edge.nodeA == nodeB or edge.nodeB == nodeB then
			return edge
		end
	end
	return nil
end

function AbstractGraph.getOtherNode(_self: AbstractGraph, edge: AbstractEdge, nodeId: number): number
	return if edge.nodeA == nodeId then edge.nodeB else edge.nodeA
end

-- Cached tile path along an edge, per direction (from nodeA or from nodeB).
function AbstractGraph.getCachedPath(self: AbstractGraph, edgeId: number, fromNodeId: number): { number }?
	local edge = self._edges[edgeId]
	if edge == nil then
		return nil
	end
	local direction = if fromNodeId == edge.nodeA then 0 else 1
	return self._pathCache[edgeId * 2 + direction]
end

function AbstractGraph.setCachedPath(self: AbstractGraph, edgeId: number, fromNodeId: number, path: { number })
	local edge = self._edges[edgeId]
	if edge == nil then
		return
	end
	local direction = if fromNodeId == edge.nodeA then 0 else 1
	self._pathCache[edgeId * 2 + direction] = path
end

function AbstractGraph.setWaterComponents(self: AbstractGraph, wc: ConnectedComponents.ConnectedComponents)
	self._waterComponents = wc
end

function AbstractGraph.getComponentId(self: AbstractGraph, tile: number): number
	local wc = self._waterComponents
	return if wc then wc:getComponentId(tile) else 0
end

function AbstractGraph.getComponentSize(self: AbstractGraph, componentId: number): number
	local wc = self._waterComponents
	return if wc then wc:getComponentSize(componentId) else 0
end

function AbstractGraph.getClusterKey(self: AbstractGraph, clusterX: number, clusterY: number): number
	return clusterY * self.clustersX + clusterX
end

function AbstractGraph.getCluster(self: AbstractGraph, clusterX: number, clusterY: number): Cluster?
	-- No range check, like the original: an out-of-range x can wrap into the
	-- neighbouring row's key, and a key outside the array is nil.
	return self._clusters[self:getClusterKey(clusterX, clusterY)]
end

function AbstractGraph.getClusterNodes(self: AbstractGraph, clusterX: number, clusterY: number): { AbstractNode }
	local cluster = self:getCluster(clusterX, clusterY)
	local out = {}
	if cluster then
		for _, id in cluster.nodeIds do
			table.insert(out, self._nodes[id])
		end
	end
	return out
end

function AbstractGraph.getNearbyClusterNodes(self: AbstractGraph, clusterX: number, clusterY: number): { AbstractNode }
	local out = {}
	for dy = -1, 1 do
		for dx = -1, 1 do
			local cluster = self:getCluster(clusterX + dx, clusterY + dy)
			if cluster then
				for _, id in cluster.nodeIds do
					table.insert(out, self._nodes[id])
				end
			end
		end
	end
	return out
end

function AbstractGraph._addNode(self: AbstractGraph, node: AbstractNode)
	self._nodes[node.id] = node
	self._nodeEdgeIds[node.id] = {}
	self.nodeCount = math.max(self.nodeCount, node.id + 1)
end

function AbstractGraph._addEdge(self: AbstractGraph, edge: AbstractEdge)
	self._edges[edge.id] = edge
	self.edgeCount = math.max(self.edgeCount, edge.id + 1)
	table.insert(self._nodeEdgeIds[edge.nodeA], edge.id)
	table.insert(self._nodeEdgeIds[edge.nodeB], edge.id)
end

-- Renumbers edges by (nodeA, nodeB) so partial and full builds match.
function AbstractGraph._sortEdges(self: AbstractGraph)
	local list = {}
	for i = 0, self.edgeCount - 1 do
		table.insert(list, self._edges[i])
	end
	table.sort(list, function(a, b)
		if a.nodeA ~= b.nodeA then
			return a.nodeA < b.nodeA
		end
		return a.nodeB < b.nodeB
	end)
	for _, ids in self._nodeEdgeIds do
		table.clear(ids)
	end
	self._edges = {}
	for i, edge in list do
		local id = i - 1
		edge.id = id
		self._edges[id] = edge
		table.insert(self._nodeEdgeIds[edge.nodeA], id)
		table.insert(self._nodeEdgeIds[edge.nodeB], id)
	end
end

function AbstractGraph._initPathCache(self: AbstractGraph)
	self._pathCache = {}
end

-- AbstractGraphBuilder -------------------------------------------------------------

local Builder = {}
Builder.__index = Builder
AbstractGraph.Builder = Builder

export type Builder = typeof(setmetatable(
	{} :: {
		map: any,
		clusterSize: number,
		oldGraph: AbstractGraph?,
		dirtyMiniTiles: { [number]: true }?,
		dirtyOrder: { number }?,
		sharedWaterComponents: ConnectedComponents.ConnectedComponents?,
		width: number,
		height: number,
		clustersX: number,
		clustersY: number,
		tileBFS: BFSGrid,
		waterComponents: ConnectedComponents.ConnectedComponents,
		graph: AbstractGraph,
		tileToNode: { [number]: AbstractNode },
		nextNodeId: number,
		nextEdgeId: number,
		edgeBetween: { [number]: { [number]: AbstractEdge } },
		cleanClusters: { [number]: true }?,
		oldEdgeCosts: { [number]: { [number]: { cost: number, clusterX: number, clusterY: number } } }?,
	},
	Builder
))

-- `dirtyMiniTiles` (in insertion order) marks changed water for a partial
-- rebuild against `oldGraph`; `sharedWaterComponents` is an up-to-date
-- labelling kept by the caller (WaterManager).
function Builder.new(
	map: any,
	clusterSize: number?,
	oldGraph: AbstractGraph?,
	dirtyMiniTiles: { number }?,
	sharedWaterComponents: ConnectedComponents.ConnectedComponents?,
	sharedTileBFS: BFSGrid?
): Builder
	local size = clusterSize or AbstractGraph.CLUSTER_SIZE
	local width, height = map:width(), map:height()
	local dirtySet: { [number]: true }? = nil
	if dirtyMiniTiles then
		local set: { [number]: true } = {}
		for _, t in dirtyMiniTiles do
			set[t] = true
		end
		dirtySet = set
	end
	return setmetatable({
		map = map,
		clusterSize = size,
		oldGraph = oldGraph,
		dirtyMiniTiles = dirtySet,
		dirtyOrder = dirtyMiniTiles,
		sharedWaterComponents = sharedWaterComponents,
		width = width,
		height = height,
		clustersX = math.ceil(width / size),
		clustersY = math.ceil(height / size),
		tileBFS = sharedTileBFS or BFSGrid.new(width * height),
		waterComponents = sharedWaterComponents or ConnectedComponents.new(map),
		graph = AbstractGraph.new(size, 0, 0),
		tileToNode = {},
		nextNodeId = 0,
		nextEdgeId = 0,
		edgeBetween = {},
		cleanClusters = nil,
		oldEdgeCosts = nil,
	}, Builder)
end

function Builder.build(self: Builder): AbstractGraph
	self.graph = AbstractGraph.new(self.clusterSize, self.clustersX, self.clustersY)
	local graph = self.graph
	if not self.sharedWaterComponents then
		self.waterComponents:initialize()
	end
	if self.oldGraph and self.dirtyOrder and #(self.dirtyOrder :: { number }) > 0 then
		self:_computePartialRebuildInfo()
	end
	for cy = 0, self.clustersY - 1 do
		for cx = 0, self.clustersX - 1 do
			graph._clusters[graph:getClusterKey(cx, cy)] = { x = cx, y = cy, nodeIds = {} }
		end
	end
	for cy = 0, self.clustersY - 1 do
		for cx = 0, self.clustersX - 1 do
			self:_processCluster(cx, cy)
		end
	end
	for cy = 0, self.clustersY - 1 do
		for cx = 0, self.clustersX - 1 do
			local cluster = graph:getCluster(cx, cy)
			if cluster and #cluster.nodeIds > 0 then
				self:_buildClusterConnections(cx, cy)
			end
		end
	end
	graph:_sortEdges()
	graph:_initPathCache()
	graph:setWaterComponents(self.waterComponents)
	return graph
end

function Builder._getOrCreateNode(self: Builder, x: number, y: number): AbstractNode
	local tile = self.map:ref(x, y)
	local existing = self.tileToNode[tile]
	if existing then
		return existing
	end
	local node = { id = self.nextNodeId, x = x, y = y, tile = tile, componentId = self.waterComponents:getComponentId(tile) }
	self.nextNodeId += 1
	self.graph:_addNode(node)
	self.tileToNode[tile] = node
	return node
end

function Builder._addNodeToCluster(self: Builder, clusterX: number, clusterY: number, node: AbstractNode)
	local cluster = self.graph:getCluster(clusterX, clusterY)
	if cluster and not table.find(cluster.nodeIds, node.id) then
		table.insert(cluster.nodeIds, node.id)
	end
end

function Builder._processCluster(self: Builder, cx: number, cy: number)
	local size = self.clusterSize
	local baseX, baseY = cx * size, cy * size
	if cx < self.clustersX - 1 then
		local edgeX = math.min(baseX + size - 1, self.width - 1)
		for _, node in self:_findNodesOnVerticalEdge(edgeX, baseY) do
			self:_addNodeToCluster(cx, cy, node)
			self:_addNodeToCluster(cx + 1, cy, node)
		end
	end
	if cy < self.clustersY - 1 then
		local edgeY = math.min(baseY + size - 1, self.height - 1)
		for _, node in self:_findNodesOnHorizontalEdge(edgeY, baseX) do
			self:_addNodeToCluster(cx, cy, node)
			self:_addNodeToCluster(cx, cy + 1, node)
		end
	end
end

function Builder._findNodesOnVerticalEdge(self: Builder, x: number, baseY: number): { AbstractNode }
	local nodes = {}
	local map = self.map
	local maxY = math.min(baseY + self.clusterSize, self.height)
	local spanStart = -1
	local function tryAddNode(y: number)
		if spanStart == -1 then
			return
		end
		local midY = spanStart + (y - spanStart) // 2
		spanStart = -1
		table.insert(nodes, self:_getOrCreateNode(x, midY))
	end
	for y = baseY, maxY - 1 do
		local tile = map:ref(x, y)
		local nextTile = if x + 1 < map:width() then map:ref(x + 1, y) else -1
		local isEntrance = map:isWater(tile) and nextTile ~= -1 and map:isWater(nextTile)
		if isEntrance then
			if spanStart == -1 then
				spanStart = y
			end
		else
			tryAddNode(y)
		end
	end
	tryAddNode(maxY)
	return nodes
end

function Builder._findNodesOnHorizontalEdge(self: Builder, y: number, baseX: number): { AbstractNode }
	local nodes = {}
	local map = self.map
	local maxX = math.min(baseX + self.clusterSize, self.width)
	local spanStart = -1
	local function tryAddNode(x: number)
		if spanStart == -1 then
			return
		end
		local midX = spanStart + (x - spanStart) // 2
		spanStart = -1
		table.insert(nodes, self:_getOrCreateNode(midX, y))
	end
	for x = baseX, maxX - 1 do
		local tile = map:ref(x, y)
		local nextTile = if y + 1 < map:height() then map:ref(x, y + 1) else -1
		local isEntrance = map:isWater(tile) and nextTile ~= -1 and map:isWater(nextTile)
		if isEntrance then
			if spanStart == -1 then
				spanStart = x
			end
		else
			tryAddNode(x)
		end
	end
	tryAddNode(maxX)
	return nodes
end

function Builder._buildClusterConnections(self: Builder, cx: number, cy: number)
	local clusterKey = cy * self.clustersX + cx
	local clean = self.cleanClusters
	if clean and clean[clusterKey] then
		self:_buildClusterConnectionsFromCache(cx, cy)
		return
	end
	local graph = self.graph
	local cluster = graph:getCluster(cx, cy)
	if cluster == nil then
		return
	end
	local nodes = {}
	for _, id in cluster.nodeIds do
		table.insert(nodes, graph:getNode(id) :: AbstractNode)
	end
	local size = self.clusterSize
	local minX, minY = cx * size, cy * size
	local maxX = math.min(self.width - 1, minX + size - 1)
	local maxY = math.min(self.height - 1, minY + size - 1)
	for i = 1, #nodes do
		local fromNode = nodes[i]
		local targets = {}
		for j = i + 1, #nodes do
			if nodes[i].componentId == nodes[j].componentId then
				table.insert(targets, nodes[j])
			end
		end
		if #targets > 0 then
			local reachedOrder, reached = self:_findAllReachableNodesInBounds(fromNode.tile, targets, minX, maxX, minY, maxY)
			for _, targetId in reachedOrder do
				self:_addOrUpdateEdge(fromNode.id, targetId, reached[targetId], cx, cy)
			end
		end
	end
end

-- Edges are stored once, lower node id first; a cheaper cost (and its
-- cluster) replaces a dearer one.
function Builder._addOrUpdateEdge(self: Builder, nodeIdA: number, nodeIdB: number, cost: number, clusterX: number, clusterY: number)
	local lo, hi = math.min(nodeIdA, nodeIdB), math.max(nodeIdA, nodeIdB)
	local nodeMap = self.edgeBetween[lo]
	if nodeMap == nil then
		nodeMap = {}
		self.edgeBetween[lo] = nodeMap
	end
	local existing = nodeMap[hi]
	if existing then
		if cost < existing.cost then
			existing.cost = cost
			existing.clusterX = clusterX
			existing.clusterY = clusterY
		end
		return
	end
	local edge = { id = self.nextEdgeId, nodeA = lo, nodeB = hi, cost = cost, clusterX = clusterX, clusterY = clusterY }
	self.nextEdgeId += 1
	nodeMap[hi] = edge
	self.graph:_addEdge(edge)
end

-- BFS inside the cluster bounds from `from`; returns the reached target node
-- ids in discovery order and their distances.
function Builder._findAllReachableNodesInBounds(
	self: Builder,
	from: number,
	targets: { AbstractNode },
	minX: number,
	maxX: number,
	minY: number,
	maxY: number
): ({ number }, { [number]: number })
	local map = self.map
	local fromX, fromY = map:x(from), map:y(from)
	local tileToNodeId: { [number]: number } = {}
	local maxManhattan = 0
	for _, node in targets do
		tileToNodeId[node.tile] = node.id
		maxManhattan = math.max(maxManhattan, math.abs(node.x - fromX) + math.abs(node.y - fromY))
	end
	local maxDistance = maxManhattan * 4 -- allow path deviation
	local order: { number } = {}
	local reachable: { [number]: number } = {}
	local foundCount = 0
	self.tileBFS:search(map:width(), map:height(), from, maxDistance, function(tile: number): boolean
		return map:isWater(tile)
	end, function(tile: number, dist: number): any
		local x, y = map:x(tile), map:y(tile)
		local isStartOrTarget = tile == from or tileToNodeId[tile] ~= nil
		if not isStartOrTarget and (x < minX or x > maxX or y < minY or y > maxY) then
			return false -- reject: outside the cluster
		end
		local nodeId = tileToNodeId[tile]
		if nodeId ~= nil then
			if reachable[nodeId] == nil then
				table.insert(order, nodeId)
			end
			reachable[nodeId] = dist
			foundCount += 1
			if foundCount == #targets then
				return true -- found them all: stop
			end
		end
		return nil
	end)
	return order, reachable
end

-- Clusters untouched by water changes reuse the old graph's edge costs.
function Builder._computePartialRebuildInfo(self: Builder)
	local oldGraph = self.oldGraph :: AbstractGraph
	local map = self.map
	local size = self.clusterSize
	local primaryDirty: { [number]: true } = {}
	local primaryOrder = {}
	for _, tile in self.dirtyOrder :: { number } do
		local key = (map:y(tile) // size) * self.clustersX + (map:x(tile) // size)
		if not primaryDirty[key] then
			primaryDirty[key] = true
			table.insert(primaryOrder, key)
		end
	end
	local expanded: { [number]: true } = {}
	for _, key in primaryOrder do
		local cy = key // self.clustersX
		local cx = key - cy * self.clustersX
		for dy = -1, 1 do
			for dx = -1, 1 do
				local nx, ny = cx + dx, cy + dy
				if nx >= 0 and nx < self.clustersX and ny >= 0 and ny < self.clustersY then
					expanded[ny * self.clustersX + nx] = true
				end
			end
		end
	end
	local clean: { [number]: true } = {}
	for k = 0, self.clustersX * self.clustersY - 1 do
		if not expanded[k] then
			clean[k] = true
		end
	end
	self.cleanClusters = clean
	local costs: { [number]: { [number]: { cost: number, clusterX: number, clusterY: number } } } = {}
	for i = 0, oldGraph.edgeCount - 1 do
		local edge = oldGraph._edges[i]
		local a, b = oldGraph:getNode(edge.nodeA), oldGraph:getNode(edge.nodeB)
		if a and b then
			local tMin, tMax = math.min(a.tile, b.tile), math.max(a.tile, b.tile)
			local inner = costs[tMin]
			if inner == nil then
				inner = {}
				costs[tMin] = inner
			end
			local existing = inner[tMax]
			if existing == nil or edge.cost < existing.cost then
				inner[tMax] = { cost = edge.cost, clusterX = edge.clusterX, clusterY = edge.clusterY }
			end
		end
	end
	self.oldEdgeCosts = costs
end

function Builder._buildClusterConnectionsFromCache(self: Builder, cx: number, cy: number)
	local graph = self.graph
	local cluster = graph:getCluster(cx, cy)
	if cluster == nil then
		return
	end
	local nodes = {}
	for _, id in cluster.nodeIds do
		table.insert(nodes, graph:getNode(id) :: AbstractNode)
	end
	local costs = self.oldEdgeCosts :: { [number]: { [number]: any } }
	for i = 1, #nodes do
		for j = i + 1, #nodes do
			if nodes[i].componentId == nodes[j].componentId then
				local tMin, tMax = math.min(nodes[i].tile, nodes[j].tile), math.max(nodes[i].tile, nodes[j].tile)
				local inner = costs[tMin]
				local entry = inner and inner[tMax]
				if entry ~= nil then
					-- Keep the original cluster: its BFS found this edge's path.
					self:_addOrUpdateEdge(nodes[i].id, nodes[j].id, entry.cost, entry.clusterX, entry.clusterY)
				end
			end
		end
	end
end

return AbstractGraph
