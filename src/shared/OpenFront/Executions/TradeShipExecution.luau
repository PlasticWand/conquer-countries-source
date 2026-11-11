--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/TradeShipExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A trade ship from one port to a trading partner's port, one tile per
-- tick. On arrival both owners get tradeShipGold(tiles travelled).
--   - Captured by a warship, it heads for the captor's nearest port and
--     pays the captor (piracy gold) instead.
--   - It sinks quietly if the trade breaks off (embargo, destroyed port,
--     or the destination now belongs to the source's owner).

local GameTypes = require(script.Parent.Parent.GameTypes)
local Format = require(script.Parent.Parent.Format)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local Util = require(script.Parent.Parent.Util)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinding.PathStatus

local TradeShipExecution = {}
TradeShipExecution.__index = TradeShipExecution

export type TradeShipExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		mg: any,
		tradeShip: any,
		wasCaptured: boolean,
		pathFinder: PathFinding.WaterPathFinder,
		tilesTraveled: number,
		motionPlanId: number,
		motionPlanDst: number?,
		origOwner: any,
		srcPort: any,
		_dstPort: any,
	},
	TradeShipExecution
))

function TradeShipExecution.new(origOwner: any, srcPort: any, dstPort: any): TradeShipExecution
	return setmetatable({
		active = true,
		mg = nil,
		tradeShip = nil,
		wasCaptured = false,
		pathFinder = nil :: any,
		tilesTraveled = 0,
		motionPlanId = 1,
		motionPlanDst = nil,
		origOwner = origOwner,
		srcPort = srcPort,
		_dstPort = dstPort,
	}, TradeShipExecution)
end

function TradeShipExecution.init(self: TradeShipExecution, mg: any, _ticks: number)
	self.mg = mg
	-- memoised: port-to-port routes repeat
	self.pathFinder = PathFinding.WaterPathFinder.new(mg, mg:nextShipStagger("tradeShip"), true)
end

function TradeShipExecution.tick(self: TradeShipExecution, ticks: number)
	local mg = self.mg
	if self.pathFinder:rebuilt() then
		self.motionPlanDst = nil
	end

	if self.tradeShip == nil then
		local spawn = self.origOwner:canBuild(UnitType.TradeShip, self.srcPort:tile())
		if spawn == false then
			self.active = false
			return
		end
		self.tradeShip = self.origOwner:buildUnit(UnitType.TradeShip, spawn, {
			targetUnit = self._dstPort,
			lastSetSafeFromPirates = ticks,
		})
		mg:stats():boatSendTrade(self.origOwner, self._dstPort:owner())
	end

	local ship = self.tradeShip
	if not ship:isActive() then
		self.active = false
		return
	end

	local shipOwner = ship:owner()
	local dstPortOwner = self._dstPort:owner()
	if self.wasCaptured ~= true and self.origOwner ~= shipOwner then
		self.wasCaptured = true
		mg:displayMessage("events_display.trade_ship_captured", "UNIT_DESTROYED", self.origOwner:id(), nil, {
			name = shipOwner:displayName(),
		})
	end

	-- The source's owner took the destination port while we sailed.
	if dstPortOwner:id() == self.srcPort:owner():id() then
		ship:delete(false)
		self.active = false
		return
	end

	if not self.wasCaptured and (not self._dstPort:isActive() or not shipOwner:canTrade(dstPortOwner)) then
		ship:delete(false)
		self.active = false
		return
	end

	local curTile = ship:tile()

	if self.wasCaptured and (shipOwner ~= dstPortOwner or not self._dstPort:isActive()) then
		local myComponent = mg:getWaterComponent(curTile)
		local nearestPort = Util.findClosestBy(shipOwner:units(UnitType.Port), function(port)
			return mg:manhattanDist(port:tile(), curTile)
		end, function(port)
			return port:isActive()
				and not port:isMarkedForDeletion()
				and not port:isUnderConstruction()
				and myComponent ~= nil
				and mg:hasWaterComponent(port:tile(), myComponent)
		end)
		if nearestPort == nil then
			ship:delete(false)
			self.active = false
			return
		end
		self._dstPort = nearestPort
		ship:setTargetUnit(nearestPort)
	end

	if curTile == self:dstPort() then
		self:_complete()
		return
	end

	local dst = self._dstPort:tile()
	local result = self.pathFinder:next(curTile, dst)
	if result.status == PathStatus.NEXT then
		local node = result.node :: number
		if dst ~= self.motionPlanDst then
			self.motionPlanId += 1
			mg:recordMotionPlan({
				kind = "grid",
				unitId = ship:id(),
				planId = self.motionPlanId,
				startTick = ticks + 1,
				ticksPerStep = 1,
				path = self.pathFinder:pathForTraversal(node, dst),
			})
			self.motionPlanDst = dst
		end
		if mg:isWater(node) and mg:map():isShoreline(node) then
			ship:setSafeFromPirates()
		end
		ship:move(node)
		self.tilesTraveled += 1
	elseif result.status == PathStatus.COMPLETE then
		self:_complete()
	else
		-- NOT_FOUND
		if ship:isActive() then
			ship:delete(false)
		end
		self.active = false
	end
end

function TradeShipExecution._complete(self: TradeShipExecution)
	local mg = self.mg
	local ship = self.tradeShip
	self.active = false
	ship:delete(false)
	local gold = mg:config():tradeShipGold(self.tilesTraveled, ship:owner())
	if self.wasCaptured and ship:owner() == self.origOwner then
		-- Retaken by its original owner: the payout stands, but nobody pirated it.
		self.origOwner:addGold(gold, self._dstPort:tile())
	elseif self.wasCaptured then
		ship:owner():addGold(gold, self._dstPort:tile())
		ship:owner():addPiracyGold(gold)
		mg:displayMessage("events_display.received_gold_from_captured_ship", "CAPTURED_ENEMY_UNIT", ship:owner():id(), gold, {
			gold = Format.renderNumber(gold),
			name = self.origOwner:displayName(),
		})
		mg:stats():boatCapturedTrade(ship:owner(), self.origOwner, gold)
	else
		-- Conquest's Sabotage (ARSENAL_V2): a dark port's owner earns nothing.
		if not self.srcPort:isDark() then
			self.srcPort:owner():addGold(gold, self.srcPort:tile())
			self.srcPort:owner():addTradeGold(gold)
		end
		if not self._dstPort:isDark() then
			self._dstPort:owner():addGold(gold, self._dstPort:tile())
			self._dstPort:owner():addTradeGold(gold)
		end
		mg:stats():boatArriveTrade(self.srcPort:owner(), self._dstPort:owner(), gold)
	end
end

function TradeShipExecution.dstPort(self: TradeShipExecution): number
	return self._dstPort:tile()
end

function TradeShipExecution.isActive(self: TradeShipExecution): boolean
	return self.active
end

function TradeShipExecution.activeDuringSpawnPhase(_self: TradeShipExecution): boolean
	return false
end

return TradeShipExecution
