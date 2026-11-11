--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/PlayerExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Each tick for one player:
--   - relations decay; structures on lost land are captured or destroyed
--   - troops and gold grow; alliances and temporary embargoes expire
--   - every 20 ticks (or every tick under 100 tiles), border clusters are
--     checked: land surrounded by a single enemy goes to that enemy
--   - land a nuke's fallout cuts off from the main body, with only enemies
--     and fallout around it, goes to the surrounding enemy

local GameTypes = require(script.Parent.Parent.GameTypes)
local Util = require(script.Parent.Parent.Util)

local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

local TICKS_PER_CLUSTER_CALC = 20

local CLUSTER_SURROUNDED = 1
local CLUSTER_SEVERED_CANDIDATE = 2
local CLUSTER_OPEN = 4

local STRUCTURES = {
	[UnitType.City] = true,
	[UnitType.DefensePost] = true,
	[UnitType.SAMLauncher] = true,
	[UnitType.MissileSilo] = true,
	[UnitType.Port] = true,
	[UnitType.Factory] = true,
}

local PlayerExecution = {}
PlayerExecution.__index = PlayerExecution

export type PlayerExecution = typeof(setmetatable(
	{} :: {
		player: any,
		mg: any,
		map: any,
		config: any,
		lastCalc: number,
		active: boolean,
		nbuf: { number },
		nbuf8: { number },
	},
	PlayerExecution
))

function PlayerExecution.new(player: any): PlayerExecution
	return setmetatable({
		player = player,
		mg = nil,
		map = nil,
		config = nil,
		lastCalc = 0,
		active = true,
		nbuf = { 0, 0, 0, 0 },
		nbuf8 = { 0, 0, 0, 0, 0, 0, 0, 0 },
	}, PlayerExecution)
end

function PlayerExecution.activeDuringSpawnPhase(_self: PlayerExecution): boolean
	return false
end

function PlayerExecution.init(self: PlayerExecution, mg: any, ticks: number)
	self.mg = mg
	self.map = mg:map()
	self.config = mg:config()
	self.lastCalc = ticks + (Util.simpleHash(self.player:id()) % TICKS_PER_CLUSTER_CALC)
end

function PlayerExecution.tick(self: PlayerExecution, ticks: number)
	local player, mg = self.player, self.mg
	player:decayRelations()
	local units: { any } = table.clone(player:units())
	for _, u in units do
		if STRUCTURES[u:type()] then
			local owner = mg:owner(u:tile())
			if not owner:isPlayer() then
				u:delete()
			elseif owner ~= player then
				local captor = mg:player(owner:id())
				if u:type() == UnitType.DefensePost then
					u:delete(true, captor)
				else
					captor:captureUnit(u)
				end
			end
		end
	end

	if not player:isAlive() then
		self:_removeOnDeath()
		self.active = false
		local stillStanding = 0
		for _, p in mg:players() do
			if p:type() ~= PlayerType.Bot then
				stillStanding += 1
			end
		end
		mg:stats():recordDeathPosition(player, stillStanding + 1)
		return
	end

	player:addTroops(self.config:troopIncreaseRate(player))
	player:addGold(self.config:goldAdditionRate(player))

	local alliances: { any } = table.clone(player:alliances())
	for _, alliance in alliances do
		if alliance:expiresAt() <= mg:ticks() then
			alliance:expire()
		end
	end

	for _, embargo in player:getEmbargoes() do
		if embargo.isTemporary and mg:ticks() - embargo.createdAt > mg:config():temporaryEmbargoDuration() then
			player:stopEmbargo(embargo.target)
		end
	end

	if ticks - self.lastCalc > TICKS_PER_CLUSTER_CALC or player:numTilesOwned() < 100 then
		if player:lastTileChange() >= self.lastCalc then
			self.lastCalc = ticks
			self:_removeClusters()
		end
	end
end

-- Severed land -----------------------------------------------------------------------
-- Boxes in these lists are flat too: piece k (1-based) at [(k-1)*4+1 .. +4].

type Candidates = { clusters: { { number } }, boxes: { number } }
type Parts = { clusters: { { number } }, boxes: { number }, classes: { number } }
type Pieces = { clusters: { { number } }, boxes: { number }, open: { boolean } }

-- A cluster that does not split is a single territory, classed as a whole.
local function wholeCluster(cluster: { number }, boxes: { number }, boxOffset: number, cls: number): Parts
	return {
		clusters = { cluster },
		boxes = { boxes[boxOffset + 1], boxes[boxOffset + 2], boxes[boxOffset + 3], boxes[boxOffset + 4] },
		classes = { cls },
	}
end

-- Adds the parts that race for the main body: every part with `all`, else
-- the candidates and, with `withOpen`, the parts with a way out.
local function addRacePieces(pieces: Pieces, parts: Parts, all: boolean, withOpen: boolean)
	for k, cluster in parts.clusters do
		local cls = parts.classes[k]
		local open = bit32.band(cls, CLUSTER_OPEN) ~= 0
		if all or bit32.band(cls, CLUSTER_SEVERED_CANDIDATE) ~= 0 or (withOpen and open) then
			table.insert(pieces.clusters, cluster)
			table.insert(pieces.open, open)
			local o = (k - 1) * 4
			table.insert(pieces.boxes, parts.boxes[o + 1])
			table.insert(pieces.boxes, parts.boxes[o + 2])
			table.insert(pieces.boxes, parts.boxes[o + 3])
			table.insert(pieces.boxes, parts.boxes[o + 4])
		end
	end
end

-- The flood that `part` merged into (0-based indices, as in the original).
local function rootOf(roots: { number }, part: number): number
	while roots[part + 1] ~= part do
		part = roots[part + 1]
	end
	return part
end

local function pushBox(list: { number }, boxes: { number }, o: number)
	table.insert(list, boxes[o + 1])
	table.insert(list, boxes[o + 2])
	table.insert(list, boxes[o + 3])
	table.insert(list, boxes[o + 4])
end

-- PlayerExecution.ts severedLand: picks the main body (the piece with the
-- largest territory, not the longest border) and returns it with the land
-- that may be cut off from it, or nil when none can be.
function PlayerExecution._severedLand(
	self: PlayerExecution,
	largestCluster: { number },
	boxes: { number },
	boxOffset: number,
	severed: Candidates?,
	openClusters: Candidates?
): { mainTiles: { { number } }, candidates: Candidates }?
	if self.map:numTilesWithFallout() == 0 then
		return nil
	end
	local largest = self:_splitCluster(largestCluster, false)
	if largest == nil then
		if severed == nil and openClusters == nil then
			return nil
		end
		largest = wholeCluster(
			largestCluster,
			boxes,
			boxOffset,
			self:_classifyCluster(largestCluster, boxes[boxOffset + 1], boxes[boxOffset + 2], boxes[boxOffset + 3], boxes[boxOffset + 4])
		)
	end
	local lp = largest :: Parts
	-- Land with a way out races only when the largest cluster could itself be
	-- the cut-off piece: none of its parts has a way out and one is a candidate.
	local anyOpen, anyCandidate = false, false
	for _, c in lp.classes do
		if bit32.band(c, CLUSTER_OPEN) ~= 0 then
			anyOpen = true
		end
		if bit32.band(c, CLUSTER_SEVERED_CANDIDATE) ~= 0 then
			anyCandidate = true
		end
	end
	local addOpen = not anyOpen and anyCandidate

	local pieces: Pieces = { clusters = {}, boxes = {}, open = {} }
	addRacePieces(pieces, lp, true, true)
	local largestParts = #pieces.clusters
	if severed ~= nil then
		for c, cluster in severed.clusters do
			local parts = self:_splitCluster(cluster, false) or wholeCluster(cluster, severed.boxes, (c - 1) * 4, CLUSTER_SEVERED_CANDIDATE)
			addRacePieces(pieces, parts, false, false)
		end
	end
	if openClusters ~= nil then
		for c, cluster in openClusters.clusters do
			local split = self:_splitCluster(cluster, not addOpen)
			if split ~= nil then
				addRacePieces(pieces, split, false, addOpen)
			elseif addOpen then
				addRacePieces(pieces, wholeCluster(cluster, openClusters.boxes, (c - 1) * 4, CLUSTER_OPEN), false, true)
			end
		end
	end
	if #pieces.clusters < 2 or not table.find(pieces.open, false) then
		return nil
	end

	local count = #pieces.clusters
	local roots = table.create(count, 0)
	local main = self:_largestTerritoryPart(pieces.clusters, roots, pieces.boxes)
	if main == -1 then
		return nil
	end
	local mainTiles = {}
	local candidates: Candidates = { clusters = {}, boxes = {} }
	-- The other clusters' parts first, then the largest cluster's.
	for k = 0, count - 1 do
		local i = (k + largestParts) % count
		if rootOf(roots, i) == main then
			table.insert(mainTiles, pieces.clusters[i + 1])
		elseif not pieces.open[i + 1] then
			table.insert(candidates.clusters, pieces.clusters[i + 1])
			pushBox(candidates.boxes, pieces.boxes, i * 4)
		end
	end
	return if #candidates.clusters > 0 then { mainTiles = mainTiles, candidates = candidates } else nil
end

-- PlayerExecution.ts splitCluster: splits a border cluster (which joins
-- tiles meeting only at a corner) into single-territory parts, each with
-- its box and class; nil when it doesn't split (or, with candidatesOnly,
-- when it borders no fallout).
function PlayerExecution._splitCluster(self: PlayerExecution, cluster: { number }, candidatesOnly: boolean): Parts?
	local map = self.map
	local me = self.player:smallID()
	local w, h = map:width(), map:height()
	if #cluster == 0 or map:ownerID(cluster[1]) ~= me then
		return nil
	end
	-- Only two of our tiles meeting at a corner, with neither tile between
	-- them ours, can split it.
	local pinched = false
	for _, t in cluster do
		if t < (h - 1) * w then
			local below = t + w
			if map:ownerID(below) ~= me then
				local x = t % w
				pinched = (x < w - 1 and map:ownerID(below + 1) == me and map:ownerID(t + 1) ~= me)
					or (x > 0 and map:ownerID(below - 1) == me and map:ownerID(t - 1) ~= me)
				if pinched then
					break
				end
			end
		end
	end
	if not pinched then
		return nil
	end
	local nbuf = self.nbuf
	if candidatesOnly then
		local fallout = false
		for _, t in cluster do
			local n4 = map:neighbors4(t, nbuf)
			for i = 1, n4 do
				local n = nbuf[i]
				if map:ownerID(n) == 0 and map:hasFallout(n) then
					fallout = true
				end
			end
			if fallout then
				break
			end
		end
		if not fallout then
			return nil
		end
	end

	local scratch = self.mg:traversalScratch()
	local visited = scratch.visited
	local memberGen = self:_bumpGenerations(2)
	local doneGen = memberGen + 1
	for _, t in cluster do
		buffer.writeu32(visited, t * 4, memberGen)
	end
	local stack = scratch.stack
	local nbuf8 = self.nbuf8
	local parts, partBoxes, classes = {}, {}, {}
	for _, start in cluster do
		if buffer.readu32(visited, start * 4) == memberGen and map:ownerID(start) == me then
			buffer.writeu32(visited, start * 4, doneGen)
			table.clear(stack)
			table.insert(stack, start)
			local part = {}
			local touchesOpen, hasEnemy, hasFallout = false, false, false
			local minX, minY, maxX, maxY = w, h, -1, -1
			while #stack > 0 do
				local t = table.remove(stack) :: number
				table.insert(part, t)
				local x = t % w
				local y = (t - x) / w
				minX, minY = math.min(minX, x), math.min(minY, y)
				maxX, maxY = math.max(maxX, x), math.max(maxY, y)
				if map:isShore(t) or map:isOnEdgeOfMap(t) then
					touchesOpen = true
				end
				local n8 = map:neighbors8(t, nbuf8)
				for i = 1, n8 do
					local n = nbuf8[i]
					local ownerId = map:ownerID(n)
					local dx = n % w - x
					local diagonal = dx ~= 0 and n - dx ~= t
					if not diagonal and ownerId ~= me then
						if ownerId ~= 0 then
							hasEnemy = true
						elseif map:hasFallout(n) then
							hasFallout = true
						else
							touchesOpen = true
						end
					end
					if buffer.readu32(visited, n * 4) == memberGen and ownerId == me then
						if not (diagonal and map:ownerID(t + dx) ~= me and map:ownerID(n - dx) ~= me) then
							buffer.writeu32(visited, n * 4, doneGen)
							table.insert(stack, n)
						end
					end
				end
			end
			table.insert(parts, part)
			table.insert(partBoxes, minX)
			table.insert(partBoxes, minY)
			table.insert(partBoxes, maxX)
			table.insert(partBoxes, maxY)
			table.insert(
				classes,
				if touchesOpen then CLUSTER_OPEN elseif hasEnemy and hasFallout then CLUSTER_SEVERED_CANDIDATE else 0
			)
		end
	end
	if #parts < 2 then
		return nil
	end
	return { clusters = parts, boxes = partBoxes, classes = classes }
end

-- PlayerExecution.ts largestTerritoryPart: every piece floods its territory
-- one tile per round, all in step; floods that meet merge. Returns the
-- 0-based piece with the largest territory (ties to the lowest), or -1 when
-- every flood leaves its pieces' boxes (rings round holes).
function PlayerExecution._largestTerritoryPart(self: PlayerExecution, parts: { { number } }, roots: { number }, boxes: { number }?): number
	local map = self.map
	local me = self.player:smallID()
	local visited = self.mg:traversalScratch().visited
	local w, h = map:width(), map:height()
	local count = #parts
	local base = self:_bumpGenerations(count)
	local bounds: { number }? = nil
	if boxes ~= nil then
		local b = table.move(boxes, 1, count * 4, 1, {})
		for o = 0, count * 4 - 1, 4 do
			if b[o + 1] == 0 or b[o + 2] == 0 or b[o + 3] == w - 1 or b[o + 4] == h - 1 then
				b[o + 1], b[o + 2], b[o + 3], b[o + 4] = 0, 0, w - 1, h - 1
			end
		end
		bounds = b
	end
	local stacks, sizes, dropped = {}, {}, {}
	for i = 0, count - 1 do
		roots[i + 1] = i
		for _, t in parts[i + 1] do
			buffer.writeu32(visited, t * 4, base + i)
		end
		stacks[i + 1] = table.clone(parts[i + 1])
		sizes[i + 1] = #parts[i + 1]
		dropped[i + 1] = false
	end
	local nbuf = self.nbuf
	local growing = count
	local best = -1
	while true do
		for i = 0, count - 1 do
			local stack = stacks[i + 1]
			if roots[i + 1] == i and not dropped[i + 1] and #stack > 0 then
				local t = table.remove(stack) :: number
				local leftBox = false
				if bounds ~= nil then
					local x = t % w
					local y = (t - x) / w
					local b = i * 4
					if x < bounds[b + 1] or y < bounds[b + 2] or x > bounds[b + 3] or y > bounds[b + 4] then
						table.insert(stack, t) -- kept for a flood that takes this one over
						dropped[i + 1] = true
						growing -= 1
						leftBox = true
					end
				end
				if not leftBox then
					local n4 = map:neighbors4(t, nbuf)
					for k = 1, n4 do
						local n = nbuf[k]
						if map:ownerID(n) == me then
							local part = buffer.readu32(visited, n * 4) - base
							if part < 0 or part >= count then
								buffer.writeu32(visited, n * 4, base + i)
								sizes[i + 1] += 1
								table.insert(stack, n)
							else
								local other = rootOf(roots, part)
								if other ~= i then
									roots[other + 1] = i
									sizes[i + 1] += sizes[other + 1]
									for _, s in stacks[other + 1] do
										table.insert(stack, s)
									end
									table.clear(stacks[other + 1])
									if not dropped[other + 1] then
										growing -= 1
									end
									if bounds ~= nil then
										local b, o = i * 4, other * 4
										bounds[b + 1] = math.min(bounds[b + 1], bounds[o + 1])
										bounds[b + 2] = math.min(bounds[b + 2], bounds[o + 2])
										bounds[b + 3] = math.max(bounds[b + 3], bounds[o + 3])
										bounds[b + 4] = math.max(bounds[b + 4], bounds[o + 4])
									end
								end
							end
						end
					end
					if #stack == 0 then
						growing -= 1
						if best == -1 or sizes[i + 1] > sizes[best + 1] or (sizes[i + 1] == sizes[best + 1] and i < best) then
							best = i
						end
					end
				end
			end
		end
		if growing == 0 then
			return best
		end
		if growing == 1 then
			local last = 0
			while roots[last + 1] ~= last or dropped[last + 1] or #stacks[last + 1] == 0 do
				last += 1
			end
			if best == -1 or sizes[last + 1] > sizes[best + 1] then
				return last
			end
		end
	end
end

-- PlayerExecution.ts annexSeveredClusters: land cut off from the main body,
-- with no coast or map edge of its own and only enemies and fallout around
-- it, goes to the surrounding enemy.
function PlayerExecution._annexSeveredClusters(self: PlayerExecution, candidates: Candidates, mainTiles: { { number } })
	local map = self.map
	local me = self.player:smallID()
	local visited = self.mg:traversalScratch().visited
	for c, cluster in candidates.clusters do
		local mainGen = self:_stampMainBody(mainTiles)
		for _, start in cluster do
			if map:ownerID(start) == me then
				local mark = buffer.readu32(visited, start * 4)
				if not (mark >= mainGen and mark <= mainGen + 2) then
					local territory = self:_severedTerritory(start, mainGen, mainGen + 1, mainGen + 2, candidates.boxes, (c - 1) * 4)
					if territory ~= nil then
						local capturing = self:_getCapturingPlayer(territory)
						if capturing ~= nil then
							if self.player:numTilesOwned() == #territory then
								self.mg:conquerPlayer(capturing, self.player)
							end
							for _, t in territory do
								capturing:conquer(t)
							end
							-- Conquering may run passes that overwrite the stamps.
							mainGen = self:_stampMainBody(mainTiles)
						end
					end
				end
			end
		end
	end
end

function PlayerExecution._stampMainBody(self: PlayerExecution, mainTiles: { { number } }): number
	local mainGen = self:_bumpGenerations(3)
	local visited = self.mg:traversalScratch().visited
	for _, piece in mainTiles do
		for _, t in piece do
			buffer.writeu32(visited, t * 4, mainGen)
		end
	end
	return mainGen
end

-- Floods our territory from `start`; returns it if it is severed (never
-- reaches the main body, the coast or the map edge, stays in the box, and
-- borders at least one enemy and fallout, nothing else). Failed floods are
-- stamped so later starts skip them.
function PlayerExecution._severedTerritory(
	self: PlayerExecution,
	start: number,
	mainGen: number,
	seenGen: number,
	failGen: number,
	box: { number },
	boxOffset: number
): { number }?
	local map = self.map
	local me = self.player:smallID()
	local scratch = self.mg:traversalScratch()
	local visited = scratch.visited
	local stack = scratch.stack
	local minX, minY, maxX, maxY = box[boxOffset + 1], box[boxOffset + 2], box[boxOffset + 3], box[boxOffset + 4]
	table.clear(stack)
	local tiles = { start }
	buffer.writeu32(visited, start * 4, seenGen)
	table.insert(stack, start)
	local hasEnemy, hasFallout = false, false
	local function stampAll(gen: number): nil
		for _, t in tiles do
			buffer.writeu32(visited, t * 4, gen)
		end
		return nil
	end
	local nbuf = self.nbuf
	while #stack > 0 do
		local tile = table.remove(stack) :: number
		local x, y = map:x(tile), map:y(tile)
		if x < minX or x > maxX or y < minY or y > maxY or map:isShore(tile) or map:isOnEdgeOfMap(tile) then
			return stampAll(failGen)
		end
		local n4 = map:neighbors4(tile, nbuf)
		for i = 1, n4 do
			local n = nbuf[i]
			local ownerId = map:ownerID(n)
			if ownerId == me then
				local mark = buffer.readu32(visited, n * 4)
				if mark == mainGen then
					return stampAll(mainGen)
				elseif mark == failGen then
					return stampAll(failGen)
				elseif mark ~= seenGen then
					buffer.writeu32(visited, n * 4, seenGen)
					table.insert(tiles, n)
					table.insert(stack, n)
				end
			elseif ownerId ~= 0 then
				hasEnemy = true
			elseif map:hasFallout(n) then
				hasFallout = true
			else
				return stampAll(failGen)
			end
		end
	end
	return if hasEnemy and hasFallout then tiles else nil
end

-- Box helpers: boxes are a flat array of minX, minY, maxX, maxY per cluster
-- (0-based cluster i at [i*4+1 .. i*4+4]).

function PlayerExecution._removeClusters(self: PlayerExecution)
	local player = self.player
	local clusters, boxes = self:_calculateClusters()

	if #clusters == 0 then
		player.largestClusterBoundingBox = nil
		return
	end

	if #clusters == 1 then
		player.largestClusterBoundingBox = { minX = boxes[1], minY = boxes[2], maxX = boxes[3], maxY = boxes[4] }
		local surroundedBy = self:_surroundedBySamePlayer(clusters[1], boxes[1], boxes[2], boxes[3], boxes[4])
		local severedLand = self:_severedLand(clusters[1], boxes, 0, nil, nil)
		if surroundedBy and not surroundedBy:isFriendly(player) then
			self:_removeCluster(clusters[1])
		end
		if severedLand ~= nil then
			self:_annexSeveredClusters(severedLand.candidates, severedLand.mainTiles)
		end
		return
	end

	-- The cluster with the most border tiles starts the surrounded checks.
	local largestIndex = 1
	for i = 2, #clusters do
		if #clusters[i] > #clusters[largestIndex] then
			largestIndex = i
		end
	end

	local function box(i: number): (number, number, number, number)
		local o = (i - 1) * 4
		return boxes[o + 1], boxes[o + 2], boxes[o + 3], boxes[o + 4]
	end

	-- Doughnut borders: a crater (hole) inside the same territory must not be
	-- taken for the main body because its border is longer.
	local clusterTerritoryIds: { number }? = nil
	local nextTerritoryId = 1
	local scratch = self.mg:traversalScratch()

	local tMinX, tMinY, tMaxX, tMaxY = box(largestIndex)
	local isLargestHole = false
	for j = 1, #clusters do
		if j ~= largestIndex then
			local jMinX, jMinY, jMaxX, jMaxY = box(j)
			if jMinX <= tMinX and jMinY <= tMinY and jMaxX >= tMaxX and jMaxY >= tMaxY then
				if clusterTerritoryIds == nil then
					local ids = table.create(#clusters, 0)
					clusterTerritoryIds = ids
					for c = 1, #clusters do
						for _, t in clusters[c] do
							buffer.writei32(scratch.clusterIndexMap, t * 4, c)
						end
					end
				end
				local ids = clusterTerritoryIds :: { number }
				nextTerritoryId = self:_checkAndAssignTerritory(clusters, largestIndex, j, ids, nextTerritoryId)
				if ids[largestIndex] == ids[j] then
					isLargestHole = true
					break
				end
			end
		end
	end

	if isLargestHole then
		local ids = clusterTerritoryIds :: { number }
		local bestIndex = -1
		local bestLength = -1
		for i = 1, #clusters do
			if i ~= largestIndex and #clusters[i] > bestLength then
				local isHole = false
				local iMinX, iMinY, iMaxX, iMaxY = box(i)
				for j = 1, #clusters do
					if j ~= i then
						local jMinX, jMinY, jMaxX, jMaxY = box(j)
						if jMinX <= iMinX and jMinY <= iMinY and jMaxX >= iMaxX and jMaxY >= iMaxY then
							nextTerritoryId = self:_checkAndAssignTerritory(clusters, i, j, ids, nextTerritoryId)
							if ids[i] == ids[j] then
								isHole = true
								break
							end
						end
					end
				end
				if not isHole then
					bestLength = #clusters[i]
					bestIndex = i
				end
			end
		end
		if bestIndex ~= -1 then
			largestIndex = bestIndex
		end
	end

	if clusterTerritoryIds then
		for c = 1, #clusters do
			for _, t in clusters[c] do
				buffer.writei32(scratch.clusterIndexMap, t * 4, 0)
			end
		end
	end

	local largestCluster = clusters[largestIndex]
	local lMinX, lMinY, lMaxX, lMaxY = box(largestIndex)
	player.largestClusterBoundingBox = { minX = lMinX, minY = lMinY, maxX = lMaxX, maxY = lMaxY }

	local surroundedBy = self:_surroundedBySamePlayer(largestCluster, lMinX, lMinY, lMaxX, lMaxY)

	-- Classify the other clusters before any land changes hands.
	local classes = table.create(#clusters, 0)
	local severed: Candidates? = nil
	local open: Candidates? = nil
	for i = 1, #clusters do
		if i ~= largestIndex then
			local result = self:_classifyCluster(clusters[i], box(i))
			classes[i] = result
			if bit32.band(result, CLUSTER_SEVERED_CANDIDATE) ~= 0 then
				local list = severed or { clusters = {}, boxes = {} }
				severed = list
				table.insert(list.clusters, clusters[i])
				pushBox(list.boxes, boxes, (i - 1) * 4)
			end
			if bit32.band(result, CLUSTER_OPEN) ~= 0 then
				local list = open or { clusters = {}, boxes = {} }
				open = list
				table.insert(list.clusters, clusters[i])
				pushBox(list.boxes, boxes, (i - 1) * 4)
			end
		end
	end

	local severedLand = self:_severedLand(largestCluster, boxes, (largestIndex - 1) * 4, severed, open)

	if surroundedBy and not surroundedBy:isFriendly(player) then
		self:_removeCluster(largestCluster)
	end
	for i = 1, #clusters do
		if bit32.band(classes[i], CLUSTER_SURROUNDED) ~= 0 then
			self:_removeCluster(clusters[i])
		end
	end
	if severedLand ~= nil then
		self:_annexSeveredClusters(severedLand.candidates, severedLand.mainTiles)
	end
end

function PlayerExecution._checkAndAssignTerritory(
	self: PlayerExecution,
	clusters: { { number } },
	cIdxA: number,
	cIdxB: number,
	ids: { number },
	nextTerritoryId: number
): number
	if ids[cIdxA] ~= 0 and ids[cIdxA] == ids[cIdxB] then
		return nextTerritoryId
	end
	if ids[cIdxA] ~= 0 and ids[cIdxB] ~= 0 then
		return nextTerritoryId
	end
	local startIdx = if ids[cIdxB] == 0 then cIdxB else cIdxA
	local territoryId = nextTerritoryId
	nextTerritoryId += 1

	local mg = self.mg
	local scratch = mg:traversalScratch()
	local visited = scratch.visited
	local floodGen = mg:bumpTraversalGeneration()
	local stack = scratch.stack
	table.clear(stack)

	local start = clusters[startIdx][1]
	buffer.writeu32(visited, start * 4, floodGen)
	table.insert(stack, start)

	local map = self.map
	local myOwner = self.player:smallID()
	ids[startIdx] = territoryId
	local nbuf8 = self.nbuf8
	while #stack > 0 do
		local tile = table.remove(stack) :: number
		local n8 = map:neighbors8(tile, nbuf8)
		for k = 1, n8 do
			local n = nbuf8[k]
			if buffer.readu32(visited, n * 4) ~= floodGen and map:ownerID(n) == myOwner then
				buffer.writeu32(visited, n * 4, floodGen)
				table.insert(stack, n)
				local cIdx = buffer.readi32(scratch.clusterIndexMap, n * 4)
				if cIdx > 0 then
					ids[cIdx] = territoryId
				end
			end
		end
	end
	return nextTerritoryId
end

-- The single enemy that surrounds `cluster`, or nil.
function PlayerExecution._surroundedBySamePlayer(
	self: PlayerExecution,
	cluster: { number },
	boxMinX: number,
	boxMinY: number,
	boxMaxX: number,
	boxMaxY: number
): any?
	local enemy: number? = nil
	local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
	local map = self.map
	local me = self.player:smallID()
	local nbuf = self.nbuf
	for _, tile in cluster do
		if map:isOceanShore(tile) or map:isOnEdgeOfMap(tile) then
			return nil
		end
		local n4 = map:neighbors4(tile, nbuf)
		for i = 1, n4 do
			local n = nbuf[i]
			local ownerId = map:ownerID(n)
			if ownerId == 0 then
				return nil -- unowned neighbour: not fully surrounded
			end
			if ownerId ~= me then
				if enemy == nil then
					enemy = ownerId
				elseif enemy ~= ownerId then
					return nil -- a second enemy
				end
				local px, py = map:x(n), map:y(n)
				if px < minX then
					minX = px
				end
				if py < minY then
					minY = py
				end
				if px > maxX then
					maxX = px
				end
				if py > maxY then
					maxY = py
				end
			end
		end
		if enemy == nil then
			return nil -- enemies.size !== 1 after this tile
		end
	end
	if enemy == nil then
		return nil
	end
	if minX <= boxMinX and minY <= boxMinY and maxX >= boxMaxX and maxY >= boxMaxY then
		return self.mg:playerBySmallID(enemy)
	end
	return nil
end

function PlayerExecution._classifyCluster(
	self: PlayerExecution,
	cluster: { number },
	boxMinX: number,
	boxMinY: number,
	boxMaxX: number,
	boxMaxY: number
): number
	local hasEnemy, hasFallout, hasOpenLand = false, false, false
	local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
	local map = self.map
	local me = self.player:smallID()
	local nbuf = self.nbuf
	for _, tr in cluster do
		if map:isShore(tr) or map:isOnEdgeOfMap(tr) then
			return CLUSTER_OPEN
		end
		local n4 = map:neighbors4(tr, nbuf)
		for i = 1, n4 do
			local n = nbuf[i]
			local ownerId = map:ownerID(n)
			if ownerId ~= 0 and ownerId ~= me then
				hasEnemy = true
				local x, y = map:x(n), map:y(n)
				if x < minX then
					minX = x
				end
				if y < minY then
					minY = y
				end
				if x > maxX then
					maxX = x
				end
				if y > maxY then
					maxY = y
				end
			elseif ownerId == 0 then
				if map:hasFallout(n) then
					hasFallout = true
				else
					hasOpenLand = true
				end
			end
		end
	end
	if not hasEnemy then
		return if hasOpenLand then CLUSTER_OPEN else 0
	end
	local result = if hasOpenLand then CLUSTER_OPEN else 0
	if minX <= boxMinX and minY <= boxMinY and maxX >= boxMaxX and maxY >= boxMaxY then
		result = bit32.bor(result, CLUSTER_SURROUNDED)
	end
	if hasFallout and not hasOpenLand then
		result = bit32.bor(result, CLUSTER_SEVERED_CANDIDATE)
	end
	return result
end

-- Whether `tiles` hold one of the player's landing zones still in its hold
-- time (ParatroopersExecution.HOLD); drops expired ones.
function PlayerExecution._heldByDrop(self: PlayerExecution, tiles: { number }): boolean
	local zones = (self.player :: any).paraZones :: { { tile: number, untilTick: number } }
	local now = self.mg:ticks()
	for i = #zones, 1, -1 do
		if zones[i].untilTick < now then
			table.remove(zones, i)
		end
	end
	if #zones == 0 then
		return false
	end
	for _, t in tiles do
		for _, zone in zones do
			if zone.tile == t then
				return true
			end
		end
	end
	return false
end

function PlayerExecution._removeCluster(self: PlayerExecution, cluster: { number })
	local mg, player = self.mg, self.player
	for _, t in cluster do
		-- Other removals can change owners, so double check.
		if mg:map():ownerID(t) ~= player:smallID() then
			return
		end
	end
	local capturing = self:_getCapturingPlayer(cluster)
	if capturing == nil then
		return
	end
	local firstTile = cluster[1]
	if firstTile == nil then
		return
	end
	-- The checks above looked at this cluster of border tiles only; the fill
	-- below hands over the whole territory. Verify it is sealed in.
	if not self:_isEnclosed(firstTile) then
		return
	end
	local me = player:smallID()
	local map = self.map
	local tiles = self:_floodFillWithGen(mg:bumpTraversalGeneration(), { firstTile }, false, function(tile: number): boolean
		return map:ownerID(tile) == me
	end)
	-- Conquest's Paratroopers (not OpenFront; ARSENAL_V2): a fresh landing
	-- zone holds out for a while though enemy land surrounds it. No zones
	-- exist without the Arsenal, so OpenFront's rule is unchanged there.
	if (player :: any).paraZones ~= nil and self:_heldByDrop(tiles) then
		return
	end
	if player:numTilesOwned() == #tiles then
		mg:conquerPlayer(capturing, player)
	end
	for _, tile in tiles do
		capturing:conquer(tile)
	end
end

-- Walking from `start` through our own tiles and unclaimed land never
-- reaches water or the map edge.
function PlayerExecution._isEnclosed(self: PlayerExecution, start: number): boolean
	local map = self.map
	local me = self.player:smallID()
	local mg = self.mg
	local scratch = mg:traversalScratch()
	local gen = mg:bumpTraversalGeneration()
	local visited = scratch.visited
	local stack = scratch.stack
	table.clear(stack)
	buffer.writeu32(visited, start * 4, gen)
	table.insert(stack, start)
	local nbuf = self.nbuf
	while #stack > 0 do
		local tile = table.remove(stack) :: number
		if map:isOnEdgeOfMap(tile) then
			return false
		end
		local n4 = map:neighbors4(tile, nbuf)
		for i = 1, n4 do
			local n = nbuf[i]
			if buffer.readu32(visited, n * 4) ~= gen then
				local ownerId = map:ownerID(n)
				if ownerId == 0 or ownerId == me then
					if ownerId == 0 and not map:isLand(n) then
						return false -- open water is a way out
					end
					buffer.writeu32(visited, n * 4, gen)
					table.insert(stack, n)
				end
			end
		end
	end
	return true
end

-- The neighbour with the biggest attack on us, else the one with the most
-- border contact (first in insertion order on a tie, like getMode).
function PlayerExecution._getCapturingPlayer(self: PlayerExecution, cluster: { number }): any?
	local map, mg, player = self.map, self.mg, self.player
	local me = player:smallID()
	local order: { any } = {}
	local counts: { [any]: number } = {}
	local nbuf = self.nbuf
	for _, t in cluster do
		local n4 = map:neighbors4(t, nbuf)
		for i = 1, n4 do
			local ownerId = map:ownerID(nbuf[i])
			if ownerId ~= 0 and ownerId ~= me then
				local owner = mg:playerBySmallID(ownerId)
				if not owner:isFriendly(player) then
					if counts[owner] == nil then
						counts[owner] = 0
						table.insert(order, owner)
					end
					counts[owner] += 1
				end
			end
		end
	end
	if #order == 0 then
		return nil
	end
	local largestNeighborAttack = nil
	local largestTroopCount = 0
	for _, neighbor in order do
		for _, attack in neighbor:outgoingAttacks() do
			if attack:target() == player and attack:troops() > largestTroopCount then
				largestTroopCount = attack:troops()
				largestNeighborAttack = neighbor
			end
		end
	end
	if largestNeighborAttack ~= nil then
		return largestNeighborAttack
	end
	-- Util.ts getMode
	local mode, maxCount = nil, 0
	for _, neighbor in order do
		if counts[neighbor] > maxCount then
			maxCount = counts[neighbor]
			mode = neighbor
		end
	end
	return mode
end

-- Border tiles grouped into 8-connected clusters, in border-set order, with
-- each cluster's bounding box.
function PlayerExecution._calculateClusters(self: PlayerExecution): ({ { number } }, { number })
	local borderTiles = self.player:borderTiles()
	if borderTiles:size() == 0 then
		return {}, {}
	end
	local mg = self.mg
	local scratch = mg:traversalScratch()
	local visited = scratch.visited
	-- Two stamps: border tiles get borderGen, the flood marks currentGen.
	local borderGen = self:_bumpGenerations(2)
	local currentGen = borderGen + 1
	local tiles = borderTiles:values()
	for _, tile in tiles do
		buffer.writeu32(visited, tile * 4, borderGen)
	end
	local clusters: { { number } } = {}
	local boxes: { number } = {}
	local function includeFn(tile: number): boolean
		return buffer.readu32(visited, tile * 4) == borderGen
	end
	for _, startTile in tiles do
		if buffer.readu32(visited, startTile * 4) ~= currentGen then
			local cluster, minX, minY, maxX, maxY = self:_floodFillWithGen(currentGen, { startTile }, true, includeFn)
			table.insert(clusters, cluster)
			table.insert(boxes, minX)
			table.insert(boxes, minY)
			table.insert(boxes, maxX)
			table.insert(boxes, maxY)
		end
	end
	return clusters, boxes
end

-- Starts `count` passes at once and returns the first generation.
function PlayerExecution._bumpGenerations(self: PlayerExecution, count: number): number
	local first = self.mg:bumpTraversalGeneration()
	local last = first
	for _ = 2, count do
		last = self.mg:bumpTraversalGeneration()
	end
	return if last - first == count - 1 then first else self:_bumpGenerations(count)
end

-- Depth-first flood from `startTiles`; returns tiles in mark order and the
-- bounding box.
function PlayerExecution._floodFillWithGen(
	self: PlayerExecution,
	currentGen: number,
	startTiles: { number },
	diag: boolean,
	includeFn: (number) -> boolean
): ({ number }, number, number, number, number)
	local mg = self.mg
	local scratch = mg:traversalScratch()
	local visited = scratch.visited
	local result = {}
	local stack = scratch.stack
	table.clear(stack)
	local minX, minY, maxX, maxY = 1e9, 1e9, -1e9, -1e9
	local map = self.map
	local function mark(t: number)
		buffer.writeu32(visited, t * 4, currentGen)
		table.insert(result, t)
		table.insert(stack, t)
		local x, y = map:x(t), map:y(t)
		if x < minX then
			minX = x
		end
		if y < minY then
			minY = y
		end
		if x > maxX then
			maxX = x
		end
		if y > maxY then
			maxY = y
		end
	end
	for _, start in startTiles do
		if buffer.readu32(visited, start * 4) ~= currentGen and includeFn(start) then
			mark(start)
		end
	end
	local nbuf = if diag then self.nbuf8 else self.nbuf
	while #stack > 0 do
		local tile = table.remove(stack) :: number
		local count = if diag then map:neighbors8(tile, nbuf) else map:neighbors4(tile, nbuf)
		for i = 1, count do
			local neighbor = nbuf[i]
			if buffer.readu32(visited, neighbor * 4) ~= currentGen and includeFn(neighbor) then
				mark(neighbor)
			end
		end
	end
	return result, minX, minY, maxX, maxY
end

-- No tiles left: delete gold, non-nuke units and alliances.
function PlayerExecution._removeOnDeath(self: PlayerExecution)
	local player = self.player
	player:removeGold(player:gold())
	local units: { any } = table.clone(player:units())
	for _, u in units do
		local t = u:type()
		if t ~= UnitType.AtomBomb and t ~= UnitType.HydrogenBomb and t ~= UnitType.MIRVWarhead and t ~= UnitType.MIRV and t ~= UnitType.MegaNuke and t ~= UnitType.Scattershot then
			u:delete()
		end
	end
	player:removeAllAlliances()
end

function PlayerExecution.owner(self: PlayerExecution): any
	return self.player
end

function PlayerExecution.isActive(self: PlayerExecution): boolean
	return self.active
end

return PlayerExecution
