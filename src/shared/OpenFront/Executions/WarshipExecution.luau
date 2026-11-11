--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/WarshipExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A warship. Each tick, in priority order:
--   - heal (passively near an own port; more when docked, the port's
--     healing pool shared among ships docked there)
--   - below warshipRetreatHealthPercent, retreat to the nearest port with
--     room (one docked ship per port level), firing back on the way
--   - shell the best target in range: transport ships, then warships,
--     closest first; or hunt down and capture a trade ship near its patrol
--     area (two moves a tick, capture within 5 tiles)
--   - otherwise patrol random water tiles around its patrol tile
-- A player's manual move cancels a retreat and blocks new ones for 50 ticks.

local GameTypes = require(script.Parent.Parent.GameTypes)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local Util = require(script.Parent.Parent.Util)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinding.PathStatus

local WarshipExecution = {}
WarshipExecution.__index = WarshipExecution

export type WarshipExecution = typeof(setmetatable(
	{} :: {
		random: PseudoRandom.PseudoRandom,
		warship: any,
		mg: any,
		pathfinder: PathFinding.WaterPathFinder,
		lastShellAttack: number,
		alreadySentShell: { [any]: true },
		lastManualMoveTickRetreatDisabled: number,
		lastObservedPatrolTile: number?,
		activeHealingRemainder: number,
		lastEmittedCombat: boolean,
		input: any, -- { owner, patrolTile } or an existing warship unit
	},
	WarshipExecution
))

local function isUnit(v: any): boolean
	return type(v) == "table" and type(v.isUnit) == "function" and v:isUnit()
end

function WarshipExecution.new(input: any): WarshipExecution
	return setmetatable({
		random = nil :: any,
		warship = nil,
		mg = nil,
		pathfinder = nil :: any,
		lastShellAttack = 0,
		alreadySentShell = {},
		lastManualMoveTickRetreatDisabled = 0,
		lastObservedPatrolTile = nil,
		activeHealingRemainder = 0,
		lastEmittedCombat = false,
		input = input,
	}, WarshipExecution)
end

function WarshipExecution.init(self: WarshipExecution, mg: any, _ticks: number)
	self.mg = mg
	self.pathfinder = PathFinding.WaterPathFinder.new(mg)
	self.random = PseudoRandom.new(mg:ticks())
	if isUnit(self.input) then
		self.warship = self.input
	else
		local owner = self.input.owner
		local spawn = owner:canBuild(UnitType.Warship, self.input.patrolTile)
		if spawn == false then
			return
		end
		self.warship = owner:buildUnit(UnitType.Warship, spawn, { patrolTile = self.input.patrolTile })
	end
	self.lastObservedPatrolTile = self.warship:warshipState().patrolTile
end

function WarshipExecution.tick(self: WarshipExecution, _ticks: number)
	local warship = self.warship
	if warship:health() <= 0 then
		warship:delete()
		return
	end
	local isInCombat = warship:warshipState().isInCombat or false
	if self.lastEmittedCombat and not isInCombat then
		warship:touch()
	end
	self.lastEmittedCombat = isInCombat
	local healthBeforeHealing = warship:health()

	self:_healWarship()
	self:_handleManualPatrolOverride()

	-- A doomed side cannot repair, so retreating only idles the ship.
	if warship:owner():inDoomsdayClock() and warship:warshipState().state ~= "patrolling" then
		self:_cancelRepairRetreat(true)
	end

	if warship:warshipState().state == "docked" then
		if self:_currentRetreatPort() == nil then
			self:_cancelRepairRetreat(true)
		end
		if self:_isFullyHealed() then
			self:_cancelRepairRetreat(true)
		end
		if warship:warshipState().state == "docked" then
			return
		end
	end

	if self:_handleRepairRetreat() then
		return
	end
	if self:_shouldStartRepairRetreat(healthBeforeHealing) then
		self:_startRepairRetreat()
		if self:_handleRepairRetreat() then
			return
		end
	end

	warship:setTargetUnit(self:_findTargetUnit())
	local target = warship:targetUnit()
	local targetType = if target then target:type() else nil
	if targetType == UnitType.TransportShip or targetType == UnitType.Warship then
		self:_shootTarget()
		self:_patrol()
		return
	end
	if targetType == UnitType.TradeShip then
		self:_huntDownTradeShip()
		return
	end
	self:_patrol()
end

function WarshipExecution._healWarship(self: WarshipExecution)
	local mg = self.mg
	local warship = self.warship
	local owner = warship:owner()
	if owner:inDoomsdayClock() then
		return
	end
	local range = mg:config():warshipPassiveHealingRange()
	local rangeSquared = range * range
	local tile = warship:tile()
	for _, port in owner:units(UnitType.Port) do
		if mg:euclideanDistSquared(tile, port:tile()) <= rangeSquared then
			warship:modifyHealth(mg:config():warshipPassiveHealing())
			break
		end
	end
	if warship:warshipState().state == "docked" then
		self:_applyActiveDockedHealing()
	end
end

function WarshipExecution._isFullyHealed(self: WarshipExecution): boolean
	if not self.warship:hasHealth() then
		return true
	end
	return self.warship:health() >= self.warship:maxHealth()
end

function WarshipExecution._shouldStartRepairRetreat(self: WarshipExecution, healthBeforeHealing: number): boolean
	local warship = self.warship
	if warship:warshipState().state ~= "patrolling" then
		return false
	end
	if warship:owner():inDoomsdayClock() then
		return false
	end
	if self.mg:ticks() - self.lastManualMoveTickRetreatDisabled < 50 then
		return false
	end
	-- Relative to (veterancy-adjusted) max health, in integers.
	local threshold = math.floor((warship:maxHealth() * self.mg:config():warshipRetreatHealthPercent()) / 100)
	if healthBeforeHealing >= threshold then
		return false
	end
	return #warship:owner():units(UnitType.Port) > 0
end

function WarshipExecution._findNearestPort(self: WarshipExecution): number?
	local mg = self.mg
	local ports = self.warship:owner():units(UnitType.Port)
	if #ports == 0 then
		return nil
	end
	local warshipTile = self.warship:tile()
	local component = mg:getWaterComponent(warshipTile)
	if component == nil then
		error(`Warship at tile {warshipTile} has no water component`)
	end
	local nearest = Util.findMinimumBy(ports, function(port)
		return mg:euclideanDistSquared(warshipTile, port:tile())
	end, function(port)
		local portComponent = mg:getWaterComponent(port:tile())
		if portComponent == nil then
			error(`Port at tile {port:tile()} has no water component`)
		end
		return portComponent == component
	end)
	return if nearest then nearest:tile() else nil
end

function WarshipExecution._findRetreatAggroTarget(self: WarshipExecution): any?
	return self:_findBestTarget({ UnitType.TransportShip, UnitType.Warship }, false)
end

function WarshipExecution._findTargetUnit(self: WarshipExecution): any?
	return self:_findBestTarget({ UnitType.TransportShip, UnitType.Warship, UnitType.TradeShip }, true)
end

-- Best target by type priority (transport, warship, trade ship), then
-- distance. Trade ships only near the patrol tile, not safe from pirates,
-- not bound for us or a friend, and only with an own port to bring them to.
function WarshipExecution._findBestTarget(self: WarshipExecution, types: { string }, includeTradeShips: boolean): any?
	local mg = self.mg
	local config = mg:config()
	local warship = self.warship
	local owner = warship:owner()
	local ships = mg:nearbyUnits(warship:tile(), config:warshipTargettingRange(), types)

	local computed = false
	local hasReachablePort = false
	local patrolTile: number? = nil
	local patrolRangeSquared = 0

	local bestUnit = nil
	local bestTypePriority = 0
	local bestDistSquared = 0
	for _, entry in ships do
		local unit = entry.unit
		local skip = unit == warship
			or unit:owner() == owner
			or not owner:canAttackPlayer(unit:owner(), true)
			or self.alreadySentShell[unit]
			or (unit:type() == UnitType.Warship and unit:warshipState().state == "docked")
		local unitType = unit:type()
		if not skip and includeTradeShips and unitType == UnitType.TradeShip then
			if not computed then
				computed = true
				local component = mg:getWaterComponent(warship:tile())
				if component ~= nil then
					for _, port in owner:units(UnitType.Port) do
						if port:isActive() and not port:isMarkedForDeletion() and not port:isUnderConstruction() and mg:hasWaterComponent(port:tile(), component) then
							hasReachablePort = true
							break
						end
					end
				end
				patrolTile = warship:warshipState().patrolTile
				patrolRangeSquared = config:warshipPatrolRange() ^ 2
			end
			local dest = unit:targetUnit()
			if
				not hasReachablePort
				or patrolTile == nil
				or unit:isSafeFromPirates()
				or (dest ~= nil and dest:owner() == owner)
				or (dest ~= nil and dest:owner():isFriendly(owner))
			then
				skip = true
			elseif mg:euclideanDistSquared(patrolTile, unit:tile()) > patrolRangeSquared then
				skip = true
			end
		end
		if not skip then
			local typePriority = if unitType == UnitType.TransportShip then 0 elseif unitType == UnitType.Warship then 1 else 2
			if bestUnit == nil or typePriority < bestTypePriority or (typePriority == bestTypePriority and entry.distSquared < bestDistSquared) then
				bestUnit = unit
				bestTypePriority = typePriority
				bestDistSquared = entry.distSquared
			end
		end
	end
	return bestUnit
end

function WarshipExecution._startRepairRetreat(self: WarshipExecution)
	local portTile = self:_findNearestPort()
	if portTile == nil then
		return
	end
	self.warship:updateWarshipState({ retreatPort = portTile, state = "retreating" })
	self.activeHealingRemainder = 0
	self.warship:setTargetUnit(nil)
end

function WarshipExecution._cancelRepairRetreat(self: WarshipExecution, clearTargetTile: boolean)
	self.activeHealingRemainder = 0
	self.warship:updateWarshipState({ state = "patrolling", retreatPort = nil, clearRetreatPort = true })
	if clearTargetTile then
		self.warship:setTargetTile(nil)
	end
end

function WarshipExecution._handleManualPatrolOverride(self: WarshipExecution)
	local patrolTile = self.warship:warshipState().patrolTile
	if self.lastObservedPatrolTile ~= nil and patrolTile ~= self.lastObservedPatrolTile then
		self.lastManualMoveTickRetreatDisabled = self.mg:ticks()
		if self.warship:warshipState().state ~= "patrolling" then
			self:_cancelRepairRetreat(false)
		end
	end
	self.lastObservedPatrolTile = patrolTile
end

function WarshipExecution._handleRepairRetreat(self: WarshipExecution): boolean
	local mg = self.mg
	local warship = self.warship
	if warship:warshipState().state == "patrolling" then
		return false
	end
	local aggro = self:_findRetreatAggroTarget()
	if aggro then
		warship:setTargetUnit(aggro)
		self:_shootTarget()
		-- keep retreating while firing back
	end
	if not self:_refreshRetreatPortTile() then
		self:_cancelRepairRetreat(true)
		return false
	end
	if not aggro then
		warship:setTargetUnit(nil)
	end
	local retreatPortTile = warship:warshipState().retreatPort
	if retreatPortTile == nil then
		return false
	end
	local dockingRadius = mg:config():warshipDockingRange()
	if mg:euclideanDistSquared(warship:tile(), retreatPortTile) <= dockingRadius * dockingRadius then
		local port = nil
		for _, p in warship:owner():units(UnitType.Port) do
			if p:tile() == retreatPortTile then
				port = p
				break
			end
		end
		if port and not self:_isPortFullOfHealing(port, warship) then
			warship:setTargetTile(nil)
			warship:updateWarshipState({ state = "docked" })
			return true
		end
		-- Port full: wait nearby, unless already healed.
		if self:_isFullyHealed() then
			self:_cancelRepairRetreat(true)
			return false
		end
		return true
	end
	warship:setTargetTile(retreatPortTile)
	local result = self.pathfinder:next(warship:tile(), retreatPortTile)
	if result.status == PathStatus.COMPLETE then
		warship:move(result.node :: number)
		if result.node == retreatPortTile then
			warship:setTargetTile(nil)
		end
	elseif result.status == PathStatus.NEXT then
		warship:move(result.node :: number)
	else
		local newPort = self:_findNearestAvailablePortTile()
		warship:updateWarshipState({ retreatPort = newPort, clearRetreatPort = true })
		if newPort == nil then
			self:_cancelRepairRetreat(true)
		end
	end
	return true
end

function WarshipExecution._refreshRetreatPortTile(self: WarshipExecution): boolean
	local warship = self.warship
	local ports = warship:owner():units(UnitType.Port)
	if #ports == 0 then
		return false
	end
	local current = warship:warshipState().retreatPort
	local currentPort = nil
	if current ~= nil then
		for _, port in ports do
			if port:tile() == current then
				currentPort = port
				break
			end
		end
	end
	if currentPort == nil then
		local newPort = self:_findNearestAvailablePortTile()
		warship:updateWarshipState({ retreatPort = newPort, clearRetreatPort = true })
		return newPort ~= nil
	end
	if self:_isPortFullOfHealing(currentPort) then
		local alternative = self:_findNearestAvailablePort()
		if alternative then
			warship:updateWarshipState({ retreatPort = alternative })
		end
		return warship:warshipState().retreatPort ~= nil
	end
	local closer = self:_findBetterPortTile()
	if closer and closer ~= current then
		warship:updateWarshipState({ retreatPort = closer })
	end
	return true
end

function WarshipExecution._isPortFullOfHealing(self: WarshipExecution, port: any, excludeShip: any?): boolean
	return #self:_dockedShipsAtPort(port, excludeShip) >= port:level()
end

function WarshipExecution._dockedShipsAtPort(self: WarshipExecution, port: any, excludeShip: any?): { any }
	local owner = self.warship:owner()
	local out = {}
	for _, entry in self.mg:nearbyUnits(port:tile(), self.mg:config():warshipDockingRange(), { UnitType.Warship }) do
		local ship = entry.unit
		if not (excludeShip and ship == excludeShip) and ship:owner() == owner and ship:warshipState().state ~= "patrolling" and ship:targetTile() == nil then
			table.insert(out, ship)
		end
	end
	return out
end

function WarshipExecution._applyActiveDockedHealing(self: WarshipExecution)
	local dockedPort = self:_currentRetreatPort()
	if not dockedPort then
		return
	end
	local docked = self:_dockedShipsAtPort(dockedPort)
	if not table.find(docked, self.warship) then
		return
	end
	local pool = dockedPort:level() * self.mg:config():warshipPortHealingBonusPerLevel()
	if pool <= 0 or #docked == 0 then
		return
	end
	-- A per-ship remainder keeps fractional shares over time.
	self.activeHealingRemainder += pool / #docked
	local integerHealing = math.floor(self.activeHealingRemainder)
	if integerHealing <= 0 then
		return
	end
	self.activeHealingRemainder -= integerHealing
	self.warship:modifyHealth(integerHealing)
end

function WarshipExecution._currentRetreatPort(self: WarshipExecution): any?
	local retreatPort = self.warship:warshipState().retreatPort
	if retreatPort == nil then
		return nil
	end
	for _, port in self.warship:owner():units(UnitType.Port) do
		if port:tile() == retreatPort then
			return port
		end
	end
	return nil
end

function WarshipExecution._nearestAvailablePortTile(self: WarshipExecution, excludeShip: any?): (number?, number)
	local mg = self.mg
	local warshipTile = self.warship:tile()
	local component = mg:getWaterComponent(warshipTile)
	if component == nil then
		error(`Warship at tile {warshipTile} has no water component`)
	end
	local bestTile: number? = nil
	local bestDistance = math.huge
	for _, port in self.warship:owner():units(UnitType.Port) do
		if not self:_isPortFullOfHealing(port, excludeShip) then
			local portTile = port:tile()
			if mg:hasWaterComponent(portTile, component) then
				local d = mg:euclideanDistSquared(warshipTile, portTile)
				if d < bestDistance then
					bestDistance = d
					bestTile = portTile
				end
			end
		end
	end
	return bestTile, bestDistance
end

function WarshipExecution._findNearestAvailablePort(self: WarshipExecution): number?
	return (self:_nearestAvailablePortTile(nil))
end

function WarshipExecution._findBetterPortTile(self: WarshipExecution): number?
	local tile, distSquared = self:_nearestAvailablePortTile(nil)
	if tile == nil then
		return nil
	end
	local currentDistance = math.huge
	local current = self.warship:warshipState().retreatPort
	if current ~= nil then
		currentDistance = self.mg:euclideanDistSquared(self.warship:tile(), current)
	end
	if distSquared < currentDistance * self.mg:config():warshipPortSwitchThreshold() then
		return tile
	end
	return nil
end

function WarshipExecution._findNearestAvailablePortTile(self: WarshipExecution): number?
	return (self:_nearestAvailablePortTile(self.warship))
end

function WarshipExecution._shootTarget(self: WarshipExecution)
	local mg = self.mg
	local warship = self.warship
	warship:updateWarshipState({ isInCombat = true })
	if mg:ticks() - self.lastShellAttack > mg:config():warshipShellAttackRate() then
		local target = warship:targetUnit()
		-- No reload against transport ships.
		if target:type() ~= UnitType.TransportShip then
			self.lastShellAttack = mg:ticks()
		end
		mg:addExecution(require(script.Parent.ShellExecution).new(warship:tile(), warship:owner(), warship, target))
		if not target:hasHealth() then
			-- One shot kills it: don't send more.
			self.alreadySentShell[target] = true
			warship:setTargetUnit(nil)
		end
	end
end

function WarshipExecution._captureTarget(self: WarshipExecution, target: any)
	self.warship:owner():captureUnit(target)
	self.warship:recordTradeCapture()
	self.warship:setTargetUnit(nil)
	self.warship:touch()
end

function WarshipExecution._huntDownTradeShip(self: WarshipExecution)
	local mg = self.mg
	local warship = self.warship
	warship:updateWarshipState({ isInCombat = true })
	for _ = 1, 2 do
		local target = warship:targetUnit()
		local targetTile = target:tile()
		local dist = mg:manhattanDist(warship:tile(), targetTile)
		if dist <= 5 then
			self:_captureTarget(target)
			return
		end
		-- Close in, minimap paths zigzag: step greedily instead.
		local greedy = nil
		if dist <= 20 then
			greedy = self:_bestNeighborToward(targetTile)
		end
		if greedy ~= nil then
			warship:move(greedy)
		else
			local result = self.pathfinder:next(warship:tile(), targetTile, 5)
			if result.status == PathStatus.COMPLETE then
				self:_captureTarget(target)
				return
			elseif result.status == PathStatus.NEXT then
				warship:move(result.node :: number)
			end
		end
	end
end

function WarshipExecution._bestNeighborToward(self: WarshipExecution, targetTile: number): number?
	local mg = self.mg
	local warshipTile = self.warship:tile()
	local best: number? = nil
	local bestDist = mg:manhattanDist(warshipTile, targetTile)
	mg:forEachNeighbor(warshipTile, function(neighbor: number)
		if mg:isWater(neighbor) then
			local d = mg:manhattanDist(neighbor, targetTile)
			if d < bestDist then
				bestDist = d
				best = neighbor
			end
		end
	end)
	return best
end

function WarshipExecution._patrol(self: WarshipExecution)
	local warship = self.warship
	if warship:targetTile() == nil then
		warship:setTargetTile(self:randomTile(false))
		if warship:targetTile() == nil then
			return
		end
	end
	local result = self.pathfinder:next(warship:tile(), warship:targetTile())
	if result.status == PathStatus.COMPLETE then
		warship:setTargetTile(nil)
		warship:move(result.node :: number)
	elseif result.status == PathStatus.NEXT then
		warship:move(result.node :: number)
	else
		warship:setTargetTile(nil)
	end
end

function WarshipExecution.isActive(self: WarshipExecution): boolean
	return self.warship ~= nil and self.warship:isActive()
end

function WarshipExecution.isDocked(self: WarshipExecution): boolean
	return self.warship ~= nil and self.warship:warshipState().state == "docked"
end

function WarshipExecution.activeDuringSpawnPhase(_self: WarshipExecution): boolean
	return false
end

-- A random water tile within patrol range of the patrol tile on the ship's
-- water body (not shoreline, unless nothing else is found); the range grows
-- by half after each 500 misses, three times.
function WarshipExecution.randomTile(self: WarshipExecution, allowShoreline: boolean): number?
	local mg = self.mg
	local range = mg:config():warshipPatrolRange()
	local attempts = 0
	local expandCount = 0
	local component = mg:getWaterComponent(self.warship:tile())
	local patrolTile = self.warship:warshipState().patrolTile
	if patrolTile == nil or not mg:isValidRef(patrolTile) then
		return nil
	end
	while expandCount < 3 do
		local x = mg:x(patrolTile) + self.random:nextInt(-range / 2, range / 2)
		local y = mg:y(patrolTile) + self.random:nextInt(-range / 2, range / 2)
		if mg:isValidCoord(x, y) then
			local tile = mg:ref(x, y)
			local bad = not mg:isWater(tile)
				or (not allowShoreline and mg:map():isShoreline(tile))
				or (component ~= nil and not mg:hasWaterComponent(tile, component))
			if not bad then
				return tile
			end
			attempts += 1
			if attempts == 500 then
				expandCount += 1
				attempts = 0
				range += math.floor(range / 2)
			end
		end
	end
	if not allowShoreline then
		return self:randomTile(true)
	end
	return nil
end

return WarshipExecution
