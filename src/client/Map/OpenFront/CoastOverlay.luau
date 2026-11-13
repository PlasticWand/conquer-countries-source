--!strict
-- Thin native adapter around immutable coast geometry and sparse colour work.
-- Native API injection lets the same lifecycle run under the map test shims.
local Geometry=require(script.Parent.CoastGeometry)
local Raster=require(script.Parent.CoastRaster)
local Camera=require(script.Parent.CameraTransform)
local Policy=require(script.Parent.RenderPolicy)
local Coast={}
Coast.__index=Coast
function Coast.new(renderer: any,api: any,touch: boolean): any
	local resolution=if touch then Policy.coastTouchResolution else Policy.coastDesktopResolution
	return setmetatable({renderer=renderer,api=api,touch=touch,resolution=resolution,
		builder=Geometry.new(renderer.core.terrain,renderer.core.width,renderer.core.height,resolution),
		raster=nil,failed=false,invalidated=false,views={},pool={},wanted={},cameraDirty=true,
		uploadMs=0,visible=0,creates=0,deletes=0,viewCount=0,destroyed=false},Coast)
end
function Coast.build(self: any,loading: boolean)
	if self.failed or self.raster or self.destroyed then return end
	Geometry.step(self.builder,if loading then Policy.coastLoadMs else Policy.coastBuildMs,if loading then 131072 else 8192)
	if not self.builder.done then return end
	self.raster=Raster.new(self.builder.geometry,self.resolution,
		if self.touch then Policy.coastTouchPixelBytes else Policy.coastDesktopPixelBytes)
	if not self.raster then self.failed=true end
end
function Coast.mark(self: any,page: any,x: number,y: number,w: number,h: number)
	if self.raster and not self.failed then Raster.mark(self.raster,page.x+x,page.y+y,w,h) end
end
local function upload(self: any,work: any)
	local api,r=self.api,self.raster
	local page=r.pages[work.page]
	if not page.image then
		page.image=api.allocate(api.Vector2.new(page.width,page.height))
		assert(page.image,'coast image allocation refused')
	end
	if work.pixels then
		page.image:WritePixelsBuffer(api.Vector2.new(work.x,work.y),api.Vector2.new(work.w,work.h),work.pixels)
		r.uploadedPixels+=work.w*work.h; r.uploads+=1
	else
		r.scratch=r.scratch or {}
		r.scratchOrder=r.scratchOrder or {}
		for _,rect in work.writes do
			local key=rect.w*1024+rect.h
			local scratch=r.scratch[key]
			if not scratch then
				if #r.scratchOrder>=4 then
					local old=table.remove(r.scratchOrder,1); r.scratchBytes-=buffer.len(r.scratch[old]); r.scratch[old]=nil
				end
				scratch=buffer.create(rect.w*rect.h*4); r.scratch[key]=scratch; r.scratchBytes+=buffer.len(scratch); table.insert(r.scratchOrder,key)
			end
			for row=0,rect.h-1 do buffer.copy(scratch,row*rect.w*4,page.pixels,((rect.y+row)*page.width+rect.x)*4,rect.w*4) end
			page.image:WritePixelsBuffer(api.Vector2.new(rect.x,rect.y),api.Vector2.new(rect.w,rect.h),scratch)
			r.uploadedPixels+=rect.w*rect.h; r.uploads+=1
		end
	end
	if not page.content then page.content=api.Content.fromObject(page.image); self.cameraDirty=true end
end
function Coast.prepare(self: any,loading: boolean): boolean
	if self.failed or not self.raster or self.destroyed then return false end
	local r=self.raster
	local work=Raster.prepare(r,self.renderer.core,if loading then Policy.coastLoadMs else Policy.coastComposeMs,
		if loading then 4096 elseif self.touch then Policy.coastTouchCellsPerFrame else Policy.coastDesktopCellsPerFrame,
		if self.touch then 65536 else 131072,if self.touch then 32 else 64,
		loading and self.renderer.firstPaintBaseReady==true)
	if not work then return false end
	local started=os.clock()
	local ok=pcall(upload,self,work)
	self.uploadMs+=(os.clock()-started)*1000
	if not ok then
		-- Coast art is optional; keep the complete source raster on refusal.
		self.failed=true
		if self.root then self.root.Visible=false end
		for _,page in r.pages do if page.image then page.image:Destroy(); page.image=nil end; page.pixels=nil; page.content=nil end
		return false
	end
	return true
end
function Coast.ready(self: any): boolean
	return self.failed or (self.raster~=nil and not Raster.pending(self.raster) and not self.viewsPending)
end
function Coast.setCamera(self: any)
	self.cameraDirty=true
	if not self.root then return end
	local c=self.renderer.camera
	local x,y=Camera.worldToScreenCoordinates(c,0,0)
	local pos=self.api.UDim2.fromScale((x-c.left)/c.viewportWidth,(y-c.top)/c.viewportHeight)
	if self.root.Position~=pos then self.root.Position=pos end
	if self.scale.Scale~=c.scale/64 then self.scale.Scale=c.scale/64 end
end
local function root(self: any)
	if self.root then return end
	local api=self.api
	local f=api.Instance.new('Frame')
	f.Name,f.BackgroundTransparency,f.BorderSizePixel,f.ZIndex='StaticCoasts',1,0,1
	f.Size=api.UDim2.fromOffset(self.renderer.core.width*64,self.renderer.core.height*64)
	f.ClipsDescendants=true; f.Parent=self.renderer.root
	local scale=api.Instance.new('UIScale'); scale.Parent=f
	self.root,self.scale=f,scale; self:setCamera()
end
function Coast.stepViews(self: any,budget: number): number
	if self.failed or self.destroyed or not self.raster then return 0 end
	local now,c=(self.api.now or os.clock)(),self.renderer.camera
	local active=c.scale>=Policy.coastMinScale
	local crossing=self.active~=active
	self.active=active
	if self.root then self.root.Visible=active end
	if not self.cameraDirty and not self.viewsPending then return 0 end
	local cull=self.cameraDirty and (crossing or now-(self.lastCull or -1)>=.1 or not self.renderer.ready)
	if not cull and not self.viewsPending then return 0 end
	if cull then
		self.lastCull=now; self.cameraDirty=false; self.wanted={}; self.limited=0
		if active then
			local x0,y0=Camera.screenToWorldCoordinatesFloat(c,c.left,c.top)
			local x1,y1=Camera.screenToWorldCoordinatesFloat(c,c.left+c.viewportWidth,c.top+c.viewportHeight)
			local candidates={}
			for id,chunk in self.raster.geometry.chunks do
				if chunk.x<x1 and chunk.y<y1 and chunk.x+Geometry.chunk>x0 and chunk.y+Geometry.chunk>y0 then
					table.insert(candidates,{id=id,d=(chunk.x+Geometry.chunk/2-(x0+x1)/2)^2+(chunk.y+Geometry.chunk/2-(y0+y1)/2)^2})
				end
			end
			table.sort(candidates,function(a,b) return if a.d==b.d then a.id<b.id else a.d<b.d end)
			local maxViews=if self.touch then Policy.coastTouchViews else Policy.coastDesktopViews
			self.limited=math.max(0,#candidates-maxViews)
			for i=1,math.min(#candidates,maxViews) do self.wanted[candidates[i].id]=true end
		end
	end
	local removed=0
	for id,view in self.views do if not self.wanted[id] and removed<Policy.coastDeletesPerFrame then
		view.Visible=false;view.Parent=nil;self.views[id]=nil;self.viewCount-=1;table.insert(self.pool,view);removed+=1
	end end
	-- Retain the already-paid high water within the existing total view cap.
	-- Spares are unparented, so camera transforms do not touch their GUI tree.
	-- The old 32-spare limit destroyed/recreated hundreds on repeated zooms.
	local cap=if self.touch then Policy.coastTouchViews else Policy.coastDesktopViews
	for _=1,math.min(Policy.coastDeletesPerFrame-removed,math.max(0,#self.pool-math.max(0,cap-self.viewCount))) do
		local view: any=table.remove(self.pool); view:Destroy(); self.deletes+=1
	end
	local used=0; local pending=false
	for id in self.wanted do
		local view=self.views[id]
		if not view then
			if used>=budget then pending=true; continue end
			local slot=self.raster.slots[id]; local page=self.raster.pages[slot.page]
			if not page.content then pending=true; continue end
			root(self)
			local api=self.api; view=table.remove(self.pool)
			if not view then
				if self.viewCount>=cap then pending=true;continue end
				view=api.Instance.new('ImageLabel');self.creates+=1
			end
			view.Name,view.BackgroundTransparency,view.BorderSizePixel,view.ZIndex='CoastPatch',1,0,1
			view.ImageContent=page.content; view.ResampleMode=api.Enum.ResamplerMode.Default
			view.ImageRectOffset=api.Vector2.new(slot.x,slot.y)
			view.ImageRectSize=api.Vector2.new(Geometry.chunk*self.resolution,Geometry.chunk*self.resolution)
			local chunk=self.raster.geometry.chunks[id]
			view.Position=api.UDim2.fromOffset(chunk.x*64,chunk.y*64)
			view.Size=api.UDim2.fromOffset(Geometry.chunk*64,Geometry.chunk*64)
			view.Parent=self.root;view.Visible=true;self.views[id]=view;self.viewCount+=1;used+=1
		end
	end
	local visible=0
	for id in self.views do if not self.wanted[id] then pending=true elseif active then visible+=1 end end
	self.viewsPending=pending; self.visible=visible
	return used
end
function Coast.invalidate(self: any)
	self.failed,self.invalidated=true,true
	if self.root then self.root.Visible=false end
	if self.raster then
		for _,page in self.raster.pages do
			if page.image then page.image:Destroy() end
			page.image,page.content,page.pixels=nil,nil,nil
		end
	end
end
function Coast.metrics(self: any): {[string]: number}
	local g=self.builder.geometry
	local r=self.raster
	local native=0
	if r then for _,page in r.pages do if page.image then native+=page.width*page.height*4 end end end
	return {coastResolution=self.resolution,coastBuildMs=self.builder.buildMs,coastCacheHit=if self.builder.cacheHit then 1 else 0,
		coastGeometryBytes=if g then Geometry.bytes(g) else buffer.len(self.builder.mask),coastCacheBytes=Geometry.cacheBytes(),
		coastCpuBufferBytes=if r then Raster.bytes(r) else 0,coastNativePixelBytes=native,coastUploadMs=self.uploadMs,
		coastCells=if g then g.count else 0,coastChunks=if g then #g.chunks else 0,
		coastComposeMs=if r then r.composeMs else 0,coastComposedCells=if r then r.composed else 0,
		coastUnchangedCells=if r then r.skipped else 0,
		coastUploadedPixels=if r then r.uploadedPixels else 0,coastUploadCalls=if r then r.uploads else 0,
		coastVisiblePatches=self.visible,coastViewCreates=self.creates,coastViewDeletes=self.deletes,coastSpareViews=#self.pool,
		coastAttachedPatches=self.viewCount,coastRetainedPatches=self.viewCount+#self.pool,
		coastViewLimitFallback=self.limited or 0,
		coastFailed=if self.failed then 1 else 0,coastInvalidated=if self.invalidated then 1 else 0}
end
function Coast.destroy(self: any)
	if self.destroyed then return end
	self.destroyed=true
	if self.root then self.root:Destroy(); self.root=nil end
	for _,view in self.pool do view:Destroy() end
	if self.raster then
		for _,page in self.raster.pages do if page.image then page.image:Destroy() end; page.image,page.content,page.pixels=nil,nil,nil end
	end
	self.builder,self.raster=nil,nil
	self.views,self.pool,self.wanted={},{},{}
	self.viewCount,self.visible=0,0
end
return Coast
