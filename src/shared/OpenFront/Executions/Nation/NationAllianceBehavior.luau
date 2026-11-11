--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/NationAllianceBehavior.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Nation alliance decisions: answering requests and renewals, asking
-- bordering players, and betraying allies when it pays. Decisions weigh
-- (in order) confusion on easier levels, traitors, players with too many
-- alliances, runaway leaders, threats, team games, relation, friendship,
-- how many alliances we already have, the early game and relative strength.

local Emoji = require(script.Parent.Parent.Parent.Data.Emoji)
local GameTypes = require(script.Parent.Parent.Parent.GameTypes)
local NationUtils = require(script.Parent.NationUtils)

local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType

local Relation = { Hostile = 0, Distrustful = 1, Neutral = 2, Friendly = 3 }

local NationAllianceBehavior = {}
NationAllianceBehavior.__index = NationAllianceBehavior

export type NationAllianceBehavior = typeof(setmetatable(
	{} :: { random: any, game: any, player: any, emojiBehavior: any },
	NationAllianceBehavior
))

function NationAllianceBehavior.new(random: any, game: any, player: any, emojiBehavior: any): NationAllianceBehavior
	return setmetatable({ random = random, game = game, player = player, emojiBehavior = emojiBehavior }, NationAllianceBehavior)
end

function NationAllianceBehavior._difficulty(self: NationAllianceBehavior): string
	return self.game:config():gameConfig().difficulty
end

local function outgoingTroops(p: any): number
	local sum = 0
	for _, a in p:outgoingAttacks() do
		sum += a:troops()
	end
	return sum
end

function NationAllianceBehavior.handleAllianceRequests(self: NationAllianceBehavior)
	if self.game:config():disableAlliances() then
		return
	end
	for _, req in self.player:incomingAllianceRequests() do
		-- Requests made during the spawn phase land on its first tick: reject them.
		if req:createdAt() <= self.game:config():numSpawnPhaseTurns() + 1 then
			req:reject()
		elseif self:_getAllianceDecision(req:requestor(), true) then
			req:accept()
		else
			req:reject()
		end
	end
end

function NationAllianceBehavior.handleAllianceExtensionRequests(self: NationAllianceBehavior)
	if self.game:config():disableAlliances() then
		return
	end
	for _, alliance: any in table.clone(self.player:alliances()) do
		-- Only a human ally can ask to renew.
		if alliance:onlyOneAgreedToExtend() then
			local human = alliance:other(self.player)
			if self:_getAllianceDecision(human, true) then
				local AllianceExtensionExecution = require(script.Parent.Parent.AllianceExtensionExecution)
				self.game:addExecution(AllianceExtensionExecution.new(self.player, human:id()))
			end
		end
	end
end

function NationAllianceBehavior.maybeSendAllianceRequests(self: NationAllianceBehavior, borderingEnemies: { any })
	if self.game:config():disableAlliances() then
		return
	end
	-- Only easy nations ask tribes.
	local easy = self:_difficulty() == Difficulty.Easy
	for _, enemy in borderingEnemies do
		if
			self.random:chance(30)
			and ((enemy:type() == PlayerType.Bot and easy) or enemy:type() ~= PlayerType.Bot)
			and self.player:canSendAllianceRequest(enemy)
			and self:_getAllianceDecision(enemy, false)
		then
			local AllianceRequestExecution = require(script.Parent.Parent.AllianceRequestExecution)
			self.game:addExecution(AllianceRequestExecution.new(self.player, enemy:id()))
		end
	end
end

function NationAllianceBehavior._getAllianceDecision(self: NationAllianceBehavior, other: any, isResponse: boolean): boolean
	if self:_isConfused() then
		return self.random:chance(2)
	end
	-- Nearly always reject traitors.
	if other:isTraitor() and self.random:nextInt(0, 100) >= 10 then
		if isResponse and self.random:chance(3) then
			self.emojiBehavior:sendEmoji(other, Emoji.CONFUSED)
		end
		return false
	end
	if self:_hasTooManyAlliances(other) then
		return false
	end
	if NationUtils.findRunawayLeader(self.game) == other then
		return false
	end
	if self:_isAlliancePartnerThreat(other) then
		if not isResponse and self.random:chance(6) then
			self.emojiBehavior:sendEmoji(other, Emoji.SCARED_OF_THREAT)
		end
		if isResponse and self.random:chance(6) then
			self.emojiBehavior:sendEmoji(other, Emoji.LOVE)
		end
		return true
	end
	if self:_shouldRejectInTeamGame() then
		return false
	end
	if self.player:relation(other) < Relation.Neutral then
		if isResponse and self.random:chance(3) then
			self.emojiBehavior:sendEmoji(other, Emoji.CONFUSED)
		end
		return false
	end
	if self:_isAlliancePartnerFriendly(other) then
		if self.random:chance(3) then
			self.emojiBehavior:sendEmoji(other, Emoji.HANDSHAKE)
		end
		return true
	end
	if self:_checkAlreadyEnoughAlliances(other) then
		return false
	end
	if self:_isEarlygame() then
		return true
	end
	return self:_isAlliancePartnerSimilarlyStrong(other)
end

-- Hard and Impossible keep enough unallied players around to stop the crown.
function NationAllianceBehavior._hasTooManyAlliances(self: NationAllianceBehavior, other: any): boolean
	local d = self:_difficulty()
	if d ~= Difficulty.Hard and d ~= Difficulty.Impossible then
		return false
	end
	local total = 0
	for _, p in self.game:players() do
		if p:type() ~= PlayerType.Bot then
			total += 1
		end
	end
	local n = #other:alliances()
	return if d == Difficulty.Hard then n >= total * 0.5 else n >= total * 0.25
end

function NationAllianceBehavior._isConfused(self: NationAllianceBehavior): boolean
	local d = self:_difficulty()
	if d == Difficulty.Easy then
		return self.random:chance(10)
	elseif d == Difficulty.Medium then
		return self.random:chance(20)
	elseif d == Difficulty.Hard then
		return self.random:chance(40)
	end
	return false
end

function NationAllianceBehavior._isEarlygame(self: NationAllianceBehavior): boolean
	local spawnTicks = self.game:config():numSpawnPhaseTurns()
	local ticks = self.game:ticks()
	local d = self:_difficulty()
	if d == Difficulty.Easy then
		return ticks < 3000 + spawnTicks and self.random:nextInt(0, 100) >= 10
	elseif d == Difficulty.Medium then
		return ticks < 1800 + spawnTicks and self.random:nextInt(0, 100) >= 30
	elseif d == Difficulty.Hard then
		return ticks < 1800 + spawnTicks and self.random:nextInt(0, 100) >= 50
	end
	return ticks < 600 + spawnTicks and self.random:nextInt(0, 100) >= 70
end

function NationAllianceBehavior._isAlliancePartnerThreat(self: NationAllianceBehavior, other: any): boolean
	local d = self:_difficulty()
	local me = self.player
	local config = self.game:config()
	if d == Difficulty.Easy then
		return false
	elseif d == Difficulty.Medium then
		return other:troops() > me:troops() * 2.5
	elseif d == Difficulty.Hard then
		return other:troops() > me:troops() and config:maxTroops(other) > config:maxTroops(me) * 2
	end
	local moreTroops = other:troops() > me:troops() * 1.5
	local moreMax = other:troops() > me:troops() and config:maxTroops(other) > config:maxTroops(me) * 1.5
	local moreTiles = other:troops() > me:troops() and other:numTilesOwned() > me:numTilesOwned() * 1.5
	return moreTroops or moreMax or moreTiles
end

function NationAllianceBehavior._shouldRejectInTeamGame(self: NationAllianceBehavior): boolean
	if self.game:config():gameConfig().gameMode ~= GameTypes.GameMode.Team then
		return false
	end
	local d = self:_difficulty()
	if d == Difficulty.Easy then
		return self.random:nextInt(0, 100) < 25
	elseif d == Difficulty.Medium then
		return self.random:nextInt(0, 100) < 50
	elseif d == Difficulty.Hard then
		return self.random:nextInt(0, 100) < 75
	end
	return true
end

function NationAllianceBehavior._checkAlreadyEnoughAlliances(self: NationAllianceBehavior, other: any): boolean
	local d = self:_difficulty()
	local me = self.player
	if d == Difficulty.Easy then
		return false
	elseif d == Difficulty.Medium then
		return #me:alliances() >= self.random:nextInt(4, 6)
	end
	-- Hard/Impossible: don't ally with every neighbour (with 2+ neighbours).
	local bordering, friends = {}, 0
	for _, n in me:nearby() do
		if n:isPlayer() and n:type() ~= PlayerType.Bot then
			table.insert(bordering, n)
			if me:isFriendly(n) then
				friends += 1
			end
		end
	end
	if #bordering >= 2 and table.find(bordering, other) then
		return #bordering <= friends + 1
	end
	if d == Difficulty.Hard then
		return #me:alliances() >= self.random:nextInt(3, 5)
	end
	return #me:alliances() >= self.random:nextInt(2, 4)
end

function NationAllianceBehavior._isAlliancePartnerFriendly(self: NationAllianceBehavior, other: any): boolean
	local d = self:_difficulty()
	local friendly = self.player:relation(other) == Relation.Friendly
	if d == Difficulty.Easy or d == Difficulty.Medium then
		return friendly
	elseif d == Difficulty.Hard then
		return friendly and self.random:nextInt(0, 100) >= 17
	end
	return friendly and self.random:nextInt(0, 100) >= 33
end

local TROOP_RANGE = {
	[Difficulty.Easy] = { 60, 70 },
	[Difficulty.Medium] = { 70, 80 },
	[Difficulty.Hard] = { 75, 85 },
	[Difficulty.Impossible] = { 80, 90 },
}
local TILE_RANGE = {
	[Difficulty.Easy] = { 70, 80 },
	[Difficulty.Medium] = { 80, 90 },
	[Difficulty.Hard] = { 85, 95 },
	[Difficulty.Impossible] = { 90, 100 },
}

function NationAllianceBehavior._isAlliancePartnerSimilarlyStrong(self: NationAllianceBehavior, other: any): boolean
	local d = self:_difficulty()
	local troopRange, tileRange = TROOP_RANGE[d], TILE_RANGE[d]
	local me = self.player
	local myTotal = me:troops() + outgoingTroops(me)
	local otherTotal = other:troops() + outgoingTroops(other)
	local troopThreshold = myTotal * (self.random:nextInt(troopRange[1], troopRange[2]) / 100)
	local tileThreshold = me:numTilesOwned() * (self.random:nextInt(tileRange[1], tileRange[2]) / 100)
	local comparableTroops = otherTotal > troopThreshold
	local comparableTiles = other:numTilesOwned() > tileThreshold and otherTotal > myTotal * 0.5
	return comparableTroops or comparableTiles
end

-- juiciestAlly comes from findJuiciestAlly(borderingFriends), computed once
-- by callers looping over the friends.
function NationAllianceBehavior.maybeBetray(self: NationAllianceBehavior, other: any, juiciestAlly: any?, borderingFriends: { any }, borderingEnemies: { any }): boolean
	local me = self.player
	if not me:isAlliedWith(other) then
		return false
	end
	local d = self:_difficulty()
	-- The juiciest ally (say, a MIRVed one), when everyone around is weak.
	if (d == Difficulty.Hard or d == Difficulty.Impossible) and juiciestAlly == other and self:_isSafeToBetray(other, borderingFriends, borderingEnemies) then
		self:_betray(other)
		return true
	end
	-- Very weak allies on the easier levels (never humans on Easy).
	if (d == Difficulty.Easy or d == Difficulty.Medium) and not (d == Difficulty.Easy and other:type() == PlayerType.Human) and me:troops() >= other:troops() * 10 then
		self:_betray(other)
		return true
	end
	-- Traitors not much stronger than us.
	if d ~= Difficulty.Easy and other:isTraitor() and other:troops() < me:troops() * 1.2 then
		self:_betray(other)
		return true
	end
	-- Our only neighbour, if much weaker.
	if d ~= Difficulty.Easy and #borderingFriends + #borderingEnemies == 1 and other:troops() * 3 < me:troops() then
		self:_betray(other)
		return true
	end
	return false
end

function NationAllianceBehavior.findJuiciestAlly(self: NationAllianceBehavior, borderingFriends: { any }): any?
	local candidates = {}
	for _, f in borderingFriends do
		if self.player:isAlliedWith(f) then
			table.insert(candidates, f)
		end
	end
	return NationUtils.findJuiciestTarget(self.game, candidates)
end

-- Safe if the target, our unallied neighbours and (unless the target is a
-- traitor) our other allies stay under a third of our troops.
function NationAllianceBehavior._isSafeToBetray(self: NationAllianceBehavior, target: any, borderingFriends: { any }, borderingEnemies: { any }): boolean
	local threats = { target }
	for _, e in borderingEnemies do
		table.insert(threats, e)
	end
	if not target:isTraitor() then
		for _, f in borderingFriends do
			if f ~= target and self.player:isAlliedWith(f) then
				table.insert(threats, f)
			end
		end
	end
	local troops = 0
	for _, t in threats do
		troops += t:troops() + outgoingTroops(t)
	end
	return troops < self.player:troops() * 0.33
end

function NationAllianceBehavior._betray(self: NationAllianceBehavior, target: any)
	local alliance = self.player:allianceWith(target)
	if alliance then
		self.player:breakAlliance(alliance)
	end
end

return NationAllianceBehavior
