--!strict
-- Real framebuffer comparisons and native-property/lifecycle shim; no GPU/FPS claim.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Core,Policy=H.require(root.RasterCore),H.require(root.RenderPolicy)
	local sinkHarness=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
	local function setup(w,h,deferred)
		local sink=sinkHarness.sink(w,h)
		local terrain=buffer.create(w*h);buffer.fill(terrain,0,128)
		local previous=Policy.deferredOwnership;Policy.deferredOwnership=deferred
		local core=Core.new(terrain,w,h,sink.backend);Policy.deferredOwnership=previous
		Core.setRoster(core,{{id='one',smallID=1,playerType='HUMAN'},
			{id='two',smallID=2,playerType='HUMAN'},{id='three',smallID=3,playerType='NATION'}})
		Core.setLocalPlayer(core,1)
		return core,sink
	end
	local function drain(core)
		local frames=0
		while Core.hasPending(core) do frames+=1;assert(frames<10000);Core.step(core,1e9,1e9) end
	end
	local function equal(a,b)
		for i,page in a.pages do t.eq(buffer.tostring(page.pixels),buffer.tostring(b.pages[i].pixels),'complete framebuffer page '..i) end
	end
	t.test('deferred and immediate dirty work equal fresh repaints through flags, hover, diplomacy, repeats and page edges',function()
		local w,h=1030,37
		local a=setup(w,h,false);local b=setup(w,h,true)
		local states=buffer.create(w*h*2)
		for tile=0,w*h-1 do buffer.writeu16(states,tile*2,1+tile%3) end
		Core.applyTileStates(a,states);Core.applyTileStates(b,states);drain(a);drain(b)
		local seed=51
		local function rand(n) seed=(seed*48271)%2147483647;return seed%n end
		for round=1,14 do
			local refs={0,w-1,w,1023,1024,w*h-1}
			for _=1,150 do table.insert(refs,rand(w*h)) end
			for _,tile in refs do buffer.writeu16(states,tile*2,rand(4)+(if rand(3)==0 then 8192 else 0)+(if rand(2)==0 then 16384 else 0)) end
			Core.applyTileStates(a,states,refs);Core.applyTileStates(b,states,refs)
			t.eq(buffer.tostring(b.tileState),buffer.tostring(states),'confirmed state waited for cosmetics')
			-- Read/paint some unrelated work between successive edits of a queued tile.
			Core.step(a,.01,4);Core.step(b,.01,4)
			for _,owner in {1,2,1} do
				buffer.writeu16(states,1024*2,owner+8192)
				Core.applyTileStates(a,states,{1024});Core.applyTileStates(b,states,{1024})
			end
			local matrix=buffer.create(16);buffer.writeu8(matrix,1*4+2,round%3);buffer.writeu8(matrix,2*4+1,round%3)
			for _,core in {a,b} do
				Core.setRelations(core,{size=4,data=matrix});Core.setHover(core,round%4)
				Core.applyTrails(core,{[1023]=4097,[1024]=2},{1023,1024})
				Core.setSpawnDiscs(core,if round%2==0 then {{x=1,y=1,owner=1}} else {})
			end
			drain(a);drain(b);equal(a,b)
			local fresh=setup(w,h,false)
			Core.applyTileStates(fresh,states);Core.setRelations(fresh,{size=4,data=matrix});Core.setHover(fresh,round%4)
			Core.applyTrails(fresh,{[1023]=4097,[1024]=2},{1023,1024})
			Core.setSpawnDiscs(fresh,if round%2==0 then {{x=1,y=1,owner=1}} else {})
			drain(fresh);equal(b,fresh);Core.destroy(fresh)
		end
		Core.destroy(a);Core.destroy(b)
	end)
	t.test('immediate horizontal halo unions equal separate sparse marks and collect confirmed transitions once',function()
		for _,soft in {false,true} do
			local w,h=1030,40;local a=setup(w,h,false);local b=setup(w,h,false)
			Core.setEdgeSmoothing(a,soft);Core.setEdgeSmoothing(b,soft)
			local states=buffer.create(w*h*2);buffer.fill(states,0,0)
			for _,core in {a,b} do Core.applyTileStates(core,states);drain(core) end
			local refs={0,2,5,9,31,33,64,100,1023,1025,1029,1030,1032,1035,1039,1200,1199,1200}
			local changes={own={},fallout={}}
			for i,tile in refs do buffer.writeu16(states,tile*2,if i%3==0 then 8193 else 1) end
			Core.applyTileStates(a,states,refs,changes)
			for _,tile in refs do Core.applyTileStates(b,states,{tile}) end
			t.eq(buffer.tostring(a.dirtyRows),buffer.tostring(b.dirtyRows),'horizontal unions never shade clean gaps')
			t.eq(buffer.tostring(a.ownDirtyRows),buffer.tostring(b.ownDirtyRows),'own priority halo unchanged')
			t.eq(buffer.tostring(a.borderFlags),buffer.tostring(b.borderFlags))
			local seen={};for _,tile in changes.own do t.ok(not seen[tile]);seen[tile]=true;t.eq(bit32.band(buffer.readu16(states,tile*2),4095),1) end
			t.eq(#changes.own,#refs-1,'duplicate refs collect only actual transitions')
			for _,tile in changes.fallout do t.eq(bit32.band(buffer.readu16(states,tile*2),8192),8192) end
			local unchanged={own={},fallout={}};Core.applyTileStates(a,states,refs,unchanged);t.eq(#unchanged.own,0);t.eq(#unchanged.fallout,0)
			drain(a);drain(b);equal(a,b);Core.destroy(a);Core.destroy(b)
		end
	end)
	t.test('neutral expansion refreshes cached foreign-border rows before a later diplomacy recolour',function()
		local a=setup(64,64,false);local b=setup(64,64,true)
		local states=buffer.create(8192)
		for tile=0,4095 do if tile%64<32 then buffer.writeu16(states,tile*2,3) end end
		local matrix=buffer.create(16)
		for _,core in {a,b} do Core.applyTileStates(core,states);Core.setRelations(core,{size=4,data=matrix});drain(core) end
		local tile=20*64+32;buffer.writeu16(states,tile*2,2)
		for _,core in {a,b} do Core.applyTileStates(core,states,{tile});drain(core) end
		buffer.writeu8(matrix,3*4+2,1);buffer.writeu8(matrix,2*4+3,1)
		for _,core in {a,b} do Core.setRelations(core,{size=4,data=matrix});drain(core) end
		equal(a,b);Core.destroy(a);Core.destroy(b)
	end)
	t.test('narrow expansion shades five ownership pixels or one defence pixel, not an unconditional nine',function()
		local a=setup(64,64,false);local b=setup(64,64,true)
		local states=buffer.create(8192);for tile=0,4095 do buffer.writeu16(states,tile*2,1) end
		for _,core in {a,b} do Core.applyTileStates(core,states);drain(core) end
		local tile=20*64+20;buffer.writeu16(states,tile*2,2)
		local beforeA,beforeB=a.shadedPixels,b.shadedPixels
		Core.applyTileStates(a,states,{tile});Core.applyTileStates(b,states,{tile})
		t.eq(b.pending,0);t.eq(b.deferred.count,1)
		drain(a);drain(b);equal(a,b)
		t.eq(a.shadedPixels-beforeA,9);t.eq(b.shadedPixels-beforeB,5)
		buffer.writeu16(states,tile*2,2+16384);beforeB=b.shadedPixels
		Core.applyTileStates(b,states,{tile});drain(b);t.eq(b.shadedPixels-beforeB,1)
		Core.destroy(a);Core.destroy(b)
	end)
	t.test('deferred work is bounded, owns priority, preserves queued age, caps overflow and clears on snapshot/destroy',function()
		local b=setup(64,64,true);local states=buffer.create(8192);drain(b)
		local refs={};for index=0,99 do local tile=index*20;buffer.writeu16(states,tile*2,2);table.insert(refs,tile) end
		Core.applyTileStates(b,states,refs)
		buffer.writeu16(states,3000*2,1);Core.applyTileStates(b,states,{3000})
		b.frames=5;Core.flushInvalidations(b,1e9,2)
		t.eq(b.deferred.items[3000],nil,'own row was stuck behind foreign expansion')
		t.ok(b.deferred.count>=99);t.ok(buffer.readu8(b.ownQueued,math.floor(3000/64/32)*b.columns+math.floor(3000%64/32))>0)
		local m=Core.metrics(b);t.ok(m.invalidationAgeFrames>=4)
		b.deferred.cap=1
		buffer.writeu16(states,4000*2,2);Core.applyTileStates(b,states,{4000})
		t.ok(b.deferred.fallbacks>0,'overflow did not fall back')
		Core.applyTileStates(b,states);t.eq(b.deferred.count,0);drain(b)
		buffer.writeu16(states,1000*2,2);Core.applyTileStates(b,states,{1000})
		local queue=b.deferred;Core.destroy(b);t.eq(queue.count,0);t.eq(next(queue.items),nil)
	end)
	t.test('bulk deferred captures retain copied references and survive repeat edits, partial steps and snapshots',function()
		local b=setup(1030,9,true);local states=buffer.create(1030*9*2)
		for tile=0,1030*9-1 do buffer.writeu16(states,tile*2,1) end
		Core.applyTileStates(b,states);drain(b)
		local refs={};for tile=0,5999 do buffer.writeu16(states,tile*2,2);table.insert(refs,tile) end
		Core.applyTileStates(b,states,refs);t.ok(b.deferred.batchBytes>0)
		Core.step(b,.1,8)
		for _,tile in refs do buffer.writeu16(states,tile*2,3+16384) end
		Core.applyTileStates(b,states,refs);table.clear(refs);drain(b)
		local fresh=setup(1030,9,false);Core.applyTileStates(fresh,states);drain(fresh);equal(b,fresh)
		t.eq(b.deferred.batchBytes,0)
		local changed={};for tile=0,5999 do buffer.writeu16(states,tile*2,1);table.insert(changed,tile) end
		Core.applyTileStates(b,states,changed);t.ok(b.deferred.count>0)
		Core.applyTileStates(b,states);t.eq(b.deferred.count,0);t.eq(b.deferred.batchBytes,0)
		drain(b);Core.destroy(b);Core.destroy(fresh)
	end)
	t.test('World rails created while zoomed out return through the 3-5 fade in every SPEED mode',function()
		local make=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
		for _,mode in {'off','split','deferred','both'} do
			local e=make();e.uis.TouchEnabled=true
			e.policy.splitMapGuis=mode=='split' or mode=='both'
			e.policy.deferredOwnership=mode=='deferred' or mode=='both'
			t.eq(e.policy.sourceRailFade,false)
			local s=e.client();s.width,s.height,s.startTick,s.tick=2000,1000,0,100;s.names={}
			s.tileState=buffer.create(2000*1000*2)
			local path={};for x=1020,1060 do local tile=500*2000+x;table.insert(path,tile);buffer.writeu16(s.tileState,tile*2,1) end
			s.units[1]={id=1,type='Factory',owner=1,tile=path[1],active=true,level=1}
			s.units[2]={id=2,type='City',owner=1,tile=path[#path],active=true,level=1,hasTrainStation=true}
			s.units[3]={id=3,type='Train',owner=1,tile=path[20],active=true,trainType='Engine'}
			local terrain=buffer.create(2000*1000);buffer.fill(terrain,0,128)
			local host=e.instance('ScreenGui');host.DisplayOrder=0;host.Parent=e.playerGui
			local parent=e.instance('Frame');parent.Parent=host
			local r=e.Renderer.new(parent,terrain,2000,1000,{autoStep=false,firstPaint='full',coasts=false,guiHost=host})
			r:applyTileStates(s.tileState);r:attachState(s)
			for _=1,1000 do e.now+=1/60;r:step(1e9,1e9);if r:isReady() then break end end
			t.ok(r:isReady())
			local function camera(zoom)
				local c=table.clone(r.camera);c.scale=zoom
				c.offsetX=1040-1000-(c.viewportWidth/2-1000)/zoom
				c.offsetY=-(c.viewportHeight/2-500)/zoom;r:setCamera(c)
				for _=1,30 do e.now+=1/60;r:step(1e9,1e9) end
			end
			camera(2)
			s:_applyEvents({{type='RailroadConstructionEvent',id=7,tiles=path}})
			camera(2);t.eq(r.scene.visibleRails,0);t.eq(r.scene.layers.Rails.Visible,false)
			for _,zoom in {4,7,15,2,7} do
				camera(zoom)
				local visible=zoom>3
				t.eq(r.scene.visibleRails,if visible then #path else 0,mode..' at zoom '..zoom)
				t.eq(r.scene.layers.Rails.Visible,visible)
				if not visible then continue end
				t.eq(r.scene.layers.Rails.Parent,r.root)
				for index,f in r.scene.railLines do if index<=#path then
					t.eq(f.Visible,true);t.eq(f.ImageContent,r.scene.content)
					t.near(f.ImageTransparency,1-math.clamp((zoom-3)/2,0,1),1e-6)
					t.eq(f.Size,rb.UDim2.fromOffset(64,64))
					t.eq(f.Position,rb.UDim2.fromOffset((1020+index-1)*64,500*64))
					t.eq(f.ImageRectSize,rb.Vector2.new(if zoom>=6 then 3 else 2,if zoom>=6 then 3 else 2))
				end end
			end
			s:_applyEvents({{type='RailroadDestructionEvent',id=7}});camera(7)
			t.eq(r.scene.visibleRails,0)
			for _,f in r.scene.railLines do t.eq(f.Visible,false) end
			r:destroy()
		end
	end)
	t.test('split map surfaces retain coordinates, ready cover, input filtering and ordered passes across resize/cleanup',function()
		local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
		source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then','node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
		local e=luau.load(source)()();e.policy.splitMapGuis=true
		local host=e.instance('ScreenGui');host.DisplayOrder=0;host.Parent=e.playerGui
		local parent=e.instance('Frame');parent.Parent=host;parent.AbsolutePosition=rb.Vector2.new(17,42)
		local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(parent,terrain,64,64,{autoStep=false,firstPaint='full',guiHost=host,coasts=false})
		local s=e.client();s.startTick=0;s.names={[1]={x=20,y=20,size=20}}
		s.units[1]={id=1,type='City',owner=1,tile=1300,active=true,level=1,underConstruction=true,constructionStartTick=0}
		r:attachState(s)
		local guis=table.clone(r.guiLayers.guis);t.eq(#guis,6)
		for _,root in r.guiLayers.roots do t.eq(root.Visible,false) end
		for _=1,500 do e.now+=.02;r:step();if r:isReady() then break end end
		t.ok(r:isReady())
		for i,gui in guis do
			t.eq(gui.DisplayOrder,i);t.eq(gui.ScreenInsets,rb.Enum.ScreenInsets.None);t.eq(gui.ClipToDeviceSafeArea,false)
		end
		for _,root in r.guiLayers.roots do t.eq(root.Visible,true);t.eq(root.Position,rb.UDim2.fromOffset(17,42)) end
		t.eq(r.scene.layers.Ground.Parent,r.guiLayers.roots.Ground)
		t.eq(r.scene.layers.Structures.Parent,r.guiLayers.roots.Structures)
		t.eq(r.scene.layers.Missiles.Parent,r.guiLayers.roots.Moving)
		t.eq(r.scene.layers.Names.Parent,r.guiLayers.roots.Labels)
		t.eq(r.scene.effects.spawn.Parent,r.root);t.eq(r.scene.effects.fx.Parent,r.guiLayers.roots.Effects)
		t.eq(r.scene.effects.text.Parent,r.guiLayers.roots.Text)
		local v=r.scene.unitViews[1];t.ok(v.progressRoot and v.progress)
		t.eq(v.progress.background.Parent,v.progressRoot);t.eq(v.progressRoot.Position,v.root.Position)
		local x,y=r:worldToScreen(20.5,20.5);t.eq(r:screenToTile(x,y),20*64+20)
		r:bindInput(e.playerGui,host,function() end)
		local hit=e.instance('Frame');hit.Visible=true;hit.Active=true;hit.BackgroundTransparency=0;hit.Parent=r.guiLayers.roots.Labels
		hit.IsDescendantOf=function(_,ancestor) local p=hit.Parent;while p do if p==ancestor then return true end;p=p.Parent end;return false end
		e.playerGui.GetGuiObjectsAtPosition=function() return {hit} end
		t.eq(r.input.isBlocked(rb.Vector2.new(x,y)),false,'map label became a modal blocker')
		hit.Parent=e.instance('ScreenGui');t.eq(r.input.isBlocked(rb.Vector2.new(x,y)),true,'HUD modal did not block')
		local observed=false;r:onCameraChanged(function()
			observed=true
			for _,root in r.guiLayers.roots do t.eq(root.Size,rb.UDim2.fromOffset(1000,500)) end
		end)
		parent.AbsoluteSize=rb.Vector2.new(1000,500);parent.signals.AbsoluteSize:Fire();t.ok(observed)
		r:setTerritoryLabelsVisible(false);t.eq(r.scene.layers.Names.Visible,false)
		local proxy=v.progressRoot;s.units[1].active=false;s.UnitsChanged:Fire({},{});e.now+=.11;r:step();t.eq(proxy.Visible,false)
		r:destroy();for _,gui in guis do t.eq(gui.destroyed,true) end;t.eq(proxy.destroyed,true)
		e.policy.splitMapGuis=false
	end)
end
