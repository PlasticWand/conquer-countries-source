--!strict
-- Ported from OpenFront v0.35.2 (resources/atlases/icon-atlas.png; resources/atlases/unit-atlas.png; src/client/render/gl/shaders/structure/structure.frag.glsl; src/client/render/gl/shaders/unit/unit.frag.glsl), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- OpenFront resources artwork: CC BY-SA 4.0, credit OpenFront. A bounded,
-- reference-counted cache combines the existing rim/fill/glyph into one GUI.
local Atlas = require(script.Parent.SpriteAtlas)
local Cache = {}
Cache.__index = Cache
Cache.cell, Cache.columns, Cache.size = 66, 15, 990
local templates: {[number]: buffer} = {}
local source: buffer? = nil
-- Reuse the base-atlas decode performed under the loading cover. Avoid a
-- second Base64/mask decode on the first live cache miss.
function Cache.setSource(pixels: buffer)
	if not source then source=pixels end
end

local function distance(column: number, x: number, y: number): number
	if column == 7 then return math.abs(x)+math.abs(y) end -- original Artillery diamond
	if column==6 or column==8 or column==9 or column==10 then return Atlas.arsenalDistance(column,x,y) end
	if column == 0 then return math.sqrt(x*x+y*y) end
	if column == 4 then return math.max(math.abs(x),math.abs(y)) * math.sqrt(2) end
	local sides = if column == 1 then 5 elseif column == 2 then 6 elseif column == 3 then 8 else 3
	local rotation = if column == 1 or column == 5 then math.pi/2 elseif column == 2 then math.pi/6 else 0
	local half = math.pi/sides
	local angle = (math.atan2(y,x)-rotation+half)%(2*half)-half
	return math.sqrt(x*x+y*y)*math.cos(angle)/math.cos(half)
end
local function template(column: number, dots: boolean): buffer
	local key=column*2+(if dots then 1 else 0)
	if templates[key] then return templates[key] end
	if not source then source=Atlas.rgba() end
	local original=source :: buffer
	local glyphX,glyphY,glyphW,glyphH=Atlas.iconRect(column)
	local out=buffer.create(64*64*4)
	for y=0,63 do for x=0,63 do
		local px,py=(x+.5)/64-.5,(y+.5)/64-.5
		local d=distance(column,px,py)
		local outer=math.clamp((.45-d)*64+.5,0,1)
		local inner=math.clamp((.45*.86-d)*64+.5,0,1)
		local glyph=0
		if not dots and math.abs(px)<.35 and math.abs(py)<.35 then
			local gx,gy=(px/.7+.5)*glyphW-.5,(py/.7+.5)*glyphH-.5
			local ix,iy=math.floor(gx),math.floor(gy)
			local fx,fy=gx-ix,gy-iy
			for dy=0,1 do for dx=0,1 do
				local sx,sy=math.clamp(ix+dx,0,glyphW-1),math.clamp(iy+dy,0,glyphH-1)
				glyph+=buffer.readu8(original,((glyphY+sy)*Atlas.width+glyphX+sx)*4+3)/255
					*(if dx==0 then 1-fx else fx)*(if dy==0 then 1-fy else fy)*.9
			end end
		end
		local off=(y*64+x)*4
		buffer.writeu8(out,off,math.floor(inner*(1-glyph)*255+.5))
		buffer.writeu8(out,off+1,math.floor((1-inner)*(1-glyph)*255+.5))
		buffer.writeu8(out,off+2,math.floor(glyph*255+.5))
		buffer.writeu8(out,off+3,math.floor(outer*255+.5))
	end end
	templates[key]=out
	return out
end

function Cache.new(maxPages: number, allocate: () -> any, write: (any, number, number, buffer) -> ()): any
	return setmetatable({maxPages=maxPages,cell=Cache.cell,columns=Cache.columns,allocate=allocate,write=write,pages={},entries={},slots={},queue={},head=1,clock=0},Cache)
end
function Cache.release(_: any, entry: any)
	if entry then entry.refs-=1; assert(entry.refs>=0,'structure cache reference underflow') end
end
local function acquire(self: any, key: string, column: number, dots: boolean, fill: Color3, edge: Color3): any
	if self.failed then return nil end
	self.clock+=1
	local entry=self.entries[key]
	if entry then
		entry.refs+=1; entry.used=self.clock
		if not entry.ready and not entry.queued then entry.queued=true; table.insert(self.queue,entry) end
		return entry
	end
	if #self.slots < self.maxPages*self.columns^2 then
		entry={slot=#self.slots,refs=0}; table.insert(self.slots,entry)
	else
		for _,candidate in self.slots do
			if candidate.refs==0 and (not entry or candidate.used<entry.used) then entry=candidate end
		end
		if not entry then return nil end -- keep the original layered view
		self.entries[entry.key]=nil
	end
	entry.key,entry.column,entry.dots,entry.fill,entry.edge=key,column,dots,fill,edge
	entry.refs,entry.used,entry.ready=1,self.clock,false
	entry.page=math.floor(entry.slot/self.columns^2)+1
	entry.x,entry.y=entry.slot%self.columns*self.cell,math.floor(entry.slot%self.columns^2/self.columns)*self.cell
	self.entries[key]=entry
	if not entry.queued then entry.queued=true; table.insert(self.queue,entry) end
	return entry
end
function Cache.acquire(self: any, column: number, dots: boolean, fill: Color3, edge: Color3): any
	return acquire(self,`{column}:{dots}:{fill}:{edge}`,column,dots,fill,edge)
end
-- Four source unit masks, composited once per changed palette/state. The
-- 13px source resolution is intentional; mobiles retain OpenFront pixel art.
function Cache.newMobile(allocate: () -> any, write: (any, number, number, buffer) -> ()): any
	local self=Cache.new(1,allocate,write)
	self.mobile,self.cell,self.columns=true,15,32
	return self
end
function Cache.acquireMobile(self: any, column: number, colors: {Color3}): any
	-- Use the same bounded, ref-counted eviction and pending-upload lifecycle.
	local key=`{column}:{colors[1]}:{colors[2]}:{colors[3]}:{colors[4]}`
	local entry=acquire(self,key,column,false,colors[1],colors[4])
	if entry then entry.colors=colors end
	return entry
end
local function mobilePixels(entry: any): buffer
	if not source then source=Atlas.rgba() end
	local pixels=buffer.create(15*15*4)
	for y=0,12 do for x=0,12 do
		local r,g,b,a=0,0,0,0
		for band=0,3 do
			local alpha=buffer.readu8(source :: buffer,((band*13+y)*Atlas.width+entry.column*13+x)*4+3)/255
			local c=entry.colors[band+1]
			r,g,b=c.R*alpha+r*(1-alpha),c.G*alpha+g*(1-alpha),c.B*alpha+b*(1-alpha)
			a=alpha+a*(1-alpha)
		end
		if a>0 then
			local off=((y+1)*15+x+1)*4
			buffer.writeu8(pixels,off,math.clamp(math.floor(r/a*255+.5),0,255))
			buffer.writeu8(pixels,off+1,math.clamp(math.floor(g/a*255+.5),0,255))
			buffer.writeu8(pixels,off+2,math.clamp(math.floor(b/a*255+.5),0,255))
			buffer.writeu8(pixels,off+3,math.floor(a*255+.5))
		end
	end end
	return pixels
end
function Cache.prepare(self: any, budgetMs: number): boolean
	while self.queue[self.head] and self.queue[self.head].refs==0 do
		self.queue[self.head].queued=false; self.head+=1
	end
	local first=self.queue[self.head]
	if not first then table.clear(self.queue); self.head=1; return false end
	local started=os.clock()
	local pageId=first.page
	local page=self.pages[pageId]
	if not page then
		local ok,result=pcall(self.allocate)
		if not ok or not result then
			-- This cache is optional acceleration. Keep the complete layered
			-- source icons when a device cannot allocate an additional page.
			self.failed=true
			for i=self.head,#self.queue do self.queue[i].queued=false end
			table.clear(self.queue); self.head=1
			return false
		end
		page=result; self.pages[pageId]=page
	end
	local count=0
	while self.head<=#self.queue do
		local entry=self.queue[self.head]
		if entry.refs==0 then entry.queued=false; self.head+=1; continue end
		if entry.page~=pageId then break end
		if self.mobile then
			self.write(page,entry.x,entry.y,mobilePixels(entry))
			entry.ready,entry.queued=true,false; self.head+=1; count+=1
			if count>=32 or (os.clock()-started)*1000>=budgetMs then break end
			continue
		end
		local weights=template(entry.column,entry.dots)
		local pixels=buffer.create(Cache.cell*Cache.cell*4)
		local fill,edge=entry.fill,entry.edge
		local glyph=if fill.R*.299+fill.G*.587+fill.B*.114<.25 then {1,1,1} else {fill.R*.3,fill.G*.3,fill.B*.3}
		local solidFill=math.floor(fill.R*255+.5)+math.floor(fill.G*255+.5)*256+math.floor(fill.B*255+.5)*65536
		local solidEdge=math.floor(edge.R*255+.5)+math.floor(edge.G*255+.5)*256+math.floor(edge.B*255+.5)*65536
		for y=0,63 do for x=0,63 do
			local off=(y*64+x)*4
			local alpha=buffer.readu8(weights,off+3)
			if alpha==0 then continue end
			local f,b,g=buffer.readu8(weights,off),buffer.readu8(weights,off+1),buffer.readu8(weights,off+2)
			local target=((y+1)*Cache.cell+x+1)*4
			local rgb
			if f==255 then rgb=solidFill elseif b==255 then rgb=solidEdge
			else
				local r=math.clamp(math.floor(f*fill.R+b*edge.R+g*glyph[1]+.5),0,255)
				local green=math.clamp(math.floor(f*fill.G+b*edge.G+g*glyph[2]+.5),0,255)
				local blue=math.clamp(math.floor(f*fill.B+b*edge.B+g*glyph[3]+.5),0,255)
				rgb=r+green*256+blue*65536
			end
			buffer.writeu32(pixels,target,rgb+alpha*16777216)
		end end
		self.write(page,entry.x,entry.y,pixels)
		entry.ready,entry.queued=true,false; self.head+=1; count+=1
		if count>=8 or (os.clock()-started)*1000>=budgetMs then break end
	end
	if self.head>#self.queue then table.clear(self.queue); self.head=1 end
	return true
end
function Cache.destroy(self: any)
	for _,page in self.pages do page.image:Destroy() end
	table.clear(self.pages); table.clear(self.entries); table.clear(self.slots); table.clear(self.queue)
end
return Cache
