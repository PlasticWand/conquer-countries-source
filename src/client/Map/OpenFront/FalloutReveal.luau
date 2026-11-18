--!strict
-- Bounded presentation staging for confirmed fallout bursts. RasterCore's
-- retained RGBA pages are the staging buffers; no second native image exists.
local Reveal = {}
Reveal.__index = Reveal
type Region = {page: number, x: number, y: number, w: number, h: number, since: number, batch: number}

function Reveal.new(enabled: boolean, maxPixels: number, capacity: number): any
	return setmetatable({enabled=enabled,maxPixels=maxPixels,capacity=capacity,regions={},
		scratch=buffer.create(0),commits=0,pixels=0,maxCommitPixels=0,heldWrites=0,
		fallbacks=0,maxDelayFrames=0,lastDelayFrames=0,commitMs=0,sequence=0,presentingBatch=nil},Reveal)
end

function Reveal.begin(self:any):number
	self.sequence+=1;return self.sequence
end

local function overlaps(a: Region,x: number,y: number,w: number,h: number): boolean
	return a.x<x+w and x<a.x+a.w and a.y<y+h and y<a.y+a.h
end

-- Block-aligned rectangles contain every suppressed row upload, including
-- the ownership-border halo. Page edges are aligned to the same 32-tile grid.
function Reveal.add(self:any,page:any,x0:number,y0:number,x1:number,y1:number,frame:number,batch:number?)
	if not self.enabled then return end
	local cohort=batch or self:begin()
	local x=math.max(0,math.floor((x0-page.x-2)/32)*32)
	local y=math.max(0,math.floor((y0-page.y-2)/32)*32)
	local right=math.min(page.width,math.ceil((x1-page.x+2)/32)*32)
	local bottom=math.min(page.height,math.ceil((y1-page.y+2)/32)*32)
	local w,h=right-x,bottom-y
	if w*h>self.maxPixels then self.fallbacks+=1; return end
	for _,r in self.regions do
		if r.page==page.id and overlaps(r,x,y,w,h) then
			local xx,yy=math.min(x,r.x),math.min(y,r.y)
			local ww,hh=math.max(right,r.x+r.w)-xx,math.max(bottom,r.y+r.h)-yy
			if ww*hh<=self.maxPixels then
				local previous=r.batch
				for _,other in self.regions do if other.batch==previous then other.batch=cohort end end
				if self.presentingBatch==previous then self.presentingBatch=nil end
				r.x,r.y,r.w,r.h=xx,yy,ww,hh;return
			end
		end
	end
	if #self.regions>=self.capacity then self.fallbacks+=1;return end
	table.insert(self.regions,{page=page.id,x=x,y=y,w=w,h=h,since=frame,batch=cohort})
end

function Reveal.holds(self:any,page:number,x:number,y:number,w:number,h:number): boolean
	for _,r in self.regions do
		if r.page==page and overlaps(r,x,y,w,h) then self.heldWrites+=1;return true end
	end
	return false
end

local function clean(core:any,r:Region):boolean
	local page=core.pages[r.page]
	for y=page.y+r.y,page.y+r.y+r.h-1,32 do
		for x=page.x+r.x,page.x+r.x+r.w-1,32 do
			local key=math.floor(y/32)*core.columns+math.floor(x/32)
			if buffer.readu8(core.queued,key)~=0 then return false end
		end
	end
	return true
end

local function cohortReady(self:any,core:any,batch:number):boolean
	if core.deferred.count>0 then return false end
	for _,r in self.regions do if r.batch==batch and not clean(core,r) then return false end end
	return true
end

function Reveal.hasReadyPage(self:any,core:any,page:number):boolean
	for _,r in self.regions do if r.page==page and cohortReady(self,core,r.batch) then return true end end
	return false
end

function Reveal.readyPage(self:any,core:any):number?
	for _,r in self.regions do if cohortReady(self,core,r.batch) then return r.page end end
	return nil
end

function Reveal.nextPage(self:any,core:any):number?
	if not self.presentingBatch then return nil end
	-- New traffic can dirty a prepared piece between native image slots.
	-- Release priority until the cohort catches up; never pin other pages.
	if cohortReady(self,core,self.presentingBatch) then
		for _,r in self.regions do if r.batch==self.presentingBatch then return r.page end end
	end
	self.presentingBatch=nil;return nil
end

-- At most capacity^2 * (maxPixels / 32^2) block checks; no per-tile scan.
-- Deferred invalidation must be expanded before zero dirty blocks is final.
function Reveal.flush(self:any,core:any,page:any): number
	if core.deferred.count>0 then return 0 end
	for index,r in self.regions do
		if r.page~=page.id then continue end
		if self.presentingBatch and r.batch~=self.presentingBatch then continue end
		if not cohortReady(self,core,r.batch) then continue end
		local started=os.clock()
		local bytes=r.w*r.h*4
		if buffer.len(self.scratch)~=bytes then self.scratch=buffer.create(bytes) end
		for row=0,r.h-1 do
			buffer.copy(self.scratch,row*r.w*4,page.pixels,((r.y+row)*page.width+r.x)*4,r.w*4)
		end
		-- Remove before invoking the sink, so a reentrant new confirmed burst
		-- gets its own gate. Never clear dirty masks/revisions here.
		self.presentingBatch=r.batch;table.remove(self.regions,index)
		core.sink.write(page,r.x,r.y,r.w,r.h,self.scratch)
		local pixels=bytes/4
		self.commits+=1;self.pixels+=pixels;self.maxCommitPixels=math.max(self.maxCommitPixels,pixels)
		self.lastDelayFrames=core.frames-r.since
		self.maxDelayFrames=math.max(self.maxDelayFrames,self.lastDelayFrames)
		self.commitMs+=(os.clock()-started)*1000
		return pixels
	end
	return 0
end

function Reveal.clear(self:any)
	table.clear(self.regions);self.scratch=buffer.create(0);self.presentingBatch=nil
end

return Reveal
