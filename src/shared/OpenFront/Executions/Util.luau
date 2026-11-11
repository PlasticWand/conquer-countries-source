--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/Util.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Helpers shared by executions. Grows as more executions are ported.

local GameMap = require(script.Parent.Parent.GameMap)
local Util = require(script.Parent.Parent.Util)

local ExecUtil = {}

-- Util.ts getSpawnTiles: the radius-4 disc around `tile` (BFS order). With
-- requireAllValid, nil if any of it is owned, water or impassable;
-- otherwise just the valid tiles.
function ExecUtil.getSpawnTiles(gm: any, tile: number, requireAllValid: boolean?): { number }?
	local spawnTiles = gm:bfs(tile, GameMap.euclDistFN(tile, 4, true))
	local function isInvalid(t: number): boolean
		return gm:hasOwner(t) or not gm:isLand(t) or gm:isImpassable(t)
	end
	if not requireAllValid then
		local out = {}
		for _, t in spawnTiles do
			if not isInvalid(t) then
				table.insert(out, t)
			end
		end
		return out
	end
	for _, t in spawnTiles do
		if isInvalid(t) then
			return nil
		end
	end
	return spawnTiles
end

-- Util.ts closestTile
function ExecUtil.closestTile(gm: any, refs: { number }, tile: number): (number?, number)
	local minDistance = math.huge
	local minRef = nil
	for _, ref in refs do
		local distance = gm:manhattanDist(ref, tile)
		if distance < minDistance then
			minDistance = distance
			minRef = ref
		end
	end
	return minRef, minDistance
end

-- Util.ts closestTwoTiles: a near-closest pair between two tile lists, by
-- a sweep over both sorted by x (stable, like the original).
function ExecUtil.closestTwoTiles(gm: any, xs: { number }, ys: { number }): { x: number, y: number }?
	local w = gm:width()
	local function byX(a: number, b: number): boolean
		return a % w < b % w
	end
	local xSorted = Util.stableSort(table.clone(xs), byX)
	local ySorted = Util.stableSort(table.clone(ys), byX)
	if #xSorted == 0 or #ySorted == 0 then
		return nil
	end
	local i, j = 1, 1
	local minDistance = math.huge
	local result = { x = xSorted[1], y = ySorted[1] }
	while i <= #xSorted and j <= #ySorted do
		local cx, cy = xSorted[i], ySorted[j]
		local cxX, cyX = cx % w, cy % w
		local distance = math.abs(cxX - cyX) + math.abs(cx // w - cy // w)
		if distance < minDistance then
			minDistance = distance
			result = { x = cx, y = cy }
		end
		if i == #xSorted then
			j += 1
		elseif j == #ySorted then
			i += 1
		elseif cxX < cyX then
			i += 1
		else
			j += 1
		end
	end
	return result
end

-- Util.ts nearestTileDist: Manhattan distance to the nearest of `tiles`
-- (a list), or math.huge.
function ExecUtil.nearestTileDist(gm: any, tiles: { number }, tile: number): number
	local best = math.huge
	for _, t in tiles do
		local d = gm:manhattanDist(t, tile)
		if d < best then
			best = d
		end
	end
	return best
end

-- Util.ts nearestTileDistCapped: the same, but only up to `cap` (math.huge
-- beyond), walking Manhattan rings round `tile` over a TileSet.
function ExecUtil.nearestTileDistCapped(gm: any, tiles: any, tile: number, cap: number): number
	if type(tiles.has) ~= "function" then
		local d = ExecUtil.nearestTileDist(gm, tiles, tile)
		return if d <= cap then d else math.huge
	end
	if tiles:size() == 0 then
		return math.huge
	end
	if tiles:has(tile) then
		return 0
	end
	local w, h = gm:width(), gm:height()
	local cx, cy = gm:x(tile), gm:y(tile)
	-- The same walk, reading TileSet's slot table directly: a method call per
	-- probe made the nations' structure placement a server-tick spike
	-- (2026-10-29 profile). `slot` is TileSet.has's own lookup.
	local slot = tiles.slot
	if type(slot) ~= "table" then
		slot = nil
	end
	for d = 1, cap do
		for dx = -d, d do
			local x = cx + dx
			if x >= 0 and x < w then
				local dy = d - math.abs(dx)
				local y1 = cy - dy
				if y1 >= 0 and (if slot then slot[y1 * w + x] ~= nil else tiles:has(y1 * w + x)) then
					return d
				end
				if dy ~= 0 then
					local y2 = cy + dy
					if y2 < h and (if slot then slot[y2 * w + x] ~= nil else tiles:has(y2 * w + x)) then
						return d
					end
				end
			end
		end
	end
	return math.huge
end

-- Util.ts calculateTerritoryCenter: the centre of the border's bounding
-- box if the target owns it, else the border tile closest to it.
function ExecUtil.calculateTerritoryCenter(game: any, target: any): number?
	local border = target:borderTiles():values()
	if #border == 0 then
		return nil
	end
	local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
	for _, t in border do
		local x, y = game:x(t), game:y(t)
		minX, maxX = math.min(minX, x), math.max(maxX, x)
		minY, maxY = math.min(minY, y), math.max(maxY, y)
	end
	local cx, cy = math.floor((minX + maxX) / 2), math.floor((minY + maxY) / 2)
	local center = game:ref(cx, cy)
	if game:owner(center) == target then
		return center
	end
	local closest, best = nil, math.huge
	for _, t in border do
		local dx, dy = game:x(t) - cx, game:y(t) - cy
		local d = dx * dx + dy * dy
		if d < best then
			best = d
			closest = t
		end
	end
	return closest
end

return ExecUtil
