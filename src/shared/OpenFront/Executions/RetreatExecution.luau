--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/RetreatExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Cancels an attack: the front stops at once (retreating), and the troops
-- come home 20 ticks later (25% lost against players, in AttackExecution).

local CANCEL_DELAY = 20

local RetreatExecution = {}
RetreatExecution.__index = RetreatExecution

export type RetreatExecution = typeof(setmetatable(
	{} :: { active: boolean, retreatOrdered: boolean, startTick: number, mg: any, player: any, attackID: string },
	RetreatExecution
))

function RetreatExecution.new(player: any, attackID: string): RetreatExecution
	return setmetatable({
		active = true,
		retreatOrdered = false,
		startTick = 0,
		mg = nil,
		player = player,
		attackID = attackID,
	}, RetreatExecution)
end

function RetreatExecution.init(self: RetreatExecution, mg: any, _ticks: number)
	self.mg = mg
	self.startTick = mg:ticks()
end

function RetreatExecution.tick(self: RetreatExecution, _ticks: number)
	if not self.retreatOrdered then
		self.player:orderRetreat(self.attackID)
		self.retreatOrdered = true
	end
	if self.mg:ticks() >= self.startTick + CANCEL_DELAY then
		self.player:executeRetreat(self.attackID)
		self.active = false
	end
end

function RetreatExecution.owner(self: RetreatExecution): any
	return self.player
end

function RetreatExecution.isActive(self: RetreatExecution): boolean
	return self.active
end

function RetreatExecution.activeDuringSpawnPhase(_self: RetreatExecution): boolean
	return false
end

return RetreatExecution
