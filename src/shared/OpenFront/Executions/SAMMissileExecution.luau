--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/SAMMissileExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A SAM interceptor flying (defaultSamMissileSpeed steps a tick, air path)
-- to the interception tile its launcher chose. Reaching it destroys the
-- nuke (or, in Conquest, a Paratroopers plane). It gives up, freeing the nuke for other SAMs, if the nuke or the
-- launcher is gone or the nuke changed hands.

local GameTypes = require(script.Parent.Parent.GameTypes)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinding.PathStatus

local INTERCEPTED_KEYS = {
	[UnitType.AtomBomb] = "unit_type.atom_bomb",
	[UnitType.MegaNuke] = "unit_type.mega_nuke",
	[UnitType.Scattershot] = "unit_type.scattershot",
	[UnitType.HydrogenBomb] = "unit_type.hydrogen_bomb",
	[UnitType.MIRVWarhead] = "unit_type.mirv",
	[UnitType.Paratroopers] = "unit_type.paratroopers",
}

local SAMMissileExecution = {}
SAMMissileExecution.__index = SAMMissileExecution

export type SAMMissileExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		pathFinder: PathFinding.Stepper,
		missile: any,
		mg: any,
		speed: number,
		spawn: number,
		_owner: any,
		ownerUnit: any,
		target: any,
		targetTile: number,
	},
	SAMMissileExecution
))

function SAMMissileExecution.new(spawn: number, owner: any, ownerUnit: any, target: any, targetTile: number): SAMMissileExecution
	return setmetatable({
		active = true,
		pathFinder = nil :: any,
		missile = nil,
		mg = nil,
		speed = 0,
		spawn = spawn,
		_owner = owner,
		ownerUnit = ownerUnit,
		target = target,
		targetTile = targetTile,
	}, SAMMissileExecution)
end

function SAMMissileExecution.init(self: SAMMissileExecution, mg: any, ticks: number)
	self.pathFinder = PathFinding.Air(mg)
	self.mg = mg
	self.speed = mg:config():defaultSamMissileSpeed()
	self:tick(ticks)
end

function SAMMissileExecution.tick(self: SAMMissileExecution, _ticks: number)
	if self.missile == nil then
		self.missile = self._owner:buildUnit(UnitType.SAMMissile, self.spawn, { targetUnit = self.target })
	end
	local missile = self.missile
	if not missile:isActive() then
		self.active = false
		return
	end
	-- Only warheads can be hit, not the MIRV carrier.
	local t = self.target:type()
	-- Conquest: also Paratroopers planes (ParatroopersExecution aims these).
	local whitelisted = t == UnitType.AtomBomb or t == UnitType.HydrogenBomb or t == UnitType.MIRVWarhead or t == UnitType.MegaNuke or t == UnitType.Scattershot or t == UnitType.Paratroopers
	if not self.target:isActive() or not self.ownerUnit:isActive() or self.target:owner() == missile:owner() or not whitelisted then
		if self.target:isActive() then
			self.target:setTargetedBySAM(false)
		end
		missile:delete(false)
		self.active = false
		return
	end
	for _ = 1, self.speed do
		local result = self.pathFinder:next(missile:tile(), self.targetTile)
		if result.status == PathStatus.COMPLETE then
			self.mg:displayMessage("events_display.missile_intercepted", "SAM_HIT", self._owner:id(), nil, {
				unit = INTERCEPTED_KEYS[self.target:type()] or self.target:type(),
			})
			self.active = false
			self.target:delete(true, self._owner)
			missile:delete(false)
			self.mg:stats():bombIntercept(self._owner, self.target:type(), 1)
			return
		elseif result.status == PathStatus.NEXT then
			missile:move(result.node :: number)
		end
	end
end

function SAMMissileExecution.isActive(self: SAMMissileExecution): boolean
	return self.active
end

function SAMMissileExecution.activeDuringSpawnPhase(_self: SAMMissileExecution): boolean
	return false
end

return SAMMissileExecution
