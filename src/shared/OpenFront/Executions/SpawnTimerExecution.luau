--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/SpawnTimerExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Ends the spawn phase after numSpawnPhaseTurns ticks (not in singleplayer,
-- where placing your spawn ends it).

local SpawnTimerExecution = {}
SpawnTimerExecution.__index = SpawnTimerExecution

export type SpawnTimerExecution = typeof(setmetatable({} :: { mg: any }, SpawnTimerExecution))

function SpawnTimerExecution.new(): SpawnTimerExecution
	return setmetatable({ mg = nil }, SpawnTimerExecution)
end

function SpawnTimerExecution.init(self: SpawnTimerExecution, mg: any, _ticks: number)
	self.mg = mg
end

function SpawnTimerExecution.tick(self: SpawnTimerExecution, _ticks: number)
	if self.mg:ticks() > self.mg:config():numSpawnPhaseTurns() then
		self.mg:endSpawnPhase()
	end
end

function SpawnTimerExecution.isActive(self: SpawnTimerExecution): boolean
	return self.mg == nil or self.mg:inSpawnPhase()
end

function SpawnTimerExecution.activeDuringSpawnPhase(_self: SpawnTimerExecution): boolean
	return true
end

return SpawnTimerExecution
