--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/NukeExecution.ts and engine-lib/src/execution/NukeAlliance.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- An atom bomb, hydrogen bomb or MIRV warhead in flight.
--   - Launched from the closest ready silo (or a given source for
--     warheads) along a parabola; stacked launches from one silo wait a
--     tick each.
--   - Players hit hard enough break any alliance with the launcher and
--     their relation drops by 100 (not for warheads).
--   - On impact: blast tiles are relinquished and become fallout (water
--     with the water-nukes modifier), troops die tile by tile with
--     diminishing effect (attacks and boats too), and every unit inside the
--     outer radius except missiles is destroyed.
--   - A SAM missile closing in on the target tile cancels the detonation.

local DetMath = require(script.Parent.Parent.DetMath)
local GameTypes = require(script.Parent.Parent.GameTypes)
local Parabola = require(script.Parent.Parent.Pathfinding.Parabola)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)

local UnitType = GameTypes.UnitType
local PathStatus = PathFinding.PathStatus

local SPRITE_RADIUS = 16

local NukeExecution = {}
NukeExecution.__index = NukeExecution

export type NukeExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		mg: any,
		nuke: any,
		tilesToDestroyCache: { number }?,
		pathFinder: Parabola.Parabola,
		nukeType: string,
		player: any,
		dst: number,
		src: number?,
		speed: number,
		waitTicks: number,
		rocketDirectionUp: boolean,
	},
	NukeExecution
))

function NukeExecution.new(
	nukeType: string,
	player: any,
	dst: number,
	src: number?,
	speed: number?,
	waitTicks: number?,
	rocketDirectionUp: boolean?
): NukeExecution
	return setmetatable({
		active = true,
		mg = nil,
		nuke = nil,
		tilesToDestroyCache = nil,
		pathFinder = nil :: any,
		nukeType = nukeType,
		player = player,
		dst = dst,
		src = src,
		speed = speed or -1,
		waitTicks = waitTicks or 0,
		rocketDirectionUp = if rocketDirectionUp == nil then true else rocketDirectionUp,
	}, NukeExecution)
end

function NukeExecution.init(self: NukeExecution, mg: any, _ticks: number)
	self.mg = mg
	if self.speed == -1 then
		self.speed = mg:config():nukeSpeed(self.nukeType)
	end
	self.pathFinder = Parabola.new(mg, { increment = self.speed, directionUp = self.rocketDirectionUp })
end

function NukeExecution.target(self: NukeExecution): any
	return self.mg:owner(self.dst)
end

-- The blast: the inner disc, plus each outer-ring tile with chance 1/2 in
-- flood order (or a smoothed random rim with water nukes).
function NukeExecution._tilesToDestroy(self: NukeExecution): { number }
	if self.tilesToDestroyCache ~= nil then
		return self.tilesToDestroyCache
	end
	local mg = self.mg
	local magnitude = mg:config():nukeMagnitudes(self.nuke:type())
	local rand = PseudoRandom.new(mg:ticks())
	local inner2 = magnitude.inner * magnitude.inner
	local outer2 = magnitude.outer * magnitude.outer
	local result: { number }
	if mg:config():waterNukes() then
		local NUM_SAMPLES = 16
		local radiiSq = table.create(NUM_SAMPLES, 0)
		for i = 1, NUM_SAMPLES do
			radiiSq[i] = rand:nextFloat(inner2, outer2)
		end
		local prev = table.clone(radiiSq)
		for i = 0, NUM_SAMPLES - 1 do
			local l = (i - 1 + NUM_SAMPLES) % NUM_SAMPLES
			local r = (i + 1) % NUM_SAMPLES
			radiiSq[i + 1] = prev[i + 1] * 0.6 + prev[l + 1] * 0.2 + prev[r + 1] * 0.2
		end
		local cx, cy = mg:x(self.dst), mg:y(self.dst)
		local outer = magnitude.outer
		result = {}
		local x0, y0 = math.max(0, cx - outer), math.max(0, cy - outer)
		local x1, y1 = math.min(mg:width() - 1, cx + outer), math.min(mg:height() - 1, cy + outer)
		for py = y0, y1 do
			for px = x0, x1 do
				local dx, dy = px - cx, py - cy
				local d2 = dx * dx + dy * dy
				local keep = d2 <= outer2
				if keep and d2 > inner2 then
					local angle = DetMath.atan2(dy, dx) + math.pi
					local t = (angle / (2 * math.pi)) * NUM_SAMPLES
					local i0 = math.floor(t) % NUM_SAMPLES
					local i1 = (i0 + 1) % NUM_SAMPLES
					local frac = t - math.floor(t)
					local threshold = radiiSq[i0 + 1] * (1 - frac) + radiiSq[i1 + 1] * frac
					keep = d2 <= threshold
				end
				if keep then
					local tile = mg:ref(px, py)
					if not mg:isImpassable(tile) then
						table.insert(result, tile)
					end
				end
			end
		end
	else
		result = mg:bfs(self.dst, function(_, n: number): boolean
			local d2 = mg:euclideanDistSquared(self.dst, n)
			return d2 <= outer2 and (d2 <= inner2 or rand:chance(2)) and not mg:isImpassable(n)
		end)
	end
	self.tilesToDestroyCache = result
	return result
end

-- NukeAlliance.ts listNukeBreakAlliance: small ids of players with more
-- than `threshold` weighted tiles in the blast (inner 1, outer 0.5) or any
-- structure in it, in first-seen order.
local function listNukeBreakAlliance(game: any, targetTile: number, magnitude: any, threshold: number): { number }
	local inner2 = magnitude.inner * magnitude.inner
	local order: { number } = {}
	local counts: { [number]: number } = {}
	-- circleSearch's own walk (columns, then rows), without building its
	-- list of tiles: the build preview asks this for every pointer move.
	local cx, cy = game:x(targetTile), game:y(targetTile)
	local width, radius = game:width(), magnitude.outer
	local r2 = radius * radius
	local minY, maxY = math.max(0, cy - radius), math.min(game:height() - 1, cy + radius)
	for x = math.max(0, cx - radius), math.min(width - 1, cx + radius) do
		local dx2 = (cx - x) * (cx - x)
		for y = minY, maxY do
			local d2 = dx2 + (cy - y) * (cy - y)
			if d2 <= r2 then
				local owner = game:ownerID(y * width + x)
				if owner > 0 then
					if counts[owner] == nil then
						counts[owner] = 0
						table.insert(order, owner)
					end
					counts[owner] += if d2 <= inner2 then 1 else 0.5
				end
			end
		end
	end
	local out: { number } = {}
	local seen: { [number]: true } = {}
	for _, id in order do
		if counts[id] > threshold then
			seen[id] = true
			table.insert(out, id)
		end
	end
	for _, entry in game:nearbyUnits(targetTile, magnitude.outer, GameTypes.Structures) do
		local id = entry.unit:owner():smallID()
		if not seen[id] then
			seen[id] = true
			table.insert(out, id)
		end
	end
	return out
end
NukeExecution.listNukeBreakAlliance = listNukeBreakAlliance

-- NukeAlliance.ts wouldNukeBreakAlliance: an allied structure in the blast,
-- or an ally with more than `threshold` weighted tiles in it.
function NukeExecution.wouldNukeBreakAlliance(game: any, targetTile: number, magnitude: any, allySmallIds: { [number]: boolean }?, threshold: number): boolean
	if allySmallIds == nil or next(allySmallIds) == nil then
		return false
	end
	local allies = allySmallIds :: { [number]: boolean }
	if game:anyUnitNearby(targetTile, magnitude.outer, GameTypes.Structures, function(unit: any): boolean
		return unit:owner():isPlayer() and allies[unit:owner():smallID()] == true
	end) then
		return true
	end
	local inner2 = magnitude.inner * magnitude.inner
	local counts: { [number]: number } = {}
	local result = false
	game:circleSearch(targetTile, magnitude.outer, function(tile: number, d2: number): boolean
		local owner = game:ownerID(tile)
		if owner > 0 and allies[owner] then
			counts[owner] = (counts[owner] or 0) + (if d2 <= inner2 then 1 else 0.5)
			if counts[owner] > threshold then
				result = true
			end
		end
		return true
	end)
	return result
end

function NukeExecution._maybeBreakAlliances(self: NukeExecution)
	if self.nuke:type() == UnitType.MIRVWarhead then
		return
	end
	local mg = self.mg
	local magnitude = mg:config():nukeMagnitudes(self.nuke:type())
	local toBreak = listNukeBreakAlliance(mg, self.dst, magnitude, mg:config():nukeAllianceBreakThreshold())
	local breakSet: { [number]: true } = {}
	for _, id in toBreak do
		breakSet[id] = true
	end
	for _, incoming: any in table.clone(self.player:incomingAllianceRequests()) do
		if breakSet[incoming:requestor():smallID()] then
			incoming:reject()
		end
	end
	for _, smallID in toBreak do
		local attacked = mg:playerBySmallID(smallID)
		if attacked:isPlayer() then
			-- A request accepted mid-flight would dodge the break: reject it.
			local pending = nil
			for _, ar in attacked:incomingAllianceRequests() do
				if ar:requestor() == self.player then
					pending = ar
					break
				end
			end
			if pending then
				pending:reject()
			else
				local alliance = self.player:allianceWith(attacked)
				if alliance ~= nil then
					self.player:breakAlliance(alliance)
				end
				if attacked ~= self.player then
					attacked:updateRelation(self.player, -100)
				end
			end
		end
	end
end

function NukeExecution.tick(self: NukeExecution, ticks: number)
	local mg = self.mg
	if self.nuke == nil then
		local spawn = self.player:canBuild(self.nukeType, self.dst)
		if spawn == false then
			self.active = false
			return
		end
		if self.src == nil then
			self.src = spawn
		end
		local silo = nil
		for _, s in self.player:units(UnitType.MissileSilo) do
			if s:tile() == spawn then
				silo = s
				break
			end
		end
		-- Stacked purchases from one silo trail each other a tick apart.
		if silo ~= nil then
			local lastDep = 0
			for _, launchTick in silo:missileTimerQueue() do
				lastDep = math.max(launchTick + 1, lastDep + 1)
			end
			if lastDep > mg:ticks() then
				self.waitTicks += lastDep - mg:ticks()
			end
		end
		self.nuke = self.player:buildUnit(self.nukeType, self.src :: number, {
			targetTile = self.dst,
			trajectory = self:_getTrajectory(self.dst),
		})
		self.nuke:updateNukeState({ waitTicks = self.waitTicks })
		self:_recordMotionPlan(ticks)
		if self.nuke:type() ~= UnitType.MIRVWarhead then
			self:_maybeBreakAlliances()
		end
		if mg:hasOwner(self.dst) then
			local target = mg:owner(self.dst)
			if target:isPlayer() then
				if self.nukeType == UnitType.AtomBomb then
					mg:displayIncomingUnit(self.nuke:id(), "events_display.atom_bomb_inbound", "NUKE_INBOUND", target:id())
				elseif self.nukeType == UnitType.HydrogenBomb then
					mg:displayIncomingUnit(self.nuke:id(), "events_display.hydrogen_bomb_inbound", "HYDROGEN_BOMB_INBOUND", target:id())
				elseif self.nukeType == UnitType.MegaNuke then
					mg:displayIncomingUnit(self.nuke:id(), "events_display.mega_nuke_inbound", "HYDROGEN_BOMB_INBOUND", target:id())
				elseif self.nukeType == UnitType.Scattershot then
					mg:displayIncomingUnit(self.nuke:id(), "events_display.scattershot_inbound", "NUKE_INBOUND", target:id())
				end
			end
			if self.nukeType == UnitType.MIRV then
				mg:recordMirvLaunch()
			end
			mg:stats():bombLaunch(self.player, target, self.nukeType)
		end
		if self.nukeType == UnitType.Scattershot then
			self:_scatter()
		end
		if silo then
			silo:launch()
		end
		return
	end

	if not self.nuke:isActive() then
		self.active = false
		return
	end
	if self.waitTicks > 0 then
		self.waitTicks -= 1
		self.nuke:updateNukeState({ waitTicks = self.waitTicks })
		return
	end

	local result = self.pathFinder:next(self.src :: number, self.dst, self.speed)
	if result.status == PathStatus.COMPLETE then
		self.nuke:move(result.node)
		-- A SAM missile about to hit this nuke wins over the detonation.
		local nuke = self.nuke
		local intercepted = #mg:nearbyUnits(self.dst, mg:config():defaultSamMissileSpeed(), UnitType.SAMMissile, function(entry: any): boolean
			local unit = entry.unit
			if unit:owner() == nuke:owner() then
				return false
			end
			local t = unit:targetUnit()
			return t ~= nil and t:id() == nuke:id()
		end) >= 1
		if not intercepted then
			self:_detonate()
		end
	elseif result.status == PathStatus.NEXT then
		self:_updateNukeTargetable()
		self.nuke:move(result.node)
		self.nuke:setTrajectoryIndex(self.pathFinder:currentIndex())
	end
end

function NukeExecution.getNuke(self: NukeExecution): any
	return self.nuke
end

-- The client derives the nuke's position from this plan: a separate replay
-- of next(), because cached curve points don't advance one per tick.
function NukeExecution._recordMotionPlan(self: NukeExecution, ticks: number)
	if self.nuke == nil or self.src == nil then
		return
	end
	local src = self.src :: number
	local pf = Parabola.new(self.mg, { increment = self.speed, directionUp = self.rocketDirectionUp })
	local path = { src }
	local result = pf:next(src, self.dst, self.speed)
	while result.status == PathStatus.NEXT do
		table.insert(path, result.node)
		result = pf:next(src, self.dst, self.speed)
	end
	self.mg:recordMotionPlan({
		kind = "grid",
		unitId = self.nuke:id(),
		planId = 1,
		startTick = ticks + self.waitTicks + 1,
		ticksPerStep = 1,
		path = path,
	})
end

function NukeExecution._getTrajectory(self: NukeExecution, target: number): { { tile: number, targetable: boolean } }
	local out = {}
	local range = self.mg:config():defaultNukeTargetableRange()
	local rangeSquared = range * range
	for _, tile in self.pathFinder:findPath(self.src :: number, target) do
		table.insert(out, { tile = tile, targetable = self:_isTargetable(target, tile, rangeSquared) })
	end
	return out
end

-- Targetable near launch and near the target, not in mid-flight.
function NukeExecution._isTargetable(self: NukeExecution, targetTile: number, nukeTile: number, rangeSquared: number): boolean
	local mg = self.mg
	return mg:euclideanDistSquared(nukeTile, targetTile) < rangeSquared
		or (self.src ~= nil and mg:euclideanDistSquared(self.src, nukeTile) < rangeSquared)
end

function NukeExecution._updateNukeTargetable(self: NukeExecution)
	if self.nuke == nil or self.nuke:targetTile() == nil then
		return
	end
	local range = self.mg:config():defaultNukeTargetableRange()
	self.nuke:setTargetable(self:_isTargetable(self.nuke:targetTile(), self.nuke:tile(), range * range))
end

function NukeExecution._detonate(self: NukeExecution)
	local mg = self.mg
	local config = mg:config()
	local magnitude = config:nukeMagnitudes(self.nuke:type())
	local toDestroy = self:_tilesToDestroy()

	-- Players hit and their tile counts, in first-hit order (a JS Map).
	local hitOrder = {}
	local hitCount: { [any]: number } = {}
	for _, tile in toDestroy do
		local owner = mg:owner(tile)
		if owner:isPlayer() then
			owner:relinquish(tile)
			if hitCount[owner] == nil then
				hitCount[owner] = 0
				table.insert(hitOrder, owner)
			end
			hitCount[owner] += 1
		end
		if mg:isLand(tile) then
			mg:queueWaterConversion(tile)
		end
		mg:queueNukeImpact(tile)
	end

	for _, player in hitOrder do
		local numImpacted = hitCount[player]
		local tilesBefore = player:numTilesOwned() + numImpacted
		local ships = player:units(UnitType.TransportShip)
		local shipTroops: { [any]: number } = {}
		for _, unit in ships do
			shipTroops[unit] = unit:troops()
		end
		local attacks = player:outgoingAttacks()
		local maxTroops = config:maxTroops(player)
		for i = 0, numImpacted - 1 do
			local left = tilesBefore - i
			player:removeTroops(config:nukeDeathFactor(self.nukeType, player:troops(), left, maxTroops))
			for _, attack in attacks do
				local troops = attack:troops()
				attack:setTroops(troops - config:nukeDeathFactor(self.nukeType, troops, left, maxTroops))
			end
			for _, unit in ships do
				local troops = shipTroops[unit] or unit:troops()
				shipTroops[unit] = math.max(0, troops - config:nukeDeathFactor(self.nukeType, troops, left, maxTroops))
			end
		end
		for _, unit in ships do
			unit:setTroops(shipTroops[unit])
		end
	end

	local outer2 = magnitude.outer * magnitude.outer
	for _, unit in mg:units() do
		local t = unit:type()
		if not (GameTypes.isNuke[t] or t == UnitType.SAMMissile) then
			if mg:euclideanDistSquared(self.dst, unit:tile()) < outer2 then
				-- treatAFKFriendly, as warships target: no kill credit on friends.
				local friendly = self.player:isFriendly(unit:owner(), true)
				unit:delete(true, if friendly then nil else self.player)
			end
		end
	end

	self:_redrawBuildings(magnitude.outer + SPRITE_RADIUS)
	self.active = false
	self.nuke:setReachedTarget()
	self.nuke:delete(false)

	if self.nukeType == UnitType.AtomBomb or self.nukeType == UnitType.HydrogenBomb or self.nukeType == UnitType.MegaNuke or self.nukeType == UnitType.Scattershot then
		local key = if self.nukeType == UnitType.AtomBomb
			then "events_display.atom_bomb_detonated"
			elseif self.nukeType == UnitType.MegaNuke then "events_display.mega_nuke_detonated"
			elseif self.nukeType == UnitType.Scattershot then "events_display.scattershot_detonated"
			else "events_display.hydrogen_bomb_detonated"
		for _, impacted in hitOrder do
			mg:displayMessage(key, "NUKE_DETONATED", impacted:id(), nil, { name = self.player:displayName() })
		end
	end
	mg:stats():bombLand(self.player, self:target(), self.nuke:type())
end

-- Conquest's Arsenal (not OpenFront; docs/design/ARSENAL_V2.md): a
-- Scattershot leaves its silo with SCATTER_MIN..SCATTER_MAX MIRV warheads,
-- evenly round the aim point (a random turn, a little jitter),
-- SCATTER_NEAR..SCATTER_FAR tiles out, never onto the launcher's land or a
-- friend's. Each leaves a moment after the last. RoWorld's rule and numbers
-- (reference/roworld 2be8efb, Core/SimArsenal.luau _scatter_warheads, and
-- Core/Rules.luau SCATTER_*), rebuilt on OpenFront's warheads.
NukeExecution.SCATTER_MIN = 4
NukeExecution.SCATTER_MAX = 6
NukeExecution.SCATTER_NEAR = 28
NukeExecution.SCATTER_FAR = 46

function NukeExecution._scatter(self: NukeExecution)
	local mg = self.mg
	local player = self.player
	local rand = PseudoRandom.new(mg:ticks() * 7919 + self.nuke:id())
	local count = rand:nextInt(NukeExecution.SCATTER_MIN, NukeExecution.SCATTER_MAX + 1)
	local base = rand:nextFloat(0, 2 * math.pi)
	local ax, ay = mg:x(self.dst), mg:y(self.dst)
	local w, h = mg:width(), mg:height()
	local fired = 0
	for i = 0, count - 1 do
		local target: number? = nil
		for _ = 1, 6 do
			local angle = base + i * 2 * math.pi / count + rand:nextFloat(-0.3, 0.3)
			local radius = rand:nextFloat(NukeExecution.SCATTER_NEAR, NukeExecution.SCATTER_FAR)
			local x = math.floor(ax + math.cos(angle) * radius + 0.5)
			local y = math.floor(ay + math.sin(angle) * radius + 0.5)
			if x >= 0 and y >= 0 and x < w and y < h then
				local tile = mg:ref(x, y)
				local owner = mg:owner(tile)
				if not (owner:isPlayer() and (owner == player or player:isFriendly(owner))) then
					target = tile
					break
				end
			end
		end
		if target ~= nil then
			fired += 1
			mg:addExecution(NukeExecution.new(UnitType.MIRVWarhead, player, target, self.src, self.speed, self.waitTicks + fired * 2))
		end
	end
end

function NukeExecution._redrawBuildings(self: NukeExecution, range: number)
	local mg = self.mg
	for _, unit in mg:units() do
		if GameTypes.isStructure[unit:type()] and mg:euclideanDistSquared(self.dst, unit:tile()) < range * range then
			unit:touch()
		end
	end
end

function NukeExecution.cancel(self: NukeExecution)
	self.active = false
	if self.nuke ~= nil and self.nuke:isActive() then
		self.nuke:delete(false)
	end
end

function NukeExecution.owner(self: NukeExecution): any
	return self.player
end

function NukeExecution.isActive(self: NukeExecution): boolean
	return self.active
end

function NukeExecution.activeDuringSpawnPhase(_self: NukeExecution): boolean
	return false
end

return NukeExecution
