--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/DefensePostExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A finished defence post. In v0.35.2 its ship targeting is commented out,
-- so it never fires: its effect is the defence bonus attacks read from
-- nearby posts. This execution only ends when the post is gone.

local DefensePostExecution = {}
DefensePostExecution.__index = DefensePostExecution

export type DefensePostExecution = typeof(setmetatable(
	{} :: { mg: any, active: boolean, target: any, lastShellAttack: number, post: any },
	DefensePostExecution
))

function DefensePostExecution.new(post: any): DefensePostExecution
	return setmetatable({ mg = nil, active = true, target = nil, lastShellAttack = 0, post = post }, DefensePostExecution)
end

function DefensePostExecution.init(self: DefensePostExecution, mg: any, _ticks: number)
	self.mg = mg
end

function DefensePostExecution.tick(self: DefensePostExecution, _ticks: number)
	if not self.post:isActive() then
		self.active = false
		return
	end
	if self.post:isUnderConstruction() then
		return
	end
	if self.target ~= nil and not self.target:isActive() then
		self.target = nil
	end
end

function DefensePostExecution.isActive(self: DefensePostExecution): boolean
	return self.active
end

function DefensePostExecution.activeDuringSpawnPhase(_self: DefensePostExecution): boolean
	return false
end

return DefensePostExecution
