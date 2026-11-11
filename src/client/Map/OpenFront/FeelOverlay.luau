--!strict
-- Original presentation accents. No image creation, pixel writes or commands.
-- Native constructors are injected like MapGuiLayers, keeping detection testable.
local State = require(script.Parent.FeelState)
local Camera = require(script.Parent.CameraTransform)
local Feel = {}
Feel.__index = Feel

local function frame(self:any,parent:any,name:string):any
	local f=self.native.new("Frame")
	f.Name,f.BackgroundTransparency,f.BorderSizePixel=name,1,0
	f.Active=false; f.Parent=parent
	return f
end

function Feel.new(scene:any,native:any):any
	local self:any=setmetatable({scene=scene,native=native,state=State.new(scene.renderer.core.width),slots={},marks={},markRings={},destroyed=false},Feel)
	self.color=native.Color3.fromRGB(255,225,158)
	self.colors={loss=native.Color3.fromRGB(245,77,70),landing=native.Color3.fromRGB(189,226,224),
		home=native.Color3.fromRGB(190,206,182),move=native.Color3.fromRGB(206,223,235),moveConfirmed=native.Color3.fromRGB(139,226,188)}
	return self
end

local function ensureRoot(self:any)
	if self.root then return end
	local r,n=self.scene.renderer,self.native
	local parent=if r.guiLayers then r.guiLayers:parent("Effects") else r.root
	self.root=frame(self,parent,"Feel")
	self.root.Size=n.UDim2.fromScale(1,1); self.root.ZIndex=9; self.root.ClipsDescendants=true
end

function Feel.visible(self:any,tile:number):boolean
	local r=self.scene.renderer
	if not r.ready or not r.root.Visible then return false end
	local c=r.camera
	local x,y=Camera.worldToScreenCoordinates(c,tile%r.core.width+.5,math.floor(tile/r.core.width)+.5)
	return x>=c.left and x<=c.left+c.viewportWidth and y>=c.top and y<=c.top+c.viewportHeight
end

local function release(self:any,slot:any)
	if slot.view then
		for _,part in slot.view.parts do if part.Parent==slot.symbol then part.Parent=slot.view.root end end
	end
	slot.symbol.Parent=self.root; slot.symbol.Visible=false; slot.scale.Scale=1
	if slot.levelScale.Parent then slot.levelScale.Parent=nil end
	slot.levelScale.Scale=1
	for _,f in slot.dust do f.Visible=false end
	slot.rim.Visible=false; slot.landing.Visible=false
	slot.id,slot.view=nil,nil
end

function Feel.reset(self:any,units:{[number]:any})
	for _,slot in self.slots do release(self,slot) end
	for _,mark in self.marks do for _,bar in mark do bar.Visible=false end end
	for _,mark in self.markRings do mark.frame.Visible=false end
	self.state:seed(units)
end

function Feel.updates(self:any,updates:{any},removed:{number},now:number)
	self.state:expire(now)
	self.state:updates(updates,removed,self.scene.localPlayer,function(tile:number):boolean return self:visible(tile) end,now)
	-- Restore symbols before SceneOverlay deletes a removed/captured unit root.
	for _,slot in self.slots do if slot.id and not self.state.units[slot.id] then release(self,slot) end end
end

function Feel.prune(self:any,units:{[number]:any})
	for _,slot in self.slots do
		local u=if slot.id then units[slot.id] else nil
		if slot.id and (not u or u.active==false or u.owner~=self.scene.localPlayer) then
			self.state.units[slot.id]=nil; release(self,slot)
		end
	end
end

function Feel.pulse(self:any,kind:string,tile:number,now:number)
	if (kind=="loss" or kind=="landing" or kind=="home") and not self:visible(tile) then return end
	local w=self.scene.renderer.core.width
	self.state:pulse(kind,tile%w+.5,math.floor(tile/w)+.5,now)
end
function Feel.move(self:any,ids:{number},tile:number,now:number)
	self.state:expire(now)
	self.state:move(ids,tile,self.scene.units,self.scene.localPlayer,now)
end
function Feel.focusAt(self:any,x:number,y:number,now:number) self.state:focusAt(x,y,now) end

local function ring(self:any,name:string):any
	local f=frame(self,self.root,name)
	f.AnchorPoint=self.native.Vector2.new(.5,.5)
	local corner=self.native.new("UICorner"); corner.CornerRadius=self.native.UDim.new(1,0); corner.Parent=f
	local stroke=self.native.new("UIStroke"); stroke.Color=self.color; stroke.Thickness=2; stroke.Parent=f
	return {frame=f,stroke=stroke}
end

local function slotNew(self:any):any
	local symbol=frame(self,self.root,"SettleSymbol")
	symbol.AnchorPoint=self.native.Vector2.new(.5,.5)
	symbol.Position=self.native.UDim2.fromScale(.5,.5); symbol.Size=self.native.UDim2.fromScale(1,1)
	local scale=self.native.new("UIScale"); scale.Scale=1; scale.Parent=symbol
	local levelScale=self.native.new("UIScale"); levelScale.Scale=1
	local rim,landing=ring(self,"CompletionRim"),ring(self,"BoatLanding")
	local dust={}
	for i=1,3 do
		local f=frame(self,self.root,"Dust")
		f.BackgroundColor3=self.color; f.AnchorPoint=self.native.Vector2.new(.5,.5)
		f.Size=self.native.UDim2.fromOffset(3,3); dust[i]=f
	end
	return {symbol=symbol,scale=scale,levelScale=levelScale,rim=rim.frame,rimStroke=rim.stroke,
		landing=landing.frame,landingStroke=landing.stroke,dust=dust}
end

local function position(self:any,x:number,y:number):any
	local c=self.scene.renderer.camera
	local sx,sy=Camera.worldToScreenCoordinates(c,x,y)
	return self.native.UDim2.fromOffset(sx-c.left,sy-c.top)
end

local function drawMark(self:any,index:number,e:any,now:number)
	local bars=self.marks[index]
	if not bars then bars={}; self.marks[index]=bars end
	local useRing=e.kind=="loss" or e.kind=="landing" or e.kind=="move" or e.kind=="moveConfirmed"
	if not useRing and #bars==0 then
		for i=1,8 do
			local f=frame(self,self.root,"FocusOrImpact")
			f.BackgroundColor3=self.color; f.AnchorPoint=self.native.Vector2.new(.5,.5); bars[i]=f
		end
	end
	local c=self.scene.renderer.camera
	local radius,alpha=State.mark(e.kind,now-e.start,c.scale)
	local p=position(self,e.x,e.y)
	local visible=p.X.Offset>=-radius and p.X.Offset<=c.viewportWidth+radius
		and p.Y.Offset>=-radius and p.Y.Offset<=c.viewportHeight+radius
	local ringView=self.markRings[index]
	if useRing then
		if not ringView then ringView=ring(self,"PulseRing"); self.markRings[index]=ringView end
		ringView.frame.Visible=visible; ringView.frame.Position=p
		ringView.frame.Size=self.native.UDim2.fromOffset(radius*2,radius*2)
		ringView.stroke.Color=self.colors[e.kind]; ringView.stroke.Transparency=alpha
		ringView.stroke.Thickness=if e.kind=="move" then 1.5 else 2+(1-math.clamp(c.scale/8,0,1))
	elseif ringView then ringView.frame.Visible=false end
	local far=1-math.clamp(c.scale/8,0,1)
	local length=if e.kind=="focus" then 7 else 5+3*far
	local thickness=if e.kind=="focus" then 2 else 2+far
	for i,f in bars do
		local corner=math.floor((i-1)/2)
		local dx,dy=if corner%2==0 then -1 else 1,if corner<2 then -1 else 1
		local horizontal=i%2==1
		local x=dx*(radius-(if horizontal then length/2 else 0))
		local y=dy*(radius-(if horizontal then 0 else length/2))
		f.Visible=visible and not useRing and (e.kind~="home" or i<=2); f.BackgroundTransparency=alpha
		f.BackgroundColor3=self.colors[e.kind] or self.color; f.Rotation=0
		f.Position=self.native.UDim2.fromOffset(p.X.Offset+x,p.Y.Offset+y)
		f.Size=self.native.UDim2.fromOffset(if horizontal then length else thickness,if horizontal then thickness else length)
		if e.kind=="home" and i<=2 then
			f.Rotation=if i==1 then -35 else 35
			f.Position=self.native.UDim2.fromOffset(p.X.Offset+(if i==1 then -1 else 1)*radius*.35,p.Y.Offset)
			f.Size=self.native.UDim2.fromOffset(radius,2)
		end
	end
end

function Feel.step(self:any,now:number)
	if self.destroyed then return end
	self.state:expire(now)
	if not self.root and (next(self.state.units)~=nil or #self.state.pulses>0 or self.state.focus) then ensureRoot(self) end
	local r,c=self.scene.renderer,self.scene.renderer.camera
	for _,slot in self.slots do
		if slot.id and not self.state.units[slot.id] then release(self,slot) end
	end
	for id,e in self.state.units do
		local unit,view=self.scene.units[id],self.scene.unitViews[id]
		if not unit or unit.active==false or unit.owner~=self.scene.localPlayer or not self:visible(unit.tile) then
			self.state.units[id]=nil
			for _,slot in self.slots do if slot.id==id then release(self,slot) end end
		elseif view and view.root.Visible then
			local slot
			for _,s in self.slots do if s.id==id then slot=s; break end end
			if not slot then
				for _,s in self.slots do if s.id==nil then slot=s; break end end
				if not slot and #self.slots<State.unitCap then slot=slotNew(self); table.insert(self.slots,slot) end
			end
			if slot then
				if slot.start~=e.start then release(self,slot); slot.start=e.start end
				slot.id,slot.view=id,view
				local age=math.max(0,now-e.start)
				if e.settle then
					if slot.symbol.Parent~=view.root then slot.symbol.Parent=view.root end
					slot.symbol.Visible=true
					for _,part in view.parts do if part.Parent~=slot.symbol then part.Parent=slot.symbol end end
					local scale=State.settle(age); if slot.scale.Scale~=scale then slot.scale.Scale=scale end
				end
				if e.upgrade and view.level then
					if slot.levelScale.Parent~=view.level then slot.levelScale.Parent=view.level end
					local scale=State.numeral(age); if slot.levelScale.Scale~=scale then slot.levelScale.Scale=scale end
				end
				local x,y=unit.tile%r.core.width+.5,math.floor(unit.tile/r.core.width)+.5
				local p=position(self,x,y)
				local size=view.root.Size.X.Offset*(if e.boat then c.scale/64 else self.scene.iconScale)
				local radius=math.max(9,math.min(50,size*.6))
				slot.rim.Visible=e.complete or e.boat
				if slot.rim.Visible then
					slot.rim.Position=p; slot.rim.Size=self.native.UDim2.fromOffset(radius*2+age*32,radius*2+age*32)
					slot.rimStroke.Transparency=math.clamp(age/.28,0,1)
				end
				for i,f in slot.dust do
					f.Visible=e.settle and not e.boat
					if f.Visible then
						f.Position=self.native.UDim2.fromOffset(p.X.Offset+(i-2)*(radius+age*25),p.Y.Offset+radius*.7+age*15)
						f.BackgroundTransparency=.35+.65*math.clamp(age/.28,0,1)
					end
				end
				slot.landing.Visible=e.boat and e.target~=nil
				if e.boat and e.target~=nil then
					slot.landing.Position=position(self,e.target%r.core.width+.5,math.floor(e.target/r.core.width)+.5)
					local extent=18+age*32
					slot.landing.Size=self.native.UDim2.fromOffset(extent,extent)
					slot.landingStroke.Transparency=math.clamp(age/.28,0,1)
				end
			end
		end
	end
	local count=0
	for _,e in self.state.pulses do count+=1; drawMark(self,count,e,now) end
	local focus=self.state.focus
	if focus then
		-- A fly-to may start with its destination outside the viewport. Spend
		-- the brief accent when it becomes visible, not behind the loading cover.
		local p=position(self,focus.x,focus.y)
		if focus.pending and r.ready and r.root.Visible and p.X.Offset>=0 and p.X.Offset<=c.viewportWidth
			and p.Y.Offset>=0 and p.Y.Offset<=c.viewportHeight then focus.pending=false; focus.start=now end
		if not focus.pending then count+=1; drawMark(self,count,focus,now) end
	end
	for i=count+1,#self.marks do for _,f in self.marks[i] do f.Visible=false end end
	for i,mark in self.markRings do if i>count then mark.frame.Visible=false end end
end

function Feel.destroy(self:any)
	if self.destroyed then return end
	self:reset({}); self.destroyed=true
	for _,slot in self.slots do slot.levelScale:Destroy() end
	if self.root then self.root:Destroy() end
	table.clear(self.slots); table.clear(self.marks); table.clear(self.markRings)
end

return Feel
