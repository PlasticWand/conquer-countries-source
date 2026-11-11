--!strict
-- Confirmed fixture/lifecycle and GUI budget evidence, not native appearance
-- or server artillery mechanics. Shared/server code is owned by Claude.
return function(t)
	local fs,luau,serde,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/serde'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local State,Visual,Atlas=H.require(root.ArtilleryState),H.require(root.UnitVisuals),H.require(root.SpriteAtlas)
	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function fixture():any return serde.decode('json',fs.readFile('tests/fixtures/OpenFrontArtillery.json')) end
	local function count(items:any):number local n=0;for _ in items do n+=1 end;return n end
	local function setup(split:boolean?):any
		local f,e=fixture(),native();e.policy.splitMapGuis=split==true;e.mapGui.DisplayOrder=0
		local s=e.client();s.startTick=0
		local config=s:config()
		local original=config.unitInfo
		config.ARTILLERY_RANGE=f.range
		config.unitInfo=function(self:any,kind:string):any
			if kind=='Artillery' then return {constructionDuration=80} end
			if kind=='Artillery Shell' then return {constructionDuration=0} end
			return original(self,kind)
		end
		s.config=function() return config end
		for _,u in f.units do s.units[u.id]=u end
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false,guiHost=e.mapGui,coasts=false})
		r:attachState(s)
		for _=1,120 do r:step(1e9,1e9) end
		r:setCamera({width=64,height=64,viewportWidth=844,viewportHeight=390,left=0,top=0,offsetX=0,offsetY=0,scale=4})
		for _=1,10 do r:step(1e9,1e9) end
		return e,s,r,f
	end
	local function update(s:any,u:any,removed:{number}?)
		s.units[u.id]=u;s.UnitsChanged:Fire({u},removed or {})
	end
	t.test('artillery has an original diamond and cannon without changing legacy atlas cells',function()
		local pixels=Atlas.rgba()
		t.eq(buffer.len(pixels),512*192*4)
		local gx,gy,gw,gh=Atlas.iconRect(7);t.eq(gx,480);t.eq(gy,80);t.eq(gw,32);t.eq(gh,32)
		local glyph=0;for y=gy,gy+gh-1 do for x=gx,gx+gw-1 do if buffer.readu8(pixels,(y*512+x)*4+3)>0 then glyph+=1 end end end
		t.ok(glyph>80 and glyph<600,'readable bounded cannon mask')
		t.eq(buffer.readu8(pixels,((120+32)*512+448+32)*4+3),255)
		t.eq(buffer.readu8(pixels,((120+4)*512+448+4)*4+3),0)
		-- Golden rolling-u32 hash from 5c1c44b, excluding only the new cells;
		-- includes selection and railroad bytes. The spec needs no git process.
		local hash=0
		for y=0,191 do for x=0,511 do
			local newGlyph=x>=480 and y>=80 and y<112
			local newShape=x>=448 and y>=120 and y<184
			local strikeCells=(x>=192 and x<512 and y<32) or (x>=156 and x<169 and y<13)
			if not newGlyph and not newShape then hash=(hash*33+(if strikeCells then 0 else buffer.readu32(pixels,(y*512+x)*4)))%4294967296 end
		end end
		t.eq(hash,fixture().legacyAtlasHash)
		local col,structure=Visual.sprite({type='Artillery'});t.eq(col,7);t.eq(structure,true)
		t.eq(Visual.constructionDuration('Artillery'),80)
		local u=fixture().shell;local v=Visual.unit(u,64,4,.5)
		t.near(v.x,34.5,1e-9);t.near(v.y,32,1e-9);t.ok(v.missile);t.eq(v.structure,false)
	end)
	t.test('copied artillery edges suppress snapshots and duplicates and require confirmed impacts',function()
		local f,state=fixture(),State.new(64)
		state:seed({[100]=f.shell});state:updates({f.shell},{},function() return true end,0,4)
		t.eq(#state.marks,0)
		f.shell.active=false;f.shell.reachedTarget=false
		state:updates({f.shell},{},function() return true end,0,4);t.eq(#state.marks,0)
		state:seed({});f.shell.active=true
		state:updates({f.shell},{},function() return true end,1,4)
		t.eq(#state.marks,1);t.eq(state.marks[1].kind,'muzzle');t.eq(state.marks[1].x,32.5)
		state:updates({f.shell},{},function() return true end,1,4);t.eq(#state.marks,1)
		f.shell.active=false;f.shell.reachedTarget=true
		state:updates({f.shell},{},function() return true end,1,4)
		t.eq(#state.marks,2);t.eq(state.marks[2].kind,'impact');t.eq(state.marks[2].x,42.5)
		state:updates({f.shell},{},function() return true end,1,4);t.eq(#state.marks,2)
		state:seed({[100]=f.shell});state:updates({f.shell},{},function() return true end,2,4);t.eq(#state.marks,0)
		state:seed({});state:updates({f.shell},{},function() return true end,2,4)
		t.eq(#state.marks,2,'short flight received only as a confirmed final still has a source flash and impact')
		state:seed({});state:updates({f.shell},{100},function() return false end,2,4)
		t.eq(#state.marks,0);t.eq(next(state.seen),nil)
	end)
	t.test('impacts merge, caps hold and level loss reads continuous confirmed ownership only',function()
		local state=State.new(64);state:seed({})
		local updates={}
		for id=1,100 do table.insert(updates,{id=id,type='Artillery Shell',owner=2,tile=2080,targetTile=2080,active=false,reachedTarget=true}) end
		state:updates(updates,{},function() return true end,0,4);t.eq(#state.marks,1,'overlapping burst merged')
		local city=fixture().units[3];state:seed({[3]=city})
		city.level=2;city.health=1000
		state:updates({city},{},function() return true end,1,4)
		t.eq(#state.marks,1);t.eq(state.marks[1].kind,'levelLoss');t.eq(state.marks[1].loss,1)
		state:updates({city},{},function() return true end,1,4);t.eq(#state.marks,1)
		city.level=1;city.owner=1;state:updates({city},{},function() return true end,1,4);t.eq(#state.marks,1,'capture is not damage')
		state:expire(1.37);t.eq(#state.marks,0)
		updates={};for id=101,150 do table.insert(updates,{id=id,type='Artillery Shell',owner=2,tile=id*4,active=false,reachedTarget=true}) end
		state:updates(updates,{},function() return true end,2,4);t.eq(#state.marks,State.markCap)
		state:seed({});t.eq(#state.marks,0)
	end)
	t.test('artillery draft and validated placement use exported range and tap inspection works for enemies',function()
		local e,s,r=setup();local preview=e.Preview.new(r,s,function() return nil end)
		preview:setChosen('Artillery');preview:draw(2080,32,32,false)
		t.eq(r.scene.buildPreview.ghostType,'Artillery');t.eq(r.scene.buildPreview.rangeRadius,45)
		preview.reply={tile=2080,unit='Artillery',tick=0,rangeWarning=false,
			buildable={type='Artillery',canBuild=2080,canUpgrade=false,cost=150000,ghostRailPaths={},overlappingRailroads={}}}
		preview:draw(2080,32,32,false);r:step(1e9,1e9)
		t.eq(r.scene.buildPreview.rangeRadius,45);t.ok(r.scene.rangeViews.BuildRange.Visible)
		t.ok(r.scene.ghostViews[1].root.Visible);t.eq(r.scene.ghostViews[1].parts[3].ImageRectOffset,rb.Vector2.new(480,80))
		preview:setChosen(nil);r.scene:inspectRange(2064);r:step(1e9,1e9)
		t.eq(r.scene.inspectedRange,2);t.ok(r.scene.rangeViews.InspectedRange.Visible)
		t.ok(r.scene.unitViews[1].structure);t.ok(r.scene.unitViews[1].progress)
		preview:destroy();r:destroy()
	end)
	t.test('damaged structure bars hide at full/absent health and survive zoom without changing progress',function()
		for _,split in {false,true} do
			local _,s,r=setup(split)
			local view=r.scene.unitViews[3];t.ok(view.health.background.Visible)
			local ratio=view.health.fill.Size.X.Offset/(view.health.background.Size.X.Offset-2/r.scene.iconScale)
			t.near(ratio,.85,.04,'UDim2 offset quantization stays within one visible bar pixel')
			local sam=r.scene.unitViews[4];t.ok(sam.health.background.Visible);t.ok(sam.progress)
			t.ok(sam.health.background.Position.Y.Offset>=sam.progress.background.Position.Y.Offset+sam.progress.background.Size.Y.Offset)
			local camera=table.clone(r.camera);camera.scale=1;r:setCamera(camera)
			for _=1,10 do r:step(1e9,1e9) end
			t.near(view.health.background.Size.Y.Offset*r.scene.iconScale,3,r.scene.iconScale*.51)
			local city=s.units[3];city.health=city.maxHealth;update(s,city);r:step(1e9,1e9);t.eq(view.health.background.Visible,false)
			city.health=nil;city.maxHealth=nil;update(s,city);r:step(1e9,1e9);t.eq(view.health.background.Visible,false)
			city.level=2;update(s,city);r:step(1e9,1e9)
			t.eq(r.scene.artillery.state.marks[1].kind,'levelLoss')
			r:destroy()
		end
	end)
	t.test('shells and burst GUI pools cap, interpolate, reuse, reset and obey the image slot',function()
		for _,split in {false,true} do
			local e,s,r,f=setup(split);local a=r.scene.artillery
			local shell=f.shell;update(s,shell);a:step(0,.5)
			t.eq(#a.shells,1);local slot=a.shells[1]
			local x,y=r:worldToScreen(35,32.5)
			t.near(slot.head.Position.X.Offset,x-r.camera.left,1e-6);t.near(slot.head.Position.Y.Offset,y-r.camera.top,1e-6)
			t.eq(r.scene.unitViews[100],nil,'no uncapped generic projectile view')
			local updates={}
			for id=101,300 do local u=table.clone(shell);u.id=id;u.tile+=id%5;s.units[id]=u;table.insert(updates,u) end
			s.UnitsChanged:Fire(updates,{})
			for _=1,12 do r:step(1e9,1e9) end
			t.eq(#a.shells,State.shellCap);t.eq(count(r.scene.smoothUnits),0)
			local objects=#e.objects
			for _=1,8 do a:step(1,.5) end
			t.eq(#e.objects,objects,'steady saturated shell set reuses views')
			shell.active=false;shell.reachedTarget=true;update(s,shell);r:step(1e9,1e9)
			t.ok(#a.state.marks>0);s.Snapshot:Fire();t.eq(#a.state.marks,0)
			for _,m in a.marks do t.eq(m.root.Visible,false) end
			e.recordUploads=true;e.uploads={};a:step(2,.5);t.eq(#e.uploads,0,'shells/accent rendering never writes images')
			for _=1,6 do e.uploads={};r:step(1e9,1e9);local images={};for _,image in e.uploads do images[image]=true end;t.ok(count(images)<=1) end
			s.winner=1;s.PhaseChanged:Fire();t.eq(#a.ids,0);t.eq(#a.state.marks,0)
			for _,v in a.shells do t.eq(v.head.Visible,false) end
			r:destroy();t.eq(a.destroyed,true);t.eq(#a.shells,0);t.eq(next(a.state.seen),nil)
		end
	end)
	t.test('many damaged structures share the normal creation quota and bars stop allocating once warm',function()
		local e,s,r=setup()
		local updates={}
		for id=500,599 do
			local u={id=id,type='City',owner=2,tile=64*(28+math.floor((id-500)/10))+28+(id-500)%10,
				active=true,level=1,health=700,maxHealth=1000}
			s.units[id]=u;table.insert(updates,u)
		end
		s.UnitsChanged:Fire(updates,{})
		local function bars():number
			local n=0;for id=500,599 do local v=r.scene.unitViews[id];if v and v.health then n+=1 end end;return n
		end
		for _=1,20 do local before=bars();r:step(1e9,1e9);t.ok(bars()-before<=25,'bar creation shares existing view allowance') end
		t.eq(bars(),100)
		local objects=#e.objects
		for _=1,5 do r:step(1e9,1e9) end;t.eq(#e.objects,objects)
		for _,u in updates do u.health=nil;u.maxHealth=nil end;s.UnitsChanged:Fire(updates,{})
		r:step(1e9,1e9)
		for id=500,599 do t.eq(r.scene.unitViews[id].health.background.Visible,false) end
		r:destroy()
	end)
end
