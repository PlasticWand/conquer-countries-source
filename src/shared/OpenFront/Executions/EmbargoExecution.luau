--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/EmbargoExecution.ts and EmbargoAllExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Starts or stops a manual trade embargo against one player, or (EmbargoAll)
-- against every non-tribe player who is neither a teammate nor an ally.

local GameTypes = require(script.Parent.Parent.GameTypes)

local EmbargoExecution = {}
EmbargoExecution.__index = EmbargoExecution

export type EmbargoExecution = typeof(setmetatable(
	{} :: { active: boolean, target: any, player: any, targetID: string, action: string },
	EmbargoExecution
))

function EmbargoExecution.new(player: any, targetID: string, action: string): EmbargoExecution
	return setmetatable({ active = true, target = nil, player = player, targetID = targetID, action = action }, EmbargoExecution)
end

function EmbargoExecution.init(self: EmbargoExecution, mg: any, _ticks: number)
	if not mg:hasPlayer(self.targetID) then
		self.active = false
		return
	end
	self.target = mg:player(self.targetID)
end

function EmbargoExecution.tick(self: EmbargoExecution, _ticks: number)
	if self.action == "start" then
		self.player:addEmbargo(self.target, false)
	else
		self.player:stopEmbargo(self.target)
	end
	self.active = false
end

function EmbargoExecution.isActive(self: EmbargoExecution): boolean
	return self.active
end

function EmbargoExecution.activeDuringSpawnPhase(_self: EmbargoExecution): boolean
	return false
end

-- EmbargoAllExecution -----------------------------------------------------------------

local EmbargoAll = {}
EmbargoAll.__index = EmbargoAll
EmbargoExecution.All = EmbargoAll

function EmbargoAll.new(player: any, action: string): any
	return setmetatable({ player = player, action = action }, EmbargoAll)
end

function EmbargoAll.init(self: any, mg: any, _ticks: number)
	local me = self.player
	if not me:canEmbargoAll() then
		return
	end
	for _, p in mg:players() do
		if p:id() ~= me:id() and p:type() ~= GameTypes.PlayerType.Bot and not me:isOnSameTeam(p) and not me:isAlliedWith(p) then
			if self.action == "start" then
				if not me:hasEmbargoAgainst(p) then
					me:addEmbargo(p, false)
				end
			elseif me:hasEmbargoAgainst(p) then
				me:stopEmbargo(p)
			end
		end
	end
	me:recordEmbargoAll()
end

function EmbargoAll.tick(_self: any, _ticks: number) end
function EmbargoAll.isActive(_self: any): boolean
	return false
end
function EmbargoAll.activeDuringSpawnPhase(_self: any): boolean
	return false
end

return EmbargoExecution
