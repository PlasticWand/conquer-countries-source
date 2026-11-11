--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/pathfinding/algorithms/ConnectedComponents.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Labels connected water regions with a scan-line flood fill, so a path
-- query between two different bodies of water can fail fast.
--   - Labels are byte-sized until 253 components, then 16-bit, with the land
--     marker 0xFF / 0xFFFF as in the original.
--   - The fill queue holds one entry per tile; pushes past the end are
--     dropped silently, as with the original's fixed Int32Array. That can
--     split a component, so it is reproduced exactly.
--   - Water added later (water nukes) joins or merges components through a
--     union-find table, without relabelling.

local ConnectedComponents = {}
ConnectedComponents.__index = ConnectedComponents

local LAND_MARKER = 0xff
local LAND_MARKER_WIDE = 0xffff
ConnectedComponents.LAND_MARKER = LAND_MARKER

export type ConnectedComponents = typeof(setmetatable(
	{} :: {
		map: any,
		width: number,
		height: number,
		numTiles: number,
		lastRowStart: number,
		ids: buffer?, -- u16 per tile
		componentSizes: { [number]: number },
		parents: { [number]: number },
		maxId: number,
		landMarker: number,
		wide: boolean,
	},
	ConnectedComponents
))

function ConnectedComponents.new(map: any): ConnectedComponents
	local width, height = map:width(), map:height()
	return setmetatable({
		map = map,
		width = width,
		height = height,
		numTiles = width * height,
		lastRowStart = (height - 1) * width,
		ids = nil,
		componentSizes = {},
		parents = {},
		maxId = 0,
		landMarker = LAND_MARKER,
		wide = false,
	}, ConnectedComponents)
end

function ConnectedComponents.initialize(self: ConnectedComponents)
	local numTiles = self.numTiles
	local ids = buffer.create(numTiles * 2)
	local map = self.map
	-- Pre-mark land (bit 7 of the terrain byte) with the land marker.
	for i = 0, numTiles - 1 do
		if map:isLand(i) then
			buffer.writeu16(ids, i * 2, LAND_MARKER)
		end
	end
	self.componentSizes = {}
	self.wide = false
	local landMarker = LAND_MARKER
	local nextId = 0
	local queue = buffer.create(numTiles * 4)
	for start = 0, numTiles - 1 do
		local value = buffer.readu16(ids, start * 2)
		if value == 0 then
			nextId += 1
			-- Promote to 16-bit labels before component 254 (0xFF is land).
			if nextId == 253 and not self.wide then
				self.wide = true
				landMarker = LAND_MARKER_WIDE
				for i = 0, numTiles - 1 do
					if buffer.readu16(ids, i * 2) == LAND_MARKER then
						buffer.writeu16(ids, i * 2, LAND_MARKER_WIDE)
					end
				end
			end
			if nextId == 0xffff then
				break
			end
			self:_floodFillComponent(ids, queue, start, nextId)
		end
	end
	self.ids = ids
	self.landMarker = landMarker
	self.maxId = nextId
	self.parents = {}
	for i = 0, nextId do
		self.parents[i] = i
	end
end

-- Scan-line fill of one water component from `start`.
function ConnectedComponents._floodFillComponent(self: ConnectedComponents, ids: buffer, queue: buffer, start: number, componentId: number)
	local width, numTiles, lastRowStart = self.width, self.numTiles, self.lastRowStart
	local head, tail = 0, 0
	local function push(v: number)
		-- A fixed-size typed array: writes past the end are dropped.
		if tail < numTiles then
			buffer.writei32(queue, tail * 4, v)
		end
		tail += 1
	end
	push(start)
	while head < tail do
		local seedIndex = head
		head += 1
		-- Reading past the end yields undefined, which is skipped.
		if seedIndex < numTiles then
			local seed = buffer.readi32(queue, seedIndex * 4)
			if buffer.readu16(ids, seed * 2) == 0 then
				local left = seed
				local rowStart = seed - (seed % width)
				while left > rowStart and buffer.readu16(ids, (left - 1) * 2) == 0 do
					left -= 1
				end
				local right = seed
				local rowEnd = rowStart + width - 1
				while right < rowEnd and buffer.readu16(ids, (right + 1) * 2) == 0 do
					right += 1
				end
				self.componentSizes[componentId] = (self.componentSizes[componentId] or 0) + (right - left + 1)
				for x = left, right do
					buffer.writeu16(ids, x * 2, componentId)
					if x >= width then
						local above = x - width
						if buffer.readu16(ids, above * 2) == 0 then
							push(above)
						end
					end
					if x < lastRowStart then
						local below = x + width
						if buffer.readu16(ids, below * 2) == 0 then
							push(below)
						end
					end
				end
			end
		end
	end
end

function ConnectedComponents._find(self: ConnectedComponents, id: number): number
	local parents = self.parents
	local root = id
	while parents[root] ~= root do
		root = parents[root]
	end
	local cur = id
	while parents[cur] ~= root do
		local nxt = parents[cur]
		parents[cur] = root
		cur = nxt
	end
	return root
end

function ConnectedComponents._rootAt(self: ConnectedComponents, index: number): number
	local id = buffer.readu16(self.ids :: buffer, index * 2)
	if id == 0 or id == self.landMarker then
		return 0
	end
	return self:_find(id)
end

function ConnectedComponents._allocComponentId(self: ConnectedComponents): number
	if self.maxId >= 0xfffe then
		return self.maxId
	end
	self.maxId += 1
	local id = self.maxId
	if id >= 253 and not self.wide then
		self.wide = true
		local ids = self.ids :: buffer
		for i = 0, self.numTiles - 1 do
			if buffer.readu16(ids, i * 2) == LAND_MARKER then
				buffer.writeu16(ids, i * 2, LAND_MARKER_WIDE)
			end
		end
		self.landMarker = LAND_MARKER_WIDE
	end
	self.parents[id] = id
	return id
end

-- Newly converted water tiles (land became water) join, merge or start
-- components. No-op before initialize().
function ConnectedComponents.addWaterTiles(self: ConnectedComponents, tiles: { number })
	local ids = self.ids
	if ids == nil then
		return
	end
	local width = self.width
	for _, tile in tiles do
		local idsNow = self.ids :: buffer
		if buffer.readu16(idsNow, tile * 2) == self.landMarker then
			local x = tile % width
			local r0, r1, r2, r3 = 0, 0, 0, 0
			if tile >= width then
				r0 = self:_rootAt(tile - width)
			end
			if tile < self.lastRowStart then
				r1 = self:_rootAt(tile + width)
			end
			if x > 0 then
				r2 = self:_rootAt(tile - 1)
			end
			if x < width - 1 then
				r3 = self:_rootAt(tile + 1)
			end
			local roots = { r0, r1, r2, r3 }
			local canon = 0
			for _, r in roots do
				if r ~= 0 and (canon == 0 or r < canon) then
					canon = r
				end
			end
			if canon == 0 then
				local id = self:_allocComponentId()
				buffer.writeu16(self.ids :: buffer, tile * 2, id)
				self.componentSizes[id] = 1
			else
				buffer.writeu16(idsNow, tile * 2, canon)
				self.componentSizes[canon] = (self.componentSizes[canon] or 0) + 1
				for _, r in roots do
					if r ~= 0 and r ~= canon and self.parents[r] ~= canon then
						self.parents[r] = canon
						self.componentSizes[canon] = (self.componentSizes[canon] or 0) + (self.componentSizes[r] or 0)
						self.componentSizes[r] = 0
					end
				end
			end
		end
	end
end

function ConnectedComponents.getComponentId(self: ConnectedComponents, tile: number): number
	local ids = self.ids
	if ids == nil then
		return 0
	end
	local id = buffer.readu16(ids, tile * 2)
	if id == 0 or id == self.landMarker then
		return id
	end
	return self:_find(id)
end

function ConnectedComponents.getComponentSize(self: ConnectedComponents, componentId: number): number
	if componentId <= 0 or componentId > self.maxId then
		return 0
	end
	return self.componentSizes[self:_find(componentId)] or 0
end

return ConnectedComponents
