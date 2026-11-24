--!strict
-- Eight pooled cosmetic lines. Gameplay name/troops/status layout wins every
-- collision; a title never revives, moves or hides a source-culled label.
local Cosmetics=require(script.Parent.MatchCosmetics)
local Line=require(script.Parent.NameLine)
local Placement=require(script.Parent.LabelPlacement)
local Titles={}
Titles.__index=Titles
function Titles.new():any
	return setmetatable({players={},slots={}},Titles)
end
function Titles.reset(self:any,layout:boolean?)
	for _,slot in self.slots do
		local v=slot.view
		if v then
			v.titleShift,v.titleLabel=0,nil
		end
		slot.previous=v;slot.used=false
	end
	if not layout then self:finish() end
end
function Titles.finish(self:any)
	self.visible=0
	for _,slot in self.slots do
		local v=slot.previous
		if v and (v.titleShift or 0)==0 and v.projected then
			local p=v.projected
			local position=UDim2.fromOffset(0,(p.namePixels/2+p.lineOffset-p.troopPixels/2)/p.guiScale)
			if v.troops.Position~=position then v.troops.Position=position end
		end
		if not slot.used then
			if slot.label.Visible then slot.label.Visible=false end
			slot.view=nil
		end
		if slot.used then self.visible+=1 end
		slot.previous=nil
	end
end
function Titles.draw(self:any,scene:any)
	self.checks=0
	if #self.players==0 or (scene.renderer.options.firstPaint=='full' and not scene.renderer.ready) then self:finish();return end
	local c=scene.renderer.camera
	local candidates={}
	local function candidate(id:number)
		if #candidates>=Cosmetics.titleCap then return end
		local v=scene.nameViews[id]
		if not v or not v.sourceVisible or not v.root.Visible then return end
		local data=Line.titleLayout(v.titleText,v.projected.namePixels,c.scale/64)
		if data then table.insert(candidates,{id=id,view=v,data=data}) end
	end
	candidate(scene.localPlayer)
	for _,id in self.players do if id~=scene.localPlayer then candidate(id) end end
	if #candidates==0 then self:finish();return end
	local bounds={x=c.left+6,y=c.top+6,w=math.max(0,c.viewportWidth-12),h=math.max(0,c.viewportHeight-12)}
	local ink={}
	for id,v in scene.nameViews do if v.sourceVisible and v.root.Visible then
		local rect=scene:nameScreenRect(id)
		if rect then
			table.insert(ink,{id=id,rect=rect})
			-- Dense overview: omit cosmetics rather than run an unbounded search.
			if #ink>128 then self:finish();return end
		end
	end end
	local accepted={}
	local made=false
	for _,item in candidates do
		local v,data=item.view,item.data
		local base=scene:nameScreenRect(item.id)
		if not base then continue end
		local width=math.max(base.w,data.width*c.scale/64+4)
		local rect={x=base.x+(base.w-width)/2,y=base.y,w=width,h=base.h+data.shift*c.scale/64}
		if not Placement.clear(rect,bounds,scene.renderer.labelOccluders or {},6) or not Placement.clear(rect,bounds,accepted,6) then continue end
		local crowded=false
		for _,other in ink do
			self.checks+=1
			if other.id~=item.id and Placement.intersects(rect,other.rect,4) then crowded=true;break end
		end
		if crowded then continue end
		local index=#accepted+1
		local slot=self.slots[index]
		if not slot then
			if made or (scene.newUnitBudget or 0)<2 then continue end
			made=true; scene.newUnitBudget-=2
			local label=Instance.new('TextLabel')
			label.Name,label.BackgroundTransparency,label.BorderSizePixel,label.Active='NationTitle',1,0,false
			label.Font,label.TextColor3,label.TextStrokeTransparency=Enum.Font.SourceSansBold,Color3.fromRGB(255,220,140),1
			label.ZIndex=9
			local stroke=Instance.new('UIStroke');stroke.Color=Color3.fromRGB(26,19,11);stroke.Parent=label
			slot={label=label,stroke=stroke}; self.slots[index]=slot
		end
		slot.view=v;slot.used=true; v.titleLabel=slot.label;v.titleShift=data.shift;v.titleWidth=data.width
		local label=slot.label; local p=v.projected
		if label.Parent~=v.root then label.Parent=v.root end
		if label.Text~=data.text then label.Text=data.text end
		if not label.Visible then label.Visible=true end
		local pixels=math.clamp(data.pixels/p.guiScale,1,100)
		if label.TextSize~=pixels then label.TextSize=pixels end
		local position=UDim2.fromOffset(0,data.top/p.guiScale)
		local size=UDim2.fromOffset(v.width/p.guiScale,data.pixels/p.guiScale)
		if label.Position~=position then label.Position=position end
		if label.Size~=size then label.Size=size end
		local thickness=1.4/(p.guiScale*c.scale/64)
		if slot.stroke.Thickness~=thickness then slot.stroke.Thickness=thickness end
		position=UDim2.fromOffset(0,(p.namePixels/2+p.lineOffset+data.shift-p.troopPixels/2)/p.guiScale)
		if v.troops.Position~=position then v.troops.Position=position end
		table.insert(accepted,rect)
	end
	self:finish()
end
function Titles.destroy(self:any)
	self:reset()
	for _,slot in self.slots do slot.label:Destroy() end
	table.clear(self.slots);table.clear(self.players)
end
return Titles
