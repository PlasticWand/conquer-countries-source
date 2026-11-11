--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/UpgradeStructureExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Raises an owned structure up to `amount` levels at once in init, paying
-- each level, and stops at the first level it can't afford.

local UpgradeStructureExecution = {}
UpgradeStructureExecution.__index = UpgradeStructureExecution

export type UpgradeStructureExecution = typeof(setmetatable(
	{} :: { structure: any, player: any, unitId: number, amount: number },
	UpgradeStructureExecution
))

function UpgradeStructureExecution.new(player: any, unitId: number, amount: number?): UpgradeStructureExecution
	return setmetatable({ structure = nil, player = player, unitId = unitId, amount = amount or 1 }, UpgradeStructureExecution)
end

function UpgradeStructureExecution.init(self: UpgradeStructureExecution, mg: any, _ticks: number)
	self.structure = mg:unit(self.unitId)
	if self.structure and self.structure:owner() ~= self.player then
		self.structure = nil
	end
	if self.structure == nil then
		return
	end
	for _ = 1, self.amount do
		if not self.player:canUpgradeUnit(self.structure) then
			break
		end
		self.player:upgradeUnit(self.structure)
	end
end

function UpgradeStructureExecution.tick(_self: UpgradeStructureExecution, _ticks: number) end

function UpgradeStructureExecution.isActive(_self: UpgradeStructureExecution): boolean
	return false
end

function UpgradeStructureExecution.activeDuringSpawnPhase(_self: UpgradeStructureExecution): boolean
	return false
end

return UpgradeStructureExecution
