--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/MIRVExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A MIRV: flies to a separation point 500 tiles above the target (clamped
-- to the map), then splits into up to 350 warheads on the target owner's
-- land within 1500 tiles, at least 55 tiles (Manhattan) apart.
--   - Launching breaks any alliance with the target owner and drops both
--     relations by 100.
--   - Flight time is normalised towards mirvNormalizeTargetTicks with
--     integer maths, so every engine flies the same arc.
--   - Warhead targets are drawn over the last 20 ticks and re-checked at
--     10; warheads launch then (with waits) so SAMs can see them coming.

local Parabola = require(script.Parent.Parent.Pathfinding.Parabola)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local GameTypes = require(script.Parent.Parent.GameTypes)
local Util = require(script.Parent.Parent.Util)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinding.PathStatus

local MATH_SCALE = 100
local LONG_FLIGHT_MULT = 14
local LONG_FLIGHT_LINEAR_PERCENT = 10
local SHORT_FLIGHT_MULT = 10

local function jsRound(x: number): number
	return math.floor(x + 0.5)
end

local MirvExecution = {}
MirvExecution.__index = MirvExecution

export type MirvExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		mg: any,
		nuke: any,
		range: number,
		rangeSquared: number,
		minimumSpread: number,
		warheadCount: number,
		baseX: number,
		baseY: number,
		random: PseudoRandom.PseudoRandom,
		pathFinder: Parabola.Parabola,
		fullPath: { number },
		pathIndex: number, -- 0-based
		targetPlayer: any,
		separateDst: number,
		spawnTile: number,
		speed: number,
		stagedTargets: { number },
		warheadsSpawned: boolean,
		warheadExecutions: { any },
		player: any,
		dst: number,
	},
	MirvExecution
))

function MirvExecution.new(player: any, dst: number): MirvExecution
	return setmetatable({
		active = true,
		mg = nil,
		nuke = nil,
		range = 1500,
		rangeSquared = 1500 * 1500,
		minimumSpread = 55,
		warheadCount = 350,
		baseX = 0,
		baseY = 0,
		random = nil :: any,
		pathFinder = nil :: any,
		fullPath = {},
		pathIndex = 0,
		targetPlayer = nil,
		separateDst = 0,
		spawnTile = 0,
		speed = -1,
		stagedTargets = {},
		warheadsSpawned = false,
		warheadExecutions = {},
		player = player,
		dst = dst,
	}, MirvExecution)
end

function MirvExecution.init(self: MirvExecution, mg: any, _ticks: number)
	self.random = PseudoRandom.new(mg:ticks() + Util.simpleHash(self.player:id()))
	self.mg = mg
	self.targetPlayer = mg:owner(self.dst)
	self.baseX = mg:x(self.dst)
	self.baseY = mg:y(self.dst)
	self.stagedTargets = { self.dst }
end

function MirvExecution.tick(self: MirvExecution, _ticks: number)
	local mg = self.mg
	if self.nuke == nil then
		local spawn = self.player:canBuild(UnitType.MIRV, self.dst)
		if spawn == false then
			self.active = false
			return
		end
		self.targetPlayer = mg:owner(self.dst)
		self.spawnTile = spawn
		self.nuke = self.player:buildUnit(UnitType.MIRV, spawn, { targetTile = self.dst, targetPlayer = self.targetPlayer })
		mg:recordMirvLaunch()
		mg:stats():bombLaunch(self.player, self.targetPlayer, UnitType.MIRV)
		-- Betrayal only once the missile has actually spawned.
		if self.targetPlayer:isPlayer() then
			local alliance = self.player:allianceWith(self.targetPlayer)
			if alliance ~= nil then
				self.player:breakAlliance(alliance)
			end
			if self.targetPlayer ~= self.player then
				self.targetPlayer:updateRelation(self.player, -100)
				self.player:updateRelation(self.targetPlayer, -100)
			end
		end
		local x = math.floor((self.baseX + mg:x(self.nuke:tile())) / 2)
		local y = math.max(0, self.baseY - 500) + 50
		self.separateDst = mg:ref(x, y)
		self.speed = self:_calculateDeterministicSpeed(self.spawnTile, self.separateDst)
		self.pathFinder = Parabola.new(mg, { increment = self.speed })
		local result = self.pathFinder:next(self.spawnTile, self.separateDst, self.speed)
		while result.status == PathStatus.NEXT do
			table.insert(self.fullPath, result.node)
			result = self.pathFinder:next(self.spawnTile, self.separateDst, self.speed)
		end
		if self.targetPlayer:isPlayer() then
			mg:displayIncomingUnit(self.nuke:id(), "events_display.mirv_inbound", "MIRV_INBOUND", self.targetPlayer:id())
		end
		for _, silo in self.player:units(UnitType.MissileSilo) do
			if silo:tile() == spawn then
				silo:launch()
				break
			end
		end
	end

	if self.nuke ~= nil and not self.nuke:isActive() then
		self.active = false
		for _, warhead in self.warheadExecutions do
			warhead:cancel()
		end
		self.warheadExecutions = {}
		return
	end

	local remainingTicks = #self.fullPath - self.pathIndex
	if remainingTicks <= 20 and remainingTicks > 10 then
		for _ = 1, 100 do
			if #self.stagedTargets >= self.warheadCount then
				break
			end
			local target = self:_tryGenerateTarget(self.stagedTargets)
			if target then
				table.insert(self.stagedTargets, target)
			end
		end
	end
	if remainingTicks <= 10 and not self.warheadsSpawned then
		self.warheadsSpawned = true
		local extraAttempts = (10 - remainingTicks) * 50
		self:_finalizeDestinations(500 + extraAttempts)
		self:_spawnWarheadsWithWait(remainingTicks)
	end

	if self.pathIndex < #self.fullPath then
		self.pathIndex += 1
		self.nuke:move(self.fullPath[self.pathIndex])
	else
		self.nuke:delete(false) -- separate
		self.active = false
		mg:stats():bombLand(self.player, self.targetPlayer, UnitType.MIRV)
	end
end

function MirvExecution._finalizeDestinations(self: MirvExecution, additionalAttempts: number)
	local mg = self.mg
	local kept = {}
	for _, tile in self.stagedTargets do
		if tile == self.dst or mg:owner(tile) == self.targetPlayer then
			table.insert(kept, tile)
		end
	end
	self.stagedTargets = kept
	for _ = 1, additionalAttempts do
		if #self.stagedTargets >= self.warheadCount then
			break
		end
		local target = self:_tryGenerateTarget(self.stagedTargets)
		if target then
			table.insert(self.stagedTargets, target)
		end
	end
	self.stagedTargets = Util.stableSort(self.stagedTargets, function(a, b)
		return mg:manhattanDist(a, self.dst) > mg:manhattanDist(b, self.dst)
	end)
end

function MirvExecution._spawnWarheadsWithWait(self: MirvExecution, remainingTicks: number)
	if self.nuke == nil then
		return
	end
	local NukeExecution = require(script.Parent.NukeExecution)
	local waitBase = math.max(0, remainingTicks)
	local warheadSpeed = self.mg:config():nukeSpeed(UnitType.MIRVWarhead)
	for idx, dst in self.stagedTargets do
		local i = idx - 1
		local speedOffset = 4
		if i < 70 then
			speedOffset = 0
		elseif i < 140 then
			speedOffset = 1
		elseif i < 210 then
			speedOffset = 2
		elseif i < 280 then
			speedOffset = 3
		end
		local execution = NukeExecution.new(UnitType.MIRVWarhead, self.player, dst, self.separateDst, warheadSpeed + speedOffset, waitBase + self.random:nextInt(0, 15))
		table.insert(self.warheadExecutions, execution)
		self.mg:addExecution(execution)
	end
end

function MirvExecution._tryGenerateTarget(self: MirvExecution, taken: { number }): number?
	local mg = self.mg
	for _ = 1, 100 do
		local r1 = self.random:next()
		local r2 = (r1 * 15485863) % 1
		local x = jsRound(r1 * self.range * 2 - self.range + self.baseX)
		local y = jsRound(r2 * self.range * 2 - self.range + self.baseY)
		if mg:isValidCoord(x, y) then
			local tile = mg:ref(x, y)
			if
				mg:isLand(tile)
				and (x - self.baseX) ^ 2 + (y - self.baseY) ^ 2 <= self.rangeSquared
				and mg:owner(tile) == self.targetPlayer
				and not self:_isOverlapping(x, y, taken)
			then
				return tile
			end
		end
	end
	return nil
end

function MirvExecution._isOverlapping(self: MirvExecution, x: number, y: number, taken: { number }): boolean
	local mg = self.mg
	for _, existing in taken do
		if math.abs(x - mg:x(existing)) + math.abs(y - mg:y(existing)) < self.minimumSpread then
			return true
		end
	end
	return false
end

function MirvExecution.owner(self: MirvExecution): any
	return self.player
end

function MirvExecution.isActive(self: MirvExecution): boolean
	return self.active
end

function MirvExecution.activeDuringSpawnPhase(_self: MirvExecution): boolean
	return false
end

-- Integer-only flight-time normalisation (no pow, which engines may round
-- differently).
function MirvExecution._calculateDeterministicSpeed(self: MirvExecution, spawnTile: number, separateDst: number): number
	local mg = self.mg
	local Bezier = Parabola.Bezier
	local i0, i1, i2, i3 = Parabola.controlPoints(mg, spawnTile, separateDst, { distanceBasedHeight = true, directionUp = true, ignoreMapBounds = true })
	local idealLength = Bezier.getLength(i0, i1, i2, i3)
	local baseSpeed = mg:config():nukeSpeed(UnitType.MIRV)
	local idealTicks = idealLength / baseSpeed
	local baseTicksScaled = mg:config():mirvNormalizeTargetTicks() * MATH_SCALE
	local idealTicksInt = math.floor(idealTicks * MATH_SCALE)
	local target = baseTicksScaled
	if idealTicksInt > baseTicksScaled then
		local diff = idealTicksInt - baseTicksScaled
		target = baseTicksScaled + math.floor(math.sqrt(diff)) * LONG_FLIGHT_MULT + math.floor((diff * LONG_FLIGHT_LINEAR_PERCENT) / 100)
	elseif idealTicksInt < baseTicksScaled then
		local diff = baseTicksScaled - idealTicksInt
		target = baseTicksScaled - math.floor(math.sqrt(diff)) * SHORT_FLIGHT_MULT
	end
	target = math.max(MATH_SCALE, target)
	local a0, a1, a2, a3 = Parabola.controlPoints(mg, spawnTile, separateDst)
	local actualLengthInt = jsRound(Bezier.getLength(a0, a1, a2, a3) * 256)
	local num = actualLengthInt * MATH_SCALE
	local den = target
	local speedScaled = math.floor((num + math.floor(den / 2)) / den)
	return math.max(1, speedScaled / 256)
end

return MirvExecution
