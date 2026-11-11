--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/AttackExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- One attack (or expansion into free land) running tick by tick: a heap of
-- the target's tiles on our border, taken in priority order until the tick's
-- budget (1) is spent, each tile priced by EngineConfig.attackLogic.
-- `targetID` nil means terra nullius. Snapshot support is not ported.

local Difficulty = require(script.Parent.Parent.GameTypes).Difficulty
local FlatBinaryHeap = require(script.Parent.Parent.FlatBinaryHeap)
local GameMap = require(script.Parent.Parent.GameMap)
local GameTypes = require(script.Parent.Parent.GameTypes)
local Player = require(script.Parent.Parent.Player)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)

local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType
-- Conquest's Field Works (FieldWorksExecution.RADIUS; ARSENAL_V2).
local FIELD_WORKS_RADIUS = 15
local Relation = Player.Relation

local malusForRetreat = 25

local IS_LAND = GameMap.IS_LAND
local MAGNITUDE_MASK = GameMap.MAGNITUDE_MASK
local IMPASSABLE_MAGNITUDE = GameMap.IMPASSABLE_MAGNITUDE
local PLAYER_ID_MASK = GameMap.PLAYER_ID_MASK

local AttackExecution = {}
AttackExecution.__index = AttackExecution

export type AttackExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		toConquer: FlatBinaryHeap.FlatBinaryHeap,
		random: PseudoRandom.PseudoRandom,
		target: any,
		mg: any,
		map: any,
		attack: any,
		ownerSmallID: number,
		targetSmallID: number,
		nbuf: { number },
		startTroops: number?,
		_owner: any,
		_targetID: string?,
		sourceTile: number?,
		removeTroops: boolean,
	},
	AttackExecution
))

function AttackExecution.new(
	startTroops: number?,
	owner: any,
	targetID: string?,
	sourceTile: number?,
	removeTroops: boolean?
): AttackExecution
	return setmetatable({
		active = true,
		toConquer = FlatBinaryHeap.new(),
		random = PseudoRandom.new(123),
		target = nil,
		mg = nil,
		map = nil,
		attack = nil,
		ownerSmallID = 0,
		targetSmallID = 0,
		nbuf = { 0, 0, 0, 0 },
		startTroops = startTroops,
		_owner = owner,
		_targetID = targetID,
		sourceTile = sourceTile,
		removeTroops = if removeTroops == nil then true else removeTroops,
	}, AttackExecution)
end

function AttackExecution.targetID(self: AttackExecution): string?
	return self._targetID
end

function AttackExecution.activeDuringSpawnPhase(_self: AttackExecution): boolean
	return false
end

function AttackExecution.init(self: AttackExecution, mg: any, _ticks: number)
	if not self.active then
		return
	end
	self.mg = mg
	self.map = mg:map()

	if self._targetID ~= nil and not mg:hasPlayer(self._targetID) then
		self.active = false
		return
	end

	self.target = if self._targetID == nil then mg:terraNullius() else mg:player(self._targetID :: string)
	self.ownerSmallID = self._owner:smallID()
	self.targetSmallID = self.target:smallID()

	if self._owner == self.target then
		self.active = false
		return
	end

	-- ALLIANCE CHECK: block attacks on friendly (ally or same team)
	if self.target:isPlayer() and self._owner:isFriendly(self.target) then
		self.active = false
		return
	end

	if self.target:isPlayer() then
		local targetPlayer = self.target
		if targetPlayer:type() ~= PlayerType.Bot and self._owner:type() ~= PlayerType.Bot then
			-- Don't let bots embargo since they can't trade anyway.
			targetPlayer:addEmbargo(self._owner, true)
			self:_rejectIncomingAllianceRequests(targetPlayer)
		end
	end

	if self.target:isPlayer() and not self._owner:canAttackPlayer(self.target) then
		self.active = false
		return
	end

	if self.startTroops == nil then
		self.startTroops = mg:config():attackAmount(self._owner, self.target)
	end
	if self.removeTroops then
		self.startTroops = math.min(self._owner:troops(), self.startTroops :: number)
		-- Take the amount actually deducted (removeTroops floors).
		self.startTroops = self._owner:removeTroops(self.startTroops :: number)
	end
	local startTroops = self.startTroops :: number
	self.attack = self._owner:createAttack(self.target, startTroops, self.sourceTile)
	local attack = self.attack

	if self.sourceTile ~= nil then
		self:_addNeighbors(self.sourceTile :: number)
	else
		self:_refreshToConquer()
	end

	mg:stats():attack(self._owner, self.target, startTroops)

	for _, incoming in self._owner:incomingAttacks() do
		if incoming:attacker() == self.target then
			-- Target has an opposing attack: cancel them out.
			if incoming:troops() > attack:troops() then
				incoming:setTroops(incoming:troops() - attack:troops())
				attack:delete()
				self.active = false
				return
			else
				attack:setTroops(attack:troops() - incoming:troops())
				incoming:delete()
			end
		end
	end
	for _, outgoing in self._owner:outgoingAttacks() do
		if
			outgoing ~= attack
			and outgoing:target() == attack:target()
			-- Boat attacks (sourceTile set) are not combined with other attacks
			and attack:sourceTile() == nil
		then
			attack:setTroops(attack:troops() + outgoing:troops())
			outgoing:delete()
		end
	end

	-- Nothing next to the owner to conquer: the attack doesn't happen.
	if self.toConquer:size() == 0 then
		self:_retreat()
		return
	end

	mg:stats():attackMaxIncoming(self.target, attack:troops())

	if not self.target:isPlayer() then
		return
	end
	local difficulty = mg:config():gameConfig().difficulty
	-- Hitting back at whoever just attacked us doesn't anger them, except on Easy
	if difficulty ~= Difficulty.Easy and self._owner:relation(self.target) == Relation.Hostile then
		return
	end
	local relationChange
	if difficulty == Difficulty.Easy then
		relationChange = -60
	elseif difficulty == Difficulty.Medium then
		relationChange = -70
	elseif difficulty == Difficulty.Hard then
		relationChange = -80
	elseif difficulty == Difficulty.Impossible then
		relationChange = -100
	else
		error(`unknown difficulty {difficulty}`)
	end
	self.target:updateRelation(self._owner, relationChange)
end

function AttackExecution._refreshToConquer(self: AttackExecution)
	self.toConquer:clear()
	self.attack:clearBorder()
	self._owner:borderTiles():forEach(function(tile: number)
		self:_addNeighbors(tile)
	end)
end

function AttackExecution._retreat(self: AttackExecution, malusPercent: number?)
	local attack = self.attack
	local deaths = attack:troops() * ((malusPercent or 0) / 100)
	if deaths ~= 0 then
		self.mg:displayMessage("events_display.attack_cancelled_retreat", "ATTACK_CANCELLED", self._owner:id(), nil, {
			troops = deaths,
		})
	end
	if self.removeTroops == false and self.sourceTile == nil then
		-- startTroops were added to the attack but never removed from the owner
		attack:setTroops(attack:troops() - (self.startTroops or 0))
	end
	local survivors = attack:troops() - deaths
	self._owner:addTroops(survivors)
	attack:delete()
	self.active = false
	-- Not all retreats are cancelled attacks
	if attack:retreated() then
		self.mg:stats():attackCancel(self._owner, self.target, survivors)
	end
end

function AttackExecution.tick(self: AttackExecution, _ticks: number)
	local attack = self.attack
	local troopCount = attack:troops()
	local targetIsPlayer = self.target:isPlayer()
	local targetPlayer = if targetIsPlayer then self.target else nil

	if attack:retreated() then
		if targetIsPlayer then
			self:_retreat(malusForRetreat)
		else
			self:_retreat()
		end
		self.active = false
		return
	end

	if attack:retreating() then
		return
	end

	if not attack:isActive() then
		self.active = false
		return
	end

	if targetPlayer and self._owner:isFriendly(targetPlayer) then
		-- An alliance was made after the attack started.
		self:_retreat()
		return
	end

	local borderSize = attack:borderSize() + self.random:nextInt(0, 5)
	-- Each tile consumes a fraction of the tick; conquer until it is spent.
	local tickBudget = 1
	local map = self.map
	local mg = self.mg
	local config = mg:config()
	local nbuf = self.nbuf

	while tickBudget > 0 do
		if troopCount < 1 then
			attack:delete()
			self.active = false
			return
		end

		if self.toConquer:size() == 0 then
			self:_refreshToConquer()
			self:_retreat()
			return
		end

		local tileToConquer = self.toConquer:dequeue()
		attack:removeBorderTile(tileToConquer)

		local onBorder = false
		local numNeighbors = map:neighbors4(tileToConquer, nbuf)
		for i = 1, numNeighbors do
			if map:ownerID(nbuf[i]) == self.ownerSmallID then
				onBorder = true
				break
			end
		end
		if map:ownerID(tileToConquer) == self.targetSmallID and onBorder then
			if map:isLand(tileToConquer) and not map:isImpassable(tileToConquer) then
				self:_addNeighbors(tileToConquer)
				local result = config:attackLogic(self:_attackLogicInput(troopCount, tileToConquer, borderSize))
				tickBudget -= result.tickFraction
				troopCount -= result.attackerTroopLoss
				attack:setTroops(troopCount)
				if targetPlayer then
					targetPlayer:removeTroops(result.defenderTroopLoss)
				end
				self._owner:conquer(tileToConquer)
				self:_handleDeadDefender()
			end
		end
	end
end

function AttackExecution._attackLogicInput(self: AttackExecution, attackTroops: number, tile: number, borderSize: number): any
	local mg = self.mg
	local defender = if self.target:isPlayer() then self.target else nil
	local defenderHasDefensePost = defender ~= nil
		and mg:hasUnitNearby(tile, mg:config():defensePostRange(), UnitType.DefensePost, defender:id())
	-- Conquest's Sabotage (ARSENAL_V2): a dark post gives no bonus. Only
	-- looked at while some building is dark, so OpenFront's path is unchanged.
	if defenderHasDefensePost and (mg.darkCount or 0) > 0 then
		defenderHasDefensePost = mg:anyUnitNearby(tile, mg:config():defensePostRange(), { UnitType.DefensePost }, function(unit: any): boolean
			return not unit:isDark()
		end, defender:id())
	end
	-- Conquest's Field Works (ARSENAL_V2): a defence post's effect within
	-- 15 tiles; only looked at while some stand.
	if defender ~= nil and not defenderHasDefensePost and (mg.fieldWorksCount or 0) > 0 then
		defenderHasDefensePost = mg:hasUnitNearby(tile, FIELD_WORKS_RADIUS, UnitType.FieldWorks, defender:id())
	end
	return {
		terrain = self.map:terrainType(tile),
		attackTroops = attackTroops,
		attacker = { type = self._owner:type(), numTiles = self._owner:numTilesOwned() },
		defender = if defender == nil
			then nil
			else {
				type = defender:type(),
				numTiles = defender:numTilesOwned(),
				troops = defender:troops(),
				isTraitor = defender:isTraitor(),
				isDisconnectedTeammate = defender:isDisconnected() and self._owner:isOnSameTeam(defender),
			},
		defenderHasDefensePost = defenderHasDefensePost,
		falloutRatio = if mg:hasFallout(tile) then mg:numTilesWithFallout() / mg:numLandTiles() else nil,
		borderSize = borderSize,
	}
end

function AttackExecution._rejectIncomingAllianceRequests(self: AttackExecution, target: any)
	for _, ar in self._owner:incomingAllianceRequests() do
		if ar:requestor() == target then
			ar:reject()
			return
		end
	end
end

-- The map's buffers are read directly here: this runs for every tile an
-- attack touches, and getter calls per probe were a large share of the tick.
function AttackExecution._addNeighbors(self: AttackExecution, tile: number)
	local attack = self.attack
	local map = self.map
	local terrain, state, w = map.terrain, map.state, map.width_
	local lastRow = (map.height_ - 1) * w
	local ownerID, targetID = self.ownerSmallID, self.targetSmallID
	local tickNow = self.mg:ticks()
	local nbuf = self.nbuf
	local numNeighbors = map:neighbors4(tile, nbuf)
	for i = 1, numNeighbors do
		local neighbor = nbuf[i]
		local bits = buffer.readu8(terrain, neighbor)
		local magnitude = bit32.band(bits, MAGNITUDE_MASK)
		-- Passable land the target owns.
		if bit32.band(bits, IS_LAND) ~= 0 and magnitude ~= IMPASSABLE_MAGNITUDE and bit32.band(buffer.readu16(state, neighbor * 2), PLAYER_ID_MASK) == targetID then
			attack:addBorderTile(neighbor)
			local numOwnedByMe = 0
			if neighbor >= w and bit32.band(buffer.readu16(state, (neighbor - w) * 2), PLAYER_ID_MASK) == ownerID then
				numOwnedByMe += 1
			end
			if neighbor < lastRow and bit32.band(buffer.readu16(state, (neighbor + w) * 2), PLAYER_ID_MASK) == ownerID then
				numOwnedByMe += 1
			end
			local x = neighbor % w
			if x ~= 0 and bit32.band(buffer.readu16(state, (neighbor - 1) * 2), PLAYER_ID_MASK) == ownerID then
				numOwnedByMe += 1
			end
			if x ~= w - 1 and bit32.band(buffer.readu16(state, (neighbor + 1) * 2), PLAYER_ID_MASK) == ownerID then
				numOwnedByMe += 1
			end
			-- terrainType: plains under 10, highland under 20, else mountain.
			local mag = if magnitude < 10 then 1 elseif magnitude < 20 then 1.5 else 2
			local priority = (self.random:nextInt(0, 7) + 10) * (1 - numOwnedByMe * 0.5 + mag / 2) + tickNow
			self.toConquer:enqueue(neighbor, priority)
		end
	end
end

-- Defender under 100 tiles: annex the rest of it.
function AttackExecution._handleDeadDefender(self: AttackExecution)
	local target = self.target
	if not (target:isPlayer() and target:numTilesOwned() < 100) then
		return
	end
	local mg = self.mg
	local owner = self._owner
	mg:conquerPlayer(owner, target)

	for _ = 1, 100 do
		local progressed = false
		target:tiles():forEach(function(tile: number)
			local borders = false
			mg:forEachNeighbor(tile, function(t: number)
				if not borders and mg:owner(t) == owner then
					borders = true
				end
			end)
			if borders then
				owner:conquer(tile)
				progressed = true
			else
				local captured = false
				mg:forEachNeighbor(tile, function(neighbor: number)
					if captured then
						return
					end
					local no = mg:owner(neighbor)
					if no:isPlayer() and no ~= target and not no:isFriendly(target) then
						mg:player(no:id()):conquer(tile)
						captured = true
					end
				end)
				if captured then
					progressed = true
				end
			end
		end)
		if not progressed then
			break
		end
	end
end

function AttackExecution.owner(self: AttackExecution): any
	return self._owner
end

function AttackExecution.isActive(self: AttackExecution): boolean
	return self.active
end

return AttackExecution
