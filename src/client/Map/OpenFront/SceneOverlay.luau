--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/passes/UnitPass.ts; StructurePass.ts; StructureLevelPass.ts; BarPass.ts; RailroadPass.ts; NukeTelegraphPass.ts; name-pass/index.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Roblox GUI adapter. Source imagery uses resources/ CC BY-SA masks;
-- ShipArt is original Conquer Countries artwork approved by Bruno.
local Camera = require(script.Parent.CameraTransform)
local Atlas = require(script.Parent.SpriteAtlas)
local Visual = require(script.Parent.UnitVisuals)
local Labels = require(script.Parent.LabelMath)
local NameBox = require(script.Parent.NameBoxCalculator)
local NameClusters = require(script.Parent.NameClusters)
local Defaults = require(script.Parent.RenderDefaults)
local Core = require(script.Parent.RasterCore)
local Trails = require(script.Parent.TrailManager)
local Effects = require(script.Parent.EffectOverlay)
local Relations = require(script.Parent.Relations)
local Sam = require(script.Parent.SamGeometry)
local Selection = require(script.Parent.WarshipSelection)
local PlayerStatus = require(script.Parent.PlayerStatus)
local NameStatus = require(script.Parent.NameStatusOverlay)
local Timings = require(script.Parent.RenderTimings)
local Flag = require(script.Parent.NameFlag)
local NameLine = require(script.Parent.NameLine)
local Cosmetics = require(script.Parent.MatchCosmetics)
local Titles = require(script.Parent.TitleOverlay)
local LabelPlacement = require(script.Parent.LabelPlacement)
local StructureCache = require(script.Parent.StructureAtlas)
local Structure = require(script.Parent.StructureMath)
local Artillery = require(script.Parent.ArtilleryOverlay)
local SabotageReach = require(script.Parent.SabotageReachOverlay)
local Shared = game:GetService('ReplicatedStorage').Shared.OpenFront
local StrikeExecution = require(Shared.Executions.StrikeExecution)
local LauncherExecution = require(Shared.Executions.LauncherExecution)
local FieldWorksExecution = require(Shared.Executions.FieldWorksExecution)
local Policy = require(script.Parent.RenderPolicy)
local Defense = require(script.Parent.DefenseRanges)
local ShipArt = require(script.Parent.ShipArt)
local Feel = require(script.Parent.FeelOverlay)
local Overlay = {}
Overlay.__index = Overlay

local function frame(parent: Instance, name: string, z: number): Frame
	local f = Instance.new("Frame")
	f.Name, f.BorderSizePixel, f.BackgroundTransparency, f.ZIndex = name, 0, 1, z
	f.Parent = parent
	return f
end
local function passParent(renderer: any, pass: string): Frame
	return if renderer.guiLayers then renderer.guiLayers:parent(pass) else renderer.root
end
local function label(parent: Instance, name: string, z: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name, l.BackgroundTransparency, l.BorderSizePixel, l.ZIndex = name, 1, 0, z
	l.Font, l.TextColor3, l.TextStrokeColor3, l.TextStrokeTransparency = Enum.Font.SourceSansBold, Color3.new(1, 1, 1), Color3.new(), .2
	l.Parent = parent
	return l
end
local function image(parent: Instance, content: Content, name: string, z: number): ImageLabel
	local i = Instance.new("ImageLabel")
	i.Name, i.BackgroundTransparency, i.BorderSizePixel, i.ZIndex = name, 1, 0, z
	i.ImageContent, i.ResampleMode = content, Enum.ResamplerMode.Pixelated
	i.Parent = parent
	return i
end
local function ownerColor(core: any, id: number, border: boolean): Color3
	local p = core.palette[id]
	if p == nil then return Color3.fromRGB(130, 130, 130) end
	local c = if border then p.border else p.fill
	return Color3.new(c.r, c.g, c.b)
end
local function localPos(camera: any, x: number, y: number): (number, number)
	local sx, sy = Camera.worldToScreenCoordinates(camera, x, y)
	return sx - camera.left, sy - camera.top
end
local textScales: {[any]: any}=setmetatable({}, {__mode="k"}) :: any
local function textSize(obj: TextLabel, size: number)
	local font=math.clamp(size,1,100)
	if obj.TextSize~=font then obj.TextSize=font end
	local scale=size/font
	local component=textScales[obj]
	if scale~=1 or component then
		if not component then component=Instance.new("UIScale"); component.Parent=obj; textScales[obj]=component end
		if component.Scale~=scale then component.Scale=scale end
	end
end
local function putRect(obj: GuiObject, x: number, y: number, w: number, h: number)
	local textScale=textScales[obj]
	local scale=if textScale then textScale.Scale else 1
	local position,size = UDim2.fromOffset(x,y),UDim2.fromOffset(math.max(0,w/scale),math.max(0,h/scale))
	if obj.Position~=position then obj.Position=position end
	if obj.Size~=size then obj.Size=size end
end

local function barColor(p: number): Color3
	if p < .25 then return Color3.fromRGB(232, 25, 25)
	elseif p < .5 then return Color3.fromRGB(240, 122, 25)
	elseif p < .75 then return Color3.fromRGB(202, 231, 15)
	else return Color3.fromRGB(44, 239, 18) end
end

-- Original: pass layer order: rails, ground units, structures, missiles,
-- telegraphs/bars, names. A single 512×192 atlas is shared by all GUI masks.
function Overlay.new(renderer: any): any
	local asset = game:GetService("AssetService")
	local atlas = asset:CreateEditableImage({Size = Vector2.new(Atlas.width, Atlas.height)})
	assert(atlas, "OpenFront GUI atlas allocation failed")
	local atlasPending = renderer.options ~= nil and renderer.options.firstPaint == "full"
	local ok, err = pcall(function()
		if not atlasPending then
			local pixels=Atlas.rgba(); StructureCache.setSource(pixels)
			atlas:WritePixelsBuffer(Vector2.zero, Vector2.new(Atlas.width, Atlas.height), pixels)
		end
	end)
	if not ok then atlas:Destroy(); error(err, 2) end
	local content = Content.fromObject(atlas)
	local layers,worldTransforms = {},{}
	for i,name in {"Rails","Ground","Structures","Missiles","Telegraphs","Names"} do
		local f=frame(passParent(renderer,name),name,i+2); layers[name]=f
		if name~="Structures" and name~="Telegraphs" then
			f.Size=UDim2.fromOffset(renderer.core.width*64,renderer.core.height*64)
			local scale=Instance.new("UIScale"); scale.Parent=f
			table.insert(worldTransforms,{frame=f,scale=scale})
		else f.Size=UDim2.fromScale(1,1) end
	end
	for _,entry in {{name="PreviewRails",z=3},{name="PreviewText",z=8}} do
		local f=frame(passParent(renderer,entry.name),entry.name,entry.z); f.Size=UDim2.fromScale(1,1); layers[entry.name]=f
	end
	local structureScale=Instance.new("UIScale"); structureScale.Parent=layers.Structures
	local progressScale: UIScale?=nil
	if renderer.guiLayers and renderer.guiLayers.enabled then
		layers.Progress=frame(passParent(renderer,"Progress"),"Progress",5)
		local scale=Instance.new("UIScale"); scale.Parent=layers.Progress;progressScale=scale
	end
	local self = setmetatable({renderer = renderer, atlas = atlas, content = content, layers = layers,
		world = layers.Ground, worldUnit=64, worldScale = worldTransforms[2].scale, worldTransforms=worldTransforms, structureScale = structureScale, progressScale=progressScale,
		units = {}, unitViews = {}, moved = {}, movedTick = -1, railroads = {}, railTypes = {}, railCells = {}, railLines = {}, railRecords = {}, railWanted = {},
		rings = {}, ringPool = {}, trajectories = {}, preview = nil, plans = nil, names = {}, nameViews = {}, roster = {}, tick = 0, tickTime = os.clock(),
		cameraDirty = true, railsDirty = true, namesDirty = true, unitsDirty = true, statusDirty = true,
		spawnPhase = false, ownSpawnRing = false, destroyed = false,
		lastNamesTick = -1, localPlayer = 0, nameAnchorMode = "local", atlasPending = atlasPending, namesPlaced = false,
		namesPending = false, unitsPending = false,
		unitOrder = {}, knownUnits = {}, nameTransitions = {}, friendly = {}, allianceClusters = {},
		trails = Trails.new(renderer.core.width,renderer.core.height)}, Overlay) :: any
	self.effects = Effects.new(renderer, renderer.root,64)
	self.titles=Titles.new(); self.cosmeticOverrides={}; self.blastStyles={}
	for _,f in {self.effects.spawn,self.effects.fx,self.effects.text,self.effects.falloutLayer} do
		f.Size=UDim2.fromOffset(renderer.core.width*64,renderer.core.height*64)
		local scale=Instance.new("UIScale"); scale.Parent=f
		table.insert(worldTransforms,{frame=f,scale=scale})
	end
	self.playerStatus, self.nameStatus = PlayerStatus.new(), NameStatus.new()
	self.profiler = renderer.profiler or Timings.new()
	self.diplomacy = {alliances = {}, incoming = {}, outgoing = {}}
	self.structureCache=StructureCache.new(Policy.structureAtlasPages,function()
		local image=asset:CreateEditableImage({Size=Vector2.new(StructureCache.size,StructureCache.size)})
		if not image then return nil end
		return {image=image,content=Content.fromObject(image)}
	end,function(page,x,y,pixels)
		page.image:WritePixelsBuffer(Vector2.new(x,y),Vector2.new(StructureCache.cell,StructureCache.cell),pixels)
	end)
	self.mobileCache=StructureCache.newMobile(function()
		local img=asset:CreateEditableImage({Size=Vector2.new(480,480)})
		if not img then return nil end
		return {image=img,content=Content.fromObject(img)}
	end,function(page,x,y,pixels)
		page.image:WritePixelsBuffer(Vector2.new(x,y),Vector2.new(15,15),pixels)
	end)
	self.shipArt=ShipArt.new()
	self.shipArt.needed=Policy.smoothShips and atlasPending -- prewarm under the full loading cover
	self.unitCells={}
	for y=0,renderer.core.height-1,128 do for x=0,renderer.core.width-1,128 do
		table.insert(self.unitCells,{x=x,y=y,frames={},units={}})
	end end
	self.pendingIcons,self.adornmentUnits,self.unitCellFor,self.staleUnits={},{},{},{}
	self.adornmentOrder,self.adornmentCursor,self.adornmentRemaining={},0,0
	self.lodCursor,self.lodRemaining=0,0
	self.nameMeasurements,self.namePlayers,self.nameSlots={},{},{}
	self.headImages={}
	self.unitCameraDirty,self.smoothUnits,self.nukeIds=true,{},{}
	self.selection=Selection.new(); self.selectionViews={}; self.highlightTypes={}; self.frameTick=0
	self.rangeViews,self.samRangeKeys,self.samCircles,self.rangePool,self.rangeStrokes={},{},{},{},{}
	self.samRecords={}
	self.defense=Defense.new(renderer.core.width,renderer.core.height); self.defenseRangeKeys={}; self.attacks={}
	self.feel=Feel.new(self,{new=Instance.new,UDim=UDim,UDim2=UDim2,Vector2=Vector2,Color3=Color3})
	self.artillery=Artillery.new(self,{new=Instance.new,UDim2=UDim2,Vector2=Vector2,Color3=Color3,Enum=Enum},StrikeExecution.SPEC)
	self.airfields={};self.strikeRangeKeys={}
	self.sabotageReach=SabotageReach.new(renderer,passParent(renderer,'Ground'))
	return self
end

-- Cell canvases retain world positions through parent-relative coordinates.
-- Visibility is grouped by a fixed 128-tile grid, so native offscreen
-- subtrees can be skipped without touching every unit during navigation.
local function unitParent(self: any, pass: string, tile: number): (Frame,number,number,number,number)
	local core=self.renderer.core
	local bx,by=math.floor((tile%core.width)/128),math.floor(math.floor(tile/core.width)/128)
	local cell=self.unitCells[by*math.ceil(core.width/128)+bx+1]
	if not cell then return self.layers[pass],0,0,core.width,core.height end
	local f=cell.frames[pass]
	if not f then
		f=frame(self.layers[pass],`Units{bx}_{by}`,self.layers[pass].ZIndex)
		f.Position=UDim2.fromScale(cell.x/core.width,cell.y/core.height)
		f.Size=UDim2.fromScale(128/core.width,128/core.height)
		f.Visible=cell.visible~=false; cell.frames[pass]=f
	end
	return f,cell.x,cell.y,128,128
end

local function newUnit(self: any, id: number, structure: boolean, kind: string): any
	local parent = self.layers[if structure then "Structures" else "Ground"]
	local root = frame(parent, `Unit{id}`, if structure then 5 else 4)
	local parts = {}
	local smoothReady=Policy.smoothShips and self.shipArt.content and ShipArt.column(kind)~=nil
	for band = 0, (if structure then 2 elseif smoothReady then 0 else 3) do
		parts[band + 1] = image(root, self.content, `Band{band}`, 5 + band)
	end
	local trail = if kind=='Shell' then image(parent, self.content, "ShellTrail", 4) else nil
	if trail then trail.Visible = false end
	local view: any = {root = root, parts = parts, trail = trail, structure = structure}
	if kind=='Warship' and Policy.smoothShips then
		-- Included in the existing 25-new-view allowance, rather than a burst
		-- of components when hundreds of already-visible ships enter combat.
		local gradient=Instance.new('UIGradient'); gradient.Enabled=false; gradient.Parent=parts[1]
		view.shipGradient=gradient
	end
	self.unitViews[id] = view
	return view
end

local function ensureBar(self: any, view: any, key: string): any?
	local existing = view[key]
	if existing then return existing end
	if self.newUnitBudget<=0 then self.unitsPending,view.adornmentPending=true,true; return nil end
	self.newUnitBudget-=1
	local parent=view.root
	if key=="progress" and view.structure and self.layers.Progress then
		if not view.progressRoot then
			local proxy=frame(self.layers.Progress,"ProgressUnit",5)
			view.progressRoot=proxy
			view.root.Destroying:Connect(function() proxy:Destroy() end)
		end
		parent=view.progressRoot
	end
	local background = frame(parent, key, 11); background.BackgroundTransparency = 0
	background.BackgroundColor3=Color3.new()
	local fill = frame(background, "Fill", 12); fill.BackgroundTransparency = 0
	local bar = {background = background, fill = fill}
	view[key] = bar
	return bar
end

local function spritePart(part: ImageLabel, x: number, y: number, w: number, h: number, color: Color3)
	local offset,size=Vector2.new(x,y),Vector2.new(w,h)
	if part.ImageRectOffset~=offset then part.ImageRectOffset=offset end
	if part.ImageRectSize~=size then part.ImageRectSize=size end
	if part.ImageColor3~=color then part.ImageColor3=color end
	local pos,scale=UDim2.fromOffset(0,0),UDim2.fromScale(1,1)
	if part.Position~=pos then part.Position=pos end
	if part.Size~=scale then part.Size=scale end
	if not part.Visible then part.Visible=true end
end

local function hideUnit(self: any, view: any)
	if not view then return end
	if view.root.Visible then view.root.Visible=false end
	if view.progressRoot then view.progressRoot.Visible=false end
	if view.trail and view.trail.Visible then view.trail.Visible=false end
	if view.iconSlot then
		(if view.structure then self.structureCache else self.mobileCache):release(view.iconSlot); view.iconSlot=nil; view.iconStyle=nil
		view.composed,view.appliedStyle=false,nil
	end
end

local watched={'type','owner','tile','lastTile','active','waitTicks','level','health','maxHealth',
	'underConstruction','constructionStartTick','markedForDeletion','hasTrainStation','targetable',
	'targetUnitId','retreating','trainType','loaded','reloadTicks','dark','expiresAt'}
local function changedUnit(view: any, unit: any): (boolean,boolean)
	if not view or not view.record or not view.root.Visible then return true,false end
	local old=view.record
	for _,key in watched do
		if key~='tile' and key~='lastTile' and old[key]~=unit[key] then return true,false end
	end
	local a,b=old.missileTimerQueue,unit.missileTimerQueue
	if (if a then #a else 0)~=(if b then #b else 0) then return true,false end
	if a then for i,value in a do if not b or b[i]~=value then return true,false end end end
	local wa,wb=old.warship,unit.warship
	if (if wa then wa.state else nil)~=(if wb then wb.state else nil)
		or (if wa then wa.veterancy else nil)~=(if wb then wb.veterancy else nil) then return true,false end
	local moved=old.tile~=unit.tile or old.lastTile~=unit.lastTile
	return moved,moved
end

-- Original: UnitPass.updateUnits / StructurePass.updateStructures / BarPass.
local function shipPose(view: any, unit: any, width: number)
	if view.headingTile~=unit.tile or view.headingLastTile~=unit.lastTile then
		view.heading=ShipArt.heading(unit.tile,unit.lastTile,width,view.heading)
		view.headingTile,view.headingLastTile=unit.tile,unit.lastTile
	end
	if view.smoothShip and view.parts[1].Rotation~=view.heading then view.parts[1].Rotation=view.heading end
end
local function shipCombat(self: any, view: any, color: Color3, active: boolean, owner: number)
	local gradient=view.shipGradient
	if active then
		if not gradient then view.parts[1].ImageColor3=Color3.fromRGB(200,0,0); return end
		if view.shipCombatColor~=color then
			-- Keep bow/stern in the owner's colour. A red midship band carries
			-- the source combat signal without turning the whole hull red.
			self.shipCombatSequences=self.shipCombatSequences or {}
			local cached=self.shipCombatSequences[owner]
			if not cached or cached.color~=color then
				cached={color=color,sequence=ColorSequence.new({ColorSequenceKeypoint.new(0,color),ColorSequenceKeypoint.new(.35,color),
					ColorSequenceKeypoint.new(.42,Color3.fromRGB(200,0,0)),ColorSequenceKeypoint.new(.58,Color3.fromRGB(200,0,0)),
					ColorSequenceKeypoint.new(.65,color),ColorSequenceKeypoint.new(1,color)})}
				self.shipCombatSequences[owner]=cached
			end
			gradient.Color=cached.sequence
			gradient.Rotation=90; view.shipCombatColor=color
		end
		if not gradient.Enabled then gradient.Enabled=true end
		if view.parts[1].ImageColor3~=Color3.new(1,1,1) then view.parts[1].ImageColor3=Color3.new(1,1,1) end
	elseif gradient and gradient.Enabled then gradient.Enabled=false end
end
local function smoothShip(self: any, view: any, kind: string, color: Color3, retreatBlink: boolean?): boolean
	local column=if Policy.smoothShips then ShipArt.column(kind) else nil
	if column==nil then return false end
	if column==2 and retreatBlink then column=3 end
	self.shipArt.needed=true
	if not self.shipArt.content then return false end
	self.mobileCache:release(view.iconSlot); view.iconSlot,view.iconStyle=nil,nil
	for i=#view.parts,2,-1 do view.parts[i]:Destroy(); view.parts[i]=nil end
	local part=view.parts[1]
	if part.ImageContent~=self.shipArt.content then part.ImageContent=self.shipArt.content end
	if part.ResampleMode~=Enum.ResamplerMode.Default then part.ResampleMode=Enum.ResamplerMode.Default end
	spritePart(part,column%ShipArt.columns*ShipArt.cell+1,math.floor(column/ShipArt.columns)*ShipArt.cell+1,ShipArt.size,ShipArt.size,color)
	view.smoothShip,view.composed=true,true
	return true
end
local function cappedWarshipBarSize(zoom: number): (number,number,number)
	local factor=zoom/64
	return math.min(11*zoom,Policy.warshipHealthBarMaxWidth)/factor,
		math.min(3*zoom,Policy.warshipHealthBarMaxHeight)/factor,
		math.min(zoom,Policy.warshipHealthBarMaxBorder)/factor
end
local function drawUnit(self: any, id: number, unit: any, fraction: number, poseOnly: boolean?)
	local renderer = self.renderer
	local actual = renderer.camera
	local _,isStructure=Visual.sprite(unit)
	local factor = if isStructure then self.iconScale else actual.scale/64
	local camera = {scale=actual.scale/factor}
	self.unitDraws=(self.unitDraws or 0)+1
	local view = self.unitViews[id]
	if poseOnly and view and not view.structure and not view.flicker and not view.adornmentPending
		and view.palette==renderer.core.palette[unit.owner] and view.highlightVersion==self.highlightVersion
		and (not view.progress or view.drawTick==self.tick)
		and (not view.iconSlot or not view.iconSlot.ready or view.composed) then
		local x,y=unit.tile%renderer.core.width,math.floor(unit.tile/renderer.core.width)
		local parent,ox,oy,w,h=unitParent(self,'Ground',unit.tile)
		if view.bucket~=parent then view.root.Parent=parent; view.bucket=parent end
		local position=UDim2.fromScale((x+.5-ox)/w,(y+.5-oy)/h)
		if view.root.Position~=position then view.root.Position=position end
		if ShipArt.column(unit.type)~=nil then shipPose(view,unit,renderer.core.width) end
		-- Hulls inherit the world transform. Refresh only capped health geometry
		-- and screen-minimum veterancy text on a pose-only zoom;
		-- rebuilding its hull/style/record here used to bunch work on each tick.
		if Policy.capWarshipHealthBars and unit.type=='Warship' and view.health and view.health.background.Visible and view.zoom~=actual.scale then
			local bw,bh,border=cappedWarshipBarSize(actual.scale)
			local hp=math.clamp(unit.health/unit.maxHealth,0,1)
			putRect(view.health.background,view.size/2-bw/2,view.size/2-6*64,bw,bh)
			putRect(view.health.fill,border,border,hp*(bw-2*border),bh-2*border)
		end
		if view.pips and view.pipZoom~=actual.scale then
			textSize(view.pips,math.max(8/factor,3*camera.scale))
			putRect(view.pips,view.size*.6,view.size*.7,view.size*.7,view.size*.3)
			view.pipZoom=actual.scale
		end
		view.record.tile,view.record.lastTile=unit.tile,unit.lastTile
		view.worldX,view.worldY,view.zoom,view.drawTick=x,y,actual.scale,self.tick
		self.unitPoseDraws=(self.unitPoseDraws or 0)+1
		return
	end
	local v = Visual.unit(unit, renderer.core.width, actual.scale, fraction, true)
	if v == nil then hideUnit(self,view); return end
	local size = v.size / factor
	if unit.type == "Transport" or unit.type == "Trade Ship" then size *= Policy.transportScale end
	local sx, sy = v.x + .5, v.y + .5
	if view == nil or view.structure ~= v.structure or (unit.type == "Shell" and view.trail == nil) then
		if self.newUnitBudget <= 0 then self.unitsPending = true; return end
		self.newUnitBudget -= 1
		if view then (if view.structure then self.structureCache else self.mobileCache):release(view.iconSlot); view.root:Destroy(); if view.trail then view.trail:Destroy() end end
		view = newUnit(self, id, v.structure, unit.type)
	end
	view.adornmentPending=false
	if not view.root.Visible then view.root.Visible = true end
	local fill = ownerColor(renderer.core, unit.owner or 0, false)
	if view.trail then view.trail.Visible = v.trailTile ~= nil end
	if v.trailTile and view.trail then
		local tx, ty = (v.trailTile % renderer.core.width + .5)*64, (math.floor(v.trailTile / renderer.core.width) + .5)*64
		local trailParent,originX,originY=unitParent(self,'Ground',v.trailTile)
		tx-=originX*64; ty-=originY*64
		if view.trail.Parent~=trailParent then view.trail.Parent=trailParent end
		spritePart(view.trail, 7 * 13, 0, 13, 13, fill)
		putRect(view.trail, tx - size / 2, ty - size / 2, size, size)
	end
	local pass=if v.missile then "Missiles" elseif v.structure then "Structures" else "Ground"
	local parent,originX,originY,width,height=self.layers[pass],0,0,renderer.core.width,renderer.core.height
	-- Smoothed missiles may cross several cells in one confirmed move; keep
	-- their small animated set on the pass canvas throughout interpolation.
	if id>=0 and not v.missile then parent,originX,originY,width,height=unitParent(self,pass,unit.tile) end
	if view.bucket~=parent then view.root.Parent=parent; view.bucket=parent end
	if view.root.AnchorPoint~=Vector2.new(.5,.5) then view.root.AnchorPoint=Vector2.new(.5,.5) end
	local position=UDim2.fromScale((sx-originX)/width,(sy-originY)/height)
	if view.root.Position~=position then view.root.Position=position end
	local extent=UDim2.fromOffset(size,size)
	if view.root.Size~=extent then view.root.Size=extent end
	local edge = ownerColor(renderer.core, unit.owner or 0, true)
	if v.structure then
		local dim=next(self.highlightTypes)~=nil and not self.highlightTypes[unit.type]
		-- Original: structure.frag uses territory colour for the local rim;
		-- its map-border palette entry is deliberately grey. Construction
		-- greys bypass classic-icon darkening, and shape coverage is opaque.
		if unit.owner == renderer.core.localPlayer then edge = fill end
		if v.underConstruction then fill, edge = Color3.fromRGB(198, 198, 198), Color3.fromRGB(127, 127, 127)
		else edge = edge:Lerp(Color3.new(), .3) end
		if unit.dark then
			local grey=math.clamp(fill.R*.299+fill.G*.587+fill.B*.114,.28,.65)
			fill,edge=Color3.new(grey,grey,grey),Color3.new(grey*.55,grey*.55,grey*.55)
		end
		local style=`{v.column}:{v.dots}:{fill}:{edge}`
		if view.iconStyle~=style or not view.iconSlot then
			(if view.structure then self.structureCache else self.mobileCache):release(view.iconSlot)
			view.iconSlot=self.structureCache:acquire(v.column,v.dots,fill,edge)
			view.iconStyle=style
		end
		local slot=view.iconSlot
		if slot and slot.ready then
			if not view.composed or view.appliedStyle~=style or view.dim~=dim then
				for i=#view.parts,2,-1 do view.parts[i]:Destroy(); view.parts[i]=nil end
				local part=view.parts[1]
				local content=self.structureCache.pages[slot.page].content
				if part.ImageContent~=content then part.ImageContent=content end
				part.ResampleMode=Enum.ResamplerMode.Default
				spritePart(part,slot.x+1,slot.y+1,64,64,Color3.new(1,1,1))
				part.ImageTransparency=if dim then .7 else 0
			end
			view.appliedStyle,view.dim=style,dim
			view.composed=true
		else
			view.composed=false
			if not view.parts[2] then
				view.parts[2]=image(view.root,self.content,'Band1',6)
				view.parts[3]=image(view.root,self.content,'Band2',7)
			end
			view.parts[1].ImageContent=self.content
			for _,part in view.parts do part.ResampleMode=Enum.ResamplerMode.Default end
			local bx,by,bw,bh=Atlas.shapeRect(v.column)
			spritePart(view.parts[1],bx,by,bw,bh,edge)
			spritePart(view.parts[2],bx,by,bw,bh,fill)
			view.parts[1].ImageTransparency, view.parts[2].ImageTransparency = 0, 0
			view.parts[2].Position, view.parts[2].Size = UDim2.fromScale(.07, .07), UDim2.fromScale(.86, .86)
			view.parts[3].Visible = not v.dots
			if not v.dots then
				local lum = fill.R * .299 + fill.G * .587 + fill.B * .114
				local glyph = if lum < .25 then Color3.new(1, 1, 1) else Color3.new(fill.R * .3, fill.G * .3, fill.B * .3)
				local gx,gy,gw,gh=Atlas.iconRect(v.column)
				spritePart(view.parts[3],gx,gy,gw,gh,glyph)
				view.parts[3].Position, view.parts[3].Size = UDim2.fromScale(.15, .15), UDim2.fromScale(.7, .7)
				view.parts[3].ImageTransparency = .1
			end
			if dim then for _,part in view.parts do part.ImageTransparency=1-(1-part.ImageTransparency)*.3 end end
		end
		if view.composed then view.parts[1].ImageTransparency=if dim then .7 else 0 end
	else
		if smoothShip(self,view,unit.type,if v.angry and view.shipGradient then Color3.new(1,1,1) else fill,
			v.retreating and not v.angry and math.floor(self.tick*.07)%2==1) then
			shipCombat(self,view,fill,v.angry==true,unit.owner)
			shipPose(view,unit,renderer.core.width)
		else
			local mid = fill:Lerp(edge, .5)
			local colors = {fill, mid, fill, edge}
			if v.angry then colors[1], colors[3] = Color3.fromRGB(200, 0, 0), Color3.fromRGB(200, 0, 0)
			elseif v.retreating and math.floor(self.tick * .07) % 2 == 1 then colors[3] = Color3.new() end
			if v.flicker then
				local hot = if unit.type=='Scattershot' then {Color3.fromRGB(177,133,245),Color3.fromRGB(222,200,255),Color3.fromRGB(150,99,229),Color3.fromRGB(250,236,255)}
					else {Color3.fromRGB(255, 0, 0), Color3.fromRGB(255, 128, 0), Color3.fromRGB(255, 255, 0), Color3.new(1, 1, 1)}
				local hash = ((v.x * .1731 + v.y * .3179) % 1)
				local i = math.floor(((self.tick * .3 + hash) % 1) * 4) + 1
				colors = {hot[i], hot[(i + 1) % 4 + 1], hot[i], hot[(i + 1) % 4 + 1]}
			end
			if view.shipGradient then view.shipGradient.Enabled=false end
			view.smoothShip=false
			local style=`{v.column}:{colors[1]}:{colors[2]}:{colors[3]}:{colors[4]}`
			if view.iconStyle~=style or not view.iconSlot then
				self.mobileCache:release(view.iconSlot)
				view.iconSlot=self.mobileCache:acquireMobile(v.column,colors); view.iconStyle=style
			end
			local slot=view.iconSlot
			if slot and slot.ready then
				for i=#view.parts,2,-1 do view.parts[i]:Destroy(); view.parts[i]=nil end
				view.parts[1].ImageContent=self.mobileCache.pages[slot.page].content
				spritePart(view.parts[1],slot.x+1,slot.y+1,13,13,Color3.new(1,1,1))
				view.composed=true
			else
				while #view.parts<4 do table.insert(view.parts,image(view.root,self.content,`Band{#view.parts}`,5+#view.parts)) end
				view.parts[1].ImageContent=self.content
				for band=0,3 do spritePart(view.parts[band+1],v.column*13,band*13,13,13,colors[band+1]) end
				view.composed=false
			end
			for _,part in view.parts do part.Rotation=0; part.ResampleMode=Enum.ResamplerMode.Pixelated end
		end
		local alpha=if v.dim then .4 else 0
		for _, part in view.parts do if part.ImageTransparency~=alpha then part.ImageTransparency=alpha end end
	end
	if v.structure then
		if v.level and not view.level then view.level = label(view.root, "Level", 10) end
		if view.level then view.level.Visible = v.level ~= nil end
		if v.level then view.level.Text = tostring(v.level); textSize(view.level, math.max(10/factor, size * .35))
			view.level.AnchorPoint=Vector2.new(.5,.5)
			putRect(view.level, size * .5, -size * .16, size * .5, size * .4) end
		if v.station and not view.station then view.station = label(view.root, "Station", 10) end
		if view.station then view.station.Visible = v.station == true end
		if v.station then view.station.Text, view.station.TextSize = "▣", math.max(8/factor, size * .2)
			putRect(view.station, size * .65, size * .7, size * .35, size * .35) end
		if v.markedForDeletion and not view.deletion then
			view.deletion = label(view.root, "Deletion", 12)
			view.deletion.Text, view.deletion.TextColor3, view.deletion.TextStrokeTransparency = "×", Color3.fromRGB(255, 64, 64), 1
		end
		if view.deletion then
			view.deletion.Visible = v.markedForDeletion
			if v.markedForDeletion then textSize(view.deletion, math.max(10/factor, size * .7)); view.deletion.Size = UDim2.fromScale(1, 1) end
		end
	end
	local hp = if unit.health and unit.maxHealth and unit.maxHealth > 0 then math.clamp(unit.health / unit.maxHealth,0,1) else 1
	if (v.structure or (unit.type == "Warship" and hp>0)) and hp < 1 then
		local bar = ensureBar(self, view, "health")
		if bar then
			if not bar.background.Visible then bar.background.Visible=true end
			local bw,bh,border,y=11*camera.scale,3*camera.scale,camera.scale,size/2-6*camera.scale
			if v.structure then
				bw,bh,border=math.max(14/factor,size*.85),3/factor,1/factor
				local progress=unit.underConstruction or #(unit.missileTimerQueue or {})>0
				y=(if progress then math.max(size,size/2+9*camera.scale) else size)+2/factor
			elseif Policy.capWarshipHealthBars then
				bw,bh,border=cappedWarshipBarSize(actual.scale)
			end
			putRect(bar.background,size/2-bw/2,y,bw,bh)
			local color=barColor(hp); if bar.fill.BackgroundColor3~=color then bar.fill.BackgroundColor3=color end
			putRect(bar.fill,border,border,hp*(bw-2*border),bh-2*border)
		end
	elseif view.health then view.health.background.Visible = false
	end
	local config=self.renderConfig
	local cooldown=unit.reloadTicks or LauncherExecution.RELOAD[unit.type]
		or (if config then (if unit.type=='SAM Launcher' then config:SAMCooldown() else config:SiloCooldown()) else 90)
	local field=unit.type=='Field Works'
	local duration=if field then FieldWorksExecution.BUILD elseif config then config:unitInfo(unit.type).constructionDuration else nil
	local progress = if field then Visual.fieldProgress(unit,self.tick,FieldWorksExecution.BUILD,FieldWorksExecution.LIFETIME)
		elseif unit.underConstruction and (duration==nil or duration==0) then nil
		else Visual.progress(unit,self.tick,cooldown,if config then config:deletionMarkDuration() else 300,duration)
	if progress~=nil then
		local bar = ensureBar(self, view, "progress")
		if bar then
			if not bar.background.Visible then bar.background.Visible=true end
			putRect(bar.background, size / 2 - 7 * camera.scale, size / 2 + 6 * camera.scale, 14 * camera.scale, 3 * camera.scale)
			local color=barColor(progress); if bar.fill.BackgroundColor3~=color then bar.fill.BackgroundColor3=color end
			if bar.fill.Visible~=(progress>0) then bar.fill.Visible=progress>0 end
			putRect(bar.fill, camera.scale, camera.scale, progress * 12 * camera.scale, camera.scale)
		end
	elseif view.progress then view.progress.background:Destroy(); view.progress=nil
	end
	-- Preserve absolute base opacity; pulse updates never multiply yesterday's
	-- alpha or invalidate the composed owner/grey style cache.
	if unit.dark then
		view.supportBase=view.supportBase or {}
		for i,part in view.parts do view.supportBase[i]=part.ImageTransparency end
	else view.supportBase=nil end
	if view.progressRoot then
		local proxy=view.progressRoot
		if view.progress then
			local progressParent=unitParent(self,"Progress",unit.tile)
			if proxy.Parent~=progressParent then proxy.Parent=progressParent end
			if proxy.Position~=view.root.Position then proxy.Position=view.root.Position end
			if proxy.Size~=view.root.Size then proxy.Size=view.root.Size end
			if proxy.AnchorPoint~=view.root.AnchorPoint then proxy.AnchorPoint=view.root.AnchorPoint end
		end
		local shown=view.progress~=nil and view.root.Visible
		if proxy.Visible~=shown then proxy.Visible=shown end
	end
	local vet = if unit.warship then unit.warship.veterancy or 0 else 0
	if vet > 0 then
		if not view.pips then
			if self.newUnitBudget>0 then self.newUnitBudget-=1; view.pips=label(view.root,'Veterancy',11)
			else self.unitsPending,view.adornmentPending=true,true end
		end
		if view.pips then
			if not view.pips.Visible then view.pips.Visible=true end
			if view.pipVet~=vet then
				view.pips.Text,view.pips.TextColor3=string.rep('▰',math.min(10,vet)),Color3.fromRGB(255,214,0); view.pipVet=vet
			end
			if view.pipZoom~=actual.scale or view.pipSize~=size then
				textSize(view.pips,math.max(8/factor,3*camera.scale))
				putRect(view.pips,size*.6,size*.7,size*.7,size*.3); view.pipZoom,view.pipSize=actual.scale,size
			end
		end
	elseif view.pips then view.pips.Visible = false end
	view.record=table.clone(unit)
	if unit.missileTimerQueue then view.record.missileTimerQueue=table.clone(unit.missileTimerQueue) end
	if unit.warship then view.record.warship=table.clone(unit.warship) end
	if view.iconSlot and not view.iconSlot.ready then self.pendingIcons[id]=true else self.pendingIcons[id]=nil end
	local adorned=view.level or view.station or view.deletion or view.health or view.progress or view.pips
	local tracked=self.adornmentUnits[id]
	self.adornmentUnits[id]=if adorned then true else nil
	if tracked~=self.adornmentUnits[id] then self.adornmentOrderDirty=true end
	view.drawTick=self.tick
	view.worldX,view.worldY,view.size,view.zoom=v.x,v.y,size,actual.scale
	view.palette,view.highlightVersion,view.flicker=renderer.core.palette[unit.owner],self.highlightVersion,v.flicker
	view.blink=if v.retreating then math.floor(self.tick*.07)%2 else nil
	view.lod=v.dots
end

-- Original: RailroadCache tile orientations and RailroadPass zoom/camera gate.
-- A stable symbol inherits camera geometry from its pass. Zoom only changes
-- screen-minimum text; keep the same capped adornment sweep without deriving
-- the whole visual, restyling its atlas entry or cloning its confirmed record.
local function zoomAdornment(self:any,id:number,view:any,unit:any):boolean
	if not view.record or view.adornmentPending or view.flicker or view.progress or (view.health and view.health.background.Visible) or not view.composed
		or self.staleUnits[id] or view.palette~=self.renderer.core.palette[unit.owner]
		or view.highlightVersion~=self.highlightVersion or (view.structure and view.lod~=self.unitLod) then return false end
	if changedUnit(view,unit) then return false end
	local zoom=self.renderer.camera.scale
	local factor=if view.structure then self.iconScale else zoom/64
	local size=view.size
	if view.level and view.level.Visible then
		textSize(view.level,math.max(10/factor,size*.35))
		putRect(view.level,size*.5,-size*.16,size*.5,size*.4)
	end
	if view.station and view.station.Visible then
		view.station.TextSize=math.max(8/factor,size*.2)
		putRect(view.station,size*.65,size*.7,size*.35,size*.35)
	end
	if view.deletion and view.deletion.Visible then
		textSize(view.deletion,math.max(10/factor,size*.7));view.deletion.Size=UDim2.fromScale(1,1)
	end
	if view.pips and view.pips.Visible then
		textSize(view.pips,math.max(8/factor,3*zoom/factor))
		putRect(view.pips,size*.6,size*.7,size*.7,size*.3)
		view.pipZoom,view.pipSize=zoom,size
	end
	view.zoom=zoom
	return true
end

local function rebuildRailTypes(self: any)
	local out,cells = {},{}
	local width = self.renderer.core.width
	for _, path in self.railroads do
		for i, tile in path do
			if not out[tile] then
				local key=math.floor(math.floor(tile/width)/128)*math.ceil(width/128)+math.floor(tile%width/128)+1
				local list=cells[key]
				if not list then list={};cells[key]=list end
				table.insert(list,tile)
			end
			out[tile] = Visual.railType(path[i - 1], tile, path[i + 1], width)
		end
	end
	self.railTypes = out
	self.railCells = cells
	self.railsDirty = true
end

local function railFade(zoom: number): number
	return if Policy.sourceRailFade then Visual.railFade(zoom) else math.clamp((zoom-3)/2,0,1)
end

local function drawRails(self: any)
	self.railsDirty=false
	local camera=self.renderer.camera
	local fade=railFade(camera.scale)
	self.layers.Rails.Visible=fade>0
	self.railRebuilds=(self.railRebuilds or 0)+1
	local x0,y0=Camera.screenToWorldCoordinatesFloat(camera,camera.left-128,camera.top-128)
	local x1,y1=Camera.screenToWorldCoordinatesFloat(camera,camera.left+camera.viewportWidth+128,camera.top+camera.viewportHeight+128)
	local wanted=self.railWanted;table.clear(wanted)
	self.railWantedFade,self.railWantedDetail=fade,camera.scale>=Defaults.railroad.railDetailZoom
	if fade>0 then
		local core=self.renderer.core
		local cols=math.ceil(core.width/128)
		for by=math.max(0,math.floor(y0/128)),math.min(math.ceil(core.height/128)-1,math.floor(y1/128)) do
		for bx=math.max(0,math.floor(x0/128)),math.min(cols-1,math.floor(x1/128)) do
		local tiles=self.railCells[by*cols+bx+1]
		if not tiles then continue end
		for _,tile in tiles do
			self.railVisits=(self.railVisits or 0)+1
			local x,y=tile%core.width,math.floor(tile/core.width)
			if x+.5<x0 or y+.5<y0 or x+.5>x1 or y+.5>y1 then continue end
			table.insert(wanted,tile)
		end end end
	end
	if fade>0 then for i=#wanted+1,#self.railLines do
		if self.railLines[i].Visible then self.railLines[i].Visible=false end
	end end
	self.railCursor,self.visibleRails,self.railTargetCount=1,0,#wanted+32
	self.railsPending=#wanted>0
end

local function commitRails(self: any)
	if not self.railsPending then return end
	local core=self.renderer.core
	local detail,fade=self.railWantedDetail,self.railWantedFade
	-- Resume the retained list instead of revisiting its already committed
	-- prefix on every allocation frame. Camera transforms remain immediate.
	for index=self.railCursor,#self.railWanted do
			local tile=self.railWanted[index]
			local kind=self.railTypes[tile]
			local x,y=tile%core.width,math.floor(tile/core.width)
			local f=self.railLines[index]
			if not f then
				if self.newRailBudget<=0 then self.railCursor=index;return end
				self.newRailBudget-=1
				f=image(self.layers.Rails,self.content,`Track{index}`,3);self.railLines[index]=f
				self.railCreates=(self.railCreates or 0)+1
			end
			local record=self.railRecords[index] or {};self.railRecords[index]=record
			local owner=bit32.band(buffer.readu16(core.tileState,tile*2),4095)
			local palette=core.palette[owner]
			if record.owner~=owner or record.palette~=palette or record.localPlayer~=core.localPlayer or record.kind~=kind or record.detail~=detail then
				local color=Visual.railColor(owner,core.localPlayer,if palette then palette.fill else nil,
					if palette then palette.border else nil,palette~=nil and palette.pattern~=nil)
				spritePart(f,384+(kind-1)*16,if detail then 56 else 72,if detail then 3 else 2,if detail then 3 else 2,Color3.new(color.r,color.g,color.b))
				record.owner,record.palette,record.localPlayer,record.kind,record.detail=owner,palette,core.localPlayer,kind,detail
				record.tile=nil -- spritePart resets the rectangle; restore it below.
			end
			if record.tile~=tile then putRect(f,x*64,y*64,64,64);record.tile=tile end
			if f.ImageTransparency~=1-fade then f.ImageTransparency=1-fade end
			if not f.Visible then f.Visible=true end
			self.visibleRails=index
	end
	self.railsPending=false;self.railCursor=#self.railWanted+1
end

local function trimRails(self: any)
	for _=1,Policy.railDeletesPerFrame do
		local index=#self.railLines
		if index<=(self.railTargetCount or index) then break end
		self.railLines[index]:Destroy();self.railLines[index]=nil;self.railRecords[index]=nil
		self.railDeletes=(self.railDeletes or 0)+1
	end
end

local function newRing(self: any, index: number): any
	local f = frame(self.layers.Telegraphs, `NukeRing{index}`, 7)
	f.BackgroundTransparency = 1
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(1, 0); corner.Parent = f
	local stroke = Instance.new("UIStroke"); stroke.Thickness = 1.5; stroke.Parent = f
	local view = {frame = f, stroke = stroke}
	self.rings[index] = view
	return view
end
local function drawRings(self: any, dirty: boolean)
	if not dirty and not self.screenCameraDirty and self.ringsTick==self.tick then
		for i=1,self.visibleRings or 0 do self.rings[i].stroke.Transparency=.15+.1*math.sin(os.clock()*3) end
		return
	end
	local camera = self.renderer.camera
	local count = 0
	for _,id in self.nukeIds do
		local unit=self.units[id]
		local plan = if self.plans then self.plans:gridPlan(id) else nil
		local t = Visual.telegraph(unit, self.renderer.core.width, self.tick, if plan then plan.startTick else nil, self.renderConfig)
		if t then
			local sx, sy = localPos(camera, t.x, t.y)
			local core = self.renderer.core
			local relation = Relations.classify(unit.owner,self.localPlayer,core.relations,core.relationSize)
			local color = if relation == 0 then Color3.fromRGB(0, 255, 0)
				elseif relation == 1 then Color3.fromRGB(255, 255, 0) else Color3.fromRGB(255, 0, 0)
			for _, radius in {t.inner, t.outer} do
				count += 1
				local view = self.rings[count] or newRing(self, count)
				view.frame.Visible = true
				putRect(view.frame, sx - radius * camera.scale, sy - radius * camera.scale, radius * 2 * camera.scale, radius * 2 * camera.scale)
				view.stroke.Color, view.stroke.Transparency = color, .15 + .1 * math.sin(os.clock() * 3)
			end
		end
	end
	for i = count + 1, #self.rings do self.rings[i].frame.Visible = false end
	self.visibleRings,self.ringsTick=count,self.tick
end

-- Original: NukeTrajectoryPass.rebuildVertices, 128 Bezier segments. The
-- preview exists only while the player aims a nuke, as in the source.
local function drawTrajectories(self: any)
	local count = 0
	local d = self.preview
	if self.drawnTrajectory==d and not self.trajectoryCameraDirty then return end
	self.drawnTrajectory,self.trajectoryCameraDirty=d,false
	if d then
		local layer=self.layers.PreviewAim
		if not layer then
			local c,core=self.renderer.camera,self.renderer.core
			layer=frame(passParent(self.renderer,'PreviewAim'),'PreviewAim',7); self.layers.PreviewAim=layer
			layer.Size=UDim2.fromOffset(core.width*64,core.height*64)
			local x,y=localPos(c,0,0)
			layer.Position=UDim2.fromScale(x/math.max(1,c.viewportWidth),y/math.max(1,c.viewportHeight))
			local scale=Instance.new('UIScale'); scale.Scale=c.scale/64; scale.Parent=layer
			table.insert(self.worldTransforms,{frame=layer,scale=scale})
		end
		local px, py = d.p0x, d.p0y
		local distance = 0
		for i = 1, 128 do
			local t = i / 128; local u = 1 - t
			local x = u^3 * d.p0x + 3*u*u*t*d.p1x + 3*u*t*t*d.p2x + t^3*d.p3x
			local y = u^3 * d.p0y + 3*u*u*t*d.p1y + 3*u*t*t*d.p2y + t^3*d.p3y
			local x0,y0,x1,y1=px*64,py*64,x*64,y*64
			local dx, dy = x1 - x0, y1 - y0
			local len = math.sqrt(dx * dx + dy * dy)
			count += 1
			local f = self.trajectories[count]
			if not f then f = frame(layer, `Trajectory{count}`, 6); f.BackgroundTransparency = 0; self.trajectories[count] = f end
			local untargetable = d.tUntargetableStart >= 0 and t >= d.tUntargetableStart
				and t <= d.tUntargetableEnd
			local dash = if untargetable then Defaults.nukeTrajectory.dashUntargetable else Defaults.nukeTrajectory.dashTargetable
			local gap = if untargetable then Defaults.nukeTrajectory.gapUntargetable else Defaults.nukeTrajectory.gapTargetable
			f.Visible = distance % (dash + gap) < dash
			f.BackgroundColor3 = if t >= d.tSamIntercept then Color3.fromRGB(255, 80, 80) else Color3.new(1, 1, 1)
			f.AnchorPoint = Vector2.new(.5, .5)
			f.Position = UDim2.fromOffset((x0 + x1) / 2, (y0 + y1) / 2)
			f.Size = UDim2.fromOffset(math.max(64/self.renderer.camera.scale, len), Defaults.nukeTrajectory.lineWidth*64/self.renderer.camera.scale)
			f.Rotation = math.deg(math.atan2(dy, dx))
			px, py = x, y; distance += len*self.renderer.camera.scale/64
		end
	end
	for i = count + 1, #self.trajectories do self.trajectories[i].Visible = false end
end

-- Original: SelectionBoxPass + Renderer selected-unit pulse/checker palette.
local function drawSelection(self:any)
	self.selection:prune(self.units,self.localPlayer)
	local count=0
	local core,camera=self.renderer.core,self.renderer.camera
	for _, id in self.selection.ids do
		local u=self.units[id]
		local x,y=u.tile%core.width,math.floor(u.tile/core.width)
		local sx,sy=localPos(camera,x+.5,y+.5)
		local size=13*camera.scale
		if sx+size/2<0 or sy+size/2<0 or sx-size/2>camera.viewportWidth or sy-size/2>camera.viewportHeight then continue end
		local view=self.selectionViews[count+1]
		if not view and self.newUnitBudget>0 then
			self.newUnitBudget-=1; view=image(self.layers.Telegraphs,self.content,'WarshipSelection',7)
			self.selectionViews[count+1]=view
		end
		if not view then continue end
		count+=1; spritePart(view,384+(x+y)%2*16,120,13,13,ownerColor(core,u.owner,false):Lerp(Color3.new(1,1,1),.3))
		putRect(view,sx-size/2,sy-size/2,size,size)
		view.ImageTransparency=1-(.784+.216*math.sin(self.frameTick*.1))
	end
	for i=count+1,#self.selectionViews do self.selectionViews[i].Visible=false end
	if self.dragBox then
		local f=self.dragView
		if not f then
			f=frame(self.layers.Telegraphs,'SelectionDrag',12)
			local stroke=Instance.new('UIStroke'); stroke.Name='Stroke'; stroke.Thickness=1; stroke.Parent=f
			self.dragView=f
		end
		local box=self.dragBox
		f.Visible=true; f.BackgroundColor3=ownerColor(core,self.localPlayer,false); f.BackgroundTransparency=.94
		local stroke=f:FindFirstChild('Stroke') :: UIStroke
		stroke.Color,stroke.Transparency=f.BackgroundColor3,.15
		putRect(f,math.min(box[1],box[3])-camera.left,math.min(box[2],box[4])-camera.top,math.abs(box[3]-box[1]),math.abs(box[4]-box[2]))
	elseif self.dragView then self.dragView.Visible=false end
end

-- Made on first use: headless raster tests load this module without Color3.
local RANGE: {yellow: Color3, red: Color3, blue: Color3}?=nil
local function ranges(): {yellow: Color3, red: Color3, blue: Color3}
	if RANGE==nil then RANGE={yellow=Color3.fromRGB(255,211,64),red=Color3.fromRGB(255,75,69),blue=Color3.fromRGB(77,163,255)} end
	return RANGE :: any
end
local function rangeColor(self:any,owner:number):Color3
	local c=ranges()
	return if owner==self.localPlayer then c.yellow elseif self.friendly[owner] then c.blue else c.red
end

local function hideRange(self:any,key:string)
	local f=self.rangeViews[key]
	if f then f.Visible=false end
end

-- One native filled circle per radius, not a segment per arc. All sizes and
-- centres are retained in world units; only the outline compensates for zoom.
-- No new EditableImage, upload slot, particles or per-frame GUI rebuilding.
local function drawRange(self:any,key:string,x:number,y:number,radius:number,color:Color3,alpha:number?):(Frame?,boolean)
	local c=self.renderer.camera
	local sx,sy=localPos(c,x+.5,y+.5)
	local r=radius*c.scale
	if radius<=0 or sx+r<0 or sy+r<0 or sx-r>c.viewportWidth or sy-r>c.viewportHeight then hideRange(self,key); return nil,false end
	local f=self.rangeViews[key]
	if not f and self.newUnitBudget>0 then
		self.newUnitBudget-=1
		f=table.remove(self.rangePool)
		if not f then
			if not self.layers.Ranges then
				-- Lazy: ordinary matches that show no range keep their existing
				-- steady-state GUI count. Camera transforms stay shared thereafter.
				local layer=frame(passParent(self.renderer,'Ranges'),'Ranges',6)
				local core=self.renderer.core
				layer.Size=UDim2.fromOffset(core.width*64,core.height*64)
				local x0,y0=localPos(c,0,0)
				layer.Position=UDim2.fromScale(x0/math.max(1,c.viewportWidth),y0/math.max(1,c.viewportHeight))
				local scale=Instance.new('UIScale'); scale.Scale=c.scale/64; scale.Parent=layer
				self.layers.Ranges=layer
				table.insert(self.worldTransforms,{frame=layer,scale=scale})
			end
			f=frame(self.layers.Ranges,key,6)
			local corner=Instance.new('UICorner'); corner.CornerRadius=UDim.new(1,0); corner.Parent=f
			local stroke=Instance.new('UIStroke'); stroke.Name='Stroke'; stroke.Parent=f
			self.rangeStrokes[f]=stroke
		end
		f.Name=key
		self.rangeViews[key]=f
	end
	if not f then return nil,true end
	f.Visible=true
	putRect(f,(x+.5-radius)*64,(y+.5-radius)*64,radius*128,radius*128)
	if f.BackgroundColor3~=color then f.BackgroundColor3=color end
	local transparency=1-.09*(alpha or 1)
	if f.BackgroundTransparency~=transparency then f.BackgroundTransparency=transparency end
	local stroke=self.rangeStrokes[f] :: UIStroke
	if stroke.Color~=color then stroke.Color=color end
	local outlineAlpha,thickness=1-.9*(alpha or 1),3*64/c.scale
	if stroke.Transparency~=outlineAlpha then stroke.Transparency=outlineAlpha end
	if stroke.Thickness~=thickness then stroke.Thickness=thickness end
	return f,false
end

local function patrolUnit(self:any):any?
	local u=if self.patrolUnitID then self.units[self.patrolUnitID] else nil
	if not u or u.type~='Warship' or u.active==false or self.localPlayer<=0 or u.owner~=self.localPlayer then
		self.patrolUnitID,self.drawnPatrol=nil,nil
		hideRange(self,'WarshipPatrol')
		return nil
	end
	return u
end

function Overlay.setWarshipPatrolVisible(self:any,id:number?)
	if self.destroyed then return end
	self.patrolUnitID,self.drawnPatrol=id,nil
	patrolUnit(self)
	-- Never leave the previous ship's geometry visible while another is queued.
	hideRange(self,'WarshipPatrol')
end

local function drawWarshipPatrol(self:any)
	local u=patrolUnit(self)
	if not u then return end
	local tile=if u.warship then u.warship.patrolTile else nil
	local core=self.renderer.core
	if type(tile)~='number' or tile~=math.floor(tile) or tile<0 or tile>=core.width*core.height or not self.renderConfig then
		self.drawnPatrol=nil; hideRange(self,'WarshipPatrol'); return
	end
	local radius=self.renderConfig:warshipPatrolRange()
	local old=self.drawnPatrol
	if old and old.tile==tile and old.radius==radius and not self.patrolCameraDirty then return end
	local _,pending=drawRange(self,'WarshipPatrol',tile%core.width,math.floor(tile/core.width),radius,ranges().yellow)
	self.drawnPatrol=if pending then nil else {tile=tile,radius=radius}
	self.patrolCameraDirty=false
end

local function drawDefense(self:any)
	local circles=self.defense:step(self.renderer.core.tileState,Policy.defenseProbeTilesPerFrame,Policy.defenseProbeMs)
	local now=os.clock()
	if self.defenseDrawVersion==self.defense.version and not self.defenseRangesPending
		and not (self.defenseCameraDirty and now-(self.defenseDrawAt or -1)>=.1) then return end
	self.defenseDrawVersion,self.defenseDrawAt,self.defenseCameraDirty=self.defense.version,now,false
	local keys={}
	self.defenseRangesPending=false
	for _,p in circles do
		local key=`DefenseAttack{p.id}`; keys[key]=true
		local _,pending=drawRange(self,key,p.tile%self.renderer.core.width,math.floor(p.tile/self.renderer.core.width),p.radius,ranges().red)
		if pending then self.defenseRangesPending=true end
	end
	for key in self.defenseRangeKeys do if not keys[key] then
		local f=self.rangeViews[key]
		if f then f.Visible=false; table.insert(self.rangePool,f); self.rangeViews[key]=nil end
	end end
	self.defenseRangeKeys=keys
end

local function structureRange(self:any,u:any):number?
	if not u or u.active==false or not self.renderConfig then return nil end
	local config=self.renderConfig
	if u.type=='Artillery' then return config.ARTILLERY_RANGE end
	if u.type=='Coastal Battery' then return config.COASTAL_RANGE end
	if u.type=='Field Works' then return FieldWorksExecution.RADIUS end
	if u.type=='Airfield' then return StrikeExecution.SPEC['Air Strike'].reach end
	if u.type=='Factory' then return config:trainStationMaxRange() end
	if u.type=='Defense Post' then return config:defensePostRange() end
	if u.type=='SAM Launcher' then
		local s=u.samUpgrade
		if s and s.startTick and s.duration and s.duration>0 then
			local target=config:samRange(s.targetLevel)
			return s.startRange+(target-s.startRange)*math.clamp((self.tick-s.startTick)/s.duration,0,1)
		end
		return config:samRange(u.level or 1)
	end
	return nil
end

-- Inspect a rendered structure, then let the UI handle the same tap. The hit
-- radius follows the displayed icon (including Bruno's size override), rather
-- than a fixed ten-tile search that steals distant taps when zoomed in.
function Overlay.inspectRange(self:any,tile:number)
	self.inspectedRange=nil
	if self.spawnPhase or self.buildPreview then return end
	local c,width=self.renderer.camera,self.renderer.core.width
	local x,y=tile%width,math.floor(tile/width)
	local nearest,distance=nil,math.huge
	for _,id in self.unitOrder do
		local u=self.units[id]
		if not structureRange(self,u) then continue end
		local dx,dy=(u.tile%width-x)*c.scale,(math.floor(u.tile/width)-y)*c.scale
		local d=dx*dx+dy*dy
		local radius=Structure.presentationSize(u.type,c.scale)/2+3
		if d<=radius*radius and d<distance then nearest,distance=id,d end
	end
	self.inspectedRange=nearest
end

-- Source SamRadiusPass supplies confirmed/upgrade radii. Bruno's deliberate
-- presentation is full coloured discs instead of animated union arc chords.
-- Collect at 10Hz or on confirmed changes; pool creation shares the scene's
-- 25-view/frame allowance. Offscreen circles allocate nothing.
local function drawSams(self:any,fraction:number)
	local ghost=self.buildPreview
	local visible=self.highlightTypes['SAM Launcher']
	for kind in self.highlightTypes do if Visual.isNuke(kind) or kind=='Paratroopers' then visible=true;break end end
	visible=visible or (ghost and (ghost.ghostType=='SAM Launcher' or Visual.isNuke(ghost.ghostType)
		or ghost.ghostType=='Paratroopers' or ghost.ghostType=='City' or ghost.ghostType=='Missile Silo'))
	visible=visible==true
	local now=os.clock()
	local refresh=self.samsDirty or self.samVisible~=visible or (self.samAnimating and now-(self.samUpdatedAt or -1)>=.1)
	if refresh then
		self.samsDirty=false; self.samVisible,self.samTick,self.samUpdatedAt=visible,self.tick,os.clock()
		self.samCircles=if visible then Sam.collect(self.units,self.unitOrder,self.renderer.core.width,self.tick+fraction,self.localPlayer,
			self.friendly,self.allianceClusters,false) else {}
		self.samAnimating=false
		for _,c in self.samCircles do
			local u=self.units[c.id]; local s=u.samUpgrade
			if s and s.startTick and self.tick+fraction-s.startTick<(s.duration or 0) then self.samAnimating=true; break end
		end
		local keys={}
		for _,c in self.samCircles do keys[`SamRange{c.id}:{c.offset}`]=true end
		for key in self.samRangeKeys do if not keys[key] then
			local f=self.rangeViews[key]
			if f then f.Visible=false; table.insert(self.rangePool,f); self.rangeViews[key]=nil end
		end end
		self.samRangeKeys=keys
	end
	if refresh or (self.rangeCameraDirty and now-(self.samDrawAt or -1)>=.1) or self.samRangesPending then
		self.samDrawAt=now; self.rangeCameraDirty=false
		self.samRangesPending=false
		for _,c in self.samCircles do
			local key=`SamRange{c.id}:{c.offset}`
			local _,pending=drawRange(self,key,c.x,c.y,c.radius,rangeColor(self,c.owner),c.alpha)
			if pending then self.samRangesPending=true end
		end
	end
	local u=if self.inspectedRange then self.units[self.inspectedRange] else nil
	local radius=structureRange(self,u)
	if radius then
		drawRange(self,'InspectedRange',u.tile%self.renderer.core.width,math.floor(u.tile/self.renderer.core.width),radius,rangeColor(self,u.owner))
	else self.inspectedRange=nil; hideRange(self,'InspectedRange') end
	for _=1,math.min(16,math.max(0,#self.rangePool-32)) do
		local f=table.remove(self.rangePool) :: Frame; self.rangeStrokes[f]=nil; f:Destroy()
	end
end

-- Original: StructurePass ghost instance, RangeCirclePass, WorldTextPass cost
-- label and RailroadPass ghost paths. The caller supplies validated/snapped
-- GhostPreviewData; this pass does not calculate buildability or spend gold.
local function drawSpread(self:any,g:any)
	local near,far=g.spreadInnerRadius,g.spreadOuterRadius
	if g.ghostType~='Scattershot' or not near or not far or near<0 or far<=near then return end
	local c=self.renderer.camera
	local x,y=localPos(c,g.radiusTileX+.5,g.radiusTileY+.5)
	local outer=far*c.scale
	if x+outer<0 or y+outer<0 or x-outer>c.viewportWidth or y-outer>c.viewportHeight then return end
	if not self.spreadRoot then
		self.spreadRoot=frame(passParent(self.renderer,'Ranges'),'ScatterSpread',6)
		self.spreadRoot.Size=UDim2.fromScale(1,1);self.spreadRoot.ClipsDescendants=true;self.spreadRings={}
	end
	self.spreadRoot.Visible=true
	for i,radius in {(near+far)/2,near,far} do
		local view=self.spreadRings[i]
		if not view then
			if self.newUnitBudget<=0 then self.ghostPending=true;continue end
			self.newUnitBudget-=1
			local f=frame(self.spreadRoot,'SpreadRing',6)
			f.AnchorPoint=Vector2.new(.5,.5)
			local corner=Instance.new('UICorner');corner.CornerRadius=UDim.new(1,0);corner.Parent=f
			local stroke=Instance.new('UIStroke');stroke.BorderStrokePosition=Enum.BorderStrokePosition.Center;stroke.Parent=f
			view={frame=f,stroke=stroke};self.spreadRings[i]=view
		end
		view.frame.Visible=true
		putRect(view.frame,x,y,radius*2*c.scale,radius*2*c.scale)
		view.stroke.Color=Color3.fromRGB(196,166,245)
		view.stroke.Thickness=if i==1 then (far-near)*c.scale else 1.5
		view.stroke.Transparency=if i==1 then .94 else .65
	end
end
local function drawStrikePreview(self:any,g:any)
	if self.strikePreviewRoot then self.strikePreviewRoot.Visible=false end
	if self.paraLanding then self.paraLanding.Visible=false end
	local previous=self.strikeRangeKeys;self.strikeRangeKeys={}
	for key in previous do hideRange(self,key) end
	local function release()
		for key in previous do if not self.strikeRangeKeys[key] then
			local view=self.rangeViews[key]
			if view then self.rangeViews[key]=nil;table.insert(self.rangePool,view) end
		end end
	end
	local spec=if g then StrikeExecution.SPEC[g.ghostType] else nil
	local para=g and g.ghostType=='Paratroopers'
	if not spec and not para then release();return end
	local core,c=self.renderer.core,self.renderer.camera
	local source=if para then g.paraOriginTile else g.strikeLauncherTile
	local bad=g.validated~=false and (source==nil or (para and (not g.canBuild or g.canAfford==false)))
	local color=if bad then ranges().red else ranges().yellow
	if para then
		if not self.paraLanding and self.newUnitBudget>0 then
			self.newUnitBudget-=1
			local f=image(passParent(self.renderer,'Ranges'),self.content,'ParatrooperLanding',6)
			f.ResampleMode=Enum.ResamplerMode.Default;f.AnchorPoint=Vector2.new(.5,.5)
			self.paraLanding=f
		end
		if not self.paraLanding then self.ghostPending=true
		else
			local x,y=localPos(c,g.radiusTileX+.5,g.radiusTileY+.5)
			local size=math.clamp(16+c.scale,18,28)
			-- spritePart fills its parent and re-shows the image. Apply atlas
			-- styling before this screen-space marker's geometry and culling.
			spritePart(self.paraLanding,352,0,32,32,color)
			putRect(self.paraLanding,x,y,size,size)
			self.paraLanding.Visible=x>=-size and y>=-size and x<=c.viewportWidth+size and y<=c.viewportHeight+size
		end
	elseif spec and spec.reach>0 then
		local used=0
		local function reach(id:number,u:any)
			if u.owner~=self.localPlayer or u.active==false or used>=32 then return end
			local key=`AirfieldReach{id}`;self.strikeRangeKeys[key]=true
			local view,pending=drawRange(self,key,u.tile%core.width,math.floor(u.tile/core.width),g.strikeReach or spec.reach,color,.5)
			if view and view.Visible then used+=1 end
			if pending then self.ghostPending=true end
		end
		for _,id in self.airfields do if self.units[id].tile==g.strikeLauncherTile then reach(id,self.units[id]);break end end
		for _,id in self.airfields do if self.units[id].tile~=g.strikeLauncherTile then reach(id,self.units[id]) end end
	end
	release()
	if source==nil then return end
	local sx,sy=localPos(c,source%core.width+.5,math.floor(source/core.width)+.5)
	local tx,ty=localPos(c,g.radiusTileX+.5,g.radiusTileY+.5)
	local ax,ay,bx,by=Artillery.clipLine(sx,sy,tx,ty,c.viewportWidth,c.viewportHeight)
	if not ax or not ay or not bx or not by then return end
	if not self.strikePreviewRoot then
		if self.newUnitBudget<=0 then self.ghostPending=true;return end
		self.newUnitBudget-=1
		self.strikePreviewRoot=frame(passParent(self.renderer,'Ranges'),'StrikeAim',6);self.strikePreviewRoot.Size=UDim2.fromScale(1,1)
		self.strikeAimLine=frame(self.strikePreviewRoot,'LauncherLine',6);self.strikeAimLine.AnchorPoint=Vector2.new(.5,.5)
		self.strikeAimLine.BackgroundTransparency=.3
	end
	self.strikePreviewRoot.Visible=true
	local line=self.strikeAimLine;line.BackgroundColor3=color
	putRect(line,(ax+bx)/2,(ay+by)/2,math.sqrt((bx-ax)^2+(by-ay)^2),1.5)
	line.Rotation=math.deg(math.atan2(by-ay,bx-ax))
end
local function drawSabotagePreview(self:any,g:any)
	if self.sabotageTarget then self.sabotageTarget.Visible=false end
	if not g or g.ghostType~='Sabotage' then return end
	if not self.sabotageTarget then
		if self.newUnitBudget<=0 then self.ghostPending=true;return end
		self.newUnitBudget-=1
		local f=frame(passParent(self.renderer,'Ranges'),'SabotageTarget',7)
		f.AnchorPoint=Vector2.new(.5,.5);f.BackgroundTransparency=.88
		local stroke=Instance.new('UIStroke');stroke.Thickness=2;stroke.Parent=f
		self.sabotageTarget,self.sabotageStroke=f,stroke
	end
	local tile=g.sabotageTargetTile
	local x,y=g.tileX,g.tileY
	if tile~=nil then x,y=tile%self.renderer.core.width,math.floor(tile/self.renderer.core.width) end
	local c=self.renderer.camera
	local sx,sy=localPos(c,x+.5,y+.5)
	local size=math.clamp(Structure.presentationSize('City',c.scale)+8,18,64)
	local bad=g.validated==false or tile==nil or not g.canBuild or g.canAfford==false
	local color=if bad then ranges().red else ranges().yellow
	local f=self.sabotageTarget
	f.BackgroundColor3=color;self.sabotageStroke.Color=color
	putRect(f,sx,sy,size,size)
	f.Visible=sx>=-size and sy>=-size and sx<=c.viewportWidth+size and sy<=c.viewportHeight+size
end
local function measureText(text: string): number
	local ok,bounds=pcall(function()
		return game:GetService('TextService'):GetTextSize(text,100,Enum.Font.SourceSansBold,Vector2.new(1000000,1000000))
	end)
	return if ok then bounds.X else Flag.halfWidth(text)*200/48
end

-- Bounds of the ink, not the wide transparent TextLabel layout boxes. All
-- dimensions below are actual screen pixels, including nested name UIScales.
function Overlay.nameScreenRect(self:any,id:number,unshifted:boolean?): LabelPlacement.Rect?
	local view=self.nameViews[id]
	if not view or not view.sourceVisible or not view.projected or not view.sx then return nil end
	if not unshifted and self.layers.Names.Visible==false then return nil end
	if not unshifted and view.labelHidden then return nil end
	local c,p=self.renderer.camera,view.projected
	local x,y=Camera.worldToScreenCoordinates(c,view.sx/64,view.sy/64)
	if not unshifted then x+=view.labelDx or 0; y+=view.labelDy or 0 end
	local factor=c.scale/64
	if view.troopMeasureText~=view.troops.Text then
		view.troopMeasureText=view.troops.Text
		view.troopMeasure=measureText(view.troops.Text or '')
	end
	local lineWidth=view.lineWidth or 0
	if lineWidth==0 then
		local measured=self.nameMeasurements[view.text]
		if not measured then measured=measureText(view.text);self.nameMeasurements[view.text]=measured end
		lineWidth=measured*p.namePixels/100
	end
	local width=math.max(lineWidth,(view.troopMeasure or 0)*p.troopPixels/100,if view.titleLabel then view.titleWidth or 0 else 0)*factor
	local top=y-p.namePixels*factor*.525
	local bottom=y+(p.lineOffset+(view.titleShift or 0)+p.troopPixels/2)*factor
	local left,right=x-width/2,x+width/2
	local function include(obj:any)
		if not obj or not obj.Visible then return end
		local s=p.guiScale*factor
		local ox=x-view.width*factor/2+obj.Position.X.Offset*s
		local oy=y-p.namePixels*factor/2+obj.Position.Y.Offset*s
		left,right=math.min(left,ox),math.max(right,ox+obj.Size.X.Offset*s)
		top,bottom=math.min(top,oy),math.max(bottom,oy+obj.Size.Y.Offset*s)
	end
	for _,entry in view.statusIcons or {} do include(entry.base); include(entry.fill) end
	include(view.statusEmoji); include(view.nativeEmoji)
	local pad=NameLine.outline(p.namePixels*factor)+1
	return {x=left-pad,y=top-pad,w=right-left+pad*2,h=bottom-top+pad*2}
end

function Overlay.layoutLabels(self:any)
	if not self.labelLayoutDirty then return end
	self.labelLayoutDirty=false
	self.titles:reset(true)
	local c=self.renderer.camera
	local obstacles=self.renderer.labelOccluders or {}
	if #obstacles==0 and not self.hadLabelOccluders and #self.titles.players==0 then self.titles:finish();return end
	self.hadLabelOccluders=#obstacles>0
	local bounds={x=c.left+6,y=c.top+6,w=math.max(0,c.viewportWidth-12),h=math.max(0,c.viewportHeight-12)}
	for id,view in self.nameViews do
		local rect=Overlay.nameScreenRect(self,id,true)
		local dx,dy=0,0
		local shown=true
		if rect and #obstacles>0 then
			if id==self.localPlayer then
				local x,y=LabelPlacement.own(rect,bounds,obstacles)
				shown=x~=nil; dx,dy=x or 0,y or 0
			else shown=LabelPlacement.clear(rect,bounds,obstacles,6) end
		end
		view.labelHidden=not shown
		local visible=shown and view.sourceVisible==true
		if view.root.Visible~=visible then view.root.Visible=visible end
		if rect then
			local position=UDim2.fromOffset(view.sx-view.width/2+dx*64/c.scale,view.sy-view.projected.namePixels/2+dy*64/c.scale)
			if view.root.Position~=position then view.root.Position=position end
		end
		view.labelWorldDx,view.labelWorldDy=dx*64/c.scale,dy*64/c.scale
		view.labelDx,view.labelDy=dx,dy
	end
	self.titles:draw(self)
end

local function placeBuildCost(self:any)
	if not self.costLayoutDirty then return end
	self.costLayoutDirty=false
	local g,cost=self.buildPreview,self.ghostCost
	if not g or not cost or not (g.showCost and g.cost>0 or (g.multiplier or 1)>1) then return end
	local c=self.renderer.camera
	local obstacles={}
	for id,view in self.nameViews do
		if not view.labelHidden then
			local rect=Overlay.nameScreenRect(self,id)
			if rect then table.insert(obstacles,rect) end
		end
	end
	for _,rect in self.renderer.labelOccluders or {} do table.insert(obstacles,rect) end
	local sx,sy=Camera.worldToScreenCoordinates(c,g.tileX+.5,g.tileY+.5)
	local rect=LabelPlacement.cost(sx,sy,{x=c.left+6,y=c.top+6,w=math.max(0,c.viewportWidth-12),h=math.max(0,c.viewportHeight-12)},obstacles)
	cost.Visible=rect~=nil
	if rect then putRect(cost,rect.x-c.left,rect.y-c.top,rect.w,rect.h) end
end

local function drawBuildPreview(self:any)
	local g=self.buildPreview
	if self.drawnBuildPreview==g and not self.previewCameraDirty and not self.ghostPending and not self.strikePreviewDirty then return end
	self.strikePreviewDirty=false
	self.drawnBuildPreview,self.previewCameraDirty,self.ghostPending=g,false,false
	self.costLayoutDirty=true
	local camera,core=self.renderer.camera,self.renderer.core
	local function hide()
		if self.spreadRoot then self.spreadRoot.Visible=false end
		for _, view in self.ghostViews or {} do view.root.Visible=false end
		if self.warshipGhost then self.warshipGhost.root.Visible=false end
		if self.ghostCost then self.ghostCost.Visible=false end
		hideRange(self,'BuildRange')
		hideRange(self,'BuildInnerRange')
		for _, f in self.ghostRails or {} do f.Visible=false end
	end
	hide()
	drawStrikePreview(self,g)
	drawSabotagePreview(self,g)
	if not g then return end
	drawSpread(self,g)
	local sx,sy=localPos(camera,g.tileX+.5,g.tileY+.5)
	local _,structure=Visual.sprite({type=g.ghostType})
	if structure then
		self.ghostViews=self.ghostViews or {}
		local placements={{x=g.tileX,y=g.tileY,alpha=.5}}
		if g.canUpgrade and g.upgradeTargetTile~=nil then
			table.insert(placements,{x=g.upgradeTargetTile%core.width,y=math.floor(g.upgradeTargetTile/core.width),alpha=.6})
		end
		for i,p in placements do
			local view=self.ghostViews[i]
			if not view and self.newUnitBudget>0 then
				self.newUnitBudget-=1
				local root=frame(self.layers.Structures,'BuildGhost',5)
				local parts={}
				for band=1,3 do parts[band]=image(root,self.content,`GhostBand{band}`,4+band); parts[band].ResampleMode=Enum.ResamplerMode.Default end
				local stroke=Instance.new('UIStroke'); stroke.Parent=root
				view={root=root,parts=parts,ghostStroke=stroke}; self.ghostViews[i]=view
			end
			if not view then self.ghostPending=true end
			if view then
				local column=Visual.sprite({type=g.ghostType}) :: number
				local invalid=g.validated~=false and ((not g.canBuild and not g.canUpgrade) or g.canAfford==false)
				local fill=if invalid then ranges().red elseif g.validated==false then Color3.fromRGB(210,210,210)
					else ownerColor(core,g.ownerID or self.localPlayer,false)
				local edge=fill:Lerp(Color3.new(),.3)
				local lum=fill.R*.299+fill.G*.587+fill.B*.114
				local glyph=if lum<.25 then Color3.new(1,1,1) else fill:Lerp(Color3.new(),.7)
				view.root.Visible=true; view.root.AnchorPoint=Vector2.new(.5,.5)
				view.root.Position=UDim2.fromScale((p.x+.5)/core.width,(p.y+.5)/core.height)
				local size=Structure.presentationSize(g.ghostType,camera.scale)/self.iconScale
				view.root.Size=UDim2.fromOffset(size,size)
				local bx,by,bw,bh=Atlas.shapeRect(column)
				spritePart(view.parts[1],bx,by,bw,bh,edge)
				spritePart(view.parts[2],bx,by,bw,bh,fill)
				view.parts[2].Position,view.parts[2].Size=UDim2.fromScale(.07,.07),UDim2.fromScale(.86,.86)
				local gx,gy,gw,gh=Atlas.iconRect(column)
				spritePart(view.parts[3],gx,gy,gw,gh,glyph)
				view.parts[3].Position,view.parts[3].Size=UDim2.fromScale(.15,.15),UDim2.fromScale(.7,.7)
				-- Absolute alpha: repeatedly multiplying cached opacity made ghosts
				-- disappear. Preview symbols never enter confirmed-unit/style caches.
				for band,part in view.parts do part.Visible=true; part.ImageTransparency=1-p.alpha*(if band==3 then .9 else 1) end
				local stroke=view.ghostStroke
				stroke.Thickness=1.5/self.iconScale
				stroke.Enabled=g.canUpgrade==true or invalid
				stroke.Color=if g.canUpgrade and not invalid then Color3.new(0,.8,0) else ranges().red
			end
		end
	elseif g.ghostType=='Warship' then
		local view=self.warshipGhost
		if not view and self.newUnitBudget>0 then
			self.newUnitBudget-=1
			local root=frame(self.layers.Ground,'WarshipGhost',5)
			local parts={}
			for band=1,4 do parts[band]=image(root,self.content,`GhostBand{band}`,4+band) end
			view={root=root,parts=parts}; self.warshipGhost=view
		end
		if not view then self.ghostPending=true
		else
			-- Mobile sprites use four 13px bands, not the structure masks.
			-- This retained advisory symbol never enters confirmed-unit caches.
			local column=Visual.sprite({type='Warship'}) :: number
			local invalid=g.validated~=false and ((not g.canBuild and not g.canUpgrade) or g.canAfford==false)
			local fill=if invalid then ranges().red elseif g.validated==false then Color3.fromRGB(210,210,210)
				else ownerColor(core,g.ownerID or self.localPlayer,false)
			local edge=fill:Lerp(Color3.new(),.3)
			local colors={fill,fill:Lerp(edge,.5),fill,edge}
			view.root.Visible=true; view.root.AnchorPoint=Vector2.new(.5,.5)
			view.root.Position=UDim2.fromScale((g.tileX+.5)/core.width,(g.tileY+.5)/core.height)
			view.root.Size=UDim2.fromOffset(13*64,13*64)
			if smoothShip(self,view,'Warship',fill) then
				view.parts[1].Rotation=0; view.parts[1].ImageTransparency=.5
			else
				while #view.parts<4 do table.insert(view.parts,image(view.root,self.content,`GhostBand{#view.parts+1}`,5+#view.parts)) end
				view.parts[1].ImageContent=self.content
				for band,part in view.parts do
					spritePart(part,column*13,(band-1)*13,13,13,colors[band])
					part.Visible=true; part.ImageTransparency=.5
				end
			end
		end
	end
	if g.rangeRadius and g.rangeRadius>0 then
		local badField=g.ghostType=='Field Works' and (not g.canBuild or g.canAfford==false)
		local aimColor=if badField or (StrikeExecution.SPEC[g.ghostType] and g.validated~=false and g.strikeLauncherTile==nil) then ranges().red else ranges().yellow
		local outer,pending=drawRange(self,'BuildRange',g.radiusTileX,g.radiusTileY,g.rangeRadius,aimColor)
		self.ghostRange=outer; if pending then self.ghostPending=true end
		if g.innerRangeRadius and g.innerRangeRadius>0 then
			local _,innerPending=drawRange(self,'BuildInnerRange',g.radiusTileX,g.radiusTileY,g.innerRangeRadius,ranges().yellow)
			if innerPending then self.ghostPending=true end
		end
	end
	local showCost=g.showCost and g.cost>0
	local multiplier=g.multiplier or 1
	if showCost or multiplier>1 then
		local cost=self.ghostCost
		if not cost then cost=label(self.layers.PreviewText,'BuildCost',14); self.ghostCost=cost end
		cost.Visible=true; cost.TextSize=18
		cost.Text=(if multiplier>1 then `×{multiplier}\n` else '')..(if showCost then Labels.renderNumber(g.cost) else '')
		cost.TextColor3=if not g.canAfford then Color3.new(1,.3,.3) elseif not g.canBuild and not g.canUpgrade then Color3.new(.6,.6,.6) else Color3.new(1,1,1)
		putRect(cost,sx-90,sy+25,180,44)
	end
	self.ghostRails=self.ghostRails or {}
	local count=0
	for _, path in g.ghostRailPaths or {} do for i=2,#path do
		local a,b=path[i-1],path[i]
		local x0,y0=localPos(camera,a%core.width+.5,math.floor(a/core.width)+.5)
		local x1,y1=localPos(camera,b%core.width+.5,math.floor(b/core.width)+.5)
		local f=self.ghostRails[count+1]
		if not f and self.newUnitBudget>0 then self.newUnitBudget-=1; f=frame(self.layers.PreviewRails,'GhostRail',4); self.ghostRails[count+1]=f end
		if not f then self.ghostPending=true end
		if f then
			count+=1; f.Visible=true; f.BackgroundColor3=Color3.new(.8,.8,.8); f.BackgroundTransparency=.5
			f.AnchorPoint=Vector2.new(.5,.5); f.Position=UDim2.fromOffset((x0+x1)/2,(y0+y1)/2)
			f.Size=UDim2.fromOffset(math.sqrt((x1-x0)^2+(y1-y0)^2),math.max(1,camera.scale)); f.Rotation=math.deg(math.atan2(y1-y0,x1-x0))
		end
	end end
end

-- Source NameBoxCalculator input from local confirmed tile state. This
-- fallback uses each owner's whole-territory bounds; authoritative cluster
-- bounds/name anchors will override it when the replication field arrives.
local function fallbackNames(self: any)
	local core = self.renderer.core
	if self.spawnPhase then
		for _, p in self.roster do
			self.names[p.smallID] = NameBox.placeSpawnName({width = core.width, height = core.height} :: any,
				{id = p.smallID, name = p.displayName or p.name, spawnTile = p.spawnTile, borderTiles = {}})
		end
		self.namesDirty = false
		return
	end
	local scan = self.nameScan
	if scan == nil then scan = {cursor = 0, stats = {}, place = 1}; self.nameScan = scan end
	local stats = scan.stats
	local started = os.clock()
	local endCursor = math.min(core.width * core.height, scan.cursor + 16384)
	while scan.cursor < endCursor do
		local tile = scan.cursor
		scan.cursor += 1
		local owner = bit32.band(buffer.readu16(core.tileState, tile * 2), 4095)
		if owner > 0 then
			local x, y = tile % core.width, math.floor(tile / core.width)
			local st = stats[owner]
			if st == nil then st = {minX = x, minY = y, maxX = x, maxY = y, border = {}}; stats[owner] = st end
			st.minX, st.minY = math.min(st.minX, x), math.min(st.minY, y)
			st.maxX, st.maxY = math.max(st.maxX, x), math.max(st.maxY, y)
			local border = x == 0 or y == 0 or x == core.width - 1 or y == core.height - 1
			if not border then
				border = bit32.band(buffer.readu16(core.tileState, (tile - 1) * 2), 4095) ~= owner
					or bit32.band(buffer.readu16(core.tileState, (tile + 1) * 2), 4095) ~= owner
					or bit32.band(buffer.readu16(core.tileState, (tile - core.width) * 2), 4095) ~= owner
					or bit32.band(buffer.readu16(core.tileState, (tile + core.width) * 2), 4095) ~= owner
			end
			if border then table.insert(st.border, tile) end
		end
		if scan.cursor % 2048 == 0 and (os.clock() - started) * 1000 >= 4 then break end
	end
	if scan.cursor < core.width * core.height then return end
	local terrain = core.terrain
	local map = {width = core.width, height = core.height,
		isShore = function(tile: number): boolean return bit32.band(buffer.readu8(terrain, tile), 64) ~= 0 end,
		isOcean = function(tile: number): boolean return bit32.band(buffer.readu8(terrain, tile), 32) ~= 0 end,
		magnitude = function(tile: number): number return bit32.band(buffer.readu8(terrain, tile), 31) end,
		owner = function(tile: number): number return bit32.band(buffer.readu16(core.tileState, tile * 2), 4095) end,
		hasFallout = function(tile: number): boolean return bit32.band(buffer.readu16(core.tileState, tile * 2), 8192) ~= 0 end}
	for index = scan.place, math.min(#self.roster, scan.place + 3) do
		local p = self.roster[index]
		local st = stats[p.smallID]
		if st then
			self.names[p.smallID] = NameBox.placeName(map, {id = p.smallID, name = p.displayName or p.name,
				borderTiles = st.border, largestClusterBoundingBox = NameClusters.largestBorderBounds(st.border, core.width, core.height)})
		elseif p.spawnTile then
			self.names[p.smallID] = NameBox.placeSpawnName(map, {id = p.smallID, name = p.displayName or p.name,
				spawnTile = p.spawnTile, borderTiles = {}})
		end
		scan.place = index + 1
		if (os.clock() - started) * 1000 >= 4 then break end
	end
	if scan.place > #self.roster then self.nameScan = nil; self.namesDirty = false end
end

-- Ported from RoWorld 2be8efb (src/client/Map/NameLayer.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
-- _plate/tick inline flag/head/name layout; retain our FlagArt and measured-font cache.
local function drawNameLine(self: any, view: any, p: any, pixels: number, width: number, guiScale: number)
	local value = p.flag
	if view.flagValue ~= value then
		view.flagValue, view.flagData = value, Flag.resolve(self.renderer.flagArt, value)
	end
	local data = view.flagData
	if data and not view.flag then
		if self.nameStatus.budget <= 0 then self.namesPending = true
		else
			self.nameStatus.budget -= 1
			local img = Instance.new("ImageLabel")
			img.Name, img.BackgroundTransparency, img.BorderSizePixel, img.ZIndex = "Flag", 1, 0, 9
			img.ScaleType, img.ResampleMode = Enum.ScaleType.Fit, Enum.ResamplerMode.Default
			img.Parent = view.root; view.flag = img
		end
	end
	local userId = NameLine.userId(p)
	view.headUserId, view.headPending = userId, false
	if userId and not view.head then
		if self.nameStatus.budget <= 0 then self.namesPending, view.headPending = true, true
		else
			self.nameStatus.budget -= 1
			local head = Instance.new("ImageLabel")
			head.Name, head.BackgroundColor3, head.BorderSizePixel, head.ZIndex = "Head", Color3.fromRGB(40,52,82), 0, 9
			head.ScaleType, head.ResampleMode = Enum.ScaleType.Fit, Enum.ResamplerMode.Default
			local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(.5,0); corner.Parent = head
			local stroke = Instance.new("UIStroke")
			stroke.Color, stroke.Transparency, stroke.Thickness = Color3.new(), .4, 1
			stroke.Parent = head
			head.Parent = view.root; view.head = head
		end
	end
	-- Measure the actual font independently of ancestor UIScales. TextBounds
	-- is a native layout result, not a logical-world width under nested scales.
	local measured=self.nameMeasurements[view.text]
	if not measured and (data or userId) then
		measured=measureText(view.text)
		self.nameMeasurements[view.text]=measured
	end
	local line = NameLine.layout((measured or 0) * pixels / 100, pixels, data ~= nil, userId ~= nil)
	local namePosition = UDim2.fromOffset(line.nameX / guiScale, 0)
	if view.name.Position ~= namePosition then view.name.Position = namePosition end
	view.lineWidth = line.width
	if view.head then
		local head = view.head
		if userId then
			local url = self.headImages[userId]
			if not url then
				url = `rbxthumb://type=AvatarHeadShot&id={userId}&w=150&h=150`
				self.headImages[userId] = url
			end
			if head.Image ~= url then head.Image = url end
			local position = UDim2.fromOffset((width/2 + line.headX)/guiScale, (pixels-line.headH)/2/guiScale)
			local size = UDim2.fromOffset(line.headH/guiScale,line.headH/guiScale)
			if head.Position ~= position then head.Position = position end
			if head.Size ~= size then head.Size = size end
		elseif head.Image ~= "" then head.Image = "" end
		if head.Visible ~= (userId ~= nil) then head.Visible = userId ~= nil end
	end
	if view.flag then
		local img = view.flag
		if data then
			if view.flagPage ~= data.page or view.flagKey ~= data.key then
				img.Image, img.ImageRectOffset, img.ImageRectSize = data.page, Vector2.new(data.x, data.y), Vector2.new(data.w, data.h)
				view.flagPage, view.flagKey = data.page, data.key
			end
			local position = UDim2.fromOffset((width/2 + line.flagX)/guiScale, (pixels-line.flagH)/2/guiScale)
			local size = UDim2.fromOffset(line.flagW/guiScale,line.flagH/guiScale)
			if img.Position ~= position then img.Position = position end
			if img.Size ~= size then img.Size = size end
			img.ImageTransparency = 1 - Defaults.name.flagAlpha
		end
		if img.Visible ~= (data ~= nil) then img.Visible = data ~= nil end
	end
end

local statusKeys={'crown','traitor','disconnected','alliance','allianceReq','target','embargo','nukeActive','nukeTargetsMe',
	'traitorRemainingTicks','allianceFraction','allianceRemainingTicks','emoji'}
local function sameStatus(a: any,b: any): boolean
	if a==b then return true end
	if not a or not b then return false end
	for _,key in statusKeys do
		if a[key]~=b[key] then return false end
	end
	return true
end
local emptyStatus={traitorRemainingTicks=0,allianceFraction=0,allianceRemainingTicks=0}
local function drawTroops(view: any,p: any,index: number,now: number)
	local bucket=Labels.troopBucket(now,index-1)
	if bucket~=view.troopBucket then
		view.troopBucket=bucket
		if view.troopValue~=(p.troops or 0) then
			view.troopValue=p.troops or 0
			local key,magnitude=Labels.troopDisplayKey(view.troopValue)
			if view.troopKey~=key or view.troopMagnitude~=magnitude then
				view.troopKey,view.troopMagnitude=key,magnitude
				local text=Labels.renderTroops(view.troopValue)
				if view.troops.Text~=text then view.troops.Text=text end
			end
		end
	end
end
local function namePose(view: any,x: number,y: number)
	if view.sx==x and view.sy==y then return end
	local p=view.projected
	local position=UDim2.fromOffset(x-view.width/2+(view.labelWorldDx or 0),y-p.namePixels/2+(view.labelWorldDy or 0))
	if view.root.Position~=position then view.root.Position=position end
	view.sx,view.sy=x,y
end
local function nameAnchor(self: any,id: number,now: number): any
	local transition=self.nameTransitions[id]
	if not transition then return self.names[id] end
	local elapsed=now-transition.time
	local current=transition.current
	if not current then current={}; transition.current=current end
	current.x,current.y=Labels.lerp(transition.x,transition.target.x,elapsed),Labels.lerp(transition.y,transition.target.y,elapsed)
	current.size=Labels.lerp(transition.size,transition.target.size,elapsed)
	if current.x==transition.target.x and current.y==transition.target.y and current.size==transition.target.size then
		self.nameTransitions[id]=nil
	end
	return current
end
local function setNameVisible(view:any,visible:boolean)
	view.sourceVisible=visible
	local shown=visible and not view.labelHidden
	if view.root.Visible~=shown then view.root.Visible=shown end
end
local function drawNames(self: any)
	local camera = self.renderer.camera
	local now=os.clock()
	local capFraction=if Policy.capNameScreenHeight then Policy.nameMaxViewportHeight else nil
	local capLimit=if capFraction then camera.viewportHeight*capFraction else math.huge
	local filmPixels=self.filmLabelPixels
	if filmPixels then capLimit=filmPixels*camera.viewportHeight/1920 end
	local maintenance=now-(self.lastNameMaintenance or -1)>=.1
	local all=maintenance or self.cameraDirty or self.statusDirty or self.namesPending or self.nameStatus.pending
	if maintenance then self.lastNameMaintenance=now end
	local x0,y0=Camera.screenToWorldCoordinatesFloat(camera,camera.left-300,camera.top-100)
	local x1,y1=Camera.screenToWorldCoordinatesFloat(camera,camera.left+camera.viewportWidth+300,camera.top+camera.viewportHeight+100)
	self.namesAnimating=false
	self.namesPending=false
	if self.statusDirty or not self.statuses then
		local statusStarted = self.profiler:begin()
		self.statuses = self.playerStatus:compute(self.roster, self.units, self.renderer.core.tileState,
			self.localPlayer, self.diplomacy, self.tick, self.renderConfig)
		self.statusDirty = false
		self.profiler:finish("status", statusStarted)
	end
	local statuses = self.statuses
	self.nameStatus:beginFrame(self.newUnitBudget)
	local function drawName(index: number,p: any)
		local cosmetic=self.cosmeticOverrides[p.smallID] or p
		self.nameVisits=(self.nameVisits or 0)+1
		local transition=self.nameTransitions[p.smallID]
		local view = self.nameViews[p.smallID]
		-- Hidden transitions retain analytic start/target/time. Maintenance and
		-- camera changes reveal their current state without replay.
		if transition and not all and (not view or not view.sourceVisible) then return end
		local anchor=nameAnchor(self,p.smallID,now)
		if anchor and (p.alive ~= false or (self.spawnPhase and p.spawnTile ~= nil)) then
			local inView=anchor.x>x0 and anchor.x<x1 and anchor.y>y0 and anchor.y<y1
			if not inView then if view then setNameVisible(view,false) end; return end
			local status = statuses[p.smallID] or emptyStatus
			local cached = view and view.sizing
			local rawCached=view and view.sourceSizing
			local sourceLodDirty=rawCached and self.nameLodDirty and (status.target or rawCached.visible~=(rawCached.nameWorldScale*72*camera.scale/camera.viewportWidth>=Defaults.name.cullThreshold))
			local capDirty=view and (view.filmPixels~=filmPixels or view.capLimit~=capLimit or ((view.capped or (view.rawNameWorldScale or 0)*camera.scale*48>capLimit) and view.zoom~=camera.scale))
			local anchorSize=math.max(1,math.floor(anchor.size))
			local palette=self.renderer.core.palette[p.smallID]
			local sourceText=p.displayName or p.name
			local statusChanged=not sameStatus(view and view.statusRecord,status)
			if view and not statusChanged then view.statusRecord=status end
			-- Camera translation is inherited; an easing position needs only its
			-- root offset. Leave text, flags, colours and icons untouched.
			if cached and not capDirty and not sourceLodDirty and view.sourceVisible and view.anchorSize==anchorSize and view.targeted==status.target
				and view.viewportWidth==camera.viewportWidth and (not maintenance or (view.zoom==camera.scale and view.strokeZoom==camera.scale))
				and view.palette==palette and view.playerType==p.type and view.sourceText==sourceText and view.flagValue==p.flag
				and view.titleText==Cosmetics.title(cosmetic) and view.goldName==Cosmetics.goldName(cosmetic)
				and view.headUserId==NameLine.userId(p) and not view.headPending
				and not (p.flag and not view.flag) and not statusChanged and not view.statusPending and view.statusContent==self.nameStatus.content
				and view.statusConfig==self.renderConfig then
				if self.nameTransitions[p.smallID] then self.namesAnimating=true end
				namePose(view,anchor.x*64,anchor.y*64)
				drawTroops(view,p,index,now)
				return
			end
			local raw,size,projected
			if rawCached and view.anchorSize == anchorSize and (not status.target or view.sourceZoom == camera.scale)
				and view.viewportWidth == camera.viewportWidth and view.targeted == status.target then
				raw=rawCached
				-- Untargeted world geometry is independent of zoom. Only its
				-- shader cull threshold changes; keep the owned sizing tables.
				if not status.target and view.sourceZoom~=camera.scale then
					raw.screenSize=raw.nameWorldScale*36*math.abs(2*camera.scale/camera.viewportWidth)
					raw.visible=raw.screenSize>=Defaults.name.cullThreshold
				end
			else
				raw = Labels.size(anchor.size, 2 * camera.scale / camera.viewportWidth, false, false, status.target == true)
			end
			if raw==rawCached and not capDirty then size,projected=cached,view.projected
			else
				size=if filmPixels then Labels.filmHeight(raw,camera.scale,camera.viewportHeight,filmPixels)
					else Labels.limitHeight(raw,camera.scale,camera.viewportHeight,capFraction)
				projected=Labels.project(size,64)
				if filmPixels then
					projected.troopPixels=projected.namePixels*.7
					projected.lineOffset=projected.namePixels*.95
				end
			end
			size.visible=raw.visible
			local sx, sy = anchor.x*64, anchor.y*64
			-- Preserve the old padded frustum in world tiles, retaining views.
			local visible = size.visible
			if visible and not view then
				if self.renderer.options and self.renderer.options.firstPaint == "full" and not self.renderer.ready then
					if self.nameStatus.budget <= 0 then self.namesPending = true; return end
					self.newUnitBudget -= 1
					self.nameStatus.budget -= 1
				end
				local root = frame(self.layers.Names, `Name{p.smallID}`, 9)
				local name = label(root, "Player", 9)
				local troops = label(root, "Troops", 9)
				-- UIStroke replaces the fixed-width, translucent legacy text
				-- stroke. Source's MSDF edge is approximated by native glyphs.
				local strokes = {}
				for _, text in {name, troops} do
					text.TextStrokeTransparency = 1
					local stroke = Instance.new("UIStroke")
					stroke.Name, stroke.ApplyStrokeMode, stroke.Transparency = "NameOutline", Enum.ApplyStrokeMode.Contextual, 0
					stroke.Parent = text; table.insert(strokes, stroke)
				end
				local scale = Instance.new("UIScale"); scale.Parent = root
				view = {root = root, name = name, troops = troops, strokes = strokes, scale = scale, troopBucket = -1, sourceVisible = true}
				self.nameViews[p.smallID] = view
			end
			-- Hidden source-LOD results mutate the source cache too. Stamp its
			-- zoom independently of the last visible layout, including rapid
			-- out/in gestures that return to that layout's previous zoom.
			if view then view.sourceSizing,view.sourceZoom=raw,camera.scale end
			if view then setNameVisible(view,visible) end
			if visible then
				if self.nameTransitions[p.smallID] then self.namesAnimating=true end
				local geometry=view.pixels~=projected.namePixels or view.filmPixels~=filmPixels
				view.sizing, view.projected, view.anchorSize = size, projected, anchorSize
				view.zoom=camera.scale
				view.filmPixels=filmPixels
				view.sourceZoom=camera.scale
				view.sourceSizing,view.rawNameWorldScale,view.capLimit,view.capped=raw,raw.nameWorldScale,capLimit,size~=raw
				view.viewportWidth, view.targeted = camera.viewportWidth, status.target
				local pixels, guiScale = projected.namePixels, projected.guiScale
				local width = if filmPixels then pixels*10 else math.max(30*64, math.min(600*64, pixels * 10))
				local text = string.sub(p.displayName or p.name, 1, 32)
				view.width=width
				if view.sx ~= sx or view.sy ~= sy or geometry then
					putRect(view.root, sx - width / 2, sy - pixels / 2, width / guiScale,
						(pixels / 2 + projected.lineOffset + projected.troopPixels / 2) / guiScale)
					view.sx, view.sy = sx, sy
				end
				if geometry then
					view.scale.Scale = guiScale
					view.name.TextSize = math.clamp(pixels / guiScale, 1, 100)
					view.name.Size = UDim2.fromOffset(width / guiScale, pixels / guiScale)
					view.troops.TextSize = math.clamp(projected.troopPixels / guiScale, 1, 100)
					view.troops.Position = UDim2.fromOffset(0, (pixels / 2 + projected.lineOffset - projected.troopPixels / 2) / guiScale)
					view.troops.Size = UDim2.fromOffset(width / guiScale, projected.troopPixels / guiScale)
				end
				local textChanged=view.text~=text
				if textChanged then view.text, view.name.Text = text, text end
				view.sourceText=sourceText
				local styleChanged=view.palette~=palette or view.playerType~=p.type
				local goldName=Cosmetics.goldName(cosmetic)
				styleChanged=styleChanged or view.goldName~=goldName
				view.titleText=Cosmetics.title(cosmetic)
				if styleChanged then
					local owner = ownerColor(self.renderer.core, p.smallID, false)
					local colors = Labels.colors(if p.type == "NATION" then 2 elseif p.type == "BOT" then 1 else 0,
						{r = owner.R, g = owner.G, b = owner.B})
					local fill, outline = colors.fill, colors.outline
					view.name.TextColor3 = if goldName then Color3.new(Cosmetics.gold.r,Cosmetics.gold.g,Cosmetics.gold.b) else Color3.new(fill.r, fill.g, fill.b)
					view.troops.TextColor3 = Color3.new(fill.r, fill.g, fill.b)
					local color=Color3.new(outline.r,outline.g,outline.b)
					for _,stroke in view.strokes do stroke.Color=color end
					if goldName then view.strokes[1].Color=Color3.new(Cosmetics.outline.r,Cosmetics.outline.g,Cosmetics.outline.b) end
					view.goldName=goldName
					view.palette,view.playerType,view.outlineWidth=palette,p.type,colors.outlineWidth
				end
				if styleChanged or geometry or (maintenance and view.strokeZoom~=camera.scale) then
					local scale=guiScale*camera.scale/64
					local thickness=NameLine.outline(pixels*camera.scale/64)/scale
					for index,stroke in view.strokes do
						local lineThickness=if index==1 then thickness else math.max(1.4/scale,thickness*.6)
						if stroke.Thickness~=lineThickness then stroke.Thickness=lineThickness end
					end
					view.strokeZoom=camera.scale
				end
				view.pixels = pixels
				if geometry or textChanged or view.flagValue~=p.flag or (p.flag and not view.flag)
					or view.headUserId~=NameLine.userId(p) or view.headPending then
					drawNameLine(self, view, p, pixels, width, guiScale)
				end
				drawTroops(view,p,index,now)
				if geometry or statusChanged or view.statusPending or view.statusContent~=self.nameStatus.content or view.statusConfig~=self.renderConfig then
					self.nameStatus:draw(view, status, size.nameWorldScale, 64,
						pixels, width, guiScale, self.renderConfig, now)
					view.statusRecord,view.statusContent,view.statusPending=status,self.nameStatus.content,self.nameStatus.pending
					view.statusConfig=self.renderConfig
					self.nameStatusDraws=(self.nameStatusDraws or 0)+1
				end
			end
		elseif view then setNameVisible(view,false) end
	end
	-- Camera movement needs visibility checks, not name layout. Interior names
	-- move with the pass canvas; only entering names need current presentation.
	local revealed={}
	if self.nameCameraDirty then
		local wholeMap=x0<=0 and y0<=0 and x1>=self.renderer.core.width and y1>=self.renderer.core.height
		if not wholeMap or not self.namesWholeMap or self.nameCapDirty or self.nameLodDirty then
			for _,p in self.roster do
				local transition=self.nameTransitions[p.smallID]
				local anchor=if transition then transition.current or self.names[p.smallID] else self.names[p.smallID]
				local view=self.nameViews[p.smallID]
				local inside=anchor and anchor.x>x0 and anchor.x<x1 and anchor.y>y0 and anchor.y<y1
				local lodChanged=false
				if inside and view and self.nameLodDirty then
					local targeted=statuses[p.smallID] and statuses[p.smallID].target==true
					local raw=view.sourceSizing
					local visible=targeted or (raw and raw.nameWorldScale*72*camera.scale/camera.viewportWidth>=Defaults.name.cullThreshold)
					lodChanged=targeted or view.sourceVisible~=visible
				end
				if not inside then if view then setNameVisible(view,false) end
				elseif not view or not view.sourceVisible or lodChanged or (self.nameCapDirty and (view.capLimit~=capLimit or view.capped or (view.rawNameWorldScale or 0)*camera.scale*48>capLimit)) then revealed[p.smallID]=true end
			end
		end
		self.namesWholeMap=wholeMap
	end
	if all then
		for index,p in self.roster do
			self.namePlayers[p.smallID],self.nameSlots[p.smallID]=p,index
			local id=p.smallID
			local view,anchor=self.nameViews[id],self.names[id]
			local status=statuses[id] or emptyStatus
			local statusChanged=not sameStatus(view and view.statusRecord,status)
			if view and not statusChanged then view.statusRecord=status end
			if not view or self.nameTransitions[id] or revealed[id] or self.cameraDirty
				or (maintenance and view.zoom~=camera.scale and anchor and anchor.x>x0 and anchor.x<x1 and anchor.y>y0 and anchor.y<y1)
				or (view.sourceVisible and (p.alive==false or not anchor or view.statusPending or statusChanged
					or view.sourceText~=(p.displayName or p.name) or view.flagValue~=p.flag or (p.flag and not view.flag)
					or view.titleText~=Cosmetics.title(self.cosmeticOverrides[p.smallID] or p) or view.goldName~=Cosmetics.goldName(self.cosmeticOverrides[p.smallID] or p)
					or view.headUserId~=NameLine.userId(p) or view.headPending
					or view.palette~=self.renderer.core.palette[id] or view.playerType~=p.type
					or view.statusContent~=self.nameStatus.content or view.statusConfig~=self.renderConfig
					or (maintenance and (view.zoom~=camera.scale or view.strokeZoom~=camera.scale)))) then
				drawName(index,p)
			elseif view.sourceVisible then drawTroops(view,p,index,now) end
		end
	else
		for id in revealed do
			local p=self.namePlayers[id]; if p then drawName(self.nameSlots[id],p) end
		end
		for id in self.nameTransitions do
			local p,view=self.namePlayers[id],self.nameViews[id]
			if not revealed[id] and p and view and view.sourceVisible then
				local anchor=nameAnchor(self,id,now)
				if anchor.x<=x0 or anchor.x>=x1 or anchor.y<=y0 or anchor.y>=y1 then setNameVisible(view,false)
				elseif view.anchorSize==math.max(1,math.floor(anchor.size)) then
					self.nameVisits=(self.nameVisits or 0)+1
					namePose(view,anchor.x*64,anchor.y*64)
					if self.nameTransitions[id] then self.namesAnimating=true end
				else drawName(self.nameSlots[id],p) end
			end
		end
	end
	self.nameCameraDirty=false
	self.nameCapDirty=false
	self.nameLodDirty=false
	self.newUnitBudget = self.nameStatus.budget
	self.namesPlaced = true
end

-- Called only by the Studio-only film camera; nil restores normal gameplay.
function Overlay.setFilmLabelPixels(self:any,pixels:number?)
	if self.filmLabelPixels==pixels then return end
	self.filmLabelPixels=pixels
	self.cameraDirty,self.nameCameraDirty,self.nameCapDirty=true,true,true
	self.labelLayoutDirty=true
end

local function seedSpawnNames(self: any)
	if self.nameAnchorMode == "server" then return end
	local core = self.renderer.core
	for _, p in self.roster do
		if p.spawnTile ~= nil and self.names[p.smallID] == nil then
			self.names[p.smallID] = NameBox.placeSpawnName({width = core.width, height = core.height} :: any,
				{id = p.smallID, name = p.displayName or p.name, spawnTile = p.spawnTile, borderTiles = {}})
		end
	end
end
local function syncSpawn(self: any, force: boolean?)
	local parts = {tostring(self.spawnPhase),tostring(self.localPlayer),tostring(self.ownSpawnRing)}
	for _, p in self.roster do
		table.insert(parts,`{p.smallID}:{p.type}:{p.team}:{p.spawnTile}`)
	end
	local signature = table.concat(parts,'|')
	if not force and signature == self.spawnSignature then return end
	self.spawnSignature = signature
	local discs = self.effects:setSpawn(self.roster,self.localPlayer,self.spawnPhase,self.ownSpawnRing)
	Core.setSpawnDiscs(self.renderer.core,discs)
end
function Overlay.setRoster(self: any, players: {any})
	self.shipCombatSequences={}
	self.unitsDirty, self.statusDirty = true, true
	self.unitCameraDirty=true
	self.roster = players; self.namesDirty, self.railsDirty = true, true; seedSpawnNames(self); syncSpawn(self,true)
	table.clear(self.blastStyles);table.clear(self.titles.players)
	for _,p in players do
		local cosmetic=self.cosmeticOverrides[p.smallID] or p
		if cosmetic.type=='HUMAN' and Cosmetics.blast(cosmetic.blastFx) then self.blastStyles[p.smallID]=cosmetic.blastFx end
		if Cosmetics.title(cosmetic) then table.insert(self.titles.players,p.smallID) end
	end
	self.cameraDirty,self.labelLayoutDirty=true,true
end
function Overlay.setStats(self: any, players: {any})
	self.statusDirty = true
	self.roster = players; if self.spawnPhase then self.namesDirty = true end; seedSpawnNames(self)
	if self.spawnPhase or self.ownSpawnRing then syncSpawn(self) end
end
function Overlay.setSpawnPhase(self: any, active: boolean)
	if self.spawnPhase ~= active then self.spawnPhase, self.namesDirty, self.nameScan = active, true, nil; syncSpawn(self) end
end
-- Original: GameView.setOwnSpawnRing, driven by TutorialPanel's territory step.
function Overlay.setOwnSpawnRing(self: any, active: boolean)
	if self.ownSpawnRing ~= active then self.ownSpawnRing = active; syncSpawn(self) end
end
function Overlay.setLocalPlayer(self: any, id: number)
	if self.localPlayer~=id then self.feel:reset(self.units) end
	self.sabotageReach:setAim(id,self.sabotageReach.reach)
	self.samsDirty=true
	self.localPlayer = id; self.railsDirty, self.unitsDirty, self.statusDirty, self.unitCameraDirty = true, true, true, true; syncSpawn(self)
	patrolUnit(self)
	self.selection:prune(self.units,id)
	self.defense:setTargets(self.attacks,id)
end
function Overlay.setUnits(self: any, units: {[number]: any})
	if not self.feelSeeded then self.feel:reset(units); self.feelSeeded=true end
	if not self.artillerySeeded then self.artillery:reset(units);self.artillerySeeded=true end
	self.artillery:setUnits(units)
	self.feel:prune(units)
	self.unitsDirty, self.statusDirty = true, true
	self.units = units
	self.nukeIds={};self.airfields={};self.supportIds={};self.strikePreviewDirty=self.buildPreview~=nil and StrikeExecution.SPEC[self.buildPreview.ghostType]~=nil
	for id,u in units do
		if u.active~=false and u.dark then table.insert(self.supportIds,id) end
		if u.type=='Airfield' and u.active~=false then table.insert(self.airfields,id) end
		if Visual.hasBlastRing(u.type) then table.insert(self.nukeIds,id) end
		if u.type=='SAM Launcher' then
			local old,s=self.samRecords[id],u.samUpgrade or {}
			if not old or old.tile~=u.tile or old.owner~=u.owner or old.level~=u.level or old.active~=u.active
				or old.startTick~=s.startTick or old.startRange~=s.startRange or old.targetLevel~=s.targetLevel or old.duration~=s.duration then
				self.samsDirty=true
				self.samRecords[id]={tile=u.tile,owner=u.owner,level=u.level,active=u.active,
					startTick=s.startTick,startRange=s.startRange,targetLevel=s.targetLevel,duration=s.duration}
			end
		end
	end
	for id in self.samRecords do if not units[id] or units[id].type~='SAM Launcher' then self.samRecords[id]=nil; self.samsDirty=true end end
	table.sort(self.airfields)
	table.sort(self.supportIds)
	if not self.unitsSeeded then
		for id,u in units do if u.active==false then self.effects.state.dead[id]=true end end
		self.unitsSeeded=true
	end
	-- Unit IDs are allocated monotonically by the source engine. Preserve arrival
	-- order thereafter instead of using unordered Luau table iteration for trails.
	local added = {}
	for id in units do if not self.knownUnits[id] then table.insert(added,id) end end
	table.sort(added)
	for _, id in added do self.knownUnits[id]=true; table.insert(self.unitOrder,id) end
	local order = {}
	for _, id in self.unitOrder do
		if units[id] then table.insert(order,id) else self.knownUnits[id]=nil end
	end
	self.unitOrder = order
	if #order==0 then self.lodCursor,self.lodRemaining=0,0
	else
		self.lodCursor=self.lodCursor%#order
		self.lodRemaining=math.min(self.lodRemaining,#order)
	end
	for id,key in self.unitCellFor do if units[id]==nil then
		self.unitCells[key].units[id]=nil; self.unitCellFor[id]=nil; self.staleUnits[id]=nil
		if self.adornmentUnits[id] then self.adornmentOrderDirty=true end
		self.pendingIcons[id]=nil; self.adornmentUnits[id]=nil
	end end
	for id, view in self.unitViews do if units[id] == nil then
		(if view.structure then self.structureCache else self.mobileCache):release(view.iconSlot); view.root:Destroy(); if view.trail then view.trail:Destroy() end; self.unitViews[id] = nil
		if self.adornmentUnits[id] then self.adornmentOrderDirty=true end
		self.pendingIcons[id],self.adornmentUnits[id],self.staleUnits[id],self.smoothUnits[id]=nil,nil,nil,nil
	end end
	patrolUnit(self)
	self.selection:prune(units,self.localPlayer)
	if self.renderConfig then self.defense:setUnits(units,self.renderConfig:defensePostRange()) end
end
function Overlay.unitUpdates(self: any, updates: {any}, removed: {number})
	self.feel:updates(updates,removed,os.clock())
	self.artillery:updates(updates,removed,os.clock())
	local headings={}
	for _, u in updates do
		if not self.knownUnits[u.id] then self.knownUnits[u.id]=true; table.insert(self.unitOrder,u.id) end
		if u.type=='Warship' and u.active==false then
			local view=self.unitViews[u.id]
			if view then headings[u.id]=view.heading end
			if Policy.smoothShips then self.shipArt.needed=true end
		end
	end
	self.effects.state:unitUpdates(updates,removed,os.clock()*1000,headings,self.blastStyles)
end
function Overlay.bonuses(self: any, events: {any}) self.effects.state:bonuses(events,os.clock()*1000) end
function Overlay.conquests(self: any, events: {any}) self.effects.state:conquests(events,os.clock()*1000) end
function Overlay.publicConquests(self:any,events:{any}) self.effects.state:publicConquests(events,os.clock()*1000) end
function Overlay.setCosmeticPreview(self:any,id:number?,data:any?)
	if id then self.cosmeticOverrides[id]=if data then {type='HUMAN',title=data.title,nameStyle=data.nameStyle,conquestFx=data.conquestFx,blastFx=data.blastFx} else nil
	else table.clear(self.cosmeticOverrides) end
	Overlay.setRoster(self,self.roster)
end
function Overlay.setDiplomacy(self: any, diplomacy: any)
	self.diplomacy = diplomacy; self.cameraDirty, self.statusDirty = true, true
end
function Overlay.diplomacyEvents(self: any, events: {any}, tick: number)
	self.playerStatus:events(events, tick); self.cameraDirty, self.statusDirty = true, true
end
function Overlay.clearStatusEvents(self: any)
	self.playerStatus:clear(); self.cameraDirty, self.statusDirty = true, true
end
function Overlay.prepareFrame(self: any): boolean
	self.structurePrepareFrame=(self.structurePrepareFrame or 0)+1
	if self.atlasPending then
		local pixels=Atlas.rgba(); StructureCache.setSource(pixels)
		self.atlas:WritePixelsBuffer(Vector2.zero, Vector2.new(Atlas.width, Atlas.height), pixels)
		self.atlasPending = false
		return true
	end
	if self.effects:prepare() then return true end
	local uploaded = self.nameStatus:prepare()
	if uploaded then self.cameraDirty = true end
	if uploaded then return true end
	local loading=self.renderer.options.firstPaint=='full' and not self.renderer.ready
	local ships=self.shipArt
	-- Loading has a finite-progress floor within the same pixel cap. Real-time
	-- deadlines alone can starve first-use art on a slow or contended host.
	if ShipArt.build(ships,if loading then 8 else Policy.shipArtMs,if loading then 32768 else Policy.shipArtPixelsPerFrame,
		if loading then 4096 else nil) then
		local ok,result=pcall(function(): Content?
			local img=game:GetService('AssetService'):CreateEditableImage({Size=Vector2.new(ShipArt.width,ShipArt.height)})
			if not img then return nil end
			ships.image=img
			img:WritePixelsBuffer(Vector2.zero,Vector2.new(ShipArt.width,ShipArt.height),ships.pixels)
			return Content.fromObject(img)
		end)
		ships.pixels=nil
		if ok and result then
			ships.content=result; self.unitCameraDirty,self.previewCameraDirty=true,true
			return true
		end
		if ships.image then ships.image:Destroy(); ships.image=nil end
		ships.failed=true -- retain source icons on devices refusing the optional image
	end
	-- A new style burst must not monopolize the image slot while ownership is
	-- dirty. Existing layered icons remain correct until their cache is ready;
	-- drain ownership before spending a displayed-image slot on an optional cache.
	if not loading and self.renderer.core.pending>0 then return false end
	if self.structureCache:prepare(if loading then 8 else Policy.structureComposeMs) then self.iconsUploaded=true; return true end
	if self.mobileCache:prepare(if loading then 8 else Policy.structureComposeMs) then self.iconsUploaded=true; return true end
	return false
end
function Overlay.isFirstPaintReady(self: any): boolean
	return self.nameAnchorMode == "server" and self.namesPlaced and not self.namesPending and not self.unitsPending
		and not self.railsPending
		and self.lodRemaining==0
		and not self.atlasPending and not self.nameStatus.pending
		and (not self.shipArt.needed or self.shipArt.content~=nil or self.shipArt.failed)
		and (not self.nameStatus.needed or self.nameStatus.content ~= nil)
		and (self.effects.atlas ~= nil or (#self.effects.centers == 0 and #self.effects.state.sprites == 0))
end
function Overlay.setMoved(self: any, ids: {number}, tick: number)
	self.moved = {}
	self.movedTick = tick
	for _, id in ids do
		self.moved[id] = true
		if self.units[id] and Visual.isSmoothed(self.units[id].type) then self.smoothUnits[id]=true end
	end
end
function Overlay.setRailroads(self: any, railroads: {[number]: {number}})
	self.railroads = railroads; rebuildRailTypes(self)
end
function Overlay.setNameAnchors(self: any, anchors: {[number]: any}?)
	if not anchors then return end
	local started = self.profiler:begin()
	-- Original: NamePass.updateNames rebases the old exponential at each target
	-- change. The first authoritative placement snaps like a newly allocated slot.
	local now,snap=os.clock(),self.nameAnchorMode~='server' or (self.renderer.options ~= nil and self.renderer.options.firstPaint == "full" and not self.renderer.ready)
	local names,transitions={},{}
	for id,anchor in anchors do
		local old=self.names[id]
		local prior=self.nameTransitions[id]
		if old and old.x==anchor.x and old.y==anchor.y and old.size==anchor.size then
			-- A sparse confirmed name update supplies the whole anchor table.
			-- Keep our owned targets instead of allocating one per unchanged player.
			names[id]=old
			if not snap then transitions[id]=prior end
		else
			local target={x=anchor.x,y=anchor.y,size=anchor.size}
			names[id]=target
			if not snap and old then
				local x,y,size=old.x,old.y,old.size
				if prior then
					local elapsed=now-prior.time
					x,y,size=Labels.lerp(prior.x,prior.target.x,elapsed),Labels.lerp(prior.y,prior.target.y,elapsed),
						Labels.lerp(prior.size,prior.target.size,elapsed)
				end
				transitions[id]={x=x,y=y,size=size,target=target,time=now}
			end
		end
	end
	self.names,self.nameTransitions=names,transitions
	self.nameAnchorMode,self.namesDirty,self.nameScan='server',false,nil
	self.namesPlaced = false
	self.cameraDirty=true
	self.profiler:finish("anchors", started)
end
function Overlay.setAffiliations(self: any, friendly: {[number]: boolean}, clusters: {[number]: number})
	self.friendly,self.allianceClusters=friendly,clusters
	self.samsDirty,self.statusDirty=true,true
end
function Overlay.setRenderConfig(self:any,config:any)
	self.renderConfig=config; self.unitsDirty,self.statusDirty,self.unitCameraDirty=true,true,true
	self.defense:setUnits(self.units,config:defensePostRange())
end
function Overlay.setAttacks(self:any,attacks:{any})
	self.attacks=attacks; self.defense:setTargets(attacks,self.localPlayer)
end
function Overlay.setNukePreview(self: any, data: any?) self.preview = data end
local function sameGhost(a:any,b:any):boolean
	if not a or not b then return a==b end
	for _,key in {'ghostType','tileX','tileY','radiusTileX','radiusTileY','rangeRadius','innerRangeRadius','ownerID',
		'spreadInnerRadius','spreadOuterRadius',
		'strikeLauncherTile','strikeReach','paraOriginTile','sabotageTargetTile',
		'canBuild','canUpgrade','validated','upgradeTargetTile','cost','showCost','multiplier','canAfford','rangeWarning'} do
		if a[key]~=b[key] then return false end
	end
	local ap,bp=a.ghostRailPaths,b.ghostRailPaths
	if ap~=bp then
		if #(ap or {})~=#(bp or {}) then return false end
		for i,path in ap or {} do
			if #path~=#bp[i] then return false end
			for j,tile in path do if tile~=bp[i][j] then return false end end
		end
	end
	return true
end
function Overlay.setBuildPreview(self:any,data:any?)
	if sameGhost(self.buildPreview,data) then return end
	self.buildPreview=if data then table.clone(data) else nil
	if data then self.inspectedRange=nil end
end
function Overlay.setHighlightStructureTypes(self:any,types:{string}?)
	self.unitsDirty,self.unitCameraDirty=true,true
	self.highlightVersion=(self.highlightVersion or 0)+1
	self.highlightTypes={}; if types then for _, kind in types do self.highlightTypes[kind]=true end end
end
function Overlay.setCamera(self: any)
	self.sabotageReach:setCamera()
	self.labelLayoutDirty,self.costLayoutDirty=true,true
	local c,core=self.renderer.camera,self.renderer.core
	local fade,detail=railFade(c.scale),c.scale>=Defaults.railroad.railDetailZoom
	local shown=fade>0
	if self.railShown~=shown or self.railDetail~=detail or self.railSourceFade~=Policy.sourceRailFade then self.railsDirty=true end
	self.railShown,self.railDetail,self.railSourceFade=shown,detail,Policy.sourceRailFade
	if self.layers.Rails.Visible~=shown then self.layers.Rails.Visible=shown end
	if self.adornmentZoom~=c.scale then
		self.adornmentRemaining=#self.adornmentOrder;self.adornmentZoom=c.scale
	end
	if self.nameLodZoom~=c.scale or self.nameLodWidth~=c.viewportWidth then
		self.nameLodDirty=true; self.nameLodZoom,self.nameLodWidth=c.scale,c.viewportWidth
	end
	self.screenCameraDirty=true
	self.previewCameraDirty=true
	if self.trajectoryZoom~=c.scale then self.trajectoryCameraDirty=true; self.trajectoryZoom=c.scale end
	self.rangeCameraDirty=true
	self.patrolCameraDirty=true
	self.defenseCameraDirty=true
	self.nameCameraDirty=true
	if self.nameCapZoom~=c.scale or self.nameCapHeight~=c.viewportHeight or self.nameCapEnabled~=Policy.capNameScreenHeight or self.nameCapFraction~=Policy.nameMaxViewportHeight then
		self.nameCapDirty=true
		self.nameCapZoom,self.nameCapHeight,self.nameCapEnabled,self.nameCapFraction=c.scale,c.viewportHeight,Policy.capNameScreenHeight,Policy.nameMaxViewportHeight
	end
	local x0,y0=Camera.screenToWorldCoordinatesFloat(c,c.left,c.top)
	local x1,y1=Camera.screenToWorldCoordinatesFloat(c,c.left+c.viewportWidth,c.top+c.viewportHeight)
	local margin=128/c.scale
	for _,cell in self.unitCells do
		local visible=cell.x+128>=x0-margin and cell.y+128>=y0-margin and cell.x<=x1+margin and cell.y<=y1+margin
		if cell.visible~=visible then
			cell.visible=visible
			if visible then cell.revealed=true; self.revealedCells=true end
			for _,f in cell.frames do f.Visible=visible end
		end
	end
	local x,y=localPos(c,0,0)
	local position=UDim2.fromScale(x/math.max(1,c.viewportWidth),y/math.max(1,c.viewportHeight))
	for _,pass in self.worldTransforms do
		if pass.frame.Position~=position then pass.frame.Position=position end
		if pass.scale.Scale~=c.scale/64 then pass.scale.Scale=c.scale/64 end
	end
	self.iconScale=Structure.presentationSize('City',c.scale)/64
	local layer=self.layers.Structures
	if layer.Position~=position then layer.Position=position end
	local extent=UDim2.fromScale(core.width*c.scale/self.iconScale/math.max(1,c.viewportWidth),core.height*c.scale/self.iconScale/math.max(1,c.viewportHeight))
	if layer.Size~=extent then layer.Size=extent end
	if self.structureScale.Scale~=self.iconScale then self.structureScale.Scale=self.iconScale end
	if self.layers.Progress then
		local progress=self.layers.Progress
		if progress.Position~=position then progress.Position=position end
		if progress.Size~=extent then progress.Size=extent end
		if self.progressScale.Scale~=self.iconScale then self.progressScale.Scale=self.iconScale end
	end
	-- The one screen-sized cost label follows on the actual camera callback,
	-- before card observers run. Symbol, ranges and aim inherit world transforms.
	Overlay.layoutLabels(self)
	placeBuildCost(self)
	local lod=c.scale<=Defaults.structure.dotsZoomThreshold
	if self.unitLod~=lod then
		self.lodRemaining=#self.unitOrder;self.lodCursor=0;self.unitLod=lod
	end
	-- Positions inherit the immediate transform. Visibility/detail crossings
	-- refresh now; frustum, topology colors and continuous fade stay at 10Hz.
end
function Overlay.tilesChanged(self: any,ownTiles:{number}?)
	self.sabotageReach:tilesChanged(ownTiles)
	self.namesDirty, self.railsDirty, self.statusDirty = true, true, true
	self.defense:tilesChanged(ownTiles)
end
function Overlay.setTick(self: any, tick: number)
	self.unitsDirty, self.statusDirty = true, true
	self.tick, self.tickTime = tick, os.clock()
	if self.movedTick ~= tick then self.moved = {} end
	if tick % 30 == 0 and self.nameAnchorMode ~= "server" then self.namesDirty = true end
	local trailStarted = self.profiler:begin()
	local changed = self.trails:update(self.units,self.unitOrder,self.moved)
	Core.applyTrails(self.renderer.core,self.trails.values,changed)
	self.profiler:finish("trails", trailStarted)
end

-- Original: GPURenderer.draw frame order. Native property updates are
-- restricted to visible units, rail redraws to topology/camera changes.
-- Only currently dark records enter this index. Bound GUI property
-- visits as well as allocations, even on a crowded public map.
local function stepSupport(self:any,now:number)
	local ids=self.supportIds or {}
	for _=1,math.min(32,#ids) do
		self.supportCursor=(self.supportCursor or 0)%#ids+1
		local id=ids[self.supportCursor]
		local u,view=self.units[id],self.unitViews[id]
		if not u or not view or not view.root.Visible or u.active==false then continue end
		local pulse=.12+.12*(.5+.5*math.sin(now*math.pi*.8))
		if u.dark then for i,part in view.parts do
			local base=if view.supportBase then view.supportBase[i] or 0 else 0
			part.ImageTransparency=base+(1-base)*pulse
		end end
	end
end
function Overlay.step(self: any)
	if self.destroyed then return end
	local sceneStarted = self.profiler:begin()
	self.frameTick+=1
	local fraction = math.clamp((os.clock() - self.tickTime) / .1, 0, 1)
	self.newUnitBudget = 25
	self.newRailBudget = Policy.railCreatesPerFrame
	local stateDirty=self.unitsDirty
	if not self.iconScale then self:setCamera() end
	local maintenance=os.clock()-(self.lastMaintenance or -1)>=.1
	if maintenance then self.lastMaintenance=os.clock(); self.railsDirty=true end
	local dirty = self.unitsDirty or self.unitCameraDirty or self.unitsPending
	self.unitsPending, self.unitsDirty = false, false
	local unitStarted = self.profiler:begin()
	local function hidden(id: number,unit: any,view: any): boolean
		if unit.active==false or (unit.waitTicks or 0)>0 then
			hideUnit(self,view); self.smoothUnits[id]=nil; self.staleUnits[id]=nil; return true
		end
		if Visual.isMissile(unit.type) then return false end
		local core=self.renderer.core
		local key=math.floor(math.floor(unit.tile/core.width)/128)*math.ceil(core.width/128)+math.floor((unit.tile%core.width)/128)+1
		local cell=self.unitCells[key]
		if not cell then return false end
		local old=self.unitCellFor[id]
		if old~=key then
			if old then self.unitCells[old].units[id]=nil end
			cell.units[id]=true; self.unitCellFor[id]=key
		end
		if cell.visible==false then
			self.staleUnits[id]=true
			if view then
				local parent=unitParent(self,if view.structure then 'Structures' else 'Ground',unit.tile)
				if view.bucket~=parent then view.root.Parent=parent; view.bucket=parent end
			end
			return true
		end
		return false
	end
	local function draw(id: number,unit: any)
		if Artillery.handles(unit.type) then self.smoothUnits[id]=nil;return end -- capped GUI-only pool owns this projectile
		self.unitScans=(self.unitScans or 0)+1
		local view=self.unitViews[id]
		if hidden(id,unit,view) then return end
		local animate=self.moved[id] and Visual.isSmoothed(unit.type) and (fraction<1 or (view and view.interpolating))
		local ready=view and (view.adornmentPending or (view.iconSlot and view.iconSlot.ready and not view.composed))
		local recordChanged,poseOnly=false,false
		if not view or self.staleUnits[id] then recordChanged=true
		elseif stateDirty or self.moved[id] then recordChanged,poseOnly=changedUnit(view,unit) end
		local blink=if unit.type=='Warship' and (unit.retreating or (unit.warship and unit.warship.state=='retreating')) then math.floor(self.tick*.07)%2 else nil
		if self.unitCameraDirty or recordChanged or ready or animate or (view and ((view.progress or view.flicker) and view.drawTick~=self.tick or view.blink~=blink)) then
			drawUnit(self,id,unit,if self.moved[id] then fraction else 1,poseOnly and not self.unitCameraDirty and view.blink==blink)
			self.staleUnits[id]=nil
			view=self.unitViews[id]
			if view then view.interpolating=self.moved[id] and Visual.isSmoothed(unit.type) and fraction<1 end
		end
		if not view or not view.interpolating then self.smoothUnits[id]=nil end
	end
	if dirty then for id, unit in self.units do
		-- Structures and boats change on confirmed ticks/camera input. Only
		-- source-smoothed missiles need sub-tick property updates, including
		-- one last draw at fraction=1 before their interpolation stops.
		draw(id,unit)
	end else for id in self.smoothUnits do
		local unit=self.units[id]; if unit then draw(id,unit) else self.smoothUnits[id]=nil end
	end end
	if self.revealedCells then
		self.revealedCells=false
		for _,cell in self.unitCells do if cell.revealed then
			cell.revealed=false
			for id in cell.units do if self.staleUnits[id] and self.units[id] then draw(id,self.units[id]) end end
		end end
	end
	if self.iconsUploaded then
		self.iconsUploaded=false
		for id in self.pendingIcons do
			local view,unit=self.unitViews[id],self.units[id]
			if not view or not unit then self.pendingIcons[id]=nil
			elseif view.iconSlot and view.iconSlot.ready and not hidden(id,unit,view) then drawUnit(self,id,unit,if self.moved[id] then fraction else 1) end
		end
	end
	-- Crossing the glyph/dot threshold changes styles, not world positions.
	-- Amortize that presentation work instead of restyling every city at once.
	for _=1,math.min(Policy.structureLodVisitsPerFrame,self.lodRemaining) do
		self.lodCursor=self.lodCursor%#self.unitOrder+1;self.lodRemaining-=1
		local id=self.unitOrder[self.lodCursor]
		local view,unit=self.unitViews[id],self.units[id]
		if view and unit and view.structure and view.lod~=self.unitLod and not hidden(id,unit,view) then
			drawUnit(self,id,unit,1);self.structureLodRefreshes=(self.structureLodRefreshes or 0)+1
		end
	end
	if self.adornmentOrderDirty then
		self.adornmentOrderDirty=false
		local order={};for id in self.adornmentUnits do table.insert(order,id) end;table.sort(order)
		self.adornmentOrder=order;self.adornmentCursor=0;self.adornmentRemaining=#order
	end
	for _=1,math.min(Policy.adornmentUpdatesPerFrame,self.adornmentRemaining) do
		self.adornmentCursor=self.adornmentCursor%#self.adornmentOrder+1
		self.adornmentRemaining-=1
		local id=self.adornmentOrder[self.adornmentCursor]
		self.adornmentVisits=(self.adornmentVisits or 0)+1
		local view,unit=self.unitViews[id],self.units[id]
		if view and unit and view.zoom~=self.renderer.camera.scale and not hidden(id,unit,view) then
			if not zoomAdornment(self,id,view,unit) then drawUnit(self,id,unit,if self.moved[id] then fraction else 1) end
			self.adornmentRefreshes=(self.adornmentRefreshes or 0)+1
		end
	end
	self.profiler:finish("units", unitStarted)
	if self.railsDirty then drawRails(self) end
	commitRails(self)
	trimRails(self)
	drawRings(self,dirty or self.statusDirty)
	local previewStamp=self.profiler:begin()
	drawTrajectories(self)
	self.profiler:finish('previewTrajectory',previewStamp)
	-- The chosen placement's two radii get the creation allowance before the
	-- surrounding SAM network, so a large network cannot starve the target.
	drawSelection(self)
	previewStamp=self.profiler:begin(); drawBuildPreview(self); self.profiler:finish('previewGhost',previewStamp)
	previewStamp=self.profiler:begin(); drawWarshipPatrol(self); drawDefense(self); drawSams(self,fraction); self.profiler:finish('previewRanges',previewStamp)
	-- First-use FX normally allocate from prepareFrame. While the base atlas
	-- reserves the loading frame, defer FX views so their lazy content helper
	-- cannot upload a second image in that same frame.
	local loading = self.renderer.options ~= nil and self.renderer.options.firstPaint == "full" and not self.renderer.ready
	if not loading or self.effects.atlas or (#self.effects.centers == 0 and #self.effects.state.sprites == 0) then
		local fxStarted = self.profiler:begin()
		self.effects:step(os.clock()*1000)
		self.profiler:finish("fx", fxStarted)
	end
	if self.namesDirty and self.nameAnchorMode ~= "server" then fallbackNames(self) end
	if self.statusDirty or self.cameraDirty or self.nameCameraDirty or self.namesAnimating or self.namesPending or self.nameStatus.pending or os.clock() - (self.lastNameDraw or 0) >= .1 then
		local namesStarted = self.profiler:begin()
		drawNames(self); self.lastNameDraw = os.clock()
		self.labelLayoutDirty,self.costLayoutDirty=true,true
		self.profiler:finish("names", namesStarted)
	end
	Overlay.layoutLabels(self)
	placeBuildCost(self)
	local iconStarted = self.profiler:begin()
	self.nameStatus:step(os.clock())
	self.feel:step(os.clock())
	stepSupport(self,os.clock())
	self.artillery:step(os.clock(),fraction)
	self.profiler:finish("icons", iconStarted)
	self.cameraDirty,self.unitCameraDirty,self.screenCameraDirty = false,false,false
	self.profiler:finish("scene", sceneStarted)
end
function Overlay.metrics(self: any): {[string]: number}
	local n = 0; for _ in self.unitViews do n += 1 end
	local names, flags, unitLabels = 0, 0, 0
	for _, v in self.nameViews do names += 1; if v.flag then flags += 1 end end
	for _, v in self.unitViews do
		for _, key in {"level", "station", "deletion", "pips"} do if v[key] then unitLabels += 1 end end
	end
	local buckets,visibleBuckets=0,0
	for _,cell in self.unitCells do for _ in cell.frames do buckets+=1; if cell.visible then visibleBuckets+=1 end end end
	local trailTiles=0; for _ in self.trails.values do trailTiles+=1 end
	local rangeViews,visibleRanges=0,0
	for _,f in self.rangeViews do rangeViews+=1; if f.Visible then visibleRanges+=1 end end
	local maskCount=0; for _ in self.effects.masks.slots do maskCount+=1 end
	return {unitViews = n, railSegments = #self.railLines, visibleRailSegments = self.visibleRails or 0,
		cosmeticTitleSlots=#self.titles.slots,cosmeticTitlesVisible=self.titles.visible or 0,cosmeticTitleChecks=self.titles.checks or 0,
		defenseProbeTiles=self.defense.visits,defensePending=math.max(0,#self.defense.queue-self.defense.head+1),
		falloutMasks=maskCount,falloutMaskBufferBytes=maskCount*Policy.falloutMaskSize^2*7,
		falloutMaskUploads=self.effects.maskUploads,falloutMaskVisits=self.effects.masks.visits,
		falloutMaskAllocationFailed=if self.effects.maskFailed then 1 else 0,
		falloutMaskNativeBytes=if self.effects.maskAtlas then Policy.falloutMaskSize^2*self.effects.masks.cap*4 else 0,
		rangeViews=rangeViews,visibleRanges=visibleRanges,rangeSpareViews=#self.rangePool,
		artilleryShellViews=#self.artillery.shells,artilleryAccentViews=#self.artillery.marks,artilleryPendingAccents=#self.artillery.state.marks,
		unitDraws=self.unitDraws or 0,unitScans=self.unitScans or 0,unitPoseDraws=self.unitPoseDraws or 0,
		railRebuilds=self.railRebuilds or 0,railVisits=self.railVisits or 0,railCreates=self.railCreates or 0,railDeletes=self.railDeletes or 0,
		adornmentVisits=self.adornmentVisits or 0,adornmentRefreshes=self.adornmentRefreshes or 0,
		structureLodRefreshes=self.structureLodRefreshes or 0,
		railGuiObjects=#self.railLines,
		worldOverlayUnit=64,unitBucketGuiObjects=buckets,visibleUnitBuckets=visibleBuckets,
		structureAtlasPixelBytes=#self.structureCache.pages*StructureCache.size^2*4,
		structureAtlasSlots=#self.structureCache.slots,structureAtlasPending=#self.structureCache.queue-self.structureCache.head+1,
		structureAtlasQueueStorage=#self.structureCache.queue,mobileAtlasQueueStorage=#self.mobileCache.queue,
		structureAtlasFailed=if self.structureCache.failed then 1 else 0,
		mobileAtlasPixelBytes=#self.mobileCache.pages*480*480*4,
		mobileAtlasSlots=#self.mobileCache.slots,
		shipAtlasPixelBytes=if self.shipArt.image then ShipArt.width*ShipArt.height*4 else 0,
		shipArtBufferBytes=if self.shipArt.pixels then buffer.len(self.shipArt.pixels) else 0,
		shipArtFailed=if self.shipArt.failed then 1 else 0,
		shipArtBuildMs=self.shipArt.buildMs or 0,
		nameViews = names, rosterNames = #self.roster, flagImages = flags, unitLabels = unitLabels,
		nameVisits=self.nameVisits or 0,nameStatusDraws=self.nameStatusDraws or 0,
		trajectorySegments = #self.trajectories, atlasPixelBytes = Atlas.width * Atlas.height * 4,
		trailTiles = trailTiles, fxSprites = #self.effects.state.sprites, fxShockwaves = #self.effects.state.shockwaves,
		bonusPopups = #self.effects.state.popups, fxAtlasPixelBytes = if self.effects.atlas then 540*306*4 else 0,
		statusAtlasPixelBytes = if self.nameStatus.atlas then 640*448*4 else 0,
		statusImages = self.nameStatus.images}
end
function Overlay.destroy(self: any)
	if self.destroyed then return end
	self.destroyed = true
	self.titles:destroy();table.clear(self.cosmeticOverrides);table.clear(self.blastStyles)
	self.sabotageReach:destroy()
	self.feel:destroy()
	self.artillery:destroy()
	if self.spreadRoot then self.spreadRoot:Destroy() end
	if self.strikePreviewRoot then self.strikePreviewRoot:Destroy() end
	if self.paraLanding then self.paraLanding:Destroy() end
	if self.sabotageTarget then self.sabotageTarget:Destroy() end
	self.supportIds={}
	self.effects:destroy(); self.trails:reset()
	self.defense:clear(); table.clear(self.defenseRangeKeys); self.attacks={}
	self.structureCache:destroy(); self.mobileCache:destroy()
	if self.shipArt.image then self.shipArt.image:Destroy() end
	self.shipArt.image,self.shipArt.content,self.shipArt.pixels=nil,nil,nil
	self.shipCombatSequences=nil
	self.playerStatus:clear(); self.nameStatus:destroy()
	for _, layer in self.layers do layer:Destroy() end
	self.atlas:Destroy()
	self.units, self.railroads, self.names = {}, {}, {}
	table.clear(self.unitViews); table.clear(self.railLines); table.clear(self.pendingIcons); table.clear(self.adornmentUnits); table.clear(self.unitCellFor); table.clear(self.staleUnits)
	table.clear(self.railCells);table.clear(self.railRecords);table.clear(self.railWanted);table.clear(self.adornmentOrder)
	table.clear(self.rings); table.clear(self.nameViews)
	table.clear(self.nameMeasurements); table.clear(self.namePlayers); table.clear(self.nameSlots)
	table.clear(self.headImages)
	table.clear(self.unitOrder); table.clear(self.knownUnits); table.clear(self.unitCells)
	table.clear(self.nameTransitions); table.clear(self.friendly); table.clear(self.allianceClusters)
	self.selection:clear(); self.selection.onSingleChanged=nil; table.clear(self.selectionViews)
	self.patrolUnitID,self.drawnPatrol=nil,nil
	table.clear(self.rangeViews); table.clear(self.rangePool); table.clear(self.rangeStrokes); table.clear(self.samRangeKeys); table.clear(self.samCircles)
	table.clear(self.samRecords)
	if self.ghostViews then table.clear(self.ghostViews) end
	self.warshipGhost=nil
	if self.ghostRails then table.clear(self.ghostRails) end
	table.clear(self.trajectories)
	self.buildPreview,self.preview,self.drawnBuildPreview,self.drawnTrajectory=nil,nil,nil,nil
end
return Overlay
