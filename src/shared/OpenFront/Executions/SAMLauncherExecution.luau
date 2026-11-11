--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/SAMLauncherExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A SAM launcher: one missile per level, each reloading SAMCooldown ticks
-- after firing. Its targeting fires early so the interception lands
-- inside its range:
--   - For each enemy nuke in detection range (4x max SAM range) it finds
--     the first trajectory tile that is targetable, inside the range the
--     launcher will have by then, and reachable by its missile in time.
--   - Results are cached per nuke: a launch tick, -1 (unreachable at this
--     level; retried after an upgrade) or -2 (never in reach).
--   - Targets due now are fired at in score order: hydrogen bombs first,
--     then nukes aimed closest to the launcher, then the most urgent.

local Config = require(script.Parent.Parent.Config)
local GameTypes = require(script.Parent.Parent.GameTypes)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local Util = require(script.Parent.Parent.Util)

local UnitType = GameTypes.UnitType

type Target = { unit: any, tile: number, score: number? }
type Cached = { tick: number, tile: number, minDistSq: number, lastSeenTick: number }

-- SAMTargetingSystem ---------------------------------------------------------------

local Targeting = {}
Targeting.__index = Targeting

type Targeting = typeof(setmetatable(
	{} :: { mg: any, sam: any, precomputed: { [number]: Cached }, missileSpeed: number },
	Targeting
))

function Targeting.new(mg: any, sam: any): Targeting
	return setmetatable({ mg = mg, sam = sam, precomputed = {}, missileSpeed = mg:config():defaultSamMissileSpeed() }, Targeting)
end

function Targeting.onLevelUp(self: Targeting)
	for id, cached in self.precomputed do
		if cached.tick == -1 then
			self.precomputed[id] = nil
		end
	end
end

function Targeting.updateUnreachableNukes(self: Targeting, currentTick: number)
	for id, cached in self.precomputed do
		if cached.lastSeenTick ~= currentTick then
			self.precomputed[id] = nil
		end
	end
end

function Targeting._tickToReach(self: Targeting, from: number, tile: number): number
	return math.ceil(self.mg:manhattanDist(from, tile) / self.missileSpeed)
end

-- Interception on the last flight tile, when the nuke's target itself is
-- inside the range.
function Targeting._checkDetonationInterception(self: Targeting, unit: any, samTile: number, ticks: number): { tick: number, tile: number }?
	local mg = self.mg
	local trajectory = unit:trajectory()
	local n = #trajectory
	local maxIdx = n - 2 -- 0-based
	local finalTile = trajectory[n]
	if finalTile == nil or not finalTile.targetable then
		return nil
	end
	local curIdx = unit:trajectoryIndex()
	local waitTicks = unit:nukeState().waitTicks or 0
	local expTicks = n - 1 - curIdx + waitTicks
	local range = mg:config():dynamicSamRange(self.sam, ticks + expTicks)
	if mg:euclideanDistSquared(samTile, finalTile.tile) > range * range then
		return nil
	end
	local flightTile = trajectory[maxIdx + 1]
	if flightTile == nil or not flightTile.targetable then
		return nil
	end
	local nukeTicks = maxIdx - curIdx + waitTicks
	local samTicks = self:_tickToReach(samTile, flightTile.tile)
	local before = nukeTicks - samTicks
	return if before >= 0 then { tick = before, tile = flightTile.tile } else nil
end

function Targeting._computeInterceptionTile(self: Targeting, unit: any, samTile: number, ticks: number): Cached
	local mg = self.mg
	local config = mg:config()
	local trajectory = unit:trajectory()
	local curIdx = unit:trajectoryIndex()
	local waitTicks = unit:nukeState().waitTicks or 0
	local maxIdx = #trajectory - 2
	local maxSamRangeSq = config:maxSamRange() ^ 2
	local minDistSq = math.huge
	local closestTile = samTile
	local incSteps = 0
	local lastDistSq = -1
	for i = curIdx, maxIdx do
		local tile = trajectory[i + 1]
		local distSq = mg:euclideanDistSquared(samTile, tile.tile)
		if distSq < minDistSq then
			minDistSq = distSq
			closestTile = tile.tile
		end
		incSteps = if lastDistSq ~= -1 and distSq > lastDistSq then incSteps + 1 else 0
		lastDistSq = distSq
		local nukeTicks = i - curIdx + waitTicks
		local samTicks = self:_tickToReach(samTile, tile.tile)
		local allowed = config:dynamicSamRange(self.sam, ticks + nukeTicks)
		if tile.targetable and distSq <= allowed * allowed and nukeTicks >= samTicks then
			return { tick = nukeTicks - samTicks, tile = tile.tile, minDistSq = minDistSq, lastSeenTick = ticks }
		end
		if incSteps > 3 and distSq > maxSamRangeSq then
			break
		end
	end
	local det = self:_checkDetonationInterception(unit, samTile, ticks)
	if det then
		return { tick = det.tick, tile = det.tile, minDistSq = minDistSq, lastSeenTick = ticks }
	end
	return { tick = if minDistSq > maxSamRangeSq then -2 else -1, tile = closestTile, minDistSq = minDistSq, lastSeenTick = ticks }
end

function Targeting._isValidNukeTarget(self: Targeting, unit: any): boolean
	if unit:targetedBySAM() or unit:owner() == self.sam:owner() then
		return false
	end
	local samOwner = self.sam:owner()
	local nukeOwner = unit:owner()
	if samOwner:isFriendly(nukeOwner) then
		-- After the game, teammates may nuke each other (not in singleplayer).
		local gameOver = self.mg:getWinner() ~= nil and self.mg:config():gameConfig().gameType ~= GameTypes.GameType.Singleplayer
		return gameOver and samOwner:isOnSameTeam(nukeOwner)
	end
	return true
end

function Targeting._computeTargetScore(self: Targeting, target: Target): number
	local mg = self.mg
	local samTile = self.sam:tile()
	local unit = target.unit
	local trajectory = unit:trajectory()
	local timeToExplode = math.max(1, #trajectory - unit:trajectoryIndex())
	local targetTile = unit:targetTile()
	if targetTile == nil then
		targetTile = if #trajectory > 0 then trajectory[#trajectory].tile else samTile
	end
	local distToSilo = mg:manhattanDist(samTile, targetTile)
	local typeBonus = if unit:type() == UnitType.HydrogenBomb then 70_001 else 0
	local distanceBonus = math.max(0, 200_000 - distToSilo * 1000)
	local urgencyBonus = math.max(0, 10_000 - timeToExplode * 100)
	return typeBonus + distanceBonus + urgencyBonus
end

function Targeting._sortTargets(self: Targeting, targets: { Target }): { Target }
	if #targets <= 1 then
		return targets
	end
	for _, target in targets do
		target.score = self:_computeTargetScore(target)
	end
	return Util.stableSort(targets, function(a, b)
		return (a.score :: number) > (b.score :: number)
	end)
end

function Targeting.getValidTargets(self: Targeting, ticks: number): { Target }
	local mg = self.mg
	local samTile = self.sam:tile()
	local detectionRange = mg:config():maxSamRange() * 4
	local nukes = mg:nearbyUnits(samTile, detectionRange, { UnitType.AtomBomb, UnitType.HydrogenBomb, UnitType.MIRVWarhead, UnitType.MegaNuke, UnitType.Scattershot }, function(entry: any): boolean
		return self:_isValidNukeTarget(entry.unit)
	end)
	local targets: { Target } = {}
	for _, nuke in nukes do
		local id = nuke.unit:id()
		local cached = self.precomputed[id]
		local skip = false
		if cached ~= nil then
			cached.lastSeenTick = ticks
			if cached.tick == -2 or cached.tick == -1 then
				skip = true
			elseif cached.tick == ticks or cached.tick == ticks + 1 then
				table.insert(targets, { tile = cached.tile, unit = nuke.unit })
				self.precomputed[id] = nil
				skip = true
			elseif cached.tick > ticks then
				skip = true
			else
				self.precomputed[id] = nil
			end
		end
		if not skip then
			local res = self:_computeInterceptionTile(nuke.unit, samTile, ticks)
			if res.tick >= 0 and res.tick <= 1 then
				table.insert(targets, { unit = nuke.unit, tile = res.tile })
			else
				self.precomputed[id] = {
					tick = if res.tick >= 0 then res.tick + ticks else res.tick,
					tile = res.tile,
					minDistSq = res.minDistSq,
					lastSeenTick = ticks,
				}
			end
		end
	end
	self:updateUnreachableNukes(ticks)
	return self:_sortTargets(targets)
end

-- SAMLauncherExecution -------------------------------------------------------------

local SAMLauncherExecution = {}
SAMLauncherExecution.__index = SAMLauncherExecution

export type SAMLauncherExecution = typeof(setmetatable(
	{} :: {
		mg: any,
		active: boolean,
		targetingSystem: Targeting?,
		pseudoRandom: PseudoRandom.PseudoRandom?,
		lastLevel: number,
		player: any,
		tile: number?,
		sam: any,
	},
	SAMLauncherExecution
))

function SAMLauncherExecution.new(player: any, tile: number?, sam: any?): SAMLauncherExecution
	return setmetatable({
		mg = nil,
		active = true,
		targetingSystem = nil,
		pseudoRandom = nil,
		lastLevel = 1,
		player = player,
		tile = if sam ~= nil then sam:tile() else tile,
		sam = sam,
	}, SAMLauncherExecution)
end

function SAMLauncherExecution.init(self: SAMLauncherExecution, mg: any, _ticks: number)
	self.mg = mg
end

function SAMLauncherExecution.tick(self: SAMLauncherExecution, ticks: number)
	local mg = self.mg
	if self.sam == nil then
		local spawnTile = self.player:canBuild(UnitType.SAMLauncher, self.tile :: number)
		if spawnTile == false then
			self.active = false
			return
		end
		self.sam = self.player:buildUnit(UnitType.SAMLauncher, spawnTile, {})
	end
	local sam = self.sam
	if self.targetingSystem == nil then
		self.targetingSystem = Targeting.new(mg, sam)
	end
	local targeting = self.targetingSystem :: Targeting
	if self.lastLevel ~= sam:level() then
		self.lastLevel = sam:level()
		targeting:onLevelUp()
	end
	if sam:isUnderConstruction() then
		return
	end
	if not sam:isActive() then
		self.active = false
		return
	end
	if self.player ~= sam:owner() then
		self.player = sam:owner()
	end
	while #sam:missileTimerQueue() > 0 do
		local frontTime = sam:missileTimerQueue()[1]
		-- (Conquest's Rapid Reload halves it; Config.rapidReload.)
		local cooldown = Config.rapidReload(sam:owner(), mg:config():SAMCooldown()) - (mg:ticks() - frontTime)
		if cooldown > 0 then
			break
		end
		sam:reloadMissile()
	end
	if sam:isInCooldown() then
		return
	end
	-- Conquest's Sabotage (ARSENAL_V2): a dark SAM holds fire.
	if sam:isDark() then
		return
	end
	if self.pseudoRandom == nil then
		self.pseudoRandom = PseudoRandom.new(sam:id())
	end
	-- No nuke in flight anywhere: nothing to target.
	if mg:unitCount(UnitType.AtomBomb) == 0 and mg:unitCount(UnitType.HydrogenBomb) == 0 and mg:unitCount(UnitType.MIRVWarhead) == 0 and mg:unitCount(UnitType.MegaNuke) == 0 and mg:unitCount(UnitType.Scattershot) == 0 then
		return
	end
	local SAMMissileExecution = require(script.Parent.SAMMissileExecution)
	for _, target in targeting:getValidTargets(ticks) do
		if sam:isInCooldown() then
			break
		end
		sam:launch()
		target.unit:setTargetedBySAM(true)
		mg:addExecution(SAMMissileExecution.new(sam:tile(), sam:owner(), sam, target.unit, target.tile))
	end
end

function SAMLauncherExecution.isActive(self: SAMLauncherExecution): boolean
	return self.active
end

function SAMLauncherExecution.activeDuringSpawnPhase(_self: SAMLauncherExecution): boolean
	return false
end

return SAMLauncherExecution
