--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/QuickChatExecution.ts, TargetPlayerExecution.ts and MarkDisconnectedExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Small one-shot player actions:
--   - QuickChat: a canned message ("category.key") to one player, with a
--     per-recipient cooldown.
--   - TargetPlayer: marks a target for allies; the target's relation to us
--     drops by 40.
--   - MarkDisconnected: flags a player as away (or back).

local SocialExecutions = {}

local function oneShot(class: any)
	class.__index = class
	function class.isActive(self: any): boolean
		return self.active
	end
	function class.activeDuringSpawnPhase(_self: any): boolean
		return false
	end
end

-- QuickChatExecution -------------------------------------------------------------------

local QuickChat = {}
oneShot(QuickChat)
SocialExecutions.QuickChat = QuickChat

function QuickChat.new(sender: any, recipientID: string, quickChatKey: string, target: string?): any
	return setmetatable({ active = true, mg = nil, recipient = nil, sender = sender, recipientID = recipientID, key = quickChatKey, target = target }, QuickChat)
end

function QuickChat.init(self: any, mg: any, _ticks: number)
	self.mg = mg
	if not mg:hasPlayer(self.recipientID) then
		self.active = false
		return
	end
	self.recipient = mg:player(self.recipientID)
end

function QuickChat.tick(self: any, _ticks: number)
	if not self.sender:canSendQuickChat(self.recipient) then
		self.active = false
		return
	end
	local parts = string.split(self.key, ".")
	self.sender:recordQuickChat(self.recipient)
	self.mg:displayChat(parts[2], parts[1], self.target, self.recipient:id(), true, self.sender:id())
	self.mg:displayChat(parts[2], parts[1], self.target, self.sender:id(), false, self.recipient:id())
	self.active = false
end

function QuickChat.owner(self: any): any
	return self.sender
end

-- TargetPlayerExecution ----------------------------------------------------------------

local TargetPlayer = {}
oneShot(TargetPlayer)
SocialExecutions.TargetPlayer = TargetPlayer

function TargetPlayer.new(requestor: any, targetID: string): any
	return setmetatable({ active = true, target = nil, requestor = requestor, targetID = targetID }, TargetPlayer)
end

function TargetPlayer.init(self: any, mg: any, _ticks: number)
	if not mg:hasPlayer(self.targetID) then
		self.active = false
		return
	end
	self.target = mg:player(self.targetID)
end

function TargetPlayer.tick(self: any, _ticks: number)
	if self.requestor:canTarget(self.target) then
		self.requestor:target(self.target)
		self.target:updateRelation(self.requestor, -40)
	end
	self.active = false
end

-- MarkDisconnectedExecution ------------------------------------------------------------

local MarkDisconnected = {}
oneShot(MarkDisconnected)
SocialExecutions.MarkDisconnected = MarkDisconnected

function MarkDisconnected.new(player: any, isDisconnected: boolean): any
	return setmetatable({ active = false, player = player, isDisconnected = isDisconnected }, MarkDisconnected)
end

function MarkDisconnected.init(self: any, mg: any, ticks: number)
	if self.isDisconnected then
		local team = self.player:team()
		self.player:markDisconnected(true, {
			currentTick = ticks,
			teamTiles = if team then mg:teamTilesOwned(team) else 0,
			totalLand = mg:totalLandTiles(),
			wasAlive = self.player:isAlive(),
		})
	else
		self.player:markDisconnected(false)
	end
end

function MarkDisconnected.tick(_self: any, _ticks: number) end

return SocialExecutions
