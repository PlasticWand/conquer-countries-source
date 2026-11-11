--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/PauseExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Marks the game paused or running (the lobby creator, or anyone in
-- singleplayer). The engine only records it and tells clients; the runner
-- stops issuing turns while paused, as OpenFront's servers do.

local PauseExecution = {}
PauseExecution.__index = PauseExecution

export type PauseExecution = typeof(setmetatable({} :: { player: any, paused: boolean }, PauseExecution))

function PauseExecution.new(player: any, paused: boolean): PauseExecution
	return setmetatable({ player = player, paused = paused }, PauseExecution)
end

function PauseExecution.isActive(_self: PauseExecution): boolean
	return false
end

function PauseExecution.activeDuringSpawnPhase(_self: PauseExecution): boolean
	return true
end

function PauseExecution.init(self: PauseExecution, game: any, _ticks: number)
	if self.player:isLobbyCreator() or game:config():gameConfig().gameType == "Singleplayer" then
		game:setPaused(self.paused)
	end
end

function PauseExecution.tick(_self: PauseExecution, _ticks: number) end

function PauseExecution.owner(self: PauseExecution): any
	return self.player
end

return PauseExecution
