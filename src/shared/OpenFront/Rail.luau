--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/{RailNetworkImpl,TrainStation,Railroad,RailroadSpatialGrid}.ts and pathfinding/PathFinder.Station.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The rail network. Factories, and cities and ports near one, are train
-- stations joined by railroads laid on the minimap.
--   - A new station snaps onto rails passing within 3 tiles (splitting
--     them), else connects to stations within trainStationMaxRange that
--     are farther than trainStationMinRange and not already within 4 hops.
--   - Clusters are the connected station groups; trains only run inside
--     one. Clusters split lazily (RecomputeRailClusterExecution).
--   - Every Set and Map here keeps JS insertion order (OrderedSet), because
--     iteration order picks destinations and rail splits.

local AStar = require(script.Parent.Pathfinding.AStar)
local GameTypes = require(script.Parent.GameTypes)
local PseudoRandom = require(script.Parent.PseudoRandom)
local Transformers = require(script.Parent.Pathfinding.Transformers)

local UnitType = GameTypes.UnitType

local Rail = {}

-- OrderedSet: a JS Set (insertion order; re-adding keeps the place).
local OrderedSet = {}
OrderedSet.__index = OrderedSet
Rail.OrderedSet = OrderedSet

export type OrderedSet = typeof(setmetatable({} :: { list: { any }, index: { [any]: number } }, OrderedSet))

function OrderedSet.new(items: { any }?): OrderedSet
	local self = setmetatable({ list = {}, index = {} }, OrderedSet)
	if items then
		for _, v in items do
			self:add(v)
		end
	end
	return self
end

function OrderedSet.add(self: OrderedSet, v: any)
	if self.index[v] == nil then
		table.insert(self.list, v)
		self.index[v] = #self.list
	end
end

function OrderedSet.has(self: OrderedSet, v: any): boolean
	return self.index[v] ~= nil
end

function OrderedSet.delete(self: OrderedSet, v: any): boolean
	local i = self.index[v]
	if i == nil then
		return false
	end
	table.remove(self.list, i)
	self.index[v] = nil
	for k = i, #self.list do
		self.index[self.list[k]] = k
	end
	return true
end

function OrderedSet.size(self: OrderedSet): number
	return #self.list
end

function OrderedSet.clear(self: OrderedSet)
	table.clear(self.list)
	table.clear(self.index)
end

-- A snapshot of the members, safe to iterate while the set changes (JS
-- iteration visits the same elements when only the current one is removed).
function OrderedSet.values(self: OrderedSet): { any }
	return table.clone(self.list)
end

function OrderedSet.first(self: OrderedSet): any
	return self.list[1]
end

-- Railroad ---------------------------------------------------------------------------

local Railroad = {}
Railroad.__index = Railroad
Rail.Railroad = Railroad

function Railroad.new(from: any, to: any, tiles: { number }, id: number): any
	return setmetatable({ from = from, to = to, tiles = tiles, id = id }, Railroad)
end

function Railroad.delete(self: any, game: any)
	game:addUpdate({ type = "RailroadDestructionEvent", id = self.id })
	self.from:removeRailroad(self)
	self.to:removeRailroad(self)
end

-- 0-based index of the rail tile closest to `to`, or -1.
function Railroad.getClosestTileIndex(self: any, game: any, to: number): number
	if #self.tiles == 0 then
		return -1
	end
	local toX, toY = game:x(to), game:y(to)
	local closest, minD = 0, math.huge
	for i, tile in self.tiles do
		local dx, dy = game:x(tile) - toX, game:y(tile) - toY
		local d = dx * dx + dy * dy
		if d < minD then
			minD = d
			closest = i - 1
		end
	end
	return closest
end

-- A railroad seen from one end, so its tiles always start there.
local OrientedRailroad = {}
OrientedRailroad.__index = OrientedRailroad

function OrientedRailroad.new(railroad: any, forward: boolean): any
	local tiles = railroad.tiles
	if not forward then
		tiles = table.clone(tiles)
		local n = #tiles
		for i = 1, n // 2 do
			tiles[i], tiles[n - i + 1] = tiles[n - i + 1], tiles[i]
		end
	end
	return setmetatable({ railroad = railroad, forward = forward, tiles = tiles }, OrientedRailroad)
end

function OrientedRailroad.getTiles(self: any): { number }
	return self.tiles
end
function OrientedRailroad.getStart(self: any): any
	return if self.forward then self.railroad.from else self.railroad.to
end
function OrientedRailroad.getEnd(self: any): any
	return if self.forward then self.railroad.to else self.railroad.from
end

function Rail.getOrientedRailroad(from: any, to: any): any?
	local railroad = from:getRailroadTo(to)
	if not railroad then
		return nil
	end
	return OrientedRailroad.new(railroad, railroad.to == to)
end

-- TrainStation -----------------------------------------------------------------------

local function rel(player: any, other: any): string
	if player == other then
		return "self"
	elseif player:isOnSameTeam(other) then
		return "team"
	elseif player:isAlliedWith(other) then
		return "ally"
	end
	return "other"
end

local TrainStation = {}
TrainStation.__index = TrainStation
Rail.TrainStation = TrainStation

function TrainStation.new(mg: any, unit: any): any
	-- The original seeds stop handlers with PseudoRandom(ticks) but never
	-- draws from it; created here only to keep the construction identical.
	local _ = PseudoRandom.new(mg:ticks())
	return setmetatable({
		mg = mg,
		unit = unit,
		id = -1,
		cluster = nil,
		railroads = OrderedSet.new(),
		railroadByNeighbor = {} :: { [any]: any },
	}, TrainStation)
end

function TrainStation.tradeAvailable(self: any, otherPlayer: any): boolean
	local player = self.unit:owner()
	return otherPlayer == player or player:canTrade(otherPlayer)
end

function TrainStation.clearRailroads(self: any)
	self.railroads:clear()
	table.clear(self.railroadByNeighbor)
end

function TrainStation.addRailroad(self: any, railroad: any)
	self.railroads:add(railroad)
	local neighbor = if railroad.from == self then railroad.to else railroad.from
	self.railroadByNeighbor[neighbor] = railroad
end

function TrainStation.removeRailroad(self: any, railroad: any)
	self.railroads:delete(railroad)
	local neighbor = if railroad.from == self then railroad.to else railroad.from
	self.railroadByNeighbor[neighbor] = nil
end

function TrainStation.neighbors(self: any): { any }
	local out = {}
	for _, r in self.railroads.list do
		table.insert(out, if r.from ~= self then r.from else r.to)
	end
	return out
end

function TrainStation.tile(self: any): number
	return self.unit:tile()
end

function TrainStation.isActive(self: any): boolean
	return self.unit:isActive()
end

function TrainStation.getRailroads(self: any): OrderedSet
	return self.railroads
end

function TrainStation.getRailroadTo(self: any, station: any): any?
	return self.railroadByNeighbor[station]
end

function TrainStation.setCluster(self: any, cluster: any?)
	if self.cluster ~= nil and self.cluster ~= cluster then
		self.cluster:removeStation(self)
	end
	self.cluster = cluster
end

function TrainStation.getCluster(self: any): any?
	return self.cluster
end

-- Cities and ports pay the train's owner (and the station's owner, if
-- someone else) trainGold for the relation and stops so far.
function TrainStation.onTrainStop(self: any, train: any)
	local t = self.unit:type()
	if t ~= UnitType.City and t ~= UnitType.Port then
		return
	end
	-- Conquest's Sabotage (ARSENAL_V2): a dark station pays nothing.
	if self.unit:isDark() then
		return
	end
	local mg = self.mg
	local stationOwner = self.unit:owner()
	local trainOwner = train:owner()
	local gold = mg:config():trainGold(rel(trainOwner, stationOwner), train:tradeStopsVisited(), trainOwner)
	if trainOwner ~= stationOwner then
		stationOwner:addGold(gold, self:tile())
		stationOwner:addTrainGold(gold)
		mg:stats():trainExternalTrade(stationOwner, gold)
	end
	trainOwner:addGold(gold, self:tile())
	trainOwner:addTrainGold(gold)
	mg:stats():trainSelfTrade(trainOwner, gold)
end

-- Cluster ----------------------------------------------------------------------------

local Cluster = {}
Cluster.__index = Cluster
Rail.Cluster = Cluster

function Cluster.new(): any
	return setmetatable({ stations = OrderedSet.new(), tradeStations = OrderedSet.new() }, Cluster)
end

local function isTradeStation(station: any): boolean
	local t = station.unit:type()
	return t == UnitType.City or t == UnitType.Port
end

function Cluster.has(self: any, station: any): boolean
	return self.stations:has(station)
end

function Cluster.addStation(self: any, station: any)
	self.stations:add(station)
	if isTradeStation(station) then
		self.tradeStations:add(station)
	end
	station:setCluster(self)
end

function Cluster.removeStation(self: any, station: any)
	self.stations:delete(station)
	self.tradeStations:delete(station)
end

function Cluster.addStations(self: any, stations: { any })
	for _, s in stations do
		self:addStation(s)
	end
end

function Cluster.merge(self: any, other: any)
	for _, s in other.stations:values() do
		self:addStation(s)
	end
end

function Cluster.hasAnyTradeDestination(self: any, player: any): boolean
	for _, station in self.tradeStations.list do
		if station:tradeAvailable(player) then
			return true
		end
	end
	return false
end

-- Reservoir sampling over eligible trade stations.
function Cluster.randomTradeDestination(self: any, player: any, random: any): any?
	local selected = nil
	local seen = 0
	for _, station in self.tradeStations.list do
		if station:tradeAvailable(player) then
			seen += 1
			if random:nextInt(0, seen) == 0 then
				selected = station
			end
		end
	end
	return selected
end

function Cluster.size(self: any): number
	return self.stations:size()
end

function Cluster.clear(self: any)
	self.stations:clear()
	self.tradeStations:clear()
end

-- RailSpatialGrid --------------------------------------------------------------------

local RailSpatialGrid = {}
RailSpatialGrid.__index = RailSpatialGrid

function RailSpatialGrid.new(game: any, cellSize: number): any
	return setmetatable({ game = game, cellSize = cellSize, cells = {} :: { [string]: OrderedSet }, railToCells = {} :: { [any]: { string } } }, RailSpatialGrid)
end

-- JS Math.floor(x / cellSize) on possibly negative coordinates.
function RailSpatialGrid._key(self: any, x: number, y: number): (number, number, string)
	local cx, cy = math.floor(x / self.cellSize), math.floor(y / self.cellSize)
	return cx, cy, `{cx},{cy}`
end

function RailSpatialGrid.register(self: any, rail: any)
	self:unregister(rail)
	local keys: { string } = {}
	local seen: { [string]: true } = {}
	for _, tile in rail.tiles do
		local _, _, k = self:_key(self.game:x(tile), self.game:y(tile))
		if not seen[k] then
			seen[k] = true
			local set = self.cells[k]
			if set == nil then
				set = OrderedSet.new()
				self.cells[k] = set
			end
			table.insert(keys, k)
			set:add(rail)
		end
	end
	if #keys > 0 then
		self.railToCells[rail] = keys
	end
end

function RailSpatialGrid.unregister(self: any, rail: any)
	local keys = self.railToCells[rail]
	if not keys then
		return
	end
	for _, k in keys do
		local set = self.cells[k]
		if set then
			set:delete(rail)
			if set:size() == 0 then
				self.cells[k] = nil
			end
		end
	end
	self.railToCells[rail] = nil
end

-- Rails with a tile in a cell touching the square of `radius` round `tile`,
-- by cell column, then row, then registration order.
function RailSpatialGrid.query(self: any, tile: number, radius: number): OrderedSet
	local x, y = self.game:x(tile), self.game:y(tile)
	local c0x, c0y = self:_key(x - radius, y - radius)
	local c1x, c1y = self:_key(x + radius, y + radius)
	local result = OrderedSet.new()
	for cx = c0x, c1x do
		for cy = c0y, c1y do
			local set = self.cells[`{cx},{cy}`]
			if set then
				for _, rail in set.list do
					result:add(rail)
				end
			end
		end
	end
	return result
end

-- StationManager ---------------------------------------------------------------------

local StationManager = {}
StationManager.__index = StationManager

function StationManager.new(): any
	return setmetatable({ stations = OrderedSet.new(), stationsById = {} :: { [number]: any }, nextId = 1 }, StationManager)
end

function StationManager.addStation(self: any, station: any)
	station.id = self.nextId
	self.nextId += 1
	self.stationsById[station.id] = station
	self.stations:add(station)
end

function StationManager.removeStation(self: any, station: any)
	self.stationsById[station.id] = nil
	self.stations:delete(station)
end

function StationManager.findStation(self: any, unit: any): any?
	for _, station in self.stations.list do
		if station.unit == unit then
			return station
		end
	end
	return nil
end

function StationManager.getAll(self: any): OrderedSet
	return self.stations
end

function StationManager.getById(self: any, id: number): any?
	return self.stationsById[id]
end

function StationManager.count(self: any): number
	return self.nextId
end

-- Station A* (PathFinder.Station.ts) ------------------------------------------------

local StationAdapter = {}
StationAdapter.__index = StationAdapter

function StationAdapter.numNodes(self: any): number
	return self.manager:count()
end
function StationAdapter.maxNeighbors(_self: any): number
	return 32
end
function StationAdapter.maxPriority(self: any): number
	return self.game:map():width() + self.game:map():height()
end
function StationAdapter.neighbors(self: any, node: number, out: { number }): number
	local station = self.manager:getById(node)
	if not station then
		return 0
	end
	local count = 0
	for _, n in station:neighbors() do
		count += 1
		out[count] = n.id
	end
	return count
end
function StationAdapter.cost(_self: any): number
	return 1
end
function StationAdapter.heuristic(self: any, node: number, goal: number): number
	local a, b = self.manager:getById(node), self.manager:getById(goal)
	if not a or not b then
		return 0
	end
	local game = self.game
	return math.abs(game:x(a:tile()) - game:x(b:tile())) + math.abs(game:y(a:tile()) - game:y(b:tile()))
end

local function findStationsPath(game: any, manager: any, from: any, to: any): { any }
	if from:getCluster() ~= to:getCluster() then
		return {}
	end
	local aStar = AStar.new(setmetatable({ game = game, manager = manager }, StationAdapter))
	local ids = aStar:findPath({ from.id }, to.id)
	if not ids then
		return {}
	end
	local out = {}
	for _, id in ids do
		table.insert(out, manager:getById(id))
	end
	return out
end

-- RailNetwork ------------------------------------------------------------------------

local RailNetwork = {}
RailNetwork.__index = RailNetwork
Rail.RailNetwork = RailNetwork

local MAX_CONNECTION_DISTANCE = 4
local STATION_RADIUS = 3
local GRID_CELL_SIZE = 4

function RailNetwork.new(game: any): any
	return setmetatable({
		game = game,
		_stationManager = StationManager.new(),
		railGrid = RailSpatialGrid.new(game, GRID_CELL_SIZE),
		nextId = 0,
		dirtyClusters = OrderedSet.new(),
		_railFinder = nil,
	}, RailNetwork)
end

function RailNetwork.stationManager(self: any): any
	return self._stationManager
end

-- PathFinding.Rail: A* on the minimap, scaled up. One instance per game is
-- equivalent to the original's per-call one (its scratch is stamped).
function RailNetwork._findTilePath(self: any, from: number, to: number): { number }
	local game = self.game
	if not game:isValidRef(from) or not game:isValidRef(to) then
		return {}
	end
	local miniMap = game:miniMap()
	if self._railFinder == nil then
		self._railFinder = Transformers.MiniMap.new(AStar.new(AStar.RailAdapter.new(miniMap)) :: any, game:map(), miniMap)
	end
	-- Conquest: stations in different rail areas can't be joined; the search
	-- would fail anyway after exhausting its area (GameMap.railComponents).
	local map = game:map()
	local labels = miniMap:railComponents()
	local a = buffer.readu32(labels, miniMap:ref(map:x(from) // 2, map:y(from) // 2) * 4)
	local b = buffer.readu32(labels, miniMap:ref(map:x(to) // 2, map:y(to) // 2) * 4)
	if a ~= 0 and b ~= 0 and a ~= b then
		return {}
	end
	return self._railFinder:findPath(from, to) or {}
end

function RailNetwork.findStationsPath(self: any, from: any, to: any): { any }
	return findStationsPath(self.game, self._stationManager, from, to)
end

function RailNetwork.connectStation(self: any, station: any)
	self._stationManager:addStation(station)
	if not self:_connectToExistingRails(station) then
		self:_connectToNearbyStations(station)
	end
end

function RailNetwork.recomputeClusters(self: any)
	if self.dirtyClusters:size() == 0 then
		return
	end
	for _, cluster in self.dirtyClusters:values() do
		local remaining = OrderedSet.new(cluster.stations.list)
		while remaining:size() > 0 do
			local connected = self:_computeCluster(remaining:first())
			for _, s in connected.list do
				remaining:delete(s)
			end
			if remaining:size() > 0 then
				-- Moving them removes them from their old cluster.
				Cluster.new():addStations(connected.list)
			end
		end
	end
	self.dirtyClusters:clear()
end

function RailNetwork.removeStation(self: any, unit: any)
	local station = self._stationManager:findStation(unit)
	if not station then
		return
	end
	self:_disconnectFromNetwork(station)
	self._stationManager:removeStation(station)
	station.unit:setTrainStation(false)
	local cluster = station:getCluster()
	if not cluster then
		return
	end
	cluster:removeStation(station)
	if cluster:size() == 0 then
		self:_deleteCluster(cluster)
		self.dirtyClusters:delete(cluster)
		return
	end
	self.dirtyClusters:add(cluster)
end

function RailNetwork._connectToExistingRails(self: any, station: any): boolean
	local game = self.game
	local rails = self.railGrid:query(station:tile(), STATION_RADIUS)
	local edited = OrderedSet.new()
	for _, rail in rails.list do
		local from, to = rail.from, rail.to
		local originalId = rail.id
		local idx = rail:getClosestTileIndex(game, station:tile())
		if not (idx == 0 or idx >= #rail.tiles) then
			from:removeRailroad(rail)
			to:removeRailroad(rail)
			self.railGrid:unregister(rail)
			local newFrom = Railroad.new(from, station, table.move(rail.tiles, 1, idx, 1, {}), self.nextId)
			self.nextId += 1
			local newTo = Railroad.new(station, to, table.move(rail.tiles, idx + 1, #rail.tiles, 1, {}), self.nextId)
			self.nextId += 1
			station:addRailroad(newFrom)
			station:addRailroad(newTo)
			from:addRailroad(newFrom)
			to:addRailroad(newTo)
			self.railGrid:register(newTo)
			self.railGrid:register(newFrom)
			local cluster = from:getCluster()
			if cluster then
				cluster:addStation(station)
				edited:add(cluster)
			end
			game:addUpdate({
				type = "RailroadSnapEvent",
				originalId = originalId,
				newId1 = newFrom.id,
				newId2 = newTo.id,
				tiles1 = newFrom.tiles,
				tiles2 = newTo.tiles,
			})
		end
	end
	if edited:size() > 1 then
		self:_mergeClusters(edited)
	end
	return edited:size() ~= 0
end

-- Tiles of rails a structure placed here would snap onto, ascending.
function RailNetwork.overlappingRailroads(self: any, unitType: string, tile: number): { number }
	if unitType ~= UnitType.City and unitType ~= UnitType.Port and unitType ~= UnitType.Factory then
		return {}
	end
	local seen, out = {}, {}
	for _, railroad in self.railGrid:query(tile, STATION_RADIUS).list do
		for _, t in railroad.tiles do
			if not seen[t] then
				seen[t] = true
				table.insert(out, t)
			end
		end
	end
	table.sort(out)
	return out
end

-- Preview rails for the build menu (closest 5 connections).
function RailNetwork.computeGhostRailPaths(self: any, unitType: string, tile: number): { { number } }
	local game = self.game
	if unitType ~= UnitType.City and unitType ~= UnitType.Port and unitType ~= UnitType.Factory then
		return {}
	end
	if self.railGrid:query(tile, STATION_RADIUS):size() > 0 then
		return {}
	end
	local config = game:config()
	local maxRange = config:trainStationMaxRange()
	local minRangeSquared = config:trainStationMinRange() ^ 2
	local maxPathSize = config:railroadMaxSize()
	local buildingFactory = unitType == UnitType.Factory
	if not buildingFactory and not game:hasUnitNearby(tile, maxRange, UnitType.Factory) then
		return {}
	end
	local neighbors = game:nearbyUnits(tile, maxRange, { UnitType.City, UnitType.Factory, UnitType.Port })
	neighbors = require(script.Parent.Util).stableSort(neighbors, function(a: any, b: any)
		return a.distSquared < b.distSquared
	end)
	local paths, connected = {}, {}
	for _, neighbor in neighbors do
		if #paths >= 5 then
			break
		end
		if neighbor.distSquared > minRangeSquared then
			local neighborStation = self._stationManager:findStation(neighbor.unit)
			local targetTile: number? = nil
			if neighborStation then
				local reachable = false
				for _, s in connected do
					if self:_distanceFrom(neighborStation, s, MAX_CONNECTION_DISTANCE - 1) ~= -1 then
						reachable = true
						break
					end
				end
				if not reachable then
					targetTile = neighborStation:tile()
				end
			elseif buildingFactory then
				targetTile = neighbor.unit:tile()
			end
			if targetTile ~= nil then
				local path = if not neighborStation and neighbor.unit:type() == UnitType.City
					then self:_findTilePath(targetTile, tile)
					else self:_findTilePath(tile, targetTile)
				if #path > 0 and #path < maxPathSize then
					table.insert(paths, path)
					if neighborStation then
						table.insert(connected, neighborStation)
					end
				end
			end
		end
	end
	return paths
end

function RailNetwork._connectToNearbyStations(self: any, station: any)
	local game = self.game
	local config = game:config()
	local neighbors = game:nearbyUnits(station:tile(), config:trainStationMaxRange(), { UnitType.City, UnitType.Factory, UnitType.Port })
	neighbors = require(script.Parent.Util).stableSort(neighbors, function(a: any, b: any)
		return a.distSquared < b.distSquared
	end)
	local edited = OrderedSet.new()
	for _, neighbor in neighbors do
		if neighbor.unit ~= station.unit then
			local neighborStation = self._stationManager:findStation(neighbor.unit)
			if neighborStation then
				local distance = self:_distanceFrom(neighborStation, station, MAX_CONNECTION_DISTANCE)
				local neighborCluster = neighborStation:getCluster()
				if neighborCluster ~= nil then
					local available = distance > MAX_CONNECTION_DISTANCE or distance == -1
					if available and neighbor.distSquared > config:trainStationMinRange() ^ 2 then
						if self:_connect(station, neighborStation) then
							neighborCluster:addStation(station)
							edited:add(neighborCluster)
						end
					end
				end
			end
		end
	end
	if edited:size() > 1 then
		self:_mergeClusters(edited)
	elseif edited:size() == 0 then
		Cluster.new():addStation(station)
	end
end

function RailNetwork._disconnectFromNetwork(self: any, station: any)
	for _, rail in station:getRailroads():values() do
		rail:delete(self.game)
		self.railGrid:unregister(rail)
	end
	station:clearRailroads()
end

function RailNetwork._deleteCluster(_self: any, cluster: any)
	for _, station in cluster.stations:values() do
		station:setCluster(nil)
	end
	cluster:clear()
end

function RailNetwork._connect(self: any, from: any, to: any): boolean
	local game = self.game
	local path = self:_findTilePath(from:tile(), to:tile())
	if #path > 0 and #path < game:config():railroadMaxSize() then
		local railroad = Railroad.new(from, to, path, self.nextId)
		self.nextId += 1
		game:addUpdate({ type = "RailroadConstructionEvent", id = railroad.id, tiles = railroad.tiles })
		from:addRailroad(railroad)
		to:addRailroad(railroad)
		self.railGrid:register(railroad)
		return true
	end
	return false
end

-- Hops from start to dest (BFS), or -1 beyond maxDistance.
function RailNetwork._distanceFrom(_self: any, start: any, dest: any, maxDistance: number): number
	if start == dest then
		return 0
	end
	local visited: { [any]: true } = {}
	local queue = { { station = start, distance = 0 } }
	local head = 1
	while head <= #queue do
		local item = queue[head]
		head += 1
		if not visited[item.station] then
			visited[item.station] = true
			if item.distance < maxDistance then
				for _, neighbor in item.station:neighbors() do
					if neighbor == dest then
						return item.distance + 1
					end
					if not visited[neighbor] then
						table.insert(queue, { station = neighbor, distance = item.distance + 1 })
					end
				end
			end
		end
	end
	return -1
end

function RailNetwork._computeCluster(_self: any, start: any): OrderedSet
	local visited = OrderedSet.new()
	local queue = { start }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		if not visited:has(current) then
			visited:add(current)
			for _, neighbor in current:neighbors() do
				if not visited:has(neighbor) then
					table.insert(queue, neighbor)
				end
			end
		end
	end
	return visited
end

function RailNetwork._mergeClusters(_self: any, clusters: OrderedSet)
	local merged = Cluster.new()
	for _, cluster in clusters.list do
		merged:merge(cluster)
	end
end

return Rail
