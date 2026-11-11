--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/DeleteUnitExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A player scraps their own unit standing on their own land (not in the
-- spawn phase, once per deleteUnitCooldown). The unit is marked, then
-- removed when its deletion timer runs out.

local DeleteUnitExecution = {}
DeleteUnitExecution.__index = DeleteUnitExecution

export type DeleteUnitExecution = typeof(setmetatable(
	{} :: { active: boolean, mg: any, unit: any, player: any, unitId: number },
	DeleteUnitExecution
))

function DeleteUnitExecution.new(player: any, unitId: number): DeleteUnitExecution
	return setmetatable({ active = true, mg = nil, unit = nil, player = player, unitId = unitId }, DeleteUnitExecution)
end

function DeleteUnitExecution.activeDuringSpawnPhase(_self: DeleteUnitExecution): boolean
	return false
end

function DeleteUnitExecution.init(self: DeleteUnitExecution, mg: any, _ticks: number)
	if not self.active then
		return
	end
	self.mg = mg
	local unit = mg:unit(self.unitId)
	if unit == nil or unit:owner() ~= self.player or not unit:isActive() then
		self.active = false
		return
	end
	self.unit = unit
	local tileOwner = mg:owner(unit:tile())
	if not tileOwner:isPlayer() or tileOwner:id() ~= self.player:id() then
		self.active = false
		return
	end
	if not mg:isLand(unit:tile()) or mg:inSpawnPhase() or not self.player:canDeleteUnit() then
		self.active = false
		return
	end
	self.player:recordDeleteUnit()
	unit:markForDeletion()
end

function DeleteUnitExecution.tick(self: DeleteUnitExecution, _ticks: number)
	if not self.active or not self.unit then
		return
	end
	if not self.unit:isActive() then
		self.active = false
		return
	end
	if self.unit:isOverdueDeletion() then
		self.unit:delete(false)
		self.mg:displayMessage("events_display.unit_voluntarily_deleted", "UNIT_DESTROYED", self.player:id())
		self.active = false
	end
end

function DeleteUnitExecution.isActive(self: DeleteUnitExecution): boolean
	return self.active
end

return DeleteUnitExecution
