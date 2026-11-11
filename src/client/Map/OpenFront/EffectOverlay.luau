--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/passes/fx-pass/index.ts; WorldTextPass.ts; SpawnOverlayPass.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Native text, 64px spawn masks and UIStroke shockwaves approximate GL edges.
local Atlas = require(script.Parent.FxAtlas)
local Fx = require(script.Parent.FxState)
local Spawn = require(script.Parent.SpawnOverlay)
local Camera = require(script.Parent.CameraTransform)
local Policy = require(script.Parent.RenderPolicy)
local Masks = require(script.Parent.FalloutMasks)
local ShipArt = require(script.Parent.ShipArt)
local Core = require(script.Parent.RasterCore)
local Effects = {}
Effects.__index = Effects

local function layer(parent: Instance, name: string, z: number): Frame
	local f = Instance.new('Frame')
	f.Name,f.Size,f.BackgroundTransparency,f.BorderSizePixel,f.ZIndex = name,UDim2.fromScale(1,1),1,0,z
	f.Parent = parent
	return f
end
function Effects.new(renderer: any, world: Frame?, worldUnit: number?): any
	local function parent(pass: string): Frame
		return if renderer.guiLayers and renderer.guiLayers.enabled then renderer.guiLayers:parent(pass) else world or renderer.root
	end
	local touch=game:GetService('UserInputService').TouchEnabled==true
	local maskCap=if touch then Policy.falloutTouchMasks else Policy.falloutDesktopMasks
	local options={spriteCap=if touch then Policy.falloutTouchSprites else Policy.falloutDesktopSprites,maskCap=maskCap,
		warshipSmoke=Policy.smoothShips,
		defenseExplosionScale=Policy.defenseExplosionScale,defenseSmokeLifetimeMs=Policy.defenseSmokeLifetimeMs,falloutLifetimeMs=Policy.falloutLifetimeMs,
		stagedConquests=true}
	return setmetatable({renderer = renderer, world = world, worldUnit=worldUnit or 1, state = Fx.new(renderer.core.width,options), atlas = nil, content = nil,
		spawn = layer(parent('SpawnGlow'),'SpawnGlow',2), fx = layer(parent('Effects'),'Effects',8), text = layer(parent('WorldText'),'WorldText',14),
		falloutLayer=layer(parent('FalloutGlow'),'FalloutGlow',3),
		masks=Masks.new(renderer.core.width,renderer.core.height,Policy.falloutMaskSize,maskCap,Policy.falloutLifetimeMs),
		maskViews={},maskColumns=if touch then 2 else 4,prepareFrame=0,maskUploads=0,
		sprites = {}, sinkingViews={}, rings = {}, popups = {}, glows = {}, centers = {}, destroyed = false},Effects)
end

function Effects.falloutTilesChanged(self:any,tiles:{number}?)
	if not tiles then self.masks:clear()
	else self.masks:tilesChanged(tiles) end
	for slot,f in self.maskViews do
		local m=self.masks.slots[slot]
		if not m or m.remaining>0 or m.uploaded~=m.revision then f.Visible=false end
	end
end

local function prepareMasks(self:any,now:number):boolean
	local config=self.renderer.scene and self.renderer.scene.renderConfig
	if config then
		for _,e in self.state.impacts do
			local m=self.masks:add(e.tile,config:nukeMagnitudes(e.kind).outer,e.start)
			if m and self.maskViews[m.slot] then self.maskViews[m.slot].Visible=false end
		end
		table.clear(self.state.impacts)
	end
	self.masks:expire(now)
	if self.maskFailed then self.masks:clear(); return false end
	self.masks:step(self.renderer.core.tileState,Policy.falloutMaskPixelsPerFrame,Policy.falloutMaskMs)
	-- Share the displayed-image slot with ownership. Under churn cosmetics
	-- get at most one in four frames, never a second upload in a raster frame.
	if Core.hasPending(self.renderer.core) and self.prepareFrame%4~=0 then return false end
	for _,m in self.masks.slots do if m.remaining==0 and m.uploaded~=m.revision then
		if not self.maskAtlas then
			local ok,atlas=pcall(function()
				return game:GetService('AssetService'):CreateEditableImage({Size=Vector2.new(Policy.falloutMaskSize*self.maskColumns,Policy.falloutMaskSize*2)})
			end)
			if not ok or not atlas then self.maskFailed=true; self.masks:clear(); return false end
			self.maskAtlas=atlas; self.maskContent=Content.fromObject(atlas)
		end
		local size=Policy.falloutMaskSize
		self.maskAtlas:WritePixelsBuffer(Vector2.new((m.slot-1)%self.maskColumns*size,math.floor((m.slot-1)/self.maskColumns)*size),Vector2.new(size,size),m.pixels)
		m.uploaded=m.revision; self.maskUploads+=1
		return true
	end end
	return false
end
local function content(self: any): Content
	if self.content then return self.content end
	local atlas = game:GetService('AssetService'):CreateEditableImage({Size = Vector2.new(Atlas.width,Atlas.height)})
	assert(atlas,'OpenFront FX atlas allocation failed')
	self.atlas = atlas
	atlas:WritePixelsBuffer(Vector2.zero,Vector2.new(Atlas.width,Atlas.height),Atlas.rgba())
	self.content = Content.fromObject(atlas)
	return self.content
end
-- Reserve this frame's image-upload slot for first-use atlas construction.
-- Subsequent animation only changes ImageRectOffset and native properties.
function Effects.prepare(self: any): boolean
	self.prepareFrame+=1
	local loading=self.renderer.options and self.renderer.options.firstPaint=='full' and not self.renderer.ready
	if not self.atlas and (loading or #self.centers>0 or #self.state.sprites>0) then content(self); return true end
	return prepareMasks(self,os.clock()*1000)
end
local function point(self: any, x: number, y: number): (number,number)
	if self.world then return x*self.worldUnit,y*self.worldUnit end
	local camera = self.renderer.camera
	local sx,sy = Camera.worldToScreenCoordinates(camera,x,y)
	return sx-camera.left,sy-camera.top
end
local function rect(obj: GuiObject, x: number,y: number,w: number,h: number)
	local position,size=UDim2.fromOffset(x-w/2,y-h/2),UDim2.fromOffset(w,h)
	if obj.Position~=position then obj.Position=position end
	if obj.Size~=size then obj.Size=size end
end
local function visible(self: any, x: number,y: number,w: number,h: number): boolean
	local c = self.renderer.camera
	if self.world then
		local sx,sy=Camera.worldToScreenCoordinates(c,x/self.worldUnit,y/self.worldUnit)
		x,y,w,h=sx-c.left,sy-c.top,w*c.scale/self.worldUnit,h*c.scale/self.worldUnit
	end
	return x+w/2>=0 and y+h/2>=0 and x-w/2<c.viewportWidth and y-h/2<c.viewportHeight
end
local function spriteView(self: any, pool: {any}, index: number, parent: Instance, z: number): ImageLabel?
	if pool[index] then return pool[index] end
	if self.budget <= 0 then return nil end
	self.budget -= 1
	local i = Instance.new('ImageLabel')
	i.Name,i.BackgroundTransparency,i.BorderSizePixel,i.ZIndex = 'FxSprite',1,0,z
	i.ImageContent,i.ResampleMode = content(self),Enum.ResamplerMode.Pixelated
	i.Parent = parent; pool[index] = i
	return i
end
local function trim(pool: {any}, count: number, styles: any?)
	for i = #pool, count+1, -1 do
		pool[i].Visible = false
		if i > count+32 then
			if styles then styles[pool[i]]=nil end
			pool[i]:Destroy(); table.remove(pool,i)
		end
	end
end

-- Original: WebGLFrameBuilder.syncSpawnOverlay, enemy → mate → self ordering.
function Effects.setSpawn(self: any, roster: {any}, localPlayer: number, active: boolean, ownSpawnRing: boolean?)
	local me = nil
	for _, p in roster do if p.smallID == localPlayer then me = p end end
	local team = if me then me.team else nil
	local centers, discs = {}, {}
	for _, p in roster do
		local c = self.renderer.core.palette[p.smallID]
		local color = Spawn.center(p.type,p.spawnTile ~= nil,p.smallID==localPlayer,team,active,ownSpawnRing==true,
			if c then c.fill else {r=.5,g=.5,b=.5,a=1})
		if color then
			local kind = if p.smallID == localPlayer then 1 elseif team ~= nil and p.team == team then 2 else 0
			local x,y = p.spawnTile % self.renderer.core.width,math.floor(p.spawnTile/self.renderer.core.width)
			if kind == 0 then table.insert(discs,{x=x,y=y,owner=p.smallID})
			else table.insert(centers,{x=x,y=y,kind=kind,color=color}) end
		end
	end
	table.sort(centers,function(a,b) return a.kind>b.kind end)
	self.centers = centers
	return discs
end

-- Original: FxSpritePass.draw, WorldTextPass.rebuildInstances and spawn shader.
function Effects.clearConquests(self:any)
	self.state:clearConquests()
	if self.conquestStamp then self.conquestStamp.Visible=false end
	for _,pool in {self.sprites,self.popups} do
		for _,view in pool do if view.Name=='ConquestMark' or view.Name=='ConquestGold' then view.Visible=false end end
	end
end

local function drawConquestStamp(self:any,now:number)
	local m=self.state.conquestMoment
	local elapsed=if m then now-m.start else -1
	if not m or elapsed<180 or elapsed>=1050 then
		if self.conquestStamp then self.conquestStamp.Visible=false end
		return
	end
	local camera=self.renderer.camera
	local x,y=Camera.worldToScreenCoordinates(camera,m.x+.5,m.y+.5)
	x-=camera.left; y-=camera.top
	if x<0 or x>camera.viewportWidth or y<0 or y>camera.viewportHeight then
		if self.conquestStamp then self.conquestStamp.Visible=false end
		return
	end
	local f=self.conquestStamp
	if not f then
		f=Instance.new('TextLabel'); self.conquestStamp=f
		f.Name,f.BackgroundTransparency,f.BorderSizePixel,f.ZIndex='ConquestStamp',1,0,15
		f.Active=false; f.Font=Enum.Font.Oswald; f.TextColor3=Color3.fromRGB(38,37,31)
		f.TextStrokeColor3=Color3.fromRGB(245,237,209); f.Rotation=-5
		f.AnchorPoint=Vector2.new(.5,.5); f.Size=UDim2.fromOffset(300,44)
		f.Parent=if self.renderer.guiLayers then self.renderer.guiLayers:parent('WorldText') else self.renderer.root
	end
	local age=elapsed-180
	local alpha=math.clamp((elapsed-800)/250,0,1)
	f.Visible=true; f.Text=if m.count>1 then `CONQUERED x{m.count}` else 'CONQUERED'
	f.TextSize=24*(1+.16*(1-math.clamp(age/100,0,1)))
	f.Position=UDim2.fromOffset(x,y); f.TextTransparency=alpha; f.TextStrokeTransparency=.4+.6*alpha
end

function Effects.step(self: any, now: number)
	if self.destroyed then return end
	self.state:tick(now); self.budget = 25
	local scale, count = if self.world then self.worldUnit else self.renderer.camera.scale,0
	for _, e in self.state.sprites do
		if e.fallout then
			local tx,ty=math.floor(e.x),math.floor(e.y)
			local core=self.renderer.core
			if tx<0 or ty<0 or tx>=core.width or ty>=core.height or bit32.band(buffer.readu16(core.tileState,(ty*core.width+tx)*2),8192)==0 then continue end
		end
		local cfg = Atlas.rows[e.kind+1]
		local x,y = point(self,e.x+.5,e.y+.5)
		local w,h = cfg[1]*scale*(e.scale or 1),cfg[2]*scale*(e.scale or 1)
		if e.conquestMark then
			local factor=if self.world then self.worldUnit/self.renderer.camera.scale else 1
			local size=math.clamp(cfg[1]*self.renderer.camera.scale,32,72)*factor
			local settle=1+.20*(1-math.clamp((now-e.start)/160,0,1))
			w,h=size*settle,size*cfg[2]/cfg[1]*settle
		end
		local art=self.renderer.scene and self.renderer.scene.shipArt
		local sinking=e.kind==5 and Policy.smoothShips and art and art.content
		local age=math.clamp((now-e.start)/e.lifetime,0,1)
		if sinking then w,h=13*scale*(1-.35*age),13*scale*(1-.65*age); y+=age*.8*scale end
		if visible(self,x,y,w,h) then
			local f = spriteView(self,self.sprites,count+1,self.fx,8)
			if f then
				count += 1
				f.Name=if e.conquestMark then 'ConquestMark' else 'FxSprite'
				local index,alpha = Fx.sampleSprite(e,now)
				if not f.Visible then f.Visible=true end
				local transparency=if sinking then age else 1-alpha
				if f.ImageTransparency~=transparency then f.ImageTransparency=transparency end
				if sinking then
					if self.sinkingViews[f]~=e then
						f.ImageContent=art.content; f.ResampleMode=Enum.ResamplerMode.Default
						f.ImageRectOffset,f.ImageRectSize=Vector2.new(1,ShipArt.cell+1),Vector2.new(ShipArt.size,ShipArt.size)
						local c=self.renderer.core.palette[e.shipOwner]
						f.ImageColor3=if c then Color3.new(c.fill.r,c.fill.g,c.fill.b) else Color3.new(1,1,1)
						self.sinkingViews[f]=e
					end
					f.Rotation=(e.shipHeading or 0)+age*22
				else
					if self.sinkingViews[f] then
						f.ImageContent=self.content; f.ResampleMode=Enum.ResamplerMode.Pixelated
						f.ImageColor3=Color3.new(1,1,1); f.Rotation=0; self.sinkingViews[f]=nil
					end
					local offset,size=Vector2.new(index*cfg[1],cfg[3]),Vector2.new(cfg[1],cfg[2])
					if f.ImageRectOffset~=offset then f.ImageRectOffset=offset end
					if f.ImageRectSize~=size then f.ImageRectSize=size end
				end
				rect(f,x,y,w,h)
			end
		end
	end
	trim(self.sprites,count,self.sinkingViews); count=0
	for _, e in self.state.shockwaves do
		local t = math.clamp((now-e.start)/e.lifetime,0,1)
		local x,y = point(self,e.x,e.y)
		local radius = t*e.radius*scale
		if radius>0 and visible(self,x,y,radius*2,radius*2) then
			local f = self.rings[count+1]
			if not f and self.budget>0 then
				self.budget-=1; f=layer(self.fx,'Shockwave',8)
				local corner=Instance.new('UICorner'); corner.CornerRadius=UDim.new(1,0); corner.Parent=f
				local stroke=Instance.new('UIStroke'); stroke.Name='Stroke'; stroke.Color=Color3.new(1,1,1); stroke.Parent=f
				self.rings[count+1]=f
			end
			if f then
				count+=1; f.Visible=true; rect(f,x,y,radius*2,radius*2)
				local stroke=f:FindFirstChild('Stroke') :: UIStroke
				stroke.Thickness,stroke.Transparency=math.max(if self.world then self.worldUnit/self.renderer.camera.scale else 1,radius*.04),t
			end
		end
	end
	trim(self.rings,count); count=0
	if self.renderer.camera.scale>=.3 then for _, e in self.state.popups do
		local age = now-e.start
		if age<0 then continue end
		local rise = (e.riseSpeed or 3)*age/1000
		local x,y = point(self,e.x+.5,e.y+.5-rise)
		local px = math.max(6*scale,.15)
		if visible(self,x,y,px*#e.text,px*2) then
			local f=self.popups[count+1]
			if not f and self.budget>0 then
				self.budget-=1; f=Instance.new('TextLabel')
				f.Name,f.BackgroundTransparency,f.BorderSizePixel,f.ZIndex='BonusGold',1,0,14
				f.Font,f.TextColor3,f.TextStrokeColor3=Enum.Font.SourceSansBold,Color3.new(1,1,1),Color3.new()
				local fontScale=Instance.new('UIScale'); fontScale.Name='FontScale'; fontScale.Parent=f
				f.Parent=self.text; self.popups[count+1]=f
			end
			if f then
				count+=1; f.Visible=true; f.Name=if e.conquest then 'ConquestGold' else 'BonusGold'
				f.Text=e.text; f.TextSize=math.clamp(px,1,100)
				f.TextTransparency,f.TextStrokeTransparency=age/e.lifetime,age/e.lifetime
				local glyphScale=math.max(1,px/100)
				local component=f:FindFirstChild('FontScale') :: UIScale
				component.Scale=glyphScale
				local width=math.max(16,px*#e.text)
				f.Position=UDim2.fromOffset(x-width/2,y-px)
				f.Size=UDim2.fromOffset(width/glyphScale,px*2/glyphScale)
			end
		end
	end end
	trim(self.popups,count); count=0
	drawConquestStamp(self,now)
	local breath=Spawn.breath(now)
	for _, c in self.centers do
		local x,y=point(self,c.x,c.y)
		local radius=(if c.kind==1 then 30 else 14)*(.5+.65*breath)*scale
		if visible(self,x,y,radius*2,radius*2) then
			local f=spriteView(self,self.glows,count+1,self.spawn,2)
			if f then
				count+=1; f.Visible=true
				f.ImageRectOffset,f.ImageRectSize=Vector2.new((c.kind-1)*64,242),Vector2.new(64,64)
				local color=Color3.new(c.color.r,c.color.g,c.color.b)
				f.ImageColor3=if c.kind==1 then Color3.new(1,1,1):Lerp(color,breath) else color
				f.ImageTransparency=1-(.65+.35*breath)
				rect(f,x,y,radius*2,radius*2)
			end
		end
	end
	trim(self.glows,count)
	self.masks:expire(now)
	for slot,m in self.masks.slots do
		local f=self.maskViews[slot]
		local ready=m.uploaded==m.revision and m.remaining==0 and self.maskContent~=nil
		if ready and not f and self.budget>0 then
			self.budget-=1; f=Instance.new('ImageLabel'); f.Name='FalloutMask'; f.BackgroundTransparency=1; f.BorderSizePixel=0
			f.ImageContent=self.maskContent; f.ResampleMode=Enum.ResamplerMode.Pixelated; f.ImageColor3=Color3.new(1,1,1)
			f.ZIndex=3; f.Parent=self.falloutLayer; self.maskViews[slot]=f
		end
		if f then
			f.Visible=ready
			if ready then
				local size=Policy.falloutMaskSize
				f.ImageRectOffset=Vector2.new((slot-1)%self.maskColumns*size,math.floor((slot-1)/self.maskColumns)*size)
				f.ImageRectSize=Vector2.new(size,size)
				local x,y=point(self,m.x,m.y)
				local s=if self.world then self.worldUnit else self.renderer.camera.scale
				f.Position=UDim2.fromOffset(x,y); f.Size=UDim2.fromOffset(size*m.step*s,size*m.step*s)
				local age=math.clamp((now-m.start)/self.masks.lifetime,0,1)
				f.ImageTransparency=1-Policy.falloutGlowAlpha*(1-age)*(.8+.2*math.sin((now-m.start)*.005))
			end
		end
	end
	for slot,f in self.maskViews do if not self.masks.slots[slot] then f.Visible=false end end
end
function Effects.destroy(self: any)
	if self.destroyed then return end
	self.destroyed=true; self.state:clear()
	self.spawn:Destroy(); self.fx:Destroy(); self.text:Destroy(); self.falloutLayer:Destroy()
	if self.conquestStamp then self.conquestStamp:Destroy(); self.conquestStamp=nil end
	if self.maskAtlas then self.maskAtlas:Destroy(); self.maskAtlas=nil end
	self.maskContent=nil; self.masks:clear(); table.clear(self.maskViews)
	if self.atlas then self.atlas:Destroy(); self.atlas=nil; self.content=nil end
	table.clear(self.centers)
	for _, pool in {self.sprites,self.rings,self.popups,self.glows} do table.clear(pool) end
	table.clear(self.sinkingViews)
end
return Effects
