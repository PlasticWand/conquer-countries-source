--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/NationMIRVBehavior.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- When a nation with a silo can afford a MIRV (and doesn't hesitate), it
-- picks, in order: whoever has a MIRV inbound at it, a player (or team's
-- biggest member) close to winning, a city leader far ahead, or (Hard and
-- up) a bordering rival about its size. A target MIRVed by any nation in
-- the last 300 ticks is skipped, and so is one whose SAMs would stop too
-- many warheads.

local Emoji = require(script.Parent.Parent.Parent.Data.Emoji)
local ExecUtil = require(script.Parent.Parent.Util)
local GameTypes = require(script.Parent.Parent.Parent.GameTypes)
local HumanProtection = require(script.Parent.Parent.Parent.HumanProtection)
local NationUtils = require(script.Parent.NationUtils)
local PseudoRandom = require(script.Parent.Parent.Parent.PseudoRandom)
local Util = require(script.Parent.Parent.Parent.Util)

local AllPlayers = GameTypes.AllPlayers
local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

local MIRV_COOLDOWN_TICKS = 300
-- Share of warheads that must get past SAMs, by difficulty (Easy never checks).
local MIN_MIRV_LEAK_SHARE = { [Difficulty.Easy] = 0, [Difficulty.Medium] = 0.1, [Difficulty.Hard] = 0.2, [Difficulty.Impossible] = 0.25 }
local MIRV_MAX_WARHEADS = 350
local LAND_TILES_PER_MIRV_WARHEAD = 2000
local RIVAL_MIN_TILE_RATIO = 0.5
local MIRV_COVERAGE_SAMPLES = 40

local NationMIRVBehavior = {}
NationMIRVBehavior.__index = NationMIRVBehavior

-- The coverage samples use their own random seeded by tick and target, so
-- they depend only on those and the target's territory: every nation asking
-- about the same leader in a tick gets the same tiles. Kept per target until
-- the tick or its tiles change (tileChangeVersion covers its border too).
local coverageSamples: { [any]: { tick: number, version: number, tiles: { number } } } = setmetatable({}, { __mode = "k" }) :: any

local function samplesFor(game: any, target: any): { number }
	local tick, version = game:ticks(), target:tileChangeVersion()
	local cached = coverageSamples[target]
	if cached ~= nil and cached.tick == tick and cached.version == version then
		return cached.tiles
	end
	local random = PseudoRandom.new(tick * 1024 + target:smallID())
	local tiles = NationUtils.randTerritoryTileArray(random, game, target, MIRV_COVERAGE_SAMPLES)
	coverageSamples[target] = { tick = tick, version = version, tiles = tiles }
	return tiles
end

-- Estimated share of a MIRV's warheads at `target` that SAMs (each
-- shooting its level in warheads) would miss.
function NationMIRVBehavior.mirvLeakShare(game: any, attacker: any, target: any): number
	local warheads = math.min(MIRV_MAX_WARHEADS, math.max(1, target:numTilesOwned() / LAND_TILES_PER_MIRV_WARHEAD))
	local samples = samplesFor(game, target)
	if #samples == 0 then
		return 1
	end
	local config = game:config()
	local perSample = warheads / #samples
	-- Map<Unit, number> in first-seen order (the shot sum is float).
	local samOrder, inRange = {}, {}
	local coveredSamples = 0
	for _, tile in samples do
		local covered = false
		for _, entry in game:nearbyUnits(tile, config:maxSamRange(), UnitType.SAMLauncher) do
			local sam = entry.unit
			local owner = sam:owner()
			if not (owner == attacker or owner:isFriendly(attacker)) and entry.distSquared <= config:samRange(sam:level()) ^ 2 then
				if inRange[sam] == nil then
					inRange[sam] = 0
					table.insert(samOrder, sam)
				end
				inRange[sam] += perSample
				covered = true
			end
		end
		if covered then
			coveredSamples += 1
		end
	end
	local shots = 0
	for _, sam in samOrder do
		shots += math.min(sam:level(), inRange[sam])
	end
	local intercepted = math.min(coveredSamples * perSample, shots)
	return 1 - intercepted / warheads
end

function NationMIRVBehavior.mirvGetsThrough(game: any, attacker: any, target: any): boolean
	local minShare = MIN_MIRV_LEAK_SHARE[game:config():gameConfig().difficulty]
	return minShare == 0 or NationMIRVBehavior.mirvLeakShare(game, attacker, target) >= minShare
end

local function validMirvTargets(game: any, player: any): { any }
	local out = {}
	for _, p in game:players() do
		if p ~= player and p:isPlayer() and p:type() ~= PlayerType.Bot and not player:isOnSameTeam(p) then
			table.insert(out, p)
		end
	end
	return out
end

-- Whether a MIRV would get through at the land or city leader.
function NationMIRVBehavior.isMirvWorthSavingFor(game: any, player: any): boolean
	local landLeader: any, cityLeader: any = nil, nil
	for _, p in validMirvTargets(game, player) do
		if landLeader == nil or p:numTilesOwned() > landLeader:numTilesOwned() then
			landLeader = p
		end
		if cityLeader == nil or p:unitCount(UnitType.City) > cityLeader:unitCount(UnitType.City) then
			cityLeader = p
		end
	end
	if landLeader ~= nil and NationMIRVBehavior.mirvGetsThrough(game, player, landLeader) then
		return true
	end
	return cityLeader ~= nil and cityLeader ~= landLeader and NationMIRVBehavior.mirvGetsThrough(game, player, cityLeader)
end

export type NationMIRVBehavior = typeof(setmetatable({} :: { random: any, game: any, player: any, emojiBehavior: any }, NationMIRVBehavior))

function NationMIRVBehavior.new(random: any, game: any, player: any, emojiBehavior: any): NationMIRVBehavior
	return setmetatable({ random = random, game = game, player = player, emojiBehavior = emojiBehavior }, NationMIRVBehavior)
end

local HESITATION = { [Difficulty.Easy] = 2, [Difficulty.Medium] = 4, [Difficulty.Hard] = 8, [Difficulty.Impossible] = 16 }
local VICTORY_DENIAL_PERCENT = { [Difficulty.Easy] = 75, [Difficulty.Medium] = 65, [Difficulty.Hard] = 55, [Difficulty.Impossible] = 40 }
local STEAMROLL_GAP = { [Difficulty.Easy] = 2, [Difficulty.Medium] = 1.5, [Difficulty.Hard] = 1.25, [Difficulty.Impossible] = 1.15 }
local STEAMROLL_MIN_CITIES = { [Difficulty.Easy] = 20, [Difficulty.Medium] = 10, [Difficulty.Hard] = 10, [Difficulty.Impossible] = 8 }

function NationMIRVBehavior._difficulty(self: NationMIRVBehavior): string
	return self.game:config():gameConfig().difficulty
end

function NationMIRVBehavior.considerMIRV(self: NationMIRVBehavior): boolean
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.MIRV) then
		return false
	end
	if #player:units(UnitType.MissileSilo) == 0 then
		return false
	end
	if player:gold() < game:unitInfo(UnitType.MIRV).cost(game, player) then
		return false
	end
	if self.random:chance(HESITATION[self:_difficulty()]) then
		return false
	end
	for _, select in { self._selectCounterMirvTarget, self._selectVictoryDenialTarget, self._selectSteamrollStopTarget, self._selectRivalTarget } do
		local target = select(self)
		if target and self:_isWorthMirving(target) then
			self:_maybeSendMIRV(target)
			return true
		end
	end
	return false
end

function NationMIRVBehavior._isWorthMirving(self: NationMIRVBehavior, target: any): boolean
	return not self:_wasRecentlyMirved(target) and NationMIRVBehavior.mirvGetsThrough(self.game, self.player, target)
end

local function byTilesDesc(list: { any }): { any }
	return Util.stableSort(list, function(a, b)
		return a:numTilesOwned() > b:numTilesOwned()
	end)
end

function NationMIRVBehavior._selectCounterMirvTarget(self: NationMIRVBehavior): any?
	local attackers = {}
	for _, p in validMirvTargets(self.game, self.player) do
		if self:_isInboundMIRVFrom(p) then
			table.insert(attackers, p)
		end
	end
	if #attackers == 0 then
		return nil
	end
	return byTilesDesc(attackers)[1]
end

function NationMIRVBehavior._selectVictoryDenialTarget(self: NationMIRVBehavior): any?
	local game = self.game
	local totalLand = game:numLandTiles()
	if totalLand == 0 then
		return nil
	end
	local threshold = totalLand * VICTORY_DENIAL_PERCENT[self:_difficulty()]
	local best, bestSeverity = nil, 0
	for _, p in validMirvTargets(game, self.player) do
		local severity = 0
		local team = p:team()
		if team ~= nil then
			local members = {}
			local territory = 0
			for _, x in game:players() do
				if x:team() == team and x:isPlayer() then
					table.insert(members, x)
					territory += x:numTilesOwned()
				end
			end
			if territory * 100 >= threshold then
				local largest, largestTiles = nil, -1
				for _, m in members do
					if m:numTilesOwned() > largestTiles then
						largestTiles = m:numTilesOwned()
						largest = m
					end
				end
				severity = if largest == p then territory else 0
			end
		elseif p:numTilesOwned() * 100 >= threshold then
			severity = p:numTilesOwned()
		end
		if severity > 0 and (best == nil or severity > bestSeverity) then
			best, bestSeverity = p, severity
		end
	end
	return best
end

function NationMIRVBehavior._selectSteamrollStopTarget(self: NationMIRVBehavior): any?
	local valid = validMirvTargets(self.game, self.player)
	if #valid == 0 then
		return nil
	end
	local all = {}
	for _, p in self.game:players() do
		if p:isPlayer() then
			table.insert(all, { p = p, cityCount = p:unitCount(UnitType.City) })
		end
	end
	all = Util.stableSort(all, function(a, b)
		return a.cityCount > b.cityCount
	end)
	if #all < 2 then
		return nil
	end
	local top = all[1]
	if top.cityCount <= STEAMROLL_MIN_CITIES[self:_difficulty()] then
		return nil
	end
	if top.cityCount >= all[2].cityCount * STEAMROLL_GAP[self:_difficulty()] then
		return if table.find(valid, top.p) then top.p else nil
	end
	return nil
end

-- Hard and up: the biggest bordering player at least half our size.
function NationMIRVBehavior._selectRivalTarget(self: NationMIRVBehavior): any?
	local d = self:_difficulty()
	if d ~= Difficulty.Hard and d ~= Difficulty.Impossible then
		return nil
	end
	local minTiles = self.player:numTilesOwned() * RIVAL_MIN_TILE_RATIO
	local best = nil
	for _, p in validMirvTargets(self.game, self.player) do
		if not self.player:isFriendly(p) and p:numTilesOwned() >= minTiles then
			if best == nil or p:numTilesOwned() > best:numTilesOwned() then
				if self.player:sharesBorderWith(p) then
					best = p
				end
			end
		end
	end
	return best
end

function NationMIRVBehavior._wasRecentlyMirved(self: NationMIRVBehavior, target: any): boolean
	local last = self.game:nationMirvTargets()[target:id()]
	if last == nil then
		return false
	end
	return self.game:ticks() - last < MIRV_COOLDOWN_TICKS
end

function NationMIRVBehavior._isInboundMIRVFrom(self: NationMIRVBehavior, attacker: any): boolean
	local game = self.game
	for _, mirv in attacker:units(UnitType.MIRV) do
		local dst = mirv:targetTile()
		if dst ~= nil and dst ~= 0 and game:hasOwner(dst) and game:owner(dst) == self.player then
			return true
		end
	end
	return false
end

function NationMIRVBehavior._maybeSendMIRV(self: NationMIRVBehavior, enemy: any)
	local game, player = self.game, self.player
	-- Conquest: bombs on a human wait for RoWorld's grace and limit.
	if HumanProtection.nukeOffLimits(game, player, enemy) then
		return
	end
	self.emojiBehavior:maybeSendAttackEmoji(enemy)
	local center = ExecUtil.calculateTerritoryCenter(game, enemy)
	if center ~= nil and center ~= 0 then
		local spawn = player:canBuild(UnitType.MIRV, center)
		if spawn ~= false and spawn ~= 0 then
			game:addExecution(require(script.Parent.Parent.MIRVExecution).new(player, center))
			game:nationMirvTargets()[enemy:id()] = game:ticks()
			self.emojiBehavior:sendEmoji(AllPlayers, Emoji.NUKE)
			require(script.Parent.NationEmojiBehavior).respondToMIRV(game, self.random, enemy)
		end
	end
end

return NationMIRVBehavior
