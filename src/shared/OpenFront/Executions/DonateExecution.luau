--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/DonateGoldExecution.ts and DonateTroopExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Gold and troop donations to a friendly player.
--   - Gold (default: a third of ours) earns 5 relation per chunk donated,
--     chunks growing with difficulty and game time, capped at 100.
--   - Troops (default: defaultDonationAmount, at most what the recipient has
--     room for) earn 50 relation above a random minimum.
--   - A nation answers with an emoji (thanks, or "too small").

local Emoji = require(script.Parent.Parent.Data.Emoji)
local GameTypes = require(script.Parent.Parent.GameTypes)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local Util = require(script.Parent.Parent.Util)

local PlayerType = GameTypes.PlayerType

local DonateExecution = {}

-- DonateGoldExecution ------------------------------------------------------------------

local Gold = {}
Gold.__index = Gold
DonateExecution.Gold = Gold

function Gold.new(sender: any, recipientID: string, gold: number?): any
	return setmetatable({
		recipient = nil,
		gold = if gold ~= nil then Util.toInt(gold) else nil,
		mg = nil,
		random = nil,
		active = true,
		sender = sender,
		recipientID = recipientID,
	}, Gold)
end

function Gold.init(self: any, mg: any, _ticks: number)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
	if not mg:hasPlayer(self.recipientID) then
		self.active = false
		return
	end
	self.recipient = mg:player(self.recipientID)
	if self.gold == nil then
		self.gold = self.sender:gold() // 3
	end
end

local GOLD_CHUNK = { Easy = 2_500, Medium = 5_000, Hard = 12_500, Impossible = 25_000 }

function Gold._relationUpdate(self: any, goldSent: number, ticks: number): number
	local chunkSize = GOLD_CHUNK[self.mg:config():gameConfig().difficulty]
	-- Chunks grow every 5 minutes of play.
	local multiplier = ticks / (3000 + self.mg:config():numSpawnPhaseTurns())
	local adjusted = math.floor(chunkSize + chunkSize * multiplier + 0.5)
	local relation = (goldSent // adjusted) * 5
	return if relation > 100 then 100 else relation
end

function Gold.tick(self: any, ticks: number)
	local sender, recipient = self.sender, self.recipient
	if sender:canDonateGold(recipient) and sender:donateGold(recipient, self.gold) then
		local relationUpdate = self:_relationUpdate(self.gold, ticks)
		if relationUpdate > 0 then
			recipient:updateRelation(sender, relationUpdate)
		end
		if recipient:type() == PlayerType.Nation and recipient:canSendEmoji(sender) then
			local group = if relationUpdate >= 50 then Emoji.LOVE elseif relationUpdate > 0 then Emoji.DONATION_OK else Emoji.DONATION_TOO_SMALL
			local EmojiExecution = require(script.Parent.EmojiExecution) :: any
			self.mg:addExecution(EmojiExecution.new(recipient, sender:id(), self.random:randElement(group)))
		end
	end
	self.active = false
end

function Gold.isActive(self: any): boolean
	return self.active
end
function Gold.activeDuringSpawnPhase(_self: any): boolean
	return false
end

-- DonateTroopsExecution ----------------------------------------------------------------

local Troops = {}
Troops.__index = Troops
DonateExecution.Troops = Troops

function Troops.new(sender: any, recipientID: string, troops: number?): any
	return setmetatable({
		recipient = nil,
		random = nil,
		mg = nil,
		active = true,
		sender = sender,
		recipientID = recipientID,
		troops = troops,
	}, Troops)
end

function Troops.init(self: any, mg: any, _ticks: number)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
	if not mg:hasPlayer(self.recipientID) then
		self.active = false
		return
	end
	self.recipient = mg:player(self.recipientID)
	if self.troops == nil then
		self.troops = mg:config():defaultDonationAmount(self.sender)
	end
	local room = mg:config():maxTroops(self.recipient) - self.recipient:troops()
	self.troops = math.min(self.troops, room)
	if self.troops <= 0 then
		self.active = false
	end
end

-- A random minimum, so a token donation can't buy a good relation.
local MIN_DIVISORS = { Easy = { 13, 11 }, Medium = { 11, 9 }, Hard = { 9, 7 }, Impossible = { 7, 5 } }

function Troops._minTroopsForRelation(self: any): number
	local d = MIN_DIVISORS[self.mg:config():gameConfig().difficulty]
	local maxTroops = self.mg:config():maxTroops(self.recipient)
	return self.random:nextInt(maxTroops / d[1], maxTroops / d[2])
end

function Troops.tick(self: any, _ticks: number)
	local minTroops = self:_minTroopsForRelation()
	local sender, recipient = self.sender, self.recipient
	if sender:canDonateTroops(recipient) and sender:donateTroops(recipient, self.troops) then
		if self.troops >= minTroops then
			recipient:updateRelation(sender, 50)
		end
		if recipient:type() == PlayerType.Nation and recipient:canSendEmoji(sender) then
			local group = if self.troops >= minTroops then Emoji.LOVE else Emoji.DONATION_TOO_SMALL
			local EmojiExecution = require(script.Parent.EmojiExecution) :: any
			self.mg:addExecution(EmojiExecution.new(recipient, sender:id(), self.random:randElement(group)))
		end
	end
	self.active = false
end

function Troops.isActive(self: any): boolean
	return self.active
end
function Troops.activeDuringSpawnPhase(_self: any): boolean
	return false
end

return DonateExecution
