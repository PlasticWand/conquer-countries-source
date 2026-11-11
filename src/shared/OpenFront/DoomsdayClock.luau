--!strict
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/game/DoomsdayClock.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Doomsday Clock threshold math, shared by the sim (DoomsdayClockExecution)
-- and, later, the HUD readout. The required share of the map rises in waves
-- after a 10-minute grace; a side below it is warned, drained, then rots.
-- Integer-only and floored, so every result is exact.

local PseudoRandom = require(script.Parent.PseudoRandom)

local imul = PseudoRandom.imul

local DoomsdayClock = {}

-- Share (basis points) at the end of each wave's ramp: FFA, and team games'
-- raised rungs.
local LEVELS = { 200, 400, 700, 1100, 1700, 2500, 3500 }
local LEVELS_TEAM = { 300, 600, 1000, 1500, 2100, 2800, 3500 }

type Schedule = { graceSeconds: number, rampSeconds: { number }, pauseSeconds: { number }, levels: { number } }

local SCHEDULES: { [string]: Schedule } = {
	normal = { graceSeconds = 600, rampSeconds = { 168, 168, 168, 168, 168, 168, 168 }, pauseSeconds = { 54, 54, 54, 54, 54, 54, 0 }, levels = LEVELS },
	slow = { graceSeconds = 600, rampSeconds = { 240, 240, 240, 240, 240, 240, 240 }, pauseSeconds = { 70, 70, 70, 70, 70, 70, 0 }, levels = LEVELS },
	fast = { graceSeconds = 600, rampSeconds = { 102, 102, 102, 102, 102, 102, 102 }, pauseSeconds = { 31, 31, 31, 31, 31, 31, 0 }, levels = LEVELS },
	veryfast = { graceSeconds = 600, rampSeconds = { 36, 36, 36, 36, 36, 36, 36 }, pauseSeconds = { 8, 8, 8, 8, 8, 8, 0 }, levels = LEVELS },
}

export type Profile = { speed: string, teamGame: boolean? }

local function schedule(profile: Profile): Schedule
	local base = SCHEDULES[profile.speed] or SCHEDULES.normal
	if profile.teamGame == true then
		return { graceSeconds = base.graceSeconds, rampSeconds = base.rampSeconds, pauseSeconds = base.pauseSeconds, levels = LEVELS_TEAM }
	end
	return base
end

-- Required share (basis points) at `elapsed` game seconds.
function DoomsdayClock.requiredBasisPoints(profile: Profile, elapsed: number): number
	local s = schedule(profile)
	if elapsed <= s.graceSeconds then
		return 0
	end
	local t = elapsed - s.graceSeconds
	local prev = 0
	for i, target in s.levels do
		local ramp = s.rampSeconds[i]
		if t < ramp then
			return prev + math.floor(((target - prev) * t) / ramp)
		end
		t -= ramp
		if t < s.pauseSeconds[i] then
			return target
		end
		t -= s.pauseSeconds[i]
		prev = target
	end
	return s.levels[#s.levels]
end

-- doomsdayClockRequiredTiles: the tiles one side must hold.
function DoomsdayClock.requiredTiles(profile: Profile, land: number, elapsed: number): number
	if land <= 0 then
		return 0
	end
	return math.floor((DoomsdayClock.requiredBasisPoints(profile, elapsed) * land) / 10000)
end

DoomsdayClock.ROT_NOISE_SCALE = 65536
local R2_X = 3242174889
local R2_Y = 2447445413
local GOLDEN = 0x9e3779b9
local TWO32 = 2 ^ 32

-- rotSpeckleNoise: an even (R2 lattice) per-tile value in [0, 65536).
function DoomsdayClock.rotSpeckleNoise(x: number, y: number, salt: number): number
	local h = (imul(x, R2_X) + imul(y, R2_Y) + imul(salt, GOLDEN)) % TWO32
	return bit32.rshift(h, 16)
end

-- rotFrontNoise: a hashed per-tile value in [0, 65536) to order the front.
function DoomsdayClock.rotFrontNoise(tile: number, salt: number): number
	local h = bit32.bxor(imul(tile, 0x27d4eb2d), imul(salt, GOLDEN))
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = imul(h, 0x2545f491)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	return bit32.rshift(h, 16)
end

-- doomsdayClockTroopFloor: linear from floorStartPercent down to
-- drainFloorPercent over floorDecaySeconds, then flat.
function DoomsdayClock.troopFloor(maxTroops: number, secondsPastWarn: number, cfg: any): number
	local finish = cfg.drainFloorPercent
	local span = cfg.floorStartPercent - finish
	local t = math.max(0, secondsPastWarn)
	local pct = if span > 0 and cfg.floorDecaySeconds > 0 and t < cfg.floorDecaySeconds
		then cfg.floorStartPercent - math.floor((span * t) / cfg.floorDecaySeconds)
		else finish
	return math.floor((maxTroops * pct) / 100)
end

local DRAIN_CURVE_SCALE = 1000000

local function drainCurveFraction(t: number, r: number, exponent: number): number
	local ratio = math.floor((t * DRAIN_CURVE_SCALE) / r)
	local acc = DRAIN_CURVE_SCALE
	for _ = 1, exponent do
		acc = math.floor((acc * ratio) / DRAIN_CURVE_SCALE)
	end
	return acc
end

-- doomsdayClockDrain: what a doomed side loses this second (troops, or a
-- warship's health with a convex curve).
function DoomsdayClock.drain(maxTroops: number, secondsPastWarn: number, cfg: any, curveExponent: number?): number
	local exponent = curveExponent or 1
	local t = math.max(0, secondsPastWarn)
	local r = cfg.drainRampSeconds
	local span = cfg.drainMaxPercent - cfg.drainStartPercent
	local pct = cfg.drainMaxPercent
	if r > 0 and t < r then
		local grown = if exponent <= 1
			then math.floor((span * t) / r)
			else math.floor((span * drainCurveFraction(t, r, exponent)) / DRAIN_CURVE_SCALE)
		pct = cfg.drainStartPercent + grown
	end
	return math.max(1, math.floor((maxTroops * pct) / 100))
end

-- doomsdayClockRotQuota: ceil(tilesLeft / secondsLeft) to meet the deadline.
function DoomsdayClock.rotQuota(tilesLeft: number, secondsUnder: number, cfg: any): number
	if tilesLeft <= 0 or cfg.rotDeathSeconds <= 0 then
		return 0
	end
	local secondsLeft = math.max(1, cfg.rotDeathSeconds - secondsUnder)
	return math.ceil(tilesLeft / secondsLeft)
end

return DoomsdayClock
