--!strict
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/configuration/Config.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The rules every part of the game reads. EngineConfig.luau extends it with
-- what only the simulation needs. Methods keep OpenFront's names, and a
-- player is anything with the PlayerLike methods below.

local DetMath = require(script.Parent.DetMath)
local GameTypes = require(script.Parent.GameTypes)
local StructureDamage = require(script.Parent.StructureDamage)

local Difficulty = GameTypes.Difficulty
local GameType = GameTypes.GameType
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

export type UnitLike = {
	isUnderConstruction: (self: any) -> boolean,
	level: (self: any) -> number,
}

export type PlayerLike = {
	type: (self: any) -> string,
	numTilesOwned: (self: any) -> number,
	troops: (self: any) -> number,
	gold: (self: any) -> number,
	units: (self: any, unitType: string) -> { UnitLike },
	isLobbyCreator: (self: any) -> boolean,
}

-- The subset of OpenFront's GameConfig the rules read (Schemas.ts GameConfig).
export type GameConfig = {
	difficulty: string,
	gameType: string?,
	gameMode: string?,
	gameMapSize: string?,
	playerTeams: any?,
	nations: string?,
	bots: number?,
	infiniteGold: boolean?,
	infiniteTroops: boolean?,
	donateGold: boolean?,
	donateTroops: boolean?,
	instantBuild: boolean?,
	randomSpawn: boolean?,
	disableNavMesh: boolean?,
	waterNukes: boolean?,
	goldMultiplier: number?,
	startingGold: number?,
	disabledUnits: { string }?,
	customAllianceDuration: number?,
	disableAlliances: boolean?,
	spawnImmunityDuration: number?,
	extraWeapons: boolean?, -- Conquest's Arsenal
	-- Conquest: RoWorld's AI layer, off in OpenFront's own rules (HumanProtection.luau).
	humanGrace: boolean?,
	humanWarLimit: boolean?,
	humanSkip: boolean?,
	capitulation: boolean?,
	-- Conquest: a boat landing on land already ours returns all its troops.
	boatFullRefund: boolean?,
	maxTimerValue: number?,
	doomsdayClock: { enabled: boolean?, speed: string? }?,
	overtime: { enabled: boolean?, startMinutes: number? }?,
	hostCheats: { infiniteGold: boolean?, infiniteTroops: boolean?, goldMultiplier: number?, startingGold: number? }?,
}

local DEFAULT_SPAWN_IMMUNITY_TICKS = 5 * 10

-- SAM launcher construction duration in ticks (non-instant-build).
local SAM_CONSTRUCTION_TICKS = 30 * 10

-- Doomsday Clock tunables (anti-stall); see Config.ts for the timeline.
local DOOMSDAY_CLOCK_DEFAULTS = table.freeze({
	enabled = false,
	speed = "normal",
	warnSeconds = 30,
	drainStartPercent = 2,
	drainMaxPercent = 5,
	drainRampSeconds = 90,
	drainFloorPercent = 5,
	floorStartPercent = 40,
	floorDecaySeconds = 90,
	rotDeathSeconds = 150,
	rotGrainSeconds = 10,
	rotSpecklePercent = 15,
	warshipDrainStartPercent = 1,
	warshipDrainMaxPercent = 50,
	warshipDrainCurveExponent = 8,
})

-- Share of the land a side must hold to win, in every game mode.
local PERCENT_TILES_OWNED_TO_WIN = 80

-- Overtime tunables (anti-stalemate). Off unless enabled in GameConfig.
local OVERTIME_DEFAULTS = table.freeze({
	enabled = false,
	startMinutes = 30,
	dropPercentPerMinute = 2,
})

local Config = {}
Config.__index = Config
Config.SAM_CONSTRUCTION_TICKS = SAM_CONSTRUCTION_TICKS

export type Config = typeof(setmetatable(
	{} :: {
		_gameConfig: GameConfig,
		_isReplay: boolean,
		listed: boolean,
		_spectator: boolean,
		_unitInfoCache: { [string]: { [string]: any } },
	},
	Config
))

function Config.new(gameConfig: GameConfig, isReplay: boolean, listed: boolean?, spectator: boolean?): Config
	return setmetatable({
		_gameConfig = gameConfig,
		_isReplay = isReplay,
		listed = listed or false,
		_spectator = spectator or false,
		_unitInfoCache = {},
	}, Config)
end

function Config.isReplay(self: Config): boolean
	return self._isReplay
end

function Config.isIntentionalSpectator(self: Config): boolean
	return self._spectator
end

function Config.traitorDefenseDebuff(_self: Config): number
	return 0.5
end

function Config.traitorDuration(_self: Config): number
	return 30 * 10 -- 30 seconds
end

function Config.doomsdayClockConfig(self: Config): typeof(DOOMSDAY_CLOCK_DEFAULTS)
	local c = self._gameConfig.doomsdayClock
	local d = table.clone(DOOMSDAY_CLOCK_DEFAULTS)
	if c then
		if c.enabled ~= nil then
			d.enabled = c.enabled
		end
		if c.speed ~= nil then
			d.speed = c.speed
		end
	end
	-- Drain/warn tuning is internal (not wire-configurable): always defaults.
	return d
end

function Config.overtimeConfig(self: Config): typeof(OVERTIME_DEFAULTS)
	local c = self._gameConfig.overtime
	local d = table.clone(OVERTIME_DEFAULTS)
	if c then
		if c.enabled ~= nil then
			d.enabled = c.enabled
		end
		if c.startMinutes ~= nil then
			d.startMinutes = c.startMinutes
		end
	end
	return d
end

function Config.spawnImmunityDuration(self: Config): number
	return self._gameConfig.spawnImmunityDuration or DEFAULT_SPAWN_IMMUNITY_TICKS
end

function Config.nationSpawnImmunityDuration(_self: Config): number
	return DEFAULT_SPAWN_IMMUNITY_TICKS
end

function Config.hasExtendedSpawnImmunity(self: Config): boolean
	return self:spawnImmunityDuration() > DEFAULT_SPAWN_IMMUNITY_TICKS
end

function Config.gameConfig(self: Config): GameConfig
	return self._gameConfig
end

function Config.cityTroopIncrease(_self: Config): number
	return 250_000
end

function Config.msPerTick(_self: Config): number
	return 100
end

function Config.SAMCooldown(_self: Config): number
	return 90
end

function Config.SiloCooldown(_self: Config): number
	return 90
end

function Config.defensePostRange(_self: Config): number
	return 30
end

function Config.isUnitDisabled(self: Config, unitType: string): boolean
	local disabled = self._gameConfig.disabledUnits
	return disabled ~= nil and table.find(disabled, unitType) ~= nil
end

function Config.instantBuild(self: Config): boolean
	return self._gameConfig.instantBuild == true
end

function Config.disableAlliances(self: Config): boolean
	-- customAllianceDuration == 0 disables alliances; the legacy boolean still counts.
	return self._gameConfig.customAllianceDuration == 0 or self._gameConfig.disableAlliances == true
end

-- Conquest's Arsenal (docs/design/rofront-ui-pass.md): weapons beyond
-- OpenFront, on only when the match turns them on; each player still needs
-- the unlock (PlayerInfo.weapons). Off in every OpenFront parity case.
function Config.extraWeapons(self: Config): boolean
	return self._gameConfig.extraWeapons == true
end

Config.REINFORCE_SHARE = 0.2 -- of the troop limit
Config.REINFORCE_GOLD = 100_000
Config.REINFORCE_COOLDOWN = 30 * 10 -- ticks
-- Artillery's reach in tiles (ARSENAL_V2; RoWorld's 45). The renderer draws
-- its range ring from this.
Config.ARTILLERY_RANGE = 45
-- The Coastal Battery's reach in tiles (ARSENAL_V2, our own).
Config.COASTAL_RANGE = 40

function Config.isRandomSpawn(self: Config): boolean
	return self._gameConfig.randomSpawn == true
end

function Config.infiniteTroops(self: Config): boolean
	return self._gameConfig.infiniteTroops == true
end

function Config.donateTroops(self: Config): boolean
	return self._gameConfig.donateTroops == true
end

function Config.trainStationMaxRange(_self: Config): number
	return 110
end

-- Config.ts unitInfo. EngineConfig adds `cost`.
function Config.unitInfo(self: Config, unitType: string): { [string]: any }
	local cached = self._unitInfoCache[unitType]
	if cached then
		return cached
	end
	local instant = self:instantBuild()
	local info: { [string]: any }
	if unitType == UnitType.Warship then
		info = { maxHealth = 1000 }
	elseif unitType == UnitType.Shell then
		info = { damage = 250 }
	elseif unitType == UnitType.Port then
		info = { constructionDuration = if instant then 0 else 5 * 10, upgradable = true }
	elseif unitType == UnitType.MissileSilo then
		info = { constructionDuration = if instant then 0 else 10 * 10, upgradable = true }
	elseif unitType == UnitType.DefensePost then
		info = { constructionDuration = if instant then 0 else 5 * 10 }
	elseif unitType == UnitType.SAMLauncher then
		info = { constructionDuration = if instant then 0 else SAM_CONSTRUCTION_TICKS, upgradable = true }
	elseif unitType == UnitType.City or unitType == UnitType.Factory then
		info = { constructionDuration = if instant then 0 else 2 * 10, upgradable = true }
	elseif unitType == UnitType.Artillery then
		-- Conquest's Arsenal: 8 s to build, not upgradable (RoWorld's).
		info = { constructionDuration = if instant then 0 else 8 * 10 }
	elseif unitType == UnitType.Airfield then
		-- Conquest's Arsenal: 10 s and 15 s to build, not upgradable (RoWorld's).
		info = { constructionDuration = if instant then 0 else 10 * 10 }
	elseif unitType == UnitType.Railgun then
		info = { constructionDuration = if instant then 0 else 15 * 10 }
	elseif unitType == UnitType.CoastalBattery then
		-- Our own (ARSENAL_V2): 8 s to build, not upgradable.
		info = { constructionDuration = if instant then 0 else 8 * 10 }
	elseif unitType == UnitType.ArtilleryShell or unitType == UnitType.AirStrike or unitType == UnitType.RailgunShot or unitType == UnitType.Paratroopers or unitType == UnitType.Sabotage or unitType == UnitType.FieldWorks then
		info = {}
	elseif
		unitType == UnitType.TransportShip
		or unitType == UnitType.SAMMissile
		or unitType == UnitType.AtomBomb
		or unitType == UnitType.HydrogenBomb
		or unitType == UnitType.MegaNuke
		or unitType == UnitType.Scattershot
		or unitType == UnitType.MIRV
		or unitType == UnitType.MIRVWarhead
		or unitType == UnitType.TradeShip
		or unitType == UnitType.Train
	then
		info = {}
	else
		error(`unknown unit type {unitType}`)
	end
	-- Conquest's Arsenal: with extra weapons on, structures have health that
	-- only Arsenal weapons lower (StructureDamage); otherwise OpenFront's.
	if self:extraWeapons() and StructureDamage.MAX_HEALTH[unitType] ~= nil then
		info = table.clone(info)
		info.maxHealth = StructureDamage.MAX_HEALTH[unitType]
	end
	self._unitInfoCache[unitType] = info
	return info
end

function Config._hasInfiniteTroopsFor(self: Config, player: PlayerLike): boolean
	if self:infiniteTroops() then
		return true
	end
	local hc = self._gameConfig.hostCheats
	return hc ~= nil and hc.infiniteTroops == true and player:isLobbyCreator()
end

function Config.deletionMarkDuration(_self: Config): number
	return 30 * 10
end

function Config.deleteUnitCooldown(_self: Config): number
	return 30 * 10
end

function Config.allianceRequestDuration(_self: Config): number
	return 20 * 10
end

function Config.allianceDuration(self: Config): number
	-- Host can set 1-15 minutes; 0 disables alliances. Default 5 minutes.
	local m = self._gameConfig.customAllianceDuration
	if type(m) == "number" and m > 0 then
		return m * 60 * 10
	end
	return 300 * 10
end

function Config.percentageTilesOwnedToWin(self: Config, elapsedGameSeconds: number): number
	local base = PERCENT_TILES_OWNED_TO_WIN
	local sd = self:overtimeConfig()
	if not sd.enabled then
		return base
	end
	-- Whole seconds and whole percentage points (see Config.ts).
	local secondsPastStart = math.floor(elapsedGameSeconds) - sd.startMinutes * 60
	if secondsPastStart <= 0 then
		return base
	end
	return math.max(0, base - math.floor((secondsPastStart * sd.dropPercentPerMinute) / 60))
end

function Config.armyLimitWarningThreshold(_self: Config): number
	return 0.8
end

function Config.numSpawnPhaseTurns(self: Config): number
	if self._gameConfig.gameType == GameType.Singleplayer then
		return 100
	end
	if self:isRandomSpawn() then
		return 150
	end
	return 200
end

function Config.maxTroops(self: Config, player: PlayerLike): number
	return self:_troopCap(player, true)
end

-- maxTroops without what cities add
function Config.maxTroopsWithoutCities(self: Config, player: PlayerLike): number
	return self:_troopCap(player, false)
end

function Config._troopCap(self: Config, player: PlayerLike, withCities: boolean): number
	local cityTroops = 0
	if withCities then
		local levels = 0
		for _, city in player:units(UnitType.City) do
			if not city:isUnderConstruction() then
				levels += city:level()
			end
		end
		cityTroops = levels * self:cityTroopIncrease()
	end
	local maxTroops = if player:type() == PlayerType.Human and self:_hasInfiniteTroopsFor(player)
		then 1_000_000_000
		else 2 * (DetMath.pow(player:numTilesOwned(), 0.6) * 1000 + 50000) + cityTroops

	if player:type() == PlayerType.Bot then
		return maxTroops / 3
	end
	if player:type() == PlayerType.Human then
		return maxTroops
	end
	local difficulty = self._gameConfig.difficulty
	if difficulty == Difficulty.Easy then
		return maxTroops * 0.5
	elseif difficulty == Difficulty.Medium then
		return maxTroops * 0.75
	elseif difficulty == Difficulty.Hard then
		return maxTroops * 1 -- Like humans
	elseif difficulty == Difficulty.Impossible then
		return maxTroops * 1.25
	end
	error(`unknown difficulty {difficulty}`)
end

function Config.troopIncreaseRate(self: Config, player: PlayerLike): number
	local max = self:maxTroops(player)
	local troops = player:troops()

	local toAdd = 10 + DetMath.pow(troops, 0.73) / 4

	local ratio = 1 - troops / max
	toAdd *= ratio

	if player:type() == PlayerType.Bot then
		toAdd *= 0.5
	end

	if player:type() == PlayerType.Nation then
		local difficulty = self._gameConfig.difficulty
		if difficulty == Difficulty.Easy then
			toAdd *= 0.9
		elseif difficulty == Difficulty.Medium then
			toAdd *= 0.95
		elseif difficulty == Difficulty.Hard then
			toAdd *= 1 -- Like humans
		elseif difficulty == Difficulty.Impossible then
			toAdd *= 1.05
		else
			error(`unknown difficulty {difficulty}`)
		end
	end

	return math.min(troops + toAdd, max) - troops
end

-- Conquest's Arsenal: Rapid Reload halves every reload of its owner's (silo,
-- SAM, Artillery, Airfield, Railgun; RoWorld's RAPID_RELOAD_MULT 0.5).
function Config.rapidReload(owner: any, ticks: number): number
	if owner ~= nil and owner.hasExtraWeapon ~= nil and owner:hasExtraWeapon("rapidReload") then
		return math.max(1, math.ceil(ticks * 0.5))
	end
	return ticks
end

function Config.nukeMagnitudes(_self: Config, unitType: string): { inner: number, outer: number }
	if unitType == UnitType.MIRVWarhead then
		return { inner = 12, outer = 18 }
	elseif unitType == UnitType.AtomBomb then
		return { inner = 12, outer = 30 }
	elseif unitType == UnitType.HydrogenBomb then
		return { inner = 80, outer = 100 }
	elseif unitType == UnitType.MegaNuke then
		-- Conquest's Arsenal: twice the Atom Bomb's radius (4x the area).
		return { inner = 24, outer = 60 }
	elseif unitType == UnitType.Scattershot then
		-- Its own crater is an Atom Bomb's (RoWorld's); the warheads it
		-- carries are MIRV warheads.
		return { inner = 12, outer = 30 }
	end
	error(`Unknown nuke type: {unitType}`)
end

function Config.nukeAllianceBreakThreshold(_self: Config): number
	return 100
end

function Config.samRange(self: Config, level: number): number
	-- level 1 = 70, level 5 just above hydro range, approaching 150
	return self:maxSamRange() - 480 / (level + 5)
end

function Config.maxSamRange(_self: Config): number
	return 150
end

function Config.structureMinDist(_self: Config): number
	return 15
end

function Config.warshipVeterancyHealthBonus(_self: Config): number
	return 20
end

function Config.allianceExtensionPromptOffset(_self: Config): number
	return 300 -- 30 seconds before expiration
end

return Config
