--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/configuration/EngineConfig.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Config plus the tunables only the simulation reads: attack resolution,
-- costs, warships, nukes and trade. Gold is an integer-valued number (BigInt
-- in OpenFront).

local Config = require(script.Parent.Config)
local DetMath = require(script.Parent.DetMath)
local GameTypes = require(script.Parent.GameTypes)
local Util = require(script.Parent.Util)

local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType
local TerrainType = GameTypes.TerrainType
local UnitType = GameTypes.UnitType
local sigmoid = Util.sigmoid
local within = Util.within
local toInt = Util.toInt

local LN2 = 0.6931471805599453 -- Math.LN2

export type AttackLogicInput = {
	terrain: number,
	attackTroops: number,
	attacker: { type: string, numTiles: number },
	-- nil when attacking terra nullius
	defender: {
		type: string,
		numTiles: number,
		troops: number,
		isTraitor: boolean,
		-- defender is disconnected and on the attacker's team
		isDisconnectedTeammate: boolean,
	}?,
	-- a defence post owned by the defender is in range of the tile
	defenderHasDefensePost: boolean,
	-- fraction of land tiles with fallout, or nil if the tile has no fallout
	falloutRatio: number?,
	-- tiles on the attack front this tick (plus jitter); fixed for the tick
	borderSize: number,
}

export type AttackLogicResult = {
	attackerTroopLoss: number,
	defenderTroopLoss: number,
	-- share of this tick's conquest budget the tile consumes
	tickFraction: number,
}

-- attackLogic tunables (EngineConfig.ts explains each)
local LARGE_TERRITORY_MIDPOINT = 300_000
local LARGE_TERRITORY_STEEPNESS = 2.5
local LARGE_ATTACKER_DEPTH = 0.7
local LARGE_DEFENDER_DEPTH = 0.3
local BOT_DEFENDER_LOSS_MULT = 0.7
local TERRA_NULLIUS_COST_SCALE = 2000
local TERRA_NULLIUS_MIN_COST = 5
local TERRA_NULLIUS_MAX_COST = 100
local ATTACKER_LOSS_BASE = 0.463
-- defender troops per attacking troop at or below which attacker losses stop shrinking
local CHEAPEST_TROOP_RATIO = 0.6
local ATTACKER_LOSS_PER_DENSITY = 0.0039
local SPEED_COST_DIVISOR = 8.55
local LARGE_ATTACKER_SPEED_DEPTH = 0.73

-- EngineConfig.ts largeTerritoryBonus: logistic in log(tiles), ~1 for small
-- territories, easing to 1 - depth for huge ones.
local function largeTerritoryBonus(numTiles: number, depth: number): number
	return 1 - depth * sigmoid(DetMath.log(numTiles), LARGE_TERRITORY_STEEPNESS, DetMath.log(LARGE_TERRITORY_MIDPOINT))
end

-- EngineConfig.ts terrainAttackBase
local function terrainAttackBase(terrain: number): (number, number)
	if terrain == TerrainType.Plains then
		return 80, 16.5
	elseif terrain == TerrainType.Highland then
		return 100, 20
	elseif terrain == TerrainType.Mountain then
		return 120, 25
	elseif terrain == TerrainType.Impassable then
		error("impassable terrain cannot be attacked")
	end
	error(`terrain type {terrain} not supported`)
end

local EngineConfig = {}
EngineConfig.__index = EngineConfig
EngineConfig.CHEAPEST_TROOP_RATIO = CHEAPEST_TROOP_RATIO
-- Inherit Config's methods (EngineConfig extends Config).
for name, value in Config :: any do
	if EngineConfig[name] == nil and name ~= "__index" and name ~= "new" then
		EngineConfig[name] = value
	end
end

export type CostFn = (game: any, player: any, extraUnits: number?) -> number

export type EngineConfig = Config.Config & {
	_costCache: { [string]: CostFn },
	[string]: any,
}

function EngineConfig.new(gameConfig: Config.GameConfig, isReplay: boolean, listed: boolean?, spectator: boolean?): EngineConfig
	local self: any = Config.new(gameConfig, isReplay, listed, spectator)
	self._costCache = {}
	return setmetatable(self, EngineConfig) :: any
end

function EngineConfig.traitorSpeedDebuff(_self: EngineConfig): number
	return 0.8
end

function EngineConfig.teamLandShareWinThresholdTenths(_self: EngineConfig): number
	return 7
end

-- falloutRatio is between 0 and 1, so the modifier is between 5 and 3
function EngineConfig.falloutDefenseModifier(_self: EngineConfig, falloutRatio: number): number
	return 5 - falloutRatio * 2
end

function EngineConfig.defensePostDefenseBonus(_self: EngineConfig): number
	return 5
end

function EngineConfig.defensePostSpeedBonus(_self: EngineConfig): number
	return 3
end

function EngineConfig.playerTeams(self: EngineConfig): any
	return self._gameConfig.playerTeams or 0
end

function EngineConfig.spawnNations(self: EngineConfig): boolean
	return self._gameConfig.nations ~= "disabled"
end

function EngineConfig.bots(self: EngineConfig): number
	return self._gameConfig.bots or 0
end

function EngineConfig.disableNavMesh(self: EngineConfig): boolean
	return self._gameConfig.disableNavMesh == true
end

function EngineConfig.waterNukes(self: EngineConfig): boolean
	return self._gameConfig.waterNukes == true
end

function EngineConfig.infiniteGold(self: EngineConfig): boolean
	return self._gameConfig.infiniteGold == true
end

function EngineConfig.donateGold(self: EngineConfig): boolean
	return self._gameConfig.donateGold == true
end

function EngineConfig.goldMultiplier(self: EngineConfig): number
	return self._gameConfig.goldMultiplier or 1
end

function EngineConfig.startingGold(self: EngineConfig, playerInfo: { playerType: string, isLobbyCreator: boolean? }): number
	if playerInfo.playerType == PlayerType.Bot then
		return 0
	end
	return self:_startingGoldFor(playerInfo)
end

-- EngineConfig.ts trainSaturation: global spawn throttle for the train economy.
function EngineConfig.trainSaturation(_self: EngineConfig, numTrainUnits: number): number
	local damping = 1 - sigmoid(numTrainUnits, LN2 / 100, 560)
	local plateau = 0.25 * (1 - sigmoid(numTrainUnits, LN2 / 150, 900))
	return math.max(damping, plateau)
end

function EngineConfig.trainSpawnRate(self: EngineConfig, numPlayerFactories: number, numTrainUnits: number): number
	-- hyperbolic decay, midpoint at 10 factories
	local rate = (numPlayerFactories + 10) * 15
	local boost = self:smallEconomySpawnBoost(numPlayerFactories)
	return math.max(1, math.floor(rate / (self:trainSaturation(numTrainUnits) * boost)))
end

-- Per-unit spawn multiplier for a player's first few port or factory levels.
function EngineConfig.smallEconomySpawnBoost(_self: EngineConfig, levels: number): number
	if levels <= 0 then
		return 1
	end
	return 1 + (0.5 * within((6 - levels) / 5, 0, 1)) / levels
end

function EngineConfig.trainGold(self: EngineConfig, rel: string, citiesVisited: number, player: Config.PlayerLike): number
	-- No penalty for the first 10 cities.
	citiesVisited = math.max(0, citiesVisited - 9)
	local baseGold
	if rel == "ally" then
		baseGold = 35_000
	elseif rel == "team" or rel == "other" then
		baseGold = 25_000
	elseif rel == "self" then
		baseGold = 10_000
	else
		error(`unknown relation {rel}`)
	end
	local distPenalty = citiesVisited * 5_000
	local gold = math.max(5000, baseGold - distPenalty)
	return toInt(gold * self:_goldMultiplierFor(player))
end

function EngineConfig.trainStationMinRange(_self: EngineConfig): number
	return 15
end

function EngineConfig.railroadMaxSize(self: EngineConfig): number
	return self:trainStationMaxRange() * 1.4142
end

-- Sigmoid: concave start, sharp middle, linear end.
function EngineConfig.tradeShipGold(self: EngineConfig, dist: number, player: Config.PlayerLike): number
	local debuff = self:tradeShipShortRangeDebuff()
	local baseGold = 75_000 / (1 + DetMath.exp(-0.03 * (dist - debuff))) + 50 * dist
	return math.floor(baseGold * self:_goldMultiplierFor(player))
end

-- Global spawn throttle for the trade-ship economy.
function EngineConfig.tradeShipSaturation(_self: EngineConfig, numTradeShips: number): number
	local damping = 1 - sigmoid(numTradeShips, LN2 / 50, 330)
	local plateau = 0.25 * (1 - sigmoid(numTradeShips, LN2 / 100, 800))
	return math.max(damping, plateau)
end

-- Probability of a trade ship spawn = 1 / tradeShipSpawnRate
function EngineConfig.tradeShipSpawnRate(
	self: EngineConfig,
	tradeShipSpawnRejections: number,
	numTradeShips: number,
	playerPortLevels: number
): number
	-- Pity timer: increases spawn chance after consecutive rejections
	local rejectionModifier = 1 / (tradeShipSpawnRejections + 1)
	local boost = self:smallEconomySpawnBoost(playerPortLevels)
	local base = 100 / (boost * boost)
	return math.max(1, math.floor((base * rejectionModifier) / self:tradeShipSaturation(numTradeShips)))
end

function EngineConfig._hasInfiniteGoldFor(self: EngineConfig, player: Config.PlayerLike): boolean
	if self:infiniteGold() then
		return true
	end
	local hc = self._gameConfig.hostCheats
	return hc ~= nil and hc.infiniteGold == true and player:isLobbyCreator()
end

-- EngineConfig.ts unitInfo: Config's info plus `cost`.
function EngineConfig.unitInfo(self: EngineConfig, unitType: string): { [string]: any }
	local cached = self._costCache[unitType]
	local info = table.clone(Config.unitInfo(self :: any, unitType))
	if cached == nil then
		cached = self:_unitCost(unitType)
		self._costCache[unitType] = cached
	end
	info.cost = cached
	return info
end

function EngineConfig._unitCost(self: EngineConfig, unitType: string): CostFn
	if unitType == UnitType.Warship then
		return self:_costWrapper(function(n: number): number
			return math.min(1_000_000, (n + 1) * 250_000)
		end, { UnitType.Warship })
	elseif unitType == UnitType.Port then
		return self:_costWrapper(function(n: number): number
			return math.min(1_000_000, DetMath.pow2(n) * 125_000)
		end, { UnitType.Port, UnitType.Factory })
	elseif unitType == UnitType.AtomBomb then
		return self:_costWrapper(function(_n: number): number
			return 750_000
		end, { UnitType.AtomBomb })
	elseif unitType == UnitType.HydrogenBomb then
		return self:_costWrapper(function(_n: number): number
			return 5_000_000
		end, { UnitType.HydrogenBomb })
	elseif unitType == UnitType.MegaNuke then
		-- Conquest's Arsenal.
		return self:_costWrapper(function(_n: number): number
			return 2_500_000
		end, { UnitType.MegaNuke })
	elseif unitType == UnitType.Scattershot then
		-- Conquest's Arsenal: 3.75M a launch (RoWorld's).
		return self:_costWrapper(function(_n: number): number
			return 3_750_000
		end, { UnitType.Scattershot })
	elseif unitType == UnitType.Airfield then
		-- Conquest's Arsenal: 500K, +500K each, at most 1.5M (RoWorld's).
		return self:_costWrapper(function(n: number): number
			return math.min(1_500_000, (n + 1) * 500_000)
		end, { UnitType.Airfield })
	elseif unitType == UnitType.Railgun then
		-- 2.5M, +2.5M each, at most 7.5M (RoWorld's).
		return self:_costWrapper(function(n: number): number
			return math.min(7_500_000, (n + 1) * 2_500_000)
		end, { UnitType.Railgun })
	elseif unitType == UnitType.Artillery then
		-- Conquest's Arsenal: 150K, +150K for each battery owned, at most 750K (RoWorld's).
		return self:_costWrapper(function(n: number): number
			return math.min(750_000, (n + 1) * 150_000)
		end, { UnitType.Artillery })
	elseif unitType == UnitType.CoastalBattery then
		-- Our own Arsenal item (ARSENAL_V2): 400K, +400K each, at most 1.2M.
		return self:_costWrapper(function(n: number): number
			return math.min(1_200_000, (n + 1) * 400_000)
		end, { UnitType.CoastalBattery })
	elseif unitType == UnitType.FieldWorks then
		-- Our own Arsenal item (ARSENAL_V2): 100K, flat.
		return self:_costWrapper(function(_n: number): number
			return 100_000
		end, { UnitType.FieldWorks })
	elseif unitType == UnitType.Sabotage then
		-- Our own Arsenal item (ARSENAL_V2): 500K an operation.
		return self:_costWrapper(function(_n: number): number
			return 500_000
		end, { UnitType.Sabotage })
	elseif unitType == UnitType.Paratroopers then
		-- Our own Arsenal item (ARSENAL_V2): 250K a drop.
		return self:_costWrapper(function(_n: number): number
			return 250_000
		end, { UnitType.Paratroopers })
	elseif unitType == UnitType.MIRV then
		return function(game: any, player: any): number
			if player:type() == PlayerType.Human and self:_hasInfiniteGoldFor(player) then
				return 0
			end
			return 25_000_000 + game:mirvsLaunched() * 15_000_000
		end
	elseif unitType == UnitType.MissileSilo then
		return self:_costWrapper(function(_n: number): number
			return 1_000_000
		end, { UnitType.MissileSilo })
	elseif unitType == UnitType.DefensePost then
		return self:_costWrapper(function(n: number): number
			return math.min(250_000, (n + 1) * 50_000)
		end, { UnitType.DefensePost })
	elseif unitType == UnitType.SAMLauncher then
		return self:_costWrapper(function(n: number): number
			return math.min(3_000_000, (n + 1) * 1_500_000)
		end, { UnitType.SAMLauncher })
	elseif unitType == UnitType.City then
		return self:_costWrapper(function(n: number): number
			return math.min(1_000_000, DetMath.pow2(n) * 125_000)
		end, { UnitType.City })
	elseif unitType == UnitType.Factory then
		return self:_costWrapper(function(n: number): number
			return math.min(1_000_000, DetMath.pow2(n) * 125_000)
		end, { UnitType.Factory, UnitType.Port })
	elseif
		unitType == UnitType.TransportShip
		or unitType == UnitType.Shell
		or unitType == UnitType.SAMMissile
		or unitType == UnitType.MIRVWarhead
		or unitType == UnitType.TradeShip
		or unitType == UnitType.Train
		or unitType == UnitType.ArtilleryShell
		or unitType == UnitType.AirStrike -- the Airfield is the price
		or unitType == UnitType.RailgunShot
	then
		return function(): number
			return 0
		end
	end
	error(`unknown unit type {unitType}`)
end

function EngineConfig._hasInfiniteTroopsForInfo(self: EngineConfig, playerInfo: { isLobbyCreator: boolean? }): boolean
	if self:infiniteTroops() then
		return true
	end
	local hc = self._gameConfig.hostCheats
	return hc ~= nil and hc.infiniteTroops == true and playerInfo.isLobbyCreator == true
end

function EngineConfig._goldMultiplierFor(self: EngineConfig, player: Config.PlayerLike): number
	local base = self:goldMultiplier()
	local hc = self._gameConfig.hostCheats
	if hc and hc.goldMultiplier and player:isLobbyCreator() then
		return hc.goldMultiplier
	end
	return base
end

function EngineConfig.conquerGoldAmount(_self: EngineConfig, captured: Config.PlayerLike): number
	if captured:type() == PlayerType.Bot or captured:type() == PlayerType.Nation then
		return captured:gold()
	end
	return math.floor(captured:gold() / 2) -- BigInt division truncates
end

function EngineConfig._startingGoldFor(self: EngineConfig, playerInfo: { isLobbyCreator: boolean? }): number
	local base = self._gameConfig.startingGold or 0
	local hc = self._gameConfig.hostCheats
	if hc and hc.startingGold and playerInfo.isLobbyCreator then
		return base + hc.startingGold
	end
	return base
end

-- EngineConfig.ts costWrapper: price from how many of the given kinds the
-- player owns (counting only constructed ones).
function EngineConfig._costWrapper(self: EngineConfig, costFn: (number) -> number, types: { string }): CostFn
	return function(_game: any, player: any, extraUnits: number?): number
		if player:type() == PlayerType.Human and self:_hasInfiniteGoldFor(player) then
			return 0
		end
		local numUnits = 0
		for _, t in types do
			numUnits += math.min(player:unitsOwned(t), player:unitsConstructed(t))
		end
		return math.floor(costFn(numUnits + (extraUnits or 0)))
	end
end

function EngineConfig.defaultDonationAmount(_self: EngineConfig, sender: Config.PlayerLike): number
	return math.floor(sender:troops() / 3)
end

function EngineConfig.donateCooldown(_self: EngineConfig): number
	return 10 * 10
end

function EngineConfig.embargoAllCooldown(_self: EngineConfig): number
	return 10 * 10
end

function EngineConfig.emojiMessageDuration(_self: EngineConfig): number
	return 5 * 10
end

-- the window emojiMessageLimit counts over
function EngineConfig.emojiMessageWindow(_self: EngineConfig): number
	return 5 * 10
end

-- emojis a human can send one recipient (or everyone) per window
function EngineConfig.emojiMessageLimit(_self: EngineConfig): number
	return 5
end

function EngineConfig.quickChatCooldown(_self: EngineConfig): number
	return 3 * 10
end

function EngineConfig.targetDuration(_self: EngineConfig): number
	return 10 * 10
end

function EngineConfig.targetCooldown(_self: EngineConfig): number
	return 15 * 10
end

function EngineConfig.allianceRequestCooldown(_self: EngineConfig): number
	return 30 * 10
end

function EngineConfig.temporaryEmbargoDuration(_self: EngineConfig): number
	return 300 * 10 -- 5 minutes
end

function EngineConfig.minDistanceBetweenPlayers(_self: EngineConfig): number
	return 30
end

function EngineConfig.boatMaxNumber(self: EngineConfig): number
	if self:isUnitDisabled(UnitType.TransportShip) then
		return 0
	end
	return 3
end

function EngineConfig.numBots(self: EngineConfig): number
	return self:bots()
end

-- EngineConfig.ts attackLogic: the per-tile attack outcome. Pure.
--   mag: how bloody the tile is (attacker troop loss)
--   tileCost: how expensive the tile is to take (higher = slower)
function EngineConfig.attackLogic(self: EngineConfig, input: AttackLogicInput): AttackLogicResult
	local attackTroops, attacker, defender = input.attackTroops, input.attacker, input.defender
	local mag, tileCost = terrainAttackBase(input.terrain)

	if defender ~= nil and input.defenderHasDefensePost then
		mag *= self:defensePostDefenseBonus()
		tileCost *= self:defensePostSpeedBonus()
	end
	if input.falloutRatio ~= nil then
		local fallout = self:falloutDefenseModifier(input.falloutRatio)
		mag *= fallout
		tileCost *= fallout
	end

	if defender == nil then
		local tickBudget = input.borderSize * 2
		return {
			attackerTroopLoss = mag / (if attacker.type == PlayerType.Bot then 10 else 5),
			defenderTroopLoss = 0,
			tickFraction = within(
				(TERRA_NULLIUS_COST_SCALE * tileCost) / attackTroops,
				TERRA_NULLIUS_MIN_COST,
				TERRA_NULLIUS_MAX_COST
			) / tickBudget,
		}
	end

	if defender.isDisconnectedTeammate then
		-- No troop loss if defender is disconnected and on same team
		mag = 0
	end
	if (attacker.type == PlayerType.Human or attacker.type == PlayerType.Nation) and defender.type == PlayerType.Bot then
		mag *= BOT_DEFENDER_LOSS_MULT
	end

	-- Big territories are cheaper and faster to attack from and into.
	local largeAttackerBonus = largeTerritoryBonus(attacker.numTiles, LARGE_ATTACKER_DEPTH)
	local largeDefenderBonus = largeTerritoryBonus(defender.numTiles, LARGE_DEFENDER_DEPTH)

	local traitorLossMod = if defender.isTraitor then self:traitorDefenseDebuff() else 1
	local traitorCostMod = if defender.isTraitor then self:traitorSpeedDebuff() else 1

	-- Defender loses its average troops-per-tile.
	local defenderTroopLoss = defender.troops / defender.numTiles

	local troopRatio = defender.troops / attackTroops
	local attackerTroopLoss = mag
		* traitorLossMod
		* within(troopRatio, CHEAPEST_TROOP_RATIO, 2)
		* (ATTACKER_LOSS_BASE * largeAttackerBonus * largeDefenderBonus + ATTACKER_LOSS_PER_DENSITY * defenderTroopLoss)

	-- Speed: floored at 0.82 below parity, linear to 7.5x, second ramp past 20x.
	local speedCost = (within(troopRatio, 0.82, 7.5) * within(troopRatio / 20, 1, 50)) / SPEED_COST_DIVISOR
	local largeAttackerSpeedBonus = largeTerritoryBonus(attacker.numTiles, LARGE_ATTACKER_SPEED_DEPTH)
	return {
		attackerTroopLoss = attackerTroopLoss,
		defenderTroopLoss = defenderTroopLoss,
		tickFraction = (speedCost * tileCost * largeAttackerSpeedBonus * largeDefenderBonus * traitorCostMod)
			/ input.borderSize,
	}
end

function EngineConfig.boatAttackAmount(_self: EngineConfig, attacker: Config.PlayerLike, _defender: any): number
	return math.floor(attacker:troops() / 5)
end

function EngineConfig.warshipShellLifetime(_self: EngineConfig): number
	return 20 -- ticks
end

function EngineConfig.radiusPortSpawn(_self: EngineConfig): number
	return 20
end

function EngineConfig.tradeShipShortRangeDebuff(_self: EngineConfig): number
	return 300
end

function EngineConfig.proximityBonusPortsNb(_self: EngineConfig, totalPorts: number): number
	return within(totalPorts / 3, 4, totalPorts)
end

function EngineConfig.attackAmount(_self: EngineConfig, attacker: Config.PlayerLike, _defender: any): number
	if attacker:type() == PlayerType.Bot then
		return attacker:troops() / 20
	end
	return attacker:troops() / 5
end

function EngineConfig.startManpower(self: EngineConfig, playerInfo: { playerType: string, isLobbyCreator: boolean? }): number
	if playerInfo.playerType == PlayerType.Bot then
		return 10_000
	end
	if playerInfo.playerType == PlayerType.Nation then
		local difficulty = self._gameConfig.difficulty
		if difficulty == Difficulty.Easy then
			return 12_500
		elseif difficulty == Difficulty.Medium then
			return 18_750
		elseif difficulty == Difficulty.Hard then
			return 25_000 -- Like humans
		elseif difficulty == Difficulty.Impossible then
			return 31_250
		end
		error(`unknown difficulty {difficulty}`)
	end
	return if self:_hasInfiniteTroopsForInfo(playerInfo) then 1_000_000 else 25_000
end

function EngineConfig.goldAdditionRate(self: EngineConfig, player: Config.PlayerLike): number
	local multiplier = self:_goldMultiplierFor(player)
	local baseRate = if player:type() == PlayerType.Bot then 50 else 100
	return math.floor(baseRate * multiplier)
end

function EngineConfig.nukeSpeed(_self: EngineConfig, unitType: string): number
	if unitType == UnitType.AtomBomb or unitType == UnitType.HydrogenBomb or unitType == UnitType.Scattershot then
		return 10
	elseif unitType == UnitType.MegaNuke then
		return 7 -- Conquest: slower, so the target sees it coming longer
	elseif unitType == UnitType.MIRV then
		return 15
	elseif unitType == UnitType.MIRVWarhead then
		return 22
	end
	error(`Unknown nuke type: {unitType}`)
end

function EngineConfig.mirvNormalizeTargetTicks(_self: EngineConfig): number
	return 14
end

function EngineConfig.defaultNukeTargetableRange(_self: EngineConfig): number
	return 150
end

function EngineConfig.defaultSamRange(_self: EngineConfig): number
	return 70
end

function EngineConfig.samUpgradeDuration(self: EngineConfig): number
	return math.floor(self:SAMCooldown() / 2)
end

-- sam: a unit with samLauncherState() and level()
function EngineConfig.dynamicSamRange(self: EngineConfig, sam: any, currentTick: number): number
	local state = sam:samLauncherState()
	if state == nil or state.upgradeStartTick == nil then
		return self:samRange(sam:level())
	end
	local duration = state.duration or self:samUpgradeDuration()
	local elapsed = currentTick - state.upgradeStartTick
	if elapsed >= duration then
		return self:samRange(state.targetLevel)
	end
	local targetRange = self:samRange(state.targetLevel)
	local diff = targetRange - state.startRange
	return state.startRange + (diff * elapsed) / duration
end

function EngineConfig.defaultSamMissileSpeed(_self: EngineConfig): number
	return 12
end

-- Humans can be soldiers, soldiers attacking, soldiers in boat etc.
function EngineConfig.nukeDeathFactor(
	_self: EngineConfig,
	nukeType: string,
	humans: number,
	tilesOwned: number,
	maxTroops: number
): number
	if nukeType ~= UnitType.MIRVWarhead then
		return (5 * humans) / math.max(1, tilesOwned)
	end
	local targetTroops = 0.03 * maxTroops
	local excessTroops = math.max(0, humans - targetTroops)
	local scalingFactor = 500
	local steepness = 2
	local normalizedExcess = excessTroops / maxTroops
	return scalingFactor * (1 - DetMath.exp(-steepness * normalizedExcess))
end

function EngineConfig.shellLifetime(_self: EngineConfig): number
	return 50
end

function EngineConfig.warshipPatrolRange(_self: EngineConfig): number
	return 100
end

function EngineConfig.warshipTargettingRange(_self: EngineConfig): number
	return 130
end

function EngineConfig.warshipShellAttackRate(_self: EngineConfig): number
	return 20
end

function EngineConfig.warshipDockingRange(_self: EngineConfig): number
	return 5
end

function EngineConfig.warshipPortHealingBonusPerLevel(_self: EngineConfig): number
	return 5
end

-- health at or below which a warship retreats to repair, percent of max health
function EngineConfig.warshipRetreatHealthPercent(_self: EngineConfig): number
	return 75
end

function EngineConfig.warshipPassiveHealing(_self: EngineConfig): number
	return 1
end

function EngineConfig.warshipPassiveHealingRange(_self: EngineConfig): number
	return 150
end

function EngineConfig.warshipPortSwitchThreshold(_self: EngineConfig): number
	return 0.75
end

function EngineConfig.warshipMaxVeterancy(_self: EngineConfig): number
	return 3
end

-- shell-damage boost per veterancy level, integer percent
function EngineConfig.warshipVeterancyShellDamageBonus(_self: EngineConfig): number
	return 20
end

-- transport ships a warship must destroy to gain one veterancy level
function EngineConfig.warshipVeterancyTransportKills(_self: EngineConfig): number
	return 10
end

-- trade ships a warship must capture to gain one veterancy level
function EngineConfig.warshipVeterancyTradeCaptures(_self: EngineConfig): number
	return 25
end

function EngineConfig.defensePostShellAttackRate(_self: EngineConfig): number
	return 100
end

function EngineConfig.safeFromPiratesCooldownMax(_self: EngineConfig): number
	return 20
end

function EngineConfig.defensePostTargettingRange(_self: EngineConfig): number
	return 75
end

return EngineConfig
