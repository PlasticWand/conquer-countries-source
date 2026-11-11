--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/NationStructureBehavior.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- What nations build and where.
--   - Defence posts behind an attack front (Medium and up), and (Hard and
--     up) facing hostile neighbours before they attack.
--   - Otherwise one structure per call, in order: ports, factories, SAMs,
--     silos while below their ratio to the city count, then cities. Each
--     owned structure inflates the next one's perceived cost while the
--     nation saves up for nukes.
--   - Dense territories upgrade instead of building; SAMs upgrade once they
--     already cover every structure.
--   - Spots are the best of 25 random own tiles by elevation, distance from
--     the border and spacing (factories and cities also by rail clusters
--     in range, SAMs by the structures they would cover).

local ExecUtil = require(script.Parent.Parent.Util)
local GameTypes = require(script.Parent.Parent.Parent.GameTypes)
local NationUtils = require(script.Parent.NationUtils)
local Util = require(script.Parent.Parent.Parent.Util)

local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

local Relation = { Hostile = 0, Distrustful = 1, Neutral = 2, Friendly = 3 }

local SAM_RATIO_BY_DIFFICULTY = { [Difficulty.Easy] = 0.15, [Difficulty.Medium] = 0.2, [Difficulty.Hard] = 0.25, [Difficulty.Impossible] = 0.3 }
local TEAM_PORT_RATIO = 1

local function getStructureRatios(difficulty: string, gameMode: string): { [string]: { ratioPerCity: number, perceivedCostIncreasePerOwned: number } }
	local teamPorts = gameMode == GameTypes.GameMode.Team and difficulty ~= Difficulty.Easy
	return {
		[UnitType.Port] = { ratioPerCity = if teamPorts then TEAM_PORT_RATIO else 0.75, perceivedCostIncreasePerOwned = 1 },
		[UnitType.Factory] = { ratioPerCity = 0.75, perceivedCostIncreasePerOwned = 1 },
		[UnitType.SAMLauncher] = { ratioPerCity = SAM_RATIO_BY_DIFFICULTY[difficulty], perceivedCostIncreasePerOwned = 0.3 },
		[UnitType.MissileSilo] = { ratioPerCity = 0.2, perceivedCostIncreasePerOwned = 1 },
	}
end

local CITY_PERCEIVED_COST_INCREASE_PER_OWNED = 1
local CITIES_BEFORE_SAVING = { [Difficulty.Easy] = 0, [Difficulty.Medium] = 3, [Difficulty.Hard] = 4, [Difficulty.Impossible] = 5 }
local INCOME_STRUCTURE_SAVING_WEIGHT = { [Difficulty.Easy] = 1, [Difficulty.Medium] = 0.8, [Difficulty.Hard] = 0.6, [Difficulty.Impossible] = 0.4 }
local FACTORY_COASTAL_RATIO_MULTIPLIER = { [Difficulty.Easy] = 0.33, [Difficulty.Medium] = 0.45, [Difficulty.Hard] = 0.55, [Difficulty.Impossible] = 0.6 }
local SAM_PROTECTED_TYPES = { UnitType.City, UnitType.Factory, UnitType.MissileSilo, UnitType.Port }
local SAM_UPGRADE_WHEN_COVERED_CHANCE = { [Difficulty.Easy] = 0, [Difficulty.Medium] = 50, [Difficulty.Hard] = 100, [Difficulty.Impossible] = 100 }
local MAX_MISSILE_SILOS = 3
local FIRST_MISSILE_SILO_RATIO = 0.4
local UPGRADE_DENSITY_THRESHOLD = 1 / 1500
local MAX_UPGRADES_AT_ONCE = { [Difficulty.Easy] = 3, [Difficulty.Medium] = 10, [Difficulty.Hard] = math.huge, [Difficulty.Impossible] = math.huge }
-- Structures counted for density (cheap defence posts would push upgrades early).
local DENSITY_STRUCTURE_TYPES = { UnitType.City, UnitType.SAMLauncher, UnitType.MissileSilo, UnitType.Port, UnitType.Factory }
local MIN_PORT_WATER_COMPONENT_SIZE = 3000
local TILES_PER_CITY_EQUIVALENT = 2000
local HIGH_NATION_DENSITY_THRESHOLD = 1 / 7500
local PACED_STARTING_GOLD_LIMIT = 10_000_000
local HIGH_GOLD_STRUCTURE_COOLDOWN_TICKS = { 0, 0, 250, 150, 100 } -- before structure #1..#5
local TEAM_POST_SAVE_UP_PHASE_TICKS = 150
local UNDER_ATTACK_THREAT_RATIO = 0.35
local DEFENSE_POST_RATIO_PER_POST = 0.4
local DEFENSE_POST_FRONT_MIN_DIST = 2 / 3
local DEFENSE_POST_FRONT_DIST_PER_RATIO = 1 / 3
local DEFENSE_POST_FRONT_RATIO_CAP = 2
local DEFENSE_POST_FRONT_BAND = 1 / 2
local PROACTIVE_DEFENSE_POST_MIN_DIST = 1 / 2
local PROACTIVE_DEFENSE_POST_MAX_DIST = 1
local PROACTIVE_DEFENSE_POST_MIN_CITIES = 2
local PROACTIVE_DEFENSE_POSTS_PER_CITY = 0.5
local PROACTIVE_DEFENSE_POST_HOSTILE_TROOP_RATIO = { [Difficulty.Hard] = 1, [Difficulty.Impossible] = 0.5 }
local DEFENSE_POST_SAMPLE_ATTEMPTS = 150

local function Construction(): any
	return require(script.Parent.Parent.ConstructionExecution)
end

-- JS truthiness of canBuild: false or tile 0 both fail.
local function canBuildAt(player: any, unitType: string, tile: number): boolean
	local r = player:canBuild(unitType, tile)
	return r ~= false and r ~= 0
end

local function tileList(units: { any }, except: number): { number }
	local out = {}
	for _, u in units do
		local t = u:tile()
		if t ~= except then
			table.insert(out, t)
		end
	end
	return out
end

local NationStructureBehavior = {}
NationStructureBehavior.__index = NationStructureBehavior

export type NationStructureBehavior = typeof(setmetatable(
	{} :: {
		random: any,
		game: any,
		player: any,
		reachableStationsCache: { any }?,
		_sharedWaterComponents: { [number]: boolean }?,
		lastStructureTick: number?,
		placementsCount: number,
		builtCrowdedMapFirstStructure: boolean,
		_hasHighStartingGold: boolean?,
		_postSaveUpStartTick: number?,
		mirvWorthSavingMemo: { tick: number, worth: boolean }?,
	},
	NationStructureBehavior
))

function NationStructureBehavior.new(random: any, game: any, player: any): NationStructureBehavior
	return setmetatable({
		random = random,
		game = game,
		player = player,
		reachableStationsCache = nil,
		_sharedWaterComponents = nil,
		lastStructureTick = nil,
		placementsCount = 0,
		builtCrowdedMapFirstStructure = false,
		_hasHighStartingGold = nil,
		_postSaveUpStartTick = nil,
		mirvWorthSavingMemo = nil,
	}, NationStructureBehavior)
end

function NationStructureBehavior._difficulty(self: NationStructureBehavior): string
	return self.game:config():gameConfig().difficulty
end

function NationStructureBehavior._cost(self: NationStructureBehavior, unitType: string, extraUnits: number?): number
	return self.game:unitInfo(unitType).cost(self.game, self.player, extraUnits or 0)
end

local function incomingTroops(player: any): number
	local s = 0
	for _, a in player:incomingAttacks() do
		s += a:troops()
	end
	return s
end

-- Defence posts are outside the pacing (no placement count, never first).
function NationStructureBehavior.handleStructures(self: NationStructureBehavior): boolean
	if self.placementsCount > 0 and not self.game:config():isUnitDisabled(UnitType.DefensePost) then
		if self:_tryBuildDefensePost() then
			return true
		end
		-- Under enough attack, nothing else is built even if no post was.
		if self:_defensePostNeeded() then
			return false
		end
	end
	if self:_isOnStructureCooldown() then
		return false
	end
	if self:_isInPostSaveUpBlockedPhase() then
		return false
	end
	local built = self:_doHandleStructures()
	if built then
		self.lastStructureTick = self.game:ticks()
		self.placementsCount += 1
	end
	return built
end

-- A post behind the attack front, far enough back to finish before the
-- attack arrives. Medium: half the time, one post. Hard and up: one per
-- 0.4 of incoming/own troops, further back against stronger attacks.
function NationStructureBehavior._tryBuildDefensePost(self: NationStructureBehavior): boolean
	local d = self:_difficulty()
	if d == Difficulty.Easy then
		return false
	end
	if d == Difficulty.Medium and not self.random:chance(2) then
		return false
	end
	local player = self.player
	local attacks = player:incomingAttacks()
	if #attacks == 0 then
		return false
	end
	local ours = player:troops()
	if ours <= 0 then
		return false
	end
	local ratio = incomingTroops(player) / ours
	if ratio < UNDER_ATTACK_THREAT_RATIO then
		return false
	end
	local allowed = if d == Difficulty.Medium then 1 else math.ceil(ratio / DEFENSE_POST_RATIO_PER_POST)
	local range = self.game:config():defensePostRange()
	local scaled = if d == Difficulty.Medium then 0 else math.min(ratio, DEFENSE_POST_FRONT_RATIO_CAP)
	local minDist = range * (DEFENSE_POST_FRONT_MIN_DIST + DEFENSE_POST_FRONT_DIST_PER_RATIO * scaled)
	local maxDist = minDist + range * DEFENSE_POST_FRONT_BAND
	local front = self:_getAttackFrontTiles(attacks)
	if self:_countDefensePostsNearFront(front, maxDist, allowed) >= allowed then
		return false
	end
	return self:_buildDefensePostBehind(front, minDist, maxDist)
end

-- Hard and up: cover the border with a hostile neighbour strong enough to
-- fear, one post per such neighbour.
function NationStructureBehavior._maybeBuildProactiveDefensePost(self: NationStructureBehavior): boolean
	local config = self.game:config()
	local hostileRatio = PROACTIVE_DEFENSE_POST_HOSTILE_TROOP_RATIO[self:_difficulty()]
	if hostileRatio == nil then
		return false
	end
	if config:isUnitDisabled(UnitType.DefensePost) then
		return false
	end
	local cities = self:_cityCount()
	if cities < PROACTIVE_DEFENSE_POST_MIN_CITIES then
		return false
	end
	local player = self.player
	if #player:units(UnitType.DefensePost) >= cities * PROACTIVE_DEFENSE_POSTS_PER_CITY then
		return false
	end
	if player:gold() < self:_cost(UnitType.DefensePost) then
		return false
	end
	local minTroops = player:troops() * hostileRatio
	local threats, count = {}, 0
	for _, n in player:nearby() do
		if n:isPlayer() and n:type() ~= PlayerType.Bot and not player:isFriendly(n) then
			if player:relation(n) == Relation.Hostile and n:troops() >= minTroops and not threats[n] then
				threats[n] = true
				count += 1
			end
		end
	end
	if count == 0 then
		return false
	end
	local range = config:defensePostRange()
	local front = self:_borderTilesFacing(threats)
	if self:_countDefensePostsNearFront(front, range * 1.5, count) >= count then
		return false
	end
	return self:_buildDefensePostBehind(front, range * PROACTIVE_DEFENSE_POST_MIN_DIST, range * PROACTIVE_DEFENSE_POST_MAX_DIST)
end

function NationStructureBehavior._buildDefensePostBehind(self: NationStructureBehavior, front: { number }, minDist: number, maxDist: number): boolean
	local player = self.player
	if player:gold() < self:_cost(UnitType.DefensePost) then
		return false
	end
	local tile = self:_findDefensePostTile(front, minDist, maxDist)
	if tile == nil then
		return false
	end
	self.game:addExecution(Construction().new(player, UnitType.DefensePost, tile))
	return true
end

function NationStructureBehavior._defensePostNeeded(self: NationStructureBehavior): boolean
	if self:_difficulty() == Difficulty.Easy then
		return false
	end
	local player = self.player
	if #player:incomingAttacks() == 0 then
		return false
	end
	local ours = player:troops()
	if ours <= 0 then
		return false
	end
	return incomingTroops(player) / ours >= UNDER_ATTACK_THREAT_RATIO
end

-- Our border facing land attackers, plus the landing fronts of boat
-- attacks from players not attacking by land.
function NationStructureBehavior._getAttackFrontTiles(self: NationStructureBehavior, attacks: { any }): { number }
	local game, player = self.game, self.player
	local land: { [any]: boolean } = {}
	for _, a in attacks do
		if a:sourceTile() == nil then
			land[a:attacker()] = true
		end
	end
	local front = self:_borderTilesFacing(land)
	for _, a in attacks do
		if a:sourceTile() ~= nil and not land[a:attacker()] then
			a:borderTiles():forEach(function(t: number)
				if game:owner(t) == player then
					table.insert(front, t)
				end
			end)
		end
	end
	return front
end

function NationStructureBehavior._borderTilesFacing(self: NationStructureBehavior, players: { [any]: boolean }): { number }
	local game = self.game
	local front = {}
	if next(players) == nil then
		return front
	end
	local nbuf = { 0, 0, 0, 0 }
	local map = game:map()
	self.player:borderTiles():forEach(function(borderTile: number)
		local n = map:neighbors4(borderTile, nbuf)
		for i = 1, n do
			if players[game:owner(nbuf[i])] then
				table.insert(front, borderTile)
				return
			end
		end
	end)
	return front
end

function NationStructureBehavior._countDefensePostsNearFront(self: NationStructureBehavior, front: { number }, range: number, cap: number?): number
	if #front == 0 then
		return 0
	end
	local game = self.game
	local r2 = range ^ 2
	local count = 0
	for _, dp in self.player:units(UnitType.DefensePost) do
		for _, ft in front do
			if game:euclideanDistSquared(dp:tile(), ft) <= r2 then
				count += 1
				if cap ~= nil and count >= cap then
					return count
				end
				break
			end
		end
	end
	return count
end

-- An own buildable tile [minDist, maxDist] from the nearest front tile,
-- away from existing posts (overlapping posts don't stack).
function NationStructureBehavior._findDefensePostTile(self: NationStructureBehavior, front: { number }, minDist: number, maxDist: number): number?
	if #front == 0 then
		return nil
	end
	local game, player = self.game, self.player
	local spread2 = (game:config():defensePostRange() * 1.5) ^ 2
	local existing = tileList(player:units(UnitType.DefensePost), -1)
	local function nearExisting(t: number): boolean
		for _, dp in existing do
			if game:euclideanDistSquared(t, dp) < spread2 then
				return true
			end
		end
		return false
	end
	local anchors = {}
	for _, ft in front do
		if not nearExisting(ft) then
			table.insert(anchors, ft)
		end
	end
	if #anchors == 0 then
		return nil
	end
	local min2, max2 = minDist ^ 2, maxDist ^ 2
	local radius = math.ceil(maxDist)
	for _ = 1, DEFENSE_POST_SAMPLE_ATTEMPTS do
		local anchor = self.random:randElement(anchors)
		local ax, ay = game:x(anchor), game:y(anchor)
		local x = self.random:nextInt(ax - radius, ax + radius + 1)
		local y = self.random:nextInt(ay - radius, ay + radius + 1)
		if game:isValidCoord(x, y) then
			local t = game:ref(x, y)
			if game:owner(t) == player and not nearExisting(t) then
				local nearest = math.huge
				for _, ft in front do
					nearest = math.min(nearest, game:euclideanDistSquared(t, ft))
					if nearest < min2 then
						break
					end
				end
				if nearest >= min2 and nearest <= max2 and canBuildAt(player, UnitType.DefensePost, t) then
					return t
				end
			end
		end
	end
	return nil
end

function NationStructureBehavior._isOnStructureCooldown(self: NationStructureBehavior): boolean
	if self.lastStructureTick == nil or not self:_hasHighStartingGoldCached() or self.game:config():startingGold(self.player:info()) >= PACED_STARTING_GOLD_LIMIT then
		return false
	end
	local gap = HIGH_GOLD_STRUCTURE_COOLDOWN_TICKS[self.placementsCount + 1] or 0
	if gap == 0 then
		return false
	end
	return self.game:ticks() - (self.lastStructureTick :: number) < gap
end

-- After the save-up target is first reached: 15 s on, 15 s off, so nukes
-- get the gold (not while it covers the target twice).
function NationStructureBehavior._isInPostSaveUpBlockedPhase(self: NationStructureBehavior): boolean
	if self.game:config():isUnitDisabled(UnitType.MissileSilo) then
		return false
	end
	local target = self:_getSaveUpTarget()
	if self._postSaveUpStartTick == nil then
		if self.player:gold() < target then
			return false
		end
		self._postSaveUpStartTick = self.game:ticks()
	end
	if self.player:gold() >= target * 2 then
		return false
	end
	local elapsed = self.game:ticks() - (self._postSaveUpStartTick :: number)
	return elapsed % (TEAM_POST_SAVE_UP_PHASE_TICKS * 2) >= TEAM_POST_SAVE_UP_PHASE_TICKS
end

function NationStructureBehavior._doHandleStructures(self: NationStructureBehavior): boolean
	self.reachableStationsCache = nil
	local game = self.game
	local config = game:config()
	local citiesDisabled = config:isUnitDisabled(UnitType.City)
	local cityCount = self:_cityCount()
	self._sharedWaterComponents = game:sharedWaterComponents(self.player)
	local hasCoastal = self._sharedWaterComponents ~= nil
	local silosEnabled = not config:isUnitDisabled(UnitType.MissileSilo)
	local d = self:_difficulty()
	-- High-starting-gold Hard and up start with a SAM, so the rush that
	-- follows is covered and not clustered under one nuke.
	if
		self.placementsCount == 0
		and (d == Difficulty.Hard or d == Difficulty.Impossible)
		and not config:isUnitDisabled(UnitType.AtomBomb)
		and silosEnabled
		and not config:isUnitDisabled(UnitType.SAMLauncher)
		and self:_hasHighStartingGoldCached()
		and self:_maybeSpawnStructure(UnitType.SAMLauncher)
	then
		return true
	end
	-- Crowded maps and team spawn areas: a port (or factory) first, for early income.
	if not citiesDisabled and not self.builtCrowdedMapFirstStructure and (self:_isHighNationDensity() or (d ~= Difficulty.Easy and self:_startsInTeamSpawnArea())) then
		local preferred = if hasCoastal and not config:isUnitDisabled(UnitType.Port) then UnitType.Port else UnitType.Factory
		if config:isUnitDisabled(preferred) then
			self.builtCrowdedMapFirstStructure = true
		elseif self:_maybeSpawnStructure(preferred) then
			self.builtCrowdedMapFirstStructure = true
			return true
		end
	end
	if self:_maybeBuildProactiveDefensePost() then
		return true
	end
	local nukesEnabled = not config:isUnitDisabled(UnitType.AtomBomb) or not config:isUnitDisabled(UnitType.HydrogenBomb) or not config:isUnitDisabled(UnitType.MIRV)
	for _, t in { UnitType.Port, UnitType.Factory, UnitType.SAMLauncher, UnitType.MissileSilo } do
		local skip = config:isUnitDisabled(t)
			or (t == UnitType.Port and not hasCoastal)
			or (not nukesEnabled and (t == UnitType.MissileSilo or t == UnitType.SAMLauncher))
			or (not silosEnabled and t == UnitType.SAMLauncher)
		if not skip and self:_levelsDue(t, cityCount, hasCoastal) > 0 then
			if self:_maybeSpawnStructure(t) then
				return true
			end
		end
	end
	if not citiesDisabled and self:_maybeSpawnStructure(UnitType.City) then
		return true
	end
	return false
end

function NationStructureBehavior._cityCount(self: NationStructureBehavior): number
	if self.game:config():isUnitDisabled(UnitType.City) then
		return math.max(1, math.floor(self.player:numTilesOwned() / TILES_PER_CITY_EQUIVALENT))
	end
	return self.player:unitsOwned(UnitType.City)
end

function NationStructureBehavior._startsInTeamSpawnArea(self: NationStructureBehavior): boolean
	local team = self.player:team()
	return team ~= nil and self.game:teamSpawnArea(team) ~= nil
end

function NationStructureBehavior._hasHighStartingGoldCached(self: NationStructureBehavior): boolean
	if self._hasHighStartingGold == nil then
		self._hasHighStartingGold = NationUtils.hasHighStartingGold(self.game, self.player)
	end
	return self._hasHighStartingGold :: boolean
end

function NationStructureBehavior._isHighNationDensity(self: NationStructureBehavior): boolean
	local land = self.game:numLandTiles()
	if land <= 0 then
		return false
	end
	return #self.game:nations() / land > HIGH_NATION_DENSITY_THRESHOLD
end

-- Levels of this type the ratio to the city count still asks for.
function NationStructureBehavior._levelsDue(self: NationStructureBehavior, t: string, cityCount: number, hasCoastal: boolean): number
	local config = self.game:config()
	local gc = config:gameConfig()
	local c = getStructureRatios(gc.difficulty, gc.gameMode)[t]
	if c == nil then
		return 0
	end
	local ratio = c.ratioPerCity
	if t == UnitType.Factory and hasCoastal and not config:isUnitDisabled(UnitType.Port) then
		ratio *= FACTORY_COASTAL_RATIO_MULTIPLIER[gc.difficulty]
	end
	local owned = self.player:unitsOwned(t)
	local target
	if t == UnitType.MissileSilo then
		if owned == 0 then
			ratio = FIRST_MISSILE_SILO_RATIO
		end
		target = math.min(math.floor(cityCount * ratio), MAX_MISSILE_SILOS)
	else
		target = math.floor(cityCount * ratio)
	end
	return target - owned
end

function NationStructureBehavior._maybeSpawnStructure(self: NationStructureBehavior, t: string): boolean
	local game, player = self.game, self.player
	if player:gold() < self:_getPerceivedCost(t) then
		return false
	end
	-- Another SAM would cover nothing new; a higher level stops more of a salvo.
	if t == UnitType.SAMLauncher and self:_shouldUpgradeSamInstead() then
		return self:_upgradeStructure(self:_samProtectingMost())
	end
	local structures = player:units(t)
	local upgradable = game:config():unitInfo(t).upgradable == true
	if self:_getTotalStructureDensity() > UPGRADE_DENSITY_THRESHOLD and upgradable then
		if self:_maybeUpgradeStructure(structures) then
			return true
		end
		-- Dense but nothing to upgrade yet (under construction): wait.
		if #structures > 0 then
			return false
		end
	end
	local tile = self:_structureSpawnTile(t)
	if tile == nil then
		-- No room (a short coastline full of ports): upgrade instead.
		return upgradable and self:_difficulty() ~= Difficulty.Easy and self:_maybeUpgradeStructure(structures)
	end
	if player:canBuild(t, tile) == false then
		return false
	end
	game:addExecution(Construction().new(player, t, tile))
	return true
end

-- The real cost, inflated per owned structure while saving up for nukes
-- (income structures less so on harder levels).
function NationStructureBehavior._getPerceivedCost(self: NationStructureBehavior, t: string): number
	local real = self:_cost(t)
	local target = self:_getSaveUpTarget()
	if target == 0 or self.player:gold() >= target or not NationUtils.isSaveUpWithinReach(self.game, self.player, target) then
		return real
	end
	local gc = self.game:config():gameConfig()
	if self:_cityCount() < CITIES_BEFORE_SAVING[gc.difficulty] then
		return real
	end
	local owned = self.player:unitsOwned(t)
	local increase
	if t == UnitType.City then
		increase = CITY_PERCEIVED_COST_INCREASE_PER_OWNED
	else
		local c = getStructureRatios(gc.difficulty, gc.gameMode)[t]
		increase = if c then c.perceivedCostIncreasePerOwned else 0.1
	end
	if t == UnitType.City or t == UnitType.Port or t == UnitType.Factory then
		increase *= INCOME_STRUCTURE_SAVING_WEIGHT[gc.difficulty]
	end
	return math.ceil(real * (1 + increase * owned))
end

-- Gold to save for, by which nukes are enabled; 0 for none.
function NationStructureBehavior._getSaveUpTarget(self: NationStructureBehavior): number
	local config = self.game:config()
	if config:isUnitDisabled(UnitType.MissileSilo) then
		return self:_cost(UnitType.SAMLauncher)
	end
	if config:gameConfig().gameMode == GameTypes.GameMode.Team then
		return self:_cost(UnitType.HydrogenBomb)
	end
	if not config:isUnitDisabled(UnitType.MIRV) and self:_isMirvWorthSavingFor() then
		return self:_cost(UnitType.MIRV) + self:_cost(UnitType.HydrogenBomb)
	end
	if not config:isUnitDisabled(UnitType.HydrogenBomb) then
		return self:_cost(UnitType.HydrogenBomb) * 5
	end
	if not config:isUnitDisabled(UnitType.AtomBomb) then
		return self:_cost(UnitType.AtomBomb) * 20
	end
	return self:_cost(UnitType.SAMLauncher)
end

function NationStructureBehavior._isMirvWorthSavingFor(self: NationStructureBehavior): boolean
	local tick = self.game:ticks()
	local memo = self.mirvWorthSavingMemo
	if memo == nil or memo.tick ~= tick then
		memo = { tick = tick, worth = require(script.Parent.NationMIRVBehavior).isMirvWorthSavingFor(self.game, self.player) }
		self.mirvWorthSavingMemo = memo
	end
	return (memo :: any).worth
end

function NationStructureBehavior._maybeUpgradeStructure(self: NationStructureBehavior, structures: { any }): boolean
	return self:_upgradeStructure(self:_findBestStructureToUpgrade(structures))
end

function NationStructureBehavior._upgradeStructure(self: NationStructureBehavior, structure: any?): boolean
	if structure == nil then
		return false
	end
	local UpgradeStructureExecution = require(script.Parent.Parent.UpgradeStructureExecution)
	self.game:addExecution(UpgradeStructureExecution.new(self.player, structure:id(), self:_upgradeAmount(structure:type())))
	return true
end

-- One level, or as many as gold beyond the save-up target pays for and the
-- ratios ask for.
function NationStructureBehavior._upgradeAmount(self: NationStructureBehavior, t: string): number
	local due = if t == UnitType.City then math.huge else self:_levelsDue(t, self:_cityCount(), self._sharedWaterComponents ~= nil)
	local max = math.min(MAX_UPGRADES_AT_ONCE[self:_difficulty()], due)
	local spare = self.player:gold() - self:_getSaveUpTarget()
	local amount = 0
	while amount < max do
		local cost = self:_cost(t, amount)
		if cost > spare then
			break
		end
		spare -= cost
		amount += 1
	end
	return math.max(1, amount)
end

function NationStructureBehavior._shouldUpgradeSamInstead(self: NationStructureBehavior): boolean
	local chance = SAM_UPGRADE_WHEN_COVERED_CHANCE[self:_difficulty()]
	local sams = self.player:units(UnitType.SAMLauncher)
	if chance == 0 or #sams == 0 then
		return false
	end
	local game = self.game
	local config = game:config()
	for _, unit in self.player:units(SAM_PROTECTED_TYPES) do
		local covered = false
		for _, sam in sams do
			if game:euclideanDistSquared(unit:tile(), sam:tile()) <= config:samRange(sam:level()) ^ 2 then
				covered = true
				break
			end
		end
		if not covered then
			return false
		end
	end
	return chance == 100 or self.random:nextInt(0, 100) < chance
end

-- The upgradable SAM covering the most structure levels.
function NationStructureBehavior._samProtectingMost(self: NationStructureBehavior): any?
	local game = self.game
	local config = game:config()
	local protectable = self.player:units(SAM_PROTECTED_TYPES)
	local best, bestLevels = nil, -1
	for _, sam in self.player:units(UnitType.SAMLauncher) do
		if self.player:canUpgradeUnit(sam) then
			local r2 = config:samRange(sam:level()) ^ 2
			local levels = 0
			for _, unit in protectable do
				if game:euclideanDistSquared(unit:tile(), sam:tile()) <= r2 then
					levels += unit:level()
				end
			end
			if levels > bestLevels then
				best, bestLevels = sam, levels
			end
		end
	end
	return best
end

function NationStructureBehavior._getTotalStructureDensity(self: NationStructureBehavior): number
	local tiles = self.player:numTilesOwned()
	return if tiles > 0 then #self.player:units(DENSITY_STRUCTURE_TYPES) / tiles else 0
end

local RANDOM_UPGRADE_CHANCE = { [Difficulty.Easy] = 70, [Difficulty.Medium] = 40, [Difficulty.Hard] = 25, [Difficulty.Impossible] = 10 }

-- Prefers structures under SAM cover; half the time takes the 2nd or 3rd best.
function NationStructureBehavior._findBestStructureToUpgrade(self: NationStructureBehavior, structures: { any }): any?
	local game = self.game
	if #structures == 0 then
		return nil
	end
	local upgradable = {}
	for _, s in structures do
		if self.player:canUpgradeUnit(s) then
			table.insert(upgradable, s)
		end
	end
	if #upgradable == 0 then
		return nil
	end
	if self.random:nextInt(0, 100) < RANDOM_UPGRADE_CHANCE[self:_difficulty()] then
		return self.random:randElement(upgradable)
	end
	local sams = self.player:units(UnitType.SAMLauncher)
	local scored = {}
	for _, structure in upgradable do
		local score = 0
		for _, sam in sams do
			local r = game:config():samRange(sam:level())
			if game:euclideanDistSquared(structure:tile(), sam:tile()) <= r * r then
				score += 10
				if sam:level() > 1 then
					score += (sam:level() - 1) * 7.5
				end
			end
		end
		score += self.random:nextInt(0, 5)
		table.insert(scored, { structure = structure, score = score })
	end
	if #scored == 0 then
		return nil
	end
	scored = Util.stableSort(scored, function(a, b)
		return a.score > b.score
	end)
	if #scored >= 2 and self.random:chance(2) then
		local pick = if #scored >= 3 then self.random:nextInt(1, 3) else 1
		return scored[pick + 1].structure
	end
	return scored[1].structure
end

function NationStructureBehavior._structureSpawnTile(self: NationStructureBehavior, t: string): number?
	local tiles: { number } = if t == UnitType.Port then self:_randCoastalTileArray(25) else NationUtils.randTerritoryTileArray(self.random, self.game, self.player, 25)
	if #tiles == 0 then
		return nil
	end
	local value = self:_structureSpawnTileValue(t)
	local bestTile, bestValue = nil, 0
	for _, tile in tiles do
		local v = value(tile)
		if not (v <= bestValue and bestTile ~= nil) and canBuildAt(self.player, t, tile) then
			bestTile, bestValue = tile, v
		end
	end
	return bestTile
end

-- Shore tiles on water another player can reach (so trade is possible);
-- not tiny lakes, except on Easy.
function NationStructureBehavior._randCoastalTileArray(self: NationStructureBehavior, numTiles: number): { number }
	local game = self.game
	local shared = self._sharedWaterComponents
	local easy = self:_difficulty() == Difficulty.Easy
	local tiles = {}
	for _, t in self.player:borderTiles():values() do
		local ok = false
		if game:isShore(t) and shared ~= nil then
			for _, n in game:neighbors(t) do
				if game:isWater(n) then
					if game:isOcean(n) then
						ok = true
						break
					end
					local comp = game:getWaterComponent(n)
					if comp ~= nil and shared[comp] then
						local size = if easy then nil else game:getWaterComponentSize(n)
						if size == nil or size >= MIN_PORT_WATER_COMPONENT_SIZE then
							ok = true
							break
						end
					end
				end
			end
		end
		if ok then
			table.insert(tiles, t)
		end
	end
	if #tiles <= numTiles then
		return tiles
	end
	-- randFromSet over a shrinking insertion-ordered set.
	local remaining = table.clone(tiles)
	local out: { number } = {}
	for _ = 1, numTiles do
		local index = self.random:nextInt(0, #remaining)
		table.insert(out, table.remove(remaining, index + 1) :: number)
	end
	return out
end

function NationStructureBehavior._structureSpawnTileValue(self: NationStructureBehavior, t: string): (number) -> number
	if t == UnitType.City then
		return self:_interiorValue(UnitType.City, UnitType.Factory, false)
	elseif t == UnitType.MissileSilo then
		return self:_missileSiloValue()
	elseif t == UnitType.Factory then
		return self:_interiorValue(UnitType.Factory, UnitType.City, true)
	elseif t == UnitType.Port then
		return self:_portValue()
	elseif t == UnitType.SAMLauncher then
		return self:_samLauncherValue()
	end
	error(`Value function not implemented for {t}`)
end

function NationStructureBehavior._spacing(self: NationStructureBehavior): (number, number)
	local border = self.game:config():nukeMagnitudes(UnitType.AtomBomb).outer
	return border, border * 2
end

-- Elevation, distance from the border, spacing from other silos.
function NationStructureBehavior._missileSiloValue(self: NationStructureBehavior): (number) -> number
	local game = self.game
	local border = self.player:borderTiles()
	local others = self.player:units(UnitType.MissileSilo)
	local borderSpacing, structureSpacing = self:_spacing()
	return function(tile: number): number
		local w = game:magnitude(tile)
		w += math.min(ExecUtil.nearestTileDistCapped(game, border, tile, borderSpacing), borderSpacing)
		local d = ExecUtil.nearestTileDist(game, tileList(others, tile), tile)
		if d ~= math.huge then
			w += math.min(d, structureSpacing)
		end
		return w
	end
end

-- As far as possible from other ports.
function NationStructureBehavior._portValue(self: NationStructureBehavior): (number) -> number
	local game = self.game
	local others = self.player:units(UnitType.Port)
	return function(tile: number): number
		return ExecUtil.nearestTileDist(game, tileList(others, tile), tile)
	end
end

-- Cities and factories: elevation, distance from the border, spacing from
-- their own kind and from each other, and (by difficulty) the trade value
-- of distinct rail clusters in station range. `isFactory` spaces from its
-- own kind by station range instead of structure spacing.
function NationStructureBehavior._interiorValue(self: NationStructureBehavior, own: string, cross: string, isFactory: boolean): (number) -> number
	local game, player = self.game, self.player
	local border = player:borderTiles()
	local others = player:units(own)
	local borderSpacing, structureSpacing = self:_spacing()
	local stationRange = game:config():trainStationMaxRange()
	local stationRange2 = stationRange * stationRange
	local useConnection = self:_shouldUseConnectivityScore()
	local stations = if useConnection then self:_getOrBuildReachableStations() else {}
	local minRange2 = game:config():trainStationMinRange() ^ 2
	local crossTiles = tileList(player:units(cross), -1)
	return function(tile: number): number
		local w = game:magnitude(tile)
		w += math.min(ExecUtil.nearestTileDistCapped(game, border, tile, borderSpacing), borderSpacing)
		local d = ExecUtil.nearestTileDist(game, tileList(others, tile), tile)
		if d ~= math.huge then
			w += math.min(d, if isFactory then stationRange else structureSpacing)
		end
		local d2 = ExecUtil.nearestTileDist(game, crossTiles, tile)
		if d2 ~= math.huge then
			w += math.min(d2, structureSpacing)
		end
		if not useConnection then
			return w
		end
		return w + self:_computeConnectivityScore(tile, stations, minRange2, stationRange2) * structureSpacing
	end
end

local CONNECTIVITY_CHANCE = { [Difficulty.Easy] = 0, [Difficulty.Medium] = 60, [Difficulty.Hard] = 75, [Difficulty.Impossible] = 100 }

function NationStructureBehavior._shouldUseConnectivityScore(self: NationStructureBehavior): boolean
	return self.random:nextInt(0, 100) < CONNECTIVITY_CHANCE[self:_difficulty()]
end

function NationStructureBehavior._getOrBuildReachableStations(self: NationStructureBehavior): { any }
	if self.reachableStationsCache == nil then
		self.reachableStationsCache = self:_buildReachableStations()
	end
	return self.reachableStationsCache :: { any }
end

-- Our stations and trading neighbours' (not tribes, not embargoed), each
-- weighted by trainGold for the relation, normalised to an ally's.
function NationStructureBehavior._buildReachableStations(self: NationStructureBehavior): { any }
	local game, player = self.game, self.player
	local clusterOf: { [any]: any } = {}
	for _, station in game:railNetwork():stationManager():getAll().list do
		clusterOf[station.unit] = station:getCluster() or false
	end
	local config = game:config()
	local maxGold = math.max(config:trainGold("ally", 0, player), 1)
	local out = {}
	local function add(units: { any }, weight: number)
		for _, unit in units do
			local c = clusterOf[unit]
			if c ~= nil then
				table.insert(out, { tile = unit:tile(), cluster = if c == false then nil else c, weight = weight })
			end
		end
	end
	local types = { UnitType.City, UnitType.Port, UnitType.Factory }
	add(player:units(types), config:trainGold("self", 0, player) / maxGold)
	for _, n in player:nearby() do
		if n:isPlayer() and n:type() ~= PlayerType.Bot and player:canTrade(n) then
			local rel = if player:isOnSameTeam(n) then "team" elseif player:isAlliedWith(n) then "ally" else "other"
			add(n:units(types), config:trainGold(rel, 0, player) / maxGold)
		end
	end
	return out
end

-- Per cluster the best station weight in range; stations without a
-- cluster count on their own.
function NationStructureBehavior._computeConnectivityScore(self: NationStructureBehavior, tile: number, stations: { any }, minRange2: number, range2: number): number
	local order, best = {}, {}
	local isolated = 0
	for _, s in stations do
		local dist = self.game:euclideanDistSquared(tile, s.tile)
		if dist >= minRange2 and dist <= range2 then
			if s.cluster ~= nil then
				if best[s.cluster] == nil then
					table.insert(order, s.cluster)
					best[s.cluster] = 0
				end
				best[s.cluster] = math.max(best[s.cluster], s.weight)
			else
				isolated += s.weight
			end
		end
	end
	local score = isolated
	for _, c in order do
		score += best[c]
	end
	return score
end

-- Elevation, border distance, spacing, and (not Easy) the structures in
-- range, weighted by level on Hard and up and sometimes by how covered
-- they already are.
function NationStructureBehavior._samLauncherValue(self: NationStructureBehavior): (number) -> number
	local game, player = self.game, self.player
	local border = player:borderTiles()
	local others = player:units(UnitType.SAMLauncher)
	local borderSpacing, structureSpacing = self:_spacing()
	local d = self:_difficulty()
	local byLevel = d == Difficulty.Hard or d == Difficulty.Impossible
	local entries = {}
	for _, unit in player:units() do
		local t = unit:type()
		if t == UnitType.City or t == UnitType.Factory or t == UnitType.MissileSilo or t == UnitType.Port then
			table.insert(entries, { tile = unit:tile(), weight = if byLevel then unit:level() else 1 })
		end
	end
	local range = game:config():defaultSamRange()
	local range2 = range * range
	local useCoverage = d ~= Difficulty.Easy and self.random:nextInt(0, 100) < 25
	local coverage: { [number]: number }? = nil
	if useCoverage then
		local cov = {}
		for _, e in entries do
			local score = 0
			for _, sam in others do
				local r = game:config():samRange(sam:level())
				if game:euclideanDistSquared(e.tile, sam:tile()) <= r * r then
					score += sam:level()
				end
			end
			cov[e.tile] = score
		end
		coverage = cov
	end
	return function(tile: number): number
		local w = game:magnitude(tile)
		local closest = ExecUtil.nearestTileDistCapped(game, border, tile, borderSpacing)
		-- math.huge also means "beyond borderSpacing"; only no border adds nothing.
		if border:size() > 0 then
			w += math.min(closest, borderSpacing)
		end
		local dd = ExecUtil.nearestTileDist(game, tileList(others, tile), tile)
		if dd ~= math.huge then
			w += math.min(dd, structureSpacing)
		end
		if d ~= Difficulty.Easy then
			for _, e in entries do
				if game:euclideanDistSquared(tile, e.tile) <= range2 then
					if useCoverage and coverage ~= nil then
						w += structureSpacing * e.weight * (1 / (1 + (coverage[e.tile] or 0)))
					else
						w += structureSpacing * e.weight
					end
				end
			end
		end
		return w
	end
end

return NationStructureBehavior
