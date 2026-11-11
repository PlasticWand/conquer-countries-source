--!strict
return function(t)
	local fs,luau,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/serde')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Trails,Fx,Atlas=H.require(root.TrailManager),H.require(root.FxState),H.require(root.FxAtlas)
	local g=serde.decode('json',fs.readFile('tests/fixtures/OpenFrontEffects.json'))
	t.test('history trails match 45 original TS states including overlaps and final claimant cleanup',function()
		local trails=Trails.new(24,16)
		for tick,case in g.trailCases do
			local units,order={},{}
			for _, u in case.units do units[u.id]={id=u.id,type=u.unitType,owner=u.ownerID,tile=u.pos,lastTile=u.lastPos}; table.insert(order,u.id) end
			trails:update(units,order)
			for i,value in case.values do t.eq(trails.values[i-1] or 0,value,`tick {tick} tile {i-1}`) end
		end
		t.eq(next(trails.values),nil); t.eq(next(trails.counts),nil)
	end)
	t.test('all death mappings and deterministic nuke debris match original TS',function()
		for _, seed in g.seeds do t.eq(Fx.seededRandom(seed.value),seed.result) end
		for i,cfg in g.fxConfig do
			local row=Atlas.rows[i]
			t.eq(row[1],cfg.frameWidth); t.eq(row[4],cfg.frameCount); t.eq(row[5],cfg.frameDurationMs); t.eq(row[6],cfg.looping)
		end
		for _, case in g.fxCases do
			local fx=Fx.new(24)
			fx:deadUnit({type=case.kind,tile=123,reachedTarget=case.reachedTarget},1000)
			t.eq(#fx.sprites,#case.sprites,case.kind)
			for i,s in case.sprites do
				local a=fx.sprites[i]
				for key,expected in {x=s.x,y=s.y,kind=s.fxType,start=s.startMs,lifetime=s.lifetimeMs,fadeIn=s.fadeIn,fadeOut=s.fadeOut} do t.eq(a[key],expected,`{case.kind} {i} {key}`) end
			end
			if case.kind=='MIRV' or case.kind=='SAMMissile' then t.eq(#fx.shockwaves,0) end
		end
	end)
	t.test('confirmed resting nuke heads catch up despite stale ClientState lastTile',function()
		local trails=Trails.new(24,16)
		local unit={id=1,type='Atom Bomb',owner=1,tile=5,lastTile=4}
		trails:update({[1]=unit},{1},{[1]=true})
		t.eq(trails.values[4],4097); t.eq(trails.values[5],nil)
		trails:update({[1]=unit},{1},{})
		t.eq(trails.values[5],4097,'source resets lastPos on a resting tick')
		unit.tile,unit.lastTile=6,5
		trails:update({[1]=unit},{1},{[1]=true}); t.eq(trails.values[6],nil)
		trails:update({[1]=unit},{1},{}); t.eq(trails.values[6],4097)
		trails:update({},{}); t.eq(next(trails.values),nil)
	end)
	t.test('FX atlas decodes losslessly; generated spawn masks stay in bounds',function()
		local atlas=Atlas.rgba()
		local meta=serde.decode('json',fs.readFile('tests/fixtures/OpenFrontFxAtlas.json'))
		t.eq(serde.hash('sha256',buffer.readstring(atlas,0,meta.rgbaBytes)),meta.rgbaSha256)
		t.eq(buffer.len(atlas),540*306*4)
		t.eq(buffer.readu8(atlas,(242*540+539)*4+3),0)
	end)
	t.test('bonuses retain signs and gold units; FX ages expire without restarting',function()
		for _, gold in g.gold do t.eq(Fx.formatGold(gold.value),gold.text,`gold {gold.value}`) end
		local fx=Fx.new(64)
		fx:bonuses({{tile=0,gold=0},{tile=0,gold=25000},{tile=65,gold=-1500000}},1000)
		t.eq(#fx.popups,2); t.eq(fx.popups[1].text,'+ 25.0K'); t.eq(fx.popups[1].x,0); t.eq(fx.popups[1].y,-3)
		t.eq(fx.popups[2].text,'- 1.5M')
		fx:deadUnit({type='Atom Bomb',tile=0,reachedTarget=false},1000)
		t.eq(fx.shockwaves[1].radius,40); t.eq(fx.shockwaves[1].lifetime,800)
		local frame,alpha=Fx.sampleSprite(fx.sprites[1],1139)
		t.eq(frame,1); t.eq(alpha,1)
		fx:tick(1800); t.eq(#fx.shockwaves,0); t.eq(#fx.sprites,0); t.eq(#fx.popups,2)
		fx:tick(2500); t.eq(#fx.popups,0)
	end)
	t.test('conquest flags and stationary gold match original TS emission, frame, fades and expiry',function()
		for _,case in g.conquestCases do
			local fx=Fx.new(64)
			fx:conquests({case.event},1000)
			t.eq(#fx.sprites,#case.sprites); t.eq(#fx.popups,#case.popups)
			for i,expected in case.sprites do
				local actual=fx.sprites[i]
				for key,value in {x=expected.x,y=expected.y,kind=expected.fxType,start=expected.startMs,
					lifetime=expected.lifetimeMs,fadeIn=expected.fadeIn,fadeOut=expected.fadeOut} do t.eq(actual[key],value,key) end
			end
			for i,expected in case.popups do
				local actual=fx.popups[i]
				t.eq(actual.text,expected.text); t.eq(actual.x,expected.x); t.eq(actual.y,expected.y)
				t.eq(actual.start,expected.startMs); t.eq(actual.lifetime,expected.lifetimeMs); t.eq(actual.riseSpeed,0)
			end
			for _,sample in case.samples do
				fx:tick(sample.now); t.eq(#fx.sprites,sample.count)
				if sample.count>0 then
					local frame,alpha=Fx.sampleSprite(fx.sprites[1],sample.now)
					t.eq(frame,sample.frame); t.near(alpha,sample.alpha/255,1e-12)
				end
			end
		end
	end)
	t.test('spawn masks and trails recompose across page seams, owner changes and final cleanup',function()
		local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
		local Core=raster.Core
		local terrain=buffer.create(1025*24); buffer.fill(terrain,0,128)
		local sink=raster.sink(1025,24)
		local core=Core.new(terrain,1025,24,sink.backend)
		Core.setRoster(core,{{id='human',smallID=1,playerType='HUMAN'}})
		Core.setSpawnDiscs(core,{{x=1023,y=10,owner=1}}); raster.drain(core)
		local color=core.palette[1].fill
		local packed=sink.pixel(1023,10)
		t.eq(bit32.band(packed,255),math.floor(color.r*255+.5))
		t.eq(sink.pixel(1023,10),sink.pixel(1024,10))
		local states=buffer.create(1025*24*2); buffer.writeu16(states,(10*1025+1023)*2,1)
		Core.applyTileStates(core,states,{10*1025+1023}); raster.drain(core)
		t.ok(sink.pixel(1023,10)~=sink.pixel(1024,10),'owned pixels no longer get an enemy disc')
		Core.setSpawnDiscs(core,{}); raster.drain(core)
		local before=sink.pixel(1024,10)
		Core.applyTrails(core,{[10*1025+1024]=1},{10*1025+1024}); raster.drain(core)
		t.ok(before~=sink.pixel(1024,10))
		for channel,c in {color.r,color.g,color.b} do
			local base=bit32.band(bit32.rshift(before,(channel-1)*8),255)
			local expected=math.floor(c*255*.588+base*(1-.588)+.5)
			t.eq(bit32.band(bit32.rshift(sink.pixel(1024,10),(channel-1)*8),255),expected)
		end
		Core.applyTrails(core,{},{10*1025+1024}); raster.drain(core)
		t.eq(sink.pixel(1024,10),before); t.eq(next(core.overlayRows),nil)
		Core.destroy(core)
	end)
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	t.test('staged conquests merge before the stamp, cap to one sequence and preserve late-event age',function()
		local fx=Fx.new(64,{stagedConquests=true})
		fx:conquests({{x=20,y=25,gold=100},{x=40,y=45,gold=200}},1000)
		t.eq(#fx.sprites,1); t.eq(#fx.popups,1); t.eq(fx.conquestMoment.count,2)
		t.eq(fx.sprites[1].x,20); t.eq(fx.popups[1].text,'+ 300'); t.eq(fx.popups[1].start,1650)
		fx:conquests({{x=50,y=55,gold=400}},1100)
		t.eq(fx.conquestMoment.count,3); t.eq(fx.popups[1].text,'+ 700'); t.eq(#fx.sprites,1)
		fx:conquests({{x=10,y=15,gold=5}},1400)
		t.eq(fx.conquestMoment.count,1); t.eq(fx.conquestMoment.x,10); t.eq(#fx.popups,1); t.eq(#fx.sprites,1)
		fx:tick(2301); t.eq(#fx.sprites,0); t.eq(#fx.popups,1)
		fx:tick(3900); t.eq(fx.conquestMoment,nil); t.eq(#fx.popups,0)
		fx:conquests({{x=1,y=2,gold=10,tickAge=12}},5000)
		t.eq(fx.conquestMoment.start,3800); t.eq(#fx.sprites,0); t.eq(fx.popups[1].start,4450)
		fx:clearConquests(); fx:conquests({{x=1,y=2,gold=10,tickAge=25}},5000)
		t.eq(fx.conquestMoment,nil); t.eq(#fx.popups,0)
	end)

	t.test('neutral conquest stamp precedes gold, reuses GUI and clears on snapshot without extra uploads',function()
		local roblox=require('@lune/roblox')
		local e=native(); local s=e.client(); s.startTick=0
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		r:attachState(s); r.scene:conquests({{x=20,y=25,gold=125000}}); r:step(1e9,1e9)
		local effects=r.scene.effects; local moment=effects.state.conquestMoment; local start=moment.start
		e.recordUploads=true; e.uploads={}; local images=#e.images
		effects:step(start+100); t.eq(effects.conquestStamp,nil); t.eq(#effects.popups,0)
		effects:step(start+200); local stamp=effects.conquestStamp
		t.ok(stamp.Visible); t.eq(stamp.Text,'CONQUERED'); t.eq(stamp.Font,roblox.Enum.Font.Oswald)
		t.eq(stamp.TextColor3,roblox.Color3.fromRGB(38,37,31)); t.eq(#effects.popups,0)
		effects:step(start+700); t.ok(effects.popups[1].Visible); t.eq(effects.popups[1].Name,'ConquestGold')
		t.eq(#e.images,images); t.eq(#e.uploads,0)
		s.Snapshot:Fire(); t.eq(stamp.Visible,false); t.eq(effects.state.conquestMoment,nil)
		t.eq(#effects.state.sprites,0); t.eq(#effects.state.popups,0); t.eq(effects.popups[1].Visible,false)
		r.scene:conquests({{x=20,y=25,gold=1},{x=30,y=35,gold=2}})
		effects:step(effects.state.conquestMoment.start+200)
		t.eq(effects.conquestStamp,stamp); t.eq(stamp.Text,'CONQUERED x2')
		s.winner='me'; s.PhaseChanged:Fire(); t.eq(stamp.Visible,false); t.eq(effects.state.conquestMoment,nil)
		r:destroy(); t.ok(stamp.destroyed)
	end)

	t.test('own confirmed conquests resolve retained dead name anchors; gold stays still and teardown disconnects',function()
		local e=native(); local s=e.client(); s.startTick=0
		-- Exercise the current ClientState generic event path without changing
		-- the Claude-owned replication allowlist in this round.
		s.names={[2]={x=20,y=25,size=30}}; s.players[2].alive=false
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		r:attachState(s); t.eq(#r.scene.effects.state.sprites,0)
		s:applyDelta({tick=1,tiles=buffer.create(0),events={
			{type='ConquestEvent',conquerorId='other',conqueredId='me',gold=100},
			{type='ConquestEvent',conquerorId='me',conqueredId='unknown',gold=100},
			{type='ConquestEvent',conquerorId='me',conqueredId='other',gold=125000}}})
		local effects=r.scene.effects
		t.eq(#effects.state.sprites,1); t.eq(#effects.state.popups,1)
		local flag,popup=effects.state.sprites[1],effects.state.popups[1]
		t.eq(flag.kind,11); t.eq(flag.x,20); t.eq(flag.y,25); t.eq(popup.y,33)
		r:step(1e9,1e9)
		effects:step(popup.start+50)
		local view=effects.popups[1]; t.eq(view.Name,'ConquestGold'); local position=view.Position
		effects:step(popup.start+600); t.eq(view.Position,position,'conquest text must not rise like a port bonus')
		t.near(view.TextTransparency,600/popup.lifetime,1e-6,'staged gold fades after its delayed arrival')
		r:destroy(); s.DiplomacyEvents:Fire({{type='ConquestEvent',conquerorId='me',conqueredId='other',gold=1}})
		t.eq(#effects.state.sprites,0); t.eq(#effects.state.popups,0)
	end)
	t.test('ClientState bonus/inactive signals reach renderer once; snapshots and removals invent no FX',function()
		local e=native(); local s=e.client()
		s.units[1]={id=1,type='Atom Bomb',tile=100,lastTile=99,owner=1,active=false,reachedTarget=true}
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
		r:attachState(s)
		t.eq(#r.scene.effects.state.sprites,0)
		s:applyDelta({tick=0,tiles=buffer.create(0),units={s.units[1]},removed={}})
		t.eq(#r.scene.effects.state.sprites,0,'inactive snapshot records are not replayed as fresh deaths')
		local dead={id=2,type='Hydrogen Bomb',tile=200,lastTile=199,owner=2,active=false,reachedTarget=false}
		s:applyDelta({tick=1,tiles=buffer.create(0),units={dead},removed={},events={{type='BonusEvent',tile=0,player='me',gold=25000}}})
		t.eq(#r.scene.effects.state.shockwaves,1); t.eq(#r.scene.effects.state.popups,1)
		s:applyDelta({tick=2,tiles=buffer.create(0),units={dead},removed={}})
		t.eq(#r.scene.effects.state.shockwaves,1)
		s:applyDelta({tick=3,tiles=buffer.create(0),units={},removed={1,2}})
		t.eq(#r.scene.effects.state.shockwaves,1)
		s:applyDelta({tick=4,tiles=buffer.create(0),units={{id=3,type='Atom Bomb',tile=300,owner=1,active=true}},removed={}})
		s:applyDelta({tick=5,tiles=buffer.create(0),units={},removed={3}})
		t.eq(#r.scene.effects.state.shockwaves,1,'bare removal cannot establish a nuke impact')
		s:applyDelta({tick=6,tiles=buffer.create(0),units={{id=4,type='Atom Bomb',tile=301,owner=1,active=false,reachedTarget=true}},removed={4}})
		t.eq(#r.scene.effects.state.shockwaves,2,'a final inactive record can accompany same-tick removal')
		local first=r:step(1e9,1e9)
		t.eq(first.atlasUpload,true); t.eq(first.uploads,0,'atlas construction reserves the dynamic-image slot')
		t.ok(r.scene.effects.atlas~=nil)
		local effects=r.scene.effects
		r:destroy(); r:destroy()
		s.Bonus:Fire({{tile=0,gold=100}}); s.TickApplied:Fire(4)
		t.eq(#effects.state.popups,0)
		for _, image in e.images do t.eq(image.destroyed,true) end
		for _, o in e.objects do if o.Parent then t.eq(o.destroyed,true,o.Name) end end
	end)
	t.test('spawn uses human discs, gold self glow, team filter, relocation and phase cleanup',function()
		local e=native(); local s=e.client()
		s.players[3]={id='nation',smallID=3,name='Nation',type='NATION',spawnTile=200,alive=true}
		table.insert(s.rosterOrder,3)
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'},{id='nation',smallID=3,playerType='NATION'}})
		r:attachState(s)
		t.eq(#r.scene.effects.centers,1); t.eq(r.scene.effects.centers[1].color.g,.84)
		t.eq(r.core.spawnDiscs[100],2)
		s.players[2].team='Blue'; s.players[1].team='Blue'; s.StatsChanged:Fire()
		t.eq(next(r.core.spawnDiscs),nil); t.eq(#r.scene.effects.centers,2)
		s.players[1].spawnTile=65; s.StatsChanged:Fire(); t.eq(r.scene.effects.centers[2].x,1)
		r:step(1e9,1e9); t.eq(#r.scene.effects.glows,2)
		s:applyDelta({tick=1,tiles=buffer.create(0),startTick=1})
		t.eq(#r.scene.effects.centers,0); t.eq(next(r.core.spawnDiscs),nil)
		r:destroy()
	end)
	t.test('FX allocation refusal frees previous image allocations and stops frame scheduling',function()
		local e=native(); local s=e.client(); local errors={}
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{onError=function(err) table.insert(errors,err) end})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
		r:attachState(s); e.failFx=true
		e.render:Fire(); t.eq(r.destroyed,true); t.eq(#errors,1)
		e.render:Fire(); t.eq(#errors,1)
		for _, image in e.images do t.eq(image.destroyed,true) end
	end)
end
