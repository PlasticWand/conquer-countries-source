--!strict
-- Original Sabotage / Field Works presentation contract and native-property proxy.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))();local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local State,Visual,Atlas=H.require(root.ArtilleryState),H.require(root.UnitVisuals),H.require(root.SpriteAtlas)
	local Camera=H.require(root.CameraTransform)
	local Field=t.require('OpenFront.Executions.FieldWorksExecution')
	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function building():any return {id=1,type='SAM Launcher',owner=2,tile=2080,active=true,level=1} end
	local function works():any return {id=3,type='Field Works',owner=1,tile=2085,active=true,underConstruction=true,expiresAt=610} end
	local function setup(split:boolean?):any
		local e=native();e.policy.splitMapGuis=split==true;e.mapGui.DisplayOrder=0
		local s=e.client();s.startTick=0;s.gold=1e9;s.units={[1]=building()}
		local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,guiHost=e.mapGui,coasts=false})
		r:attachState(s);for _=1,100 do r:step(1e9,1e9) end
		r:setCamera({width=64,height=64,viewportWidth=844,viewportHeight=390,left=17,top=23,offsetX=0,offsetY=0,scale=4})
		return e,s,r
	end
	local function reply(kind:string,canBuild:any):any
		return {tile=2200,unit=kind,tick=0,rangeWarning=false,
			buildable={type=kind,canBuild=canBuild,canUpgrade=false,cost=100000,ghostRailPaths={},overlappingRailroads={}}}
	end
	local function screen(r:any,x:number,y:number):any
		local sx,sy=Camera.worldToScreenCoordinates(r.camera,x,y)
		return rb.UDim2.fromOffset(sx-r.camera.left,sy-r.camera.top)
	end
	t.test('sandbag masks fit spare cells and expiresAt drives both build and lifetime progress',function()
		local col,structure=Visual.sprite(works());t.eq(col,10);t.ok(structure)
		local x,y,w,h=Atlas.iconRect(col);t.eq(x,480);t.eq(y,0);t.eq(w,32);t.eq(h,32)
		local pixels=Atlas.rgba();t.eq(buffer.len(pixels),512*192*4)
		local count=0;for yy=0,31 do for xx=480,511 do if buffer.readu8(pixels,(yy*512+xx)*4+3)>0 then count+=1 end end end
		t.ok(count>150 and count<650);t.eq(Atlas.shapeRect(col),448)
		local u=works();t.eq(Visual.fieldProgress(u,5,Field.BUILD,Field.LIFETIME),.5)
		u.underConstruction=false;t.eq(Visual.fieldProgress(u,10,Field.BUILD,Field.LIFETIME),1)
		t.eq(Visual.fieldProgress(u,310,Field.BUILD,Field.LIFETIME),.5)
		t.eq(Visual.fieldProgress(u,999,Field.BUILD,Field.LIFETIME),0)
		u.expiresAt=nil;t.eq(Visual.fieldProgress(u,20,Field.BUILD,Field.LIFETIME),nil)
	end)
	t.test('Sabotage targets the validated building including tile zero and clears stale target highlights',function()
		for _,split in {false,true} do
			local e,s,r=setup(split)
			local controller=e.Preview.new(r,s,function() return nil end,{snapToPlacement=true})
			controller:setChosen('Sabotage');controller.reply=reply('Sabotage',2080);controller.reply.sabotageAim={targetTile=2080,reach=60,readyAt=0}
			controller:draw(2200,24,34,false);r:step(1e9,1e9)
			t.eq(r.scene.buildPreview.sabotageTargetTile,2080);t.ok(not r.scene.buildPreview.snapToPlacement)
			local marker=r.scene.sabotageTarget;t.ok(marker.Visible)
			t.eq(marker.Position,screen(r,32.5,32.5));t.eq(marker.BackgroundColor3,rb.Color3.fromRGB(255,211,64))
			controller.reply=reply('Sabotage',0);controller.reply.sabotageAim={targetTile=0,reach=60,readyAt=0}
			controller:draw(2200,24,34,false);r:step(1e9,1e9)
			t.eq(marker.Position,screen(r,.5,.5));t.eq(marker.BackgroundColor3,rb.Color3.fromRGB(255,211,64))
			controller.reply=reply('Sabotage',false);controller.reply.sabotageAim={reach=60,readyAt=0}
			controller:draw(2200,24,34,false);r:step(1e9,1e9)
			t.eq(marker.Position,screen(r,24.5,34.5));t.eq(marker.BackgroundColor3,rb.Color3.fromRGB(255,75,69))
			controller:setChosen(nil);r:step(1e9,1e9);t.eq(marker.Visible,false)
			controller:destroy();r:destroy();t.ok(marker.destroyed)
		end
	end)
	t.test('Field Works stays on the tapped tile even with snapping enabled and invalid rings are red',function()
		local e,s,r=setup();local p=e.Preview.new(r,s,function() return nil end,{snapToPlacement=true})
		p:setChosen('Field Works');p:draw(2200,24,34,false);r:step(1e9,1e9)
		t.eq(r.scene.buildPreview.rangeRadius,Field.RADIUS)
		p.reply=reply('Field Works',2085);p.reply.fieldWorksAim={radius=19,readyAt=0}
		p:draw(2200,24,34,false);for _=1,3 do r:step(1e9,1e9) end
		local g=r.scene.buildPreview;t.ok(not g.snapToPlacement);t.eq(g.tileX,24);t.eq(g.radiusTileX,24);t.eq(g.rangeRadius,19)
		t.ok(r.scene.ghostViews[1].root.Visible);t.eq(r.scene.rangeViews.BuildRange.BackgroundColor3,rb.Color3.fromRGB(255,211,64))
		p.reply=reply('Field Works',false);p.reply.fieldWorksAim={radius=19,readyAt=0};p:draw(2200,24,34,false);r:step(1e9,1e9)
		t.eq(r.scene.rangeViews.BuildRange.BackgroundColor3,rb.Color3.fromRGB(255,75,69))
		p:destroy();r:destroy()
	end)
	t.test('only a confirmed dark transition switches off; fuse finals and snapshot seeds cannot invent success',function()
		local b,state=building(),State.new(64);local visible=function() return true end
		state:seed({[1]=b})
		local fuse={id=2,type='Sabotage',owner=1,tile=b.tile,targetTile=b.tile,targetUnitId=1,active=true}
		state:updates({fuse},{},visible,1,4);t.eq(#state.marks,0)
		fuse.active=false;fuse.reachedTarget=true;state:updates({fuse},{2},visible,2,4);t.eq(#state.marks,0,'fizzle is not a success')
		b.dark=true;state:updates({b},{},visible,3,4);t.eq(#state.marks,1);t.eq(state.marks[1].kind,'switchOff')
		state:updates({b},{},visible,3.01,4);t.eq(#state.marks,1,'mutated records are copied')
		state:seed({[1]=b});state:updates({b},{},visible,4,4);t.eq(#state.marks,0)
		b.dark=false;state:updates({b},{},visible,5,4);t.eq(#state.marks,0)
		b.dark=true;state:updates({b},{},function() return false end,6,4);t.eq(#state.marks,0)
	end)
	t.test('Field Works fades once on final or removal, with snapshot and offscreen suppression',function()
		local u,state=works(),State.new(64);local visible=function() return true end
		state:seed({[3]=u});u.active=false;state:updates({u},{3},visible,1,4)
		t.eq(#state.marks,1);t.eq(state.marks[1].kind,'fieldFade')
		u.active=true;state:seed({[3]=u});state:updates({},{3},visible,2,4);t.eq(#state.marks,1)
		state:seed({[3]=u});state:updates({},{3},function() return false end,3,4);t.eq(#state.marks,0)
		u.active=false;state:seed({[3]=u});state:updates({},{3},visible,4,4);t.eq(#state.marks,0)
	end)
	t.test('dark styles pulse without new style uploads and restore owner colour on clear',function()
		local e,s,r=setup();r.core.palette[2]={fill={r=.2,g=.7,b=.3},border={r=.1,g=.4,b=.15}}
		r.scene.unitCameraDirty=true
		s.UnitsChanged:Fire({s.units[1]},{});for _=1,10 do r:step(1e9,1e9) end
		local view=r.scene.unitViews[1];local normal=view.iconStyle
		s.units[1].dark=true;s.UnitsChanged:Fire({s.units[1]},{});for _=1,10 do r:step(1e9,1e9) end
		local dark=view.iconStyle;t.ok(dark~=normal);t.eq(r.scene.artillery.state.marks[1].kind,'switchOff')
		t.near(view.iconSlot.fill.R,view.iconSlot.fill.G,1e-6);t.near(view.iconSlot.fill.G,view.iconSlot.fill.B,1e-6)
		e.recordUploads=true;e.uploads={};e.now=.3;r:step(1e9,1e9);local alpha=view.parts[1].ImageTransparency
		e.now=1.5;r:step(1e9,1e9);t.ok(view.parts[1].ImageTransparency~=alpha)
		for i=1,30 do e.now+=.1;s.TickApplied:Fire(i);r:step(1e9,1e9);t.ok(view.parts[1].ImageTransparency<.25) end
		t.eq(view.iconStyle,dark);t.eq(#e.uploads,0,'pulse performs GUI writes only')
		s.units[1].dark=false;s.UnitsChanged:Fire({s.units[1]},{});for _=1,4 do r:step(1e9,1e9) end
		t.eq(view.iconStyle,normal);t.eq(view.parts[1].ImageTransparency,0);r:destroy()
	end)
	t.test('digging, lifetime bar, public fuse and gentle fade share teardown and one-image scheduling',function()
		local e,s,r=setup();local u=works();s.units[3]=u;s.UnitsChanged:Fire({u},{});r:step(1e9,1e9)
		local view=r.scene.unitViews[3];local dig=r.scene.artillery.shells[1];t.eq(dig.id,3);t.ok(dig.head.Visible);t.ok(view.progress)
		e.now=.2;r:step(1e9,1e9);local pos=dig.head.Position;e.now=.4;r:step(1e9,1e9);t.ok(dig.head.Position~=pos)
		u.underConstruction=false;s.UnitsChanged:Fire({u},{});s.TickApplied:Fire(310);r:step(1e9,1e9)
		t.eq(dig.head.Visible,false);local half=view.progress.fill.Size.X.Offset
		s.TickApplied:Fire(500);r:step(1e9,1e9);t.ok(view.progress.fill.Size.X.Offset<half)
		local fuse={id=2,type='Sabotage',owner=2,tile=2080,targetUnitId=1,targetTile=2080,active=true}
		s.units[2]=fuse;s.UnitsChanged:Fire({fuse},{});r:step(1e9,1e9)
		local a=r.scene.artillery;t.eq(r.scene.unitViews[2],nil);t.eq(#a.shells,1);t.ok(a.shells[1].head.Visible);t.eq(a.shells[1].plane.Visible,false)
		local old=a.shells[1].tail.Position;a:step(.45,1);t.ok(a.shells[1].tail.Position~=old)
		e.recordUploads=true
		for i=1,4 do e.uploads={};r:step(1e9,1e9);local distinct={};for _,img in e.uploads do distinct[img]=true end
			local n=0;for _ in distinct do n+=1 end;t.ok(n<=1) end
		u.active=false;s.UnitsChanged:Fire({u},{});r:step(1e9,1e9)
		local last=a.state.marks[#a.state.marks];t.eq(last.kind,'fieldFade');a:step(last.start+.1,1)
		t.ok(a.marks[#a.state.marks].earth.Visible);t.eq(#r.scene.effects.state.sprites,0,'no structure explosion')
		s.Snapshot:Fire();t.eq(#a.state.marks,0)
		s.winner=1;s.PhaseChanged:Fire();t.ok(a.stopped);r:destroy();t.ok(a.destroyed);t.eq(next(a.state.seen),nil)
	end)
	t.test('many public fuses, digging works and switch-off bursts share existing shot and accent caps',function()
		local e,s,r=setup();local updates={}
		for id=10,100 do
			local u={id=id,type=if id%2==0 then 'Sabotage' else 'Field Works',owner=2,tile=2080,targetUnitId=1,active=true,
				underConstruction=id%2==1,expiresAt=610}
			s.units[id]=u;table.insert(updates,u)
		end
		s.UnitsChanged:Fire(updates,{});local a=r.scene.artillery
		for _=1,10 do r:step(1e9,1e9) end;t.eq(#a.shells,State.shellCap)
		local state=State.new(1000);local buildings={}
		for id=1,60 do buildings[id]={id=id,type='City',owner=2,tile=id*20,active=true} end
		state:seed(buildings);updates={}
		for _,b in buildings do b.dark=true;table.insert(updates,b) end
		state:updates(updates,{},function() return true end,1,20);t.eq(#state.marks,State.markCap)
		state:seed({});t.eq(#state.marks,0);r:destroy()
	end)
end
