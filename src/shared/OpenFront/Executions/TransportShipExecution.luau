--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/TransportShipExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A troop boat: launched from the attacker's nearest shore by water, one
-- tile per tick along the water path.
--   - On landing it takes the landing tile and starts an attack from there
--     (or hands the troops back, if the target became friendly).
--   - Landing on our own shore (a retreat) refunds the troops minus 25%.
--   - The full path is recorded as a motion plan for clients.

local AttackExecution = require(script.Parent.AttackExecution)
local GameTypes = require(script.Parent.Parent.GameTypes)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local TransportShipUtils = require(script.Parent.Parent.TransportShipUtils)

local PlayerType = GameTypes.PlayerType
local PathStatus = PathFinding.PathStatus

local malusForRetreat = 25

local TransportShipExecution = {}
TransportShipExecution.__index = TransportShipExecution

export type TransportShipExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		ticksPerMove: number,
		lastMove: number,
		mg: any,
		target: any,
		pathFinder: PathFinding.WaterPathFinder?,
		dst: number?,
		src: number?,
		retreatDst: (number | false)?,
		boat: any,
		motionPlanId: number,
		motionPlanDst: number?,
		originalOwner: any,
		attacker: any,
		ref: number,
		troops: number?,
	},
	TransportShipExecution
))

function TransportShipExecution.new(attacker: any, ref: number, troops: number?): TransportShipExecution
	return setmetatable({
		active = true,
		ticksPerMove = 1,
		lastMove = 0,
		mg = nil,
		target = nil,
		pathFinder = nil,
		dst = nil,
		src = nil,
		retreatDst = nil,
		boat = nil,
		motionPlanId = 1,
		motionPlanDst = nil,
		originalOwner = attacker,
		attacker = attacker,
		ref = ref,
		troops = troops,
	}, TransportShipExecution)
end

function TransportShipExecution.activeDuringSpawnPhase(_self: TransportShipExecution): boolean
	return false
end

function TransportShipExecution.init(self: TransportShipExecution, mg: any, ticks: number)
	if not mg:isValidRef(self.ref) then
		self.active = false
		return
	end
	self.lastMove = ticks
	self.mg = mg
	self.target = mg:owner(self.ref)
	self.pathFinder = PathFinding.WaterPathFinder.new(mg, mg:nextShipStagger("transportShip"))
	local attacker = self.attacker
	if attacker:unitCount("Transport") >= mg:config():boatMaxNumber() then
		mg:displayMessage("events_display.no_boats_available", "ATTACK_FAILED", attacker:id(), nil, {
			max = mg:config():boatMaxNumber(),
		})
		self.active = false
		return
	end
	if self.target:isPlayer() then
		if self.target:type() ~= PlayerType.Bot and attacker:type() ~= PlayerType.Bot then
			for _, ar in attacker:incomingAllianceRequests() do
				if ar:requestor() == self.target then
					ar:reject()
					break
				end
			end
		end
	end
	if self.target == attacker then
		self.active = false
		return
	end
	if self.target:isPlayer() and not attacker:canAttackPlayer(self.target) then
		self.active = false
		return
	end
	if self.troops == nil then
		self.troops = mg:config():boatAttackAmount(attacker, self.target)
	end
	self.troops = math.min(self.troops :: number, attacker:troops())
	self.dst = TransportShipUtils.targetTransportTile(mg, attacker, self.ref)
	if self.dst == nil then
		self.active = false
		return
	end
	local src = attacker:canBuild("Transport", self.dst :: number)
	if src == false then
		self.active = false
		return
	end
	self.src = src :: number
	self.boat = attacker:buildUnit("Transport", src :: number, { troops = self.troops, targetTile = self.dst })

	local fullPath = (self.pathFinder :: PathFinding.WaterPathFinder):findPath(src :: number, self.dst :: number)
		or { src :: number }
	if #fullPath == 0 or fullPath[1] ~= src then
		table.insert(fullPath, 1, src :: number)
	end
	mg:recordMotionPlan({
		kind = "grid",
		unitId = self.boat:id(),
		planId = self.motionPlanId,
		startTick = ticks + self.ticksPerMove,
		ticksPerStep = self.ticksPerMove,
		path = fullPath,
	})
	self.motionPlanDst = self.dst
	if self.target:isPlayer() then
		mg:displayIncomingUnit(
			self.boat:id(),
			"events_display.naval_invasion_inbound",
			"NAVAL_INVASION_INBOUND",
			self.target:id()
		)
	end
end

function TransportShipExecution.tick(self: TransportShipExecution, ticks: number)
	if self.dst == nil then
		self.active = false
		return
	end
	if not self.active then
		return
	end
	local boat = self.boat
	if not boat:isActive() then
		self.active = false
		return
	end
	if ticks - self.lastMove < self.ticksPerMove then
		return
	end
	self.lastMove = ticks
	local mg = self.mg
	local pathFinder = self.pathFinder :: PathFinding.WaterPathFinder

	-- A teammate who conquered a disconnected player now owns the boat.
	local boatOwner = boat:owner()
	if self.originalOwner:isDisconnected() and boatOwner ~= self.originalOwner and boatOwner:isOnSameTeam(self.originalOwner) then
		self.attacker = boatOwner
		self.originalOwner = boatOwner
	end

	if pathFinder:rebuilt() then
		self.motionPlanDst = nil -- force a new motion plan
	end

	-- The destination was nuked into water: retreat.
	if self.dst ~= nil and mg:isWater(self.dst) then
		if not boat:transportShipState().isRetreating then
			boat:updateTransportShipState({ isRetreating = true })
		end
		self.retreatDst = nil
	end

	if boat:transportShipState().isRetreating then
		if self.retreatDst == nil then
			self.retreatDst = self.attacker:bestTransportShipSpawn(boat:tile())
		end
		if self.retreatDst == false then
			self.attacker:addTroops(boat:troops())
			boat:delete(false)
			self.active = false
			return
		end
		self.dst = self.retreatDst :: number
		if boat:targetTile() ~= self.dst then
			boat:setTargetTile(self.dst)
		end
	end

	local dst = self.dst :: number
	local result = pathFinder:next(boat:tile(), dst)
	if result.status == PathStatus.COMPLETE then
		if mg:owner(dst) == self.attacker then
			-- Conquest (Bruno, 2026-11-05): a boat that finds its landing already
			-- ours, say taken by an earlier boat, didn't retreat, so all its troops
			-- go home. Turning a boat back still costs the malus.
			if mg:config():gameConfig().boatFullRefund and not boat:transportShipState().isRetreating then
				local troops = boat:troops()
				self.attacker:addTroops(troops)
				boat:delete(false)
				self.active = false
				-- `tile`: where it came home, for the client's "home" mark
				-- (Bruno, 2026-11-08). Presentation only.
				mg:displayMessage("events_display.boat_returned_troops", "BOAT_RETURNED", self.attacker:id(), nil, {
					troops = troops,
					tile = dst,
				})
				return
			end
			local deaths = boat:troops() * (malusForRetreat / 100)
			local survivors = boat:troops() - deaths
			self.attacker:addTroops(survivors)
			boat:delete(false)
			self.active = false
			if deaths ~= 0 then
				mg:displayMessage("events_display.attack_cancelled_retreat", "ATTACK_CANCELLED", self.attacker:id(), nil, {
					troops = deaths,
				})
			end
			return
		end
		self.attacker:conquer(dst)
		if self.target:isPlayer() and self.attacker:isFriendly(self.target) then
			self.attacker:addTroops(boat:troops())
		else
			mg:addExecution(AttackExecution.new(boat:troops(), self.attacker, self.target:id(), dst, false))
		end
		-- Conquest (Bruno, 2026-11-08): a boat that lands says so, as
		-- OpenFront's nukes, shells and trains do. OpenFront never sets it on
		-- boats, so the "troops land" and "enemy boat landed" sounds and the
		-- landing splash never fired. Nothing in the sim reads a boat's
		-- reachedTarget; presentation only.
		boat:setReachedTarget()
		boat:delete(false)
		self.active = false
		return
	elseif result.status == PathStatus.NEXT then
		boat:move(result.node :: number)
	else
		-- NOT_FOUND
		self.attacker:addTroops(boat:troops())
		boat:delete(false)
		self.active = false
		return
	end

	if self.dst ~= nil and self.dst ~= self.motionPlanDst then
		self.motionPlanId += 1
		local fullPath = pathFinder:findPath(boat:tile(), self.dst :: number) or { boat:tile() }
		if #fullPath == 0 or fullPath[1] ~= boat:tile() then
			table.insert(fullPath, 1, boat:tile())
		end
		mg:recordMotionPlan({
			kind = "grid",
			unitId = boat:id(),
			planId = self.motionPlanId,
			startTick = ticks + self.ticksPerMove,
			ticksPerStep = self.ticksPerMove,
			path = fullPath,
		})
		self.motionPlanDst = self.dst
	end
end

function TransportShipExecution.owner(self: TransportShipExecution): any
	return self.attacker
end

function TransportShipExecution.isActive(self: TransportShipExecution): boolean
	return self.active
end

return TransportShipExecution
