--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/EmojiExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Sends an emoji (an id into the emoji table) to a player or to everyone,
-- within the per-recipient rate limit. Nations may answer it.

local Emoji = require(script.Parent.Parent.Data.Emoji)
local GameTypes = require(script.Parent.Parent.GameTypes)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)

local AllPlayers = GameTypes.AllPlayers

local EmojiExecution = {}
EmojiExecution.__index = EmojiExecution

export type EmojiExecution = typeof(setmetatable(
	{} :: { recipient: any, mg: any, random: PseudoRandom.PseudoRandom, active: boolean, requestor: any, recipientID: string, emoji: number },
	EmojiExecution
))

function EmojiExecution.new(requestor: any, recipientID: string, emoji: number): EmojiExecution
	return setmetatable({
		recipient = nil,
		mg = nil,
		random = nil :: any,
		active = true,
		requestor = requestor,
		recipientID = recipientID,
		emoji = emoji,
	}, EmojiExecution)
end

function EmojiExecution.init(self: EmojiExecution, mg: any, _ticks: number)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
	if self.recipientID ~= AllPlayers and not mg:hasPlayer(self.recipientID) then
		self.active = false
		return
	end
	self.recipient = if self.recipientID == AllPlayers then AllPlayers else mg:player(self.recipientID)
end

function EmojiExecution.tick(self: EmojiExecution, _ticks: number)
	local emojiString = Emoji.flat[self.emoji]
	if emojiString ~= nil and self.requestor:canSendEmoji(self.recipient) then
		self.requestor:sendEmoji(self.recipient, emojiString)
		local NationEmojiBehavior = require(script.Parent.Nation.NationEmojiBehavior) :: any
		NationEmojiBehavior.respondToEmoji(self.mg, self.random, self.requestor, self.recipient, emojiString)
	end
	self.active = false
end

function EmojiExecution.isActive(self: EmojiExecution): boolean
	return self.active
end

function EmojiExecution.activeDuringSpawnPhase(_self: EmojiExecution): boolean
	return false
end

return EmojiExecution
