--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/FactoryExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A finished factory: on its first tick it becomes a train-spawning
-- station and makes stations of the cities, ports and factories in range.

local GameTypes = require(script.Parent.Parent.GameTypes)

local UnitType = GameTypes.UnitType

local FactoryExecution = {}
FactoryExecution.__index = FactoryExecution

export type FactoryExecution = typeof(setmetatable(
	{} :: { active: boolean, game: any, stationCreated: boolean, factory: any },
	FactoryExecution
))

function FactoryExecution.new(factory: any): FactoryExecution
	return setmetatable({ active = true, game = nil, stationCreated = false, factory = factory }, FactoryExecution)
end

function FactoryExecution.init(self: FactoryExecution, mg: any, _ticks: number)
	self.game = mg
end

function FactoryExecution.tick(self: FactoryExecution, _ticks: number)
	if not self.stationCreated then
		self:_createStation()
		self.stationCreated = true
	end
	if not self.factory:isActive() then
		self.active = false
		return
	end
end

function FactoryExecution._createStation(self: FactoryExecution)
	local game = self.game
	local TrainStationExecution = require(script.Parent.TrainStationExecution)
	local structures = game:nearbyUnits(self.factory:tile(), game:config():trainStationMaxRange(), { UnitType.City, UnitType.Port, UnitType.Factory })
	game:addExecution(TrainStationExecution.new(self.factory, true))
	for _, entry in structures do
		if not entry.unit:hasTrainStation() then
			game:addExecution(TrainStationExecution.new(entry.unit))
		end
	end
end

function FactoryExecution.isActive(self: FactoryExecution): boolean
	return self.active
end

function FactoryExecution.activeDuringSpawnPhase(_self: FactoryExecution): boolean
	return false
end

return FactoryExecution
