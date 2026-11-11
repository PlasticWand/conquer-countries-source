--!strict
-- Coastal presentation consumes confirmed placement/source records only.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))();local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local State,Visual,Atlas=H.require(root.ArtilleryState),H.require(root.UnitVisuals),H.require(root.SpriteAtlas)
	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function battery(owner:number?):any return {id=1,type='Coastal Battery',owner=owner or 1,tile=2080,active=true,level=1} end
	local function setup(split:boolean?):any
		local e=native();e.policy.splitMapGuis=split==true;e.mapGui.DisplayOrder=0
		local s=e.client();s.startTick=0;s.gold=1e9;s.units={[1]=battery()}
		local config=s:config();config.COASTAL_RANGE=17
		local old=config.unitInfo;config.unitInfo=function(self:any,kind:string):any
			if kind=='Coastal Battery' then return {constructionDuration=80} end
			return old(self,kind)
		end;s.config=function() return config end
		local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,guiHost=e.mapGui,coasts=false})
		r:attachState(s);for _=1,100 do r:step(1e9,1e9) end
		r:setCamera({width=64,height=64,viewportWidth=844,viewportHeight=390,left=17,top=23,offsetX=0,offsetY=0,scale=4})
		return e,s,r
	end
	t.test('casemate symbol, distinct plate and construction duration use the existing atlas',function()
		local col,structure=Visual.sprite(battery());t.eq(col,9);t.ok(structure);t.eq(Visual.constructionDuration('Coastal Battery'),80)
		local pixels=Atlas.rgba();t.eq(buffer.len(pixels),512*192*4)
		local x,y,w,h=Atlas.iconRect(col);t.eq(x,416);t.eq(y,0);t.eq(w,32);t.eq(h,32)
		local ink=0;for yy=0,31 do for xx=416,447 do if buffer.readu8(pixels,(yy*512+xx)*4+3)>0 then ink+=1 end end end
		t.ok(ink>180 and ink<700);local sx,sy=Atlas.shapeRect(col);t.eq(sx,384);t.eq(sy,0)
		t.eq(buffer.readu8(pixels,(16*512+400)*4+3),255);t.eq(buffer.readu8(pixels,384*4+3),0)
	end)
	t.test('confirmed shore snap moves ghost and config range together, with inspected owner colours',function()
		for _,split in {false,true} do
			local e,s,r=setup(split);local p=e.Preview.new(r,s,function() return nil end)
			p:setChosen('Coastal Battery');p:draw(2200,24,34,false);r:step(1e9,1e9)
			t.eq(r.scene.buildPreview.rangeRadius,17)
			p.reply={tile=2200,unit='Coastal Battery',tick=0,rangeWarning=false,
				buildable={type='Coastal Battery',canBuild=2085,canUpgrade=false,cost=400000,ghostRailPaths={},overlappingRailroads={}}}
			p:draw(2200,24,34,false);for _=1,3 do r:step(1e9,1e9) end
			local g=r.scene.buildPreview;t.ok(g.snapToPlacement);t.eq(g.tileX,37);t.eq(g.tileY,32);t.eq(g.radiusTileX,37);t.eq(g.radiusTileY,32)
			t.eq(g.rangeRadius,17);t.ok(r.scene.ghostViews[1].root.Visible)
			t.eq(r.scene.rangeViews.BuildRange.Size.X.Offset,17*128);t.eq(r.scene.rangeViews.BuildRange.BackgroundColor3,rb.Color3.fromRGB(255,211,64))
			p:setChosen(nil);r.scene:inspectRange(2080);r:step(1e9,1e9)
			t.eq(r.scene.rangeViews.InspectedRange.BackgroundColor3,rb.Color3.fromRGB(255,211,64))
			local u=s.units[1];u.owner=2;s.UnitsChanged:Fire({u},{});r.scene:inspectRange(2080);r:step(1e9,1e9)
			t.eq(r.scene.rangeViews.InspectedRange.BackgroundColor3,rb.Color3.fromRGB(255,75,69))
			u.health=400;u.maxHealth=800;s.UnitsChanged:Fire({u},{});r:step(1e9,1e9);t.ok(r.scene.unitViews[1].health)
			p:destroy();r:destroy()
		end
	end)
	t.test('battery muzzle uses first confirmed Shell source, deduplicates and suppresses snapshots',function()
		local b,state=battery(),State.new(64)
		local shell={id=10,type='Shell',owner=1,tile=2080,active=true}
		state:seed({[1]=b,[10]=shell});state:updates({shell},{},function() return true end,0,4);t.eq(#state.marks,0)
		state:seed({[1]=b});state:updates({shell},{},function() return true end,1,4)
		t.eq(#state.marks,1);t.eq(state.marks[1].kind,'muzzle');t.eq(state.marks[1].x,32.5)
		state:updates({shell},{},function() return true end,1.01,4);t.eq(#state.marks,1)
		state:seed({[1]=b});shell.tile=2083;shell.sourceTile=2080
		state:updates({shell},{},function() return true end,2,4);t.eq(#state.marks,1,'first-tick movement retains explicit origin')
		state:seed({[1]=b});shell.sourceTile=nil;state:updates({shell},{},function() return true end,3,4);t.eq(#state.marks,0,'never infer the nearest gun')
		state:seed({});shell.sourceTile=2080;state:updates({shell,b},{},function() return true end,4,4);t.eq(#state.marks,1,'batch order independent')
		state:seed({[1]=b});shell.active=false;shell.reachedTarget=true
		state:updates({shell},{},function() return true end,5,4);t.eq(#state.marks,1,'instant confirmed hit still has a muzzle flash')
		t.eq(State.projectiles.Shell,nil,'ordinary Shell is not stolen by the Arsenal flight pool')
	end)
	t.test('captured, unfinished, removed and offscreen guns cannot create stale muzzle accents',function()
		local b,state=battery(),State.new(64);local shell={id=10,type='Shell',owner=1,tile=2080,active=true}
		b.underConstruction=true;state:seed({[1]=b});state:updates({shell},{},function() return true end,0,4);t.eq(#state.marks,0)
		b.underConstruction=false;state:seed({[1]=b});b.owner=2;state:updates({b,shell},{},function() return true end,1,4);t.eq(#state.marks,0)
		state:seed({[1]=b});state:updates({},{1},function() return true end,2,4);shell.owner=2
		state:updates({shell},{},function() return true end,2,4);t.eq(#state.marks,0)
		state:seed({[1]=b});state:updates({shell},{},function() return false end,3,4);t.eq(#state.marks,0)
	end)
	t.test('normal shells still render and muzzle accents share caps and snapshot cleanup',function()
		local _,s,r=setup();local shell={id=10,type='Shell',owner=1,tile=2080,lastTile=2080,active=true}
		s.units[10]=shell;s.UnitsChanged:Fire({shell},{});r:step(1e9,1e9)
		t.ok(r.scene.unitViews[10]);t.eq(#r.scene.artillery.ids,0);t.eq(r.scene.artillery.state.marks[1].kind,'muzzle')
		local a=r.scene.artillery;a:step(a.state.marks[1].start+.02,1);t.ok(a.marks[1].root.Visible)
		s.Snapshot:Fire();t.eq(#a.state.marks,0);r:destroy();t.eq(next(a.state.coastal),nil)
	end)
end
