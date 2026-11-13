--!strict
return function(t)
	local fs,luau,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/serde')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Relations,Sam,Visual,Selection=H.require(root.Relations),H.require(root.SamGeometry),H.require(root.UnitVisuals),H.require(root.WarshipSelection)
	local g=serde.decode('json',fs.readFile('tests/fixtures/OpenFrontAdapters.json'))
	t.test('relation matrices and insertion-ordered alliance roots match original TS',function()
		for _, c in g.relations do
			local actual=Relations.matrix(c.players)
			local expected=buffer.create(c.size*c.size)
			for _, entry in c.entries do buffer.writeu8(expected,entry[1],entry[2]) end
			t.eq(actual.size,c.size); t.eq(buffer.tostring(actual.data),buffer.tostring(expected))
			local clusters=Relations.clusters(c.players)
			for _, pair in c.clusters do t.eq(clusters[pair[1]],pair[2]) end
		end
	end)
	t.test('SAM friendliness and nuke telegraphs keep source distinctions',function()
		local roster={{smallID=1,team='Blue',allies={2},embargoes={2}},{smallID=2,team='Red',allies={},embargoes={}},
			{smallID=1024,team='Blue',allies={},embargoes={}}}
		local m=Relations.matrix(roster); local f=Relations.friendly(roster,1)
		t.eq(f[2],true); t.eq(f[1024],true)
		t.eq(Relations.classify(2,1,m.data,m.size),2,'embargo wins for nuke telegraphs')
		t.eq(Relations.classify(1024,1,m.data,m.size),2,'source matrix limit remains neutral')
		t.eq(Relations.classify(1,1,m.data,m.size),0); t.eq(Relations.classify(1,0,m.data,m.size),2)
		local roots=Relations.clusters(roster); t.ok(roots[1]~=roots[1024],'team membership is not an alliance edge')
	end)
	t.test('relation invalidation is owner-scoped, unchanged matrices do no work, partial paints restart',function()
		local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
		local Core=raster.Core
		local terrain=buffer.create(96*32); buffer.fill(terrain,0,128)
		local roster={{id='a',smallID=1,playerType='HUMAN'},{id='b',smallID=2,playerType='HUMAN'},{id='c',smallID=3,playerType='HUMAN'}}
		local state=buffer.create(96*32*2)
		for tile=0,96*32-1 do buffer.writeu16(state,tile*2,math.floor(tile%96/32)+1) end
		local function core()
			local sink=raster.sink(96,32); local s=Core.new(terrain,96,32,sink.backend)
			Core.setRoster(s,roster); Core.applyTileStates(s,state)
			Core.setRelations(s,Relations.matrix({{smallID=1},{smallID=2},{smallID=3}}))
			return s,sink
		end
		local a,sink=core(); raster.drain(a)
		local ally=Relations.matrix({{smallID=1,allies={2}},{smallID=2},{smallID=3}})
		Core.setRelations(a,ally); t.eq(a.pending,2); raster.drain(a)
		Core.setRelations(a,ally); t.eq(a.pending,0)
		local b,other=core(); Core.step(b,1e9,1); t.ok(b.job~=nil)
		Core.setRelations(b,ally); raster.drain(b)
		for y=0,31 do for x=0,95 do t.eq(sink.pixel(x,y),other.pixel(x,y)) end end
		Core.destroy(a); Core.destroy(b)
	end)
	t.test('SAM uncovered arcs match original TS including enclosure, coincidence, tangency and wrap',function()
		for _, c in g.samCases do for i,circle in c.circles do
			local arcs=Sam.uncovered(circle,c.circles)
			t.eq(#arcs,#c.arcs[i])
			for j,arc in arcs do t.near(arc[1],c.arcs[i][j][1],1e-12); t.near(arc[2],c.arcs[i][j][2],1e-12) end
		end end
	end)
	t.test('SAM upgrade radius, operating/preview groups and colors match original TS',function()
		for _, c in g.collect do
			local units,order={},{}
			for _, u in c.units do
				local upgrade=if type(u.samUpgradeStartTick)=='number' then {startTick=u.samUpgradeStartTick,duration=u.samUpgradeDuration,
					startRange=u.samUpgradeStartRange,targetLevel=u.samUpgradeTargetLevel} else nil
				units[u.id]={id=u.id,type=u.unitType,owner=u.ownerID,tile=u.pos,level=u.level,active=u.isActive,samUpgrade=upgrade}
				table.insert(order,u.id)
			end
			local circles=Sam.collect(units,order,64,c.tick,1,{[2]=true},{[1]=1,[2]=1,[3]=3},c.ownerMode)
			t.eq(#circles,#c.circles)
			for i,circle in circles do
				for key,value in c.circles[i] do t.near(circle[key],value,1e-12,`{key} @ {c.tick}`) end
				t.eq(circle.owner,units[circle.id].owner,'adapter identity metadata follows the confirmed unit')
				t.ok(circle.offset==0 or circle.offset==1)
			end
		end
	end)
	t.test('construction, deletion and missile bars match 84 original TS states',function()
		for _, c in g.bars do
			local u={type=c.type,markedForDeletion=if c.mode=='delete' then 300 else false,
				underConstruction=c.mode=='build',constructionStartTick=if c.mode=='build' then 0 else nil,level=2,
				missileTimerQueue=if c.mode=='reload' then {0} else {}}
			local duration=if c.type=='City' then 20 elseif c.type=='SAM Launcher' then 300 else 100
			local value=Visual.progress(u,c.tick,90,300,duration)
			if type(c.value)=='number' then t.near(value,c.value,1e-12) else t.eq(value,nil) end
		end
	end)
	t.test('warship water pick/move, tie order, multi-select and capture cleanup',function()
		local units={[1]={type='Warship',owner=1,active=true,tile=10},[2]={type='Warship',owner=1,active=true,tile=12},
			[3]={type='Warship',owner=2,active=true,tile=11}}
		local selection=Selection.new()
		t.eq(selection:tap(11,64,false,units,{2,1,3},1).kind,'pass')
		local picked=selection:tap(11,64,true,units,{2,1,3},1)
		t.eq(picked.kind,'select'); t.eq(picked.ids[1],2)
		local move=selection:tap(0,64,true,units,{2,1,3},1)
		t.eq(move.kind,'move'); t.eq(move.ids[1],2); t.eq(#selection.ids,0)
		selection:box(units,{1,2,3},1,0,0,12,1,function(tile) return tile,0 end)
		t.eq(#selection.ids,2)
		units[2].owner=2; selection:prune(units,1); t.eq(#selection.ids,1)
		selection:toggleAll(units,{1,2,3},1); t.eq(#selection.ids,0)
		units[1].active=false; t.eq(selection:tap(10,64,true,units,{1,2,3},1).kind,'pass')
	end)
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local function setup():any
		local e=native(); local s=e.client()
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
		return e,s,r
	end
	t.test('singleton rails survive snapshot attachment, split signals and later destruction',function()
		local _,s,r=setup(); s.startTick=0
		s.railroads={[1]={0}}
		r:attachState(s)
		t.eq(r.scene.railTypes[0],1,'snapshot singleton at valid tile zero')
		s:applyDelta({tick=1,tiles=buffer.create(0),events={
			{type='RailroadConstructionEvent',id=2,tiles={130,131,132}},
		}})
		for _,tile in {130,131,132} do t.eq(r.scene.railTypes[tile],2,'horizontal before split') end
		-- RailNetwork._connectToExistingRails can split immediately before the
		-- last tile, leaving a confirmed one-tile tail and no orientation neighbour.
		s:applyDelta({tick=2,tiles=buffer.create(0),events={
			{type='RailroadSnapEvent',originalId=2,newId1=3,newId2=4,tiles1={130,131},tiles2={132}},
		}})
		t.eq(s.railroads[2],nil); t.eq(r.scene.railTypes[130],2); t.eq(r.scene.railTypes[131],2)
		t.eq(r.scene.railTypes[132],1,'singleton tail follows source vertical fallback')
		local camera=table.clone(r.camera); camera.scale=8; r:setCamera(camera)
		r:step(1e9,1e9); t.eq(r.scene.visibleRails,4,'all confirmed rail tiles draw')
		s:applyDelta({tick=3,tiles=buffer.create(0),events={
			{type='RailroadDestructionEvent',id=1},{type='RailroadDestructionEvent',id=4},
		}})
		t.eq(r.scene.railTypes[0],nil); t.eq(r.scene.railTypes[132],nil)
		r:step(1e9,1e9); t.eq(r.scene.visibleRails,2,'later signals still update the overlay')
		t.eq(next(s.units),nil,'reproduction needs no unit record or patch')
		r:destroy()
	end)
	t.test('name and troop fills use source dark shades, 48-unit ems and opaque territory outlines',function()
		-- Test source projection independently of Bruno's optional height cap.
		local e,s,r=setup()
		local policy=e.policy;local cap=policy.capNameScreenHeight;policy.capNameScreenHeight=false
		s.startTick=0
		s.players[2].type='NATION'
		s.players[3]={id='bot',smallID=3,name='Bot',type='BOT',troops=100,alive=true}
		table.insert(s.rosterOrder,3)
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='NATION'},
			{id='bot',smallID=3,playerType='BOT'}})
		s.names={[1]={x=20,y=20,size=40},[2]={x=30,y=30,size=40},[3]={x=40,y=40,size=40}}
		r:attachState(s)
		local camera=table.clone(r.camera); camera.scale,camera.offsetX,camera.offsetY=1.8,0,0
		r:setCamera(camera); r:step(1e9,1e9)
		for id,shade in {0,.3,.4} do
			local v=r.scene.nameViews[id]
			t.near(v.name.TextColor3.R,shade,1e-6); t.eq(v.troops.TextColor3,v.name.TextColor3)
			t.eq(v.name.TextStrokeTransparency,1); t.eq(v.troops.TextStrokeTransparency,1)
			t.near(v.name.TextSize*v.scale.Scale*r.scene.worldScale.Scale,86.4,1e-5); t.near(v.troops.TextSize*v.scale.Scale*r.scene.worldScale.Scale,51.84,1e-5)
			local c=r.core.palette[id].fill
			for line,stroke in v.strokes do
				t.near(stroke.Color.R,c.r,1e-6); t.near(stroke.Color.G,c.g,1e-6); t.near(stroke.Color.B,c.b,1e-6)
				t.eq(stroke.Transparency,0); t.near(stroke.Thickness*v.scale.Scale*r.scene.worldScale.Scale,86.4*.085*(if line==1 then 1 else .6),1e-6)
			end
			local offset=v.troops.Position.Y.Offset+v.troops.Size.Y.Offset/2-v.name.Size.Y.Offset/2
			t.near(offset*v.scale.Scale*r.scene.worldScale.Scale,36*1.8*1.1,1,'GUI offsets round to integer pixels')
		end
		camera.scale=4; r:setCamera(camera); r.scene.lastNameDraw=-1; r.scene.lastNameMaintenance=-1; r:step(1e9,1e9)
		local v=r.scene.nameViews[2]
		t.near(v.name.TextSize*v.scale.Scale*r.scene.worldScale.Scale,192,1e-12); t.near(v.troops.TextSize*v.scale.Scale*r.scene.worldScale.Scale,115.2,1e-12)
		t.near(v.strokes[1].Thickness*v.scale.Scale*r.scene.worldScale.Scale,192*.085,1e-12,'RoWorld outline follows text size')
		r:destroy()
		for _,o in e.objects do if o.Name=='NameOutline' then t.eq(o.destroyed,true) end end
		policy.capNameScreenHeight=cap
	end)
	t.test('tutorial spawn-ring hook retains only self after spawn and clears without a timer',function()
		local _,s,r=setup(); s.startTick=0
		r:setOwnSpawnRing(true); r:attachState(s)
		t.eq(#r.scene.effects.centers,1); t.eq(r.scene.effects.centers[1].kind,1)
		t.eq(r.scene.effects.centers[1].color.r,1); t.eq(r.scene.effects.centers[1].color.g,.84)
		t.eq(next(r.core.spawnDiscs),nil,'post-spawn enemy discs stay off')
		s.players[1].spawnTile=13; s.StatsChanged:Fire()
		t.eq(r.scene.effects.centers[1].x,13)
		r:setOwnSpawnRing(false); t.eq(#r.scene.effects.centers,0)
		r.scene:setSpawnPhase(true); t.eq(#r.scene.effects.centers,1); t.ok(next(r.core.spawnDiscs)~=nil)
		r.scene:setSpawnPhase(false); t.eq(#r.scene.effects.centers,0); t.eq(next(r.core.spawnDiscs),nil)
		r:destroy(); r:setOwnSpawnRing(true)
	end)
	t.test('local structure rim keeps owner colour; construction greys bypass darkening',function()
		local _,s,r=setup(); s.startTick=0
		s.units={[1]={id=1,type='City',owner=1,tile=100,active=true,level=1},
			[2]={id=2,type='City',owner=2,tile=200,active=true,level=1},
			[3]={id=3,type='City',owner=1,tile=300,active=true,level=1,underConstruction=true,constructionStartTick=0}}
		r:attachState(s); r:step(1e9,1e9)
		local own,other,building=r.scene.unitViews[1],r.scene.unitViews[2],r.scene.unitViews[3]
		local fill,edge=r.core.palette[1].fill,r.core.palette[2].border
		t.near(own.parts[1].ImageColor3.R,fill.r*.7,1e-6); t.near(own.parts[1].ImageColor3.G,fill.g*.7,1e-6)
		t.near(other.parts[1].ImageColor3.R,edge.r*.7,1e-6)
		t.near(building.parts[1].ImageColor3.R,127/255,1e-6); t.near(building.parts[2].ImageColor3.R,198/255,1e-6)
		for _,v in {own,other,building} do t.eq(v.parts[1].ImageTransparency,0); t.eq(v.parts[2].ImageTransparency,0) end
		r:destroy()
	end)
	t.test('server anchors stop local scans, copy data, ease updates and retain dead anchors',function()
		-- (Claude, 2026-11-10: deltas carry changed anchors packed, and the ids
		-- that went in namesGone; Replication wire format 2.)
		local Replication=H.require(H.shared().OpenFront.Replication)
		local _,s,r=setup()
		s.names={[1]={x=12,y=14,size=30},[2]={x=30,y=30,size=20}}
		r:attachState(s)
		t.eq(r.scene.nameAnchorMode,'server'); t.eq(r.scene.nameScan,nil); t.eq(r.scene.names[1].x,12)
		s.names[1].x=99; t.eq(r.scene.names[1].x,12)
		s:applyDelta({tick=1,tiles=buffer.create(0),names=Replication.encodeNames({{smallID=1,x=20,y=25,size=35},{smallID=2,x=30,y=30,size=20}})})
		t.eq(r.scene.nameTransitions[1].x,12); t.eq(r.scene.nameTransitions[1].target.x,20)
		s.players[2].alive=false; s.StatsChanged:Fire()
		r.scene:tilesChanged(); r:step(1e9,1e9)
		t.eq(r.scene.nameScan,nil); t.eq(r.scene.names[2].x,30)
		s:applyDelta({tick=2,tiles=buffer.create(0),namesGone={1,2}})
		t.eq(r.scene.nameAnchorMode,'server'); t.eq(next(r.scene.names),nil)
		r:destroy()
	end)
	t.test('relations, final records and construction config flow through actual ClientState signals',function()
		local _,s,r=setup()
		s.gameConfig={instantBuild=false}; s.tick=10; s.startTick=0
		s.units[1]={id=1,type='City',owner=1,tile=200,active=true,underConstruction=true,constructionStartTick=0,level=1}
		r:attachState(s); r:step(1e9,1e9)
		local bar=r.scene.unitViews[1].progress
		t.ok(bar.background.Visible); t.near(bar.fill.Size.X.Offset*r.scene.structureScale.Scale,6*r.camera.scale,1)
		s:applyDelta({tick=11,tiles=buffer.create(0),relations={{smallID=1,allies={2},embargoes={}}}})
		t.eq(r.scene.friendly[2],true); t.eq(buffer.readu8(r.core.relations,1024+2),1)
		s:applyDelta({tick=12,tiles=buffer.create(0),units={{id=9,type='Atom Bomb',owner=2,tile=0,lastTile=1,active=false,reachedTarget=true}},removed={9}})
		t.eq(#r.scene.effects.state.shockwaves,1); t.eq(r.scene.effects.state.shockwaves[1].x,0)
		s:applyDelta({tick=13,tiles=buffer.create(0),relations={{smallID=2,allies={},embargoes={1}}}})
		t.eq(buffer.readu8(r.core.relations,1024+2),2)
		r:destroy(); s.RelationsChanged:Fire({1}); s.NamesChanged:Fire()
	end)
	t.test('instant-build config suppresses zero-duration bars; validated preview draws without issuing actions',function()
		local e,s,r=setup()
		s.gameConfig={instantBuild=true}; s.startTick=0; s.tick=10
		s.units[1]={id=1,type='City',owner=1,tile=200,active=true,underConstruction=true,constructionStartTick=0,level=1}
		r:attachState(s); r:step(1e9,1e9); t.eq(r.scene.unitViews[1].progress,nil)
		r:setBuildPreview({ghostType='City',tileX=20.25,tileY=20.5,radiusTileX=20,radiusTileY=20,rangeRadius=30,
			ownerID=1,canBuild=true,canUpgrade=false,cost=125000,showCost=true,canAfford=true,ghostRailPaths={{100,101,102}}})
		r:step(1e9,1e9)
		t.ok(r.scene.ghostViews[1].root.Visible); t.ok(r.scene.ghostRange.Visible); t.eq(r.scene.ghostCost.Text,'125K')
		t.eq(#r.scene.ghostRails,2)
		r:setBuildPreview(nil); r:step(1e9,1e9)
		t.eq(r.scene.ghostViews[1].root.Visible,false); t.eq(r.scene.ghostRange.Visible,false)
		r:destroy(); for _, image in e.images do t.eq(image.destroyed,true) end
	end)
	t.test('native input adapter dispatches selection/move once and leaves build-mode taps to caller',function()
		local e,s,r=setup(); s.startTick=0
		s.units[1]={id=1,type='Warship',owner=1,tile=11,active=true}
		r:attachState(s)
		local taps,moves={},{}
		local allowed=true
		r:bindInput(e.playerGui,e.mapGui,function(tile) table.insert(taps,tile) end,function(ids,tile) table.insert(moves,{ids=ids,tile=tile}) end,function() return allowed end)
		local function tap(tile)
			local x,y=r:worldToScreen(tile%64+.5,math.floor(tile/64)+.5); e.mouseTap(x,y)
		end
		tap(11); t.eq(#taps,0); t.eq(#moves,0); t.eq(r.scene.selection.ids[1],1)
		tap(0); t.eq(#moves,1); t.eq(moves[1].ids[1],1); t.eq(moves[1].tile,0); t.eq(s.units[1].tile,11)
		allowed=false; tap(11); t.eq(taps[1],11); t.eq(#moves,1)
		r:destroy(); tap(0); t.eq(#moves,1); t.eq(#taps,1)
	end)
end
