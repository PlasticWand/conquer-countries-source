--!strict
--!native
-- Conquest's Arsenal (not OpenFront; docs/design/ARSENAL_V2.md): one Artillery
-- shell. RoWorld's numbers (reference/roworld 2be8efb, Core/Rules.luau
-- SHELL_KILL_*, STRIKE_DAMAGE, STRUCT_HP), rebuilt as an OpenFront execution.
--
-- The shell is a public unit that flies straight (OpenFront's air steps, as
-- a warship's shell) SPEED tiles a tick from its battery to the target tile,
-- so the target sees it coming. On impact it kills KILL_FRAC of the troops of
-- whoever owns the tile then (between KILL_MIN and KILL_MAX, internal troop
-- units), unless that's the shooter or a friend, and does DAMAGE to every
-- non-friendly structure within DAMAGE_RADIUS tiles (StructureDamage).

local GameTypes = require(script.Parent.Parent.GameTypes)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local StructureDamage = require(script.Parent.Parent.StructureDamage)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinding.PathStatus

local ArtilleryShellExecution = {}
ArtilleryShellExecution.__index = ArtilleryShellExecution

ArtilleryShellExecution.SPEED = 3
ArtilleryShellExecution.KILL_FRAC = 0.0288
ArtilleryShellExecution.KILL_MIN = 1440
ArtilleryShellExecution.KILL_MAX = 19200
ArtilleryShellExecution.DAMAGE = 150
ArtilleryShellExecution.DAMAGE_RADIUS = 1.5

export type ArtilleryShellExecution = typeof(setmetatable(
	{} :: { active: boolean, mg: any, owner: any, from: number, target: number, shell: any, pathFinder: any },
	ArtilleryShellExecution
))

function ArtilleryShellExecution.new(owner: any, from: number, target: number): ArtilleryShellExecution
	return setmetatable({ active = true, mg = nil, owner = owner, from = from, target = target, shell = nil, pathFinder = nil }, ArtilleryShellExecution)
end

function ArtilleryShellExecution.init(self: ArtilleryShellExecution, mg: any, _ticks: number)
	self.mg = mg
	self.pathFinder = PathFinding.Air(mg)
end

-- What a shell landing on `tile` does (also called by tests).
function ArtilleryShellExecution.impact(mg: any, shooter: any, tile: number)
	local victim = mg:owner(tile)
	if victim:isPlayer() and victim ~= shooter and not shooter:isFriendly(victim) then
		local kill = math.clamp(math.floor(victim:troops() * ArtilleryShellExecution.KILL_FRAC), ArtilleryShellExecution.KILL_MIN, ArtilleryShellExecution.KILL_MAX)
		victim:removeTroops(kill)
	end
	StructureDamage.inRadius(mg, shooter, tile, ArtilleryShellExecution.DAMAGE_RADIUS, ArtilleryShellExecution.DAMAGE)
end

function ArtilleryShellExecution.tick(self: ArtilleryShellExecution, _ticks: number)
	if self.shell == nil then
		if not self.owner:isAlive() then
			self.active = false
			return
		end
		self.shell = self.owner:buildUnit(UnitType.ArtilleryShell, self.from, { targetTile = self.target })
		-- Where it was fired from, for the battery's muzzle flash (Replication).
		self.shell._sourceTile = self.from
	end
	local shell = self.shell
	if not shell:isActive() then
		self.active = false
		return
	end
	for _ = 1, ArtilleryShellExecution.SPEED do
		local result = self.pathFinder:next(shell:tile(), self.target)
		if result.status == PathStatus.COMPLETE then
			self.active = false
			ArtilleryShellExecution.impact(self.mg, self.owner, self.target)
			shell:setReachedTarget()
			shell:delete(false)
			return
		elseif result.status == PathStatus.NEXT then
			shell:move(result.node :: number)
		else
			self.active = false
			shell:delete(false)
			return
		end
	end
end

function ArtilleryShellExecution.isActive(self: ArtilleryShellExecution): boolean
	return self.active
end

function ArtilleryShellExecution.activeDuringSpawnPhase(_self: ArtilleryShellExecution): boolean
	return false
end

return ArtilleryShellExecution
