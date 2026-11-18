--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/passes/TerrainPass.ts; src/client/render/gl/shaders/border-compute/border-compute.frag.glsl; src/client/render/gl/shaders/map-overlay/territory.frag.glsl; src/client/render/frame/Upload.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Pure CPU producer. A sink owns the EditableImages (or headless buffers).
local Terrain = require(script.Parent.TerrainColors)
local Colors = require(script.Parent.PlayerColors)
local ColorMath = require(script.Parent.ColorMath)
local Political = require(script.Parent.PoliticalColors)
local Defaults = require(script.Parent.RenderDefaults)
local Edge = require(script.Parent.EdgeSmoothing)
local Policy = require(script.Parent.RenderPolicy)
local DeferredDirty = require(script.Parent.DeferredDirty)
local FalloutReveal = require(script.Parent.FalloutReveal)
-- Cache the numerical primitives used for each shaded pixel.
local read8,read16,read32,write32=buffer.readu8,buffer.readu16,buffer.readu32,buffer.writeu32
local band,btest=bit32.band,bit32.btest
local FOREIGN_BORDER_PATTERN="["..string.char(8).."-"..string.char(14).."]"
local Core = {}
Core.PAGE, Core.BLOCK = 1024, 32
export type Pattern = {width: number, height: number, scale: number, bytes: buffer}
export type Player = {id: string, smallID: number, playerType: string, team: string?, cosmetics: Colors.Cosmetics?, pattern: Pattern?}
export type Page = {id: number, x: number, y: number, width: number, height: number, queue: {number}, head: number, pixels: buffer, initialized: boolean}
export type Sink = {write: (Page, number, number, number, number, buffer) -> (), destroy: () -> ()}
type Paint = {solid: number?, lut: buffer?, color: Political.RGBA?}
type Entry = {fill: Political.RGBA, border: Political.RGBA, secondary: Political.RGBA, pattern: Pattern?, paints: {[number]: Paint}}
type Job = {key: number, page: number, revision: number, x: number, y: number, width: number, height: number, cursor: number, full: boolean, pixels: buffer, owners: {[number]: boolean}}
type AgeSample = {frame: number, time: number, age: number, ownAge: number, frontAge: number}
export type Viewport = {x0: number, y0: number, x1: number, y1: number}
export type State = {
	width: number, height: number, terrain: buffer, tileState: buffer, terrainLut: buffer, pages: {Page}, columns: number, pageColumns: number,
	borderFlags: buffer, relationRows: buffer, dirtyRows: buffer, fullDirty: buffer, shadedPixels: number, composeMs: number, sinkMs: number, queued: buffer, revisions: buffer, dirtyBounds: buffer, dirtySince: buffer, pending: number, blocks: number, nextPage: number, job: Job?, sink: Sink,
	palette: {[number]: Entry}, theme: Colors.Theme, roster: {Player}, localPlayer: number, hover: number,
	relations: buffer, relationSize: number, ownerBlocks: {[number]: {[number]: boolean}}, blockOwners: {[number]: {[number]: boolean}}, indexEntries: number,
	paints: {[string]: Paint}, paintBytes: number, paintLimit: number, scratch: {[number]: buffer}, scratchBytes: number,
	paintedPixels: number, uploadedBytes: number, uploads: number, frames: number, managedFrames: boolean, steps: number, destroyed: boolean,
	terrainOnly: boolean,
	softMapEdges: boolean,
	trails: {[number]: number}, spawnDiscs: {[number]: number}, overlayRows: {[number]: number},
	maxUploadAgeFrames: number,
	viewport: Viewport?, visiblePending: number, lastUploadAgeFrames: number,
	rowCursor: buffer, rowDirtySince: buffer, ownDirtyRows: buffer, ownQueued: buffer, committedRevisions: buffer, nextOwnPage: number, nextBackgroundPage: number,
	recentAges: {AgeSample}, recentCursor: number, lastTileTime: number, lastOwnTileTime: number,
	deferred: any,
	falloutReveal: any,
	frontDirtyRows: buffer, frontQueued: buffer, frontRowSince: buffer,
	normalCursor: number,
}

-- Roblox adapter for TerrainPass texture allocation: exact-size edge pages,
-- never a stride. Sink allocation is lazy on the first upload of each page.
function Core.new(terrain: buffer, width: number, height: number, sink: Sink): State
	assert(width > 0 and height > 0 and width % 1 == 0 and height % 1 == 0 and buffer.len(terrain) == width * height, "invalid terrain dimensions")
	local pages: {Page} = {}
	for y = 0, height - 1, Core.PAGE do for x = 0, width - 1, Core.PAGE do
		table.insert(pages, {id = #pages + 1, x = x, y = y, width = math.min(Core.PAGE, width - x), height = math.min(Core.PAGE, height - y), queue = {}, head = 1, initialized=false, pixels=buffer.create(math.min(Core.PAGE,width-x)*math.min(Core.PAGE,height-y)*4)})
	end end
	local cols, rows = math.ceil(width / Core.BLOCK), math.ceil(height / Core.BLOCK)
	local s: State = {width = width, height = height, terrain = buffer.create(buffer.len(terrain)), tileState = buffer.create(width * height * 2),
		terrainLut = Terrain.palette(Terrain.defaults), pages = pages, columns = cols, pageColumns = math.ceil(width / Core.PAGE),
		borderFlags=buffer.create(width*height),relationRows=buffer.create(cols*rows*128),dirtyRows=buffer.create(cols*rows*128),fullDirty=buffer.create(cols*rows),shadedPixels=0,composeMs=0,sinkMs=0,
		queued = buffer.create(cols * rows), revisions = buffer.create(cols * rows * 4), dirtyBounds = buffer.create(cols * rows * 4), dirtySince = buffer.create(cols * rows * 4),
		pending = 0, blocks = cols * rows, nextPage = 1, job = nil, sink = sink,
		palette = {}, theme = Colors.new(), roster = {}, localPlayer = 0, hover = 0, relations = buffer.create(0), relationSize = 0,
		ownerBlocks = {}, blockOwners = {}, indexEntries = 0, paints = {}, paintBytes = 0, paintLimit = 4 * 1024 * 1024,
		scratch = {}, scratchBytes = 0, paintedPixels = 0, uploadedBytes = 0, uploads = 0, frames=0, managedFrames=false, steps = 0, destroyed = false, terrainOnly = true, softMapEdges=Policy.softMapEdges, maxUploadAgeFrames = 0,
		trails = {}, spawnDiscs = {}, overlayRows = {}, viewport=nil, visiblePending=0, lastUploadAgeFrames=0,
		rowCursor=buffer.create(cols*rows),rowDirtySince=buffer.create(cols*rows*128),ownQueued=buffer.create(cols*rows),committedRevisions=buffer.create(cols*rows*4),
		ownDirtyRows=buffer.create(cols*rows*128),nextOwnPage=1,nextBackgroundPage=1,
		recentAges={},recentCursor=0,lastTileTime=-1,lastOwnTileTime=-1,
		deferred=DeferredDirty.new(Policy.deferredOwnership,Policy.deferredMaxPendingRecords),
		falloutReveal=FalloutReveal.new(Policy.coherentFallout,Policy.falloutRevealMaxPixels,Policy.falloutRevealRegions),
		frontDirtyRows=buffer.create(cols*rows*128),frontQueued=buffer.create(cols*rows),frontRowSince=buffer.create(cols*rows*128),normalCursor=0}
	buffer.fill(s.borderFlags,0,255)
	buffer.copy(s.terrain, 0, terrain)
	s.deferred.width=width
	Core.repaint(s)
	return s
end

-- Roblox dirty-chunk scheduling for GPURenderer.uploadLiveDelta. Queue once;
-- revisions protect row commits from clearing a later confirmed edit.
local function mark(s: State, key: number, x0: number?, y0: number?, x1: number?, y1: number?)
	if x0==nil then
		buffer.writeu8(s.fullDirty,key,1)
		local bx,by=key%s.columns*Core.BLOCK,math.floor(key/s.columns)*Core.BLOCK
		local width=math.min(Core.BLOCK,s.width-bx)
		local mask=bit32.rshift(4294967295,32-width)
		local own=s.ownerBlocks[s.localPlayer] and s.ownerBlocks[s.localPlayer][key]
		for row=by,math.min(by+Core.BLOCK,s.height)-1 do
			buffer.fill(s.borderFlags,row*s.width+bx,255,width)
			local offset=key*128+(row-by)*4
			if read32(s.dirtyRows,offset)==0 then write32(s.rowDirtySince,offset,s.frames+1) end
			write32(s.dirtyRows,offset,mask)
			if own then write32(s.ownDirtyRows,offset,mask) end
		end
		if s.ownerBlocks[s.localPlayer] and s.ownerBlocks[s.localPlayer][key] then buffer.writeu8(s.ownQueued,key,1) end
	end
	local revision = buffer.readu32(s.revisions, key * 4)
	buffer.writeu32(s.revisions, key * 4, (revision + 1) % 4294967296)
	local x, y = key % s.columns * Core.BLOCK, math.floor(key / s.columns) * Core.BLOCK
	local minX, minY = math.max(0, (x0 or x) - x), math.max(0, (y0 or y) - y)
	local maxX, maxY = math.min(Core.BLOCK, s.width - x, (x1 or (x + Core.BLOCK)) - x), math.min(Core.BLOCK, s.height - y, (y1 or (y + Core.BLOCK)) - y)
	local queued = buffer.readu8(s.queued, key) ~= 0
	if queued then
		minX = math.min(minX, buffer.readu8(s.dirtyBounds, key * 4)); minY = math.min(minY, buffer.readu8(s.dirtyBounds, key * 4 + 1))
		maxX = math.max(maxX, buffer.readu8(s.dirtyBounds, key * 4 + 2)); maxY = math.max(maxY, buffer.readu8(s.dirtyBounds, key * 4 + 3))
	end
	buffer.writeu8(s.dirtyBounds, key * 4, minX); buffer.writeu8(s.dirtyBounds, key * 4 + 1, minY)
	buffer.writeu8(s.dirtyBounds, key * 4 + 2, maxX); buffer.writeu8(s.dirtyBounds, key * 4 + 3, maxY)
	if queued then return end
	buffer.writeu8(s.queued, key, 1); s.pending += 1
	buffer.writeu32(s.dirtySince, key * 4, s.frames + 1)
	local page = s.pages[math.floor(y / Core.PAGE) * s.pageColumns + math.floor(x / Core.PAGE) + 1]
	table.insert(page.queue, key)
end

-- Original uploadFrameData full-upload path, scheduled over pages.
function Core.repaint(s: State)
	assert(not s.destroyed, "renderer destroyed")
	s.deferred:clear() -- the full repaint covers every pending cosmetic edit
	buffer.fill(s.frontDirtyRows,0,0);buffer.fill(s.frontQueued,0,0);buffer.fill(s.frontRowSince,0,0)
	for key = 0, s.blocks - 1 do mark(s, key) end
end

-- Experimental presentation only. Repeated settings are free; switching
-- repaints through the ordinary row/revision/one-page scheduler.
function Core.setEdgeSmoothing(s: State, enabled: boolean)
	assert(not s.destroyed,'renderer destroyed')
	if s.softMapEdges==enabled then return end
	s.softMapEdges=enabled; Core.repaint(s)
end

-- One 32-bit mask per block row retains the precise dirty halo. Sparse
-- changes on opposite sides of a block must not shade its unchanged interior.
local function dirtyRect(s: State, key: number, x0: number, y0: number, x1: number, y1: number, borders: boolean?, own: boolean?, front: boolean?, frontSince: number?)
	local bx,by=key%s.columns*Core.BLOCK,math.floor(key/s.columns)*Core.BLOCK
	local lo,hi=math.max(0,x0-bx),math.min(32,s.width-bx,x1-bx)
	local mask=bit32.lshift(bit32.rshift(4294967295,32-(hi-lo)),lo)
	for y=math.max(0,y0-by),math.min(32,s.height-by,y1-by)-1 do
		local off=key*128+y*4
		local old=read32(s.dirtyRows,off);local merged=bit32.bor(old,mask)
		if old==0 then write32(s.rowDirtySince,off,s.frames+1) end
		if merged~=old then write32(s.dirtyRows,off,merged) end
		if own then
			local previous=read32(s.ownDirtyRows,off);local value=bit32.bor(previous,mask)
			if value~=previous then write32(s.ownDirtyRows,off,value) end
		end
		if front then
			local previousFront=read32(s.frontDirtyRows,off);local since=frontSince or s.frames+1
			write32(s.frontRowSince,off,if previousFront==0 then since else math.min(read32(s.frontRowSince,off),since))
			write32(s.frontDirtyRows,off,bit32.bor(previousFront,mask));buffer.writeu8(s.frontQueued,key,1)
		end
		if borders then buffer.fill(s.borderFlags,(by+y)*s.width+bx+lo,255,hi-lo) end
	end
end

-- Original border-compute highlight halo. Invalidate across page boundaries,
-- including diagonal halo samples, without reading or downsampling neighbours.
local function markAround(s: State, tile: number, regions: {[number]: {number}}, last: number?, own: boolean?, since: number?, front: boolean?)
	local x, y = tile % s.width, math.floor(tile / s.width)
	local right=if last then last%s.width else x
	local radius = math.max(if s.softMapEdges then 2 else 1, Defaults.mapOverlay.highlightThicken)
	for by = math.floor(math.max(0, y - radius) / Core.BLOCK), math.floor(math.min(s.height - 1, y + radius) / Core.BLOCK) do
		for bx = math.floor(math.max(0, x - radius) / Core.BLOCK), math.floor(math.min(s.width - 1, right + radius) / Core.BLOCK) do
			local key = by * s.columns + bx
			dirtyRect(s,key,x-radius,y-radius,right+radius+1,y+radius+1,true,own,front,since)
			if since then
				for row=math.max(by*32,y-radius),math.min((by+1)*32,s.height,y+radius+1)-1 do
					local off=key*128+(row%32)*4
					write32(s.rowDirtySince,off,math.min(read32(s.rowDirtySince,off),since))
				end
			end
			if own then buffer.writeu8(s.ownQueued,key,1) end
			local r = regions[key]
			if r then
				r[1], r[2] = math.min(r[1], x - radius), math.min(r[2], y - radius)
				r[3], r[4] = math.max(r[3], right + radius + 1), math.max(r[4], y + radius + 1)
			else regions[key] = {x - radius, y - radius, right + radius + 1, y + radius + 1} end
		end
	end
end

-- Roblox batching of uploadLiveDelta dirty rectangles: one revision/queue
-- operation per affected block, retaining deterministic row-major scheduling.
local function flushRegions(s: State, regions: {[number]: {number}})
	local keys = {}; for key in regions do table.insert(keys, key) end; table.sort(keys)
	for _, key in keys do local r = regions[key]; mark(s, key, r[1], r[2], r[3], r[4]) end
end

function Core.hasPending(s: State): boolean
	return s.pending>0 or s.deferred.count>0 or #s.falloutReveal.regions>0
end

-- Ported from RoWorld 2be8efb (src/client/Map/MapSurface.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
-- _expand_changes: centre always; only potentially changed cardinal borders,
-- and hovered diagonals. Repeated owner paths conservatively visit all cardinals.
function Core.flushInvalidations(s: State, budgetMs: number?, limit: number?): number
	local regions: {[number]: {number}}={}
	local front=false
	local function dirty(tile: number, own: boolean, since: number)
		local x,y=tile%s.width,math.floor(tile/s.width)
		local key=math.floor(y/32)*s.columns+math.floor(x/32)
		dirtyRect(s,key,x,y,x+1,y+1,true,own,front,since)
		local offset=key*128+(y%32)*4
		write32(s.rowDirtySince,offset,math.min(read32(s.rowDirtySince,offset),since))
		if own then buffer.writeu8(s.ownQueued,key,1) end
		local r=regions[key]
		if r then r[1],r[2],r[3],r[4]=math.min(r[1],x),math.min(r[2],y),math.max(r[3],x+1),math.max(r[4],y+1)
		else regions[key]={x,y,x+1,y+1} end
	end
	local n=s.deferred:step(function(item: any)
		local tile=item.tile
		front=item.front==true
		if item.last or s.softMapEdges or Defaults.mapOverlay.highlightThicken>1 then markAround(s,tile,regions,item.last,item.own,item.since,front);return end
		dirty(tile,item.own,item.since)
		if not item.ownerChanged then return end
		local a,b=item.old,band(read16(s.tileState,tile*2),4095)
		local x,y=tile%s.width,math.floor(tile/s.width)
		local function neighbour(other: number)
			local owner=band(read16(s.tileState,other*2),4095)
			if owner==0 then return end
			local related=false
			if owner<s.relationSize then
				local base=owner*s.relationSize
				related=(a>0 and a<s.relationSize and read8(s.relations,base+a)>0)
					or (b>0 and b<s.relationSize and read8(s.relations,base+b)>0)
			end
			-- Neutral transitions also change our cached foreign-border bit,
			-- even when the visible border stays opaque. Diplomacy uses that index.
			if item.wide or a==0 or b==0 or owner==a or owner==b or related then dirty(other,item.own or owner==s.localPlayer,item.since) end
		end
		if x>0 then neighbour(tile-1) end;if x<s.width-1 then neighbour(tile+1) end
		if y>0 then neighbour(tile-s.width) end;if y<s.height-1 then neighbour(tile+s.width) end
		if s.hover>0 then
			for dy=-1,1,2 do for dx=-1,1,2 do
				local xx,yy=x+dx,y+dy
				if xx>=0 and yy>=0 and xx<s.width and yy<s.height then
					local other=yy*s.width+xx
					if band(read16(s.tileState,other*2),4095)==s.hover then dirty(other,item.own,item.since) end
				end
			end end
		end
	end,limit or Policy.deferredTilesPerFrame,budgetMs or Policy.deferredMs,s.frames%4~=0)
	flushRegions(s,regions)
	return n
end

-- Original: TrailPass.upload and SpawnOverlayPass enemy highlights. These
-- share the existing page upload budget rather than a second dynamic image.
local function sparseChanges(s: State, target: {[number]: number}, values: {[number]: number}, refs: {number})
	local regions: {[number]: {number}} = {}
	for _, tile in refs do
		local old, new = target[tile], values[tile]
		if old ~= new then
			local row = math.floor(tile / s.width)
			s.overlayRows[row] = (s.overlayRows[row] or 0) + (if new then 1 else 0) - (if old then 1 else 0)
			if s.overlayRows[row] == 0 then s.overlayRows[row] = nil end
			target[tile] = new
			local x = tile % s.width
			local key = math.floor(row / Core.BLOCK) * s.columns + math.floor(x / Core.BLOCK)
			dirtyRect(s,key,x,row,x+1,row+1)
			local r = regions[key]
			if r then r[1],r[2],r[3],r[4] = math.min(r[1],x),math.min(r[2],row),math.max(r[3],x+1),math.max(r[4],row+1)
			else regions[key] = {x,row,x+1,row+1} end
		end
	end
	flushRegions(s,regions)
end
function Core.applyTrails(s: State, values: {[number]: number}, refs: {number})
	sparseChanges(s,s.trails,values,refs)
end
function Core.setSpawnDiscs(s: State, centers: {{x: number,y: number,owner: number}})
	local values: {[number]: number} = {}
	for _, c in centers do
		local radius = Defaults.spawnOverlay.highlightRadius
		for y = math.max(0,math.floor(c.y-radius)),math.min(s.height-1,math.ceil(c.y+radius)) do
			for x = math.max(0,math.floor(c.x-radius)),math.min(s.width-1,math.ceil(c.x+radius)) do
				-- One map pixel samples the shader at the tile centre.
				if (x+.5-c.x)^2 + (y+.5-c.y)^2 <= radius^2 then values[y*s.width+x] = c.owner end
			end
		end
	end
	local refs, seen = {}, {}
	for tile in values do table.insert(refs,tile); seen[tile] = true end
	for tile in s.spawnDiscs do if not seen[tile] then table.insert(refs,tile) end end
	sparseChanges(s,s.spawnDiscs,values,refs)
end

-- Original WebGLFrameBuilder.syncPlayers / PlayerView.computeColors. Rebuild
-- in supplied source roster order, using rounded RGB at the renderer boundary.
local function buildPalette(s: State)
	s.theme, s.palette = Colors.new(), {}
	s.paints, s.paintBytes = {}, 0
	for _, p in s.roster do
		local themed = Colors.territoryColor(s.theme, p.id, p.playerType, p.team)
		local resolved = Colors.resolvePlayerColors(s.theme, themed, p.cosmetics or {}, p.team, p.smallID == s.localPlayer)
		local a, b = ColorMath.toRgb(resolved.territory), ColorMath.toRgb(resolved.border)
		local secondary = {r = b.r / 255, g = b.g / 255, b = b.b / 255, a = 1}
		-- Conquest store masks have no source colour palette. Give them a
		-- readable second shade independent of the local player's grey border;
		-- explicit OpenFront cosmetic palettes retain their source colours.
		if p.pattern and not (p.cosmetics and p.cosmetics.pattern and p.cosmetics.pattern.colorPalette) then
			local light = (a.r * .299 + a.g * .587 + a.b * .114) / 255 > .5
			local target = if light then 0 else 1
			secondary = {r = a.r / 255 * .65 + target * .35, g = a.g / 255 * .65 + target * .35,
				b = a.b / 255 * .65 + target * .35, a = 1}
		end
		s.palette[p.smallID] = {fill = {r = a.r / 255, g = a.g / 255, b = a.b / 255, a = 1},
			border = {r = b.r / 255, g = b.g / 255, b = b.b / 255, a = 1}, secondary = secondary, pattern = p.pattern, paints = {}}
	end
	Core.repaint(s)
end

-- Original GameView.update player construction/merge order. Own the supplied
-- metadata and bitmasks so later caller mutations cannot bypass invalidation.
function Core.setRoster(s: State, players: {Player})
	assert(not s.destroyed, "renderer destroyed")
	local roster: {Player}, seen: {[number]: boolean} = {}, {}
	for _, p in players do
		assert(p.smallID >= 1 and p.smallID <= 4095 and p.smallID % 1 == 0 and not seen[p.smallID], "invalid/duplicate smallID")
		assert(p.playerType == "HUMAN" or p.playerType == "BOT" or p.playerType == "NATION", "invalid player type")
		seen[p.smallID] = true
		local c = table.clone(p)
		if p.cosmetics then
			local cosmetics = table.clone(p.cosmetics)
			if cosmetics.color then cosmetics.color = table.clone(cosmetics.color) end
			if cosmetics.pattern then
				cosmetics.pattern = table.clone(cosmetics.pattern)
				if cosmetics.pattern.colorPalette then cosmetics.pattern.colorPalette = table.clone(cosmetics.pattern.colorPalette) end
			end
			c.cosmetics = cosmetics
		end
		if p.pattern then
			local mask = p.pattern
			assert(mask.width >= 1 and mask.height >= 1 and mask.scale >= 0 and mask.scale <= 30 and mask.scale % 1 == 0
				and mask.width % 1 == 0 and mask.height % 1 == 0 and buffer.len(mask.bytes) >= math.ceil(mask.width * mask.height / 8), "invalid pattern")
			local copied = table.clone(mask); copied.bytes = buffer.create(buffer.len(mask.bytes)); buffer.copy(copied.bytes, 0, mask.bytes)
			c.pattern = copied
		end
		table.insert(roster, c)
	end
	s.roster = roster; buildPalette(s)
end

-- Original palette own-player border selection.
function Core.setLocalPlayer(s: State, smallID: number)
	assert(not s.destroyed, "renderer destroyed")
	assert(smallID >= 0 and smallID <= 4095 and smallID % 1 == 0, "invalid local smallID")
	if smallID == s.localPlayer then return end
	s.localPlayer = smallID; buildPalette(s)
end

-- Original uploadFrameData.updateRelations (matrix is symmetric in source).
local function neighborRelation(s: State, matrix: {size: number, data: buffer}, owner: number, tile: number): number
	local other=band(read16(s.tileState,tile*2),4095)
	return if other>0 and other~=owner and other<matrix.size then read8(matrix.data,owner*matrix.size+other) else 0
end
function Core.setRelations(s: State, matrix: {size: number, data: buffer})
	assert(not s.destroyed, "renderer destroyed")
	assert(matrix.size >= 0 and matrix.size <= 4096 and matrix.size % 1 == 0 and buffer.len(matrix.data) == matrix.size ^ 2, "invalid relation matrix")
	if s.relationSize~=matrix.size then
		s.relationSize,s.relations=matrix.size,buffer.create(buffer.len(matrix.data))
		buffer.copy(s.relations,0,matrix.data); Core.repaint(s); return
	end
	-- Relations affect the cardinal border classification, never an empire's
	-- interior fill. Candidate blocks use the conservative painted-owner index;
	-- pending ownership halos already invalidate any unindexed new borders.
	local candidates: {[number]: boolean}={}
	local changedOwners: {[number]: boolean}={}
	for id=0,matrix.size-1 do
		local offset=id*matrix.size
		if buffer.readstring(s.relations,offset,matrix.size)~=buffer.readstring(matrix.data,offset,matrix.size) then
			changedOwners[id]=true
			local blocks=s.ownerBlocks[id]
			if blocks then for key in blocks do candidates[key]=true end end
		end
	end
	local regions: {[number]: {number}}={}
	for key in candidates do
		-- A packed border-row cache skips whole interior blocks and visits only
		-- borders toward another owner (coasts cannot change relation). Do not
		-- walk/allocate strings for every map row
		-- on the confirmed-state callback (especially a near-total empire).
		if buffer.readstring(s.relationRows,key*128,128):find('[^%z]')==nil then continue end
		local bx,by=key%s.columns*32,math.floor(key/s.columns)*32
		local h=math.min(32,s.height-by)
		for y=by,by+h-1 do
			local mask=read32(s.relationRows,key*128+(y-by)*4)
			while mask~=0 do
				local col=bit32.countrz(mask)+1
				local tile=y*s.width+bx+col-1
				local old=read8(s.borderFlags,tile)
				local owner=band(read16(s.tileState,tile*2),4095)
				if old~=255 and changedOwners[owner] and owner<matrix.size then
					local x=bx+col-1
					local relation=0
					if y>0 then relation=math.max(relation,neighborRelation(s,matrix,owner,tile-s.width)) end
					if y+1<s.height then relation=math.max(relation,neighborRelation(s,matrix,owner,tile+s.width)) end
					if x>0 then relation=math.max(relation,neighborRelation(s,matrix,owner,tile-1)) end
					if x+1<s.width then relation=math.max(relation,neighborRelation(s,matrix,owner,tile+1)) end
					if relation~=band(bit32.rshift(old,1),3) then
						if s.softMapEdges then markAround(s,tile,regions,nil,owner==s.localPlayer)
						else
							dirtyRect(s,key,x,y,x+1,y+1,true,owner==s.localPlayer)
							if owner==s.localPlayer then buffer.writeu8(s.ownQueued,key,1) end
							local r=regions[key]
							if r then r[1],r[2],r[3],r[4]=math.min(r[1],x),math.min(r[2],y),math.max(r[3],x+1),math.max(r[4],y+1)
							else regions[key]={x,y,x+1,y+1} end
						end
					end
				end
				mask=band(mask,mask-1)
			end
		end
	end
	buffer.copy(s.relations,0,matrix.data)
	-- Reentrant sink changes must retain an in-flight row's dirty bits. Do
	-- not expand those rows or reset their ages to a full-block repaint.
	if next(changedOwners)~=nil and s.job then
		local key=s.job.key
		if read8(s.queued,key)~=0 and not regions[key] then
			mark(s,key,key%s.columns*32+read8(s.dirtyBounds,key*4),math.floor(key/s.columns)*32+read8(s.dirtyBounds,key*4+1),
				key%s.columns*32+read8(s.dirtyBounds,key*4+2),math.floor(key/s.columns)*32+read8(s.dirtyBounds,key*4+3))
		end
	end
	flushRegions(s,regions)
end

-- Original GPURenderer.setHighlightOwner. Indexes describe displayed blocks;
-- blocks with new owners not yet indexed are already pending repaint.
function Core.setHover(s: State, owner: number)
	assert(not s.destroyed, "renderer destroyed")
	assert(owner >= 0 and owner <= 4095 and owner % 1 == 0, "invalid hover owner")
	if s.hover == owner then return end
	if s.job then mark(s,s.job.key) end
	for _, id in {s.hover, owner} do
		local blocks = s.ownerBlocks[id]
		if blocks then for key in blocks do mark(s, key) end end
	end
	s.hover = owner
end

-- Original GameView packed tile updates. Copy only listed refs; full nil means
-- snapshot/full repaint, empty list means no updates. TileRef 0 is valid.
function Core.applyTileStates(s: State, states: buffer, changedTiles: {number}?, changes: {own: {number}, fallout: {number}}?, stageFallout: boolean?)
	assert(not s.destroyed and buffer.len(states) == s.width * s.height * 2, "invalid tile state buffer")
	if changedTiles == nil then s.falloutReveal:clear(); s.terrainOnly = false; buffer.copy(s.tileState, 0, states); Core.repaint(s); return end
	for _, tile in changedTiles do assert(tile >= 0 and tile < s.width * s.height and tile % 1 == 0, "invalid TileRef") end
	local bulk: buffer?=nil
	if s.deferred.enabled and #changedTiles>=4096 and s.deferred.count+2<=s.deferred.cap
		and s.deferred.batchBytes+#changedTiles*16<=Policy.deferredBatchBytes then bulk=buffer.create(#changedTiles*8) end
	local bulkOwn,bulkOther=0,0
	local regions: {[number]: {number}} = {}
	local falloutCount=0
	local revealEnabled=s.falloutReveal.enabled and stageFallout~=false
	local falloutFirst,falloutLast,falloutLeft,falloutRight=math.huge,-1,s.width,-1
	local falloutRunFirst:number?=nil
	local falloutRunLast=0
	local function falloutBounds(from:number,to:number)
		local left,right=from%s.width,to%s.width
		if from<falloutFirst then falloutFirst=from end
		if to>falloutLast then falloutLast=to end
		if left<falloutLeft then falloutLeft=left end
		if right>falloutRight then falloutRight=right end
	end
	local first: number?=nil
	local last: number?=nil
	local ownRun=false
	local firstOld=0
	local rowEnd=0
	local haloGap=2*math.max(if s.softMapEdges then 2 else 1,Defaults.mapOverlay.highlightThicken)+1
	local now=os.clock()
	-- Live deltas need a small-work lane ahead of a nation-sized transfer.
	-- This is scheduling only: every old bulk/foreign row retains its age and
	-- receives the existing normal/background turns. Masks share fixed map bounds.
	local frontBatch=#changedTiles<4096
	local function flush()
		if first then
			if falloutRunFirst then falloutBounds(falloutRunFirst,falloutRunLast);falloutRunFirst=nil end
			if s.deferred.enabled then
				if last and last>first then
					for from=first,last,256 do
						local to=math.min(last,from+255)
						if not s.deferred:pushRun(from,to,ownRun,s.frames+1,ownRun and frontBatch) then markAround(s,from,regions,to,ownRun,nil,ownRun and frontBatch) end
					end
				elseif not s.deferred:push(first,firstOld,read16(s.tileState,first*2),ownRun,s.frames+1,ownRun and frontBatch) then markAround(s,first,regions,nil,ownRun,nil,ownRun and frontBatch) end
			else markAround(s,first,regions,last,ownRun,nil,ownRun and frontBatch) end
			first,last=nil,nil;ownRun=false
		end
	end
	for _, tile in changedTiles do
		local v = buffer.readu16(states, tile * 2)
		local old=read16(s.tileState,tile*2)
		if v ~= old then
			local falloutChanged=band(bit32.bxor(old,v),8192)~=0
			local newFallout=revealEnabled and falloutChanged and btest(v,8192)
			s.lastTileTime=now
			local oldOwner,newOwner=band(old,4095),band(v,4095)
			local own=s.localPlayer>0 and (oldOwner==s.localPlayer or newOwner==s.localPlayer)
			-- The adapter needs these exact transitions too. Collect while the
			-- old/new confirmed words are already in registers, rather than reading
			-- a nation-sized batch again before this copy. Never retain the lists.
			if changes then
				if own and oldOwner~=newOwner then table.insert(changes.own,tile) end
				if falloutChanged then table.insert(changes.fallout,tile) end
			end
			if own then s.lastOwnTileTime=s.lastTileTime end
			s.terrainOnly=false; buffer.writeu16(s.tileState,tile*2,v)
			if bulk then
				if own then write32(bulk,bulkOwn*4,tile);bulkOwn+=1
				else write32(bulk,(#changedTiles+bulkOther)*4,tile);bulkOther+=1 end
			elseif last and tile>last and tile<rowEnd and (tile==last+1 or (not s.deferred.enabled and own==ownRun and tile-last<=haloGap)) then
				-- Adjacent horizontal halos already overlap, even across a small
				-- unchanged gap. Union them before dirtyRect without widening the
				-- dirty mask or the own-priority mask. Deferred sparse semantics stay
				-- unchanged; large/unsorted gaps still use their original spans.
				last=tile;ownRun=ownRun or own
			else flush();first,last,ownRun,firstOld=tile,tile,own,old;rowEnd=(math.floor(tile/s.width)+1)*s.width end
			if newFallout then
				falloutCount+=1
				if bulk then falloutBounds(tile,tile)
				else falloutRunFirst=falloutRunFirst or tile;falloutRunLast=tile end
			end
		end
	end
	flush(); flushRegions(s, regions)
	if falloutCount>=Policy.falloutRevealMinTiles then
		local batch=s.falloutReveal:begin()
		local top,bottom=math.floor(falloutFirst/s.width),math.floor(falloutLast/s.width)+1
		for _,page in s.pages do
			if page.initialized and falloutLeft<page.x+page.width and falloutRight>=page.x and top<page.y+page.height and bottom>page.y then
				s.falloutReveal:add(page,math.max(falloutLeft,page.x),math.max(top,page.y),
					math.min(falloutRight+1,page.x+page.width),math.min(bottom,page.y+page.height),s.frames,batch)
			end
		end
	end
	if bulk then
		s.deferred:pushBatch(bulk,0,bulkOwn,true,s.frames+1)
		s.deferred:pushBatch(bulk,#changedTiles*4,bulkOther,false,s.frames+1)
	end
end

-- Original TerrainPass.applyTerrainRects after water-nuke terrain changes.
function Core.applyTerrain(s: State, terrain: buffer, changedTiles: {number}?)
	assert(not s.destroyed and buffer.len(terrain) == s.width * s.height, "invalid terrain buffer")
	if changedTiles == nil then buffer.copy(s.terrain, 0, terrain); Core.repaint(s); return end
	for _, tile in changedTiles do assert(tile >= 0 and tile < s.width * s.height and tile % 1 == 0, "invalid TileRef") end
	local regions: {[number]: {number}} = {}
	for _, tile in changedTiles do
		local v = buffer.readu8(terrain, tile)
		if v ~= buffer.readu8(s.terrain, tile) then buffer.writeu8(s.terrain, tile, v); markAround(s, tile, regions) end
	end
	flushRegions(s, regions)
end

-- Original border-compute.getOwner (off-map is zero, never wrap row edges).
local function ownerAt(s: State, x: number, y: number): number
	if x < 0 or y < 0 or x >= s.width or y >= s.height then return 0 end
	return band(read16(s.tileState, (y * s.width + x) * 2), 4095)
end

-- Original texture blend into the opaque terrain framebuffer, quantized to
-- RGBA8. This CPU composition removes a second native image per page.
local function compositeChannels(cr:number,cg:number,cb:number,alpha:number,background:number):number
	local inverse = 1 - alpha
	local r = math.clamp(math.floor(cr * 255 * alpha + band(background, 255) * inverse + .5), 0, 255)
	local g = math.clamp(math.floor(cg * 255 * alpha + band(bit32.rshift(background, 8), 255) * inverse + .5), 0, 255)
	local b = math.clamp(math.floor(cb * 255 * alpha + band(bit32.rshift(background, 16), 255) * inverse + .5), 0, 255)
	return r + g * 256 + b * 65536 + 4278190080
end
local function composite(c:Political.RGBA,background:number):number return compositeChannels(c.r,c.g,c.b,c.a,background) end

-- Original territory.frag and border-stamp.frag via the tested PoliticalColors
-- functions. Cache by actual RGBA so hundreds of grey tribes share one LUT.
local function paint(s: State, e: Entry, border: boolean, relation: number, highlight: boolean, defended: boolean, secondary: boolean): Paint
	local key = if border then 8 + relation * 4 + (if highlight then 2 else 0) + (if defended then 1 else 0)
		else (if highlight then 2 else 0) + (if defended then 1 else 0) + (if secondary then 4 else 0)
	local cached = e.paints[key]
	if cached then return cached end
	local tile = {owner = 1, x = 1, y = 0, defended = defended, hovered = highlight, secondaryPattern = secondary}
	local flags = {borderType = if border then (if highlight then 1 else .5) else 0, relation = relation * .5}
	local c = if border then Political.stamp(tile, e.border, flags) else Political.fill(tile, e.fill, e.secondary, flags)
	local identity = string.format("%.17g/%.17g/%.17g/%.17g", c.r, c.g, c.b, c.a)
	local p = s.paints[identity]
	if not p then
		local created: Paint = {}
		if c.a == 1 then created.solid = composite(c, 0)
		elseif s.paintBytes + 1024 <= s.paintLimit then
			local lut = buffer.create(1024)
			for byte = 0, 255 do buffer.writeu32(lut, byte * 4, composite(c, read32(s.terrainLut, byte * 4))) end
			created.lut = lut; s.paintBytes += 1024
		else created.color = c end -- retain only RGBA once the 4 MiB LUT budget fills
		s.paints[identity] = created; p = created
	end
	e.paints[key] = p
	return p
end

-- Original border-compute.main + territory/border-stamp sampling. Shader
-- equations are shared with PoliticalColors; only the neighbourhood traversal
-- and RGBA8 framebuffer blend are CPU adaptations.
local function politicalPixel(s: State, x: number, y: number, owners: {[number]: boolean}): number
	local tile = y * s.width + x
	local terrainByte = read8(s.terrain, tile)
	local raw = read16(s.tileState, tile * 2)
	local owner = band(raw, 4095)
	local fallout = btest(raw, 8192)
	if owner > 0 then owners[owner] = true end
	local e = s.palette[owner]
	if owner==0 then
		buffer.writeu8(s.borderFlags,tile,0)
	end
	if owner == 0 and not fallout or owner > 0 and not e and not fallout then return read32(s.terrainLut, terrainByte * 4) end
	local kind, relation = 0, 0
	local highlight = owner > 0 and owner == s.hover
	if owner > 0 then
		local flags=read8(s.borderFlags,tile)
		if flags==255 then
			local state, w = s.tileState, s.width
			local n = if y == 0 then 0 else band(read16(state, (tile - w) * 2), 4095)
			local south = if y == s.height - 1 then 0 else band(read16(state, (tile + w) * 2), 4095)
			local west = if x == 0 then 0 else band(read16(state, (tile - 1) * 2), 4095)
			local east = if x == w - 1 then 0 else band(read16(state, (tile + 1) * 2), 4095)
			if n ~= owner or south ~= owner or west ~= owner or east ~= owner then
				kind = .5
				if owner < s.relationSize then
					local matrix,base,size=s.relations,owner*s.relationSize,s.relationSize
					if n~=owner and n>0 and n<size then relation=read8(matrix,base+n) end
					if south~=n and south~=owner and south>0 and south<size then relation=math.max(relation,read8(matrix,base+south)) end
					if west~=n and west~=south and west~=owner and west>0 and west<size then relation=math.max(relation,read8(matrix,base+west)) end
					if east~=n and east~=south and east~=west and east~=owner and east>0 and east<size then relation=math.max(relation,read8(matrix,base+east)) end
				end
			end
			local foreign=(n>0 and n~=owner) or (south>0 and south~=owner) or (west>0 and west~=owner) or (east>0 and east~=owner)
			buffer.writeu8(s.borderFlags,tile,(if kind>0 then 1 else 0)+relation*2+(if foreign then 8 else 0))
		else
			kind=if btest(flags,1) then .5 else 0
			relation=band(bit32.rshift(flags,1),3)
		end
		if highlight then
			if kind > 0 then kind = 1
			else
				for d = 1, math.min(10, Defaults.mapOverlay.highlightThicken) do
					for i = -d, d do
						if ownerAt(s, x + i, y - d) ~= owner or ownerAt(s, x + i, y + d) ~= owner then kind = 1; break end
					end
					if kind == 0 then for i = -d + 1, d - 1 do
						if ownerAt(s, x - d, y + i) ~= owner or ownerAt(s, x + d, y + i) ~= owner then kind = 1; break end
					end end
					if kind > 0 then break end
				end
			end
		end
	end
	local defended = btest(raw, 16384)
	if kind > 0 and e then
		local odd = defended and (x + y) % 2 == 1
		local key = 8 + relation * 4 + (if kind > .75 then 2 else 0) + (if odd then 1 else 0)
		local p = e.paints[key] or paint(s, e, true, relation, kind > .75, odd, false)
		return p.solid :: number
	end
	if fallout then
		-- Exact territory.frag fallout formula, without five per-pixel temporary
		-- tables during a large landing repaint. Border precedence above remains.
		local settings=Defaults.mapOverlay
		local value=math.sin(x*12.9898+y*78.233)*43758.5453
		local noise=settings.staleNukeBase+(value-math.floor(value))*settings.staleNukeVariation
		return compositeChannels(settings.staleNukeR+noise,settings.staleNukeG+noise,settings.staleNukeB+noise,
			settings.staleNukeAlpha,read32(s.terrainLut,terrainByte*4))
	end
	local secondary = false
	local pattern = (e :: Entry).pattern
	if pattern then
		local i = (bit32.rshift(y, pattern.scale) % pattern.height) * pattern.width + bit32.rshift(x, pattern.scale) % pattern.width
		secondary = btest(read8(pattern.bytes, math.floor(i / 8)), bit32.lshift(1, i % 8))
	end
	local entry = e :: Entry
	local key = (if highlight then 2 else 0) + (if defended then 1 else 0) + (if secondary then 4 else 0)
	local p = entry.paints[key] or paint(s, entry, false, 0, highlight, defended, secondary)
	if p.solid then return p.solid end
	if p.lut then return read32(p.lut, terrainByte * 4) end
	return composite(p.color :: Political.RGBA, read32(s.terrainLut, terrainByte * 4))
end

local function mapPixel(s: State, x: number, y: number, owners: {[number]: boolean}): number
	return Edge.pixel(s,x,y,owners,politicalPixel)
end

-- Original: terrain/fill → enemy spawn → borders → trails frame order.
-- Enemy discs only cover owner 0, which has no political border of its own.
local function pixel(s: State, x: number, y: number, owners: {[number]: boolean}): number
	local out = if s.softMapEdges then mapPixel(s,x,y,owners) else politicalPixel(s,x,y,owners)
	local tile = y*s.width+x
	local spawn = s.spawnDiscs[tile]
	if spawn and band(read16(s.tileState,tile*2),4095) == 0 then
		local e = s.palette[spawn]
		if e then out = composite({r=e.fill.r,g=e.fill.g,b=e.fill.b,a=Defaults.spawnOverlay.highlightAlpha},out) end
	end
	local trail = s.trails[tile]
	if trail then
		local e = s.palette[band(trail,4095)]
		if e then out = composite({r=e.fill.r,g=e.fill.g,b=e.fill.b,a=Defaults.mapOverlay.trailAlpha},out) end
	end
	return out
end

-- Roblox adapter for frame upload: one displayed image per step, progressive
-- row commits, row-level CPU deadlines and independent fairness cursors.
function Core.setViewport(s: State, viewport: Viewport?)
	s.viewport=viewport
end
local function visible(s: State, key: number): boolean
	local v=s.viewport
	if not v then return true end
	local x,y=key%s.columns*Core.BLOCK,math.floor(key/s.columns)*Core.BLOCK
	return x+Core.BLOCK>v.x0 and y+Core.BLOCK>v.y0 and x<v.x1 and y<v.y1
end
-- Own visible fronts get three of four foreground turns. Other visible work
-- and every eighth background turn retain FIFO/page rotation fairness.
local function prioritize(s: State): number
	local pending=0
	if s.pending==0 then return 0 end
	if not s.viewport then return s.pending end
	local background=s.steps%8==0
	local ownFirst=not background and s.steps%4~=0
	for _,page in s.pages do
		local fronts: {number}={}
		local first: {number}={}
		local second: {number}={}
		local third: {number}={}
		for i=page.head,#page.queue do
			local key=page.queue[i]
			local onScreen=visible(s,key)
			if onScreen then pending+=1 end
			if background then table.insert(if onScreen then second else first,key)
			elseif not onScreen then table.insert(third,key)
			elseif ownFirst and read8(s.frontQueued,key)~=0 then table.insert(fronts,key)
			elseif ownFirst and read8(s.ownQueued,key)==0 then table.insert(second,key)
			else table.insert(first,key) end
		end
		if #fronts>0 then for _,key in first do table.insert(fronts,key) end;first=fronts end
		for _,key in second do table.insert(first,key) end
		-- Priority partitioning is destructive. On the normal turn explicitly
		-- restore the oldest visible block to the head, so a continuous stream
		-- of live fronts cannot keep old own/foreign work behind that partition.
		if not ownFirst and not background and #first>1 then
			local oldest=1
			for i=2,#first do
				local a,b=read32(s.dirtySince,first[i]*4),read32(s.dirtySince,first[oldest]*4)
				if a<b or (a==b and (first[i]-s.normalCursor+s.blocks)%s.blocks<(first[oldest]-s.normalCursor+s.blocks)%s.blocks) then oldest=i end
			end
			if oldest~=1 then local key=table.remove(first,oldest)::number;table.insert(first,1,key) end
		end
		for _,key in third do table.insert(first,key) end
		page.queue,page.head=first,1
	end
	return pending
end

local function scratch(s: State,w: number,h: number): buffer
	local key=w*1024+h
	local pixels=s.scratch[key]
	if not pixels then
		local created=buffer.create(w*h*4); s.scratch[key]=created; s.scratchBytes+=buffer.len(created)
		return created
	end
	return pixels
end

local function recordAge(s: State,age: number,own: boolean,frontAge:number)
	local last=s.recentAges[s.recentCursor]
	if not last or last.frame~=s.frames then
		s.recentCursor=s.recentCursor%512+1
		local sample: AgeSample={frame=s.frames,time=os.clock(),age=age,ownAge=if own then age else -1,frontAge=frontAge}
		s.recentAges[s.recentCursor]=sample
	else
		last.age=math.max(last.age,age)
		if own then last.ownAge=math.max(last.ownAge,age) end
		last.frontAge=math.max(last.frontAge,frontAge)
	end
end
-- The adapter advances once even when an atlas reserves the upload slot.
-- Standalone pure callers continue to count one displayed frame per step.
function Core.beginFrame(s: State)
	s.managedFrames=true; s.frames+=1
end
function Core.step(s: State, budgetMs: number?, pixelBudget: number?, heldPages: {[number]: boolean}?): {pixels: number, uploads: number, page: number?, ms: number}
	assert(not s.destroyed, "renderer destroyed")
	local started,pixels,uploads=os.clock(),0,0
	local budget,limit=budgetMs or 2,pixelBudget or 65536
	if budget<=0 or limit<=0 then return {pixels=0,uploads=0,ms=0} end
	s.steps+=1; if not s.managedFrames then s.frames+=1 end
	if s.deferred.count>0 then Core.flushInvalidations(s,math.min(Policy.deferredMs,budget*.5)) end
	s.visiblePending=prioritize(s)
	local presenting:number?=if #s.falloutReveal.regions>0 then s.falloutReveal:nextPage(s) else nil
	-- A ready cohort still gets an image slot when unrelated fronts keep the
	-- ordinary queues busy. Once started, its remaining pages follow directly.
	if not presenting and #s.falloutReveal.regions>0 and s.steps%4==0 then presenting=s.falloutReveal:readyPage(s) end
	local page: Page?=if presenting and not (heldPages and heldPages[presenting]) then s.pages[presenting] else nil
	local fallback: Page?=nil
	local foreground: Page?=nil
	local ownForeground: Page?=nil
	local presentation: Page?=nil
	local ownFirst=s.viewport~=nil and s.steps%4~=0
	local background=s.viewport~=nil and s.steps%8==0
	local pageCursor=if background then s.nextBackgroundPage elseif ownFirst then s.nextOwnPage else s.nextPage
	for offset=0,#s.pages-1 do
		if page then break end
		local candidate=s.pages[(pageCursor+offset-1)%#s.pages+1]
		-- The full-paint adapter holds each fully uploaded page while the other
		-- pages finish. New deltas retain their rows/revisions for live catch-up.
		if heldPages and heldPages[candidate.id] then continue end
		if #s.falloutReveal.regions>0 and candidate.head>#candidate.queue and s.falloutReveal:hasReadyPage(s,candidate.id) then presentation=presentation or candidate end
		if candidate.head<=#candidate.queue then
			fallback=fallback or candidate
			local key=candidate.queue[candidate.head]
			if not s.viewport or s.steps%8==0 then page=candidate; break end
			if visible(s,key) then
				foreground=foreground or candidate
				if not ownFirst or read8(s.frontQueued,key)~=0 then page=candidate; break end
				if read8(s.ownQueued,key)~=0 then ownForeground=ownForeground or candidate end
			end
		end
	end
	page=page or ownForeground or foreground or presentation or fallback
	if not page then return {pixels=0,uploads=0,ms=(os.clock()-started)*1000} end
	local selected=page :: Page
	s.job=nil
	local frontDeadline=math.min(started+budget/1000,os.clock()+math.min(1,budget*.25)/1000)
	while selected.head<=#selected.queue do
		local key=selected.queue[selected.head]
		local bx,by=key%s.columns*32,math.floor(key/s.columns)*32
		local blockHeight=math.min(32,s.height-by)
		local hasFront=read8(s.frontQueued,key)~=0
		-- Spend only a slice on narrow urgent spans, then use normal rectangles
		-- for throughput inside this same deadline. No additional frame budget.
		local frontWork=ownFirst and not background and hasFront and os.clock()<frontDeadline
		local rowStart: number?=nil
		-- Own priority must reach the rows as well as the page/block. Otherwise
		-- a fresh local pixel can still wait behind 31 unrelated enemy rows.
		for pass=1,3 do
			local rows=if pass==1 and frontWork then s.frontDirtyRows elseif pass<=2 and ownFirst and not background then s.ownDirtyRows else s.dirtyRows
			for offset=0,blockHeight-1 do
				local row=(read8(s.rowCursor,key)+offset)%blockHeight
				if band(read32(rows,key*128+row*4),read32(s.dirtyRows,key*128+row*4))~=0 then rowStart=row; break end
			end
			if rowStart~=nil then break end
		end
		if rowStart==nil then error("queued raster block has no dirty rows") end
		-- Bound the upload by currently dirty contiguous rows. Historical dirty
		-- bounds can retain already committed corners and large clean gaps.
		local union,h=0,0
		for row=rowStart,blockHeight-1 do
			local mask=read32(s.dirtyRows,key*128+row*4)
			if frontWork then mask=band(mask,read32(s.frontDirtyRows,key*128+row*4)) end
			if mask==0 then break end
			union=bit32.bor(union,mask);h+=1
		end
		local minX=bit32.countrz(union)
		local w=32-bit32.countlz(union)-minX
		local work: Job={key=key,page=selected.id,revision=read32(s.revisions,key*4),x=bx+minX,y=by+rowStart,
			width=w,height=h,cursor=0,full=read8(s.fullDirty,key)~=0,pixels=scratch(s,w,h),owners={}}
		s.job=work
		local spanMask=bit32.lshift(bit32.rshift(4294967295,32-w),minX)
		local masks: {number}={}
		local age=0
		local frontAge=-1
		local ownUpload=false
		local composeStarted=os.clock()
		while work.cursor<w*h do
			local row=work.cursor/w
			local offset=key*128+(rowStart+row)*4
			local mask=band(read32(s.dirtyRows,offset),spanMask)
			if frontWork then mask=band(mask,read32(s.frontDirtyRows,offset)) end
			masks[row+1]=mask
			if band(read32(s.ownDirtyRows,offset),mask)~=0 then ownUpload=true end
			if hasFront and band(read32(s.frontDirtyRows,offset),mask)~=0 then frontAge=math.max(frontAge,s.frames-read32(s.frontRowSince,offset)+1) end
			local first=(work.y+row)*s.width+work.x
			local sourceOffset=((work.y+row-selected.y)*selected.width+work.x-selected.x)*4
			local shade: (State,number,number,{[number]: boolean})->number=if s.overlayRows[work.y+row] then pixel elseif s.softMapEdges then mapPixel else politicalPixel
			local shaded=0
			if mask==spanMask then
				local empty=not s.softMapEdges and not s.overlayRows[work.y+row] and (s.terrainOnly or buffer.readstring(s.tileState,first*2,w*2):find("[^%z]")==nil)
				if empty then
					for col=0,w-1 do write32(work.pixels,(work.cursor+col)*4,read32(s.terrainLut,read8(s.terrain,first+col)*4)) end
					buffer.fill(s.borderFlags,first,0,w)
				else
					for col=0,w-1 do write32(work.pixels,(work.cursor+col)*4,shade(s,work.x+col,work.y+row,work.owners)) end
				end
				shaded=w
			else
				buffer.copy(work.pixels,work.cursor*4,selected.pixels,sourceOffset,w*4)
				while mask~=0 do
					local x=bit32.countrz(mask)+bx
					write32(work.pixels,(work.cursor+x-work.x)*4,shade(s,x,work.y+row,work.owners))
					mask=band(mask,mask-1); shaded+=1
				end
			end
			-- Cache foreign-border bits once per composed row. Native string
			-- search avoids adding index/mask bookkeeping to every shaded pixel.
			local previous=read32(s.relationRows,offset)
			local borders=band(previous,bit32.bnot(spanMask))
			local flags=buffer.readstring(s.borderFlags,first,w)
			local col=flags:find(FOREIGN_BORDER_PATTERN)
			while col do
				borders=bit32.bor(borders,bit32.lshift(1,minX+col-1))
				col=flags:find(FOREIGN_BORDER_PATTERN,col+1)
			end
			if borders~=previous then write32(s.relationRows,offset,borders) end
			if masks[row+1]~=0 then age=math.max(age,s.frames-read32(s.rowDirtySince,offset)+1) end
			work.cursor+=w; pixels+=shaded; s.shadedPixels+=shaded
			if pixels>=limit or (os.clock()-started)*1000>=budget then break end
		end
		s.composeMs+=(os.clock()-composeStarted)*1000
		local rows=work.cursor/w
		-- Commit every completed row now. A future revision only dirties its
		-- affected rows; it cannot erase already-displayed progress.
		local out=if rows==h then work.pixels else scratch(s,w,rows)
		if out~=work.pixels then buffer.copy(out,0,work.pixels,0,w*rows*4) end
		for row=0,rows-1 do
			buffer.copy(selected.pixels,((work.y+row-selected.y)*selected.width+work.x-selected.x)*4,out,row*w*4,w*4)
		end
		local sinkStarted=os.clock()
		local held=#s.falloutReveal.regions>0 and s.falloutReveal:holds(selected.id,work.x-selected.x,work.y-selected.y,w,rows)
		if not held then s.sink.write(selected,work.x-selected.x,work.y-selected.y,w,rows,out) end
		s.sinkMs+=(os.clock()-sinkStarted)*1000
		local sameRevision=work.revision==read32(s.revisions,key*4)
		if sameRevision then
			for row=0,rows-1 do
				local offset=key*128+(rowStart+row)*4
				local remaining=band(read32(s.dirtyRows,offset),bit32.bnot(masks[row+1]))
				write32(s.dirtyRows,offset,remaining)
				write32(s.ownDirtyRows,offset,band(read32(s.ownDirtyRows,offset),bit32.bnot(masks[row+1])))
					if hasFront then
						local remainingFront=band(read32(s.frontDirtyRows,offset),remaining)
						write32(s.frontDirtyRows,offset,remainingFront);if remainingFront==0 then write32(s.frontRowSince,offset,0) end
					end
				if remaining==0 then write32(s.rowDirtySince,offset,0) end
			end
		end
		buffer.writeu8(s.rowCursor,key,(rowStart+rows)%blockHeight)
		ownUpload=ownUpload or work.owners[s.localPlayer]==true
		local old=s.blockOwners[key]
		local full=sameRevision and minX==0 and rowStart==0 and w==math.min(32,s.width-bx) and rows==blockHeight
		if old and full then for owner in old do
			if not work.owners[owner] then s.ownerBlocks[owner][key]=nil; s.indexEntries-=1 end
		end end
		for owner in work.owners do
			local blocks=s.ownerBlocks[owner]
			if not blocks then blocks={}; s.ownerBlocks[owner]=blocks end
			if not blocks[key] then blocks[key]=true; s.indexEntries+=1 end
		end
		if old and not full then for owner in old do work.owners[owner]=true end end
		s.blockOwners[key]=work.owners
		s.paintedPixels+=w*rows
		if not held then
			s.uploadedBytes+=w*rows*4; s.uploads+=1; uploads+=1
			s.lastUploadAgeFrames=age; s.maxUploadAgeFrames=math.max(s.maxUploadAgeFrames,age)
			if visible(s,key) then recordAge(s,age,ownUpload,frontAge) end
		end
		local remains,ownRemains,frontRemains=false,false,false
		if not sameRevision then hasFront=hasFront or read8(s.frontQueued,key)~=0 end
		for row=0,blockHeight-1 do
			if read32(s.dirtyRows,key*128+row*4)~=0 then remains=true end
			if read32(s.ownDirtyRows,key*128+row*4)~=0 then ownRemains=true end
			if hasFront and band(read32(s.frontDirtyRows,key*128+row*4),read32(s.dirtyRows,key*128+row*4))~=0 then frontRemains=true end
		end
		buffer.writeu8(s.ownQueued,key,if ownRemains then 1 else 0)
		buffer.writeu8(s.frontQueued,key,if frontRemains then 1 else 0)
		selected.head+=1
		if not ownFirst and not background then s.normalCursor=(key+1)%s.blocks end
		if remains then
			-- Rotate partial blocks too: a hot block cannot pin the page or
			-- other fronts. Its next dirty row survives in rowCursor.
			table.insert(selected.queue,key)
		else
			buffer.writeu8(s.queued,key,0); buffer.writeu8(s.fullDirty,key,0); buffer.writeu8(s.ownQueued,key,0)
			write32(s.committedRevisions,key*4,read32(s.revisions,key*4))
			s.pending-=1; s.job=nil
			if visible(s,key) then s.visiblePending=math.max(0,s.visiblePending-1) end
		end
		if pixels>=limit or (os.clock()-started)*1000>=budget then break end
	end
	if #s.falloutReveal.regions>0 then
		local revealStarted=os.clock()
		local revealed=s.falloutReveal:flush(s,selected)
		s.sinkMs+=(os.clock()-revealStarted)*1000
		if revealed>0 then
			s.uploadedBytes+=revealed*4;s.uploads+=1;uploads+=1
			s.lastUploadAgeFrames=s.falloutReveal.lastDelayFrames
			s.maxUploadAgeFrames=math.max(s.maxUploadAgeFrames,s.lastUploadAgeFrames)
		end
	end
	if selected.head>#selected.queue then table.clear(selected.queue); selected.head=1;selected.initialized=true
	elseif selected.head>256 then
		local compact={}; for i=selected.head,#selected.queue do table.insert(compact,selected.queue[i]) end
		selected.queue,selected.head=compact,1
	end
	if background then s.nextBackgroundPage=selected.id%#s.pages+1
	elseif ownFirst then s.nextOwnPage=selected.id%#s.pages+1
	else s.nextPage=selected.id%#s.pages+1 end
	return {pixels=pixels,uploads=uploads,page=selected.id,ms=(os.clock()-started)*1000}
end

-- Roblox accounting for explicit buffers, separate from native image backing
-- and Lua tables. No claim about allocator/Instance/GPU overhead.
function Core.metrics(s: State): {[string]: number}
	local invalidationAge,invalidationOwnAge,invalidationBytes=s.deferred:ages(s.frames)
	local patternBytes = 0; for _, p in s.roster do if p.pattern then patternBytes += buffer.len(p.pattern.bytes) end end
	local recent,ownRecent,frontRecent={},{},{}
	local now=os.clock()
	for _,sample in s.recentAges do if now-sample.time<=2 then
		table.insert(recent,sample.age)
		if sample.ownAge>=0 then table.insert(ownRecent,sample.ownAge) end
		if sample.frontAge>=0 then table.insert(frontRecent,sample.frontAge) end
	end end
	table.sort(recent);table.sort(ownRecent);table.sort(frontRecent)
	local pendingAge,ownAge,ownPending,visiblePending=0,0,0,0
	if not s.destroyed then for key=0,s.blocks-1 do
		if read8(s.queued,key)~=0 and visible(s,key) then
			visiblePending+=1
			if read8(s.ownQueued,key)~=0 then ownPending+=1 end
			for row=0,31 do
				local offset=key*128+row*4
				if read32(s.dirtyRows,offset)~=0 then
					local age=s.frames-read32(s.rowDirtySince,offset)+1
					pendingAge=math.max(pendingAge,age)
					if read32(s.ownDirtyRows,offset)~=0 then ownAge=math.max(ownAge,age) end
				end
			end
		end
	end end
	local rowBytes=buffer.len(s.rowCursor)+buffer.len(s.rowDirtySince)+buffer.len(s.ownDirtyRows)+buffer.len(s.ownQueued)+buffer.len(s.committedRevisions)+buffer.len(s.relationRows)+buffer.len(s.frontDirtyRows)+buffer.len(s.frontQueued)+buffer.len(s.frontRowSince)
	return {pages = #s.pages, stride = 1, pendingBlocks = s.pending, paintedPixels = s.paintedPixels, uploads = s.uploads,
		falloutRevealPending=#s.falloutReveal.regions,falloutRevealCommits=s.falloutReveal.commits,
		falloutRevealHeldWrites=s.falloutReveal.heldWrites,falloutRevealFallbacks=s.falloutReveal.fallbacks,
		falloutRevealMaxPixels=s.falloutReveal.maxCommitPixels,falloutRevealPixels=s.falloutReveal.pixels,
		falloutRevealMaxDelayFrames=s.falloutReveal.maxDelayFrames,falloutRevealCommitMs=s.falloutReveal.commitMs,
		falloutRevealScratchBytes=buffer.len(s.falloutReveal.scratch),
		invalidationPendingRecords=s.deferred.count,invalidationOwnRecords=s.deferred.ownCount,
		invalidationAgeFrames=invalidationAge,invalidationOwnAgeFrames=invalidationOwnAge,
		invalidationExpandedTiles=s.deferred.expanded,invalidationFallbacks=s.deferred.fallbacks,
		invalidationBufferBytes=invalidationBytes,invalidationReservedBufferBytes=s.deferred.batchBytes,
		visiblePendingBlocks=visiblePending,lastUploadAgeFrames=s.lastUploadAgeFrames,visibleOwnPendingBlocks=ownPending,
		recentUploadP95Frames=recent[math.max(1,math.ceil(#recent*.95))] or 0,recentUploadMaxFrames=recent[#recent] or 0,
		recentOwnUploadP95Frames=ownRecent[math.max(1,math.ceil(#ownRecent*.95))] or 0,recentOwnUploadMaxFrames=ownRecent[#ownRecent] or 0,
		recentOwnFrontUploadP95Frames=frontRecent[math.max(1,math.ceil(#frontRecent*.95))] or 0,recentOwnFrontUploadMaxFrames=frontRecent[#frontRecent] or 0,
		recentOwnFrontUploadSamples=#frontRecent,
		recentUploadSamples=#recent,recentOwnUploadSamples=#ownRecent,pendingVisibleAgeFrames=pendingAge,pendingOwnVisibleAgeFrames=ownAge,
		tileUpdateGapMs=if s.lastTileTime>=0 then (now-s.lastTileTime)*1000 else -1,
		ownTileUpdateGapMs=if s.lastOwnTileTime>=0 then (now-s.lastOwnTileTime)*1000 else -1,
		rasterScratchBytes=s.scratchBytes,rasterRowMetadataBytes=rowBytes,
		shadedPixels=s.shadedPixels,rasterComposeMs=s.composeMs,rasterSinkMs=s.sinkMs,
		rasterBackingBytes=if s.destroyed then 0 else s.width*s.height*4,
		uploadedBytes = s.uploadedBytes, steps = s.steps, indexEntries = s.indexEntries, paintBytes = s.paintBytes, maxUploadAgeFrames = s.maxUploadAgeFrames,
		cpuBufferBytes = buffer.len(s.terrain) + buffer.len(s.tileState) + buffer.len(s.terrainLut) + buffer.len(s.queued)
			+ (if s.destroyed then 0 else s.width*s.height*4) + invalidationBytes + buffer.len(s.borderFlags) + buffer.len(s.dirtyRows) + buffer.len(s.fullDirty)
			+ buffer.len(s.revisions) + buffer.len(s.dirtyBounds) + buffer.len(s.dirtySince) + buffer.len(s.relations) + s.scratchBytes + s.paintBytes + patternBytes+rowBytes+buffer.len(s.falloutReveal.scratch),
		imagePixelBytes = if s.destroyed then 0 else s.width * s.height * 4}
end

-- Original TerrainPass.dispose, plus all CPU state owned by this controller.
function Core.destroy(s: State)
	if s.destroyed then return end
	s.destroyed = true; s.sink.destroy()
	s.deferred:clear()
	s.falloutReveal:clear()
	s.job = nil; s.palette = {}; s.roster = {}; s.paints = {}; s.scratch = {}; s.ownerBlocks = {}; s.blockOwners = {}; s.pages = {}
	table.clear(s.recentAges); s.recentCursor=0; s.lastTileTime,s.lastOwnTileTime=-1,-1
	table.clear(s.trails); table.clear(s.spawnDiscs); table.clear(s.overlayRows)
	for _, pool in {s.theme.human, s.theme.nation, s.theme.bot} do table.clear(pool.available); table.clear(pool.fallback); table.clear(pool.assigned); table.clear(pool.order) end
	table.clear(s.theme.teamPalettes); table.clear(s.theme.teamPlayerColors)
	s.paintBytes, s.scratchBytes, s.indexEntries = 0, 0, 0
	s.terrain = buffer.create(0); s.tileState = buffer.create(0); s.terrainLut = buffer.create(0)
	s.borderFlags=buffer.create(0); s.relationRows=buffer.create(0); s.dirtyRows=buffer.create(0); s.fullDirty=buffer.create(0)
	s.rowCursor=buffer.create(0);s.rowDirtySince=buffer.create(0);s.ownQueued=buffer.create(0);s.committedRevisions=buffer.create(0)
	s.ownDirtyRows=buffer.create(0)
	s.frontDirtyRows=buffer.create(0);s.frontQueued=buffer.create(0);s.frontRowSince=buffer.create(0)
	s.queued = buffer.create(0); s.revisions = buffer.create(0); s.dirtyBounds = buffer.create(0); s.dirtySince = buffer.create(0); s.relations = buffer.create(0); s.pending = 0
end

return Core
