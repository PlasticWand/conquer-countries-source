--!strict
--!native
-- Conquest's Arsenal (not OpenFront; docs/design/ARSENAL_V2.md): a finished
-- Airfield or Railgun. Like a missile silo (MissileSiloExecution) it holds
-- one shot, which reloads RELOAD ticks after it was fired: an Airfield
-- rearms in 30 s, a Railgun reloads in 25 s (RoWorld's RELOAD_TICKS,
-- reference/roworld 2be8efb Core/Rules.luau). Rapid Reload halves it.

local Config = require(script.Parent.Parent.Config)
local GameTypes = require(script.Parent.Parent.GameTypes)

local UnitType = GameTypes.UnitType

local LauncherExecution = {}
LauncherExecution.__index = LauncherExecution

LauncherExecution.RELOAD = table.freeze({
	[UnitType.Airfield] = 300,
	[UnitType.Railgun] = 250,
}) :: { [string]: number }

export type LauncherExecution = typeof(setmetatable({} :: { active: boolean, mg: any, launcher: any }, LauncherExecution))

function LauncherExecution.new(launcher: any): LauncherExecution
	return setmetatable({ active = true, mg = nil, launcher = launcher }, LauncherExecution)
end

function LauncherExecution.init(self: LauncherExecution, mg: any, _ticks: number)
	self.mg = mg
end

-- Ticks a launcher of `unitType` owned by `owner` takes to reload.
function LauncherExecution.reloadTicks(unitType: string, owner: any): number
	return Config.rapidReload(owner, LauncherExecution.RELOAD[unitType] or 0)
end

function LauncherExecution.tick(self: LauncherExecution, _ticks: number)
	local launcher = self.launcher
	if launcher:isUnderConstruction() then
		return
	end
	if not launcher:isActive() then
		self.active = false
		return
	end
	local fired = launcher:missileTimerQueue()[1]
	if fired == nil then
		return
	end
	if self.mg:ticks() - fired >= LauncherExecution.reloadTicks(launcher:type(), launcher:owner()) then
		launcher:reloadMissile()
	end
end

function LauncherExecution.isActive(self: LauncherExecution): boolean
	return self.active
end

function LauncherExecution.activeDuringSpawnPhase(_self: LauncherExecution): boolean
	return false
end

return LauncherExecution
