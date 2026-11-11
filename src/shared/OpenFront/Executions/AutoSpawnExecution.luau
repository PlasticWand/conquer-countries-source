--!strict
--!native
-- Conquest addition (not in OpenFront, Bruno 2026-10-28): with
-- gameConfig.autoSpawnUnplaced, a connected human who hasn't picked a start
-- when the multiplayer spawn timer runs out is placed on a random free spot
-- (a SpawnExecution with no tile, as PlayerSpawner does for random spawn).
-- OpenFront leaves them out of the match.

local GameTypes = require(script.Parent.Parent.GameTypes)
local SpawnExecution = require(script.Parent.SpawnExecution)

local AutoSpawnExecution = {}
AutoSpawnExecution.__index = AutoSpawnExecution

export type AutoSpawnExecution = typeof(setmetatable({} :: { mg: any, gameID: string, active: boolean }, AutoSpawnExecution))

function AutoSpawnExecution.new(gameID: string): AutoSpawnExecution
	return setmetatable({ mg = nil, gameID = gameID, active = true }, AutoSpawnExecution)
end

function AutoSpawnExecution.init(self: AutoSpawnExecution, mg: any, _ticks: number)
	self.mg = mg
end

-- SpawnTimerExecution ends the phase once ticks pass numSpawnPhaseTurns;
-- this runs on that last spawn tick.
function AutoSpawnExecution.tick(self: AutoSpawnExecution, _ticks: number)
	local mg = self.mg
	if mg:ticks() < mg:config():numSpawnPhaseTurns() then
		return
	end
	self.active = false
	for _, player in mg:allPlayers() do
		if player:type() == GameTypes.PlayerType.Human and not player:hasSpawned() and not player:isDisconnected() then
			mg:addExecution(SpawnExecution.new(self.gameID, player:info()))
		end
	end
end

function AutoSpawnExecution.isActive(self: AutoSpawnExecution): boolean
	return self.active
end

function AutoSpawnExecution.activeDuringSpawnPhase(_self: AutoSpawnExecution): boolean
	return true
end

return AutoSpawnExecution
