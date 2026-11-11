--!strict
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/NameBoxCalculator.ts; packages/engine-lib/src/Util.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
local Js = require(script.Parent.JsMath)
export type Point = {x: number, y: number}
export type Bounds = {min: Point, max: Point}
export type Rectangle = {x: number, y: number, width: number, height: number}
export type Name = {x: number, y: number, size: number}
-- This adapter is intentionally independent of ClientMatchState. All tile
-- indices stay zero based; the grid is column-major, as in the source.
export type Map = {width: number, height: number, isShore: (number) -> boolean,
	isOcean: (number) -> boolean, magnitude: (number) -> number,
	owner: (number) -> number, hasFallout: (number) -> boolean}
export type Player = {id: number, name: string, spawnTile: number?,
	largestClusterBoundingBox: Bounds?, borderTiles: {number}}
local NameBox = {}

-- Original: NameBoxCalculator.calculateFontSize.
function NameBox.calculateFontSize(rectangle: Rectangle, name: string): number
	return math.min(rectangle.width / #Js.utf16(name) * 2, rectangle.height / 3)
end

-- Original: NameBoxCalculator.largestRectangleInHistogram. Strict area
-- comparisons and source stack order preserve equal-area tie breaking.
function NameBox.largestRectangleInHistogram(heights: {number}): Rectangle
	local stack: {number} = {}
	local maximum = 0
	local rectangle: Rectangle = {x = 0, y = 0, width = 0, height = 0}
	for step = 1, #heights + 1 do
		local i = step - 1
		local h = if i == #heights then 0 else heights[i + 1]
		while #stack > 0 and h < heights[stack[#stack] + 1] do
			local top = table.remove(stack) :: number
			local height = heights[top + 1]
			local width = if #stack == 0 then i else i - stack[#stack] - 1
			if height * width > maximum then
				maximum = height * width
				rectangle = {x = if #stack == 0 then 0 else stack[#stack] + 1, y = 0, width = width, height = height}
			end
		end
		table.insert(stack, i)
	end
	return rectangle
end

-- Original: NameBoxCalculator.findLargestInscribedRectangle.
function NameBox.findLargestInscribedRectangle(grid: {{boolean}}): Rectangle
	local rows, columns = #grid[1], #grid
	local heights = table.create(columns, 0)
	local rectangle: Rectangle = {x = 0, y = 0, width = 0, height = 0}
	for row = 1, rows do
		for col = 1, columns do heights[col] = if grid[col][row] then heights[col] + 1 else 0 end
		local candidate = NameBox.largestRectangleInHistogram(heights)
		if candidate.width * candidate.height > rectangle.width * rectangle.height then
			rectangle = {x = candidate.x, y = row - candidate.height, width = candidate.width, height = candidate.height}
		end
	end
	return rectangle
end

-- Original: NameBoxCalculator.placeName sampling-factor branch.
function NameBox.scalingFactor(bounds: Bounds): number
	local size = math.min(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y)
	if size < 25 then return 1 elseif size < 50 then return 2 elseif size < 100 then return 4
	elseif size < 250 then return 8 elseif size < 500 then return 16 else return 32 end
end

-- Original: NameBoxCalculator.createGrid. Shores, shallow ocean and fallout
-- are accepted even when not owned; do not replace this with a land mask.
function NameBox.createGrid(map: Map, player: number, bounds: Bounds, scale: number): {{boolean}}
	local x0, y0 = math.floor(bounds.min.x / scale), math.floor(bounds.min.y / scale)
	local x1, y1 = math.floor(bounds.max.x / scale), math.floor(bounds.max.y / scale)
	local grid: {{boolean}} = {}
	for x = x0, x1 do
		local column = table.create(y1 - y0 + 1, false)
		for y = y0, y1 do
			local xx, yy = x * scale, y * scale
			if xx >= 0 and yy >= 0 and xx < map.width and yy < map.height then
				local tile = yy * map.width + xx
				column[y - y0 + 1] = map.isShore(tile) or (map.isOcean(tile) and map.magnitude(tile) < 10)
					or map.owner(tile) == player or map.hasFallout(tile)
			end
		end
		table.insert(grid, column)
	end
	return grid
end

-- Original: Util.calculateBoundingBox, including the empty-set infinities.
local function calculateBoundingBox(map: Map, tiles: {number}): Bounds
	local bounds: Bounds = {min = {x = math.huge, y = math.huge}, max = {x = -math.huge, y = -math.huge}}
	for _, tile in tiles do
		local x, y = tile % map.width, math.floor(tile / map.width)
		bounds.min.x, bounds.min.y = math.min(bounds.min.x, x), math.min(bounds.min.y, y)
		bounds.max.x, bounds.max.y = math.max(bounds.max.x, x), math.max(bounds.max.y, y)
	end
	return bounds
end

-- Original: NameBoxCalculator.placeName. Bounds and tile callbacks come from
-- the confirmed adapter; no gameplay state is mutated here.
function NameBox.placeName(map: Map, player: Player): Name
	local bounds = player.largestClusterBoundingBox or calculateBoundingBox(map, player.borderTiles)
	local scale = NameBox.scalingFactor(bounds)
	local rectangle = NameBox.findLargestInscribedRectangle(NameBox.createGrid(map, player.id, bounds, scale))
	rectangle.x *= scale; rectangle.y *= scale; rectangle.width *= scale; rectangle.height *= scale
	local x = math.floor(rectangle.x + rectangle.width / 2 + bounds.min.x)
	local y = math.floor(rectangle.y + rectangle.height / 2 + bounds.min.y)
	local size = NameBox.calculateFontSize(rectangle, player.name)
	return {x = math.ceil(x), y = math.ceil(y - size / 3), size = size}
end

-- Original: NameBoxCalculator.placeSpawnName (diameter 8).
function NameBox.placeSpawnName(map: Map, player: Player): Name
	local tile = player.spawnTile
	if tile == nil then return {x = 0, y = 0, size = 0} end
	local size = NameBox.calculateFontSize({x = 0, y = 0, width = 8, height = 8}, player.name)
	return {x = math.ceil(tile % map.width), y = math.ceil(math.floor(tile / map.width) - size / 3), size = size}
end

return NameBox
