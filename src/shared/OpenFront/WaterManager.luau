--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/WaterManager.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Owns the minimap water graph: connected water components, the abstract
-- graph and the hierarchical pathfinder ships route on, plus component
-- queries for full-map tiles.
-- Not yet ported: converting land to water (the water nukes modifier,
-- finalizeWaterChanges); queueing water tiles errors until nukes arrive.

local AStarWaterHierarchical = require(script.Parent.Pathfinding.AStarWaterHierarchical)
local AbstractGraph = require(script.Parent.Pathfinding.AbstractGraph)
local ConnectedComponents = require(script.Parent.Pathfinding.ConnectedComponents)

local WaterManager = {}
WaterManager.__index = WaterManager

export type WaterManager = typeof(setmetatable(
	{} :: {
		map: any,
		miniMap: any,
		disableNavMesh: boolean,
		miniWaterGraph_: AbstractGraph.AbstractGraph?,
		miniWaterHPA_: AStarWaterHierarchical.AStarWaterHierarchical?,
		miniWaterCC: ConnectedComponents.ConnectedComponents?,
		builderBFS: AbstractGraph.BFSGrid?,
		waterGraphVersion_: number,
		pendingWaterTiles: { number },
	},
	WaterManager
))

function WaterManager.new(map: any, miniMap: any, disableNavMesh: boolean): WaterManager
	local self: WaterManager = setmetatable({
		map = map,
		miniMap = miniMap,
		disableNavMesh = disableNavMesh,
		miniWaterGraph_ = nil,
		miniWaterHPA_ = nil,
		miniWaterCC = nil,
		builderBFS = nil,
		waterGraphVersion_ = 0,
		pendingWaterTiles = {},
	}, WaterManager) :: any
	if not disableNavMesh then
		local cc = ConnectedComponents.new(miniMap)
		cc:initialize()
		local bfs = AbstractGraph.BFSGrid.new(miniMap:width() * miniMap:height())
		local graph = AbstractGraph.Builder.new(miniMap, AbstractGraph.CLUSTER_SIZE, nil, nil, cc, bfs):build()
		self.miniWaterCC = cc
		self.builderBFS = bfs
		self.miniWaterGraph_ = graph
		self.miniWaterHPA_ = AStarWaterHierarchical.new(miniMap, graph, { cachePaths = true })
	end
	return self
end

function WaterManager.queueTile(self: WaterManager, tile: number)
	table.insert(self.pendingWaterTiles, tile)
end

-- Flushes queued water conversions; returns tiles whose terrain changed.
function WaterManager.tick(self: WaterManager, _currentTick: number): { number }
	if #self.pendingWaterTiles > 0 then
		error("water nukes (land to water) are not ported yet")
	end
	return {}
end

function WaterManager.waterGraphVersion(self: WaterManager): number
	return self.waterGraphVersion_
end

function WaterManager.miniWaterHPA(self: WaterManager): any?
	return self.miniWaterHPA_
end

function WaterManager.miniWaterGraph(self: WaterManager): AbstractGraph.AbstractGraph?
	return self.miniWaterGraph_
end

-- The water component near a full-map tile: its minimap tile if water,
-- else a water neighbour, else one two steps away (narrow straits).
function WaterManager.getWaterComponent(self: WaterManager, tile: number): number?
	local graph = self.miniWaterGraph_
	if graph == nil then
		return 0 -- permissive without a nav mesh
	end
	local mini = self.miniMap
	local miniTile = mini:ref(self.map:x(tile) // 2, self.map:y(tile) // 2)
	if mini:isWater(miniTile) then
		return graph:getComponentId(miniTile)
	end
	local neighbors = mini:neighbors(miniTile)
	for _, n in neighbors do
		if mini:isWater(n) then
			return graph:getComponentId(n)
		end
	end
	for _, n in neighbors do
		for _, n2 in mini:neighbors(n) do
			if mini:isWater(n2) then
				return graph:getComponentId(n2)
			end
		end
	end
	return nil
end

function WaterManager.hasWaterComponent(self: WaterManager, tile: number, component: number): boolean
	local graph = self.miniWaterGraph_
	if graph == nil then
		return true
	end
	local mini = self.miniMap
	local miniTile = mini:ref(self.map:x(tile) // 2, self.map:y(tile) // 2)
	if mini:isWater(miniTile) and graph:getComponentId(miniTile) == component then
		return true
	end
	local neighbors = mini:neighbors(miniTile)
	for _, n in neighbors do
		if mini:isWater(n) and graph:getComponentId(n) == component then
			return true
		end
	end
	for _, n in neighbors do
		for _, n2 in mini:neighbors(n) do
			if mini:isWater(n2) and graph:getComponentId(n2) == component then
				return true
			end
		end
	end
	return false
end

-- Approximate water tiles (full-map units) in the tile's component.
function WaterManager.getWaterComponentSize(self: WaterManager, tile: number): number?
	local componentId = self:getWaterComponent(tile)
	if componentId == nil then
		return nil
	end
	local graph = self.miniWaterGraph_
	if graph == nil then
		return 0
	end
	return graph:getComponentSize(componentId) * 4
end

return WaterManager
