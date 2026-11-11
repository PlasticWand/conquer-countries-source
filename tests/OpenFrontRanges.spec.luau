--!strict
-- Native-property/count evidence only; excludes phone fill-rate/layout/GPU.
return function(t)
	local fs,luau,roblox=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local function setup():any
		local e=native(); local s=e.client(); s.startTick=0
		local terrain=buffer.create(4096); buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false})
		r:attachState(s); r:step(1e9,1e9)
		return e,s,r
	end
	t.test('SAM discs retain own yellow, enemy red and ally blue, including every enemy while aiming MIRV',function()
		local e,s,r=setup()
		s.units={}
		for id,owner in {1,2,3,2} do s.units[id]={id=id,type='SAM Launcher',owner=owner,tile=130+id*8,level=id,active=true} end
		r.scene:setUnits(s.units); r.scene:setAffiliations({[3]=true},{})
		r:setHighlightStructureTypes({'MIRV'})
		for _=1,4 do r:step(1e9,1e9) end
		for id,color in {roblox.Color3.fromRGB(255,211,64),roblox.Color3.fromRGB(255,75,69),
			roblox.Color3.fromRGB(77,163,255),roblox.Color3.fromRGB(255,75,69)} do
			local f=r.scene.rangeViews[`SamRange{id}:0`]
			t.ok(f and f.Visible); t.eq(f.BackgroundColor3,color)
			t.near(f.Size.X.Offset,s:config():samRange(id)*128,1,'native integer offsets: at most 1/64 tile')
			t.near(f.BackgroundTransparency,.91,1e-6)
			t.near(f:FindFirstChild('Stroke').Thickness*r.camera.scale/64,3,1e-6)
		end
		local views=r.scene.rangeViews
		local first=views['SamRange1:0']; local created=#e.objects
		r:pan(15,-20); r:step(1e9,1e9)
		t.eq(views['SamRange1:0'],first); t.eq(#e.objects,created,'pan reuses circles')
		r.scene:setAffiliations({[2]=true,[3]=true},{}); r:step(1e9,1e9)
		t.eq(views['SamRange2:0'].BackgroundColor3,roblox.Color3.fromRGB(77,163,255),'confirmed alliance recolours retained enemy range')
		t.eq(#e.objects,created)
		r:destroy(); for _,f in e.objects do if f.Parent then t.eq(f.destroyed,true,f.Name) end end
	end)
	t.test('inner and outer bomb radii use config and continuous preview movement without GUI rebuilds',function()
		for _,kind in {'Atom Bomb','Hydrogen Bomb','Mega Nuke'} do
			local e,s,r=setup(); s.gold=1e9
			s.units[10]={id=10,type='Missile Silo',tile=0,owner=1,active=true,level=1}
			r:bindInput(e.playerGui,e.mapGui,function() end)
			local p=e.Preview.new(r,s,function(tile,unit)
				return {tile=tile,unit=unit,rangeWarning=true,buildable={type=unit,canBuild=tile,canUpgrade=false,cost=1}}
			end)
			local x,y=r:worldToScreen(20.5,22.5)
			e.uis.InputChanged:Fire({UserInputType=roblox.Enum.UserInputType.MouseMovement,Position={X=x,Y=y}},false)
			p:setChosen(kind); p:step(); e.completeQuery(); p:step(); r:step(1e9,1e9)
			local m=s:config():nukeMagnitudes(kind)
			t.eq(r.scene.buildPreview.innerRangeRadius,m.inner)
			local outer,inner=r.scene.rangeViews.BuildRange,r.scene.rangeViews.BuildInnerRange
			t.ok(outer.Visible and inner.Visible)
			t.near(outer.Size.X.Offset,m.outer*128,1e-3); t.near(inner.Size.X.Offset,m.inner*128,1e-3)
			t.eq(outer.BackgroundColor3,roblox.Color3.fromRGB(255,211,64),'warning does not recolour your blast red')
			local created=#e.objects
			for _=1,3 do p:step(); r:step(1e9,1e9) end
			t.eq(#e.objects,created)
			p:setChosen(nil); r:step(1e9,1e9); t.eq(outer.Visible,false); t.eq(inner.Visible,false)
			p:destroy(); r:destroy()
		end
	end)
	t.test('tapping ranged enemy structures exposes real radii and passes the tap to UI; empty tap/death clears',function()
		local e,s,r=setup()
		s.units={}
		for id,kind in {'SAM Launcher','Factory','Defense Post'} do
			s.units[id]={id=id,type=kind,tile=64*(id*12)+20,owner=2,active=true,level=2}
		end
		r.scene:setUnits(s.units); r:step(1e9,1e9)
		local taps=0; r:bindInput(e.playerGui,e.mapGui,function() taps+=1 end)
		for id,expected in {s:config():samRange(2),s:config():trainStationMaxRange(),s:config():defensePostRange()} do
			local tile=s.units[id].tile
			local x,y=r:worldToScreen(tile%64+.5,math.floor(tile/64)+.5); e.mouseTap(x,y); r:step(1e9,1e9)
			t.eq(r.scene.inspectedRange,id); t.eq(taps,id)
			local f=r.scene.rangeViews.InspectedRange
			t.ok(f.Visible); t.near(f.Size.X.Offset,expected*128,1)
		end
		s.units[3].active=false; r.scene:setUnits(s.units); r:step(1e9,1e9)
		t.eq(r.scene.rangeViews.InspectedRange.Visible,false)
		r.scene:inspectRange(s.units[1].tile); r:step(1e9,1e9)
		r.scene:inspectRange(0); r:step(1e9,1e9); t.eq(r.scene.inspectedRange,nil)
		t.eq(r.scene.rangeViews.InspectedRange.Visible,false); r:destroy()
	end)
	t.test('large SAM range sets share the create budget, settle to zero churn and retire in bounded batches',function()
		local e,_,r=setup(); local scene=r.scene
		-- Isolate circle work from optional structure atlas/GUI construction.
		scene.units,scene.unitOrder={},{}
		for id=1,120 do scene.units[id]={id=id,type='SAM Launcher',owner=2,tile=id,level=1,active=true}; table.insert(scene.unitOrder,id) end
		scene.highlightTypes={['Atom Bomb']=true}
		for _=1,8 do
			local before=#e.objects; r:step(1e9,1e9)
			t.ok(#e.objects-before<=25*3+2,'at most 25 range views plus one lazy shared layer')
		end
		local count=0; for _,f in scene.rangeViews do if f.Visible then count+=1 end end; t.eq(count,120)
		local created=#e.objects
		for _=1,5 do r:step(1e9,1e9) end; t.eq(#e.objects,created)
		scene.highlightTypes={}; r:step(1e9,1e9)
		t.ok(#scene.rangePool>=120-16)
		for _=1,10 do r:step(1e9,1e9) end
		t.ok(#scene.rangePool<=32); t.eq(next(scene.rangeViews),nil)
		r:destroy(); t.eq(#scene.rangePool,0)
	end)
	t.test('both target blast radii appear before a large SAM network can consume the create allowance',function()
		local _,_,r=setup(); local scene=r.scene
		scene.units,scene.unitOrder={},{}
		for id=1,120 do scene.units[id]={id=id,type='SAM Launcher',owner=2,tile=id,level=1,active=true}; table.insert(scene.unitOrder,id) end
		r:setBuildPreview({ghostType='Atom Bomb',tileX=20,tileY=20,radiusTileX=20,radiusTileY=20,
			rangeRadius=30,innerRangeRadius=12,ownerID=1,canBuild=true,canUpgrade=false})
		r:step(1e9,1e9)
		t.ok(scene.rangeViews.BuildRange.Visible); t.ok(scene.rangeViews.BuildInnerRange.Visible)
		t.eq(scene.newUnitBudget,0); t.ok(scene.samRangesPending)
		r:destroy()
	end)
	t.test('idle SAM descriptors survive ordinary ticks and unrelated unit changes but refresh on capture',function()
		local _,s,r=setup()
		s.units[1]={id=1,type='SAM Launcher',owner=2,tile=65,level=1,active=true}
		s.units[2]={id=2,type='City',owner=1,tile=500,level=1,active=true}
		r.scene:setUnits(s.units); r:setHighlightStructureTypes({'Atom Bomb'}); r:step(1e9,1e9)
		local circles=r.scene.samCircles
		for tick=1,12 do
			r.scene:setTick(tick); s.units[2].level=2; r.scene:setUnits(s.units); r:step(1e9,1e9)
			t.eq(r.scene.samCircles,circles,'no full SAM rebuild for an unchanged network')
		end
		s.units[1].owner=1; r.scene:setUnits(s.units); r:step(1e9,1e9)
		t.ok(r.scene.samCircles~=circles); t.eq(r.scene.samCircles[1].owner,1)
		r:destroy()
	end)
end
