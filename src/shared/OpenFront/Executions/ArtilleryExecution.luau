--!strict
--!native
-- Conquest's Arsenal (not OpenFront; docs/design/ARSENAL_V2.md, Bruno 2026-11-08):
-- a finished Artillery battery. It shells enemy land within ARTILLERY_RANGE on
-- its own. The rules and numbers are RoWorld's (reference/roworld 2be8efb,
-- src/shared/Core/Rules.luau "Artillery" and Core/SimArsenal.luau), rebuilt
-- here as an OpenFront-style execution.
--
-- Every 40-70 ticks (a gap rolled per shot; a new battery waits one gap
-- first), it fires at the nearest enemy structure in range, or else at the
-- first of up to 24 random tiles within range owned by a player that is
-- neither its owner nor friendly to it. With nothing found it looks again in
-- 20 ticks. A captured battery fires for its new owner.

local ArtilleryShellExecution = require(script.Parent.ArtilleryShellExecution)
local Config = require(script.Parent.Parent.Config)
local GameTypes = require(script.Parent.Parent.GameTypes)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)

local ArtilleryExecution = {}
ArtilleryExecution.__index = ArtilleryExecution

ArtilleryExecution.RANGE = Config.ARTILLERY_RANGE
ArtilleryExecution.GAP_MIN = 40
ArtilleryExecution.GAP_MAX = 70
ArtilleryExecution.IDLE_TICKS = 20
ArtilleryExecution.SAMPLES = 24

export type ArtilleryExecution = typeof(setmetatable(
	{} :: { active: boolean, mg: any, battery: any, random: PseudoRandom.PseudoRandom?, nextFire: number? },
	ArtilleryExecution
))

function ArtilleryExecution.new(battery: any): ArtilleryExecution
	return setmetatable({ active = true, mg = nil, battery = battery, random = nil, nextFire = nil }, ArtilleryExecution)
end

function ArtilleryExecution.init(self: ArtilleryExecution, mg: any, ticks: number)
	self.mg = mg
	-- Seeded by the tick and the battery, so every battery rolls its own gaps.
	self.random = PseudoRandom.new(ticks * 7919 + self.battery:id())
end

local function gap(self: ArtilleryExecution): number
	-- Rapid Reload halves it (RoWorld's _battery_gap).
	return Config.rapidReload(self.battery:owner(), (self.random :: PseudoRandom.PseudoRandom):nextInt(ArtilleryExecution.GAP_MIN, ArtilleryExecution.GAP_MAX + 1))
end

-- Where the battery aims: the nearest structure in range that is neither its
-- owner's nor a friend's (ties to the lower tile; RoWorld's _battery_target),
-- else an enemy tile found in up to SAMPLES random tries. Nil: nothing.
function ArtilleryExecution._target(self: ArtilleryExecution, from: number): number?
	local mg, owner = self.mg, self.battery:owner()
	local random = self.random :: PseudoRandom.PseudoRandom
	local r = ArtilleryExecution.RANGE
	local best, bestD = nil, math.huge
	for _, entry in mg:nearbyUnits(from, r, GameTypes.Structures, function(entry: any): boolean
		local other = entry.unit:owner()
		return other:isPlayer() and other ~= owner and not owner:isFriendly(other)
	end, true) do
		local tile = entry.unit:tile()
		if entry.distSquared < bestD or (entry.distSquared == bestD and tile < (best :: number)) then
			best, bestD = tile, entry.distSquared
		end
	end
	if best ~= nil then
		return best
	end
	local fx, fy = mg:x(from), mg:y(from)
	local w, h = mg:width(), mg:height()
	for _ = 1, ArtilleryExecution.SAMPLES do
		local dx, dy = random:nextInt(-r, r + 1), random:nextInt(-r, r + 1)
		local x, y = fx + dx, fy + dy
		if dx * dx + dy * dy <= r * r and x >= 0 and y >= 0 and x < w and y < h then
			local tile = mg:ref(x, y)
			local other = mg:owner(tile)
			if other:isPlayer() and other ~= owner and not owner:isFriendly(other) then
				return tile
			end
		end
	end
	return nil
end

function ArtilleryExecution.tick(self: ArtilleryExecution, ticks: number)
	local battery = self.battery
	if not battery:isActive() then
		self.active = false
		return
	end
	if battery:isUnderConstruction() then
		return
	end
	if self.nextFire == nil then
		self.nextFire = ticks + gap(self)
		return
	end
	if ticks < (self.nextFire :: number) then
		return
	end
	-- Our Sabotage (ARSENAL_V2): silent while dark.
	if battery:isDark() then
		return
	end
	local from = battery:tile()
	local target = self:_target(from)
	if target == nil then
		self.nextFire = ticks + ArtilleryExecution.IDLE_TICKS
		return
	end
	self.mg:addExecution(ArtilleryShellExecution.new(battery:owner(), from, target))
	self.nextFire = ticks + gap(self)
end

function ArtilleryExecution.isActive(self: ArtilleryExecution): boolean
	return self.active
end

function ArtilleryExecution.activeDuringSpawnPhase(_self: ArtilleryExecution): boolean
	return false
end

return ArtilleryExecution
