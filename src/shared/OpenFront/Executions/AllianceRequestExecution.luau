--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/alliance/AllianceRequestExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Asks for an alliance. If the other side had already asked, it is
-- accepted at once: relations +100 both ways, automatic embargoes lifted,
-- and nukes in flight between the two that would break the alliance are
-- destroyed. Otherwise the request waits allianceRequestDuration ticks and
-- then lapses (rejected).

local GameTypes = require(script.Parent.Parent.GameTypes)

local UnitType = GameTypes.UnitType

local AllianceRequestExecution = {}
AllianceRequestExecution.__index = AllianceRequestExecution

export type AllianceRequestExecution = typeof(setmetatable(
	{} :: { req: any, active: boolean, mg: any, requestor: any, recipientID: string },
	AllianceRequestExecution
))

function AllianceRequestExecution.new(requestor: any, recipientID: string): AllianceRequestExecution
	return setmetatable({ req = nil, active = true, mg = nil, requestor = requestor, recipientID = recipientID }, AllianceRequestExecution)
end

function AllianceRequestExecution.init(self: AllianceRequestExecution, mg: any, _ticks: number)
	self.mg = mg
	if not mg:hasPlayer(self.recipientID) then
		return
	end
	local recipient = mg:player(self.recipientID)
	if not self.requestor:canSendAllianceRequest(recipient) then
		self.active = false
		return
	end
	local incoming = nil
	for _, r in recipient:outgoingAllianceRequests() do
		if r:recipient() == self.requestor then
			incoming = r
			break
		end
	end
	if incoming then
		self.active = false
		incoming:accept()
		self.requestor:updateRelation(recipient, 100)
		recipient:updateRelation(self.requestor, 100)
		-- Only automatic (temporary) embargoes are lifted.
		if self.requestor:hasEmbargoAgainst(recipient) then
			self.requestor:endTemporaryEmbargo(recipient)
		end
		if recipient:hasEmbargoAgainst(self.requestor) then
			recipient:endTemporaryEmbargo(self.requestor)
		end
		self:_cancelNukesBetweenAlliedPlayers(recipient)
	else
		self.req = self.requestor:createAllianceRequest(recipient)
	end
end

function AllianceRequestExecution.tick(self: AllianceRequestExecution, _ticks: number)
	local req = self.req
	local status = if req then req:status() else nil
	if status == "accepted" or status == "rejected" then
		self.active = false
		return
	end
	if self.mg:ticks() - (if req then req:createdAt() else 0) > self.mg:config():allianceRequestDuration() then
		if req then
			req:reject()
		end
		self.active = false
	end
end

function AllianceRequestExecution.isActive(self: AllianceRequestExecution): boolean
	return self.active
end

function AllianceRequestExecution.activeDuringSpawnPhase(_self: AllianceRequestExecution): boolean
	return false
end

function AllianceRequestExecution._cancelNukesBetweenAlliedPlayers(self: AllianceRequestExecution, recipient: any)
	local mg = self.mg
	local NukeExecution = require(script.Parent.NukeExecution)
	-- Maps in first-insert order.
	local order, neutralized = {}, {}
	local warheadOrder, warheadSeen = {}, {}
	local function bump(launcher: any)
		if neutralized[launcher] == nil then
			neutralized[launcher] = 0
			table.insert(order, launcher)
		end
		neutralized[launcher] += 1
	end
	for _, launcher in { self.requestor, recipient } do
		local other = if launcher == self.requestor then recipient else self.requestor
		-- Conquest: the Arsenal's Mega Nuke is cancelled like an Atom Bomb.
		for _, unit in launcher:units({ UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRV, UnitType.MIRVWarhead, UnitType.MegaNuke, UnitType.Scattershot }) do
			if unit:isActive() and not unit:reachedTarget() then
				local targetTile = unit:targetTile()
				local cancel = false
				if unit:type() == UnitType.MIRV then
					-- The target captured at launch, not the tile's current owner.
					local target = unit:targetPlayer() or (if targetTile then mg:owner(targetTile) else nil)
					cancel = target == other
				elseif unit:type() == UnitType.MIRVWarhead then
					cancel = targetTile ~= nil and mg:owner(targetTile) == other
				elseif targetTile ~= nil then
					local magnitude = mg:config():nukeMagnitudes(unit:type())
					cancel = NukeExecution.wouldNukeBreakAlliance(mg, targetTile, magnitude, { [other:smallID()] = true }, mg:config():nukeAllianceBreakThreshold())
				end
				if cancel then
					unit:delete(false)
					if unit:type() == UnitType.MIRVWarhead then
						if not warheadSeen[launcher] then
							warheadSeen[launcher] = true
							table.insert(warheadOrder, launcher)
						end
					else
						bump(launcher)
					end
				end
			end
		end
	end
	for _, launcher in warheadOrder do
		bump(launcher)
	end
	for _, launcher in order do
		local count = neutralized[launcher]
		local other = if launcher == self.requestor then recipient else self.requestor
		mg:displayMessage("events_display.alliance_nukes_destroyed_outgoing", "ALLIANCE_ACCEPTED", launcher:id(), nil, { name = other:displayName(), count = count })
		mg:displayMessage("events_display.alliance_nukes_destroyed_incoming", "ALLIANCE_ACCEPTED", other:id(), nil, { name = launcher:displayName(), count = count })
	end
end

return AllianceRequestExecution
