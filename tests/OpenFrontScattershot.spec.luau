--!strict
-- Synthetic confirmed plans and native-property shims, not server targeting,
-- native rendering cost or proof of published/device appearance.
return function(t)
	local fs,luau,serde,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/serde'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))();local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local shared=H.shared()
	local Nuke=H.require(shared.OpenFront.Executions.NukeExecution)
	local Visual,Trails,Fx,Status=H.require(root.UnitVisuals),H.require(root.TrailManager),H.require(root.FxState),H.require(root.PlayerStatus)
	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function fixture():any return serde.decode('json',fs.readFile('tests/fixtures/OpenFrontScattershot.json')) end
	local function count(items:any):number local n=0;for _ in items do n+=1 end;return n end
	local function setup(split:boolean?):any
		local f,e=fixture(),native();e.policy.splitMapGuis=split==true;e.mapGui.DisplayOrder=0
		local s=e.client();s.startTick=0;s.gold=1e9;s.width,s.height=f.width,f.height;s.tileState=buffer.create(f.width*f.height*2)
		local terrain=buffer.create(f.width*f.height);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,f.width,f.height,{autoStep=false,coasts=false,guiHost=e.mapGui})
		r:attachState(s);for _=1,100 do r:step(1e9,1e9) end
		r:setCamera({width=f.width,height=f.height,viewportWidth=844,viewportHeight=390,left=0,top=0,offsetX=0,offsetY=0,scale=4})
		return e,s,r,f
	end
	t.test('carrier is an Atom-shaped smoothed missile with config blast radii and launch gates',function()
		local u=fixture().carrier;u.tile=4132
		local v=Visual.unit(u,128,4,.5)
		t.eq(v.column,3);t.eq(v.structure,false);t.ok(v.missile);t.ok(Visual.isNuke('Scattershot'));t.ok(Visual.isSmoothed('Scattershot'))
		t.near(v.x,34,1e-9);t.eq(v.y,32)
		t.eq(Visual.telegraph(u,128,9,10),nil,'no future-plan target ring')
		local config={nukeMagnitudes=function(_,kind) t.eq(kind,'Scattershot');return {inner=13,outer=31} end}
		local ring=Visual.telegraph(u,128,10,10,config);t.eq(ring.inner,13);t.eq(ring.outer,31)
		u.waitTicks=2;t.eq(Visual.unit(u,128,4,1),nil);t.eq(Visual.telegraph(u,128),nil)
		u.waitTicks=0;u.active=false;t.eq(Visual.unit(u,128,4,1),nil)
		t.eq(Visual.isNuke('Artillery Shell'),false)
	end)
	t.test('Scattershot carrier impact and interception exactly reuse Atom effects; warheads keep theirs',function()
		for _,reached in {false,true} do
			local atom,scatter=Fx.new(128),Fx.new(128)
			atom:deadUnit({type='Atom Bomb',tile=8256,reachedTarget=reached},1000)
			scatter:deadUnit({type='Scattershot',tile=8256,reachedTarget=reached},1000)
			t.eq(serde.encode('json',scatter.sprites),serde.encode('json',atom.sprites))
			t.eq(serde.encode('json',scatter.shockwaves),serde.encode('json',atom.shockwaves))
		end
		local fx=Fx.new(128);local final={id=1,type='Scattershot',tile=8256,active=false,reachedTarget=true}
		fx:unitUpdates({final},{},1000);local total=#fx.sprites
		fx:unitUpdates({final},{},1010);t.eq(#fx.sprites,total)
		fx:unitUpdates({{id=2,type='MIRV Warhead',tile=8292,active=false,reachedTarget=true}},{},1010)
		t.ok(#fx.sprites>total);t.eq(#fx.shockwaves,2)
	end)
	t.test('seven silo-launched trails share source claims and clear without a fake midair split',function()
		local f=fixture();local trails=Trails.new(f.width,f.height)
		local units,order={[100]=f.carrier},{100}
		for _,w in f.warheads do units[w.id]={id=w.id,type='MIRV Warhead',owner=1,tile=f.source,lastTile=f.source,targetTile=w.targetTile};table.insert(order,w.id) end
		trails:update(units,order);t.eq(trails.counts[f.source],7);t.eq(count(trails.values),1)
		for _,u in units do u.lastTile=u.tile;u.tile+=2 end
		trails:update(units,order,{})
		t.eq(trails.counts[f.source],7);t.eq(trails.values[f.source+2],4097)
		for _,id in order do t.ok(trails.units[id]);t.ok(trails.units[id].tiles[f.source]) end
		trails:update({},{});t.eq(next(trails.values),nil);t.eq(next(trails.counts),nil)
	end)
	t.test('draft and validated Scattershot previews show source-derived annulus, SAMs and arc with pooled cleanup',function()
		for _,split in {false,true} do
			local e,s,r,f=setup(split)
			s.units[10]={id=10,type='Missile Silo',owner=1,tile=f.source,level=1,active=true}
			s.units[11]={id=11,type='SAM Launcher',owner=2,tile=f.aim,level=1,active=true}
			s.UnitsChanged:Fire({s.units[10],s.units[11]},{})
			local p=e.Preview.new(r,s,function() return nil end);p:setChosen('Scattershot');p:draw(f.aim,64,64,false)
			t.eq(r.scene.buildPreview.spreadInnerRadius,Nuke.SCATTER_NEAR);t.eq(r.scene.buildPreview.spreadOuterRadius,Nuke.SCATTER_FAR)
			p.reply={tile=f.aim,unit='Scattershot',tick=0,rangeWarning=false,
				buildable={type='Scattershot',canBuild=f.aim,canUpgrade=false,cost=3750000,ghostRailPaths={},overlappingRailroads={}},
				nukeAim={siloTile=f.source,sams={{x=64,y=64,r=20}}}}
			p:draw(f.aim,64,64,false)
			for _=1,8 do r:step(1e9,1e9) end
			local g=r.scene.buildPreview;local magnitudes=s:config():nukeMagnitudes('Scattershot')
			t.eq(g.rangeRadius,magnitudes.outer);t.eq(g.innerRangeRadius,magnitudes.inner);t.ok(r.scene.preview)
			t.ok(r.scene.rangeViews.BuildRange.Visible);t.ok(r.scene.rangeViews.BuildInnerRange.Visible);t.ok(r.scene.samVisible)
			local spread=r.scene.spreadRings;t.eq(#spread,3);t.eq(spread[1].frame.BackgroundTransparency,1)
			t.eq(spread[1].stroke.BorderStrokePosition,rb.Enum.BorderStrokePosition.Center)
			t.near(spread[1].frame.Size.X.Offset,(Nuke.SCATTER_NEAR+Nuke.SCATTER_FAR)*r.camera.scale,1)
			t.near(spread[1].stroke.Thickness,(Nuke.SCATTER_FAR-Nuke.SCATTER_NEAR)*r.camera.scale,1e-8)
			local objects=#e.objects;e.recordUploads=true
			for _=1,5 do
				e.uploads={};r:step(1e9,1e9)
				local images={};for _,image in e.uploads do images[image]=true end;t.ok(count(images)<=1)
			end
			t.eq(#e.objects,objects)
			p:setChosen('Atom Bomb');p:draw(f.aim,64,64,false);r:step(1e9,1e9);t.eq(r.scene.spreadRoot.Visible,false)
			p:setChosen(nil);r:step(1e9,1e9);t.eq(r.scene.rangeViews.BuildRange.Visible,false)
			p:destroy();local overlay=r.scene.spreadRoot;r:destroy();t.ok(overlay.destroyed)
		end
	end)
	t.test('confirmed motion plans release all six warheads at the silo and retain sprites, trails and target status',function()
		local e,s,r,f=setup();s.units[100]=f.carrier
		local updates={f.carrier};local plans={{kind='grid',unitId=100,planId=1,startTick=0,ticksPerStep=1,path={f.source,f.source+2,f.aim}}}
		for _,w in f.warheads do
			local u={id=w.id,type='MIRV Warhead',owner=1,tile=f.source,lastTile=f.source,targetTile=w.targetTile,active=true,waitTicks=w.delay}
			s.units[w.id]=u;table.insert(updates,u)
			table.insert(plans,{kind='grid',unitId=w.id,planId=1,startTick=w.delay,ticksPerStep=1,path={f.source,f.source+1,w.targetTile}})
		end
		s.plans:applyRecords(plans);s.UnitsChanged:Fire(updates,{})
		r:step(1e9,1e9);t.ok(r.scene.unitViews[100]);t.eq(r.scene.unitViews[101],nil)
		s.tick=1;s.TickApplied:Fire(1);r:step(1e9,1e9)
		local carrier=r.scene.unitViews[100];t.ok(carrier.iconSlot.colors[1].B>carrier.iconSlot.colors[1].R,'violet carrier distinct from hot Atom palette')
		for tick=2,14 do
			s.tick=tick
			for _,w in f.warheads do local u=s.units[w.id];u.waitTicks=math.max(0,w.delay-tick);if tick==w.delay then t.eq(u.tile,f.source) end end
			local moved=s:_advancePlans();s.UnitsMoved:Fire(moved);s.UnitsChanged:Fire(updates,{});s.TickApplied:Fire(tick)
			r:step(1e9,1e9)
		end
		for _,u in updates do t.eq(u.tile,u.targetTile);t.ok(r.scene.unitViews[u.id].root.Visible);t.ok(r.scene.trails.units[u.id]) end
		t.eq(#r.scene.nukeIds,7)
		local states=buffer.create(128*128*2);buffer.writeu16(states,f.aim*2,2)
		local roster={{smallID=1,alive=true,tiles=1},{smallID=2,alive=true,tiles=2}}
		local result=Status.new():compute(roster,{[100]=f.carrier},states,2,{},0,nil)
		t.ok(result[1].nukeActive);t.ok(result[1].nukeTargetsMe)
		r:destroy()
	end)
end
