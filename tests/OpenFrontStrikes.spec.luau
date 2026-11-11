--!strict
-- Public confirmed strike fixtures; excludes native layout/GPU and sim damage.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))();local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local shared=H.shared();local Strike=H.require(shared.OpenFront.Executions.StrikeExecution)
	local Launcher=H.require(shared.OpenFront.Executions.LauncherExecution)
	local State,Visual,Atlas=H.require(root.ArtilleryState),H.require(root.UnitVisuals),H.require(root.SpriteAtlas)
	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function count(items:any):number local n=0;for _ in items do n+=1 end;return n end
	local function setup(split:boolean?):any
		local e=native();e.policy.splitMapGuis=split==true;e.mapGui.DisplayOrder=0
		local s=e.client();s.startTick=0;s.gold=1e9
		s.units={[1]={id=1,type='Airfield',owner=1,tile=0,active=true,level=1},
			[2]={id=2,type='Railgun',owner=1,tile=2080,active=true,level=1},
			[3]={id=3,type='SAM Launcher',owner=2,tile=2200,active=true,level=1}}
		local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,guiHost=e.mapGui,coasts=false})
		r:attachState(s);for _=1,100 do r:step(1e9,1e9) end
		r:setCamera({width=64,height=64,viewportWidth=844,viewportHeight=390,left=0,top=0,offsetX=0,offsetY=0,scale=4})
		return e,s,r
	end
	local function reply(kind:string,source:number?):any
		local spec=Strike.SPEC[kind]
		return {tile=2080,unit=kind,tick=0,rangeWarning=source==nil,
			buildable={type=kind,canBuild=if source~=nil then source else false,canUpgrade=false,cost=0,ghostRailPaths={},overlappingRailroads={}},
			strikeAim={launcherTile=source,radius=spec.radius,reach=spec.reach}}
	end
	t.test('new structure masks, glyphs and bomber fit spare cells and share the existing atlas',function()
		local pixels=Atlas.rgba();t.eq(buffer.len(pixels),512*192*4)
		for _,kind in {'Airfield','Railgun'} do
			local col,structure=Visual.sprite({type=kind});t.ok(structure)
			local x,y,w,h=Atlas.iconRect(col);t.eq(w,32);t.eq(h,32)
			local n=0;for yy=y,y+h-1 do for xx=x,x+w-1 do if buffer.readu8(pixels,(yy*512+xx)*4+3)>0 then n+=1 end end end
			t.ok(n>30,'nonempty bold symbol');local sx,sy=Atlas.shapeRect(col);t.ok(buffer.readu8(pixels,((sy+16)*512+sx+16)*4+3)>0)
		end
		t.eq(Visual.sprite({type='Air Strike'}),12);t.eq(Visual.isNuke('Air Strike'),false)
		t.eq(buffer.readu8(pixels,(6*512+162)*4+3),255)
	end)
	t.test('all four reload bar kinds honor effective replicated reload ticks',function()
		for _,kind in {'Missile Silo','SAM Launcher','Airfield','Railgun'} do
			local u={type=kind,level=1,missileTimerQueue={100},reloadTicks=50}
			t.near(Visual.progress(u,125,100,300),.5,1e-9)
			t.eq(Visual.progress(u,150,100,300),nil)
			u.reloadTicks=nil;t.near(Visual.progress(u,125,100,300),.25,1e-9)
		end
	end)
	t.test('placement, selected launcher lines, own Airfield reach and red invalid aim use confirmed spec',function()
		for _,split in {false,true} do
			local e,s,r=setup(split);local p=e.Preview.new(r,s,function() return nil end)
			p:setChosen('Airfield');p:draw(2080,32,32,false);r:step(1e9,1e9)
			t.eq(r.scene.buildPreview.rangeRadius,Strike.SPEC['Air Strike'].reach);t.ok(r.scene.ghostViews[1].root.Visible)
			for _,kind in {'Air Strike','Railgun Shot'} do
				p:setChosen(kind);p.reply=reply(kind,0);p:draw(2080,32,32,false)
				for _=1,4 do r:step(1e9,1e9) end
				t.eq(r.scene.buildPreview.rangeRadius,Strike.SPEC[kind].radius);t.eq(r.scene.preview,nil,'non-interceptible shot has no SAM trajectory')
				t.eq(r.scene.samVisible,false);t.ok(r.scene.strikePreviewRoot.Visible);t.ok(r.scene.strikeAimLine.Size.X.Offset>0)
				if kind=='Air Strike' then t.ok(r.scene.rangeViews.AirfieldReach1.Visible) else t.eq(count(r.scene.strikeRangeKeys),0) end
				p.reply=reply(kind,nil);p:draw(2080,32,32,false);r:step(1e9,1e9)
				t.eq(r.scene.strikePreviewRoot.Visible,false);t.eq(r.scene.rangeViews.BuildRange.BackgroundColor3,rb.Color3.fromRGB(255,75,69))
			end
			p:setChosen(nil);r:step(1e9,1e9);t.eq(count(r.scene.strikeRangeKeys),0)
			local overlay=r.scene.strikePreviewRoot;p:destroy();r:destroy();t.ok(overlay.destroyed)
		end
	end)
	t.test('confirmed air impacts and instant rail finals merge, deduplicate and suppress snapshots',function()
		local state=State.new(64,Strike.SPEC)
		local plane={id=1,type='Air Strike',owner=2,tile=2080,sourceTile=0,targetTile=2080,active=true}
		state:seed({[1]=plane});state:updates({plane},{},function() return true end,0,4);t.eq(#state.marks,0)
		plane.active=false;plane.reachedTarget=true
		state:updates({plane},{},function() return true end,0,4);t.eq(state.marks[1].kind,'airImpact');t.eq(state.marks[1].radius,Strike.SPEC['Air Strike'].radius)
		state:updates({plane},{},function() return true end,.01,4);t.eq(#state.marks,1)
		state:seed({});local shot={id=2,type='Railgun Shot',owner=2,tile=2080,sourceTile=0,targetTile=2080,active=false,reachedTarget=true}
		state:updates({shot},{},function() return true end,1,4)
		t.eq(#state.marks,3);t.eq(state.marks[2].kind,'railBeam');t.eq(state.marks[2].source,0);t.eq(state.marks[3].kind,'railImpact')
		state:seed({[2]=shot});state:updates({shot},{},function() return true end,2,4);t.eq(#state.marks,0)
	end)
	t.test('cross-map beams clip even with both endpoints offscreen',function()
		local a,b,c,d=State.clipLine(-100,50,200,50,100,100)
		t.eq(a,0);t.eq(b,50);t.eq(c,100);t.eq(d,50)
		t.eq(State.clipLine(-100,-100,-20,-20,100,100),nil)
	end)
	t.test('plane and beam pools reuse GUI, final FX stay bounded and image-slot rules hold',function()
		local e,s,r=setup(true);local a=r.scene.artillery
		local plane={id=100,type='Air Strike',owner=2,tile=2085,lastTile=2080,targetTile=2100,sourceTile=0,active=true}
		s.units[100]=plane;s.UnitsChanged:Fire({plane},{});r:step(1e9,1e9);a:step(0,.5)
		t.eq(#a.shells,1);t.ok(a.shells[1].plane.Visible);t.eq(r.scene.unitViews[100],nil)
		local updates={};for id=101,180 do local u=table.clone(plane);u.id=id;s.units[id]=u;table.insert(updates,u) end
		s.UnitsChanged:Fire(updates,{});for _=1,12 do r:step(1e9,1e9) end;t.eq(#a.shells,State.shellCap)
		plane.active=false;plane.reachedTarget=true;s.UnitsChanged:Fire({plane},{});r:step(1e9,1e9)
		local efx=a.state.marks[#a.state.marks];t.eq(efx.kind,'airImpact');a:step(efx.start+.1,1)
		t.ok(a.marks[#a.state.marks].bars[1].Visible)
		e.recordUploads=true
		for _=1,5 do e.uploads={};r:step(1e9,1e9);local seen={};for _,image in e.uploads do seen[image]=true end;t.ok(count(seen)<=1) end
		s.Snapshot:Fire();t.eq(#a.state.marks,0);s.winner=1;s.PhaseChanged:Fire();t.eq(#a.ids,0)
		r:destroy();t.eq(#a.shells,0);t.eq(next(a.state.seen),nil)
	end)
	t.test('scene reload bars update when only effective reloadTicks changes',function()
		local _,s,r=setup();local u=s.units[1];u.missileTimerQueue={0};u.reloadTicks=300;s.tick=75
		s.UnitsChanged:Fire({u},{});s.TickApplied:Fire(75);r:step(1e9,1e9)
		local bar=r.scene.unitViews[1].progress;local before=bar.fill.Size.X.Offset
		u.reloadTicks=150;s.UnitsChanged:Fire({u},{});r:step(1e9,1e9);t.ok(bar.fill.Size.X.Offset>before)
		t.eq(Launcher.RELOAD.Airfield,300);r:destroy()
	end)
end
