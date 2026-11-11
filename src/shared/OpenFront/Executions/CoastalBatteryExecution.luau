--!strict
--!native
-- Conquest's own Arsenal item (not OpenFront or RoWorld;
-- docs/design/ARSENAL_V2.md, Coastal Battery, Bruno 2026-11-09).
--
-- A finished battery on the shore fires OpenFront's warship shell
-- (ShellExecution, with the battery as the firing unit) every RELOAD ticks
-- at the nearest enemy Transport or Warship within Config.COASTAL_RANGE:
-- not its owner's, a teammate's or an ally's, never a trade ship. A
-- transport has no health, so one shell sinks it; a warship takes 200-300.
-- A captured battery fires for its new owner.

local Config = require(script.Parent.Parent.Config)
local GameTypes = require(script.Parent.Parent.GameTypes)
local ShellExecution = require(script.Parent.ShellExecution)

local UnitType = GameTypes.UnitType

local CoastalBatteryExecution = {}
CoastalBatteryExecution.__index = CoastalBatteryExecution

CoastalBatteryExecution.RANGE = Config.COASTAL_RANGE
-- Ticks between shots (Rapid Reload halves it).
CoastalBatteryExecution.RELOAD = 30
local TARGETS = { UnitType.TransportShip, UnitType.Warship }

export type CoastalBatteryExecution = typeof(setmetatable(
	{} :: { active: boolean, mg: any, battery: any, readyAt: number, shot: { [any]: boolean } },
	CoastalBatteryExecution
))

function CoastalBatteryExecution.new(battery: any): CoastalBatteryExecution
	return setmetatable({ active = true, mg = nil, battery = battery, readyAt = 0, shot = {} }, CoastalBatteryExecution)
end

function CoastalBatteryExecution.init(self: CoastalBatteryExecution, mg: any, _ticks: number)
	self.mg = mg
end

-- The nearest boat in range the battery may shoot (ties to the lower id),
-- skipping transports a shell is already on.
function CoastalBatteryExecution._target(self: CoastalBatteryExecution): any?
	local battery = self.battery
	local owner = battery:owner()
	local best, bestD = nil, math.huge
	for _, entry in self.mg:nearbyUnits(battery:tile(), CoastalBatteryExecution.RANGE, TARGETS) do
		local unit = entry.unit
		local other = unit:owner()
		if unit:isActive() and other ~= owner and not owner:isFriendly(other) and not self.shot[unit] then
			if entry.distSquared < bestD or (entry.distSquared == bestD and unit:id() < (best :: any):id()) then
				best, bestD = unit, entry.distSquared
			end
		end
	end
	return best
end

function CoastalBatteryExecution.tick(self: CoastalBatteryExecution, ticks: number)
	local battery = self.battery
	if not battery:isActive() then
		self.active = false
		return
	end
	-- (Sabotage, ARSENAL_V2: silent while dark.)
	if battery:isUnderConstruction() or ticks < self.readyAt or battery:isDark() then
		return
	end
	for unit in self.shot do
		if not unit:isActive() then
			self.shot[unit] = nil
		end
	end
	local target = self:_target()
	if target == nil then
		return
	end
	self.mg:addExecution(ShellExecution.new(battery:tile(), battery:owner(), battery, target))
	-- One shell sinks a transport: don't send another after it.
	if target:type() == UnitType.TransportShip then
		self.shot[target] = true
	end
	self.readyAt = ticks + Config.rapidReload(battery:owner(), CoastalBatteryExecution.RELOAD)
end

function CoastalBatteryExecution.isActive(self: CoastalBatteryExecution): boolean
	return self.active
end

function CoastalBatteryExecution.activeDuringSpawnPhase(_self: CoastalBatteryExecution): boolean
	return false
end

return CoastalBatteryExecution
