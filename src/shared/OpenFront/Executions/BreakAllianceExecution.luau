--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/alliance/BreakAllianceExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Breaks an alliance (the breaker becomes a traitor unless the other side
-- already is). The betrayed side's relation drops by 100, and every
-- neighbour not on the betrayed player's team drops theirs by 40.

local BreakAllianceExecution = {}
BreakAllianceExecution.__index = BreakAllianceExecution

export type BreakAllianceExecution = typeof(setmetatable(
	{} :: { active: boolean, recipient: any, mg: any, requestor: any, recipientID: string },
	BreakAllianceExecution
))

function BreakAllianceExecution.new(requestor: any, recipientID: string): BreakAllianceExecution
	return setmetatable({ active = true, recipient = nil, mg = nil, requestor = requestor, recipientID = recipientID }, BreakAllianceExecution)
end

function BreakAllianceExecution.init(self: BreakAllianceExecution, mg: any, _ticks: number)
	if not mg:hasPlayer(self.recipientID) then
		self.active = false
		return
	end
	self.recipient = mg:player(self.recipientID)
	self.mg = mg
end

function BreakAllianceExecution.tick(self: BreakAllianceExecution, _ticks: number)
	local recipient = self.recipient
	local alliance = self.requestor:allianceWith(recipient)
	if alliance ~= nil then
		self.requestor:breakAlliance(alliance)
		recipient:updateRelation(self.requestor, -100)
		for _, n in self.requestor:nearby() do
			if n:isPlayer() and not n:isOnSameTeam(recipient) then
				n:updateRelation(self.requestor, -40)
			end
		end
	end
	self.active = false
end

function BreakAllianceExecution.isActive(self: BreakAllianceExecution): boolean
	return self.active
end

function BreakAllianceExecution.activeDuringSpawnPhase(_self: BreakAllianceExecution): boolean
	return false
end

return BreakAllianceExecution
