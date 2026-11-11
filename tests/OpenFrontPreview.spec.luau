--!strict
-- Advisory preview queries are deliberately delayed in this native-property
-- shim; these checks do not establish Roblox layout/GPU or touch feel.
return function(t)
	local fs,luau,roblox=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Camera=H.require(root.CameraTransform)
	local function setup(options:any?):any
		local e=native(); local s=e.client(); s.startTick,s.gold=0,2000000
		local terrain=buffer.create(4096); buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false})
		r:attachState(s); r:bindInput(e.playerGui,e.mapGui,function() end)
		local q={calls={}}
		q.reply=function(tile:number?,unit:string):any
			return {tile=tile,unit=unit,tick=s.tick,rangeWarning=false,buildable={type=unit,
				canBuild=if tile~=nil then tile else false,canUpgrade=false,cost=125000,
				ghostRailPaths={},overlappingRailroads={}}}
		end
		local p=e.Preview.new(r,s,function(tile,unit)
			table.insert(q.calls,{tile=tile,unit=unit}); return q.reply(tile,unit)
		end,options)
		local function move(x:number,y:number)
			local sx,sy=r:worldToScreen(x,y)
			e.uis.InputChanged:Fire({UserInputType=roblox.Enum.UserInputType.MouseMovement,Position={X=sx,Y=sy}},false)
		end
		return e,s,r,p,q,move
	end
	t.test('ghost data matches original TypeScript except approved Warship range; upgrades, snap and cost settings',function()
		local serde=require('@lune/serde')
		local fixture=serde.decode('json',fs.readFile('tests/fixtures/OpenFrontPreview.json'))
		for _,c in fixture.cases do
			local e,s,r,p,q,move=setup({snapToPlacement=c.snap,showCost=c.showCost})
			s.gold=c.gold
			s.units[10]={type='Missile Silo',owner=1,active=true,tile=0,level=1,
				missileTimerQueue=if c.ready==0 then {0} else {}}
			if c.upgrade and not c.missing then s.units[9]={type=c.type,tile=0,level=2} end
			q.reply=function(tile,unit) return {tile=tile,unit=unit,tick=0,rangeWarning=c.warning==true,buildable=c.buildable} end
			move(c.tile%64+.5,math.floor(c.tile/64)+.5); p:setChosen(c.type); p:step(); e.completeQuery(); p:step()
			local g=r.scene.buildPreview
			for key,value in c.expected do
				-- Keep the original oracle unchanged: feature 13 deliberately
				-- adds the configured patrol disc to its zero-radius ship ghost.
				if c.type=='Warship' and key=='rangeRadius' then
					t.eq(value,0,'source Warship ghost has no range')
					t.eq(g[key],s:config():warshipPatrolRange(),'approved Warship patrol presentation')
				elseif key=='upgradeTargetTile' and type(value)~='number' then t.eq(g[key],nil,c.name..' '..key)
				elseif type(value)=='number' then t.near(g[key],value,1e-12,c.name..' '..key)
				elseif type(value)~='table' then t.eq(g[key],value,c.name..' '..key) end
			end
			p:destroy(); r:destroy()
		end
	end)
	t.test('one request in flight, 50ms refresh, tile zero and continuous unsnapped cursor follow',function()
		local e,_,r,p,q,move=setup()
		move(.25,.75); p:setChosen('City'); p:step()
		t.eq(#e.pending,1); t.eq(r.scene.buildPreview.validated,false)
		for _=1,10 do e.now+=.01; p:step() end
		t.eq(#e.pending,1)
		e.completeQuery(); p:step(); t.eq(q.calls[1].tile,0)
		local g=r.scene.buildPreview; t.ok(g.canBuild); t.eq(g.cost,125000); t.near(g.tileX,-.25,1e-12)
		-- One new request may be queued after the delayed first reply.
		if #e.pending>0 then e.completeQuery() end
		e.now+=.001; move(.7,.8); p:step(); t.eq(#e.pending,0)
		t.near(r.scene.buildPreview.tileX,.2,1e-12); t.near(r.scene.buildPreview.tileY,.3,1e-12)
		e.now+=.051; p:step(); t.eq(#e.pending,1)
		p:destroy(); r:destroy()
	end)
	t.test('late replies cannot cross pointer tiles, chosen types, modal exclusion or destruction',function()
		local e,_,r,p,_,move=setup()
		move(1.5,1.5); p:setChosen('City'); p:step()
		move(2.5,2.5); e.now=.06; p:step(); e.completeQuery(); t.eq(p.reply,nil)
		p:step(); t.eq(#e.pending,1)
		p:setChosen('Factory'); e.completeQuery(); t.eq(p.reply,nil)
		p:step(); e.blocked=true; e.completeQuery(); t.eq(p.reply,nil)
		p:step(); t.eq(r.scene.buildPreview,nil); t.eq(r.scene.preview,nil)
		e.blocked=false; e.now+=.06; p:step(); t.eq(#e.pending,1)
		p:destroy(); e.completeQuery(); t.eq(p.reply,nil); t.eq(r.scene.buildPreview,nil)
		e.render:Fire(1); t.eq(#e.pending,0); r:destroy()
	end)
	t.test('upgrade anchors/radii, affordability and supplied rail paths use query and confirmed state',function()
		local e,s,r,p,q,move=setup()
		s.units[9]={id=9,type='SAM Launcher',owner=1,tile=0,level=2,active=true}
		s.gold=100
		q.reply=function(tile,unit)
			return {tile=tile,unit=unit,tick=s.tick,rangeWarning=true,buildable={type=unit,canBuild=false,
				canUpgrade=9,cost=1500000,ghostRailPaths={{0,1,2}},overlappingRailroads={0,1}}}
		end
		move(1.25,.75); p:setChosen('SAM Launcher'); p:step(); e.completeQuery(); p:step()
		local g=r.scene.buildPreview
		t.ok(g.canUpgrade); t.eq(g.canBuild,false); t.eq(g.upgradeTargetTile,0)
		t.eq(g.radiusTileX,0); t.eq(g.radiusTileY,0); t.near(g.rangeRadius,s:config():samRange(3),1e-12)
		t.eq(g.canAfford,false); t.eq(g.rangeWarning,true); t.eq(g.ghostRailPaths[1][1],0)
		t.eq(g.overlappingRailroads[1],0); t.eq(g.multiplier,1)
		p:destroy(); r:destroy()
	end)
	t.test('optional placement snapping anchors moved builds but preserves cursor motion on the same tile',function()
		local e,_,r,p,q,move=setup({snapToPlacement=true,showCost=false})
		q.reply=function(tile,unit)
			return {tile=tile,unit=unit,tick=1,rangeWarning=false,buildable={type=unit,canBuild=0,
				canUpgrade=false,cost=125000,ghostRailPaths={},overlappingRailroads={}}}
		end
		move(2.5,2.5); p:setChosen('City'); p:step(); e.completeQuery(); p:step()
		t.eq(r.scene.buildPreview.tileX,0); t.eq(r.scene.buildPreview.snapToPlacement,true)
		move(.75,.75); e.now=.06; p:step(); e.completeQuery(); p:step()
		t.near(r.scene.buildPreview.tileX,.25,1e-12); t.eq(r.scene.buildPreview.snapToPlacement,false)
		t.eq(r.scene.buildPreview.showCost,false); p:destroy(); r:destroy()
	end)
	t.test('Atom/Hydrogen aim uses supplied silo/SAMs even when unbuildable; MIRV clears trajectory',function()
		local e,s,r,p,q,move=setup()
		s.units[9]={type='Missile Silo',owner=1,tile=0,level=1,active=true,underConstruction=false,missileTimerQueue={0}}
		q.reply=function(tile,unit)
			return {tile=tile,unit=unit,tick=1,rangeWarning=false,buildable={type=unit,canBuild=false,
				canUpgrade=false,cost=750000,ghostRailPaths={},overlappingRailroads={}},
				nukeAim={siloTile=0,sams={{x=2,y=2,r=70}}}}
		end
		move(20.25,20.75); p:setChosen('Atom Bomb'); p:step(); e.completeQuery(); p:step()
		t.eq(r.scene.buildPreview.canAfford,false)
		local a=r.scene.preview; t.eq(a.p0x,0); t.eq(a.p0y,0); t.near(a.p3x,19.75,1e-12)
		t.ok(a.p1y<=a.p0y+(a.p3y-a.p0y)/4); t.ok(a.tSamIntercept<1)
		p:setChosen('Hydrogen Bomb'); e.now+=.06; p:step(); e.completeQuery(); p:step(); t.ok(r.scene.preview~=nil)
		p:setChosen('MIRV'); e.now+=.06; p:step(); e.completeQuery(); p:step(); t.eq(r.scene.preview,nil)
		p:setChosen(nil); t.eq(r.scene.buildPreview,nil); p:destroy(); r:destroy()
	end)
	t.test('impassable destination voids ghost, retains blocked nuke arc and sends its raw tile',function()
		local e,_,r,p,q,move=setup()
		buffer.writeu8(r.core.terrain,0,159)
		q.reply=function(tile,unit)
			return {tile=tile,unit=unit,tick=1,rangeWarning=false,buildable={type=unit,canBuild=false,
				canUpgrade=false,cost=750000,ghostRailPaths={},overlappingRailroads={}},nukeAim={siloTile=100,sams={}}}
		end
		move(.5,.5); p:setChosen('Atom Bomb'); p:step(); e.completeQuery(); p:step()
		t.eq(q.calls[1].tile,0); t.eq(r.scene.buildPreview,nil); t.eq(r.scene.preview.tSamIntercept,.9999)
		p:setChosen('City'); e.now+=.06; p:step(); e.completeQuery(); p:step()
		t.eq(q.calls[2].tile,nil); t.eq(r.scene.buildPreview,nil); t.eq(r.scene.preview,nil)
		move(-2,4); p:setChosen('Hydrogen Bomb'); e.now+=.06; p:step(); e.completeQuery(); p:step()
		t.eq(q.calls[3].tile,nil); t.eq(r.scene.preview,nil); p:destroy(); r:destroy()
	end)
	t.test('rocket direction flips a cached arc and also applies to a query already in flight',function()
		local e,_,r,p,q,move=setup()
		q.reply=function(tile,unit)
			return {tile=tile,unit=unit,tick=1,rangeWarning=false,buildable={type=unit,canBuild=false,
				canUpgrade=false,cost=750000,ghostRailPaths={},overlappingRailroads={}},nukeAim={siloTile=1950,sams={}}}
		end
		move(40.5,30.5); p:setChosen('Atom Bomb'); p:step()
		p:setRocketDirection(false); t.eq(#e.pending,1)
		e.completeQuery(); p:step(); t.eq(#q.calls,1)
		local down=r.scene.preview; t.ok(down.p1y>down.p0y); t.ok(down.p2y>down.p3y)
		local reply=p.reply
		p:setRocketDirection(true); p:step()
		local up=r.scene.preview; t.ok(up.p1y<up.p0y); t.ok(up.p2y<up.p3y)
		t.eq(up.p0x,down.p0x); t.eq(up.p3x,down.p3x); t.eq(p.reply,reply); t.eq(#e.pending,0)
		p:destroy(); p:setRocketDirection(false); t.eq(p.rocketDirectionUp,true); t.eq(r.scene.preview,nil)
		r:destroy()
	end)
	t.test('touch keeps its last position, camera movement revalidates tile and failed query stays advisory',function()
		local e,_,r,p,q=setup()
		local c=table.clone(r.camera);c.scale=16
		c.offsetX=(c.width-c.viewportWidth)/(2*c.scale);c.offsetY=(c.height-c.viewportHeight)/(2*c.scale);r:setCamera(c)
		local sx,sy=r:worldToScreen(16.25,32.75)
		local touch={UserInputType=roblox.Enum.UserInputType.Touch,Position={X=sx,Y=sy}}
		e.uis.InputBegan:Fire(touch,false); e.uis.InputEnded:Fire(touch)
		p:setChosen('City'); p:step(); e.completeQuery(); p:step()
		t.near(r.scene.buildPreview.tileX,15.75,1e-12)
		local oldTile=p.pointerTile
		r:pan(20,0); e.now+=.06; p:step(); t.eq(p.reply,nil);t.ok(p.pointerTile~=oldTile)
		t.eq(r.scene.buildPreview.validated,false);t.eq(r.scene.buildPreview.canBuild,false)
		q.reply=function() error('remote disconnected') end
		e.completeQuery(); p:step(); t.eq(p.reply,nil)
		t.eq(r.scene.buildPreview.validated,false);t.eq(r.scene.buildPreview.canBuild,false)
		r:destroy(); t.eq(p.destroyed,true); t.eq(p.queryThread,nil)
	end)
	t.test('fly-to matches source-tested camera steps, cancels on manual input and releases its connection',function()
		local e=native()
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		local expected=table.clone(r.camera)
		r:goTo(12,40,8)
		e.render:Fire(.008); t.eq(r.camera.offsetX,expected.offsetX)
		e.render:Fire(.008); Camera.goTo(expected,12,40,8,16)
		t.near(r.camera.offsetX,expected.offsetX,1e-12); t.near(r.camera.scale,expected.scale,1e-12)
		e.render:Fire(.032); Camera.goTo(expected,12,40,8,32)
		t.near(r.camera.offsetY,expected.offsetY,1e-12); t.near(r.camera.scale,expected.scale,1e-12)
		for _,manual in {function() r:pan(1,0) end,function() r:zoom(20,30,1) end,function() r:centerAll() end,
			function() r:setCamera(r.camera) end} do
			r:goTo(20,20); manual(); t.eq(r.goToTarget,nil); t.eq(r.goToConnection,nil)
		end
		r:goTo(20,20); for _=1,600 do e.render:Fire(.016) end
		t.eq(r.goToTarget,nil); local x,y=Camera.screenCenter(r.camera); t.ok(math.abs(x-20)+math.abs(y-20)<2)
		r:goTo(40,40); local connection=r.goToConnection; r:destroy(); t.eq(r.goToConnection,nil)
		e.render:Fire(1); t.eq(r.goToTarget,nil); t.ok(connection~=nil)
	end)
	t.test('hasSelection prunes captured ships and is safe before attach and after destroy',function()
		local e,s,r,p=setup(); t.eq(r:hasSelection(),false)
		s.units[8]={id=8,type='Warship',owner=1,tile=10,active=true}; r.scene.selection.ids={8}
		t.eq(r:hasSelection(),true); s.units[8].owner=2; t.eq(r:hasSelection(),false)
		p:destroy(); r:destroy(); t.eq(r:hasSelection(),false)
	end)
	t.test('pending tiles survive pointer/UI exclusion and camera changes; move/cancel reject stale replies',function()
		local e,_,r,p,_,move=setup()
		p:setChosen('Factory'); p:setPendingTile(65); p:step()
		t.eq(p:pendingTile(),65); t.eq(r.scene.buildPreview.validated,false)
		e.blocked=true; e.completeQuery(); p:step()
		t.eq(r.scene.buildPreview.tileX,1); t.eq(r.scene.buildPreview.tileY,1)
		r:pan(25,20); move(20,30); e.now+=.1; p:step(); r:step(1e9,1e9)
		t.eq(p:pendingTile(),65); t.eq(r.scene.buildPreview.tileX,1); t.eq(r.scene.buildPreview.rangeRadius,110)
		p:setPendingTile(66); p:step(); p:setPendingTile(67); e.completeQuery()
		t.eq(p.reply,nil); p:step(); e.completeQuery(); p:step(); t.eq(r.scene.buildPreview.tileX,3)
		p:setPendingTile(nil); e.blocked=false; move(10,10); e.now+=1; p:step()
		t.eq(p:pendingTile(),nil); t.eq(r.scene.buildPreview,nil); t.eq(r.scene.preview,nil)
		p:setPendingTile(0); p:step(); t.eq(p:pendingTile(),0)
		p:setChosen(nil); t.eq(p:pendingTile(),nil); t.eq(r.scene.buildPreview,nil)
		t.errors(function() p:setPendingTile(4096) end); p:destroy(); r:destroy()
	end)
	t.test('pinned structures retain their glyph, absolute opacity, range and cost over many frames at world zoom',function()
		for _,kind in {'City','Factory','SAM Launcher','Defense Post'} do
			local e,_,r,p,q=setup(); local c=table.clone(r.camera); c.scale=.4; r:setCamera(c)
			p:setChosen(kind); p:setPendingTile(65); p:step(); e.completeQuery(); p:step()
			e.blocked=true
			for _=1,120 do e.now+=1/60; p:step(); r:step(1e9,1e9) end
			local view=r.scene.ghostViews[1]
			t.ok(view.root.Visible and view.parts[3].Visible,kind)
			t.near(view.parts[1].ImageTransparency,.5,1e-6); t.near(view.parts[3].ImageTransparency,.55,1e-6)
			t.eq(r.scene.ghostCost.Text,'125K'); t.eq(r.scene.ghostCost.Visible,true)
			if kind~='City' then t.ok(r.scene.ghostRange and r.scene.ghostRange.Visible,kind..' range') end
			q.reply=function(tile,unit) return {tile=tile,unit=unit,buildable={type=unit,canBuild=false,canUpgrade=false,cost=125000}} end
			p:setPendingTile(66); p:step(); e.completeQuery(); p:step(); r:step(1e9,1e9)
			t.eq(r.scene.buildPreview.validated,true); t.ok(r.scene.ghostViews[1].parts[2].ImageColor3.R>.99)
			t.ok(r.scene.ghostViews[1].parts[2].ImageColor3.G<.4,'invalid symbol is red')
			p:destroy(); r:destroy()
		end
	end)
	t.test('pinned bombs cache their exact trajectory across identical replies, redraw on SAM/direction changes, and clear on cancel',function()
		local e,s,r,p,q=setup()
		local sams={{x=20,y=20,r=70}}
		q.reply=function(tile,unit) return {tile=tile,unit=unit,buildable={type=unit,canBuild=tile,canUpgrade=false,cost=750000},
			nukeAim={siloTile=0,sams=table.clone(sams)}} end
		p:setChosen('Atom Bomb'); p:setPendingTile(1300); p:step(); e.completeQuery(); p:step(); r:step(1e9,1e9)
		local data=r.scene.preview; local calls=r:metrics().timing_previewArc_calls
		s.tick+=1; e.now+=.1; p:step(); e.completeQuery(); p:step(); t.eq(r.scene.preview,data)
		t.eq(r:metrics().timing_previewArc_calls,calls)
		e.blocked=true; r:pan(20,10); p:step(); r:step(1e9,1e9)
		t.eq(r.scene.preview,data); t.eq(r.scene.trajectories[1].Parent,r.scene.layers.PreviewAim)
		p:setRocketDirection(false); p:step(); t.ok(r.scene.preview~=data); data=r.scene.preview
		sams={{x=25,y=25,r=90}}; s.tick+=1; e.now+=.1; p:step(); e.completeQuery(); p:step(); t.ok(r.scene.preview~=data)
		p:setPendingTile(nil); p:step(); r:step(1e9,1e9)
		t.eq(r.scene.preview,nil); t.eq(r.scene.trajectories[1].Visible,false)
		p:destroy(); r:destroy()
	end)
	t.test('camera observers run after transforms, skip unchanged views and disconnect on teardown',function()
		local e,_,r,p=setup(); r:step(1e9,1e9)
		local calls,x,y=0,0,0
		local consistent=false
		local disconnect=r:onCameraChanged(function()
			consistent=false
			calls+=1; x,y=r:worldToScreen(12,14)
			local expectedX,expectedY=Camera.worldToScreenCoordinates(r.camera,12,14)
			consistent=x==expectedX and y==expectedY and math.abs(r.scene.world.Position.X.Scale*r.camera.viewportWidth+r.camera.left
				-select(1,r:worldToScreen(0,0)))<1e-4
		end)
		r:pan(20,10); t.eq(calls,1); t.ok(consistent); r:setCamera(r.camera); t.eq(calls,1)
		r.parent.AbsoluteSize=roblox.Vector2.new(667,375); r.parent:GetPropertyChangedSignal('AbsoluteSize'):Fire(); t.eq(calls,2); t.ok(consistent)
		disconnect(); disconnect(); r:pan(1,1); t.eq(calls,2)
		r:onCameraChanged(function() calls+=1 end); r:goTo(20,20,8); e.render:Fire(.016); t.eq(calls,3)
		r:destroy(); e.render:Fire(1); t.eq(calls,3); t.eq(next(r.cameraListeners),nil)
		p:destroy()
	end)
	t.test('pinned placement does not send duplicate queries within an unchanged confirmed tick',function()
		local e,s,r,p,q=setup()
		p:setChosen('Factory'); p:setPendingTile(1000)
		for frame=0,59 do
			e.now=frame/60; s.tick=math.floor(frame/6)
			p:step(); if #e.pending>0 then e.completeQuery(); p:step() end
		end
		t.eq(#q.calls,10)
		e.now+=.06; s.gold+=1; p:step(); e.completeQuery(); p:step(); t.eq(#q.calls,11)
		p:destroy(); r:destroy()
	end)
end
