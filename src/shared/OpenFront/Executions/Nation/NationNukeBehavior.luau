--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/NationNukeBehavior.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- When, at whom and where a nation with a silo drops atom and hydrogen
-- bombs. It picks a target (retaliation first, then teammates' fights, the
-- crown, a strike target, dense builders, allies' targets, hated players,
-- runaway leaders, the strongest team), then scores candidate tiles by the
-- structures a blast would hit. Each launch makes the next bomb of its type
-- feel pricier, so the nation saves up for a MIRV. Hard and Impossible
-- follow a "strike" with a land attack the moment the bomb lands, and
-- Impossible overwhelms SAMs with timed atom-bomb salvos.
--
-- OpenFront's snapshot/restore (for its replay checkpoints) is not ported.

local Emoji = require(script.Parent.Parent.Parent.Data.Emoji)
local ExecUtil = require(script.Parent.Parent.Util)
local GameMap = require(script.Parent.Parent.Parent.GameMap)
local GameTypes = require(script.Parent.Parent.Parent.GameTypes)
local HumanProtection = require(script.Parent.Parent.Parent.HumanProtection)
local NationMIRVBehavior = require(script.Parent.NationMIRVBehavior)
local NationUtils = require(script.Parent.NationUtils)
local Parabola = require(script.Parent.Parent.Parent.Pathfinding.Parabola)
local Util = require(script.Parent.Parent.Parent.Util)

local Difficulty = GameTypes.Difficulty
local GameMode = GameTypes.GameMode
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

-- GameTypes.ts Relation
local Relation = { Hostile = 0, Distrustful = 1, Neutral = 2, Friendly = 3 }

-- Cap on silo levels reachable via maybeDestroyEnemySam's upgrade fallback.
local MAX_NATION_SILO_UPGRADE_LEVEL = 5
-- Level-weighted structure density above which the richest Impossible nation pre-emptively nukes a player.
local HIGH_DENSITY_NUKE_THRESHOLD = 1 / 75
local MIN_LEVEL_SUM_FOR_HIGH_DENSITY_NUKE = 5
-- Share of the non-fallout land above which every FFA nation nukes the crown.
local CROWN_NEAR_WIN_SHARE = 0.5
-- Minimum share of a blast that must hit enemy land (not water, fallout or unowned land).
local MIN_BLAST_COVERAGE = { [UnitType.AtomBomb] = 0.25, [UnitType.HydrogenBomb] = 0.4 }
-- Tile score bonus for a blast that hits nothing but enemy land.
local FULL_BLAST_COVERAGE_VALUE = 50000
-- A strike target has at least this share of our troops.
local STRIKE_MIN_TROOP_RATIO = 0.5
-- Hard and Impossible strike only if the follow-up attack can send this share of the target's troops.
local STRIKE_MIN_STACK_RATIO = 0.5
-- Tiles kept between a strike's blast and our land, so the front survives for the follow-up.
local STRIKE_BORDER_MARGIN = 10
-- Ticks a strike waits for its bomb to spawn before it's dropped.
local STRIKE_SPAWN_TICKS = 10
-- Hard and Impossible: ticks after a launch until the perceived price is back to the real one.
local NUKE_PRICE_MEMORY_TICKS = 3000

type Strike = { target: any, tile: number, tick: number, nuke: any? }

local NationNukeBehavior = {}
NationNukeBehavior.__index = NationNukeBehavior

export type NationNukeBehavior = typeof(setmetatable(
	{} :: {
		random: any,
		game: any,
		player: any,
		attackBehavior: any,
		emojiBehavior: any,
		recentlySentNukes: { { tick: number, tile: number, nukeType: string } },
		atomBombsLaunched: number,
		atomBombPerceivedCost: number,
		atomBombLastLaunch: number?,
		hydrogenBombsLaunched: number,
		hydrogenBombPerceivedCost: number,
		hydrogenBombLastLaunch: number?,
		strikes: { Strike },
	},
	NationNukeBehavior
))

local function structureLevels(player: any): number
	local levels = 0
	for _, s in player:units(GameTypes.Structures) do
		levels += s:level()
	end
	return levels
end

local function isHardOrUp(d: string): boolean
	return d == Difficulty.Hard or d == Difficulty.Impossible
end

function NationNukeBehavior.new(random: any, game: any, player: any, attackBehavior: any, emojiBehavior: any): NationNukeBehavior
	local self = setmetatable({
		random = random,
		game = game,
		player = player,
		attackBehavior = attackBehavior,
		emojiBehavior = emojiBehavior,
		recentlySentNukes = {},
		atomBombsLaunched = 0,
		atomBombPerceivedCost = 0,
		atomBombLastLaunch = nil,
		hydrogenBombsLaunched = 0,
		hydrogenBombPerceivedCost = 0,
		hydrogenBombLastLaunch = nil,
		strikes = {},
	}, NationNukeBehavior)
	self.atomBombPerceivedCost = self:_cost(UnitType.AtomBomb)
	self.hydrogenBombPerceivedCost = self:_cost(UnitType.HydrogenBomb)
	return self
end

function NationNukeBehavior._difficulty(self: NationNukeBehavior): string
	return self.game:config():gameConfig().difficulty
end

function NationNukeBehavior._cost(self: NationNukeBehavior, unitType: string): number
	return self.game:unitInfo(unitType).cost(self.game, self.player)
end

function NationNukeBehavior.maybeSendNuke(self: NationNukeBehavior)
	local game, player = self.game, self.player
	local silos = player:units(UnitType.MissileSilo)
	local config = game:config()
	if
		#silos == 0
		or config:isUnitDisabled(UnitType.MissileSilo)
		or (config:isUnitDisabled(UnitType.AtomBomb) and config:isUnitDisabled(UnitType.HydrogenBomb))
	then
		return
	end

	local nukeTarget, strike = self:_chooseNukeTarget()
	if nukeTarget == nil then
		return
	end
	if
		nukeTarget:type() == PlayerType.Bot -- don't nuke tribes
		or player:isOnSameTeam(nukeTarget)
		or self.attackBehavior:shouldAttack(nukeTarget) == false
		or HumanProtection.nukeOffLimits(game, player, nukeTarget) -- Conquest: RoWorld's grace and limit
	then
		return
	end

	-- While saving up for a MIRV, Hard and Impossible only nuke back at players hitting them, with atom bombs.
	local saving = self:_isSavingForMirv()
	if saving and not self:_isHittingUs(nukeTarget) then
		return
	end

	local nukeTypes = self:_nukeTypesToTry(saving)
	if #nukeTypes == 0 then
		return
	end

	local structures = nukeTarget:units(GameTypes.Structures)
	local difficulty = self:_difficulty()
	-- More random tiles on Impossible, to find a spot that outranges SAMs.
	local numRandomTiles = if difficulty == Difficulty.Impossible then 30 else 10
	local randomTiles = NationUtils.randTerritoryTileArray(self.random, game, nukeTarget, numRandomTiles)
	-- new Set(randomTiles.concat(structure tiles)): insertion order, no repeats
	local candidates, seen = {}, {}
	local function addCandidate(t: number)
		if not seen[t] then
			seen[t] = true
			table.insert(candidates, t)
		end
	end
	for _, t in randomTiles do
		addCandidate(t)
	end
	for _, u in structures do
		addCandidate(u:tile())
	end
	self:_removeOldNukeEvents()

	for _, nukeType in nukeTypes do
		local tile = self:_findBestNukeTile(nukeType, nukeTarget, candidates, silos, structures, strike)
		if tile ~= nil then
			self:_sendNuke(tile, nukeType, nukeTarget)
			if strike and self:_followsUpStrikes() then
				table.insert(self.strikes, { target = nukeTarget, tile = tile, tick = game:ticks(), nuke = nil })
			end
			return
		end
	end
	if difficulty == Difficulty.Impossible and not saving then
		self:_maybeDestroyEnemySam(nukeTarget)
	end
end

-- Hydrogen bomb first; on Hard and Impossible, also an atom bomb if no spot is worth a hydrogen bomb.
function NationNukeBehavior._nukeTypesToTry(self: NationNukeBehavior, atomOnly: boolean): { string }
	local config = self.game:config()
	local difficulty = self:_difficulty()
	local gold = self.player:gold()
	local types = {}
	if
		not atomOnly
		and not config:isUnitDisabled(UnitType.HydrogenBomb)
		and gold >= self:_getPerceivedNukeCost(UnitType.HydrogenBomb)
	then
		table.insert(types, UnitType.HydrogenBomb)
	end
	if
		(#types == 0 or isHardOrUp(difficulty))
		and not config:isUnitDisabled(UnitType.AtomBomb)
		and gold >= self:_getPerceivedNukeCost(UnitType.AtomBomb)
	then
		table.insert(types, UnitType.AtomBomb)
	end
	return types
end

function NationNukeBehavior._findBestNukeTile(
	self: NationNukeBehavior,
	nukeType: string,
	nukeTarget: any,
	candidates: { number },
	silos: { any },
	structures: { any },
	strike: boolean
): number?
	local game, player = self.game, self.player
	local difficulty = self:_difficulty()
	local range = game:config():nukeMagnitudes(nukeType).outer
	local scored: { { tile: number, score: number } } = {}

	for _, tile in candidates do
		-- Cheap pre-filter; blastHitsFriendlyLand checks the whole blast of the winner.
		-- The half-radius ring catches unwanted territory inside the outer radius.
		local valid = true
		for _, radius in { range, math.floor(range / 2) } do
			for _, t in Util.boundingBoxTiles(game, tile, radius) do
				if not self:_isValidNukeTile(t, nukeTarget) then
					valid = false
					break
				end
			end
			if not valid then
				break
			end
		end
		if not valid then
			continue
		end
		local spawnTile = player:canBuild(nukeType, tile)
		if spawnTile == false then
			continue
		end

		-- Above Easy, skip spots already being nuked or where the blast would be mostly wasted.
		local coverage = 0
		if difficulty ~= Difficulty.Easy then
			if self:_isNukeAlreadyLandingNear(tile, nukeType) then
				continue
			end
			coverage = self:_enemyLandBlastCoverage(tile, nukeType)
			if coverage < MIN_BLAST_COVERAGE[nukeType] then
				continue
			end
		end

		-- On Hard and Impossible, avoid trajectories enemy SAMs can intercept.
		if isHardOrUp(difficulty) and self:_isTrajectoryInterceptableBySam(spawnTile :: number, tile) then
			continue
		end

		local value = self:_nukeTileScore(tile, silos, structures, nukeType)
		-- Impossible only nukes spots with structure value, unless it's after the troops.
		local rejected = if difficulty == Difficulty.Impossible and not strike then value <= 0 else value < 0
		if rejected then
			continue
		end
		table.insert(scored, { tile = tile, score = value + coverage * FULL_BLAST_COVERAGE_VALUE })
	end
	-- Stable sort: on ties the earlier candidate wins.
	scored = Util.stableSort(scored, function(a, b)
		return a.score > b.score
	end)
	local margin = if strike then STRIKE_BORDER_MARGIN else 0
	for _, entry in scored do
		if not self:_blastHitsFriendlyLand(entry.tile, nukeType, margin) then
			return entry.tile
		end
	end
	return nil
end

-- Who to nuke, and whether it's a strike: a nuke that softens a player up for our attack.
function NationNukeBehavior._chooseNukeTarget(self: NationNukeBehavior): (any?, boolean)
	local target = self:findBestNukeTarget()
	if target == nil then
		return nil, false
	end
	local difficulty = self:_difficulty()
	local strike
	if difficulty == Difficulty.Easy then
		strike = false
	elseif difficulty == Difficulty.Medium then
		strike = self:_troopsAttacking(target) > 0
	else
		strike = self:_canStrike(target)
	end
	return target, strike
end

local function byTilesDesc(list: { any }): { any }
	return Util.stableSort(table.clone(list), function(a, b)
		return a:numTilesOwned() > b:numTilesOwned()
	end)
end

function NationNukeBehavior.findBestNukeTarget(self: NationNukeBehavior): any?
	local game, player = self.game, self.player
	local gc = game:config():gameConfig()
	local diff, gameMode = gc.difficulty, gc.gameMode

	-- On Hard and Impossible with only 2 players left, target the other one.
	if isHardOrUp(diff) and #game:players() == 2 then
		for _, p in game:players() do
			if p ~= player then
				return p
			end
		end
	end

	-- Retaliate against incoming attacks (most important!).
	local incomingAttackPlayer = self.attackBehavior:findIncomingAttackPlayer()
	if incomingAttackPlayer then
		return incomingAttackPlayer
	end
	local incomingNukePlayer = self:_findIncomingNukePlayer()
	if incomingNukePlayer then
		return incomingNukePlayer
	end

	-- In Teams, back up teammates in their fights before starting our own.
	local teammateFightTarget = self:_findTeammateFightTarget()
	if teammateFightTarget then
		return teammateFightTarget
	end

	-- Impossible FFA: nuke the crown if it holds more than half the map.
	if diff == Difficulty.Impossible and gameMode == GameMode.FFA then
		local numTilesWithoutFallout = game:numLandTiles() - game:numTilesWithFallout()
		if numTilesWithoutFallout > 0 then
			local crown = byTilesDesc(game:players())[1]
			if crown and crown ~= player and not player:isFriendly(crown) then
				if crown:numTilesOwned() / numTilesWithoutFallout > CROWN_NEAR_WIN_SHARE then
					return crown
				end
			end
		end
	end

	-- Soften up a neighbour about as strong as us before attacking it.
	local strikeTarget = self:_findStrikeTarget()
	if strikeTarget ~= nil then
		return strikeTarget
	end

	-- On Impossible, the richest nation hunts very dense builders (only the
	-- richest, so every Impossible nation doesn't pile onto one player).
	if diff == Difficulty.Impossible and self:_isRichestNation() and self.random:chance(2) then
		local denseTarget = self:_findHighDensityTarget()
		if denseTarget ~= nil then
			return denseTarget
		end
	end

	-- Assist allies: their targets (as in assistAllies, without the emojis).
	for _, ally in player:allies() do
		if #ally:targets() == 0 then
			continue
		end
		if player:relation(ally) < Relation.Friendly then
			continue
		end
		for _, target in ally:targets() do
			if target == player or player:isFriendly(target) then
				continue
			end
			return target
		end
	end

	-- The most hated player, ignoring much weaker ones (no nukes needed for them).
	local config = game:config()
	local myMaxTroops = config:maxTroops(player)
	for _, relation in player:allRelationsSorted() do
		if relation.relation ~= Relation.Hostile then
			continue
		end
		local other = relation.player
		if player:isFriendly(other) then
			continue
		end
		if myMaxTroops >= config:maxTroops(other) * 2 then
			continue
		end
		return other
	end

	-- In FFAs, the crown if it's far enough ahead.
	local crownTarget = self:_findFFACrownTarget()
	if crownTarget then
		return crownTarget
	end

	-- In Teams, the strongest team.
	return self:_findStrongestTeamTarget()
end

-- A player not much weaker than us: on Medium one we're attacking, on Hard
-- and Impossible the strongest neighbour we can follow up on.
function NationNukeBehavior._findStrikeTarget(self: NationNukeBehavior): any?
	local player = self.player
	local myTroops = player:troops()
	local function isCandidate(other: any): boolean
		return other:isPlayer()
			and other:type() ~= PlayerType.Bot
			and not player:isFriendly(other)
			and other:troops() >= myTroops * STRIKE_MIN_TROOP_RATIO
	end
	local difficulty = self:_difficulty()
	if difficulty == Difficulty.Easy then
		return nil
	elseif difficulty == Difficulty.Medium then
		for _, attack in player:outgoingAttacks() do
			local target = attack:target()
			if isCandidate(target) then
				return target
			end
		end
		return nil
	end
	local best = nil
	for _, other in player:nearby() do
		if not isCandidate(other) then
			continue
		end
		if best ~= nil and other:troops() <= best:troops() then
			continue
		end
		if self:_canStrike(other) then
			best = other
		end
	end
	return best
end

-- Whether the attack right after our nuke could send enough troops into target by land.
function NationNukeBehavior._canStrike(self: NationNukeBehavior, target: any): boolean
	return target:type() ~= PlayerType.Bot
		and not self.player:isFriendly(target)
		and self.attackBehavior:strikeTroops(target) >= target:troops() * STRIKE_MIN_STACK_RATIO
		and self.player:sharesBorderWith(target)
end

function NationNukeBehavior._followsUpStrikes(self: NationNukeBehavior): boolean
	return isHardOrUp(self:_difficulty())
end

-- Called every tick: attacks a strike's target the moment its bomb, or its MIRV's last warhead, lands.
function NationNukeBehavior.followUpStrikes(self: NationNukeBehavior)
	local player = self.player
	if self:_followsUpStrikes() and player:unitCount(UnitType.MIRV) > 0 then
		self:_trackMirvStrikes()
	end
	if #self.strikes == 0 then
		return
	end
	local pending = {}
	for _, strike in self.strikes do
		if strike.nuke == nil then
			strike.nuke = self:_findStrikeNuke(strike.tile)
		end
		local nuke = strike.nuke
		if nuke == nil then
			if self.game:ticks() - strike.tick <= STRIKE_SPAWN_TICKS then
				table.insert(pending, strike)
			end
			continue
		end
		if nuke:isActive() then
			table.insert(pending, strike)
			continue
		end
		if nuke:type() == UnitType.MIRV then
			-- A MIRV deletes itself when it splits into warheads.
			if player:unitCount(UnitType.MIRVWarhead) > 0 then
				table.insert(pending, strike)
				continue
			end
		elseif not nuke:reachedTarget() then
			-- Intercepted bombs leave the target's troops alone.
			continue
		end
		if strike.target:isAlive() then
			self.attackBehavior:strike(strike.target)
		end
	end
	self.strikes = pending
end

function NationNukeBehavior._isStrikeNuke(self: NationNukeBehavior, nuke: any): boolean
	for _, s in self.strikes do
		if s.nuke == nuke then
			return true
		end
	end
	return false
end

-- Our MIRVs at bordering players are strikes too: a MIRV leaves next to no troops to defend with.
function NationNukeBehavior._trackMirvStrikes(self: NationNukeBehavior)
	local player = self.player
	for _, mirv in player:units(UnitType.MIRV) do
		if self:_isStrikeNuke(mirv) then
			continue
		end
		local target = mirv:targetPlayer()
		local tile = mirv:targetTile()
		if target == nil or not target:isPlayer() or tile == nil then
			continue
		end
		if player:isFriendly(target) or not player:sharesBorderWith(target) then
			continue
		end
		table.insert(self.strikes, { target = target, tile = tile, tick = self.game:ticks(), nuke = mirv })
	end
end

function NationNukeBehavior._findStrikeNuke(self: NationNukeBehavior, tile: number): any?
	for _, nuke in self.player:units({ UnitType.AtomBomb, UnitType.HydrogenBomb }) do
		if nuke:targetTile() == tile and not self:_isStrikeNuke(nuke) then
			return nuke
		end
	end
	return nil
end

function NationNukeBehavior._troopsAttacking(self: NationNukeBehavior, target: any): number
	local troops = 0
	for _, attack in self.player:outgoingAttacks() do
		if attack:target() == target then
			troops += attack:troops()
		end
	end
	return troops
end

function NationNukeBehavior._findIncomingNukePlayer(self: NationNukeBehavior): any?
	local game, player = self.game, self.player
	-- Conquest: nations also answer the Arsenal's Mega Nuke and Scattershot.
	for _, nuke in game:units(UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MegaNuke, UnitType.Scattershot) do
		local sender = nuke:owner()
		if player:isFriendly(sender) then
			continue
		end
		local targetTile = nuke:targetTile()
		if targetTile ~= nil and game:owner(targetTile) == player then
			return sender
		end
	end
	return nil
end

function NationNukeBehavior._isRichestNation(self: NationNukeBehavior): boolean
	local myGold = self.player:gold()
	for _, other in self.game:players() do
		if other ~= self.player and other:type() == PlayerType.Nation and other:gold() > myGold then
			return false
		end
	end
	return true
end

function NationNukeBehavior._findHighDensityTarget(self: NationNukeBehavior): any?
	local bestTarget = nil
	local bestDensity = HIGH_DENSITY_NUKE_THRESHOLD
	for _, other in self.game:players() do
		if other == self.player or other:type() == PlayerType.Bot or self.player:isFriendly(other) then
			continue
		end
		local tilesOwned = other:numTilesOwned()
		if tilesOwned == 0 then
			continue
		end
		local levelSum = structureLevels(other)
		-- Skip players with too few structures regardless of density.
		if levelSum < MIN_LEVEL_SUM_FOR_HIGH_DENSITY_NUKE then
			continue
		end
		local density = levelSum / tilesOwned
		if density > bestDensity then
			bestDensity = density
			bestTarget = other
		end
	end
	return bestTarget
end

function NationNukeBehavior._findFFACrownTarget(self: NationNukeBehavior): any?
	local game, player = self.game, self.player
	local gc = game:config():gameConfig()
	if gc.gameMode ~= GameMode.FFA or #game:players() <= 1 then
		return nil
	end
	local firstPlace = byTilesDesc(game:players())[1]
	-- Not ourselves or allies.
	if firstPlace == player or player:isFriendly(firstPlace) then
		return nil
	end
	local numTilesWithoutFallout = game:numLandTiles() - game:numTilesWithFallout()
	if numTilesWithoutFallout <= 0 then
		return nil
	end
	local firstPlaceShare = firstPlace:numTilesOwned() / numTilesWithoutFallout
	if firstPlaceShare > CROWN_NEAR_WIN_SHARE then
		return firstPlace
	end

	-- Below that, only a runaway leader far enough ahead of us. Its
	-- neighbours react first, everyone else once the gap is twice as big.
	if NationUtils.findRunawayLeader(game) ~= firstPlace then
		return nil
	end
	local threshold
	if gc.difficulty == Difficulty.Easy then
		return nil -- never notices a runaway leader
	elseif gc.difficulty == Difficulty.Medium then
		threshold = 0.3
	elseif gc.difficulty == Difficulty.Hard then
		threshold = 0.2
	else
		threshold = 0.1
	end
	if not player:sharesBorderWith(firstPlace) then
		threshold *= 2
	end
	local myShare = player:numTilesOwned() / numTilesWithoutFallout
	if firstPlaceShare - myShare > threshold then
		return firstPlace
	end
	return nil
end

-- Medium and up: the enemy attacking our teammates hardest, else the one they attack hardest.
function NationNukeBehavior._findTeammateFightTarget(self: NationNukeBehavior): any?
	local game, player = self.game, self.player
	local gc = game:config():gameConfig()
	if gc.gameMode ~= GameMode.Team or gc.difficulty == Difficulty.Easy then
		return nil
	end
	local teammates = {}
	for _, p in game:players() do
		if p ~= player and player:isOnSameTeam(p) then
			table.insert(teammates, p)
		end
	end
	local function isEnemy(p: any): boolean
		return p:isPlayer() and p:type() ~= PlayerType.Bot and not player:isFriendly(p)
	end
	local best, bestTroops = nil, 0
	for _, mate in teammates do
		for _, attack in mate:incomingAttacks() do
			local attacker = attack:attacker()
			if isEnemy(attacker) and attack:troops() > bestTroops then
				best, bestTroops = attacker, attack:troops()
			end
		end
	end
	if best ~= nil then
		return best
	end
	for _, mate in teammates do
		for _, attack in mate:outgoingAttacks() do
			local target = attack:target()
			if isEnemy(target) and attack:troops() > bestTroops then
				best, bestTroops = target, attack:troops()
			end
		end
	end
	return best
end

function NationNukeBehavior._findStrongestTeamTarget(self: NationNukeBehavior): any?
	local game, player = self.game, self.player
	local config = game:config()
	if config:gameConfig().gameMode ~= GameMode.Team or #game:players() <= 1 then
		return nil
	end
	-- Map<team, tiles> and Map<team, players> in first-seen order.
	local teamOrder, teamTiles, teamPlayers = {}, {}, {}
	for _, p in game:players() do
		local team = p:team()
		if team == nil then
			continue
		end
		if teamTiles[team] == nil then
			table.insert(teamOrder, team)
			teamTiles[team] = 0
			teamPlayers[team] = {}
		end
		teamTiles[team] += p:numTilesOwned()
		table.insert(teamPlayers[team], p)
	end
	local sortedTeams = Util.stableSort(teamOrder, function(a, b)
		return teamTiles[a] > teamTiles[b]
	end)
	if #sortedTeams == 0 then
		return nil
	end
	local strongestTeam = sortedTeams[1]
	if strongestTeam == player:team() then
		if #sortedTeams > 1 then
			strongestTeam = sortedTeams[2]
		else
			return nil
		end
	end

	local validTargets = {}
	for _, p in teamPlayers[strongestTeam] do
		if not player:isFriendly(p) then
			table.insert(validTargets, p)
		end
	end
	if #validTargets == 0 then
		return nil
	end

	-- Hard and Impossible: one of the three players with the most structure levels.
	if isHardOrUp(config:gameConfig().difficulty) then
		local withLevels = {}
		for _, p in validTargets do
			local levels = structureLevels(p)
			if levels > 0 then
				table.insert(withLevels, { p = p, levels = levels })
			end
		end
		withLevels = Util.stableSort(withLevels, function(a, b)
			return a.levels > b.levels
		end)
		if #withLevels > 0 then
			local top3 = table.move(withLevels, 1, math.min(3, #withLevels), 1, {})
			return self.random:randElement(top3).p
		end
	end

	if self.random:chance(2) then
		-- Strongest player (reduce keeps prev only when strictly stronger).
		local best = validTargets[1]
		for i = 2, #validTargets do
			local current = validTargets[i]
			if not (config:maxTroops(best) > config:maxTroops(current)) then
				best = current
			end
		end
		return best
	end
	return self.random:randElement(validTargets)
end

-- Each launch makes the next nuke of its type feel pricier, to save up for a MIRV and pace launches.
function NationNukeBehavior._getPerceivedNukeCost(self: NationNukeBehavior, nukeType: string): number
	if self:_paysRealNukePrice() then
		return self:_cost(nukeType)
	end
	-- Easy and Medium keep the price up for good, so only while a MIRV is worth saving for.
	if not self:_forgetsNukePrices() and not NationMIRVBehavior.isMirvWorthSavingFor(self.game, self.player) then
		return self:_cost(nukeType)
	end
	return self:_inflatedNukeCost(nukeType)
end

function NationNukeBehavior._paysRealNukePrice(self: NationNukeBehavior): boolean
	local game, player = self.game, self.player
	local config = game:config()
	-- Only 2 players left: no point saving for a MIRV.
	if #game:players() == 2 then
		return true
	end
	if config:isUnitDisabled(UnitType.MIRV) then
		return true
	end
	-- Teams save up a limited amount, synced with NationStructureBehavior.
	if config:gameConfig().gameMode == GameMode.Team and player:gold() > self:_cost(UnitType.HydrogenBomb) then
		return true
	end
	-- Already enough gold for both a MIRV and a hydrogen bomb.
	if player:gold() > self:_mirvSaveUpTarget() then
		return true
	end
	-- Hard and Impossible go all-in under heavy attack: they're probably about to be destroyed.
	return isHardOrUp(self:_difficulty()) and self:_isUnderHeavyAttack()
end

-- Hard and Impossible in FFA: the perceived price falls back to the real one within minutes of the last launch.
function NationNukeBehavior._forgetsNukePrices(self: NationNukeBehavior): boolean
	local gc = self.game:config():gameConfig()
	return isHardOrUp(gc.difficulty) and gc.gameMode ~= GameMode.Team
end

-- BigInt arithmetic: gold stays integral and division truncates (all
-- operands here are positive, so floor).
function NationNukeBehavior._inflatedNukeCost(self: NationNukeBehavior, nukeType: string): number
	local real = self:_cost(nukeType)
	local perceived, lastLaunch
	if nukeType == UnitType.AtomBomb then
		perceived, lastLaunch = self.atomBombPerceivedCost, self.atomBombLastLaunch
	else
		perceived, lastLaunch = self.hydrogenBombPerceivedCost, self.hydrogenBombLastLaunch
	end
	if perceived <= real then
		return real
	end
	if not self:_forgetsNukePrices() then
		return perceived
	end
	local left = if lastLaunch == nil then 0 else NUKE_PRICE_MEMORY_TICKS - (self.game:ticks() - lastLaunch)
	if left <= 0 then
		return real
	end
	return real + (perceived - real) * left // NUKE_PRICE_MEMORY_TICKS
end

-- Hard and Impossible in FFA: whether they're holding gold back for a MIRV their income will soon reach.
function NationNukeBehavior._isSavingForMirv(self: NationNukeBehavior): boolean
	return self:_forgetsNukePrices()
		and not self:_paysRealNukePrice()
		and NationMIRVBehavior.isMirvWorthSavingFor(self.game, self.player)
		and NationUtils.isSaveUpWithinReach(self.game, self.player, self:_mirvSaveUpTarget())
end

function NationNukeBehavior._mirvSaveUpTarget(self: NationNukeBehavior): number
	return self:_cost(UnitType.MIRV) + self:_cost(UnitType.HydrogenBomb)
end

-- Whether the player is attacking us or has a bomb flying at our land.
function NationNukeBehavior._isHittingUs(self: NationNukeBehavior, other: any): boolean
	local game, player = self.game, self.player
	for _, a in player:incomingAttacks() do
		if a:attacker() == other then
			return true
		end
	end
	for _, nuke in other:units({ UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRV, UnitType.MIRVWarhead, UnitType.MegaNuke, UnitType.Scattershot }) do
		local tile = nuke:targetTile()
		if tile ~= nil and game:owner(tile) == player then
			return true
		end
	end
	return false
end

function NationNukeBehavior._isUnderHeavyAttack(self: NationNukeBehavior): boolean
	local totalIncomingTroops = 0
	for _, attack in self.player:incomingAttacks() do
		totalIncomingTroops += attack:troops()
	end
	return totalIncomingTroops >= self.player:troops()
end

function NationNukeBehavior._removeOldNukeEvents(self: NationNukeBehavior)
	local maxAge = 600 -- 1 minute
	local tick = self.game:ticks()
	while #self.recentlySentNukes > 0 and self.recentlySentNukes[1].tick + maxAge < tick do
		table.remove(self.recentlySentNukes, 1)
	end
end

-- Whether our inner blast would overlap the inner blast of any player's nuke in flight.
function NationNukeBehavior._isNukeAlreadyLandingNear(self: NationNukeBehavior, tile: number, nukeType: string): boolean
	local game = self.game
	local config = game:config()
	local ourInnerRadius = config:nukeMagnitudes(nukeType).inner
	for _, nuke in game:units(UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRVWarhead, UnitType.MegaNuke, UnitType.Scattershot) do
		local targetTile = nuke:targetTile()
		if targetTile == nil then
			continue
		end
		local sumRadius = ourInnerRadius + config:nukeMagnitudes(nuke:type()).inner
		if game:euclideanDistSquared(tile, targetTile) <= sumRadius * sumRadius then
			return true
		end
	end
	return false
end

-- Grid-sampled share of the blast that hits enemy land. Inner-radius tiles
-- count double, as the outer ring is only partially destroyed.
function NationNukeBehavior._enemyLandBlastCoverage(self: NationNukeBehavior, center: number, nukeType: string): number
	local game, player = self.game, self.player
	local m = game:config():nukeMagnitudes(nukeType)
	local inner, outer = m.inner, m.outer
	local step = math.max(1, math.floor(outer / 10))
	local cx, cy = game:x(center), game:y(center)
	local total, enemyLand = 0, 0
	for dy = -outer, outer, step do
		for dx = -outer, outer, step do
			local distSquared = dx * dx + dy * dy
			if distSquared > outer * outer then
				continue
			end
			local weight = if distSquared <= inner * inner then 2 else 1
			total += weight
			if not game:isValidCoord(cx + dx, cy + dy) then
				continue
			end
			-- Water, fallout and unowned land have no player owner.
			local owner = game:owner(game:ref(cx + dx, cy + dy))
			if owner:isPlayer() and not player:isFriendly(owner, true) then
				enemyLand += weight
			end
		end
	end
	return enemyLand / total
end

-- Whether any tile in the blast, widened by margin, belongs to us, a teammate or an ally (even AFK ones).
function NationNukeBehavior._blastHitsFriendlyLand(self: NationNukeBehavior, center: number, nukeType: string, margin: number?): boolean
	local game, player = self.game, self.player
	local friendlyIds = {}
	for _, p in game:players() do
		if player:isFriendly(p, true) then
			friendlyIds[p:smallID()] = true
		end
	end
	local outer = game:config():nukeMagnitudes(nukeType).outer + (margin or 0)
	local cx, cy = game:x(center), game:y(center)
	for dy = -outer, outer do
		for dx = -outer, outer do
			if dx * dx + dy * dy > outer * outer or not game:isValidCoord(cx + dx, cy + dy) then
				continue
			end
			if friendlyIds[game:ownerID(game:ref(cx + dx, cy + dy))] then
				return true
			end
		end
	end
	return false
end

local function nukeTrajectory(game: any, from: number, to: number): { number }
	local speed = game:config():nukeSpeed(UnitType.AtomBomb)
	-- Atom and hydrogen bombs use distance-based height; AI nukes always go "up".
	return Parabola.new(game, { increment = speed, distanceBasedHeight = true, directionUp = true }):findPath(from, to)
end

-- Mirrors NukeTrajectoryPreviewLayer.ts a bit: whether an enemy SAM covers
-- any targetable point of the flight (the mid-air stretch out of range of
-- both ends is skipped).
function NationNukeBehavior._isTrajectoryInterceptableBySam(
	self: NationNukeBehavior,
	spawnTile: number,
	targetTile: number,
	excludedSamIds: { [number]: boolean }?
): boolean
	local game, player = self.game, self.player
	local config = game:config()
	local trajectory = nukeTrajectory(game, spawnTile, targetTile)
	if #trajectory == 0 then
		return false
	end
	local targetRangeSquared = config:defaultNukeTargetableRange() ^ 2

	-- 0-based indices, as in the TS loop
	local untargetableStart, untargetableEnd = -1, -1
	for i = 0, #trajectory - 1 do
		local tile = trajectory[i + 1]
		if untargetableStart == -1 then
			if game:euclideanDistSquared(tile, spawnTile) > targetRangeSquared then
				if game:euclideanDistSquared(tile, targetTile) < targetRangeSquared then
					break -- spawn and target ranges overlap: no untargetable stretch
				else
					untargetableStart = i
				end
			end
		elseif game:euclideanDistSquared(tile, targetTile) < targetRangeSquared then
			untargetableEnd = i
			break
		end
	end

	local maxSamRange = config:maxSamRange()
	local i = 0
	while i < #trajectory do
		if untargetableStart ~= -1 and untargetableEnd ~= -1 and i == untargetableStart then
			i = untargetableEnd -- the TS sets i = end - 1, then the loop's i++
			continue
		end
		for _, sam in game:nearbyUnits(trajectory[i + 1], maxSamRange, UnitType.SAMLauncher) do
			local owner = sam.unit:owner()
			if owner == player or player:isFriendly(owner) then
				continue
			end
			-- Skip SAMs we're intentionally overwhelming.
			if excludedSamIds and excludedSamIds[sam.unit:id()] then
				continue
			end
			if sam.distSquared <= config:samRange(sam.unit:level()) ^ 2 then
				return true
			end
		end
		i += 1
	end
	return false
end

function NationNukeBehavior._isValidNukeTile(self: NationNukeBehavior, t: number, nukeTarget: any?): boolean
	local owner = self.game:owner(t)
	if owner == nukeTarget then
		return true
	end
	-- Hard and Impossible also allow unowned land (small islands) and other
	-- players unless they're teammates or allies (even AFK ones). Easy and
	-- Medium only nuke inside the target, away from the border.
	return isHardOrUp(self:_difficulty()) and (not owner:isPlayer() or not self.player:isFriendly(owner, true))
end

local STRUCTURE_NUKE_VALUE = {
	[UnitType.City] = 25000,
	[UnitType.DefensePost] = 5000,
	[UnitType.MissileSilo] = 50000,
	[UnitType.Port] = 15000,
	[UnitType.Factory] = 15000,
}

function NationNukeBehavior._nukeTileScore(self: NationNukeBehavior, tile: number, silos: { any }, targets: { any }, nukeType: string): number
	local game = self.game
	local config = game:config()
	local magnitude = config:nukeMagnitudes(nukeType)
	local dist = GameMap.euclDistFN(tile, magnitude.outer, false)
	local tileValue = 0
	for _, unit in targets do
		if dist(game, unit:tile()) then
			tileValue += (STRUCTURE_NUKE_VALUE[unit:type()] or 0) * unit:level()
		end
	end

	local difficulty = self:_difficulty()
	-- Easy ignores SAMs; Medium applies a simple local SAM penalty; Hard and
	-- Impossible rely on the trajectory checks in findBestNukeTile instead.
	if difficulty == Difficulty.Medium then
		local dist50 = GameMap.euclDistFN(tile, 50, false)
		for _, unit in targets do
			if unit:type() == UnitType.SAMLauncher and dist50(game, unit:tile()) then
				return -1
			end
		end
	end

	-- Impossible with a hydrogen bomb: value for SAMs it can outrange.
	if difficulty == Difficulty.Impossible and nukeType == UnitType.HydrogenBomb then
		local hydroOuter = config:nukeMagnitudes(UnitType.HydrogenBomb).outer
		for _, sam in game:nearbyUnits(tile, hydroOuter, UnitType.SAMLauncher) do
			local samLevel = sam.unit:level()
			if samLevel >= 5 then
				continue -- can't outrange level 5+ SAMs
			end
			local distToSam = math.sqrt(game:euclideanDistSquared(tile, sam.unit:tile()))
			if distToSam > config:samRange(samLevel) then
				tileValue += 100000 * samLevel
			end
		end
	end

	-- Prefer tiles closer to a silo, keeping at least 20% of the structure value.
	local siloTiles = {}
	for _, u in silos do
		table.insert(siloTiles, u:tile())
	end
	local result = ExecUtil.closestTwoTiles(game, siloTiles, { tile })
	if result == nil then
		error("Missing result")
	end
	local distancePenalty = math.sqrt(game:euclideanDistSquared(tile, result.x)) * 30
	tileValue = math.max(tileValue * 0.2, tileValue - distancePenalty)

	-- Don't target near recent targets.
	for _, recent in self.recentlySentNukes do
		local recentInnerRadius = config:nukeMagnitudes(recent.nukeType).inner
		if game:euclideanDistSquared(tile, recent.tile) <= recentInnerRadius * recentInnerRadius then
			tileValue -= 1000000
		end
	end
	return tileValue
end

function NationNukeBehavior._sendNuke(self: NationNukeBehavior, tile: number, nukeType: string, targetPlayer: any, waitTicks: number?)
	local tick = self.game:ticks()
	table.insert(self.recentlySentNukes, { tick = tick, tile = tile, nukeType = nukeType })
	local perceived = self:_inflatedNukeCost(nukeType)
	if nukeType == UnitType.AtomBomb then
		self.atomBombsLaunched += 1
		-- +50% each time, to save up for a MIRV (more than hydrogen, so atom bombs fade late game).
		self.atomBombPerceivedCost = perceived * 150 // 100
		self.atomBombLastLaunch = tick
	elseif nukeType == UnitType.HydrogenBomb then
		self.hydrogenBombsLaunched += 1
		self.hydrogenBombPerceivedCost = perceived * 125 // 100
		self.hydrogenBombLastLaunch = tick
	end
	local NukeExecution = require(script.Parent.Parent.NukeExecution) :: any
	self.game:addExecution(NukeExecution.new(nukeType, self.player, tile, nil, -1, waitTicks or 0))
	self.emojiBehavior:maybeSendEmoji(targetPlayer, Emoji.NUKE)
end

-- Impossible, when no spot is worth a nuke: overwhelm an enemy SAM with
-- atom bombs. A level N SAM intercepts N nukes before its cooldown, so it
-- takes N+1 bombs (summed over every SAM covering the spot).
function NationNukeBehavior._maybeDestroyEnemySam(self: NationNukeBehavior, nukeTarget: any)
	local game, player = self.game, self.player
	local config = game:config()
	if config:isUnitDisabled(UnitType.AtomBomb) then
		return
	end
	-- No new salvo while we have atom bombs in flight.
	if #player:units(UnitType.AtomBomb) > 0 then
		return
	end
	local atomCost = self:_cost(UnitType.AtomBomb)
	local enemySams = nukeTarget:units(UnitType.SAMLauncher)
	if #enemySams == 0 then
		return
	end
	local ourSilos = {}
	for _, silo in player:units(UnitType.MissileSilo) do
		if not silo:isUnderConstruction() then
			table.insert(ourSilos, silo)
		end
	end
	if #ourSilos == 0 then
		return
	end

	-- Easiest (lowest level) SAM first.
	local sortedSams = Util.stableSort(table.clone(enemySams), function(a: any, b: any)
		return a:level() < b:level()
	end)
	local needsMoreSilos = false
	-- The first failed plan, so we upgrade a silo that would have helped it.
	local failedTarget: { targetTile: number, coveringSamIds: { [number]: boolean }, totalBombs: number }? = nil

	for _, targetSam in sortedSams do
		local targetTile = targetSam:tile()
		-- Hitting an ally's land would break the alliance.
		if self:_blastHitsFriendlyLand(targetTile, UnitType.AtomBomb) then
			continue
		end

		-- Every enemy SAM covering the spot will try to intercept.
		local coveringSams = self:_findEnemySamsCoveringTile(targetTile)
		local coveringSamIds = {}
		local totalInterceptions = 0
		for _, sam in coveringSams do
			coveringSamIds[sam:id()] = true
			totalInterceptions += sam:level()
		end
		local bombsNeeded = totalInterceptions + 1

		-- NukeExecution always picks the closest ready silo by Manhattan
		-- distance (nukeSpawn), so the plan mirrors that order. Silos whose
		-- flights can be intercepted still fire first and waste their slots.
		local allAvailableSilos = {}
		for _, silo in ourSilos do
			local availableSlots = silo:level() - #silo:missileTimerQueue()
			if availableSlots <= 0 then
				continue
			end
			local interceptable = self:_isTrajectoryInterceptableBySam(silo:tile(), targetTile, coveringSamIds)
			local trajectory = nukeTrajectory(game, silo:tile(), targetTile)
			if #trajectory == 0 then
				continue
			end
			table.insert(allAvailableSilos, {
				silo = silo,
				slots = availableSlots,
				flightTicks = #trajectory,
				interceptable = interceptable,
			})
		end
		allAvailableSilos = Util.stableSort(allAvailableSilos, function(a, b)
			return game:manhattanDist(a.silo:tile(), targetTile) < game:manhattanDist(b.silo:tile(), targetTile)
		end)

		-- One entry per bomb, in NukeExecution's launch order.
		local launchSequence = {}
		for _, entry in allAvailableSilos do
			for _ = 1, entry.slots do
				table.insert(launchSequence, { flightTicks = entry.flightTicks, interceptable = entry.interceptable })
			end
		end

		-- Half the SAM cooldown as the max arrival spread, to be safe.
		local maxTotalArrivalSpread = math.floor(config:SAMCooldown() / 2)
		-- One extra bomb per 5, for SAMs built while ours are in flight.
		local totalBombs = bombsNeeded + math.floor(bombsNeeded / 5)

		-- Bombs whose flight no SAM other than the covering ones can stop
		-- (index is 0-based, as in the TS).
		local unblockedBombs = {}
		for i, b in launchSequence do
			if not b.interceptable then
				table.insert(unblockedBombs, { index = i - 1, flightTicks = b.flightTicks })
			end
		end
		if #unblockedBombs < totalBombs then
			failedTarget = failedTarget or { targetTile = targetTile, coveringSamIds = coveringSamIds, totalBombs = totalBombs }
			needsMoreSilos = true
			continue
		end

		-- The arrival window of maxTotalArrivalSpread that holds the most bombs.
		local sortedByFlight = Util.stableSort(table.clone(unblockedBombs), function(a, b)
			return a.flightTicks < b.flightTicks
		end)
		local bestWindowStart, bestWindowCount = 1, 0
		for start = 1, #sortedByFlight do
			local finish = start
			while
				finish <= #sortedByFlight
				and sortedByFlight[finish].flightTicks - sortedByFlight[start].flightTicks <= maxTotalArrivalSpread
			do
				finish += 1
			end
			if finish - start > bestWindowCount then
				bestWindowCount = finish - start
				bestWindowStart = start
			end
		end
		if bestWindowCount < totalBombs then
			failedTarget = failedTarget or { targetTile = targetTile, coveringSamIds = coveringSamIds, totalBombs = totalBombs }
			needsMoreSilos = true
			continue
		end

		-- From the window, the totalBombs earliest in launch order, to fire as few bombs as possible.
		local windowByIndex = Util.stableSort(
			table.move(sortedByFlight, bestWindowStart, bestWindowStart + bestWindowCount - 1, 1, {}),
			function(a, b)
				return a.index < b.index
			end
		)
		local selected = table.move(windowByIndex, 1, totalBombs, 1, {})
		local selectedSet = {}
		local selectedFlightMin = math.huge
		for _, b in selected do
			selectedSet[b.index] = true
			selectedFlightMin = math.min(selectedFlightMin, b.flightTicks)
		end
		local bombsToFire = selected[#selected].index + 1

		-- Wait times that spread the selected arrivals evenly from the earliest flight time.
		local staggerInterval = math.max(1, math.floor(maxTotalArrivalSpread / totalBombs))
		local selectedIdx = 0
		local waitTicksPerBomb = {}
		for i = 0, bombsToFire - 1 do
			if selectedSet[i] then
				local targetArrival = selectedFlightMin + selectedIdx * staggerInterval
				table.insert(waitTicksPerBomb, math.max(0, targetArrival - launchSequence[i + 1].flightTicks))
				selectedIdx += 1
			else
				-- A wasted bomb (interceptable or out of the window) launches at once.
				table.insert(waitTicksPerBomb, 0)
			end
		end

		-- Gold for every bomb fired, wasted ones included.
		if player:gold() < atomCost * bombsToFire then
			continue
		end
		-- NukeExecution picks silos in the same Manhattan order we planned.
		for i = 1, bombsToFire do
			self:_sendNuke(targetTile, UnitType.AtomBomb, nukeTarget, waitTicksPerBomb[i])
		end
		return
	end

	-- No SAM could be destroyed: upgrade a silo only if capacity was the
	-- bottleneck. If only gold was short, wait and save instead.
	if needsMoreSilos and failedTarget ~= nil then
		self:_maybeUpgradeHelpfulSilo(failedTarget)
	end
end

function NationNukeBehavior._findEnemySamsCoveringTile(self: NationNukeBehavior, tile: number): { any }
	local game, player = self.game, self.player
	local config = game:config()
	local result = {}
	for _, sam in game:nearbyUnits(tile, config:maxSamRange(), UnitType.SAMLauncher) do
		local owner = sam.unit:owner()
		if owner == player or player:isFriendly(owner) then
			continue
		end
		local range = config:samRange(sam.unit:level())
		if sam.distSquared <= range * range then
			table.insert(result, sam.unit)
		end
	end
	return result
end

-- Upgrade a silo that would have helped the failed overwhelm plan: its
-- flight isn't blocked by other enemy SAMs and it's below the cap. Of
-- those, the one our own SAMs protect best.
function NationNukeBehavior._maybeUpgradeHelpfulSilo(
	self: NationNukeBehavior,
	failedTarget: { targetTile: number, coveringSamIds: { [number]: boolean }, totalBombs: number }
)
	local game, player = self.game, self.player
	local config = game:config()
	local silos = player:units(UnitType.MissileSilo)
	if #silos == 0 then
		return
	end
	local unblockedSilos = {}
	for _, silo in silos do
		if not self:_isTrajectoryInterceptableBySam(silo:tile(), failedTarget.targetTile, failedTarget.coveringSamIds) then
			table.insert(unblockedSilos, silo)
		end
	end
	if #unblockedSilos == 0 then
		return
	end
	-- Unreachable even at the max silo level: upgrading would waste gold.
	if #unblockedSilos * MAX_NATION_SILO_UPGRADE_LEVEL < failedTarget.totalBombs then
		return
	end

	local ourSams = player:units(UnitType.SAMLauncher)
	local bestSilo, bestProtection = nil, -1
	for _, silo in unblockedSilos do
		if silo:level() >= MAX_NATION_SILO_UPGRADE_LEVEL or not player:canUpgradeUnit(silo) then
			continue
		end
		local protection = 0
		for _, sam in ourSams do
			local range = config:samRange(sam:level())
			if game:euclideanDistSquared(silo:tile(), sam:tile()) <= range * range then
				protection += sam:level()
			end
		end
		if protection > bestProtection then
			bestProtection = protection
			bestSilo = silo
		end
	end
	if bestSilo ~= nil then
		local UpgradeStructureExecution = require(script.Parent.Parent.UpgradeStructureExecution) :: any
		game:addExecution(UpgradeStructureExecution.new(player, bestSilo:id()))
	end
end

return NationNukeBehavior
