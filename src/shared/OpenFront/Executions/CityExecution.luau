--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/CityExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A finished city. On its first tick it joins the rail network if a
-- factory is in range; it ends when the city is gone.

local GameTypes = require(script.Parent.Parent.GameTypes)

local CityExecution = {}
CityExecution.__index = CityExecution

export type CityExecution = typeof(setmetatable(
	{} :: { mg: any, active: boolean, stationCreated: boolean, city: any },
	CityExecution
))

function CityExecution.new(city: any): CityExecution
	return setmetatable({ mg = nil, active = true, stationCreated = false, city = city }, CityExecution)
end

function CityExecution.init(self: CityExecution, mg: any, _ticks: number)
	self.mg = mg
end

function CityExecution.tick(self: CityExecution, _ticks: number)
	if not self.stationCreated then
		self:_createStation()
		self.stationCreated = true
	end
	if not self.city:isActive() then
		self.active = false
		return
	end
end

function CityExecution._createStation(self: CityExecution)
	local mg = self.mg
	if mg:hasUnitNearby(self.city:tile(), mg:config():trainStationMaxRange(), GameTypes.UnitType.Factory) then
		mg:addExecution((require(script.Parent.TrainStationExecution) :: any).new(self.city))
	end
end

function CityExecution.isActive(self: CityExecution): boolean
	return self.active
end

function CityExecution.activeDuringSpawnPhase(_self: CityExecution): boolean
	return false
end

return CityExecution
