--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/AllianceImpl.ts and AllianceRequestImpl.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Alliances and alliance requests. An alliance lasts allianceDuration
-- ticks; both sides may agree to extend it near the end. Requests stay
-- pending until accepted, rejected or expired (AllianceRequestExecution).

local Alliance = {}
Alliance.__index = Alliance

export type Alliance = typeof(setmetatable(
	{} :: {
		mg: any,
		requestor_: any,
		recipient_: any,
		createdAt_: number,
		id_: number,
		expiresAt_: number,
		extensionRequestedRequestor_: boolean,
		extensionRequestedRecipient_: boolean,
	},
	Alliance
))

function Alliance.new(mg: any, requestor: any, recipient: any, createdAt: number, id: number): Alliance
	return setmetatable({
		mg = mg,
		requestor_ = requestor,
		recipient_ = recipient,
		createdAt_ = createdAt,
		id_ = id,
		expiresAt_ = createdAt + mg:config():allianceDuration(),
		extensionRequestedRequestor_ = false,
		extensionRequestedRecipient_ = false,
	}, Alliance)
end

function Alliance.other(self: Alliance, player: any): any
	return if self.requestor_ == player then self.recipient_ else self.requestor_
end
function Alliance.requestor(self: Alliance): any
	return self.requestor_
end
function Alliance.recipient(self: Alliance): any
	return self.recipient_
end
function Alliance.createdAt(self: Alliance): number
	return self.createdAt_
end
function Alliance.id(self: Alliance): number
	return self.id_
end
function Alliance.expiresAt(self: Alliance): number
	return self.expiresAt_
end

function Alliance.expire(self: Alliance)
	self.mg:expireAlliance(self)
end

function Alliance.addExtensionRequest(self: Alliance, player: any)
	if self.requestor_ == player then
		self.extensionRequestedRequestor_ = true
	elseif self.recipient_ == player then
		self.extensionRequestedRecipient_ = true
	end
	self.mg:addUpdate({ type = "AllianceExtension", playerID = player:smallID(), allianceID = self.id_ })
end

function Alliance.bothAgreedToExtend(self: Alliance): boolean
	return self.extensionRequestedRequestor_ and self.extensionRequestedRecipient_
end

-- One side asked to extend and the other hasn't (yet).
function Alliance.onlyOneAgreedToExtend(self: Alliance): boolean
	return self.extensionRequestedRequestor_ ~= self.extensionRequestedRecipient_
end

function Alliance.agreedToExtend(self: Alliance, player: any): boolean
	return (self.requestor_ == player and self.extensionRequestedRequestor_)
		or (self.recipient_ == player and self.extensionRequestedRecipient_)
end

function Alliance.extend(self: Alliance)
	self.extensionRequestedRequestor_ = false
	self.extensionRequestedRecipient_ = false
	self.expiresAt_ = self.mg:ticks() + self.mg:config():allianceDuration()
end

-- AllianceRequestImpl ---------------------------------------------------------------

local AllianceRequest = {}
AllianceRequest.__index = AllianceRequest
Alliance.Request = AllianceRequest

export type AllianceRequest = typeof(setmetatable(
	{} :: { status_: string, requestor_: any, recipient_: any, tickCreated: number, game: any },
	AllianceRequest
))

function AllianceRequest.new(requestor: any, recipient: any, tickCreated: number, game: any): AllianceRequest
	return setmetatable({ status_ = "pending", requestor_ = requestor, recipient_ = recipient, tickCreated = tickCreated, game = game }, AllianceRequest)
end

function AllianceRequest.status(self: AllianceRequest): string
	return self.status_
end
function AllianceRequest.requestor(self: AllianceRequest): any
	return self.requestor_
end
function AllianceRequest.recipient(self: AllianceRequest): any
	return self.recipient_
end
function AllianceRequest.createdAt(self: AllianceRequest): number
	return self.tickCreated
end

function AllianceRequest.accept(self: AllianceRequest)
	self.status_ = "accepted"
	self.game:acceptAllianceRequest(self)
end

function AllianceRequest.reject(self: AllianceRequest)
	self.status_ = "rejected"
	self.game:rejectAllianceRequest(self)
end

function AllianceRequest.toUpdate(self: AllianceRequest): { [string]: any }
	return {
		type = "AllianceRequest",
		requestorID = self.requestor_:smallID(),
		recipientID = self.recipient_:smallID(),
		createdAt = self.tickCreated,
	}
end

return Alliance
