--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/RecomputeRailClusterExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Splits rail clusters that lost a station, once a tick, for the whole game.

local RecomputeRailClusterExecution = {}
RecomputeRailClusterExecution.__index = RecomputeRailClusterExecution

export type RecomputeRailClusterExecution = typeof(setmetatable({} :: { railNetwork: any }, RecomputeRailClusterExecution))

function RecomputeRailClusterExecution.new(railNetwork: any): RecomputeRailClusterExecution
	return setmetatable({ railNetwork = railNetwork }, RecomputeRailClusterExecution)
end

function RecomputeRailClusterExecution.isActive(_self: RecomputeRailClusterExecution): boolean
	return true
end

function RecomputeRailClusterExecution.activeDuringSpawnPhase(_self: RecomputeRailClusterExecution): boolean
	return false
end

function RecomputeRailClusterExecution.init(_self: RecomputeRailClusterExecution, _mg: any, _ticks: number) end

function RecomputeRailClusterExecution.tick(self: RecomputeRailClusterExecution, _ticks: number)
	self.railNetwork:recomputeClusters()
end

return RecomputeRailClusterExecution
