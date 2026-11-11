--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/MoveWarshipExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Moves the patrol centre of the player's chosen warships (each once) to a
-- tile on the same water body.

local GameTypes = require(script.Parent.Parent.GameTypes)

local MoveWarshipExecution = {}
MoveWarshipExecution.__index = MoveWarshipExecution

export type MoveWarshipExecution = typeof(setmetatable(
	{} :: { owner: any, unitIds: { number }, position: number },
	MoveWarshipExecution
))

function MoveWarshipExecution.new(owner: any, unitIds: { number }, position: number): MoveWarshipExecution
	return setmetatable({ owner = owner, unitIds = unitIds, position = position }, MoveWarshipExecution)
end

function MoveWarshipExecution.init(self: MoveWarshipExecution, mg: any, _ticks: number)
	if not mg:isValidRef(self.position) then
		return
	end
	local component = mg:getWaterComponent(self.position)
	local byId = {}
	for _, u in self.owner:units(GameTypes.UnitType.Warship) do
		byId[u:id()] = u
	end
	local seen = {}
	for _, unitId in self.unitIds do
		if not seen[unitId] then
			seen[unitId] = true
			local warship = byId[unitId]
			if warship and warship:isActive() and component ~= nil and mg:hasWaterComponent(warship:tile(), component) then
				warship:updateWarshipState({ patrolTile = self.position })
				warship:setTargetTile(nil)
			end
		end
	end
end

function MoveWarshipExecution.tick(_self: MoveWarshipExecution, _ticks: number) end

function MoveWarshipExecution.isActive(_self: MoveWarshipExecution): boolean
	return false
end

function MoveWarshipExecution.activeDuringSpawnPhase(_self: MoveWarshipExecution): boolean
	return false
end

return MoveWarshipExecution
