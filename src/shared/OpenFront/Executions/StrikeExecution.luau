--!strict
--!native
-- Conquest's Arsenal (not OpenFront; docs/design/ARSENAL_V2.md): an Air
-- Strike or a Railgun shot. RoWorld's rules and numbers (reference/roworld
-- 2be8efb: Core/SimNukes.luau's launch, Core/SimArsenal.luau _strike, and
-- Core/Rules.luau AIRSTRIKE_*, SLUG_*, STRIKE_DAMAGE, NUKE_SPEED_FULL,
-- launch_range), rebuilt as an OpenFront-style execution.
--
-- It leaves the nearest loaded launcher (an Airfield within reach of the
-- target, or any Railgun: Player.strikeSpawn), which then reloads
-- (LauncherExecution), and flies straight at `speed` tiles a tick: a public
-- unit nobody can intercept. On impact, every army that is neither the
-- shooter's nor a friend's and has land in the `radius` disc loses
-- min(troops, tiles hit x perTile, troops x frac), and its attacks and boats
-- lose the same share; every such structure in the disc takes `damage`
-- (StructureDamage).

local GameTypes = require(script.Parent.Parent.GameTypes)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local StructureDamage = require(script.Parent.Parent.StructureDamage)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinding.PathStatus

local StrikeExecution = {}
StrikeExecution.__index = StrikeExecution

export type Spec = { launcher: string, reach: number, speed: number, radius: number, perTile: number, frac: number, damage: number, lang: string }

-- By munition type. `reach` 0: no limit.
StrikeExecution.SPEC = table.freeze({
	[UnitType.AirStrike] = table.freeze({ launcher = UnitType.Airfield, reach = 156, speed = 8, radius = 15, perTile = 60, frac = 0.06, damage = 600, lang = "air_strike" }),
	[UnitType.RailgunShot] = table.freeze({ launcher = UnitType.Railgun, reach = 0, speed = 80, radius = 5, perTile = 150, frac = 0.04, damage = 1000, lang = "railgun_shot" }),
}) :: { [string]: Spec }

export type StrikeExecution = typeof(setmetatable(
	{} :: { active: boolean, mg: any, kind: string, player: any, dst: number, src: number?, unit: any, pathFinder: any },
	StrikeExecution
))

function StrikeExecution.new(kind: string, player: any, dst: number): StrikeExecution
	return setmetatable({ active = true, mg = nil, kind = kind, player = player, dst = dst, src = nil, unit = nil, pathFinder = nil }, StrikeExecution)
end

function StrikeExecution.init(self: StrikeExecution, mg: any, _ticks: number)
	self.mg = mg
	self.pathFinder = PathFinding.Air(mg)
end

-- What a strike of `kind` landing on `tile` does (also called by tests).
function StrikeExecution.impact(mg: any, shooter: any, kind: string, tile: number)
	local spec = StrikeExecution.SPEC[kind]
	local r = spec.radius
	local r2 = r * r
	local cx, cy = mg:x(tile), mg:y(tile)
	local w, h = mg:width(), mg:height()
	-- Land under the blast, per enemy army.
	local hit: { [any]: number } = {}
	local order = {}
	for y = math.max(0, math.floor(cy - r)), math.min(h - 1, math.ceil(cy + r)) do
		for x = math.max(0, math.floor(cx - r)), math.min(w - 1, math.ceil(cx + r)) do
			local dx, dy = x - cx, y - cy
			if dx * dx + dy * dy <= r2 then
				local owner = mg:owner(mg:ref(x, y))
				if owner:isPlayer() and owner ~= shooter and not shooter:isFriendly(owner) then
					if hit[owner] == nil then
						hit[owner] = 0
						table.insert(order, owner)
					end
					hit[owner] += 1
				end
			end
		end
	end
	for _, victim in order do
		local troops = victim:troops()
		local kill = math.floor(math.min(troops, hit[victim] * spec.perTile, troops * spec.frac))
		if kill > 0 then
			local keep = 1 - kill / math.max(troops, 1)
			victim:removeTroops(kill)
			-- The same share of its armies in the field and at sea.
			for _, attack in victim:outgoingAttacks() do
				attack:setTroops(math.floor(attack:troops() * keep))
			end
			for _, boat in victim:units(UnitType.TransportShip) do
				boat:setTroops(math.floor(boat:troops() * keep))
			end
		end
		mg:displayMessage(`events_display.{spec.lang}_hit`, "NUKE_DETONATED", victim:id(), nil, { name = shooter:displayName() })
	end
	StructureDamage.inRadius(mg, shooter, tile, r, spec.damage)
end

function StrikeExecution.tick(self: StrikeExecution, _ticks: number)
	local mg = self.mg
	local spec = StrikeExecution.SPEC[self.kind]
	if self.unit == nil then
		local spawn = self.player:canBuild(self.kind, self.dst)
		if spawn == false then
			self.active = false
			return
		end
		self.src = spawn
		for _, launcher in self.player:units(spec.launcher) do
			if launcher:tile() == spawn then
				launcher:launch()
				break
			end
		end
		self.unit = self.player:buildUnit(self.kind, spawn, { targetTile = self.dst })
		-- Where it left from, for the launch flash (Replication).
		self.unit._sourceTile = spawn
		return
	end
	local unit = self.unit
	if not unit:isActive() then
		self.active = false
		return
	end
	for _ = 1, spec.speed do
		local result = self.pathFinder:next(unit:tile(), self.dst)
		if result.status == PathStatus.COMPLETE then
			self.active = false
			StrikeExecution.impact(mg, self.player, self.kind, self.dst)
			unit:setReachedTarget()
			unit:delete(false)
			return
		elseif result.status == PathStatus.NEXT then
			unit:move(result.node :: number)
		else
			self.active = false
			unit:delete(false)
			return
		end
	end
end

function StrikeExecution.isActive(self: StrikeExecution): boolean
	return self.active
end

function StrikeExecution.activeDuringSpawnPhase(_self: StrikeExecution): boolean
	return false
end

return StrikeExecution
