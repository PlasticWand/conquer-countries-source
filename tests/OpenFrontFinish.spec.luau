--!strict
-- Confirmed-state lifecycle and bounded cosmetic work, not native GPU evidence.
return function(t)
	local fs,luau,roblox=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Defense,Masks,Fx=H.require(root.DefenseRanges),H.require(root.FalloutMasks),H.require(root.FxState)
	local function setup(touch:boolean?):any
		local e=native(); e.uis.TouchEnabled=touch==true
		local s=e.client(); s.startTick=0; s.names={[1]={x=20,y=25,size=30},[2]={x=40,y=40,size=30}}
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		return e,s,r
	end
	local function settle(r:any)
		for _=1,100 do r:step(1e9,1e9) end
	end
	t.test('label setting before attach hides one parent, defaults on, is repeatable and leaves map passes alone',function()
		local e,s,r=setup()
		t.eq(r.territoryLabelsVisible,true); r:setOwnSpawnRing(true); r:setTerritoryLabelsVisible(false); r:attachState(s); settle(r)
		t.eq(r.scene.layers.Names.Visible,false)
		t.eq(r.scene.layers.Ground.Visible,true); t.eq(r.scene.layers.Structures.Visible,true)
		t.ok(#r.scene.effects.centers>0,'own spawn ring remains enabled')
		r:setBuildPreview({ghostType='City',tileX=20,tileY=25,radiusTileX=20,radiusTileY=25,rangeRadius=30,ownerID=1,canBuild=true,canUpgrade=false})
		r:step(1e9,1e9); t.ok(r.scene.rangeViews.BuildRange.Visible)
		local count=#e.objects
		for _=1,100 do r:setTerritoryLabelsVisible(false) end
		t.eq(#e.objects,count); t.eq(r.scene.layers.Names.Visible,false)
		r:setTerritoryLabelsVisible(true); t.eq(r.scene.layers.Names.Visible,true)
		r:destroy(); r:setTerritoryLabelsVisible(false)
	end)
	t.test('name query reads displayed easing in screen pixels without half-tile offsets, including labels off',function()
		local _,s,r=setup(); r:attachState(s); settle(r)
		local function check()
			local view=r.scene.nameViews[1]
			local x,y=r:playerNameScreenPosition(1)
			local sx,sy=r:worldToScreen(view.sx/64,view.sy/64)
			t.near(x,sx,1e-4); t.near(y,sy,1e-4)
		end
		check(); r:setTerritoryLabelsVisible(false); check()
		r.scene:setNameAnchors({[1]={x=28,y=31,size=30}}); r:step(1e9,1e9); check()
		t.ok(r.scene.nameViews[1].sx~=28*64,'query does not jump to the target anchor')
		r.parent.AbsolutePosition=roblox.Vector2.new(27,39); r.parent:GetPropertyChangedSignal('AbsolutePosition'):Fire(); check()
		r:pan(10,0); check()
		t.eq(select(1,r:playerNameScreenPosition(999)),nil)
		s.players[1].alive=false; r.scene:setStats({s.players[1],s.players[2]}); r:step(1e9,1e9)
		t.eq(select(1,r:playerNameScreenPosition(1)),nil)
		r:destroy(); t.eq(select(1,r:playerNameScreenPosition(1)),nil)
	end)
	t.test('defense probes are bounded, use Euclidean inclusion and cache unrelated changes and troop-only attack updates',function()
		local d=Defense.new(256,256); local states=buffer.create(256*256*2)
		local units={[1]={type='Defense Post',tile=256*10+10,owner=2,active=true}}
		d:setUnits(units,3); d:setTargets({{outgoing=true,attacker=1,target=2,troops=50}},1)
		buffer.writeu16(states,(256*10+13)*2,1)
		local circles={}
		for _=1,100 do local before=d.visits; circles=d:step(states,2); t.ok(d.visits-before<=2) end
		t.eq(#circles,1); t.eq(circles[1].radius,3)
		local visits=d.visits
		d:setUnits(units,3); d:setTargets({{outgoing=true,attacker=1,target=2,troops=100}},1)
		d:tilesChanged({256*200+200}); d:step(states,2); t.eq(d.visits,visits)
		d:tilesChanged({256*10+12}); d:step(states,2); t.eq(d.visits,visits,'other nearby captures retain a valid owned witness')
		d:setTargets({{outgoing=true,attacker=1,target=2,troops=0,retreating=true}},1)
		d:step(states,2); t.eq(d.visits,visits,'confirmed outgoing record controls membership until it ends')
		buffer.writeu16(states,(256*10+13)*2,0); d:tilesChanged({256*10+13})
		for _=1,100 do circles=d:step(states,2) end; t.eq(#circles,0)
		buffer.writeu16(states,(256*13+13)*2,1); d:tilesChanged({256*13+13})
		for _=1,100 do circles=d:step(states,2) end; t.eq(#circles,0,'square corner is outside the circle')
		d:setTargets({{outgoing=false,attacker=2,target=1,troops=10}},1); d:step(states,2); t.eq(#d.circles,0)
		d:clear(); t.eq(next(d.cells),nil)
	end)
	t.test('bulk defense invalidation visits relevant circles once and retains surviving witnesses across cells',function()
		local d=Defense.new(512,256);local states=buffer.create(512*256*2)
		local units={}
		for id=1,80 do units[id]={type='Defense Post',tile=(20+math.floor((id-1)/16)*40)*512+10+(id-1)%16*30,owner=if id%3==0 then 3 else 2,active=true} end
		d:setUnits(units,12);d:setTargets({},1);d:step(states,1e9)
		local generations={};for id,p in d.posts do generations[id]=p.generation end
		local refs={};for y=0,160 do for x=0,180 do table.insert(refs,y*512+x) end end
		d:tilesChanged(refs);t.eq(#d.queue,0,'no outgoing attack, no range work')
		for id,p in d.posts do t.eq(p.generation,generations[id]) end
		for _,u in units do buffer.writeu16(states,u.tile*2,1) end
		d:setTargets({{outgoing=true,attacker=1,target=2}},1);d:step(states,1e9)
		local expected={}
		local changed={};for _,tile in refs do changed[tile]=true;buffer.writeu16(states,tile*2,0) end
		for id,p in d.posts do
			generations[id]=p.generation
			if d.active[id] then expected[id]=changed[p.witness]==true
			elseif p.owner==2 then
				for _,tile in refs do local dx,dy=tile%512-p.tile%512,math.floor(tile/512)-math.floor(p.tile/512)
					if dx*dx+dy*dy<=p.radius*p.radius then expected[id]=true;break end
				end
			end
		end
		d:tilesChanged(refs)
		for id,p in d.posts do t.eq(p.generation-generations[id],if expected[id] then 1 else 0,`post {id} invalidated once iff its relevant circle/witness changed`) end
		d:step(states,1e9)
		for _,circle in d.circles do t.eq(buffer.readu16(states,d.posts[circle.id].witness*2),1) end
		-- End the attack, change land, then reopen it. Skipping idle changes must
		-- not leave stale probes when the range becomes relevant again.
		d:setTargets({},1);d:step(states,1e9);buffer.fill(states,0,0);d:tilesChanged(refs)
		d:setTargets({{outgoing=true,attacker=1,target=2}},1);d:step(states,1e9);t.eq(#d.circles,0)
		d:clear()
	end)
	t.test('confirmed attack, ownership and post capture changes control retained red defense ranges',function()
		local _,s,r=setup()
		local own=64*30
		buffer.writeu16(s.tileState,own*2,1); r:applyTileStates(s.tileState)
		s.units[10]={id=10,type='Defense Post',owner=2,tile=64*30+30,active=true,level=1}
		s.attacks={{outgoing=true,attacker=1,target=2,troops=50}}
		r:attachState(s); settle(r)
		local f=r.scene.rangeViews.DefenseAttack10
		t.ok(f and f.Visible); t.eq(f.BackgroundColor3,roblox.Color3.fromRGB(255,75,69))
		t.near(f.Size.X.Offset,s:config():defensePostRange()*128,1e-4)
		local visits=r.scene.defense.visits
		s.units[10].health=100; s.UnitsChanged:Fire({s.units[10]},{}); settle(r); t.eq(r.scene.defense.visits,visits)
		buffer.writeu16(s.tileState,own*2,0); r:applyTileStates(s.tileState,{own}); settle(r); t.eq(f.Visible,false)
		buffer.writeu16(s.tileState,own*2,1); r:applyTileStates(s.tileState,{own}); settle(r)
		t.ok(r.scene.rangeViews.DefenseAttack10.Visible)
		s.attacks={}; s.AttacksChanged:Fire(); r:step(1e9,1e9); t.eq(f.Visible,false)
		s.attacks={{outgoing=true,attacker=1,target=2,troops=50}}; s.AttacksChanged:Fire(); settle(r)
		s.units[10].owner=1; s.UnitsChanged:Fire({s.units[10]},{}); r:step(1e9,1e9); t.eq(f.Visible,false)
		r:destroy(); t.eq(#s.attacks,1,'teardown never clears ClientState attacks')
	end)
	t.test('post destruction enlarges the explosion and adds three-second pooled smoke only for final inactive updates',function()
		local _,s,r=setup(true); s.units[10]={id=10,type='Defense Post',tile=64*30+30,owner=2,active=true}
		r:attachState(s); t.eq(#r.scene.effects.state.sprites,0)
		s.units[10].active=false; s.UnitsChanged:Fire({s.units[10]},{});
		local fx=r.scene.effects.state
		t.eq(#fx.sprites,5); t.eq(fx.sprites[1].kind,2); t.eq(fx.sprites[1].scale,2.5)
		for i=2,5 do t.eq(fx.sprites[i].lifetime,3000) end
		s.UnitsChanged:Fire({s.units[10]},{}); t.eq(#fx.sprites,5)
		fx:tick(fx.sprites[1].start+3001); t.eq(#fx.sprites,0)
		r:destroy()
		local _,snapshot,other=setup(true); snapshot.units[10]={id=10,type='Defense Post',tile=100,active=false,owner=2}
		other:attachState(snapshot); snapshot.UnitsChanged:Fire({snapshot.units[10]},{}); t.eq(#other.scene.effects.state.sprites,0)
		other:destroy()
	end)
	t.test('coarse fallout masks never fill a pixel containing a clean tile and invalidate cleared cells',function()
		local masks=Masks.new(32,32,8,2,15000); local states=buffer.create(32*32*2)
		for tile=0,32*32-1 do buffer.writeu16(states,tile*2,8192) end
		local m=masks:add(32*16+16,9,0); masks:add(32*12+12,5,0)
		for _=1,100 do t.ok(masks:step(states,7)<=7) end
		t.eq(m.remaining,0); local found=nil
		for index=0,63 do if buffer.readu32(m.pixels,index*4)~=0 then
			found=index
			local x,y=m.x+index%8*m.step,m.y+math.floor(index/8)*m.step
			for dy=0,m.step-1 do for dx=0,m.step-1 do
				t.ok(x+dx>=0 and y+dy>=0 and x+dx<32 and y+dy<32)
				t.ok((x+dx-m.cx)^2+(y+dy-m.cy)^2<=m.radius^2)
			end end
		end end
		t.ok(found~=nil); m.uploaded=m.revision
		local tile=(m.y+math.floor(found/8)*m.step)*32+m.x+found%8*m.step
		buffer.writeu16(states,tile*2,0); masks:tilesChanged({tile})
		t.ok(m.uploaded~=m.revision); t.eq(m.remaining,1)
		masks:step(states,7); t.eq(buffer.readu32(m.pixels,found*4),0)
		for i=1,20 do masks:add(i,5,i) end
		local count=0; for _ in masks.slots do count+=1 end; t.eq(count,2)
		masks:expire(20000); t.eq(next(masks.slots),nil)
	end)
	t.test('confirmed impacts produce clipped masks, hide dirty masks immediately and share one upload image per frame',function()
		local e,s,r=setup(true); e.recordUploads=true
		for tile=0,4095 do buffer.writeu16(s.tileState,tile*2,8192) end
		local hole=64*30+30; buffer.writeu16(s.tileState,hole*2,0); r:applyTileStates(s.tileState); r:attachState(s)
		local u={id=10,type='Atom Bomb',owner=2,tile=hole,active=false,reachedTarget=true}
		s.units[10]=u; s.UnitsChanged:Fire({u},{})
		local effects=r.scene.effects
		for _=1,120 do
			e.uploads={}; r:step(1e9,1e9)
			local images={}; for _,image in e.uploads do images[image]=true end
			local count=0; for _ in images do count+=1 end; t.ok(count<=1,'one displayed image per frame, including masks')
		end
		local m=effects.masks.slots[1]; t.ok(m and m.remaining==0); t.eq(m.uploaded,m.revision)
		local f=effects.maskViews[1]; t.ok(f.Visible); t.eq(effects.maskAtlas.Size,roblox.Vector2.new(256,256))
		local index=math.floor((30-m.y)/m.step)*128+math.floor((30-m.x)/m.step)
		t.eq(buffer.readu32(m.pixels,index*4),0,'clean impact-centre hole stays transparent')
		local clear=64*30+31
		buffer.writeu16(s.tileState,clear*2,0); r:applyTileStates(s.tileState,{clear}); t.eq(f.Visible,false)
		for _=1,8 do r:step(1e9,1e9) end
		local cleared=math.floor((30-m.y)/m.step)*128+math.floor((31-m.x)/m.step)
		t.eq(buffer.readu32(m.pixels,cleared*4),0); t.ok(f.Visible)
		local starts=m.start; effects:step(starts+15001); t.eq(f.Visible,false); t.eq(next(effects.masks.slots),nil)
		local atlas=effects.maskAtlas; r:destroy(); t.ok(atlas.destroyed)
	end)
	t.test('bomb types, intercepts, duplicate finals, global sprite caps and optional mask refusal',function()
		local options={spriteCap=24,maskCap=4,falloutLifetimeMs=15000,defenseExplosionScale=2.5,defenseSmokeLifetimeMs=3000}
		local fx=Fx.new(64,options)
		for id,kind in {'Atom Bomb','Hydrogen Bomb','MIRV Warhead','Mega Nuke'} do
			local u={id=id,type=kind,tile=100+id,active=false,reachedTarget=true}
			fx:unitUpdates({u},{},0); fx:unitUpdates({u},{},0)
		end
		t.eq(#fx.impacts,4)
		fx:unitUpdates({{id=5,type='Atom Bomb',tile=200,active=false,reachedTarget=false}},{},0); t.eq(#fx.impacts,4)
		fx:unitUpdates({}, {6},0); t.eq(#fx.impacts,4)
		for id=10,30 do fx:unitUpdates({{id=id,type='Defense Post',tile=id,active=false}},{},0) end
		for id=40,60 do fx:unitUpdates({{id=id,type='Warship',tile=id,active=false}},{},0) end
		local count=0; for _,e in fx.sprites do if e.kind>=6 and e.kind<=9 then count+=1 end end
		t.ok(count<=24); t.eq(fx.smokeCount,count)
		fx:tick(20000); t.eq(fx.smokeCount,0)
		local _,desktopState,desktop=setup(false); desktop:attachState(desktopState)
		t.eq(desktop.scene.effects.masks.cap,8); t.eq(desktop.scene.effects.state.options.spriteCap,48); desktop:destroy()
		local e,s,r=setup(true); e.failFallout=true; r:attachState(s)
		r.scene.effects.state:unitUpdates({{id=99,type='Atom Bomb',tile=200,active=false,reachedTarget=true}},{},os.clock()*1000)
		settle(r); t.eq(r.destroyed,false); t.eq(r.scene.effects.maskFailed,true)
		r:destroy()
	end)
end
