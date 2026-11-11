--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/ShellExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A warship shell: three air-path steps a tick toward its target unit.
-- Damage is 200-300 (five steps of 25, from PseudoRandom(creation tick)),
-- scaled by the firing warship's veterancy. A shell whose warship sank
-- lives shellLifetime more ticks. A killing blow earns the warship veterancy.

local GameTypes = require(script.Parent.Parent.GameTypes)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinding.PathStatus

local ShellExecution = {}
ShellExecution.__index = ShellExecution

export type ShellExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		pathFinder: PathFinding.Stepper,
		shell: any,
		mg: any,
		destroyAtTick: number,
		random: PseudoRandom.PseudoRandom,
		spawn: number,
		_owner: any,
		ownerUnit: any,
		target: any,
	},
	ShellExecution
))

function ShellExecution.new(spawn: number, owner: any, ownerUnit: any, target: any): ShellExecution
	return setmetatable({
		active = true,
		pathFinder = nil :: any,
		shell = nil,
		mg = nil,
		destroyAtTick = -1,
		random = nil :: any,
		spawn = spawn,
		_owner = owner,
		ownerUnit = ownerUnit,
		target = target,
	}, ShellExecution)
end

function ShellExecution.init(self: ShellExecution, mg: any, _ticks: number)
	self.pathFinder = PathFinding.Air(mg)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
end

function ShellExecution.tick(self: ShellExecution, _ticks: number)
	local mg = self.mg
	if self.shell == nil then
		self.shell = self._owner:buildUnit(UnitType.Shell, self.spawn, {})
		-- Conquest: where it was fired from (a warship or our Coastal Battery),
		-- for the client's muzzle flash. Presentation only.
		self.shell._sourceTile = self.spawn
	end
	local shell = self.shell
	if not shell:isActive() then
		self.active = false
		return
	end
	if not self.target:isActive() or self.target:owner() == shell:owner() or (self.destroyAtTick ~= -1 and mg:ticks() >= self.destroyAtTick) then
		shell:delete(false)
		self.active = false
		return
	end
	if self.destroyAtTick == -1 and not self.ownerUnit:isActive() then
		self.destroyAtTick = mg:ticks() + mg:config():shellLifetime()
	end
	for _ = 1, 3 do
		local result = self.pathFinder:next(shell:tile(), self.target:tile())
		if result.status == PathStatus.COMPLETE then
			self.active = false
			local targetType = self.target:type()
			local wasActive = self.target:isActive()
			self.target:modifyHealth(-self:_effectOnTarget(), self._owner)
			if wasActive and not self.target:isActive() and self.ownerUnit:isActive() and self.ownerUnit:type() == UnitType.Warship then
				self.ownerUnit:recordKill(targetType)
			end
			shell:setReachedTarget()
			shell:delete(false)
			return
		elseif result.status == PathStatus.NEXT then
			shell:move(result.node :: number)
		end
	end
end

function ShellExecution._effectOnTarget(self: ShellExecution): number
	local baseDamage = self.mg:config():unitInfo(UnitType.Shell).damage or 250
	local roll = self.random:nextInt(1, 6)
	local multiplier = (roll - 1) * 25 + 200
	local veterancy = self.ownerUnit:veterancy()
	if veterancy > 0 then
		local bonusPercent = self.mg:config():warshipVeterancyShellDamageBonus()
		multiplier = math.floor((multiplier * (100 + veterancy * bonusPercent)) / 100)
	end
	return math.floor((baseDamage / 250) * multiplier + 0.5)
end

function ShellExecution.isActive(self: ShellExecution): boolean
	return self.active
end

function ShellExecution.activeDuringSpawnPhase(_self: ShellExecution): boolean
	return false
end

return ShellExecution
