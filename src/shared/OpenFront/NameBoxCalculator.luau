--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/NameBoxCalculator.ts and GameRunner.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Where each player's name sits on the map and how big it is, computed on
-- the server exactly as OpenFront's GameRunner does each tick:
--   - spawn phase: humans and nations with a spawn tile, sized to the spawn
--     region
--   - otherwise the largest rectangle inside the player's largest cluster
--     (own land, shore, shallow water, fallout), on a grid coarsened for big
--     players; refreshed when the spawn phase ends, on the first 3 ticks
--     and every 30 ticks
-- Anchors are { x, y, size } in tile units (size is the source font size).
-- OpenFront runs this in every client's worker; here the server runs it for
-- everyone, so the Tracker can spread a full recompute over the following
-- ticks within a time budget (exact, synchronous, when no budget is given;
-- the parity tests use that).

local GameTypes = require(script.Parent.GameTypes)

local PlayerType = GameTypes.PlayerType

export type Anchor = { x: number, y: number, size: number }
type Rect = { x: number, y: number, width: number, height: number }
type Box = { min: { x: number, y: number }, max: { x: number, y: number } }

local NameBoxCalculator = {}

-- Spawn region diameter (SpawnExecution's euclidean radius 4).
local SPAWN_REGION_DIAMETER = 8

-- JS string length: UTF-16 code units.
local function jsLength(s: string): number
	local n = 0
	for _, c in utf8.codes(s) do
		n += if c > 0xFFFF then 2 else 1
	end
	return n
end

function NameBoxCalculator.calculateFontSize(rect: Rect, name: string): number
	local widthConstrained = (rect.width / jsLength(name)) * 2
	local heightConstrained = rect.height / 3
	return math.min(widthConstrained, heightConstrained)
end

function NameBoxCalculator.largestRectangleInHistogram(widths: { number }): Rect
	local stack: { number } = {}
	local maxArea = 0
	local largest: Rect = { x = 0, y = 0, width = 0, height = 0 }
	local n = #widths
	-- i is 0-based, as in the source
	for i = 0, n do
		local h = if i == n then 0 else widths[i + 1]
		while #stack > 0 and h < widths[stack[#stack] + 1] do
			local height = widths[(table.remove(stack) :: number) + 1]
			local width = if #stack == 0 then i else i - stack[#stack] - 1
			if height * width > maxArea then
				maxArea = height * width
				largest = { x = if #stack == 0 then 0 else stack[#stack] + 1, y = 0, width = width, height = height }
			end
		end
		table.insert(stack, i)
	end
	return largest
end

-- grid[col][row], 1-based in Luau, columns are x.
function NameBoxCalculator.findLargestInscribedRectangle(grid: { { boolean } }): Rect
	local cols = #grid
	local rows = #grid[1]
	local heights = table.create(cols, 0)
	local largest: Rect = { x = 0, y = 0, width = 0, height = 0 }
	for row = 0, rows - 1 do
		for col = 1, cols do
			if grid[col][row + 1] then
				heights[col] += 1
			else
				heights[col] = 0
			end
		end
		local r = NameBoxCalculator.largestRectangleInHistogram(heights)
		if r.width * r.height > largest.width * largest.height then
			largest = { x = r.x, y = row - r.height + 1, width = r.width, height = r.height }
		end
	end
	return largest
end

function NameBoxCalculator.createGrid(game: any, player: any, box: Box, scalingFactor: number): { { boolean } }
	local minX, minY = math.floor(box.min.x / scalingFactor), math.floor(box.min.y / scalingFactor)
	local maxX, maxY = math.floor(box.max.x / scalingFactor), math.floor(box.max.y / scalingFactor)
	-- Straight on the map, own land first: the same `or` of booleans as the
	-- source, in the order that's cheapest here (this runs for every player).
	local map = game:map()
	local mine = player:smallID()
	local width, height = map:width(), map:height()
	local grid: { { boolean } } = {}
	for x = minX, maxX do
		local column = table.create(maxY - minY + 1, false)
		local cx = x * scalingFactor
		if cx >= 0 and cx < width then
			for y = minY, maxY do
				local cy = y * scalingFactor
				if cy >= 0 and cy < height then
					local tile = cy * width + cx
					column[y - minY + 1] = map:ownerID(tile) == mine
						or map:isShore(tile)
						or (map:isOcean(tile) and map:magnitude(tile) < 10)
						or map:hasFallout(tile)
				end
			end
		end
		table.insert(grid, column)
	end
	return grid
end

-- Util.ts calculateBoundingBox over the border tiles.
local function borderBox(game: any, player: any): Box
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	player:borderTiles():forEach(function(tile: number)
		local x, y = game:x(tile), game:y(tile)
		minX, minY = math.min(minX, x), math.min(minY, y)
		maxX, maxY = math.max(maxX, x), math.max(maxY, y)
	end)
	return { min = { x = minX, y = minY }, max = { x = maxX, y = maxY } }
end

function NameBoxCalculator.placeSpawnName(game: any, player: any): Anchor
	local spawnTile = player:spawnTile()
	if spawnTile == nil then
		return { x = 0, y = 0, size = 0 }
	end
	local fontSize = NameBoxCalculator.calculateFontSize(
		{ x = 0, y = 0, width = SPAWN_REGION_DIAMETER, height = SPAWN_REGION_DIAMETER },
		player:displayName()
	)
	return { x = math.ceil(game:x(spawnTile)), y = math.ceil(game:y(spawnTile) - fontSize / 3), size = fontSize }
end

function NameBoxCalculator.placeName(game: any, player: any): Anchor
	local c = player.largestClusterBoundingBox
	local box: Box = if c then { min = { x = c.minX, y = c.minY }, max = { x = c.maxX, y = c.maxY } } else borderBox(game, player)
	local size = math.min(box.max.x - box.min.x, box.max.y - box.min.y)
	local scalingFactor = if size < 25
		then 1
		elseif size < 50 then 2
		elseif size < 100 then 4
		elseif size < 250 then 8
		elseif size < 500 then 16
		else 32
	local r = NameBoxCalculator.findLargestInscribedRectangle(NameBoxCalculator.createGrid(game, player, box, scalingFactor))
	local rect = { x = r.x * scalingFactor, y = r.y * scalingFactor, width = r.width * scalingFactor, height = r.height * scalingFactor }
	local cx = math.floor(rect.x + rect.width / 2 + box.min.x)
	local cy = math.floor(rect.y + rect.height / 2 + box.min.y)
	local fontSize = NameBoxCalculator.calculateFontSize(rect, player:displayName())
	return { x = math.ceil(cx), y = math.ceil(cy - fontSize / 3), size = fontSize }
end

-- GameRunner's per-tick bookkeeping: holds every player's anchor (by id).
local Tracker = {}
Tracker.__index = Tracker
NameBoxCalculator.Tracker = Tracker

export type Tracker = typeof(setmetatable(
	{} :: {
		anchors: { [string]: Anchor },
		stale: boolean,
		budgetMs: number?,
		clock: () -> number,
		pending: { any },
		pendingAt: number,
		again: boolean,
	},
	Tracker
))

-- budgetMs: spend at most this long per tick on full placements (nil: all at
-- once, exactly on GameRunner's ticks). clock: seconds (os.clock by default).
function NameBoxCalculator.newTracker(budgetMs: number?, clock: (() -> number)?): Tracker
	return setmetatable(
		{ anchors = {}, stale = true, budgetMs = budgetMs, clock = clock or os.clock, pending = {}, pendingAt = 1, again = false },
		Tracker
	)
end

-- Call after each tick with whether the game was in the spawn phase before
-- it. Returns true if any anchor was recomputed (GameRunner's
-- viewDataChanged).
function Tracker.update(self: Tracker, game: any, wasInSpawnPhase: boolean): boolean
	local changed = false
	if game:inSpawnPhase() then
		for _, p in game:players() do
			local t = p:type()
			if (t == PlayerType.Human or t == PlayerType.Nation) and p:spawnTile() ~= nil then
				self.anchors[p:id()] = NameBoxCalculator.placeSpawnName(game, p)
				changed = true
			end
		end
	end
	local spawnJustEnded = wasInSpawnPhase and not game:inSpawnPhase()
	local ticks = game:ticks()
	if spawnJustEnded or self.stale or ticks < 3 or ticks % 30 == 0 then
		self.stale = false
		if self.budgetMs == nil then
			for _, p in game:players() do
				self.anchors[p:id()] = NameBoxCalculator.placeName(game, p)
			end
			return true
		end
		-- A pass still running finishes first; the next starts right after.
		if self.pendingAt > #self.pending then
			self.pending = game:players()
			self.pendingAt = 1
		else
			self.again = true
		end
	end
	if self.pendingAt > #self.pending and self.again then
		self.again = false
		self.pending = game:players()
		self.pendingAt = 1
	end
	if #self.pending >= self.pendingAt then
		local deadline = self.clock() + (self.budgetMs :: number) / 1000
		repeat
			local p = self.pending[self.pendingAt]
			self.pendingAt += 1
			if p:isAlive() then
				self.anchors[p:id()] = NameBoxCalculator.placeName(game, p)
			end
			changed = true
		until self.pendingAt > #self.pending or self.clock() >= deadline
	end
	return changed
end

return NameBoxCalculator
