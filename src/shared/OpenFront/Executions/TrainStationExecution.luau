--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/TrainStationExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Makes a structure a train station and joins it to the rail network. A
-- factory's station also spawns trains (5 cars) to random trade stations
-- in its cluster: one roll per level per tick at trainSpawnRate, at least
-- 10 ticks apart.

local GameTypes = require(script.Parent.Parent.GameTypes)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local Rail = require(script.Parent.Parent.Rail)

local UnitType = GameTypes.UnitType

local TrainStationExecution = {}
TrainStationExecution.__index = TrainStationExecution

export type TrainStationExecution = typeof(setmetatable(
	{} :: {
		mg: any,
		active: boolean,
		random: PseudoRandom.PseudoRandom?,
		station: any,
		numCars: number,
		lastSpawnTick: number,
		ticksCooldown: number,
		unit: any,
		spawnTrains: boolean,
	},
	TrainStationExecution
))

function TrainStationExecution.new(unit: any, spawnTrains: boolean?): TrainStationExecution
	unit:setTrainStation(true)
	return setmetatable({
		mg = nil,
		active = true,
		random = nil,
		station = nil,
		numCars = 5,
		lastSpawnTick = 0,
		ticksCooldown = 10,
		unit = unit,
		spawnTrains = spawnTrains == true,
	}, TrainStationExecution)
end

function TrainStationExecution.isActive(self: TrainStationExecution): boolean
	return self.active
end

function TrainStationExecution.init(self: TrainStationExecution, mg: any, _ticks: number)
	self.mg = mg
	if self.spawnTrains then
		self.random = PseudoRandom.new(mg:ticks())
	end
end

function TrainStationExecution.tick(self: TrainStationExecution, ticks: number)
	if not self.active then
		return
	end
	if self.station == nil then
		-- Executions can't be created in init, so the station is made here.
		self.station = Rail.TrainStation.new(self.mg, self.unit)
		self.mg:railNetwork():connectStation(self.station)
	end
	if not self.station:isActive() then
		self.active = false
		return
	end
	if self.spawnTrains then
		self:_spawnTrain(self.station, ticks)
	end
end

function TrainStationExecution._shouldSpawnTrain(self: TrainStationExecution): boolean
	local mg = self.mg
	local spawnRate = mg:config():trainSpawnRate(self.unit:owner():unitCount(UnitType.Factory), mg:unitCount(UnitType.Train))
	local random = self.random :: PseudoRandom.PseudoRandom
	for _ = 1, self.unit:level() do
		if random:chance(spawnRate) then
			return true
		end
	end
	return false
end

function TrainStationExecution._spawnTrain(self: TrainStationExecution, station: any, currentTick: number)
	if currentTick < self.lastSpawnTick + self.ticksCooldown then
		return
	end
	local cluster = station:getCluster()
	if cluster == nil then
		return
	end
	local owner = self.unit:owner()
	if not cluster:hasAnyTradeDestination(owner) then
		return
	end
	if not self:_shouldSpawnTrain() then
		return
	end
	local destination = cluster:randomTradeDestination(owner, self.random)
	if destination == nil or destination == station then
		return
	end
	local TrainExecution = require(script.Parent.TrainExecution)
	self.mg:addExecution(TrainExecution.new(self.mg:railNetwork(), owner, station, destination, self.numCars))
	self.lastSpawnTick = currentTick
end

function TrainStationExecution.activeDuringSpawnPhase(_self: TrainStationExecution): boolean
	return false
end

return TrainStationExecution
