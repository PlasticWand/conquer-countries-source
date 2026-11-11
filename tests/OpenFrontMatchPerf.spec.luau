--!strict
-- Scheduling, information preservation and ownership of cached native assets.
-- These properties do not prove engine GUI cost, GPU uploads or phone feel.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Cache,Structure,Policy=H.require(root.StructureAtlas),H.require(root.StructureMath),H.require(root.RenderPolicy)
	local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local function setup()
		local e=native(); local s=e.client(); s.startTick=0; s.names={}
		local terrain=buffer.create(4096); buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
		return e,s,r
	end
	local function settle(e,r)
		for _=1,40 do e.now+=.016; r:step(1e9,1e9) end
	end
	t.test('shell trail keeps sprite dimensions instead of filling the Ground layer',function()
		local e,s,r=setup()
		s.units[1]={id=1,type='Shell',owner=1,tile=100,lastTile=99,active=true,level=1}
		r:attachState(s); r:step(1e9,1e9)
		local trail=r.scene.unitViews[1].trail
		t.eq(trail.Size.X.Scale,0,'shell pixel must not be stretched across the viewport')
		t.near(trail.Size.X.Offset,13*64,1)
		t.near(trail.Size.Y.Offset,13*64,1)
		r:destroy()
	end)
	t.test('shared transforms preserve map alignment and icon sizes through pan, zoom and viewport offsets',function()
		local e,s,r=setup()
		s.units[1]={id=1,type='City',owner=1,tile=100,active=true,level=1}
		s.units[2]={id=2,type='Transport',owner=1,tile=101,active=true,level=1}
		r:attachState(s); settle(e,r)
		for _,zoom in {.39,.613,1.19,1.21,4,8,20} do
			local c=table.clone(r.camera); c.scale,c.offsetX,c.offsetY,c.left,c.top=zoom,2.3,-1.7,17,42
			r:setCamera(c)
			for id,view in r.scene.unitViews do
				local layer=r.scene.layers[if view.structure then "Structures" else "Ground"]
				local multiplier=if view.structure then r.scene.structureScale.Scale else r.scene.worldScale.Scale
				local origin=if view.structure then layer.Position else r.scene.world.Position
				local w=if view.structure then layer.Size.X.Scale*c.viewportWidth else r.core.width*64
				local h=if view.structure then layer.Size.Y.Scale*c.viewportHeight else r.core.height*64
				local nx,ny=view.root.Position.X.Scale,view.root.Position.Y.Scale
				local bucket=view.root.Parent
				if bucket~=layer then
					nx=bucket.Position.X.Scale+nx*bucket.Size.X.Scale
					ny=bucket.Position.Y.Scale+ny*bucket.Size.Y.Scale
				end
				local x=origin.X.Scale*c.viewportWidth+nx*w*multiplier+c.left
				local y=origin.Y.Scale*c.viewportHeight+ny*h*multiplier+c.top
				local tile=s.units[id].tile
				local expectedX,expectedY=r:worldToScreen(tile%64+.5,math.floor(tile/64)+.5)
				t.near(x,expectedX,1); t.near(y,expectedY,1)
				local size=if view.structure then Structure.presentationSize('City',zoom) else 13*zoom
				if s.units[id].type=='Transport' or s.units[id].type=='Trade Ship' then size*=.7 end -- Bruno's approved boat scale
				t.near(view.root.Size.X.Offset*multiplier,size,1)
			end
			-- Camera input updates raster and overlay transforms together before
			-- a renderer frame or a confirmed tick can refresh any individual unit.
			r:step(1e9,1e9)
		end
		r:destroy()
	end)
	t.test('screen telegraphs and invalid-ghost outlines follow camera transforms without redrawing settled units',function()
		local e,s,r=setup()
		s.units[1]={id=1,type='Atom Bomb',owner=1,tile=100,targetTile=200,active=true,level=1}
		r:attachState(s); settle(e,r)
		local ring=r.scene.rings[1].frame; local old=ring.Position
		local draws=r.scene.unitDraws; r:pan(20,0); r:step(1e9,1e9)
		t.ok(ring.Position~=old,'telegraph must move even when no state tick arrived')
		t.eq(r.scene.unitDraws,draws)
		r:setBuildPreview({ghostType='City',ownerID=1,tileX=10.25,tileY=11.75,canBuild=false})
		r:step(1e9,1e9)
		local ghost=r.scene.ghostViews[1]
		t.near(ghost.ghostStroke.Thickness*r.scene.structureScale.Scale,1.5,1e-5)
		r:destroy()
	end)
	t.test('camera property writes stay constant with ten or one thousand retained structures',function()
		local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
		source=source:gsub('local o: any = {ClassName=class','local values: any = {ClassName=class')
		source=source:gsub('o.GetPropertyChangedSignal=function',[[local o: any = setmetatable({}, {__index=values,__newindex=function(_,key,value)
			if type(value)~='function' then env.writes=(env.writes or 0)+1 end
			values[key]=value
		end})
		o.GetPropertyChangedSignal=function]])
		local make=luau.load(source)()
		local counts={}
		for _,count in {10,1000} do
			local e=make(); local state=e.client(); state.startTick=0; state.names={}
			for id=1,count do state.units[id]={id=id,type='City',owner=1,tile=id%4096,active=true,level=1} end
			local terrain=buffer.create(4096); buffer.fill(terrain,0,128)
			local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false})
			r:setRoster({{id='a',smallID=1,playerType='HUMAN'}}); r:attachState(state)
			for _=1,64 do r:step(1e9,1e9) end
			e.writes=0; local c=table.clone(r.camera); c.offsetX+=2; c.scale*=.99; r:setCamera(c)
			table.insert(counts,e.writes)
			local draws=r.scene.unitDraws; r:step(1e9,1e9); t.eq(r.scene.unitDraws,draws)
			r:destroy()
		end
		t.eq(counts[1],counts[2]); t.ok(counts[1]<=24,'bounded shared transform and map page writes')
	end)
	t.test('sparse interiors retain old pixels and cached borders match a complete repaint',function()
		local Core=raster.Core
		local terrain=buffer.create(128*64); buffer.fill(terrain,0,128)
		local sink=raster.sink(128,64); local core=Core.new(terrain,128,64,sink.backend)
		Core.setRoster(core,{{id='a',smallID=1,playerType='HUMAN'},{id='b',smallID=2,playerType='HUMAN'}})
		local states=buffer.create(128*64*2); for tile=0,128*64-1 do buffer.writeu16(states,tile*2,1) end
		Core.applyTileStates(core,states); raster.drain(core,1e9)
		local before=core.shadedPixels
		for _,tile in {4*128+34,27*128+60} do buffer.writeu16(states,tile*2,2) end
		Core.applyTileStates(core,states,{4*128+34,27*128+60}); raster.drain(core,1e9)
		t.eq(core.shadedPixels-before,18,'only two 3x3 halos are shaded')
		local function compare()
			local fresh=raster.sink(128,64); local other=Core.new(terrain,128,64,fresh.backend)
			Core.setRoster(other,core.roster); Core.applyTileStates(other,states)
			Core.setRelations(other,{size=core.relationSize,data=core.relations}); Core.setHover(other,core.hover)
			Core.applyTrails(other,core.trails,{4*128+35}); raster.drain(other,1e9)
			for y=0,63 do for x=0,127 do t.eq(sink.pixel(x,y),fresh.pixel(x,y),`pixel {x},{y}`) end end
			Core.destroy(other)
		end
		compare()
		Core.applyTrails(core,{[4*128+35]=2},{4*128+35}); raster.drain(core,1e9); compare()
		local relations=buffer.create(9); buffer.writeu8(relations,1*3+2,2)
		Core.setRelations(core,{size=3,data=relations}); raster.drain(core,1e9); compare()
		Core.setHover(core,2); raster.drain(core,1e9); compare(); Core.destroy(core)
	end)
	t.test('composed cache preserves owner fill and rim, alpha edges and transparent gutters',function()
		local pixels
		local image={Destroy=function() end}
		local cache=Cache.new(1,function() return {image=image} end,function(_,_,_,data) pixels=data end)
		local fill,edge=rb.Color3.fromRGB(51,102,153),rb.Color3.fromRGB(20,40,60)
		local entry=cache:acquire(0,true,fill,edge)
		t.eq(entry.ready,false); cache:prepare(1e9); t.eq(entry.ready,true)
		local function pixel(x,y,c) return buffer.readu8(pixels,(y*Cache.cell+x)*4+c) end
		for c,value in {51,102,153,255} do t.eq(pixel(33,33,c-1),value,'owner fill') end
		for c,value in {20,40,60} do t.eq(pixel(61,33,c-1),value,'rim colour') end
		local soft=0
		for y=0,Cache.cell-1 do for x=0,Cache.cell-1 do
			local a=pixel(x,y,3)
			if a>0 and a<255 then soft+=1 end
			if x==0 or y==0 or x==Cache.cell-1 or y==Cache.cell-1 then t.eq(a,0,'filtering gutter') end
		end end
		t.ok(soft>0,'analytic antialiasing retained'); cache:release(entry); cache:destroy()
	end)
	t.test('cache capacity never evicts referenced styles; released slots reuse without growth',function()
		local allocations,writes=0,0
		local cache=Cache.new(1,function() allocations+=1; return {image={Destroy=function() end}} end,function() writes+=1 end)
		local entries={}
		for i=1,Cache.columns^2 do
			entries[i]=cache:acquire(0,true,rb.Color3.fromRGB(i,100,150),rb.Color3.new())
		end
		local color=rb.Color3.fromRGB(250,200,150)
		t.eq(cache:acquire(1,false,color,rb.Color3.new()),nil,'layered fallback when all cells are referenced')
		local oldKey=entries[1].key
		cache:release(entries[1])
		local replacement=cache:acquire(1,false,color,rb.Color3.new())
		t.eq(replacement,entries[1]); t.eq(cache.entries[oldKey],nil); t.eq(#cache.slots,Cache.columns^2)
		local same=cache:acquire(1,false,color,rb.Color3.new())
		t.eq(same,replacement); t.eq(same.refs,2); cache:release(same)
		while cache.queue[cache.head] do cache:prepare(1e9) end
		t.eq(allocations,1); t.eq(writes,Cache.columns^2); t.eq(replacement.ready,true)
		for _,entry in entries do cache:release(entry) end
		cache:destroy()
	end)
	t.test('settled structures use two GUI objects; idle and unchanged ticks perform no unit draws',function()
		local e,s,r=setup()
		s.units[1]={id=1,type='City',owner=1,tile=100,active=true,level=1}
		r:attachState(s); settle(e,r)
		local view=r.scene.unitViews[1]
		t.eq(#view.parts,1); t.eq(view.parts[1].ResampleMode,rb.Enum.ResamplerMode.Default); t.eq(view.progress,nil)
		local count=0; for _,o in e.objects do if not o.destroyed and (o==view.root or o.Parent==view.root) then count+=1 end end
		t.eq(count,2)
		local scans,draws=r.scene.unitScans,r.scene.unitDraws
		settle(e,r); t.eq(r.scene.unitScans,scans,'no idle unit scan'); t.eq(r.scene.unitDraws,draws)
		s.tick=1; s.TickApplied:Fire(1); r:step(1e9,1e9); t.eq(r.scene.unitDraws,draws,'unchanged confirmed tick')
		r:destroy(); for _,image in e.images do t.eq(image.destroyed,true) end
	end)
	t.test('shared camera transform moves retained views without projecting or rebuilding them',function()
		local e,s,r=setup()
		s.units[1]={id=1,type='City',owner=1,tile=100,active=true,level=3}
		r:attachState(s); settle(e,r)
		local view=r.scene.unitViews[1]; local oldSlot=view.iconSlot
		local position,world,draws=view.root.Position,r.scene.layers.Structures.Position,r.scene.unitDraws
		r:pan(20,0); r:step(1e9,1e9)
		t.eq(view.root.Position,position); t.ok(r.scene.layers.Structures.Position~=world)
		t.eq(view.iconSlot,oldSlot); t.eq(r.scene.unitDraws,draws)
		local camera=table.clone(r.camera); camera.offsetX=10000; r:setCamera(camera); r:step(1e9,1e9)
		t.eq(view.root.Position,position); t.eq(view.iconSlot,oldSlot,'native clipping retains the reusable style')
		t.eq(r.scene.unitDraws,draws,'camera does no unit projection')
		t.eq(view.root.Parent.Visible,false,'offscreen subtree is hidden without touching its views')
		r:centerAll(); settle(e,r)
		t.eq(view.parts[1].ImageRectOffset,rb.Vector2.new(view.iconSlot.x+1,view.iconSlot.y+1))
		s.units[1].owner=2; s.UnitsChanged:Fire({},{}); settle(e,r)
		t.eq(view.iconSlot.fill,rb.Color3.new(r.core.palette[2].fill.r,r.core.palette[2].fill.g,r.core.palette[2].fill.b))
		t.eq(view.level.Text,'3'); t.eq(view.level.Visible,true)
		r:destroy()
	end)
	t.test('hidden cells defer styling and reveal the latest confirmed pose, owner and annotations',function()
		local e,s,r=setup()
		s.units[1]={id=1,type='City',owner=1,tile=100,active=true,level=1}
		r:attachState(s); settle(e,r)
		local view=r.scene.unitViews[1]; local position=view.root.Position
		local c=table.clone(r.camera); c.offsetX=10000; r:setCamera(c); r:step(1e9,1e9)
		t.eq(view.root.Parent.Visible,false)
		local draws=r.scene.unitDraws
		s.units[1].owner=2; s.units[1].tile=101; s.units[1].level=3; s.units[1].hasTrainStation=true
		s.UnitsChanged:Fire({},{}); r:step(1e9,1e9)
		t.eq(r.scene.unitDraws,draws); t.eq(view.root.Position,position); t.eq(view.record.owner,1)
		r:centerAll(); r:step(1e9,1e9)
		t.eq(view.root.Parent.Visible,true); t.eq(view.record.owner,2); t.eq(view.record.tile,101)
		t.ok(view.root.Position~=position); t.eq(view.level.Text,'3'); t.eq(view.station.Visible,true)
		r:destroy()
	end)
	t.test('confirmed ground motion updates only pose; health, train loading and owner changes still refresh styles',function()
		local e,s,r=setup()
		s.units[1]={id=1,type='Warship',owner=1,tile=100,lastTile=99,active=true,health=100,maxHealth=100}
		r:attachState(s); settle(e,r)
		local view=r.scene.unitViews[1]; local slot,record=view.iconSlot,view.record
		s.units[1].tile,s.units[1].lastTile=101,100; s.UnitsMoved:Fire({1},1); s.TickApplied:Fire(1); r:step(1e9,1e9)
		t.eq(r.scene.unitPoseDraws,1); t.eq(view.iconSlot,slot); t.eq(view.record,record); t.eq(view.record.tile,101)
		s.units[1].tile=102; s.units[1].health=50; s.UnitsMoved:Fire({1},2); s.TickApplied:Fire(2); r:step(1e9,1e9)
		t.eq(r.scene.unitPoseDraws,1); t.ok(view.health.background.Visible); t.eq(view.record.health,50)
		s.units[1].owner=2; s.UnitsChanged:Fire({},{}); r:step(1e9,1e9)
		t.eq(view.record.owner,2); t.eq(r.scene.unitPoseDraws,1)
		r:destroy()
	end)
	t.test('inactive or waiting records need no position and stop retained interpolation',function()
		local e,s,r=setup()
		s.units[1]={id=1,type='City',owner=1,active=false}
		s.units[2]={id=2,type='Transport',owner=1,active=true,waitTicks=3}
		r:attachState(s); settle(e,r)
		t.eq(next(r.scene.unitViews),nil); t.eq(next(r.scene.smoothUnits),nil)
		r:destroy()
	end)
	t.test('uncreated hidden units are removed from cell membership without leaking stale state',function()
		local e,s,r=setup(); s.units={}; r:attachState(s); settle(e,r)
		local c=table.clone(r.camera); c.offsetX=10000; r:setCamera(c); r:step(1e9,1e9)
		s.units[9]={id=9,type='Transport',owner=1,tile=100,active=true}
		s.units[10]={id=10,type='Atom Bomb',owner=1,tile=100,active=true}
		s.UnitsChanged:Fire({s.units[9],s.units[10]},{}); r:step(1e9,1e9)
		t.eq(r.scene.unitViews[9],nil); t.eq(r.scene.staleUnits[9],true)
		local key=r.scene.unitCellFor[9]; t.eq(r.scene.unitCells[key].units[9],true)
		s.units[9],s.units[10]=nil,nil; s.UnitsChanged:Fire({},{9,10})
		t.eq(r.scene.pendingIcons[10],nil); t.eq(r.scene.smoothUnits[10],nil)
		t.eq(r.scene.unitCellFor[9],nil); t.eq(r.scene.unitCells[key].units[9],nil); t.eq(r.scene.staleUnits[9],nil)
		r:destroy()
	end)
	t.test('construction, cooldown, deletion, level and station information survive composition',function()
		local e,s,r=setup(); s.tick=10
		s.units[1]={id=1,type='City',owner=1,tile=100,active=true,level=3,underConstruction=true,constructionStartTick=0,hasTrainStation=true}
		r:attachState(s); settle(e,r)
		local view=r.scene.unitViews[1]
		t.ok(view.progress.background.Visible); t.eq(view.iconSlot.fill,rb.Color3.fromRGB(198,198,198))
		t.eq(view.level.Text,'3'); t.eq(view.station.Visible,true)
		s.units[1].underConstruction=false; s.UnitsChanged:Fire({},{}); settle(e,r); t.eq(view.progress,nil)
		s.units[1].markedForDeletion=100; s.UnitsChanged:Fire({},{}); settle(e,r)
		t.eq(view.deletion.Visible,true); t.eq(view.progress.background.Visible,true)
		s.units[2]={id=2,type='Missile Silo',owner=1,tile=300,active=true,level=2,missileTimerQueue={10}}
		s.UnitsChanged:Fire({s.units[2]},{}); settle(e,r)
		t.eq(r.scene.unitViews[2].progress.background.Visible,true)
		s.tick=1000; s.TickApplied:Fire(1000); settle(e,r); t.eq(r.scene.unitViews[2].progress,nil)
		r:destroy()
	end)
	t.test('composed ground sprites retain train masks, owner colour, health and veterancy with allocation fallback',function()
		for _,fail in {false,true} do
			local e,s,r=setup(); e.failMobiles=fail
			e.policy.smoothShips=false -- exercise the retained source/failure path deterministically
			s.units[1]={id=1,type='Train',trainType='Engine',owner=1,tile=100,active=true}
			s.units[2]={id=2,type='Warship',owner=1,tile=200,active=true,health=50,maxHealth=100,warship={veterancy=2}}
			r:attachState(s); settle(e,r)
			local train,ship=r.scene.unitViews[1],r.scene.unitViews[2]
			t.eq(#train.parts,if fail then 4 else 1); t.eq(#ship.parts,if fail then 4 else 1)
			t.ok(ship.health.background.Visible); t.ok(ship.pips.Visible)
			if not fail then t.eq(train.iconSlot.column,9); t.eq(train.iconSlot.colors[1],train.iconSlot.fill) end
			s.units[1].trainType='Wagon'; s.units[1].loaded=true
			s.units[2].owner=2; s.units[2].targetUnitId=99; s.units[2].health=100
			s.UnitsChanged:Fire({},{}); settle(e,r)
			t.eq(ship.health.background.Visible,false)
			if not fail then t.eq(train.iconSlot.column,11); t.eq(ship.iconSlot.colors[1],rb.Color3.fromRGB(200,0,0)) end
			r:destroy(); for _,img in e.images do t.eq(img.destroyed,true) end
		end
	end)
	t.test('rail detail uses one image per tile and zoom-out releases the hidden pool',function()
		local e,s,r=setup()
		local path={}; for tile=138,177 do table.insert(path,tile) end
		s.railroads={[1]=path}
		r:attachState(s)
		local c=table.clone(r.camera); c.scale=8; c.offsetX=30-32-(c.viewportWidth/2-32)/8; c.offsetY=2.5-32-(c.viewportHeight/2-32)/8; r:setCamera(c); settle(e,r)
		t.eq(r.scene.visibleRails,40); t.eq(#r.scene.railLines,40)
		for _,rail in r.scene.railLines do t.eq(rail.ClassName,'ImageLabel'); t.eq(rail.ImageRectSize,rb.Vector2.new(3,3)) end
		c.scale=.5; r:setCamera(c); r.scene.railsDirty=true; r:step(1e9,1e9)
		t.eq(r.scene.visibleRails,0); t.ok(#r.scene.railLines<=32)
		t.eq(r:metrics().railGuiObjects,#r.scene.railLines); t.ok(r:metrics().mapGuiObjects>=#r.scene.railLines)
		r:destroy()
	end)
	t.test('dense rails create and retire at most the policy batch each frame',function()
		local e,s,r=setup()
		for y=10,29 do local path={};for x=10,49 do table.insert(path,y*64+x) end;s.railroads[y]=path end
		r:attachState(s)
		local c=table.clone(r.camera);c.scale=4;r:setCamera(c)
		for _=1,40 do
			local creates=r.scene.railCreates or 0;e.now+=1/60;r:step(1e9,1e9)
			t.ok((r.scene.railCreates or 0)-creates<=Policy.railCreatesPerFrame)
		end
		t.eq(r.scene.visibleRails,800);t.eq(r.scene.railsPending,false)
		c.scale=.5;r:setCamera(c)
		for _=1,30 do
			local deletes=r.scene.railDeletes or 0;e.now+=1/60;r:step(1e9,1e9)
			t.ok((r.scene.railDeletes or 0)-deletes<=Policy.railDeletesPerFrame)
			t.eq(r.scene.layers.Rails.Visible,false,'hidden rails flashed during retirement')
		end
		t.ok(#r.scene.railLines<=32);r:destroy()
	end)
	t.test('camera-only adornment and structure LOD refreshes have bounded batches',function()
		local e,s,r=setup()
		for id=1,200 do s.units[id]={id=id,type='City',owner=1,tile=id+100,active=true,level=3,hasTrainStation=true} end
		r:attachState(s);settle(e,r)
		for _,scale in {.5,4,.5,4} do
			local c=table.clone(r.camera);c.scale=scale;r:setCamera(c)
			for _=1,10 do
				local a,b=r.scene.adornmentRefreshes or 0,r.scene.structureLodRefreshes or 0
				e.now+=1/60;r:step(1e9,1e9)
				t.ok((r.scene.adornmentRefreshes or 0)-a<=Policy.adornmentUpdatesPerFrame)
				t.ok((r.scene.structureLodRefreshes or 0)-b<=Policy.structureLodVisitsPerFrame)
			end
			for _,view in r.scene.unitViews do t.eq(view.lod,scale<=1.2) end
		end
		local c=table.clone(r.camera);c.scale=.5;r:setCamera(c)
		s.units={};s.UnitsChanged:Fire({},{});r:step(1e9,1e9)
		t.eq(r.scene.lodRemaining,0);t.eq(#r.scene.adornmentOrder,0,'removed units retained camera refresh work')
		r:destroy()
	end)
	t.test('presentation sizing is smaller, continuous and monotonic; source equations remain available',function()
		t.near(Structure.size('City',.61).screenSize,18,1e-9)
		local size=Structure.presentationSize('City',.61)
		t.ok(size>7 and size<10,'roughly half at World fit')
		local prior=0
		for i=20,2000 do local current=Structure.presentationSize('City',i/100); t.ok(current>=prior); prior=current end
		for _,zoom in {1.2,3,7} do
			t.near(Structure.presentationSize('City',zoom-.000001),Structure.presentationSize('City',zoom+.000001),.0001)
		end
		local old=Policy.continuousStructureZoom; Policy.continuousStructureZoom=false
		t.near(Structure.presentationSize('City',4),Structure.size('City',4).screenSize*Policy.structureScale,1e-9)
		Policy.continuousStructureZoom=old
	end)
	t.test('visible raster work precedes unseen pages; background work drains with partial jobs intact',function()
		local Core=raster.Core
		local terrain=buffer.create(2048*64); buffer.fill(terrain,0,128)
		local sink=raster.sink(2048,64)
		local core=Core.new(terrain,2048,64,sink.backend)
		raster.drain(core,1e9); table.clear(sink.writes)
		Core.setViewport(core,{x0=1500,y0=0,x1=1800,y1=64})
		Core.repaint(core)
		local result=Core.step(core,1e9,1024)
		t.eq(result.page,2,'visible page before FIFO page 1'); t.eq(sink.writes[1],2)
		local original=core.pending
		for _=1,10000 do
			if core.pending==0 then break end
			Core.step(core,1e9,64)
		end
		t.eq(core.pending,0,'background fairness and partial-row progress'); t.ok(original>0)
		local fresh=raster.sink(2048,64); local other=Core.new(terrain,2048,64,fresh.backend); raster.drain(other,1e9)
		for _,point in {{0,0},{1023,63},{1024,0},{2047,63}} do t.eq(sink.pixel(point[1],point[2]),fresh.pixel(point[1],point[2])) end
		Core.destroy(core); Core.destroy(other)
	end)
	t.test('adaptive raster limits respect touch ceilings and explicit caller budgets',function()
		for _,touch in {false,true} do
			local e=native(); e.uis.TouchEnabled=touch
			local terrain=buffer.create(512*512); buffer.fill(terrain,0,128)
			local r=e.Renderer.new(e.instance('Frame'),terrain,512,512,{autoStep=false})
			-- Incremental adapters start ready, so the live catch-up policy applies.
			r:step()
			t.eq(r.rasterMaxMs,if touch then Policy.rasterTouchMaxMs else Policy.rasterDesktopMaxMs)
			t.eq(r.rasterBudgetMs,r.rasterMaxMs)
			r:step(.5,32); t.eq(r.rasterBudgetMs,.5)
			r:destroy()
		end
	end)
	t.test('composed icon uploads share the single displayed-image frame slot with map and status',function()
		local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
		source=source:gsub('image.WritePixelsBuffer=function%(_,_,size,pixels%)',
			'image.WritePixelsBuffer=function(_,_,size,pixels) env.frameImages=env.frameImages or {}; env.frameImages[image]=true;')
		local make=luau.load(source)()
		-- Full paint gained progressive rows (f64fb61) and coast preparation
		-- (a480ec4). Its wall-time slices do not promise completion in 100 calls.
		for _,budgetMs in {30,1e-9} do
			local e=make(); local s=e.client(); s.startTick=0; s.names={}
			for id=1,50 do s.units[id]={id=id,type='City',owner=id%2+1,tile=100+id,active=true,level=1} end
			local terrain=buffer.create(4096); buffer.fill(terrain,0,128)
			local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,firstPaint='full',firstPaintBudgetMs=budgetMs})
			r:attachState(s)
			-- Even an exhausted slice commits one 32px-wide row. Allow all 128
			-- block rows plus 32 preparation/reveal turns; keep every frame checked.
			local maxFrames=r.core.height*math.ceil(r.core.width/raster.Core.BLOCK)+32
			for frame=1,maxFrames do
				e.frameImages={}; r:step()
				local count=0; for _ in e.frameImages do count+=1 end
				t.ok(count<=1,'multiple displayed images uploaded in one frame')
				if frame==100 and budgetMs<1 then
					t.eq(r:isReady(),false,'exhausted slices must exercise the old cutoff')
					t.ok(r.core.pending>0,'map work should still hold the loading cover')
				end
				t.eq(r.root.Visible,r:isReady(),'loading cover released before full paint')
			end
			t.eq(r:isReady(),true); t.ok(r.scene.structureCache.pages[1]~=nil)
			r:destroy(); for _,image in e.images do t.eq(image.destroyed,true) end
		end
	end)
	t.test('live style bursts leave at least three of four image slots for dirty ownership',function()
		local e,s,r=setup()
		local roster={}
		for id=1,80 do
			roster[id]={id=`p{id}`,smallID=id,playerType='NATION'}
			s.units[id]={id=id,type='City',owner=id,tile=100+id,active=true,level=1}
		end
		r:setRoster(roster); r:attachState(s)
		local before=r.core.steps
		for _=1,80 do r:step(.01,1) end
		t.ok(r.core.steps-before>=60,'composition starved the raster slot')
		t.ok(r.core.pending>0,'test must keep ownership dirty')
		local count=0; for _,view in r.scene.unitViews do if view.root.Visible then count+=1 end end
		t.eq(count,80,'pending cache never hides a source icon')
		r:destroy()
	end)
	t.test('optional atlas allocation refusal keeps the complete layered map icons',function()
		local e,s,r=setup(); e.failStructures=true
		s.units[1]={id=1,type='City',owner=1,tile=100,active=true,level=3}
		r:attachState(s); settle(e,r)
		local view=r.scene.unitViews[1]
		t.eq(r.destroyed,false); t.eq(view.root.Visible,true); t.eq(#view.parts,3)
		t.eq(view.level.Text,'3'); t.eq(r:metrics().structureAtlasFailed,1)
		s.units[1].owner=2; s.UnitsChanged:Fire({},{}); settle(e,r)
		t.eq(view.parts[2].ImageColor3,rb.Color3.new(r.core.palette[2].fill.r,r.core.palette[2].fill.g,r.core.palette[2].fill.b))
		t.eq(r.scene.structureCache.queue[1],nil)
		r:destroy(); for _,image in e.images do t.eq(image.destroyed,true) end
	end)
end
