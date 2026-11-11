--!strict
-- Confirmed Paratroopers presentation and bounded GUI lifecycle. These checks
-- do not establish native sampling, touch feel, GPU cost or sim balance.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))();local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local State,Visual,Atlas=H.require(root.ArtilleryState),H.require(root.UnitVisuals),H.require(root.SpriteAtlas)
	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function count(items:any):number local n=0;for _ in items do n+=1 end;return n end
	local function setup(split:boolean?):any
		local e=native();e.policy.splitMapGuis=split==true;e.mapGui.DisplayOrder=0
		local s=e.client();s.startTick=0;s.gold=1e9
		s.units={[1]={id=1,type='City',owner=1,tile=0,active=true,level=1},
			[2]={id=2,type='SAM Launcher',owner=2,tile=2080,active=true,level=1}}
		local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,guiHost=e.mapGui,coasts=false})
		r:attachState(s);for _=1,100 do r:step(1e9,1e9) end
		r.core.palette[2]={fill={r=.2,g=.6,b=.8},border={r=.1,g=.3,b=.4}}
		r:setCamera({width=64,height=64,viewportWidth=844,viewportHeight=390,left=17,top=23,offsetX=0,offsetY=0,scale=4})
		return e,s,r
	end
	local function plane(id:number?):any
		return {id=id or 100,type='Paratroopers',owner=2,tile=2088,lastTile=2087,sourceTile=2080,targetTile=2100,troops=100,active=true}
	end
	local function reply(source:number?,valid:boolean?):any
		return {tile=2080,unit='Paratroopers',tick=0,rangeWarning=false,
			buildable={type='Paratroopers',canBuild=if valid==false or source==nil then false else source,canUpgrade=false,
				cost=250000,ghostRailPaths={},overlappingRailroads={}},paraAim={originTile=source,reach=120,troops=100,readyAt=0}}
	end
	t.test('transport and canopy masks occupy only spare atlas space and never classify as nukes',function()
		local pixels=Atlas.rgba();t.eq(buffer.len(pixels),512*192*4)
		for _,origin in {320,352} do
			local opaque,soft=0,0
			for y=0,31 do for x=origin,origin+31 do local a=buffer.readu8(pixels,(y*512+x)*4+3)
				if a==255 then opaque+=1 elseif a>0 then soft+=1 end
			end end
			t.ok(opaque>120 and soft>0,'bold antialiased shape')
		end
		t.eq(Visual.sprite(plane()),13);t.eq(Visual.isNuke('Paratroopers'),false);t.eq(Visual.isMissile('Paratroopers'),false)
		t.eq(Visual.hasBlastRing('Paratroopers'),false)
	end)
	t.test('aim uses origin tile zero, shows SAMs and invalidates missing origin, cooldown and gold',function()
		for _,split in {false,true} do
			local e,s,r=setup(split);local p=e.Preview.new(r,s,function() return nil end)
			p:setChosen('Paratroopers');p.reply=reply(0);p:draw(2080,32,32,false)
			for _=1,4 do r:step(1e9,1e9) end
			t.eq(r.scene.buildPreview.paraOriginTile,0);t.eq(r.scene.buildPreview.rangeRadius,0)
			t.ok(r.scene.strikePreviewRoot.Visible);t.ok(r.scene.paraLanding.Visible);t.eq(r.scene.samVisible,true)
			t.eq(r.scene.preview,nil,'straight air intent never gets a nuke arc or predicted intercept')
			t.eq(r.scene.paraLanding.ImageColor3,rb.Color3.fromRGB(255,211,64));t.eq(count(r.scene.strikeRangeKeys),0)
			p.reply=reply(nil);p:draw(2080,32,32,false);r:step(1e9,1e9)
			t.eq(r.scene.strikePreviewRoot.Visible,false);t.eq(r.scene.paraLanding.ImageColor3,rb.Color3.fromRGB(255,75,69))
			p.reply=reply(0,false);p:draw(2080,32,32,false);r:step(1e9,1e9)
			t.eq(r.scene.strikeAimLine.BackgroundColor3,rb.Color3.fromRGB(255,75,69))
			p.reply=reply(0);s.gold=0;p:draw(2080,32,32,false);r:step(1e9,1e9)
			t.eq(r.scene.paraLanding.ImageColor3,rb.Color3.fromRGB(255,75,69))
			local marker=r.scene.paraLanding;p:setChosen(nil);r:step(1e9,1e9)
			t.eq(marker.Visible,false);t.eq(r.scene.samVisible,false)
			p:destroy();r:destroy();t.ok(marker.destroyed)
		end
	end)
	t.test('landing marker retains screen-pixel bounds and cursor position after atlas styling, including offscreen culling',function()
		local Camera=H.require(root.CameraTransform)
		for _,split in {false,true} do
			local e,s,r=setup(split);local p=e.Preview.new(r,s,function() return nil end)
			p:setChosen('Paratroopers')
			for _,validated in {false,true} do
				p.reply=if validated then reply(0) else nil
				for _,zoom in {.2,4,20} do
					r:setCamera({width=64,height=64,viewportWidth=1914,viewportHeight=829,left=17,top=23,offsetX=0,offsetY=0,scale=zoom})
					p:draw(2080,32,32,false);r:step(1e9,1e9)
					local marker,c=r.scene.paraLanding,r.camera
					local x,y=Camera.worldToScreenCoordinates(c,32.5,32.5)
					t.eq(marker.Size.X.Scale,0,'atlas styling must not stretch the marker to its viewport parent')
					t.eq(marker.Size.Y.Scale,0);t.eq(marker.Size.X.Offset,math.clamp(16+zoom,18,28));t.eq(marker.Size.Y.Offset,marker.Size.X.Offset)
					t.eq(marker.Position.X.Scale,0);t.eq(marker.Position.Y.Scale,0)
					t.eq(marker.Position,rb.UDim2.fromOffset(x-c.left,y-c.top))
					t.eq(marker.ImageRectOffset,rb.Vector2.new(352,0));t.eq(marker.ImageRectSize,rb.Vector2.new(32,32));t.ok(marker.Visible)
				end
			end
			r:setCamera({width=64,height=64,viewportWidth=844,viewportHeight=390,left=17,top=23,offsetX=1000,offsetY=1000,scale=4})
			r:step(1e9,1e9);t.eq(r.scene.paraLanding.Visible,false,'atlas styling must not re-show an offscreen marker')
			p:setChosen(nil);r:step(1e9,1e9);t.eq(r.scene.paraLanding.Visible,false)
			p:destroy();r:destroy()
		end
	end)
	t.test('landing finals deduplicate and snapshots seed without replay, including instant flights',function()
		local state,u=State.new(64),plane();state:seed({[u.id]=u})
		u.active=false;u.reachedTarget=true
		state:updates({u},{},function() return true end,1,4);t.eq(#state.marks,1);t.eq(state.marks[1].kind,'paraLand')
		t.eq(state.marks[1].x,u.tile%64+.5)
		state:updates({u},{},function() return true end,1.01,4);t.eq(#state.marks,1)
		state:seed({[u.id]=u});state:updates({u},{},function() return true end,2,4);t.eq(#state.marks,0)
		state:seed({});state:updates({u},{},function() return true end,3,4);t.eq(state.marks[1].kind,'paraLand')
		state:expire(4);t.eq(#state.marks,0)
	end)
	t.test('shoot-down needs confirmed destroyer and targeting SAM independent of packet ordering',function()
		for _,reverse in {false,true} do
			local state,u=State.new(64),plane();state:seed({[u.id]=u})
			u.active=false;u.reachedTarget=false;u.destroyer=3
			local sam={id=200,type='SAMMissile',owner=3,targetUnitId=u.id,active=false,tile=u.tile}
			state:updates(if reverse then {sam,u} else {u,sam},{},function() return true end,1,4)
			t.eq(#state.marks,1);t.eq(state.marks[1].kind,'paraDown')
			state:updates({u,sam},{},function() return true end,1.01,4);t.eq(#state.marks,1)
		end
		local state,u=State.new(64),plane()
		local sam={id=200,type='SAMMissile',owner=3,targetUnitId=u.id,active=true,tile=u.tile}
		state:seed({[u.id]=u,[200]=sam});u.active=false
		state:updates({u},{},function() return true end,1,4);t.eq(#state.marks,0,'owner cleanup cannot invent an interception')
		state:seed({});u.destroyer=3;state:updates({u},{},function() return true end,2,4);t.eq(#state.marks,0,'no matching SAM')
	end)
	t.test('flight interpolates the full confirmed delta and retargets from its displayed pose without extrapolation',function()
		local state,u=State.new(64),plane();u.tile=2080;state:seed({[u.id]=u})
		u.tile=2088;u.lastTile=2087;state:updates({u},{},function() return true end,1,4)
		local x,y=state:flightPosition(u,1.05);t.near(x,36,1e-8);t.eq(y,32)
		u.tile=2096;state:updates({u},{},function() return true end,1.05,4)
		x=state:flightPosition(u,1.05);t.near(x,36,1e-8,'no discontinuity during an in-flight update')
		x=state:flightPosition(u,10);t.eq(x,48,'never advances past confirmed state')
		state:seed({[u.id]=u});x=state:flightPosition(u,10);t.eq(x,48,'snapshot starts at its current tile')
	end)
	t.test('public owner-colored planes and canopy/smoke accents share pool caps, image slot and cleanup',function()
		local e,s,r=setup(true);local a,u=r.scene.artillery,plane()
		s.units[u.id]=u;s.UnitsChanged:Fire({u},{});r:step(1e9,1e9);a:step(0,.5)
		local slot=a.shells[1];t.ok(slot.plane.Visible and slot.outline.Visible);t.eq(slot.tail.Visible,false)
		t.eq(r.scene.unitViews[u.id],nil);t.eq(slot.plane.ImageRectSize,rb.Vector2.new(32,32))
		local fill=r.core.palette[u.owner].fill;t.eq(slot.plane.ImageColor3,rb.Color3.new(fill.r,fill.g,fill.b))
		for _,zoom in {.2,20} do r.camera.scale=zoom;a:step(0,1);t.ok(slot.head.Size.X.Offset>=16 and slot.head.Size.X.Offset<=32) end
		r.camera.scale=4
		local updates={};for id=101,180 do local v=plane(id);s.units[id]=v;table.insert(updates,v) end
		s.UnitsChanged:Fire(updates,{});for _=1,12 do r:step(1e9,1e9) end;t.eq(#a.shells,State.shellCap)
		u.active=false;u.reachedTarget=true;s.UnitsChanged:Fire({u},{});r:step(1e9,1e9)
		local mark=a.state.marks[#a.state.marks];a:step(mark.start+.2,1)
		t.ok(a.marks[#a.state.marks].canopies[1].Visible);t.eq(a.marks[#a.state.marks].bars[1].Visible,false)
		local down=plane(300);down.active=false;down.destroyer=3
		local sam={id=301,type='SAMMissile',owner=3,targetUnitId=300,active=false,tile=down.tile}
		a:updates({down,sam},{},mark.start+.25);a:step(mark.start+.35,1)
		local m=a.marks[#a.state.marks];t.ok(m.bars[2].Visible);t.ok(m.bars[2].Position.Y.Offset>0);t.eq(m.canopies[1].Visible,false)
		for id=400,480 do local v=plane(id);v.active=false;v.reachedTarget=true;v.tile=2000+id%64
			a:updates({v},{},mark.start+.4+id*.001) end
		t.ok(#a.state.marks<=State.markCap)
		e.recordUploads=true;for _=1,5 do e.uploads={};r:step(1e9,1e9);local seen={};for _,img in e.uploads do seen[img]=true end;t.ok(count(seen)<=1) end
		s.Snapshot:Fire();t.eq(#a.state.marks,0);s.winner=1;s.PhaseChanged:Fire();t.eq(#a.ids,0)
		local parent=a.root;r:destroy();t.ok(parent.destroyed);t.eq(#a.shells,0);t.eq(next(a.state.flights),nil);t.eq(next(a.state.samTargets),nil)
	end)
	t.test('a public troop plane preempts a shell view when the shared flight pool is saturated',function()
		local _,s,r=setup();local updates={}
		for id=100,139 do
			local u=plane(id);u.type='Artillery Shell';s.units[id]=u;table.insert(updates,u)
		end
		s.UnitsChanged:Fire(updates,{});for _=1,12 do r:step(1e9,1e9) end
		t.eq(#r.scene.artillery.shells,State.shellCap)
		local u=plane(200);s.units[u.id]=u;s.UnitsChanged:Fire({u},{});r:step(1e9,1e9)
		local found=false
		for _,slot in r.scene.artillery.shells do if slot.id==u.id then found=true;t.ok(slot.outline.Visible) end end
		t.ok(found,'plane appears without waiting for ordinary shots to finish');t.eq(#r.scene.artillery.shells,State.shellCap)
		r:destroy()
	end)
end
