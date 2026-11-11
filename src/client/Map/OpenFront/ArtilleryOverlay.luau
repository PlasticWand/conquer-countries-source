--!strict
-- Original Conquest GUI-only shells and accents. No raster writes, trails
-- per tile, camera shake, delayed callbacks or inferred combat outcomes.
local State = require(script.Parent.ArtilleryState)
local Camera = require(script.Parent.CameraTransform)
local Overlay = {}
Overlay.__index = Overlay
Overlay.handles=function(kind:string):boolean return State.projectiles[kind]==true end
Overlay.clipLine=State.clipLine
local function usesSlot(u:any):boolean
	return Overlay.handles(u.type) or (u.type=='Field Works' and u.underConstruction==true)
end

local function frame(self:any,parent:any,name:string):any
	local f=self.native.new("Frame")
	f.Name,f.BackgroundTransparency,f.BorderSizePixel=name,1,0
	f.Active=false;f.Parent=parent
	return f
end
function Overlay.new(scene:any,native:any,specs:any?):any
	return setmetatable({scene=scene,native=native,state=State.new(scene.renderer.core.width,specs),
		shells={},marks={},ids={},planeIds={},cursor=0,destroyed=false},Overlay)
end
local function root(self:any)
	if self.root then return end
	local r,n=self.scene.renderer,self.native
	self.root=frame(self,if r.guiLayers then r.guiLayers:parent("Effects") else r.root,"Artillery")
	self.root.Size=n.UDim2.fromScale(1,1);self.root.ZIndex=9;self.root.ClipsDescendants=true
	self.ink=n.Color3.fromRGB(255,224,163);self.red=n.Color3.fromRGB(240,108,85)
end
local function position(self:any,x:number,y:number):(number,number)
	local c=self.scene.renderer.camera
	local sx,sy=Camera.worldToScreenCoordinates(c,x,y)
	return sx-c.left,sy-c.top
end
function Overlay.visible(self:any,tile:number,other:number?):boolean
	local r=self.scene.renderer
	if not r.ready or not r.root.Visible then return false end
	local x,y=position(self,tile%r.core.width+.5,math.floor(tile/r.core.width)+.5)
	if other~=nil then
		local tx,ty=position(self,other%r.core.width+.5,math.floor(other/r.core.width)+.5)
		return State.clipLine(x,y,tx,ty,r.camera.viewportWidth,r.camera.viewportHeight)~=nil
	end
	return x>=0 and y>=0 and x<=r.camera.viewportWidth and y<=r.camera.viewportHeight
end
function Overlay.setUnits(self:any,units:{[number]:any})
	local ids,planes={},{}
	if not self.stopped then
		for id,u in units do if usesSlot(u) and u.active~=false then
			table.insert(ids,id);if u.type=='Paratroopers' then table.insert(planes,id) end
		end end
	end
	table.sort(ids);table.sort(planes);self.ids,self.planeIds=ids,planes
	self.cursor=if #ids>0 then self.cursor%#ids else 0
end
function Overlay.reset(self:any,units:{[number]:any})
	self.stopped=false
	self.state:seed(units);self:setUnits(units)
	for _,s in self.shells do s.id=nil;s.head.Visible=false;s.tail.Visible=false end
	for _,m in self.marks do m.root.Visible=false end
end
function Overlay.updates(self:any,updates:{any},removed:{number},now:number)
	if self.stopped then return end
	self.state:updates(updates,removed,function(tile:number,other:number?):boolean return self:visible(tile,other) end,now,self.scene.renderer.camera.scale)
end
local function shellNew(self:any):any
	local head=frame(self,self.root,"ArtilleryShell")
	head.AnchorPoint=self.native.Vector2.new(.5,.5);head.BackgroundTransparency=0
	head.BackgroundColor3=self.ink;head.BorderSizePixel=1;head.BorderColor3=self.native.Color3.fromRGB(45,37,28)
	head.ZIndex=9
	local tail=frame(self,self.root,"ArtilleryTail")
	tail.AnchorPoint=self.native.Vector2.new(.5,.5);tail.BackgroundTransparency=.35;tail.BackgroundColor3=self.ink
	tail.ZIndex=8
	local plane=self.native.new('ImageLabel');plane.Name='Bomber';plane.BackgroundTransparency=1;plane.BorderSizePixel=0
	plane.ImageContent=self.scene.content;plane.ImageRectOffset=self.native.Vector2.new(156,0);plane.ImageRectSize=self.native.Vector2.new(13,13)
	plane.ImageColor3=self.ink;plane.ResampleMode=self.native.Enum.ResamplerMode.Pixelated
	plane.Size=self.native.UDim2.fromScale(1,1);plane.Parent=head
	local outline=self.native.new('ImageLabel');outline.Name='TransportOutline';outline.BackgroundTransparency=1;outline.BorderSizePixel=0
	outline.ImageContent=self.scene.content;outline.ImageRectOffset=self.native.Vector2.new(320,0);outline.ImageRectSize=self.native.Vector2.new(32,32)
	outline.ImageColor3=self.native.Color3.fromRGB(34,30,26);outline.ResampleMode=self.native.Enum.ResamplerMode.Default
	outline.AnchorPoint=self.native.Vector2.new(.5,.5);outline.Position=self.native.UDim2.fromScale(.5,.5)
	outline.ZIndex=9;outline.Parent=head;plane.ZIndex=10
	return {head=head,tail=tail,plane=plane,outline=outline}
end
local function shellPose(self:any,u:any,fraction:number,now:number):(number,number,number,number)
	local width=self.scene.renderer.core.width
	local wx,wy=u.tile%width,math.floor(u.tile/width)
	if u.type=='Paratroopers' then wx,wy=self.state:flightPosition(u,now)
	elseif u.lastTile~=nil then
		local lx,ly=u.lastTile%width,math.floor(u.lastTile/width)
		local a=math.clamp(fraction,0,1)
		wx,wy=lx+(wx-lx)*a,ly+(wy-ly)*a
	end
	local x,y=position(self,wx+.5,wy+.5)
	local from=u.lastTile or u.sourceTile or u.tile
	local target=u.targetTile or u.tile
	local dx,dy=target%width-from%width,math.floor(target/width)-math.floor(from/width)
	local length=math.sqrt(dx*dx+dy*dy)
	return x,y,if length>0 then dx/length else 1,if length>0 then dy/length else 0
end
local function shellVisible(self:any,u:any,fraction:number,now:number):boolean
	if not u or not usesSlot(u) or u.active==false or (u.waitTicks or 0)>0 then return false end
	local r=self.scene.renderer
	if not r.ready or not r.root.Visible then return false end
	if u.type=='Railgun Shot' and u.sourceTile~=nil then return self:visible(u.sourceTile,u.tile) end
	local x,y=shellPose(self,u,fraction,now)
	return x>=-10 and y>=-10 and x<=r.camera.viewportWidth+10 and y<=r.camera.viewportHeight+10
end
local function markNew(self:any):any
	local r=frame(self,self.root,"ArtilleryAccent");r.Size=self.native.UDim2.fromOffset(0,0)
	local bars={}
	for i=1,4 do
		local f=frame(self,r,"Ray");f.AnchorPoint=self.native.Vector2.new(.5,.5);f.BackgroundTransparency=0;bars[i]=f
	end
	local text=self.native.new("TextLabel")
	text.Name="LevelLoss";text.BackgroundTransparency=1;text.BorderSizePixel=0;text.Active=false
	text.Font=self.native.Enum.Font.SourceSansBold;text.TextSize=13;text.TextStrokeTransparency=.35
	text.TextColor3=self.red;text.Size=self.native.UDim2.fromOffset(64,18);text.Parent=r
	local canopies={}
	for i=1,3 do
		local f=self.native.new('ImageLabel');f.Name='Canopy';f.BackgroundTransparency=1;f.BorderSizePixel=0
		f.ImageContent=self.scene.content;f.ImageRectOffset=self.native.Vector2.new(352,0);f.ImageRectSize=self.native.Vector2.new(32,32)
		f.ImageColor3=self.ink;f.ResampleMode=self.native.Enum.ResamplerMode.Default
		f.AnchorPoint=self.native.Vector2.new(.5,.5);f.Parent=r;canopies[i]=f
	end
	local earth=self.native.new('ImageLabel');earth.Name='FadingEarthworks';earth.BackgroundTransparency=1;earth.BorderSizePixel=0
	earth.ImageContent=self.scene.content;earth.ImageRectOffset=self.native.Vector2.new(480,0);earth.ImageRectSize=self.native.Vector2.new(32,32)
	earth.ImageColor3=self.ink;earth.ResampleMode=self.native.Enum.ResamplerMode.Default
	earth.AnchorPoint=self.native.Vector2.new(.5,.5);earth.Parent=r
	return {root=r,bars=bars,text=text,canopies=canopies,earth=earth}
end
function Overlay.step(self:any,now:number,fraction:number)
	if self.destroyed or self.stopped then return end
	self.state:expire(now)
	if not self.root and (#self.ids>0 or #self.state.marks>0) then root(self) end
	if not self.root then return end
	local n,c=self.native,self.scene.renderer.camera
	local active={}
	for _,s in self.shells do
		if s.id and shellVisible(self,self.scene.units[s.id],fraction,now) then active[s.id]=true
		else s.id=nil;s.head.Visible=false;s.tail.Visible=false end
	end
	local created=0
	local function assign(id:number,priority:boolean):boolean
		if active[id] or not shellVisible(self,self.scene.units[id],fraction,now) then return true end
		local slot
		for _,s in self.shells do if not s.id then slot=s;break end end
		-- A troop-carrying public plane must not wait for a shell barrage to
		-- finish. Reuse a lower-priority shot view within the same hard cap.
		if not slot and priority then for _,s in self.shells do
			if self.scene.units[s.id].type~='Paratroopers' then active[s.id]=nil;slot=s;break end
		end end
		if not slot and (#self.shells>=State.shellCap or created>=4) then return false end
		if not slot then slot=shellNew(self);table.insert(self.shells,slot);created+=1 end
		slot.id=id;active[id]=true
		return true
	end
	local visits=0
	for _,id in self.planeIds do
		if visits>=State.visitCap then break end
		visits+=1;assign(id,true)
	end
	for _=1,math.min(State.visitCap-visits,#self.ids) do
		self.cursor=self.cursor%#self.ids+1
		local id=self.ids[self.cursor]
		if not assign(id,false) then break end
	end
	for _,s in self.shells do if s.id then
		local x,y,dx,dy=shellPose(self,self.scene.units[s.id],fraction,now)
		local u=self.scene.units[s.id]
		local fuse=u.type=='Sabotage'
		local digging=u.type=='Field Works'
		local transport=u.type=='Paratroopers'
		local plane=u.type=='Air Strike' or transport
		local size=if transport then math.clamp(14+c.scale*1.5,16,32) elseif plane then math.clamp(8+c.scale*1.5,10,24) else math.clamp(2+c.scale*.35,3,6)
		local length=math.clamp(c.scale*(if plane then 4 else 2),4,18)
		s.plane.Visible=plane;s.head.BackgroundTransparency=if plane then 1 else 0;s.head.BorderSizePixel=if plane then 0 else 1
		s.outline.Visible=transport;s.outline.Size=n.UDim2.fromOffset(size+3,size+3)
		s.plane.ImageRectOffset=n.Vector2.new(if transport then 320 else 156,0)
		s.plane.ImageRectSize=n.Vector2.new(if transport then 32 else 13,if transport then 32 else 13)
		s.plane.ResampleMode=if transport then n.Enum.ResamplerMode.Default else n.Enum.ResamplerMode.Pixelated
		local palette=self.scene.renderer.core.palette[u.owner]
		s.plane.ImageColor3=if transport then (if palette then n.Color3.new(palette.fill.r,palette.fill.g,palette.fill.b) else n.Color3.fromRGB(130,130,130)) else self.ink
		s.head.Rotation=if plane then math.deg(math.atan2(dy,dx))+90 else 0
		s.head.Visible=true;s.head.Position=n.UDim2.fromOffset(x,y);s.head.Size=n.UDim2.fromOffset(size,size)
		s.tail.Visible=not transport;s.tail.Position=n.UDim2.fromOffset(x-dx*length*.7,y-dy*length*.7)
		s.tail.Size=n.UDim2.fromOffset(length,1.5);s.tail.Rotation=math.deg(math.atan2(dy,dx))
		-- A stationary public fuse uses the existing head/tail slot. Its tiny
		-- warm spark and sputtering tip never imply a successful switch-off.
		s.head.BackgroundColor3=self.ink;s.head.BackgroundTransparency=if plane then 1 else 0
		s.tail.BackgroundColor3=self.ink;s.tail.BackgroundTransparency=.35
		if fuse then
			local t=(now*5+s.id*.13)%1
			s.head.Size=n.UDim2.fromOffset(3+t*2,3+t*2);s.head.Position=n.UDim2.fromOffset(x,y-5);s.head.Rotation=45
			s.head.BackgroundColor3=n.Color3.fromRGB(255,190+math.floor(t*60),80)
			s.tail.Position=n.UDim2.fromOffset(x-3+t*5,y-7-t*5)
			s.tail.Size=n.UDim2.fromOffset(2,1);s.tail.Rotation=t*160;s.tail.BackgroundTransparency=t
		end
		if digging then
			-- Two earth flecks share the same hard-capped view as shots/fuses.
			-- Construction's grey symbol and timer remain even under saturation.
			for i,f in {s.head,s.tail} do
				local t=(now*2+(i-1)*.5)%1
				f.BackgroundColor3=n.Color3.fromRGB(154,126,81);f.BorderSizePixel=0
				f.Position=n.UDim2.fromOffset(x+(i*2-3)*4,y-3-t*7)
				f.Size=n.UDim2.fromOffset(2,2);f.Rotation=20+t*70;f.BackgroundTransparency=t
			end
		end
		if u.type=='Railgun Shot' and u.sourceTile~=nil then
			local sx,sy=position(self,u.sourceTile%self.state.width+.5,math.floor(u.sourceTile/self.state.width)+.5)
			local ax,ay,bx,by=State.clipLine(sx,sy,x,y,c.viewportWidth,c.viewportHeight)
			if ax and ay and bx and by then
				s.tail.Position=n.UDim2.fromOffset((ax+bx)/2,(ay+by)/2);s.tail.Size=n.UDim2.fromOffset(math.sqrt((bx-ax)^2+(by-ay)^2),2)
				s.tail.Rotation=math.deg(math.atan2(by-ay,bx-ax))
			end
		end
	end end
	created=0
	for i,e in self.state.marks do
		local m=self.marks[i]
		if not m then
			if created>=2 then break end
			m=markNew(self);self.marks[i]=m;created+=1
		end
		local x,y=position(self,e.x,e.y)
		local a=math.clamp((now-e.start)/e.life,0,1)
		m.root.Visible=self.scene.renderer.ready and self.scene.renderer.root.Visible
			and x>=-30 and y>=-30 and x<=c.viewportWidth+30 and y<=c.viewportHeight+30
		m.root.Position=n.UDim2.fromOffset(x,y)
		local level=e.kind=="levelLoss"
		local air=e.kind=='airImpact'
		local landing,down=e.kind=='paraLand',e.kind=='paraDown'
		m.earth.Visible=e.kind=='fieldFade'
		m.earth.Position=n.UDim2.fromOffset(0,a*3)
		local earthSize=math.clamp(12+c.scale*2,14,32)
		m.earth.Size=n.UDim2.fromOffset(earthSize,earthSize);m.earth.ImageTransparency=.15+.85*a
		for j,f in m.canopies do
			local delay=(j-1)*.06
			local t=math.clamp((now-e.start-delay)/(.85-delay),0,1)
			f.Visible=landing and now-e.start>=delay
			local bloom=math.min(1,t/.22)
			local spread=math.clamp(c.scale*2,8,20)
			f.Position=n.UDim2.fromOffset((j-2)*spread*bloom,-12*(1-t)+math.abs(j-2)*4)
			local extent=math.clamp(12+c.scale,13,22)*(.35+.65*bloom)
			f.Size=n.UDim2.fromOffset(extent,extent);f.ImageTransparency=math.clamp((t-.55)/.45,0,1)
		end
		for _,f in m.bars do f.Visible=true end
		local radius=if e.kind=="muzzle" then 2+a*4 elseif level then 8+a*5 else 3+a*10
		for j,f in m.bars do
			local angle=(j-1)*math.pi/2+math.pi/4
			f.BackgroundColor3=if level then self.red else self.ink
			f.BackgroundTransparency=a;f.Rotation=math.deg(angle)
			f.Position=n.UDim2.fromOffset(math.cos(angle)*radius,math.sin(angle)*radius)
			f.Size=n.UDim2.fromOffset(if level then 4 else 5*(1-a)+1,2)
			if air then
				local t=math.clamp((now-e.start-(j-1)*.04)/.28,0,1)
				f.Visible=now-e.start>=(j-1)*.04
				local reach=(e.radius or 0)*c.scale*.6
				f.Position=n.UDim2.fromOffset(math.cos(angle)*reach,math.sin(angle)*reach)
				local extent=math.clamp(3+c.scale,4,9)*(1-t*.4)
				f.Size=n.UDim2.fromOffset(extent,extent);f.BackgroundTransparency=t;f.Rotation=45
			end
			if landing or e.kind=='fieldFade' then f.Visible=false end
			if e.kind=='switchOff' then
				-- Inward cool rays blink off, rather than an explosive gold burst.
				f.BackgroundColor3=n.Color3.fromRGB(193,202,207)
				f.Position=n.UDim2.fromOffset(math.cos(angle)*(12-8*a),math.sin(angle)*(12-8*a))
				f.Size=n.UDim2.fromOffset(5*(1-a)+1,2)
			end
			if down then
				if j==1 then
					f.Visible=a<.3;f.BackgroundColor3=self.ink;f.Rotation=45
					f.Position=n.UDim2.fromOffset(0,0);local size=5+18*math.min(1,a/.3)
					f.Size=n.UDim2.fromOffset(size,size);f.BackgroundTransparency=math.min(1,a/.3)
				else
					local t=math.clamp((a-(j-2)*.08)/.84,0,1)
					f.Visible=a>=(j-2)*.08;f.BackgroundColor3=n.Color3.fromRGB(72,67,61);f.Rotation=25+j*25+t*30
					f.Position=n.UDim2.fromOffset((j-3)*4+t*4,3+t*22)
					local size=3+t*7;f.Size=n.UDim2.fromOffset(size,size);f.BackgroundTransparency=.15+.85*t
				end
			end
		end
		m.text.Visible=level
		m.text.BackgroundTransparency=1
		if level then m.text.Text=`-{e.loss} LV`;m.text.TextTransparency=a;m.text.TextStrokeTransparency=.35+.65*a
			m.text.Position=n.UDim2.fromOffset(-32,8+a*8) end
		if e.kind=='railBeam' and e.source~=nil then
			local sx,sy=position(self,e.source%self.state.width+.5,math.floor(e.source/self.state.width)+.5)
			local ax,ay,bx,by=State.clipLine(sx,sy,x,y,c.viewportWidth,c.viewportHeight)
			m.root.Visible=ax~=nil and self.scene.renderer.ready and self.scene.renderer.root.Visible
			m.root.Position=n.UDim2.fromOffset(0,0)
			for j,f in m.bars do f.Visible=j==1 end
			if ax and ay and bx and by then
				local f=m.bars[1];f.Position=n.UDim2.fromOffset((ax+bx)/2,(ay+by)/2)
				f.Size=n.UDim2.fromOffset(math.sqrt((bx-ax)^2+(by-ay)^2),3*(1-a)+1)
				f.Rotation=math.deg(math.atan2(by-ay,bx-ax))
			end
		end
	end
	for i=#self.state.marks+1,#self.marks do self.marks[i].root.Visible=false end
end
function Overlay.destroy(self:any)
	if self.destroyed then return end
	self:reset({});self.destroyed=true
	if self.root then self.root:Destroy() end
	table.clear(self.shells);table.clear(self.marks)
end
return Overlay
