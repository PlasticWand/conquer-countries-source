--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/UnitImpl.ts and engine-lib/src/game/Veterancy.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- One unit: a structure, ship, missile or train car. Health is an integer
-- (BigInt in OpenFront), floored like its toInt. Kill stats and client update
-- events are not kept: replication diffs unit state each tick instead.

local Util = require(script.Parent.Util)

local Unit = {}
Unit.__index = Unit

export type WarshipState = {
	state: string, -- "patrolling" | "retreating" | "docked" ...
	patrolTile: number?,
	retreatPort: any?,
	lastCombatTick: number,
	veterancy: number,
	veterancyProgress: number,
	isInCombat: boolean?,
}

export type NukeState = {
	trajectory: { { tile: number, targetable: boolean } },
	waitTicks: number,
	trajectoryIndex: number,
	targetedBySam: boolean,
}

export type SamLauncherState = {
	upgradeStartTick: number?,
	startRange: number,
	targetLevel: number,
	duration: number?,
}

export type Unit = typeof(setmetatable(
	{} :: {
		_type: string,
		_id: number,
		_tile: number,
		_owner: any,
		mg: any,
		_active: boolean,
		_underConstruction: boolean,
		_level: number,
		_troops: number,
		_lastTile: number,
		_targetTile: number?,
		_targetPlayer: any?,
		_targetUnit: any?,
		_health: number,
		_transportShipState: { isRetreating: boolean }?,
		_warshipState: WarshipState?,
		_nukeState: NukeState?,
		_samLauncherState: SamLauncherState?,
		_missileTimerQueue: { number },
		_reachedTarget: boolean,
		_wasDestroyedByEnemy: boolean,
		_destroyer: any?,
		_lastSetSafeFromPirates: number,
		_lastOwner: any?,
		_hasTrainStation: boolean,
		_targetable: boolean,
		_loaded: boolean?,
		_trainType: string?,
		_deletionAt: number?,
		_darkUntil: number?,
		_expiresAt: number?, -- Field Works (ARSENAL_V2)
	},
	Unit
))

export type Params = {
	troops: number?,
	targetTile: number?,
	targetPlayer: any?,
	targetUnit: any?,
	trajectory: { { tile: number, targetable: boolean } }?,
	waitTicks: number?,
	lastSetSafeFromPirates: number?,
	patrolTile: number?,
	loaded: boolean?,
	trainType: string?,
}

-- UnitImpl constructor. `owner.mg` is the game.
function Unit.new(unitType: string, tile: number, id: number, owner: any, params: Params?): Unit
	local p: Params = params or {}
	local mg = owner.mg
	local config = mg:config()
	local self: Unit = setmetatable({
		_type = unitType,
		_id = id,
		_tile = tile,
		_owner = owner,
		mg = mg,
		_active = true,
		_underConstruction = false,
		_level = 1,
		_troops = p.troops or 0,
		_lastTile = tile,
		_targetTile = p.targetTile,
		_targetPlayer = p.targetPlayer,
		_targetUnit = p.targetUnit,
		_health = Util.toInt(mg:unitInfo(unitType).maxHealth or 1),
		_transportShipState = if unitType == "Transport" then { isRetreating = false } else nil,
		_warshipState = nil,
		_nukeState = nil,
		_samLauncherState = nil,
		_missileTimerQueue = {},
		_reachedTarget = false,
		_wasDestroyedByEnemy = false,
		_destroyer = nil,
		_lastSetSafeFromPirates = p.lastSetSafeFromPirates or 0,
		_lastOwner = nil,
		_hasTrainStation = false,
		_targetable = true,
		_loaded = p.loaded,
		_trainType = p.trainType,
		_deletionAt = nil,
		_darkUntil = nil,
		_expiresAt = nil,
	}, Unit) :: any
	if p.trajectory ~= nil or p.waitTicks ~= nil then
		self._nukeState = { trajectory = p.trajectory or {}, waitTicks = 0, trajectoryIndex = 0, targetedBySam = false }
	end
	if unitType == "SAM Launcher" then
		self._samLauncherState = { startRange = config:samRange(1), targetLevel = 1, duration = config:samUpgradeDuration() }
	end
	if p.patrolTile ~= nil then
		self._warshipState = {
			state = "patrolling",
			patrolTile = p.patrolTile,
			lastCombatTick = -100,
			veterancy = 0,
			veterancyProgress = 0,
		}
	end
	return self
end

function Unit.id(self: Unit): number
	return self._id
end
function Unit.type(self: Unit): string
	return self._type
end
function Unit.tile(self: Unit): number
	return self._tile
end
function Unit.lastTile(self: Unit): number
	return self._lastTile
end
function Unit.owner(self: Unit): any
	return self._owner
end
function Unit.lastOwner(self: Unit): any?
	return self._lastOwner
end
function Unit.info(self: Unit): { [string]: any }
	return self.mg:unitInfo(self._type)
end
function Unit.isActive(self: Unit): boolean
	return self._active
end
function Unit.level(self: Unit): number
	return self._level
end
function Unit.isUnit(_self: Unit): boolean
	return true
end

function Unit.setTargetable(self: Unit, targetable: boolean)
	self._targetable = targetable
end
function Unit.isTargetable(self: Unit): boolean
	return self._targetable
end

function Unit.move(self: Unit, tile: number)
	self._lastTile = self._tile
	self._tile = tile
	self.mg:onUnitMoved(self)
end

-- UnitImpl.ts touch: asks clients to redraw the unit. Replication sends unit
-- state every tick it changes, so there is nothing to flag here.
function Unit.touch(_self: Unit) end

function Unit.troops(self: Unit): number
	return self._troops
end
function Unit.setTroops(self: Unit, troops: number)
	self._troops = math.max(0, troops)
end

-- Health -------------------------------------------------------------------------

function Unit.health(self: Unit): number
	return self._health
end
function Unit.hasHealth(self: Unit): boolean
	return self:info().maxHealth ~= nil
end

-- Veterancy.ts maxHealthWithVeterancy
function Unit.maxHealth(self: Unit): number
	local base = self:info().maxHealth or 1
	local vet = self:veterancy()
	if vet <= 0 then
		return base
	end
	return base + math.floor((base * vet * self.mg:config():warshipVeterancyHealthBonus()) / 100)
end

function Unit.modifyHealth(self: Unit, delta: number, attacker: any?)
	local previous = self._health
	local nextHealth = math.clamp(self._health + Util.toInt(delta), 0, Util.toInt(self:maxHealth()))
	if nextHealth == previous then
		return
	end
	if attacker ~= nil and delta < 0 and self._warshipState ~= nil then
		self._warshipState.lastCombatTick = self.mg:ticks()
	end
	self._health = nextHealth
	if self._health == 0 then
		self:delete(true, attacker)
	end
end

-- Ownership and deletion ------------------------------------------------------------

-- UnitImpl.ts setOwner: a capture moves the unit to the new owner's list.
function Unit.setOwner(self: Unit, newOwner: any)
	self:clearPendingDeletion()
	local old = self._owner
	self._lastOwner = old
	local kept = {}
	for _, u in old._units do
		if u ~= self then
			table.insert(kept, u)
		end
	end
	old._units = kept
	old._myUnitsVersion += 1
	self._owner = newOwner
	table.insert(newOwner._units, self)
	newOwner._myUnitsVersion += 1
	self.mg:_unitsChanged()
end

-- UnitImpl.ts delete. `destroyer` is who destroyed it (nil if retired or
-- self-inflicted).
function Unit.delete(self: Unit, displayMessage: boolean?, destroyer: any?)
	if not self._active then
		error(`cannot delete unit {self._id}: not active`)
	end
	self._wasDestroyedByEnemy = destroyer ~= nil
	self._destroyer = destroyer
	local owner = self._owner
	local kept = {}
	for _, u in owner._units do
		if u ~= self then
			table.insert(kept, u)
		end
	end
	owner._units = kept
	owner._myUnitsVersion += 1
	self.mg:_unitsChanged()
	self._active = false
	self.mg:removeUnit(self)
	if displayMessage ~= false and (self._type == "Warship" or self._type == "Transport") then
		self.mg:displayMessage("events_display.unit_destroyed", "UNIT_DESTROYED", owner:id(), nil, {
			unit = if self._type == "Transport" then "unit_type.boat" else "unit_type.warship",
		})
	end
end

function Unit.wasDestroyedByEnemy(self: Unit): boolean
	return self._wasDestroyedByEnemy
end
function Unit.destroyer(self: Unit): any?
	return self._destroyer
end

function Unit.clearPendingDeletion(self: Unit)
	self._deletionAt = nil
end
function Unit.isMarkedForDeletion(self: Unit): boolean
	return self._deletionAt ~= nil
end
function Unit.markedForDeletion(self: Unit): number?
	return self._deletionAt
end
function Unit.markForDeletion(self: Unit)
	if not self._active then
		return
	end
	self._deletionAt = self.mg:ticks() + self.mg:config():deletionMarkDuration()
end
function Unit.isOverdueDeletion(self: Unit): boolean
	if not self._active then
		return false
	end
	return self._deletionAt ~= nil and self.mg:ticks() - (self._deletionAt :: number) > 0
end

-- Conquest's Sabotage (ARSENAL_V2): a building that's dark doesn't fire,
-- launch, defend or earn until the tick in _darkUntil.
function Unit.isDark(self: Unit): boolean
	return self._darkUntil ~= nil and self.mg:ticks() < self._darkUntil
end

function Unit.setDarkUntil(self: Unit, tick: number)
	self._darkUntil = tick
end

-- Construction and levels ------------------------------------------------------------

function Unit.isUnderConstruction(self: Unit): boolean
	return self._underConstruction
end
function Unit.setUnderConstruction(self: Unit, underConstruction: boolean)
	self._underConstruction = underConstruction
end

function Unit.increaseLevel(self: Unit)
	if self._type == "SAM Launcher" then
		local now = self.mg:ticks()
		local currentRange = self.mg:config():dynamicSamRange(self, now)
		self._samLauncherState = {
			upgradeStartTick = now,
			startRange = currentRange,
			targetLevel = self._level + 1,
			duration = self.mg:config():samUpgradeDuration(),
		}
	end
	self._level += 1
	-- unitCount is level-weighted and memoised on these versions (UnitImpl.ts).
	self.mg:_unitsChanged()
	self._owner._myUnitsVersion += 1
	if self._type == "Missile Silo" or self._type == "SAM Launcher" then
		table.insert(self._missileTimerQueue, self.mg:ticks())
	end
end

function Unit.decreaseLevel(self: Unit, destroyer: any?)
	self._level -= 1
	if self._type == "Missile Silo" or self._type == "SAM Launcher" then
		table.remove(self._missileTimerQueue)
	end
	if self._type == "SAM Launcher" then
		self._samLauncherState = nil
	end
	if self._level <= 0 then
		self:delete(true, destroyer)
		return
	end
	self.mg:_unitsChanged()
	self._owner._myUnitsVersion += 1
end

-- Missiles (silos and SAMs) ------------------------------------------------------------

function Unit.launch(self: Unit)
	table.insert(self._missileTimerQueue, self.mg:ticks())
end
function Unit.ticksLeftInCooldown(self: Unit): number?
	return self._missileTimerQueue[1]
end
function Unit.isInCooldown(self: Unit): boolean
	return #self._missileTimerQueue == self._level
end
function Unit.missileTimerQueue(self: Unit): { number }
	return self._missileTimerQueue
end
function Unit.reloadMissile(self: Unit)
	table.remove(self._missileTimerQueue, 1)
end
function Unit.samLauncherState(self: Unit): SamLauncherState?
	return self._samLauncherState
end

-- Targets -------------------------------------------------------------------------

function Unit.targetTile(self: Unit): number?
	return self._targetTile
end
function Unit.setTargetTile(self: Unit, tile: number?)
	self._targetTile = tile
end
function Unit.targetPlayer(self: Unit): any?
	return self._targetPlayer
end
function Unit.targetUnit(self: Unit): any?
	return self._targetUnit
end
function Unit.setTargetUnit(self: Unit, target: any?)
	self._targetUnit = target
end
function Unit.setReachedTarget(self: Unit)
	self._reachedTarget = true
end
function Unit.reachedTarget(self: Unit): boolean
	return self._reachedTarget
end

-- Transport ships ------------------------------------------------------------------

function Unit.transportShipState(self: Unit): { isRetreating: boolean, troops: number }
	local state = self._transportShipState
	if state == nil then
		error("transportShipState called on non-transport-ship unit")
	end
	return { isRetreating = state.isRetreating, troops = self._troops }
end

function Unit.updateTransportShipState(self: Unit, update: { isRetreating: boolean?, troops: number? })
	local state = self._transportShipState
	if state == nil then
		error("updateTransportShipState called on non-transport-ship unit")
	end
	if update.isRetreating ~= nil then
		state.isRetreating = update.isRetreating
	end
end

-- Trade ships ------------------------------------------------------------------------

function Unit.setSafeFromPirates(self: Unit)
	self._lastSetSafeFromPirates = self.mg:ticks()
end
function Unit.isSafeFromPirates(self: Unit): boolean
	return self.mg:ticks() - self._lastSetSafeFromPirates < self.mg:config():safeFromPiratesCooldownMax()
end

-- Warships -------------------------------------------------------------------------

function Unit.warshipState(self: Unit): WarshipState
	local state = self._warshipState
	if state == nil then
		error("warshipState called on non-warship unit")
	end
	state.isInCombat = self:isInCombat()
	return state
end

-- `update` keys: state, patrolTile, retreatPort (set clearRetreatPort to
-- clear it, the original's explicit undefined), isInCombat.
function Unit.updateWarshipState(self: Unit, update: { [string]: any })
	local state = self._warshipState
	if state == nil then
		error("updateWarshipState called on non-warship unit")
	end
	if update.isInCombat then
		state.lastCombatTick = self.mg:ticks()
	end
	if update.state ~= nil then
		state.state = update.state
	end
	if update.patrolTile ~= nil then
		state.patrolTile = update.patrolTile
	end
	if update.retreatPort ~= nil or update.clearRetreatPort then
		state.retreatPort = update.retreatPort
	end
end

function Unit.isInCombat(self: Unit): boolean
	return self.mg:ticks() - (self._warshipState :: WarshipState).lastCombatTick <= 3
end

function Unit.veterancy(self: Unit): number
	local state = self._warshipState
	return if state then state.veterancy else 0
end

function Unit._increaseVeterancy(self: Unit)
	local state = self._warshipState
	if state == nil or state.veterancy >= self.mg:config():warshipMaxVeterancy() then
		return
	end
	state.veterancy += 1
end

function Unit.recordKill(self: Unit, targetType: string)
	local state = self._warshipState
	if state == nil then
		return
	end
	if targetType == "Warship" then
		state.veterancyProgress = 0
		self:_increaseVeterancy()
	elseif targetType == "Transport" then
		self:_addVeterancyProgress("Transport")
	end
end

function Unit.recordTradeCapture(self: Unit)
	if self._warshipState ~= nil then
		self:_addVeterancyProgress("Trade Ship")
	end
end

-- Transports and captures share one integer progress meter (see UnitImpl.ts).
function Unit._addVeterancyProgress(self: Unit, source: string)
	local state = self._warshipState
	if state == nil then
		return
	end
	local config = self.mg:config()
	local maxVet = config:warshipMaxVeterancy()
	if state.veterancy >= maxVet then
		return
	end
	local transportThreshold = config:warshipVeterancyTransportKills()
	local captureThreshold = config:warshipVeterancyTradeCaptures()
	local pointsPerLevel = transportThreshold * captureThreshold
	state.veterancyProgress += if source == "Transport" then captureThreshold else transportThreshold
	while state.veterancyProgress >= pointsPerLevel and state.veterancy < maxVet do
		state.veterancyProgress -= pointsPerLevel
		self:_increaseVeterancy()
	end
	if state.veterancy >= maxVet then
		state.veterancyProgress = 0
	end
end

-- Nukes -------------------------------------------------------------------------

function Unit.nukeState(self: Unit): NukeState
	local state = self._nukeState
	if state == nil then
		error("nukeState called on non-nuke unit")
	end
	return state
end

function Unit.updateNukeState(self: Unit, update: { [string]: any })
	local state = self._nukeState
	if state == nil then
		error("updateNukeState called on non-nuke unit")
	end
	if update.targetedBySam ~= nil then
		state.targetedBySam = update.targetedBySam
	end
	if update.trajectoryIndex ~= nil then
		state.trajectoryIndex = update.trajectoryIndex
	end
	if update.waitTicks ~= nil then
		state.waitTicks = update.waitTicks
	end
end

function Unit.setTrajectoryIndex(self: Unit, i: number)
	local state = self._nukeState
	if state == nil then
		error("setTrajectoryIndex called on non-nuke unit")
	end
	local max = #state.trajectory - 1
	state.trajectoryIndex = if i < 0 then 0 elseif i > max then max else i
end
function Unit.trajectoryIndex(self: Unit): number
	local state = self._nukeState
	return if state then state.trajectoryIndex else 0
end
function Unit.trajectory(self: Unit): { { tile: number, targetable: boolean } }
	local state = self._nukeState
	return if state then state.trajectory else {}
end
function Unit.setTargetedBySAM(self: Unit, targeted: boolean)
	(self._nukeState :: NukeState).targetedBySam = targeted
end
function Unit.targetedBySAM(self: Unit): boolean
	return (self._nukeState :: NukeState).targetedBySam
end

-- Trains -------------------------------------------------------------------------

function Unit.setTrainStation(self: Unit, trainStation: boolean)
	self._hasTrainStation = trainStation
end
function Unit.hasTrainStation(self: Unit): boolean
	return self._hasTrainStation
end
function Unit.trainType(self: Unit): string?
	return self._trainType
end
function Unit.isLoaded(self: Unit): boolean?
	return self._loaded
end
function Unit.setLoaded(self: Unit, loaded: boolean)
	self._loaded = loaded
end

-- UnitImpl.ts hash
function Unit.hash(self: Unit): number
	return self._tile + Util.simpleHash(self._type) * self._id
end

return Unit
