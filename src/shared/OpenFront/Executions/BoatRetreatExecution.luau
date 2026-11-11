--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/BoatRetreatExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Turns one of the player's transport ships around.

local BoatRetreatExecution = {}
BoatRetreatExecution.__index = BoatRetreatExecution

export type BoatRetreatExecution = typeof(setmetatable({} :: { active: boolean, player: any, unitID: number }, BoatRetreatExecution))

function BoatRetreatExecution.new(player: any, unitID: number): BoatRetreatExecution
	return setmetatable({ active = true, player = player, unitID = unitID }, BoatRetreatExecution)
end

function BoatRetreatExecution.init(_self: BoatRetreatExecution, _mg: any, _ticks: number) end

function BoatRetreatExecution.tick(self: BoatRetreatExecution, _ticks: number)
	for _, unit in self.player:units() do
		if unit:id() == self.unitID and unit:type() == "Transport" then
			unit:updateTransportShipState({ isRetreating = true })
			break
		end
	end
	self.active = false
end

function BoatRetreatExecution.owner(self: BoatRetreatExecution): any
	return self.player
end

function BoatRetreatExecution.isActive(self: BoatRetreatExecution): boolean
	return self.active
end

function BoatRetreatExecution.activeDuringSpawnPhase(_self: BoatRetreatExecution): boolean
	return false
end

return BoatRetreatExecution
