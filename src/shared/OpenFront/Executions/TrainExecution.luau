--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/TrainExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A train: an engine, a tail engine and cars, two tiles a tick along the
-- station path to its destination. Each city or port it stops at pays
-- trainGold (more for longer trips). It stops when a station on its way
-- is gone or trade with the next one is cut. When a railroad it is on gets
-- split by a new station, it follows the new segments only if their tiles
-- match the path clients already have.

local GameTypes = require(script.Parent.Parent.GameTypes)
local Rail = require(script.Parent.Parent.Rail)

local UnitType = GameTypes.UnitType
local getOrientedRailroad = Rail.getOrientedRailroad

local TrainExecution = {}
TrainExecution.__index = TrainExecution

export type TrainExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		mg: any,
		train: any,
		cars: { any }, -- back to front
		hasCargo: boolean,
		currentTile: number, -- 0-based index into the current railroad
		spacing: number,
		usedTiles: { number },
		stations: { any },
		currentRailroad: any,
		speed: number,
		_tradeStopsVisited: number,
		pathTiles: { number },
		pathIndex: number, -- 0-based
		railNetwork: any,
		player: any,
		source: any,
		destination: any,
		numCars: number,
	},
	TrainExecution
))

function TrainExecution.new(railNetwork: any, player: any, source: any, destination: any, numCars: number): TrainExecution
	return setmetatable({
		active = true,
		mg = nil,
		train = nil,
		cars = {},
		hasCargo = false,
		currentTile = 0,
		spacing = 2,
		usedTiles = {},
		stations = {},
		currentRailroad = nil,
		speed = 2,
		_tradeStopsVisited = 0,
		pathTiles = {},
		pathIndex = 0,
		railNetwork = railNetwork,
		player = player,
		source = source,
		destination = destination,
		numCars = numCars,
	}, TrainExecution)
end

function TrainExecution.owner(self: TrainExecution): any
	return self.player
end

function TrainExecution.tradeStopsVisited(self: TrainExecution): number
	return self._tradeStopsVisited
end

function TrainExecution.init(self: TrainExecution, mg: any, ticks: number)
	self.mg = mg
	local stations = self.railNetwork:findStationsPath(self.source, self.destination)
	if #stations <= 1 then
		self.active = false
		return
	end
	self.stations = stations
	local railroad = getOrientedRailroad(stations[1], stations[2])
	if not railroad then
		self.active = false
		return
	end
	self.currentRailroad = railroad
	local spawn = self.player:canBuild(UnitType.Train, stations[1]:tile())
	if spawn == false then
		self.active = false
		return
	end
	self.train = self:_createTrainUnits(spawn)
	local carUnitIds = {}
	for _, c in self.cars do
		table.insert(carUnitIds, c:id())
	end
	local pathTiles = {}
	for i = 1, #stations - 1 do
		local segment = getOrientedRailroad(stations[i], stations[i + 1])
		if not segment then
			self.active = false
			return
		end
		table.move(segment:getTiles(), 1, #segment:getTiles(), #pathTiles + 1, pathTiles)
	end
	local startTile = self.train:tile()
	if #pathTiles == 0 or pathTiles[1] ~= startTile then
		table.insert(pathTiles, 1, startTile)
		self.pathIndex = 1
	end
	self.pathTiles = pathTiles
	mg:recordMotionPlan({
		kind = "train",
		engineUnitId = self.train:id(),
		carUnitIds = carUnitIds,
		planId = 1,
		startTick = ticks + 1,
		speed = self.speed,
		spacing = self.spacing,
		path = pathTiles,
	})
end

function TrainExecution.tick(self: TrainExecution, _ticks: number)
	if self.train == nil then
		error("Not initialized")
	end
	if not self.train:isActive() then
		self:_deleteTrain()
		return
	end
	self:_reconcileCurrentRailroadSplit()
	if not self:_activeSourceOrDestination() then
		self:_deleteTrain()
		return
	end
	local tile = self:_getNextTile()
	-- JS truthiness: tile 0 counts as no tile.
	if tile ~= nil and tile ~= 0 then
		self:_updateCarsPositions(tile)
	else
		self:_targetReached()
		self:_deleteTrain()
	end
end

function TrainExecution.loadCargo(self: TrainExecution)
	if self.hasCargo or self.train == nil then
		return
	end
	self.hasCargo = true
	-- Not the tail engine.
	for i = 2, #self.cars do
		self.cars[i]:setLoaded(true)
	end
end

function TrainExecution._targetReached(self: TrainExecution)
	if self.train == nil then
		return
	end
	self.train:setReachedTarget()
	for _, car in self.cars do
		car:setReachedTarget()
	end
end

function TrainExecution._createTrainUnits(self: TrainExecution, tile: number): any
	local train = self.player:buildUnit(UnitType.Train, tile, { targetUnit = self.destination.unit, trainType = "Engine" })
	table.insert(self.cars, self.player:buildUnit(UnitType.Train, tile, { targetUnit = self.destination.unit, trainType = "TailEngine" }))
	for _ = 1, self.numCars do
		table.insert(self.cars, self.player:buildUnit(UnitType.Train, tile, { trainType = "Carriage", loaded = self.hasCargo }))
	end
	return train
end

function TrainExecution._deleteTrain(self: TrainExecution)
	self.active = false
	if self.train and self.train:isActive() then
		self.train:delete(false)
	end
	for _, car in self.cars do
		if car:isActive() then
			car:delete(false)
		end
	end
end

function TrainExecution._activeSourceOrDestination(self: TrainExecution): boolean
	return #self.stations > 1 and self.stations[2]:isActive() and self.stations[1]:isActive()
end

-- Keeps the tiles the engine passes so cars follow at fixed spacing.
function TrainExecution._saveTraversedTiles(self: TrainExecution, from: number, speed: number)
	if not self.currentRailroad then
		return
	end
	local tiles = self.currentRailroad:getTiles()
	local toSave = from
	local i = 0
	while i < speed and toSave < #tiles do
		self:_saveTile(tiles[toSave + 1])
		toSave += 1
		i += 1
	end
end

function TrainExecution._saveTile(self: TrainExecution, tile: number)
	table.insert(self.usedTiles, tile)
	if #self.usedTiles > #self.cars * self.spacing + 3 then
		table.remove(self.usedTiles, 1)
	end
end

function TrainExecution._updateCarsPositions(self: TrainExecution, newTile: number)
	for i = #self.cars - 1, 0, -1 do
		local carTileIndex = (i + 1) * self.spacing + 2
		if #self.usedTiles > carTileIndex then
			self.cars[i + 1]:move(self.usedTiles[carTileIndex + 1])
		end
	end
	if self.train ~= nil then
		self.train:move(newTile)
	end
end

function TrainExecution._nextStation(self: TrainExecution): boolean
	if #self.stations > 2 then
		self.pathIndex += if self.currentRailroad then #self.currentRailroad:getTiles() else 0
		table.remove(self.stations, 1)
		local railroad = getOrientedRailroad(self.stations[1], self.stations[2]) or self:_resolveSplitRailroad()
		if railroad then
			self.currentRailroad = railroad
			return true
		end
	end
	return false
end

local function spliceFront(list: { any }, removeCount: number, insert: { any })
	for _ = 1, removeCount do
		table.remove(list, 1)
	end
	for i = #insert, 1, -1 do
		table.insert(list, 1, insert[i])
	end
end

function TrainExecution._resolveSplitRailroad(self: TrainExecution): any?
	local path = self.railNetwork:findStationsPath(self.stations[1], self.stations[2])
	if #path <= 2 then
		return nil
	end
	local cursor = self.pathIndex
	for i = 1, #path - 1 do
		local segment = getOrientedRailroad(path[i], path[i + 1])
		if not segment then
			return nil
		end
		for _, tile in segment:getTiles() do
			cursor += 1
			if self.pathTiles[cursor] ~= tile then
				return nil
			end
		end
	end
	spliceFront(self.stations, 2, path)
	return getOrientedRailroad(self.stations[1], self.stations[2])
end

-- A split of the railroad the train is on: take the new segments if their
-- tiles exactly match the motion plan clients follow.
function TrainExecution._reconcileCurrentRailroadSplit(self: TrainExecution)
	if self.currentRailroad == nil or #self.stations < 2 then
		return
	end
	local station0, station1 = self.stations[1], self.stations[2]
	if station0:getRailroadTo(station1) ~= nil then
		return
	end
	local path = self.railNetwork:findStationsPath(station0, station1)
	if #path <= 2 then
		return
	end
	local segments = {}
	local cursor = self.pathIndex
	for i = 1, #path - 1 do
		local segment = getOrientedRailroad(path[i], path[i + 1])
		if not segment then
			return
		end
		table.insert(segments, segment)
		for _, tile in segment:getTiles() do
			cursor += 1
			if self.pathTiles[cursor] ~= tile then
				return
			end
		end
	end
	local oldTiles = self.currentRailroad:getTiles()
	if cursor ~= self.pathIndex + #oldTiles then
		return
	end
	-- Drop stations already behind the engine; one exactly at it stays.
	local activeSegment = 0
	local segmentStart = 0
	local boundary = 0
	for i = 0, #segments - 2 do
		boundary += #segments[i + 1]:getTiles()
		local stopIndex = self:_stopIndexAtBoundary(path[i + 2], oldTiles, boundary)
		if self.currentTile <= stopIndex then
			break
		end
		activeSegment = i + 1
		segmentStart = boundary
	end
	self.pathIndex += segmentStart
	self.currentTile -= segmentStart
	self.currentRailroad = segments[activeSegment + 1]
	spliceFront(self.stations, 2, table.move(path, activeSegment + 1, #path, 1, {}))
end

-- The rail tile next to the station where its stop is reached.
function TrainExecution._stopIndexAtBoundary(self: TrainExecution, station: any, tiles: { number }, boundary: number): number
	local mg = self.mg
	local before, after = boundary - 1, boundary
	local sx, sy = mg:x(station:tile()), mg:y(station:tile())
	local function d2(index: number): number
		local dx, dy = mg:x(tiles[index + 1]) - sx, mg:y(tiles[index + 1]) - sy
		return dx * dx + dy * dy
	end
	return if d2(before) <= d2(after) then before else after
end

function TrainExecution._canTradeWithDestination(self: TrainExecution): boolean
	return #self.stations > 1 and self.stations[2]:tradeAvailable(self.player)
end

function TrainExecution._getNextTile(self: TrainExecution): number?
	if self.currentRailroad == nil or not self:_canTradeWithDestination() then
		return nil
	end
	self:_saveTraversedTiles(self.currentTile, self.speed)
	self.currentTile += self.speed
	local leftOver = self.currentTile - #self.currentRailroad:getTiles()
	if leftOver >= 0 then
		self:_stationReached()
		if not self:_nextStation() then
			return nil
		end
		self.currentTile = leftOver
		self:_saveTraversedTiles(0, leftOver)
	end
	return self.currentRailroad:getTiles()[self.currentTile + 1]
end

function TrainExecution._stationReached(self: TrainExecution)
	self.stations[2]:onTrainStop(self)
	local t = self.stations[2].unit:type()
	if t == UnitType.City or t == UnitType.Port then
		self._tradeStopsVisited += 1
	end
end

function TrainExecution.isActive(self: TrainExecution): boolean
	return self.active
end

function TrainExecution.activeDuringSpawnPhase(_self: TrainExecution): boolean
	return false
end

return TrainExecution
