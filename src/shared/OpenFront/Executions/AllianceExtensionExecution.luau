--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/alliance/AllianceExtensionExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Agrees to renew an alliance. Once both sides agree it runs a full
-- allianceDuration again; the first agreement tells the other side.

local AllianceExtensionExecution = {}
AllianceExtensionExecution.__index = AllianceExtensionExecution

export type AllianceExtensionExecution = typeof(setmetatable({} :: { from: any, toID: string }, AllianceExtensionExecution))

function AllianceExtensionExecution.new(from: any, toID: string): AllianceExtensionExecution
	return setmetatable({ from = from, toID = toID }, AllianceExtensionExecution)
end

function AllianceExtensionExecution.init(self: AllianceExtensionExecution, mg: any, _ticks: number)
	if not mg:hasPlayer(self.toID) then
		return
	end
	local to = mg:player(self.toID)
	if not self.from:isAlive() or not to:isAlive() then
		return
	end
	local alliance = self.from:allianceWith(to)
	if not alliance then
		return
	end
	local wasOnlyOneAgreed = alliance:onlyOneAgreedToExtend()
	alliance:addExtensionRequest(self.from)
	if alliance:bothAgreedToExtend() then
		alliance:extend()
		mg:displayMessage("events_display.alliance_renewed", "ALLIANCE_ACCEPTED", self.from:id(), nil, { name = to:displayName() })
		mg:displayMessage("events_display.alliance_renewed", "ALLIANCE_ACCEPTED", self.toID, nil, { name = self.from:displayName() })
	elseif alliance:onlyOneAgreedToExtend() and not wasOnlyOneAgreed then
		mg:displayMessage("events_display.wants_to_renew_alliance", "RENEW_ALLIANCE", self.toID, nil, { name = self.from:displayName() })
	end
end

function AllianceExtensionExecution.tick(_self: AllianceExtensionExecution, _ticks: number) end

function AllianceExtensionExecution.isActive(_self: AllianceExtensionExecution): boolean
	return false
end

function AllianceExtensionExecution.activeDuringSpawnPhase(_self: AllianceExtensionExecution): boolean
	return false
end

return AllianceExtensionExecution
