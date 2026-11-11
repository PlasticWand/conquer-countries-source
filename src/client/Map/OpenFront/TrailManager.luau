--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/frame/TrailManager.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Sparse storage replaces the two full-map u16 arrays; claim/stamp order is unchanged.
local Trails = {}
Trails.__index = Trails
local Visual = require(script.Parent.UnitVisuals)

function Trails.new(width: number, height: number): any
	return setmetatable({width = width, height = height, values = {}, counts = {}, units = {}, changed = {}}, Trails)
end

-- Original: stamp / claim. Crossings retain the last stamped value until all claimants die.
local function stamp(self: any, tile: number, value: number)
	if self.values[tile] ~= (if value == 0 then nil else value) then
		self.values[tile] = if value == 0 then nil else value
		self.changed[tile] = true
	end
end
local function claim(self: any, tile: number, trail: any)
	if not trail.tiles[tile] then
		trail.tiles[tile] = true
		self.counts[tile] = ((self.counts[tile] or 0) + 1) % 65536
	end
	stamp(self, tile, trail.value)
end

-- Original: bresenham, including both endpoints and its diagonal tie rules.
local function connect(self: any, from: number, to: number, trail: any)
	local w = self.width
	local x, y, tx, ty = from % w, math.floor(from / w), to % w, math.floor(to / w)
	local dx, dy = math.abs(tx - x), -math.abs(ty - y)
	local sx, sy = if x < tx then 1 else -1, if y < ty then 1 else -1
	local err = dx + dy
	while true do
		claim(self, y * w + x, trail)
		if x == tx and y == ty then break end
		local twice = 2 * err
		if twice >= dy then err += dy; x += sx end
		if twice <= dx then err += dx; y += sy end
	end
end

-- Original: update / clearDeadUnits. Ordered IDs preserve JS Map stamp precedence.
function Trails.update(self: any, units: {[number]: any}, order: {number}, moved: {[number]: boolean}?): {number}
	table.clear(self.changed)
	for id, trail in self.units do
		local unit = units[id]
		if not unit or unit.active == false then
			self.units[id] = nil
			for tile in trail.tiles do
				local count = ((self.counts[tile] or 0) - 1) % 65536
				self.counts[tile] = if count == 0 then nil else count
				if count == 0 then stamp(self, tile, 0) end
			end
		end
	end
	for _, id in order do
		local unit = units[id]
		if unit and unit.active ~= false and (unit.type == 'Transport' or Visual.isNuke(unit.type)) then
			local nuke = Visual.isNuke(unit.type)
			local head = if nuke then (unit.lastTile or unit.tile) else unit.tile
			-- ClientState currently leaves lastTile stale on plan-rest ticks.
			-- Source GameView resets lastPos=pos then; use the confirmed move
			-- notification to normalize that boundary without changing state.
			if nuke and moved ~= nil and not moved[id] then head=unit.tile end
			if head == nil or head < 0 or head >= self.width * self.height then continue end
			local trail = self.units[id]
			if not trail then
				trail = {value = bit32.bor(unit.owner, if nuke then 4096 else 0), tiles = {}, last = -1}
				self.units[id] = trail
			end
			if trail.last == -1 then claim(self, head, trail)
			elseif trail.last ~= head then connect(self, trail.last, head, trail) end
			trail.last = head
		end
	end
	local changed = {}; for tile in self.changed do table.insert(changed, tile) end
	table.sort(changed)
	return changed
end

function Trails.reset(self: any)
	table.clear(self.values); table.clear(self.counts); table.clear(self.units); table.clear(self.changed)
end
return Trails
