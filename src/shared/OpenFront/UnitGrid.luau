--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/game/UnitGrid.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Units bucketed in 100×100-tile cells for proximity queries.
--   - Each cell keeps one insertion-ordered set per unit type (JS Set
--     semantics: deleting then re-adding moves a unit to the end).
--   - Results come cell by cell (rows, then columns), then by type, then in
--     set order. Callers that take "the first" match depend on that.

local CELL_SIZE = 100

local UnitGrid = {}
UnitGrid.__index = UnitGrid

-- An insertion-ordered set of units.
type OrderedSet = { list: { any }, index: { [any]: number } }

local function setAdd(set: OrderedSet, unit: any)
	if set.index[unit] == nil then
		table.insert(set.list, unit)
		set.index[unit] = #set.list
	end
end

local function setDelete(set: OrderedSet, unit: any)
	local i = set.index[unit]
	if i ~= nil then
		table.remove(set.list, i)
		set.index[unit] = nil
		for k = i, #set.list do
			set.index[set.list[k]] = k
		end
	end
end

export type UnitGrid = typeof(setmetatable(
	{} :: {
		gm: any,
		cols: number,
		rows: number,
		-- cell key (row * cols + col) -> { types in first-seen order, sets }
		cells: { [number]: { order: { string }, sets: { [string]: OrderedSet } } },
	},
	UnitGrid
))

function UnitGrid.new(gm: any): UnitGrid
	return setmetatable({
		gm = gm,
		cols = math.ceil(gm:width() / CELL_SIZE),
		rows = math.ceil(gm:height() / CELL_SIZE),
		cells = {},
	}, UnitGrid)
end

function UnitGrid._cell(self: UnitGrid, gx: number, gy: number): { order: { string }, sets: { [string]: OrderedSet } }
	local key = gy * self.cols + gx
	local cell = self.cells[key]
	if cell == nil then
		cell = { order = {}, sets = {} }
		self.cells[key] = cell
	end
	return cell
end

function UnitGrid._valid(self: UnitGrid, gx: number, gy: number): boolean
	return gx >= 0 and gx < self.cols and gy >= 0 and gy < self.rows
end

function UnitGrid.addUnit(self: UnitGrid, unit: any)
	local tile = unit:tile()
	local gx, gy = self.gm:x(tile) // CELL_SIZE, self.gm:y(tile) // CELL_SIZE
	if self:_valid(gx, gy) then
		local cell = self:_cell(gx, gy)
		local set = cell.sets[unit:type()]
		if set == nil then
			set = { list = {}, index = {} }
			cell.sets[unit:type()] = set
			table.insert(cell.order, unit:type())
		end
		setAdd(set, unit)
	end
end

function UnitGrid.removeUnitByTile(self: UnitGrid, unit: any, tile: number)
	local gx, gy = self.gm:x(tile) // CELL_SIZE, self.gm:y(tile) // CELL_SIZE
	if self:_valid(gx, gy) then
		local cell = self.cells[gy * self.cols + gx]
		local set = cell and cell.sets[unit:type()]
		if set then
			setDelete(set, unit)
		end
	end
end

function UnitGrid.removeUnit(self: UnitGrid, unit: any)
	self:removeUnitByTile(unit, unit:tile())
end

-- Moves a unit to its new cell if it changed.
function UnitGrid.updateUnitCell(self: UnitGrid, unit: any)
	local newTile, oldTile = unit:tile(), unit:lastTile()
	if newTile == oldTile then
		return
	end
	local gm = self.gm
	if gm:x(oldTile) // CELL_SIZE ~= gm:x(newTile) // CELL_SIZE or gm:y(oldTile) // CELL_SIZE ~= gm:y(newTile) // CELL_SIZE then
		self:removeUnitByTile(unit, oldTile)
		self:addUnit(unit)
	end
end

function UnitGrid._cellsInRange(self: UnitGrid, tile: number, range: number): (number, number, number, number)
	local x, y = self.gm:x(tile), self.gm:y(tile)
	local gx, gy = x // CELL_SIZE, y // CELL_SIZE
	local startX = math.max(0, gx - math.ceil((range - (x % CELL_SIZE)) / CELL_SIZE))
	local endX = math.min(self.cols - 1, gx + math.ceil((range - (CELL_SIZE - (x % CELL_SIZE))) / CELL_SIZE))
	local startY = math.max(0, gy - math.ceil((range - (y % CELL_SIZE)) / CELL_SIZE))
	local endY = math.min(self.rows - 1, gy + math.ceil((range - (CELL_SIZE - (y % CELL_SIZE))) / CELL_SIZE))
	return startX, endX, startY, endY
end

export type Nearby = { unit: any, distSquared: number }

-- Units of `types` (a type or list) within Euclidean range, in grid order.
-- With a list, types are visited in the list's order within each cell.
function UnitGrid.nearbyUnits(
	self: UnitGrid,
	tile: number,
	searchRange: number,
	types: string | { string },
	predicate: ((Nearby) -> boolean)?,
	includeUnderConstruction: boolean?
): { Nearby }
	local out = {}
	local gm = self.gm
	local x, y = gm:x(tile), gm:y(tile)
	local sx, ex, sy, ey = self:_cellsInRange(tile, searchRange)
	local r2 = searchRange * searchRange
	local typeList: { string } = if type(types) == "string" then { types } else types :: { string }
	for cy = sy, ey do
		for cx = sx, ex do
			local cell = self.cells[cy * self.cols + cx]
			if cell then
				for _, t in typeList do
					local set = cell.sets[t]
					if set then
						for _, unit in set.list do
							if unit:isActive() and (includeUnderConstruction or not unit:isUnderConstruction()) then
								local ut = unit:tile()
								local dx, dy = gm:x(ut) - x, gm:y(ut) - y
								local d2 = dx * dx + dy * dy
								if d2 <= r2 then
									local value = { unit = unit, distSquared = d2 }
									if predicate == nil or predicate(value) then
										table.insert(out, value)
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return out
end

local function inRange(gm: any, unit: any, tile: number, r2: number, playerId: string?, includeUC: boolean?): boolean
	if not unit:isActive() then
		return false
	end
	if not includeUC and unit:isUnderConstruction() then
		return false
	end
	if playerId ~= nil and unit:owner():id() ~= playerId then
		return false
	end
	local ut = unit:tile()
	local dx, dy = gm:x(ut) - gm:x(tile), gm:y(ut) - gm:y(tile)
	return dx * dx + dy * dy <= r2
end

function UnitGrid.hasUnitNearby(self: UnitGrid, tile: number, searchRange: number, unitType: string, playerId: string?, includeUnderConstruction: boolean?): boolean
	local sx, ex, sy, ey = self:_cellsInRange(tile, searchRange)
	local r2 = searchRange * searchRange
	for cy = sy, ey do
		for cx = sx, ex do
			local cell = self.cells[cy * self.cols + cx]
			local set = cell and cell.sets[unitType]
			if set then
				for _, unit in set.list do
					if inRange(self.gm, unit, tile, r2, playerId, includeUnderConstruction) then
						return true
					end
				end
			end
		end
	end
	return false
end

function UnitGrid.anyUnitNearby(
	self: UnitGrid,
	tile: number,
	searchRange: number,
	types: { string },
	predicate: (any) -> boolean,
	playerId: string?,
	includeUnderConstruction: boolean?
): boolean
	local sx, ex, sy, ey = self:_cellsInRange(tile, searchRange)
	local r2 = searchRange * searchRange
	for cy = sy, ey do
		for cx = sx, ex do
			local cell = self.cells[cy * self.cols + cx]
			if cell then
				for _, t in types do
					local set = cell.sets[t]
					if set then
						for _, unit in set.list do
							if inRange(self.gm, unit, tile, r2, playerId, includeUnderConstruction) and predicate(unit) then
								return true
							end
						end
					end
				end
			end
		end
	end
	return false
end

return UnitGrid
