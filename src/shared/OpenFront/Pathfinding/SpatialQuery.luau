--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/spatial/SpatialQuery.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Shore lookups for ships: the nearest qualifying shore by a bounded walk,
-- the best launch shore by water pathfinding (refined near the start), and
-- the water bodies a player's coast touches (memoised per player).

local AStarWaterBounded = require(script.Parent.AStarWaterBounded)
local PathFinding = require(script.Parent.PathFinding)

local REFINE_MAX_SEARCH_AREA = 100 * 100

local SpatialQuery = {}
SpatialQuery.__index = SpatialQuery

export type SpatialQuery = typeof(setmetatable({} :: { game: any }, SpatialQuery))

function SpatialQuery.new(game: any): SpatialQuery
	return setmetatable({ game = game }, SpatialQuery)
end

-- One bounded A* scratch per game (the original makes one per query; only
-- its stamped scratch differs, never the answer).
local function boundedAStar(game: any): any
	local cached = game._spatialAStar
	if cached == nil then
		cached = AStarWaterBounded.new(game:map(), REFINE_MAX_SEARCH_AREA)
		game._spatialAStar = cached
	end
	return cached
end

-- Conquest: the walk below marks tiles in an order that depends only on the
-- offsets from `from` while its diamond stays inside the map. Replaying it once
-- per radius on an open grid gives each offset its mark rank; the rings list
-- offsets by distance, then rank.
local MAX_RING_RADIUS = 200
local ringCache: { [number]: { { dx: { number }, dy: { number } } } } = {}
local function ringsFor(radius: number): { { dx: { number }, dy: { number } } }
	local cached = ringCache[radius]
	if cached then
		return cached
	end
	local side = 2 * radius + 1
	local marked = buffer.create(side * side)
	local rings = {}
	for d = 0, radius do
		rings[d + 1] = { dx = {}, dy = {} }
	end
	local stack = {}
	local function mark(dx: number, dy: number)
		buffer.writeu8(marked, (dy + radius) * side + dx + radius, 1)
		table.insert(stack, { dx, dy })
		local ring = rings[math.abs(dx) + math.abs(dy) + 1]
		table.insert(ring.dx, dx)
		table.insert(ring.dy, dy)
	end
	local function visit(dx: number, dy: number)
		if math.abs(dx) + math.abs(dy) <= radius and buffer.readu8(marked, (dy + radius) * side + dx + radius) == 0 then
			mark(dx, dy)
		end
	end
	mark(0, 0)
	while #stack > 0 do
		local curr = table.remove(stack) :: { number }
		local dx, dy = curr[1], curr[2]
		visit(dx, dy - 1)
		visit(dx, dy + 1)
		visit(dx - 1, dy)
		visit(dx + 1, dy)
	end
	ringCache[radius] = rings
	return rings
end

-- Nearest tile matching `predicate` within Manhattan `maxDist`, ignoring
-- terrain. Depth-first (LIFO, neighbours N, S, W, E); the first candidate at
-- the minimum distance wins.
function SpatialQuery._bfsNearest(self: SpatialQuery, from: number, maxDist: number, predicate: (number) -> boolean): number?
	local game = self.game
	local map = game:map()
	if not map:isValidRef(from) then
		return nil
	end
	-- Conquest: the same answer from the precomputed mark order, checking
	-- rings outward and stopping at the first hit (the walk reads every tile
	-- in the diamond: ~5,000 at the default 50). Near the map's edge the
	-- order changes, so the walk runs there.
	local w, h = map:width(), map:height()
	local x, y = from % w, from // w
	if maxDist >= 0 and maxDist <= MAX_RING_RADIUS and maxDist == math.floor(maxDist)
		and x - maxDist >= 0 and x + maxDist < w and y - maxDist >= 0 and y + maxDist < h then
		game:bumpTraversalGeneration()
		for _, ring in ringsFor(maxDist) do
			local dxs, dys = ring.dx, ring.dy
			for i = 1, #dxs do
				local t = from + dys[i] * w + dxs[i]
				if predicate(t) then
					return t
				end
			end
		end
		return nil
	end
	local scratch = game:traversalScratch()
	local gen = game:bumpTraversalGeneration()
	local visited = scratch.visited
	local stack = scratch.stack
	table.clear(stack)
	local best: number? = nil
	local bestDist = math.huge
	local function mark(t: number)
		buffer.writeu32(visited, t * 4, gen)
		table.insert(stack, t)
		if predicate(t) then
			local dist = map:manhattanDist(from, t)
			if dist < bestDist then
				best = t
				bestDist = dist
			end
		end
	end
	if maxDist >= 0 then
		mark(from)
	end
	local function visit(n: number)
		if buffer.readu32(visited, n * 4) ~= gen and map:manhattanDist(from, n) <= maxDist then
			mark(n)
		end
	end
	while #stack > 0 do
		local curr = table.remove(stack) :: number
		map:forEachNeighbor(curr, visit)
	end
	return best
end

-- Closest shore tile owned by `owner` (players and terra nullius).
function SpatialQuery.closestShore(self: SpatialQuery, owner: any, tile: number, maxDist: number?): number?
	local gm = self.game
	local ownerId = owner:smallID()
	return self:_bfsNearest(tile, maxDist or 50, function(t: number): boolean
		return gm:isShore(t) and gm:isLand(t) and gm:ownerID(t) == ownerId
	end)
end

-- Closest shore of `targetOwner` near `tile` on water the attacker's own
-- coast touches (so never a shore facing an unreachable lake).
function SpatialQuery.closestReachableShore(self: SpatialQuery, targetOwner: any, attacker: any, tile: number, maxDist: number?): number?
	local gm = self.game
	local limit = maxDist or 50
	local targetId = targetOwner:smallID()
	local reachable = self:_reachableComponents(attacker)
	if next(reachable) == nil then
		return nil
	end
	local function isValidTile(t: number): boolean
		if not gm:isShore(t) or not gm:isLand(t) then
			return false
		end
		if gm:ownerID(t) ~= targetId then
			return false
		end
		local component = gm:getWaterComponent(t)
		return component ~= nil and reachable[component] == true
	end
	-- The start tile is at distance 0: if it qualifies nothing beats it.
	if limit >= 0 and gm:map():isValidRef(tile) and isValidTile(tile) then
		return tile
	end
	return self:_bfsNearest(tile, limit, isValidTile)
end

function SpatialQuery._reachableComponents(self: SpatialQuery, attacker: any): { [number]: true }
	local gm = self.game
	-- Conquest: reads only the shore tiles, so it keys on shoreVersion.
	local tileVersion = attacker:shoreVersion()
	local waterVersion = gm:map():waterVersion()
	local cached = attacker._reachableComponents
	if cached ~= nil and cached.tileVersion == tileVersion and cached.waterVersion == waterVersion then
		return cached.components
	end
	local components: { [number]: true } = {}
	attacker:borderTiles():forEach(function(t: number)
		if gm:isShore(t) and gm:isLand(t) then
			local component = gm:getWaterComponent(t)
			if component ~= nil then
				components[component] = true
			end
		end
	end)
	attacker._reachableComponents = { tileVersion = tileVersion, waterVersion = waterVersion, components = components }
	return components
end

-- The owner's shore tile to launch from toward `target`, by water.
function SpatialQuery.closestShoreByWater(self: SpatialQuery, owner: any, target: number): number?
	if not owner:isPlayer() then
		return nil
	end
	local gm = self.game
	if not gm:isWater(target) and not gm:isShore(target) then
		return nil
	end
	local targetComponent = gm:getWaterComponent(target)
	if targetComponent == nil then
		return nil
	end
	-- Conquest: the answer depends only on the owner's shore tiles (in border
	-- order), the water graph and the terrain, so it is kept until one of
	-- them changes. A nation's boat asks twice (choosing a target, then the
	-- boat's launch), and a nation at war asks again every attack cycle.
	-- shoreVersion, not tileChangeVersion (Bruno, 2026-11-08: server spikes):
	-- inland fighting no longer throws the answers away.
	local tileVersion, graphVersion, waterVersion = owner:shoreVersion(), gm:waterGraphVersion(), gm:map():waterVersion()
	local memo = owner._shoreByWater
	if memo == nil or memo.tileVersion ~= tileVersion or memo.graphVersion ~= graphVersion or memo.waterVersion ~= waterVersion then
		memo = { tileVersion = tileVersion, graphVersion = graphVersion, waterVersion = waterVersion, results = {} }
		owner._shoreByWater = memo
	end
	local known = memo.results[target]
	if known ~= nil then
		return if known == false then nil else known
	end
	local result = self:_closestShoreByWater(owner, target, targetComponent)
	memo.results[target] = if result == nil then false else result
	return result
end

function SpatialQuery._closestShoreByWater(self: SpatialQuery, owner: any, target: number, targetComponent: number): number?
	local gm = self.game
	local shores = {}
	owner:borderTiles():forEach(function(t: number)
		if gm:isShore(t) and gm:isLand(t) and gm:getWaterComponent(t) == targetComponent then
			table.insert(shores, t)
		end
	end)
	if #shores == 0 then
		return nil
	end
	local stepper = PathFinding.Stepper.new(PathFinding.sharedWaterChain(gm), gm)
	local path = stepper:findPath(shores, target)
	if path == nil or #path == 0 then
		return nil
	end
	return self:_refineStartTile(path, shores)
end

-- A bounded search from nearby shores to a waypoint a little way along the
-- path, so the launch shore suits the actual route.
function SpatialQuery._refineStartTile(self: SpatialQuery, path: { number }, shores: { number }): number
	local CANDIDATE_RADIUS = 20
	local MIN_WAYPOINT_DIST = 50
	local MAX_WAYPOINT_DIST = 200
	local PADDING = 10
	if #path <= MIN_WAYPOINT_DIST then
		return path[1]
	end
	local bestTile = path[1]
	local map = self.game:map()
	local candidates = {}
	for _, s in shores do
		if map:manhattanDist(s, bestTile) <= CANDIDATE_RADIUS then
			table.insert(candidates, s)
		end
	end
	if #candidates <= 1 then
		return bestTile
	end
	local cMinX, cMinY = map:x(candidates[1]), map:y(candidates[1])
	local cMaxX, cMaxY = cMinX, cMinY
	for i = 2, #candidates do
		local sx, sy = map:x(candidates[i]), map:y(candidates[i])
		cMinX, cMaxX = math.min(cMinX, sx), math.max(cMaxX, sx)
		cMinY, cMaxY = math.min(cMinY, sy), math.max(cMaxY, sy)
	end
	-- Binary search (5 steps) for the farthest waypoint keeping the box small.
	local lo, hi = MIN_WAYPOINT_DIST, math.min(MAX_WAYPOINT_DIST, #path - 1)
	local bestIdx = lo
	local i = 0
	while i < 5 and lo <= hi do
		local mid = (lo + hi) // 2
		local wp = path[mid + 1]
		local wpX, wpY = map:x(wp), map:y(wp)
		local minX, maxX = math.min(cMinX, wpX) - PADDING, math.max(cMaxX, wpX) + PADDING
		local minY, maxY = math.min(cMinY, wpY) - PADDING, math.max(cMaxY, wpY) + PADDING
		if (maxX - minX + 1) * (maxY - minY + 1) <= REFINE_MAX_SEARCH_AREA then
			bestIdx = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
		i += 1
	end
	local waypoint = path[bestIdx + 1]
	local wpX, wpY = map:x(waypoint), map:y(waypoint)
	local bounds = {
		minX = math.max(0, math.min(cMinX, wpX) - PADDING),
		maxX = math.min(map:width() - 1, math.max(cMaxX, wpX) + PADDING),
		minY = math.max(0, math.min(cMinY, wpY) - PADDING),
		maxY = math.min(map:height() - 1, math.max(cMaxY, wpY) + PADDING),
	}
	if (bounds.maxX - bounds.minX + 1) * (bounds.maxY - bounds.minY + 1) > REFINE_MAX_SEARCH_AREA then
		return bestTile
	end
	local refined = boundedAStar(self.game):searchBounded(candidates, waypoint, bounds)
	return if refined and refined[1] then refined[1] else bestTile
end

return SpatialQuery
