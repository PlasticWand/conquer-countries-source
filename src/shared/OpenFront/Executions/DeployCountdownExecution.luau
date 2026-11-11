--!strict
--!native
-- Conquest addition (not in OpenFront, Bruno 2026-10-27): with
-- gameConfig.soloDeployCountdown, placing your capital in singleplayer
-- starts a short countdown instead of ending the spawn phase at once, so the
-- player can still move it. SpawnExecution sets the deadline on the first
-- pick (moves keep it, Bruno 2026-10-29); this ends the spawn phase when it
-- passes.

local DeployCountdownExecution = {}
DeployCountdownExecution.__index = DeployCountdownExecution

export type DeployCountdownExecution = typeof(setmetatable({} :: { mg: any }, DeployCountdownExecution))

function DeployCountdownExecution.new(): DeployCountdownExecution
	return setmetatable({ mg = nil }, DeployCountdownExecution)
end

function DeployCountdownExecution.init(self: DeployCountdownExecution, mg: any, _ticks: number)
	self.mg = mg
end

function DeployCountdownExecution.tick(self: DeployCountdownExecution, _ticks: number)
	local deadline = self.mg.deployDeadline
	if deadline ~= nil and self.mg:ticks() >= deadline then
		self.mg:endSpawnPhase()
	end
end

function DeployCountdownExecution.isActive(self: DeployCountdownExecution): boolean
	return self.mg == nil or self.mg:inSpawnPhase()
end

function DeployCountdownExecution.activeDuringSpawnPhase(_self: DeployCountdownExecution): boolean
	return true
end

return DeployCountdownExecution
