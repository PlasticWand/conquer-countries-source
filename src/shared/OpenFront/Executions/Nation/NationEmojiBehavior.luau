--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/NationEmojiBehavior.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Nation emoji: casual ones (overwhelmed, bored by tiny attacks, victory
-- and congratulations, bragging, charming human allies, mocking traitors,
-- spotting rats, greeting neighbours), attack emoji, and replies to
-- emoji humans send (insults cost relation; doves and hearts may earn it).
-- At most one emoji to each human per 300 ticks.

local Emoji = require(script.Parent.Parent.Parent.Data.Emoji)
local GameTypes = require(script.Parent.Parent.Parent.GameTypes)
local Util = require(script.Parent.Parent.Parent.Util)

local AllPlayers = GameTypes.AllPlayers
local PlayerType = GameTypes.PlayerType

local Relation = { Hostile = 0, Distrustful = 1, Neutral = 2, Friendly = 3 }

local function EmojiExecution(): any
	return require(script.Parent.Parent.EmojiExecution)
end

local NationEmojiBehavior = {}
NationEmojiBehavior.__index = NationEmojiBehavior

export type NationEmojiBehavior = typeof(setmetatable(
	{} :: { lastEmojiSent: { [any]: number }, gameOver: boolean, random: any, game: any, player: any },
	NationEmojiBehavior
))

function NationEmojiBehavior.new(random: any, game: any, player: any): NationEmojiBehavior
	return setmetatable({ lastEmojiSent = {}, gameOver = false, random = random, game = game, player = player }, NationEmojiBehavior)
end

function NationEmojiBehavior.maybeSendCasualEmoji(self: NationEmojiBehavior)
	if self.gameOver then
		return
	end
	self:_checkOverwhelmedByAttacks()
	self:_checkVerySmallAttack()
	self:_congratulateWinner()
	self:_brag()
	self:_charmAllies()
	self:_annoyTraitors()
	self:_findRat()
	self:_greetNearbyPlayers()
end

function NationEmojiBehavior._checkOverwhelmedByAttacks(self: NationEmojiBehavior)
	if not self.random:chance(16) then
		return
	end
	local incoming = self.player:incomingAttacks()
	if #incoming == 0 then
		return
	end
	local troops = 0
	for _, a in incoming do
		troops += a:troops()
	end
	if troops >= self.player:troops() * 3 then
		self:sendEmoji(AllPlayers, Emoji.OVERWHELMED)
	end
end

function NationEmojiBehavior._checkVerySmallAttack(self: NationEmojiBehavior)
	if not self.random:chance(8) then
		return
	end
	local incoming = self.player:incomingAttacks()
	if #incoming == 0 then
		return
	end
	local ours = self.player:troops()
	if ours <= 0 then
		return
	end
	for _, attack in incoming do
		local attacker = attack:attacker()
		if attacker:type() == PlayerType.Human and attack:troops() < ours * 0.1 then
			self:maybeSendEmoji(attacker, if self.random:chance(2) then Emoji.CONFUSED else Emoji.BORED)
		end
	end
end

local function byTilesDesc(list: { any }): { any }
	return Util.stableSort(list, function(a, b)
		return a:numTilesOwned() > b:numTilesOwned()
	end)
end

function NationEmojiBehavior._congratulateWinner(self: NationEmojiBehavior)
	local winner = self.game:getWinner()
	if winner == nil then
		return
	end
	self.gameOver = true
	if winner == self.player or winner == self.player:team() then
		if self.random:chance(2) then
			self:sendEmoji(AllPlayers, Emoji.VICTORY)
		end
		return
	end
	if self.game:config():gameConfig().gameMode == GameTypes.GameMode.Team then
		self:sendEmoji(AllPlayers, Emoji.CONGRATULATE)
	else
		if type(winner) == "string" then
			return -- a team
		end
		local nations = {}
		for _, p in self.game:players() do
			if p:type() == PlayerType.Nation then
				table.insert(nations, p)
			end
		end
		if byTilesDesc(nations)[1] ~= self.player then
			return
		end
		self:sendEmoji(winner, Emoji.CONGRATULATE)
	end
end

function NationEmojiBehavior._brag(self: NationEmojiBehavior)
	if not self.random:chance(300) then
		return
	end
	local sorted = byTilesDesc(table.clone(self.game:players()))
	if #sorted == 0 or sorted[1] ~= self.player then
		return
	end
	self:sendEmoji(AllPlayers, Emoji.BRAG)
end

function NationEmojiBehavior._charmAllies(self: NationEmojiBehavior)
	if not self.random:chance(250) then
		return
	end
	local humans = {}
	for _, p in self.player:allies() do
		if p:type() == PlayerType.Human then
			table.insert(humans, p)
		end
	end
	if #humans == 0 then
		return
	end
	local ally = self.random:randElement(humans)
	self:sendEmoji(ally, if self.random:chance(3) then Emoji.LOVE else Emoji.CHARM_ALLIES)
end

function NationEmojiBehavior._annoyTraitors(self: NationEmojiBehavior)
	if not self.random:chance(3) then
		return
	end
	for _, traitor in self.game:players() do
		-- One nation mocks each traitor, not the whole map.
		if traitor:type() == PlayerType.Human and traitor:isTraitor() and self:_traitorMocker(traitor) == self.player then
			self:sendEmoji(traitor, Emoji.CLOWN)
		end
	end
end

-- The most hostile nation (usually the betrayed one), first on ties.
function NationEmojiBehavior._traitorMocker(self: NationEmojiBehavior, traitor: any): any?
	local mocker = nil
	for _, p in self.game:players() do
		if p:type() == PlayerType.Nation and not p:isFriendly(traitor) then
			if mocker == nil or p:relation(traitor) < mocker:relation(traitor) then
				mocker = p
			end
		end
	end
	return mocker
end

function NationEmojiBehavior._findRat(self: NationEmojiBehavior)
	if self.game:ticks() < 6000 then
		return -- everyone is small in the first 10 minutes
	end
	if not self.random:chance(10000) then
		return
	end
	local threshold = self.game:numLandTiles() * 0.01
	local small = {}
	for _, p in self.game:players() do
		if p:type() == PlayerType.Human and p:numTilesOwned() < threshold and p:numTilesOwned() > 0 then
			table.insert(small, p)
		end
	end
	if #small == 0 then
		return
	end
	self:sendEmoji(self.random:randElement(small), Emoji.RAT)
end

function NationEmojiBehavior._greetNearbyPlayers(self: NationEmojiBehavior)
	if self.game:ticks() > 600 then
		return
	end
	if not self.random:chance(250) then
		return
	end
	local humans = {}
	for _, p in self.player:nearby() do
		if p:isPlayer() and p:type() == PlayerType.Human then
			table.insert(humans, p)
		end
	end
	if #humans == 0 then
		return
	end
	self:sendEmoji(self.random:randElement(humans), Emoji.GREET)
end

function NationEmojiBehavior.maybeSendEmoji(self: NationEmojiBehavior, other: any, emojis: { number })
	if not self:_shouldSendEmoji(other, true) then
		return
	end
	self:sendEmoji(other, emojis)
end

-- Aggressive when we like them (we are probably attacking first),
-- otherwise angry (probably retaliating).
function NationEmojiBehavior.maybeSendAttackEmoji(self: NationEmojiBehavior, other: any)
	if not self:_shouldSendEmoji(other, true) then
		return
	end
	if self.player:relation(other) >= Relation.Neutral then
		if not self.random:chance(2) then
			return
		end
		self:sendEmoji(other, Emoji.AGGRESSIVE_ATTACK)
		return
	end
	if not self.random:chance(4) then
		return
	end
	self:sendEmoji(other, Emoji.ATTACK)
end

function NationEmojiBehavior.sendEmoji(self: NationEmojiBehavior, other: any, emojis: { number })
	if not self:_shouldSendEmoji(other, false) then
		return
	end
	if not self.player:canSendEmoji(other) then
		return
	end
	self.game:addExecution(EmojiExecution().new(self.player, if other == AllPlayers then AllPlayers else other:id(), self.random:randElement(emojis)))
end

function NationEmojiBehavior._shouldSendEmoji(self: NationEmojiBehavior, other: any, limitByTime: boolean): boolean
	if other == AllPlayers then
		return true
	end
	if self.player:type() == PlayerType.Bot then
		return false
	end
	if other:type() ~= PlayerType.Human then
		return false
	end
	if limitByTime then
		local last = self.lastEmojiSent[other] or -300
		if self.game:ticks() - last <= 300 then
			return false
		end
		self.lastEmojiSent[other] = self.game:ticks()
	end
	return true
end

local FRIENDLY = { ["🕊️"] = true, ["🏳️"] = true, ["❤️"] = true, ["🥰"] = true, ["👏"] = true }

-- A nation answers an emoji sent to it.
function NationEmojiBehavior.respondToEmoji(game: any, random: any, sender: any, recipient: any, emojiString: string)
	if recipient == AllPlayers or recipient:type() ~= PlayerType.Nation then
		return
	end
	if not recipient:canSendEmoji(sender) then
		return
	end
	if emojiString == "🖕" then
		recipient:updateRelation(sender, -100)
		game:addExecution(EmojiExecution().new(recipient, sender:id(), random:randElement(Emoji.GOT_INSULTED)))
	end
	if emojiString == "🤡" then
		recipient:updateRelation(sender, -10)
		game:addExecution(EmojiExecution().new(recipient, sender:id(), random:randElement(Emoji.CONFUSED)))
	end
	if FRIENDLY[emojiString] then
		if game:config():gameConfig().difficulty == GameTypes.Difficulty.Easy then
			recipient:updateRelation(sender, 15)
		end
		local group = if sender:relation(recipient) >= Relation.Neutral then Emoji.LOVE else Emoji.CONFUSED
		game:addExecution(EmojiExecution().new(recipient, sender:id(), random:randElement(group)))
	end
end

function NationEmojiBehavior.respondToMIRV(game: any, random: any, mirvTarget: any)
	if not random:chance(8) then
		return
	end
	if not mirvTarget:canSendEmoji(AllPlayers) then
		return
	end
	game:addExecution(EmojiExecution().new(mirvTarget, AllPlayers, random:randElement(Emoji.OVERWHELMED)))
end

return NationEmojiBehavior
