--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/alliance/AllianceRejectExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Turns down a pending alliance request from `requestorID`.

local AllianceRejectExecution = {}
AllianceRejectExecution.__index = AllianceRejectExecution

export type AllianceRejectExecution = typeof(setmetatable(
	{} :: { active: boolean, requestorID: string, recipient: any },
	AllianceRejectExecution
))

function AllianceRejectExecution.new(requestorID: string, recipient: any): AllianceRejectExecution
	return setmetatable({ active = true, requestorID = requestorID, recipient = recipient }, AllianceRejectExecution)
end

function AllianceRejectExecution.init(self: AllianceRejectExecution, mg: any, _ticks: number)
	if not mg:hasPlayer(self.requestorID) then
		self.active = false
		return
	end
	local requestor = mg:player(self.requestorID)
	if not requestor:isFriendly(self.recipient) then
		for _, ar in requestor:outgoingAllianceRequests() do
			if ar:recipient() == self.recipient then
				ar:reject()
				break
			end
		end
	end
	self.active = false
end

function AllianceRejectExecution.tick(_self: AllianceRejectExecution, _ticks: number) end

function AllianceRejectExecution.isActive(self: AllianceRejectExecution): boolean
	return self.active
end

function AllianceRejectExecution.activeDuringSpawnPhase(_self: AllianceRejectExecution): boolean
	return false
end

return AllianceRejectExecution
