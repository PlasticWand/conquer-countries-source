--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/utils/AiAttackBehavior.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- How AI players (tribes and nations) choose and size attacks. This file
-- grows by phase:
--   - Phase A ports what tribes use: random targets, traitors, retaliation,
--     land attacks and the troop caps.
--   - Boat attacks plan a landing, launch from the best shore, and avoid
--     hostile warships by difficulty.
--   - Nations add the full strategy: maybeAttack picks among retaliation,
--     tribes (walled in on Hard and up), allies' targets, betrayal, nuked
--     land, victims, juicy targets, hated players, the weakest, islands,
--     donations and the crown, in an order set by difficulty.

local AttackExecution = require(script.Parent.AttackExecution)
local ExecUtil = require(script.Parent.Util)
local GameTypes = require(script.Parent.Parent.GameTypes)
local HumanProtection = require(script.Parent.Parent.HumanProtection)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)
local TransportShipExecution = require(script.Parent.TransportShipExecution)
local TransportShipUtils = require(script.Parent.Parent.TransportShipUtils)

local Util = require(script.Parent.Parent.Util)

local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

local HIGH_STARTING_GOLD = 3_000_000 -- NationUtils.ts

local STRUCTURES = {
	[UnitType.City] = true,
	[UnitType.DefensePost] = true,
	[UnitType.SAMLauncher] = true,
	[UnitType.MissileSilo] = true,
	[UnitType.Port] = true,
	[UnitType.Factory] = true,
}

local AiAttackBehavior = {}
AiAttackBehavior.__index = AiAttackBehavior

export type AiAttackBehavior = typeof(setmetatable(
	{} :: {
		random: any,
		game: any,
		player: any,
		triggerRatio: number,
		reserveRatio: number,
		expandRatio: number,
		allianceBehavior: any?,
		emojiBehavior: any?,
		warshipBehavior: any?,
		botAttackTroopsSent: number,
		nbuf: { number },
		-- only set during a nation's maybeAttack: land neighbours and planned
		-- boat routes (a Map in first-planned order)
		landNeighbors: { any }?,
		boatRoutes: { map: { [any]: any }, order: { any } }?,
		followedLandings: { any },
	},
	AiAttackBehavior
))

function AiAttackBehavior.new(
	random: any,
	game: any,
	player: any,
	triggerRatio: number,
	reserveRatio: number,
	expandRatio: number,
	allianceBehavior: any?,
	emojiBehavior: any?,
	warshipBehavior: any?
): AiAttackBehavior
	return setmetatable({
		random = random,
		game = game,
		player = player,
		triggerRatio = triggerRatio,
		reserveRatio = reserveRatio,
		expandRatio = expandRatio,
		allianceBehavior = allianceBehavior,
		emojiBehavior = emojiBehavior,
		warshipBehavior = warshipBehavior,
		botAttackTroopsSent = 0,
		nbuf = { 0, 0, 0, 0 },
		landNeighbors = nil,
		boatRoutes = nil,
		followedLandings = {},
	}, AiAttackBehavior)
end

function AiAttackBehavior._hasReserveRatioTroops(self: AiAttackBehavior): boolean
	local maxTroops = self.game:config():maxTroops(self.player)
	return self.player:troops() / maxTroops >= self.reserveRatio
end

function AiAttackBehavior._hasTriggerRatioTroops(self: AiAttackBehavior, expansion: boolean?): boolean
	return self.player:troops() / self:_reserveBasis(expansion == true) >= self.triggerRatio
end

-- The max troops the ratios refer to. With high starting gold, cities don't
-- hold back expanding into free land and bots.
function AiAttackBehavior._reserveBasis(self: AiAttackBehavior, expansion: boolean): number
	local config = self.game:config()
	if expansion and self:_expandsPastCityTroops() then
		return config:maxTroopsWithoutCities(self.player)
	end
	return config:maxTroops(self.player)
end

function AiAttackBehavior._expandsPastCityTroops(self: AiAttackBehavior): boolean
	return self.game:config():startingGold(self.player:info()) >= HIGH_STARTING_GOLD
end

function AiAttackBehavior.findIncomingAttackPlayer(self: AiAttackBehavior): any?
	local player = self.player
	local largestAttack = 0
	local largestAttacker = nil
	for _, attack in player:incomingAttacks() do
		local attacker = attack:attacker()
		-- Ignore friendly attackers, and bot attacks unless we are a bot.
		if not player:isFriendly(attacker) and (player:type() == PlayerType.Bot or attacker:type() ~= PlayerType.Bot) then
			if attack:troops() > largestAttack then
				largestAttack = attack:troops()
				largestAttacker = attacker
			end
		end
	end
	return largestAttacker
end

function AiAttackBehavior._troopsAttacking(_self: AiAttackBehavior, target: any): number
	local sum = 0
	for _, a in target:incomingAttacks() do
		sum += a:troops()
	end
	return sum
end

function AiAttackBehavior.attackRandomTarget(self: AiAttackBehavior)
	-- Save up troops until we reach the trigger ratio
	if not self:_hasTriggerRatioTroops() then
		return
	end
	-- Retaliate against incoming attacks
	local incomingAttackPlayer = self:findIncomingAttackPlayer()
	if incomingAttackPlayer and self:sendAttack(incomingAttackPlayer, true) then
		return
	end
	-- Select a traitor as an enemy
	local toAttack = self:getNeighborTraitorToAttack()
	if toAttack ~= nil and self.random:chance(3) and self:sendAttack(toAttack) then
		return
	end
	-- Choose a new enemy randomly
	for _, neighbor in self.random:shuffleArray(self.player:nearby()) do
		if neighbor:isPlayer() and not self.player:isFriendly(neighbor) then
			local skip = false
			if neighbor:type() == PlayerType.Nation or neighbor:type() == PlayerType.Human then
				skip = self.random:chance(2)
			end
			if not skip and self:sendAttack(neighbor) then
				return
			end
		end
	end
end

function AiAttackBehavior.getNeighborTraitorToAttack(self: AiAttackBehavior): any?
	if self.game:config():disableAlliances() then
		return nil
	end
	local traitors = {}
	for _, n in self.player:nearby() do
		if n:isPlayer() and self.player:isFriendly(n) == false and n:isTraitor() then
			table.insert(traitors, n)
		end
	end
	return if #traitors > 0 then self.random:randElement(traitors) else nil
end

function AiAttackBehavior.forceSendAttack(self: AiAttackBehavior, target: any)
	self.game:addExecution(
		AttackExecution.new(self.player:troops() / 2, self.player, if target:isPlayer() then target:id() else nil)
	)
end

function AiAttackBehavior.sendAttack(self: AiAttackBehavior, target: any, force: boolean?): boolean
	if not force and not self:shouldAttack(target) then
		return false
	end
	if target:isPlayer() then
		if self.player:sharesBorderWith(target) then
			return self:_sendLandAttack(target)
		end
		return self:_sendBoatAttack(target)
	end
	-- sharesBorderWith(TerraNullius) counts water, so use a land-only check.
	if self:_hasLandBorderWithTerraNullius() then
		return self:_sendLandAttack(target)
	end
	return self:_sendBoatAttackToNearbyTerraNullius()
end

function AiAttackBehavior._hasLandBorderWithTerraNullius(self: AiAttackBehavior): boolean
	local map = self.game:map()
	local nbuf = self.nbuf
	for _, border in self.player:borderTiles():values() do
		local n = map:neighbors4(border, nbuf)
		for i = 1, n do
			local neighbor = nbuf[i]
			if map:isLand(neighbor) and not map:isImpassable(neighbor) and not map:hasOwner(neighbor) then
				return true
			end
		end
	end
	return false
end

-- The player's shore border tiles, in border-set order.
function AiAttackBehavior._shoreTiles(self: AiAttackBehavior, player: any): { number }
	local out = {}
	for _, t in player:borderTiles():values() do
		if self.game:isShore(t) then
			table.insert(out, t)
		end
	end
	return out
end

local DIRECTIONS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

-- Every 10th shore border tile looks 5 water tiles out for free land.
function AiAttackBehavior._sendBoatAttackToNearbyTerraNullius(self: AiAttackBehavior): boolean
	local game = self.game
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return false
	end
	if self.player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return false
	end
	local shores = self:_shoreTiles(self.player)
	for i = 1, #shores, 10 do
		local border = shores[i]
		local bx, by = game:x(border), game:y(border)
		for _, d in DIRECTIONS do
			local dx, dy = d[1], d[2]
			local x1, y1 = bx + dx, by + dy
			if game:isValidCoord(x1, y1) and game:isWater(game:ref(x1, y1)) then
				local nx, ny = bx + dx * 5, by + dy * 5
				if game:isValidCoord(nx, ny) then
					local tile = game:ref(nx, ny)
					if
						game:isLand(tile)
						and not game:isImpassable(tile)
						and not game:hasOwner(tile)
						and not game:hasFallout(tile)
					then
						local launch = TransportShipUtils.canBuildTransportShip(game, self.player, tile)
						if launch ~= false and self:_sail(launch :: number, tile).blocker == nil then
							if self:_landsBeachheads() then
								return self:_sendBeachhead(game:terraNullius(), tile)
							end
							local troops = math.min(self.player:troops() / 5, self:_troopSendCapForExpansion())
							if troops < 1 then
								return false
							end
							game:addExecution(TransportShipExecution.new(self.player, tile, troops))
							return true
						end
					end
				end
			end
		end
	end
	return false
end

function AiAttackBehavior.shouldAttack(self: AiAttackBehavior, other: any): boolean
	if
		-- Always attack terra nullius and non-humans
		other:isPlayer() == false
		or other:type() ~= PlayerType.Human
		-- Always attack if we are a bot or in an HvN game
		or self.player:type() == PlayerType.Bot
		or self.game:config():gameConfig().playerTeams == GameTypes.HumansVsNations
	then
		return true
	end
	-- Conquest: RoWorld's grace and war limit (off in OpenFront's own rules).
	if HumanProtection.offLimits(self.game, self.player, other) then
		return false
	end
	-- Always attack traitors
	if other:isTraitor() then
		return true
	end
	-- Conquest: the same odds as below, rolled once per attack cycle.
	if self.game:config():gameConfig().humanSkip then
		return not HumanProtection.skips(self.game, self.player, other)
	end
	-- Prevent attacking humans on lower difficulties
	local difficulty = self.game:config():gameConfig().difficulty
	if difficulty == Difficulty.Easy and self.random:nextInt(0, 4) ~= 0 then
		return false
	end
	if difficulty == Difficulty.Medium and self.random:chance(4) then
		return false
	end
	return true
end

-- Hard and Impossible nations in FFA: an attack under 20% of the target's
-- troops is not worth making.
function AiAttackBehavior._isAttackTooWeak(self: AiAttackBehavior, troops: number, target: any): boolean
	if self.player:type() == PlayerType.Bot then
		return false
	end
	if self.game:config():gameConfig().gameMode == GameTypes.GameMode.Team then
		return false
	end
	-- Nations under attack may retaliate freely
	if #self.player:incomingAttacks() > 0 then
		return false
	end
	local difficulty = self.game:config():gameConfig().difficulty
	return (difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible) and troops < target:troops() * 0.2
end

function AiAttackBehavior._troopSendCap(self: AiAttackBehavior, ignore: any?): number
	local cap = self:_neighborTroopCap(ignore)
	-- Nations under attack may retaliate with at least the incoming troops
	local incoming = self.player:incomingAttacks()
	if #incoming > 0 then
		local total = 0
		for _, a in incoming do
			total += a:troops()
		end
		cap = math.max(cap, total)
	end
	return cap
end

-- Hard/Impossible nations in FFA keep 75%/90% of their strongest non-allied,
-- non-bot neighbour's troops at home.
function AiAttackBehavior._neighborTroopCap(self: AiAttackBehavior, ignore: any?): number
	if self.player:type() == PlayerType.Bot then
		return math.huge
	end
	if self.game:config():gameConfig().gameMode == GameTypes.GameMode.Team then
		return math.huge
	end
	local difficulty = self.game:config():gameConfig().difficulty
	local retainFraction
	if difficulty == Difficulty.Hard then
		retainFraction = 0.75
	elseif difficulty == Difficulty.Impossible then
		retainFraction = 0.9
	else
		return math.huge
	end
	local maxNeighborTroops = 0
	for _, n in self.player:nearby() do
		if
			n:isPlayer()
			and n ~= ignore
			and not self.player:isFriendly(n)
			and n:type() ~= PlayerType.Bot
			and n:troops() > maxNeighborTroops
		then
			maxNeighborTroops = n:troops()
		end
	end
	if maxNeighborTroops == 0 then
		return math.huge
	end
	local minRetained = math.ceil(maxNeighborTroops * retainFraction)
	return math.max(0, self.player:troops() - minRetained)
end

-- Like troopSendCap, but free land is throttled, never frozen.
function AiAttackBehavior._troopSendCapForExpansion(self: AiAttackBehavior): number
	local cap = self:_troopSendCap()
	if cap > 0 then
		return cap
	end
	return math.ceil(self.player:troops() * 0.05)
end

-- `opponent`: a player taken on on purpose (retaliation, runaway leader).
function AiAttackBehavior._calculateAttackTroops(
	self: AiAttackBehavior,
	target: any,
	nonBotTroops: (number) -> number,
	opponent: any?
): number?
	local player = self.player
	local expansion = not target:isPlayer() or target:type() == PlayerType.Bot
	local maxTroops = self:_reserveBasis(expansion)
	local botWithStructures = false
	if target:isPlayer() and target:type() == PlayerType.Bot then
		for _, u in target:units() do
			if STRUCTURES[u:type()] then
				botWithStructures = true
				break
			end
		end
	end
	-- The expand ratio against a bot with structures: take them back fast.
	local useReserve = target:isPlayer() and not botWithStructures
	local ratio = if useReserve then self.reserveRatio else self.expandRatio
	local targetTroops = maxTroops * ratio

	local troops
	local isBotAttack = target:isPlayer() and target:type() == PlayerType.Bot and player:type() ~= PlayerType.Bot
	if isBotAttack then
		troops = (self :: any):_calculateBotAttackTroops(target, player:troops() - targetTroops - self.botAttackTroopsSent)
	else
		troops = nonBotTroops(targetTroops)
	end

	troops = math.min(troops, if target:isPlayer() then self:_troopSendCap(opponent) else self:_troopSendCapForExpansion())
	if troops < 1 then
		return nil
	end

	local pileOn = if target:isPlayer() and target == opponent then self:_troopsAttacking(target) else 0
	if target:isPlayer() and self:_isAttackTooWeak(troops + pileOn, target) then
		return nil
	end

	if target:isPlayer() and player:type() == PlayerType.Nation then
		local emoji = self.emojiBehavior
		if emoji == nil then
			error("not initialized")
		end
		emoji:maybeSendAttackEmoji(target)
	end

	if isBotAttack then
		self.botAttackTroopsSent += troops
	end
	return troops
end

function AiAttackBehavior._sendLandAttack(
	self: AiAttackBehavior,
	target: any,
	nonBotTroops: ((number) -> number)?,
	opponent: any?
): boolean
	local player = self.player
	local troops = self:_calculateAttackTroops(target, nonBotTroops or function(targetTroops: number): number
		return player:troops() - targetTroops
	end, opponent)
	if troops == nil then
		return false
	end
	self.game:addExecution(AttackExecution.new(troops, player, if target:isPlayer() then target:id() else nil))
	HumanProtection.noteWar(self.game, player, target)
	return true
end

function AiAttackBehavior._sendBoatAttack(self: AiAttackBehavior, target: any): boolean
	local route = self:_boatRoute(target)
	if route == nil then
		return false
	end
	-- A beachhead boat is cheap enough to risk past a warship, one at a time
	local beachhead = self:_landsBeachheads()
	if route.blocker ~= nil and (not beachhead or self.player:unitCount("Transport") > 0) then
		return false
	end
	if beachhead then
		return self:_sendBeachhead(target, route.landing)
	end
	local player = self.player
	local troops = self:_calculateAttackTroops(target, function(_targetTroops: number): number
		return player:troops() / 5
	end)
	if troops == nil then
		return false
	end
	self.game:addExecution(TransportShipExecution.new(player, route.landing, troops))
	HumanProtection.noteWar(self.game, player, target)
	return true
end

-- Hard and Impossible nations boat a tiny force and attack by land on landing.
function AiAttackBehavior._landsBeachheads(self: AiAttackBehavior): boolean
	local difficulty = self.game:config():gameConfig().difficulty
	return self.player:type() == PlayerType.Nation and (difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible)
end

-- A 1% boat, if the land attack after landing would be worth making now.
function AiAttackBehavior._sendBeachhead(self: AiAttackBehavior, target: any, landing: number): boolean
	local player = self.player
	local troops = self:_calculateAttackTroops(target, function(targetTroops: number): number
		return player:troops() - targetTroops
	end, if target:isPlayer() then target else nil)
	if troops == nil then
		return false
	end
	local boatTroops = math.max(1, math.floor(player:troops() / 100))
	-- Only the boat leaves now: the land attack is budgeted once it lands
	if target:isPlayer() and target:type() == PlayerType.Bot then
		self.botAttackTroopsSent += boatTroops - troops
	end
	self.game:addExecution(TransportShipExecution.new(player, landing, boatTroops))
	HumanProtection.noteWar(self.game, player, target)
	return true
end

export type BoatRoute = { landing: number, length: number, blocker: any? }

function AiAttackBehavior._boatRoute(self: AiAttackBehavior, target: any): BoatRoute?
	local routes = self.boatRoutes
	if routes ~= nil then
		local known = routes.map[target]
		if known ~= nil then
			return if known == false then nil else known
		end
	end
	local route = self:_planBoatRoute(target)
	if routes ~= nil then
		if routes.map[target] == nil then
			table.insert(routes.order, target)
		end
		routes.map[target] = if route == nil then false else route
	end
	return route
end

-- The direct crossing, or if a warship blocks it, the shortest safe one
-- landing elsewhere.
function AiAttackBehavior._planBoatRoute(self: AiAttackBehavior, target: any): BoatRoute?
	local game = self.game
	if game:config():isUnitDisabled(UnitType.TransportShip) or self.player:unitCount("Transport") >= game:config():boatMaxNumber() then
		return nil
	end
	local ours = self:_shoreTiles(self.player)
	local theirs = self:_shoreTiles(target)
	local closest = ExecUtil.closestTwoTiles(game, ours, theirs)
	if closest == nil then
		return nil
	end
	local warships = self:_hostileWarships()
	local direct = self:_routeTo(closest.y, warships)
	if direct ~= nil and direct.blocker == nil then
		return direct
	end
	local best: BoatRoute? = nil
	for _, landing in self:_otherLandings(ours, theirs, closest.y, warships) do
		local route = self:_routeTo(landing, warships)
		if route ~= nil and route.blocker == nil and (best == nil or route.length < (best :: BoatRoute).length) then
			best = route
		end
	end
	return best or direct
end

-- The launch follows from the landing: our shore closest to it by water.
function AiAttackBehavior._routeTo(self: AiAttackBehavior, landing: number, warships: { any }): BoatRoute?
	local launch = TransportShipUtils.canBuildTransportShip(self.game, self.player, landing)
	if launch == false then
		return nil
	end
	local sail = self:_sail(launch :: number, landing, warships)
	return { landing = landing, length = sail.length, blocker = sail.blocker }
end

-- Landings on their coast apart from `tried`, clear of hostile warships,
-- nearest to our coast first: Medium tries 1, Hard 2, Impossible 4.
function AiAttackBehavior._otherLandings(self: AiAttackBehavior, ours: { number }, theirs: { number }, tried: number, warships: { any }): { number }
	local game = self.game
	local difficulty = game:config():gameConfig().difficulty
	local count
	if difficulty == Difficulty.Easy then
		return {}
	elseif difficulty == Difficulty.Medium then
		count = 1
	elseif difficulty == Difficulty.Hard then
		count = 2
	else
		count = 4
	end
	local rangeSquared = self:_dangerRange() ^ 2
	local ourStep = math.max(1, #ours // 32)
	local ourSample = {}
	for i, t in ours do
		if (i - 1) % ourStep == 0 then
			table.insert(ourSample, t)
		end
	end
	local candidates = {}
	local theirStep = math.max(1, #theirs // 32)
	for i = 1, #theirs, theirStep do
		local tile = theirs[i]
		local threatened = false
		for _, w in warships do
			if game:euclideanDistSquared(w:tile(), tile) <= rangeSquared then
				threatened = true
				break
			end
		end
		if not threatened then
			local dist = math.huge
			for _, s2 in ourSample do
				dist = math.min(dist, game:manhattanDist(s2, tile))
			end
			table.insert(candidates, { tile = tile, dist = dist })
		end
	end
	candidates = Util.stableSort(candidates, function(a, b)
		return a.dist < b.dist
	end)
	local picked = { tried }
	for _, c in candidates do
		if #picked > count then
			break
		end
		local near = false
		for _, p in picked do
			if game:manhattanDist(p, c.tile) < 50 then
				near = true
				break
			end
		end
		if not near then
			table.insert(picked, c.tile)
		end
	end
	return table.move(picked, 2, #picked, 1, {})
end

function AiAttackBehavior._hostileWarships(self: AiAttackBehavior): { any }
	local out = {}
	for _, w in self.game:units(UnitType.Warship) do
		if
			w:owner() ~= self.player
			and not w:isUnderConstruction()
			and w:warshipState().state ~= "docked"
			and w:owner():canAttackPlayer(self.player, true)
		then
			table.insert(out, w)
		end
	end
	return out
end

-- Warship targeting range, plus what it may move while our boat approaches.
function AiAttackBehavior._dangerRange(self: AiAttackBehavior): number
	return self.game:config():warshipTargettingRange() + 20
end

-- Tiles a boat sails from launch to the shore at target, and the hostile
-- warship that would sink it. Easy doesn't look, Medium checks both shores,
-- Hard and Impossible pathfind.
function AiAttackBehavior._sail(self: AiAttackBehavior, launch: number, target: number, warships: { any }?): { length: number, blocker: any? }
	local game = self.game
	local ships = warships or self:_hostileWarships()
	local landing = TransportShipUtils.targetTransportTile(game, self.player, target) or target
	local direct = game:manhattanDist(launch, landing)
	local difficulty = game:config():gameConfig().difficulty
	if self.player:type() == PlayerType.Bot or difficulty == Difficulty.Easy then
		return { length = direct, blocker = nil }
	end
	local path: { number }? = nil
	if not (difficulty == Difficulty.Medium or direct <= 20) then
		path = PathFinding.Stepper.new(PathFinding.sharedWaterChain(game), game):findPath(launch, landing)
	end
	local route: { number } = path or { launch, landing }
	local length = if path then #path else direct
	local range = self:_dangerRange()
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for _, t in route do
		minX, maxX = math.min(minX, game:x(t)), math.max(maxX, game:x(t))
		minY, maxY = math.min(minY, game:y(t)), math.max(maxY, game:y(t))
	end
	for _, w in ships do
		local wx, wy = game:x(w:tile()), game:y(w:tile())
		if not (wx < minX - range or wx > maxX + range or wy < minY - range or wy > maxY + range) then
			for i, t in route do
				if game:euclideanDistSquared(w:tile(), t) <= range * range then
					-- Without a path, assume it can fire as soon as we launch.
					local sailed = if path == nil then 0 else i - 1
					local ticksLeft = length - sailed
					if 4 * ticksLeft >= game:manhattanDist(w:tile(), t) - 10 then
						return { length = length, blocker = w }
					end
					break
				end
			end
		end
	end
	return { length = length, blocker = nil }
end

-- Nation strategy ----------------------------------------------------------------------

local Emoji = require(script.Parent.Parent.Data.Emoji)

local Relation = { Hostile = 0, Distrustful = 1, Neutral = 2, Friendly = 3 }
local CHEAPEST_TROOP_RATIO = 0.6 -- EngineConfig.ts

local function NationUtils(): any
	return require(script.Parent.Nation.NationUtils)
end

-- Fewest tiles between two boxes ({minX, minY, maxX, maxY}); unknown boxes
-- count as touching.
local function boxGap(a: any, b: any): number
	if not a or not b then
		return 0
	end
	local dx = math.max(0, a.minX - b.maxX, b.minX - a.maxX)
	local dy = math.max(0, a.minY - b.maxY, b.minY - a.maxY)
	return dx + dy
end

local function sumTroops(attacks: { any }): number
	local s = 0
	for _, a in attacks do
		s += a:troops()
	end
	return s
end

local function byTroops(list: { any }): { any }
	return Util.stableSort(list, function(a, b)
		return a:troops() < b:troops()
	end)
end

function AiAttackBehavior._isFFA(self: AiAttackBehavior): boolean
	return self.game:config():gameConfig().gameMode == GameTypes.GameMode.FFA
end

function AiAttackBehavior.maybeAttack(self: AiAttackBehavior)
	local routes = { map = {}, order = {} }
	self.boatRoutes = routes
	local landFront = false
	local ok, err = pcall(function()
		self:_chooseAttack()
		for _, neighbor in (self.landNeighbors or {}) :: { any } do
			if not self.player:isFriendly(neighbor) then
				landFront = true
			end
		end
	end)
	self.landNeighbors = nil
	self.boatRoutes = nil
	if not ok then
		error(err, 0)
	end
	self:_clearBlockedLane(routes, landFront)
end

-- Every tick on Hard and up: a boat that just landed (its attack starts at
-- the landing tile) is followed by a land attack on its target, once.
function AiAttackBehavior.followUpLandings(self: AiAttackBehavior)
	if not self:_landsBeachheads() then
		return
	end
	local attacks = self.player:outgoingAttacks()
	local kept = {}
	for _, a in self.followedLandings do
		if table.find(attacks, a) then
			table.insert(kept, a)
		end
	end
	self.followedLandings = kept
	for _, attack in attacks do
		local landing = attack:sourceTile()
		if landing ~= nil and not table.find(self.followedLandings, attack) then
			table.insert(self.followedLandings, attack)
			local target = attack:target()
			if self:_holdsLandNextTo(target, landing) then
				self:_sendLandAttack(target, nil, if target:isPlayer() then target else nil)
			end
		end
	end
end

function AiAttackBehavior._holdsLandNextTo(self: AiAttackBehavior, owner: any, tile: number): boolean
	local game = self.game
	local n = game:map():neighbors4(tile, self.nbuf)
	for i = 1, n do
		local t = self.nbuf[i]
		if game:isLand(t) and not game:isImpassable(t) and game:owner(t) == owner then
			return true
		end
	end
	return false
end

function AiAttackBehavior._chooseAttack(self: AiAttackBehavior)
	local game, player = self.game, self.player
	-- Discovery order feeds the stable troop sort: ties keep it.
	local order, seen = {}, {}
	local borderHasNonNukedTN = false
	local smallID = player:smallID()
	local function visit(t: number)
		if not game:isLand(t) or game:isImpassable(t) then
			return
		end
		if game:ownerID(t) == smallID then
			return
		end
		local owner = game:playerBySmallID(game:ownerID(t))
		if owner:isPlayer() and not seen[owner] then
			seen[owner] = true
			table.insert(order, owner)
		end
		if not game:hasOwner(t) and not game:hasFallout(t) then
			borderHasNonNukedTN = true
		end
	end
	player:borderTiles():forEach(function(t: number)
		game:forEachNeighbor(t, visit)
	end)
	self.landNeighbors = table.clone(order)
	local playerNeighbors = player:nearby()
	for _, n in playerNeighbors do
		if n:isPlayer() and not seen[n] then
			seen[n] = true
			table.insert(order, n)
		end
	end
	local bordering = byTroops(order)
	local friends, enemies = {}, {}
	for _, o in bordering do
		if player:isFriendly(o) then
			table.insert(friends, o)
		else
			table.insert(enemies, o)
		end
	end
	local hasTN = borderHasNonNukedTN
	if not hasTN then
		for _, n in playerNeighbors do
			if not n:isPlayer() then
				hasTN = true
				break
			end
		end
	end
	if hasTN and self:sendAttack(game:terraNullius()) then
		return
	end
	local holdBoats = self:_holdsBoatsUnderAttack()
	if #enemies == 0 then
		if not holdBoats and self.random:chance(5) then
			self:_attackWithRandomBoat({})
		end
	else
		if not holdBoats and self.random:chance(10) then
			self:_attackWithRandomBoat(enemies)
			return
		end
		(self.allianceBehavior :: any):maybeSendAllianceRequests(enemies)
	end
	self:_attackBestTarget(friends, enemies)
end

function AiAttackBehavior._attackWithRandomBoat(self: AiAttackBehavior, borderingEnemies: { any })
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return
	end
	if player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return
	end
	local shore = self:_shoreTiles(player)
	if #shore == 0 then
		return
	end
	local src = self.random:randElement(shore)
	local found = self:_findRandomBoatTarget(src, borderingEnemies, true) or self:_findRandomBoatTarget(src, borderingEnemies, false)
	if found == nil then
		return
	end
	local dst, launch = found.tile, found.launch
	if self:_sail(launch, dst).blocker ~= nil then
		return
	end
	local owner = game:owner(dst)
	-- Conquest: this path skips shouldAttack, so it checks the grace and limit
	-- itself. As in RoWorld, a boat doesn't roll humanSkip.
	if owner:isPlayer() and HumanProtection.offLimits(game, player, owner) then
		return
	end
	if self:_landsBeachheads() then
		self:_sendBeachhead(owner, dst)
		return
	end
	local cap = if owner:isPlayer() then self:_troopSendCap() else self:_troopSendCapForExpansion()
	local troops = math.min(player:troops() / 5, cap)
	if troops < 1 then
		return
	end
	if owner:isPlayer() and self:_isAttackTooWeak(troops, owner) then
		return
	end
	game:addExecution(TransportShipExecution.new(player, dst, troops))
	HumanProtection.noteWar(game, player, owner)
end

function AiAttackBehavior._findRandomBoatTarget(self: AiAttackBehavior, tile: number, borderingEnemies: { any }, highInterestOnly: boolean): { tile: number, launch: number }?
	local game, player = self.game, self.player
	local x, y = game:x(tile), game:y(tile)
	local unreachable: { [string]: boolean } = {}
	for _ = 1, 500 do
		local rx = self.random:nextInt(x - 150, x + 150)
		local ry = self.random:nextInt(y - 150, y + 150)
		if game:isValidCoord(rx, ry) then
			local t = game:ref(rx, ry)
			if game:isLand(t) and not game:isImpassable(t) then
				local owner = game:owner(t)
				local skip = owner == player
					or (owner:isPlayer() and unreachable[owner:id()])
					or (owner:isPlayer() and table.find(borderingEnemies, owner) ~= nil)
					or (self:_isFFA() and owner:isPlayer() and owner:troops() > player:troops())
				if not skip then
					local matches
					if highInterestOnly then
						matches = not owner:isPlayer() or owner:type() == PlayerType.Bot
					else
						matches = not owner:isPlayer() or not owner:isFriendly(player)
					end
					if matches then
						local launch = TransportShipUtils.canBuildTransportShip(game, player, t)
						if launch == false then
							if owner:isPlayer() then
								unreachable[owner:id()] = true
							end
						else
							return { tile = t, launch = launch :: number }
						end
					end
				end
			end
		end
	end
	return nil
end

-- Friends and enemies arrive sorted by troops (ascending).
function AiAttackBehavior._attackBestTarget(self: AiAttackBehavior, friends: { any }, enemies: { any })
	local d = self.game:config():gameConfig().difficulty
	-- Hard and up answer attacks at once, below the ratios.
	if (d == Difficulty.Hard or d == Difficulty.Impossible) and self:_retaliate() then
		return
	end
	-- A walled-in tribe costs next to nothing: don't save up for it.
	self:_annexWalledInBots()
	-- Tribes holding structures (ours, maybe), and with high starting gold.
	if self:_hasNeighboringBotWithStructures() or (self:_expandsPastCityTroops() and self:_hasTriggerRatioTroops(true)) then
		if self:_attackBots() then
			return
		end
	end
	if not self:_hasReserveRatioTroops() then
		return
	end
	if d == Difficulty.Medium and self:_retaliate() then
		return
	end
	if not self:_hasTriggerRatioTroops() and not self.random:chance(10) then
		return
	end
	for _, strategy in self:_getAttackStrategies(friends, enemies) do
		if strategy() then
			return
		end
	end
end

function AiAttackBehavior._getAttackStrategies(self: AiAttackBehavior, friends: { any }, enemies: { any }): { () -> boolean }
	local game, player = self.game, self.player
	local d = game:config():gameConfig().difficulty

	-- Target groups, tried in order, each by troops. Hard and up without a
	-- land front weigh enemies within boat range too; Impossible with one
	-- turns to them once it finds nothing at hand.
	local groups: { { any } }? = nil
	local function targetGroups(): { { any } }
		if groups ~= nil then
			return groups
		end
		local landFront = false
		for _, e in enemies do
			if self:_bordersByLand(e) then
				landFront = true
				break
			end
		end
		if d == Difficulty.Impossible and landFront then
			groups = { enemies, byTroops(self:_overseasTargets(enemies)) }
		elseif (d == Difficulty.Hard or d == Difficulty.Impossible) and not landFront then
			local all = table.clone(enemies)
			for _, p in self:_overseasTargets(enemies) do
				table.insert(all, p)
			end
			groups = { byTroops(all) }
		else
			groups = { enemies }
		end
		return groups :: { { any } }
	end

	-- What `find` picks among targets we can reach now, from the first group
	-- where it picks anything (Easy doesn't check reach).
	local function pick(find: ({ any }) -> any?): any?
		for _, group in targetGroups() do
			local pool = group
			while true do
				local target = find(pool)
				if target == nil then
					break
				end
				if d == Difficulty.Easy or self:_canReach(target) then
					return target
				end
				local nextPool = {}
				for _, e in pool do
					if e ~= target then
						table.insert(nextPool, e)
					end
				end
				pool = nextPool
			end
		end
		return nil
	end

	local function first(list: { any }, pred: (any) -> boolean): any?
		for _, e in list do
			if pred(e) then
				return e
			end
		end
		return nil
	end

	local function retaliate(): boolean
		return self:_retaliate()
	end
	local function bots(): boolean
		return self:_attackBots()
	end
	local function assist(): boolean
		return self:_assistAllies()
	end
	local function traitor(): boolean
		local t = pick(function(es)
			return self:_findTraitor(es)
		end)
		return if t then self:sendAttack(t) else false
	end
	local function afk(): boolean
		local t = pick(function(es)
			return first(es, function(e)
				return e:isDisconnected() and (not self:_isFFA() or e:troops() < player:troops() * 3)
			end)
		end)
		return if t then self:sendAttack(t) else false
	end
	local function betray(): boolean
		return self:_maybeBetrayAndAttack(friends, enemies)
	end
	local function nuked(): boolean
		if self:_isBorderingNukedTerritory() then
			return self:sendAttack(game:terraNullius())
		end
		return false
	end
	local function victim(): boolean
		local t = pick(function(es)
			return self:_findVictim(es)
		end)
		return if t then self:sendAttack(t) else false
	end
	local function juicy(): boolean
		local t = pick(function(es)
			return self:_findJuicyTarget(es)
		end)
		return if t ~= nil then self:sendAttack(t) else false
	end
	local function hated(): boolean
		for _, relation in player:allRelationsSorted() do
			if relation.relation == Relation.Hostile then
				local other = relation.player
				if
					not player:isFriendly(other)
					and not (self:_isFFA() and other:troops() > player:troops() * 3)
					and (d == Difficulty.Easy or self:_canReach(other))
				then
					return self:sendAttack(other)
				end
			end
		end
		return false
	end
	local function veryWeak(): boolean
		local t = pick(function(es)
			return self:_findVeryWeakEnemy(es)
		end)
		return if t then self:sendAttack(t) else false
	end
	local function weakest(): boolean
		local t = pick(function(es)
			return first(es, function(e)
				return not self:_isFFA() or e:troops() < player:troops()
			end)
		end)
		return if t ~= nil then self:sendAttack(t) else false
	end
	local function island(): boolean
		if pick(function(es)
			return es[1]
		end) == nil then
			local enemy = self:_findNearestIslandEnemy()
			if enemy then
				return self:sendAttack(enemy)
			end
		end
		return false
	end
	local function donate(): boolean
		return self:_donateTroops()
	end
	local function crown(): boolean
		local leader = self:_findCrownTarget(enemies)
		return leader ~= nil and self:shouldAttack(leader) and self:_sendLandAttack(leader, nil, leader)
	end

	-- Easy gets the dumbest order, Impossible the smartest.
	if d == Difficulty.Easy then
		return { nuked, bots, retaliate, assist, betray, hated, weakest }
	elseif d == Difficulty.Medium then
		return { bots, nuked, assist, betray, hated, afk, traitor, crown, weakest, island, donate }
	elseif d == Difficulty.Hard then
		return { bots, assist, betray, nuked, traitor, afk, hated, veryWeak, juicy, victim, crown, weakest, island, donate }
	end
	return { bots, veryWeak, betray, assist, victim, crown, traitor, juicy, afk, nuked, hated, weakest, island, donate }
end

function AiAttackBehavior._hasNeighboringBotWithStructures(self: AiAttackBehavior): boolean
	for _, n in self.player:nearby() do
		if n:isPlayer() and n:type() == PlayerType.Bot and not self.player:isFriendly(n) then
			for _, u in n:units() do
				if STRUCTURES[u:type()] then
					return true
				end
			end
		end
	end
	return false
end

function AiAttackBehavior._retaliate(self: AiAttackBehavior): boolean
	local attacker = self:findIncomingAttackPlayer()
	if attacker == nil then
		return false
	end
	local d = self.game:config():gameConfig().difficulty
	if (d == Difficulty.Hard or d == Difficulty.Impossible) and self:_isFFA() and self.player:sharesBorderWith(attacker) then
		return self:_sendRetaliation(attacker)
	end
	return self:sendAttack(attacker, true)
end

-- Hard and up keep troops home while under attack, Medium sometimes.
function AiAttackBehavior._holdsBoatsUnderAttack(self: AiAttackBehavior): boolean
	if self:findIncomingAttackPlayer() == nil then
		return false
	end
	local d = self.game:config():gameConfig().difficulty
	if d == Difficulty.Easy then
		return false
	elseif d == Difficulty.Medium then
		return self.random:chance(2)
	end
	return true
end

-- Cancels the attacker's incoming troops; if we can also match its home
-- army while keeping what troopSendCap wants for other neighbours, pushes
-- into its land. Never below the expand ratio.
function AiAttackBehavior._sendRetaliation(self: AiAttackBehavior, attacker: any): boolean
	local player = self.player
	local incoming = 0
	for _, a in player:incomingAttacks() do
		if a:attacker() == attacker then
			incoming += a:troops()
		end
	end
	local pressing = 0
	for _, a in player:outgoingAttacks() do
		if a:target() == attacker then
			pressing += a:troops()
		end
	end
	local troops = player:troops()
	local maxTroops = self.game:config():maxTroops(player)
	local spare = math.min(troops - maxTroops * self.expandRatio, self:_neighborTroopCap(attacker))
	local aboveReserve = troops - maxTroops * self.reserveRatio
	local counter = incoming + math.max(0, attacker:troops() - pressing)
	local send = if spare >= counter then math.max(counter, math.min(aboveReserve, spare)) else math.min(incoming, math.max(spare, aboveReserve))
	return self:_sendLandAttack(attacker, function()
		return send
	end, attacker)
end

-- Troops a strike on target could send now.
function AiAttackBehavior.strikeTroops(self: AiAttackBehavior, target: any): number
	local maxTroops = self.game:config():maxTroops(self.player)
	return math.min(self.player:troops() - maxTroops * self.reserveRatio, self:_troopSendCap(target))
end

-- Attacks a player our nuke just hit, skipping the trigger ratio.
function AiAttackBehavior.strike(self: AiAttackBehavior, target: any): boolean
	if self.player:isFriendly(target) or not self.player:sharesBorderWith(target) then
		return false
	end
	return self:_sendLandAttack(target, nil, target)
end

-- A bordering runaway leader (Medium only joins attacks under way).
function AiAttackBehavior._findCrownTarget(self: AiAttackBehavior, enemies: { any }): any?
	local leader = NationUtils().findRunawayLeader(self.game)
	if leader == nil or not table.find(enemies, leader) or not self.player:sharesBorderWith(leader) then
		return nil
	end
	local d = self.game:config():gameConfig().difficulty
	if d == Difficulty.Hard or d == Difficulty.Impossible then
		return leader
	end
	return if self:_troopsAttacking(leader) >= leader:troops() * 0.1 then leader else nil
end

-- Neighbouring tribes by density (or wall-in order on Hard and up),
-- structure owners first, attacked in parallel.
function AiAttackBehavior._attackBots(self: AiAttackBehavior): boolean
	local bots = self:_neighboringBots()
	if #bots == 0 then
		return false
	end
	self.botAttackTroopsSent = 0
	local ordered
	if self:_annexesBots() then
		ordered = require(script.Parent.Nation.BotAnnexation).planBotAttacks(self.game, self.player, bots)
	else
		ordered = Util.stableSort(table.clone(bots), function(a, b)
			return a:troops() / a:numTilesOwned() < b:troops() / b:numTilesOwned()
		end)
	end
	local function owns(p: any): number
		for _, u in p:units() do
			if STRUCTURES[u:type()] then
				return 1
			end
		end
		return 0
	end
	local sorted = Util.stableSort(ordered, function(a, b)
		return owns(a) > owns(b)
	end)
	local reduced = table.move(sorted, 1, math.min(#sorted, self:_getBotAttackMaxParallelism()), 1, {})
	for _, bot in reduced do
		self:sendAttack(bot)
	end
	if self.botAttackTroopsSent > 0 then
		return true
	end
	if self:_annexesBots() then
		for _, a in self.player:outgoingAttacks() do
			if table.find(reduced, a:target()) then
				return true
			end
		end
	end
	return false
end

function AiAttackBehavior._neighboringBots(self: AiAttackBehavior): { any }
	local out = {}
	for _, n in self.player:nearby() do
		if n:isPlayer() and not self.player:isFriendly(n) and n:type() == PlayerType.Bot then
			table.insert(out, n)
		end
	end
	return out
end

function AiAttackBehavior._annexesBots(self: AiAttackBehavior): boolean
	local d = self.game:config():gameConfig().difficulty
	return self.player:type() == PlayerType.Nation and (d == Difficulty.Hard or d == Difficulty.Impossible)
end

-- A 1% attack makes the engine hand over a tribe only we border.
function AiAttackBehavior._annexWalledInBots(self: AiAttackBehavior)
	if not self:_annexesBots() then
		return
	end
	local bots = self:_neighboringBots()
	if #bots == 0 then
		return
	end
	local troops = math.floor(self.player:troops() / 100)
	if troops < 1 then
		return
	end
	for _, bot in require(script.Parent.Nation.BotAnnexation).walledInBots(self.game, self.player, bots) do
		self.game:addExecution(AttackExecution.new(troops, self.player, bot:id()))
	end
end

function AiAttackBehavior._getBotAttackMaxParallelism(self: AiAttackBehavior): number
	local d = self.game:config():gameConfig().difficulty
	if d == Difficulty.Easy then
		return 1
	elseif d == Difficulty.Medium then
		return if self.random:chance(2) then 1 else 2
	elseif d == Difficulty.Hard then
		return 3
	end
	return 100
end

function AiAttackBehavior._assistAllies(self: AiAttackBehavior): boolean
	local player = self.player
	local emoji: any = self.emojiBehavior
	if self.game:config():disableAlliances() then
		return false
	end
	for _, ally in player:allies() do
		if #ally:targets() > 0 then
			if player:relation(ally) < Relation.Friendly then
				emoji:sendEmoji(ally, Emoji.ASSIST_RELATION_TOO_LOW)
			else
				for _, target in ally:targets() do
					if target == player then
						emoji:sendEmoji(ally, Emoji.ASSIST_TARGET_ME)
					elseif player:isFriendly(target) then
						emoji:sendEmoji(ally, Emoji.ASSIST_TARGET_ALLY)
					elseif self:sendAttack(target) then
						player:updateRelation(ally, -20)
						emoji:sendEmoji(ally, Emoji.ASSIST_ACCEPT)
						return true
					end
				end
			end
		end
	end
	return false
end

-- The weakest traitor not much stronger than us.
function AiAttackBehavior._findTraitor(self: AiAttackBehavior, enemies: { any }): any?
	if self.game:config():disableAlliances() then
		return nil
	end
	for _, e in enemies do
		if e:isTraitor() and (not self:_isFFA() or e:troops() < self.player:troops() * 1.2) then
			return e
		end
	end
	return nil
end

function AiAttackBehavior._maybeBetrayAndAttack(self: AiAttackBehavior, friends: { any }, enemies: { any }): boolean
	if self.game:config():disableAlliances() then
		return false
	end
	if #friends > 0 then
		local alliance: any = self.allianceBehavior
		local juiciest = alliance:findJuiciestAlly(friends)
		for _, friend in friends do
			-- Conquest: a betrayal opens a war, so it waits for the grace and limit too.
			if not HumanProtection.offLimits(self.game, self.player, friend) and alliance:maybeBetray(friend, juiciest, friends, enemies) then
				return self:sendAttack(friend, true)
			end
		end
	end
	return false
end

function AiAttackBehavior._isBorderingNukedTerritory(self: AiAttackBehavior): boolean
	local game = self.game
	if game:config():isUnitDisabled(UnitType.MissileSilo) then
		return false
	end
	local map = game:map()
	for _, tile in self.player:borderTiles():values() do
		local n = map:neighbors4(tile, self.nbuf)
		for i = 1, n do
			local nb = self.nbuf[i]
			if game:isLand(nb) and not game:hasOwner(nb) and game:hasFallout(nb) then
				return true
			end
		end
	end
	return false
end

-- The weakest enemy under big attack (50%+ of its troops incoming).
function AiAttackBehavior._findVictim(self: AiAttackBehavior, enemies: { any }): any?
	for _, e in enemies do
		if not (self:_isFFA() and e:troops() > self.player:troops() * 1.2) then
			if sumTroops(e:incomingAttacks()) > e:troops() * 0.5 then
				return e
			end
		end
	end
	return nil
end

-- The weakest enemy under 15% of its max troops, not much stronger than us.
function AiAttackBehavior._findVeryWeakEnemy(self: AiAttackBehavior, enemies: { any }): any?
	for _, e in enemies do
		if e:troops() < self.game:config():maxTroops(e) * 0.15 and (not self:_isFFA() or e:troops() < self.player:troops() * 1.2) then
			return e
		end
	end
	return nil
end

function AiAttackBehavior._findJuicyTarget(self: AiAttackBehavior, enemies: { any }): any?
	local candidates = {}
	for _, e in enemies do
		if e:troops() <= self.player:troops() * 0.75 then
			table.insert(candidates, e)
		end
	end
	return NationUtils().findJuiciestTarget(self.game, candidates)
end

function AiAttackBehavior._playerCenter(self: AiAttackBehavior, p: any): (number, number)
	local box = p.largestClusterBoundingBox
	if box then
		return box.minX + (box.maxX - box.minX) // 2, box.minY + (box.maxY - box.minY) // 2
	end
	local b = NationUtils().borderBoundingBox(self.game, p)
	return b.min.x + math.floor((b.max.x - b.min.x) / 2), b.min.y + math.floor((b.max.y - b.min.y) / 2)
end

function AiAttackBehavior._findNearestIslandEnemy(self: AiAttackBehavior): any?
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.TransportShip) then
		return nil
	end
	if player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return nil
	end
	local hasShore = false
	for _, t in player:borderTiles():values() do
		if game:isShore(t) then
			hasShore = true
			break
		end
	end
	if not hasShore then
		return nil
	end
	local filtered = {}
	for _, p in game:players() do
		if p ~= player and not player:isFriendly(p) and (not self:_isFFA() or p:troops() < player:troops()) then
			table.insert(filtered, p)
		end
	end
	if #filtered == 0 then
		return nil
	end
	local px, py = self:_playerCenter(player)
	local myCenter = game:ref(px, py)
	local entries = {}
	for _, p in filtered do
		local cx, cy = self:_playerCenter(p)
		table.insert(entries, { player = p, distance = game:manhattanDist(myCenter, game:ref(cx, cy)) })
	end
	entries = Util.stableSort(entries, function(a, b)
		return a.distance < b.distance
	end)
	-- Beachhead boats sail any distance, even past a warship.
	local reachable = {}
	for _, e in entries do
		local ok = if self:_landsBeachheads() then (self:_bordersByLand(e.player) or self:_boatRoute(e.player) ~= nil) else self:_canReach(e.player)
		if ok then
			table.insert(reachable, e.player)
			if #reachable >= 2 then
				break
			end
		end
	end
	if #reachable == 0 then
		return nil
	end
	if #reachable >= 2 and self.random:chance(3) then
		return reachable[2]
	end
	return reachable[1]
end

function AiAttackBehavior._bordersByLand(self: AiAttackBehavior, target: any): boolean
	local land = self.landNeighbors
	if land ~= nil then
		return table.find(land, target) ~= nil
	end
	return self.player:sharesBorderWith(target)
end

-- By land, or by a boat no hostile warship stops that isn't sailing too far.
function AiAttackBehavior._canReach(self: AiAttackBehavior, target: any): boolean
	if self:_bordersByLand(target) then
		return true
	end
	local route = self:_boatRoute(target)
	return route ~= nil and route.blocker == nil and route.length <= self:_maxBoatRoute()
end

function AiAttackBehavior._maxBoatRoute(self: AiAttackBehavior): number
	local d = self.game:config():gameConfig().difficulty
	if d == Difficulty.Hard then
		return 300
	elseif d == Difficulty.Impossible then
		return 500
	end
	return math.huge
end

-- Enemies across the water whose main territory is within boat range.
function AiAttackBehavior._overseasTargets(self: AiAttackBehavior, enemies: { any }): { any }
	local game, player = self.game, self.player
	if player:unitCount(UnitType.TransportShip) >= game:config():boatMaxNumber() then
		return {}
	end
	local range = self:_maxBoatRoute()
	local ours = player.largestClusterBoundingBox
	local out = {}
	for _, p in game:players() do
		if
			p ~= player
			and p:type() ~= PlayerType.Bot
			and not player:isFriendly(p)
			and not table.find(enemies, p)
			and (not self:_isFFA() or p:troops() < player:troops())
			and boxGap(ours, p.largestClusterBoundingBox) <= range
		then
			table.insert(out, p)
		end
	end
	return out
end

-- Hard and up send warships at whatever blocks the juiciest target they
-- couldn't reach (any distance without a land front).
function AiAttackBehavior._clearBlockedLane(self: AiAttackBehavior, routes: { map: { [any]: any }, order: { any } }, landFront: boolean)
	if self.warshipBehavior == nil then
		return
	end
	local d = self.game:config():gameConfig().difficulty
	if d ~= Difficulty.Hard and d ~= Difficulty.Impossible then
		return
	end
	local maxRoute = self:_maxBoatRoute()
	local blockedOrder, blocked = {}, {}
	for _, target in routes.order do
		local route = routes.map[target]
		if route and route.blocker and (not landFront or route.length <= maxRoute) and (not self:_isFFA() or target:troops() < self.player:troops()) then
			table.insert(blockedOrder, target)
			blocked[target] = route.blocker
		end
	end
	local target = NationUtils().findJuiciestTarget(self.game, blockedOrder)
	if target ~= nil then
		self.warshipBehavior:clearSeaLane(blocked[target])
	end
end

function AiAttackBehavior._calculateBotAttackTroops(self: AiAttackBehavior, target: any, maxTroops: number): number
	local d = self.game:config():gameConfig().difficulty
	if d == Difficulty.Easy then
		return maxTroops
	elseif d == Difficulty.Medium then
		local troops = target:troops() * 4
		if troops > maxTroops then
			troops = if maxTroops < target:troops() * 2 then 0 else maxTroops
		end
		return troops
	end
	-- Top up what already attacks the tribe, or wait until we can send it all.
	local troops = self:_botAttackTroopsNeeded(target) * 1.3 - self:_ourStackAgainst(target)
	return if troops <= maxTroops then troops else 0
end

-- Keeps the attack at its cheapest loss rate until the tribe drops below 100 tiles.
function AiAttackBehavior._botAttackTroopsNeeded(self: AiAttackBehavior, bot: any): number
	local stack = math.max(1, bot:troops() / CHEAPEST_TROOP_RATIO)
	local tiles = math.max(0, bot:numTilesOwned() - 100)
	return math.max(stack, tiles * self:_botTileLoss(bot, stack))
end

-- Troops lost per tile: Impossible samples the terrain on a 6x6 grid over
-- the tribe's land, Hard assumes highland.
function AiAttackBehavior._botTileLoss(self: AiAttackBehavior, bot: any, stack: number): number
	local game = self.game
	local terrains = {}
	local box = bot.largestClusterBoundingBox
	if game:config():gameConfig().difficulty == Difficulty.Impossible and box then
		local width = box.maxX - box.minX + 1
		local height = box.maxY - box.minY + 1
		for i = 0, 5 do
			for j = 0, 5 do
				local tile = game:ref(box.minX + math.floor(((2 * i + 1) * width) / 12), box.minY + math.floor(((2 * j + 1) * height) / 12))
				if game:ownerID(tile) == bot:smallID() then
					table.insert(terrains, game:terrainType(tile))
				end
			end
		end
	end
	if #terrains == 0 then
		table.insert(terrains, GameTypes.TerrainType.Highland)
	end
	local loss = 0
	for _, terrain in terrains do
		loss += game:config():attackLogic({
			terrain = terrain,
			attackTroops = stack,
			attacker = { type = self.player:type(), numTiles = self.player:numTilesOwned() },
			defender = {
				type = bot:type(),
				numTiles = bot:numTilesOwned(),
				troops = bot:troops(),
				isTraitor = bot:isTraitor(),
				isDisconnectedTeammate = false,
			},
			defenderHasDefensePost = false,
			falloutRatio = nil,
			borderSize = 1,
		}).attackerTroopLoss
	end
	return loss / #terrains
end

-- Land attacks on one target merge; the target's attacks on us cancel out.
function AiAttackBehavior._ourStackAgainst(self: AiAttackBehavior, target: any): number
	local troops = 0
	for _, a in self.player:outgoingAttacks() do
		if a:target() == target and a:sourceTile() == nil then
			troops += a:troops()
		end
	end
	for _, a in self.player:incomingAttacks() do
		if a:attacker() == target then
			troops -= a:troops()
		end
	end
	return troops
end

-- Team games (not public): troops to the teammate in combat with the
-- lowest troop share.
function AiAttackBehavior._donateTroops(self: AiAttackBehavior): boolean
	local game, player = self.game, self.player
	local config = game:config():gameConfig()
	if config.gameMode ~= GameTypes.GameMode.Team then
		return false
	end
	if config.gameType == GameTypes.GameType.Public then
		return false
	end
	if game:config():donateTroops() == false then
		return false
	end
	local d = config.difficulty
	if d == Difficulty.Easy then
		return false
	elseif d == Difficulty.Medium then
		if not self.random:chance(4) then
			return false
		end
	elseif d == Difficulty.Hard then
		if not self.random:chance(2) then
			return false
		end
	end
	local entries = {}
	for _, p in game:players() do
		if player:isOnSameTeam(p) and (#p:incomingAttacks() > 0 or #p:outgoingAttacks() > 0) then
			table.insert(entries, { teammate = p, share = p:troops() / math.max(game:config():maxTroops(p), 1) })
		end
	end
	if #entries == 0 then
		return false
	end
	entries = Util.stableSort(entries, function(a, b)
		return a.share < b.share
	end)
	local selected = nil
	for _, e in entries do
		if player:canDonateTroops(e.teammate) then
			selected = e.teammate
			break
		end
	end
	if selected == nil then
		return false
	end
	local available = player:troops() - game:config():maxTroops(player) * self.reserveRatio
	if available < 1 then
		return false
	end
	game:addExecution(require(script.Parent.DonateExecution).Troops.new(player, selected:id(), available))
	return true
end

return AiAttackBehavior
