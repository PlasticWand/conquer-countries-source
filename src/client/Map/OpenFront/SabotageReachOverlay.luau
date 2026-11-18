--!strict
-- Original Conquest map-only aim aid. One cached, bounded mask; all native
-- writes run through EditableRenderer's shared image slot, never the preview's callback.
local Reach = require(script.Parent.SabotageReach)
local Camera = require(script.Parent.CameraTransform)
local Sabotage = require(game:GetService('ReplicatedStorage').Shared.OpenFront.Executions.SabotageExecution)
local Overlay = {}
Overlay.__index = Overlay

function Overlay.new(renderer:any,parent:Frame):any
	local core=renderer.core
	return setmetatable({renderer=renderer,parent=parent,owner=0,reach=nil,
		cache=Reach.new(core.width,core.height,function(tile:number):number
			return bit32.band(buffer.readu16(core.tileState,tile*2),4095)
		end),uploads=0,uploadBytes=0,maxUploadMs=0,failed=false,shown=false},Overlay)
end
function Overlay.setAim(self:any,owner:number,reach:number?)
	if self.owner==owner and self.reach==reach then return end
	local reset=self.owner~=owner or (reach~=nil and self.cache.reach~=reach)
	self.owner,self.reach=owner,reach
	self.cache:prewarm(owner,reach or (if self.cache.reach>0 then self.cache.reach else Sabotage.REACH))
	self.cache:setActive(owner,reach)
	if reset then self.shown=false end
	if self.view then self.view.Visible=reach~=nil and self.shown end
end
function Overlay.tilesChanged(self:any,tiles:{number}?)
	self.cache:tilesChanged(tiles)
	if not tiles then self.shown=false;if self.view then self.view.Visible=false end end
end
function Overlay.setCamera(self:any)
	if not self.view then return end
	local c,core=self.renderer.camera,self.renderer.core
	local x,y=Camera.worldToScreenCoordinates(c,0,0)
	self.view.Position=UDim2.fromOffset(x-c.left,y-c.top)
	self.view.Size=UDim2.fromOffset(core.width*c.scale,core.height*c.scale)
end

-- Called even when another pass owns the upload slot: CPU slices are bounded
-- independently, while every fourth busy raster frame allows this aim to progress.
function Overlay.prepare(self:any,canUpload:boolean):boolean
	local cache=self.cache
	if self.failed then return false end
	cache:step()
	if not cache.active or not canUpload then return false end
	local y,h=cache:nextUpload()
	if y==nil or h==nil then return false end
	if not self.image then
		local ok,img=pcall(function()
			return game:GetService('AssetService'):CreateEditableImage({Size=Vector2.new(cache.mw,cache.mh)})
		end)
		if not ok or not img then self.failed=true;return false end
		self.image=img
		local view=Instance.new('ImageLabel')
		view.Name,view.BackgroundTransparency,view.BorderSizePixel,view.ZIndex='SabotageReach',1,0,3
		view.ImageContent=Content.fromObject(img)
		view.ResampleMode=Enum.ResamplerMode.Default
		view.Visible=false;view.Parent=self.parent;self.view=view
		self:setCamera()
	end
	local size=cache.mw*h*4
	if not self.scratch or buffer.len(self.scratch)~=size then self.scratch=buffer.create(size) end
	local start=os.clock()
	buffer.copy(self.scratch,0,cache.pixels,y*cache.mw*4,size)
	self.image:WritePixelsBuffer(Vector2.new(0,y),Vector2.new(cache.mw,h),self.scratch)
	self.maxUploadMs=math.max(self.maxUploadMs,(os.clock()-start)*1000)
	self.uploads+=1;self.uploadBytes+=size;cache:uploaded(y)
	if cache:presentable() then self.shown=true;self.view.Visible=true end
	return true
end
function Overlay.metrics(self:any):{[string]:number}
	local c=self.cache
	return {sabotageReachStepMaxMs=c.maxStepMs,sabotageReachCpuMs=c.cpuMs,sabotageReachWork=c.work,
		sabotageReachBorderEntries=c.borderEntries,
		sabotageReachQueueRows=math.max(0,#c.borderQueue-c.borderHead+1)+math.max(0,#c.maskQueue-c.maskHead+1),
		sabotageReachBorderRows=c.scans,sabotageReachMaskRows=c.maskBuilds,
		sabotageReachPending=if c:pending() then 1 else 0,sabotageReachUploads=self.uploads,
		sabotageReachUploadBytes=self.uploadBytes,sabotageReachUploadMaxMs=self.maxUploadMs,
		sabotageReachBufferBytes=(if c.pixels then buffer.len(c.pixels) else 0)+(if self.scratch then buffer.len(self.scratch) else 0),
		sabotageReachImagePixelBytes=if self.image then c.mw*c.mh*4 else 0,
		sabotageReachFailed=if self.failed then 1 else 0}
end
function Overlay.destroy(self:any)
	self.cache:destroy()
	if self.view then self.view:Destroy();self.view=nil end
	if self.image then self.image:Destroy();self.image=nil end
	self.scratch=nil
end
return Overlay
