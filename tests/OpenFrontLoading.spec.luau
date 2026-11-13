--!strict
-- First paint with confirmed unit/tile traffic already running behind the
-- cover. Native-property shim: not a Studio or device timing measurement.
return function(t)
	local fs,luau=require('@lune/fs'),require('@lune/luau')
	local source,replacements=fs.readFile('tests/OpenFrontEffectsHarness.luau'):gsub(
		'image.WritePixelsBuffer=function%(_,_,size,pixels%)',
		'image.WritePixelsBuffer=function(_,_,size,pixels) env.frameImages=env.frameImages or {}; env.frameImages[image]=true;')
	assert(replacements==1,'upload instrumentation was not installed')
	local native=luau.load(source)()
	t.test('first paint finishes when live updates alternate with quiet render frames',function()
		for _,cadence in {2,3} do
			local e=native(); local s=e.client(); s.width=1088; s.startTick=0; s.names={}
			s.tileState=buffer.create(1088*64*2)
			local terrain=buffer.create(1088*64)
			for tile=0,1088*64-1 do buffer.writeu8(terrain,tile,if tile%64<32 then 128 else 0) end
			local r=e.Renderer.new(e.instance('Frame'),terrain,1088,64,{autoStep=false,firstPaint='full'})
			r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
			r:attachState(s)
			local tick=0
			for frame=1,240 do
				if frame%cadence==0 then
					tick+=1
					for _,tile in {31,1055} do buffer.writeu16(s.tileState,tile*2,1+tick%2) end
					r:applyTileStates(s.tileState,{31,1055})
				end
				e.frameImages={}; r:step()
				local images=0; for _ in e.frameImages do images+=1 end
				t.ok(images<=1,'cadenced updates used a second displayed image')
				t.eq(r.root.Visible,r:isReady())
				if r:isReady() then break end
			end
			t.ok(r:isReady(),`ownership every {cadence} frames stalled loading: base={r.firstPaintBaseReady}, core={r.core.pending}, coast={r.coasts:ready()}, initial={r.coasts.raster.initial}, coastPending={r.coasts.raster.pendingCount}, scene={r.scene:isFirstPaintReady()}, settle={r.readyPending}, writes={r.firstPaintWrites}`)
			r:destroy()
		end
	end)
	t.test('a late confirmed snapshot supplies the held first-paint base',function()
		local e=native(); local s=e.client(); s.startTick=0; s.names={}
		local terrain=buffer.create(4096); buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,firstPaint='full'})
		for _=1,8 do r:step() end
		t.eq(r.firstPaintBaseReady,false); t.eq(r:isReady(),false); t.eq(r.root.Visible,false)
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'}})
		for tile=0,4095 do buffer.writeu16(s.tileState,tile*2,1) end
		r:applyTileStates(s.tileState,nil); r:attachState(s)
		for _=1,100 do r:step(); if r:isReady() then break end end
		t.ok(r:isReady()); t.eq(r.core.pending,0); t.eq(r.firstPaintWrites,1)
		t.eq(buffer.readu16(r.core.tileState,100*2),1)
		r:destroy()
	end)
	for _,width in {64,1088} do
		t.test(`full paint with {width}-wide live traffic finishes on both cold and repeat entry`,function()
			local e=native()
			for session=1,2 do
				local s=e.client(); s.width=width; s.startTick=0; s.names={}
				s.tileState=buffer.create(width*64*2)
				local terrain=buffer.create(width*64)
				for tile=0,width*64-1 do buffer.writeu8(terrain,tile,if tile%64<32 then 128 else 0) end
				local r=e.Renderer.new(e.instance('Frame'),terrain,width,64,{autoStep=false,firstPaint='full'})
				r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
				r:attachState(s)
				local readyCalls=0; r:onReady(function() readyCalls+=1 end)
				local held={}; local queuedDuringHold=false; local lastUpload=0; local refreshed=false
				for frame=1,240 do
					if frame==2 then
						for id=1,8 do s.units[id]={id=id,type=if id<=2 then 'Port' else 'Warship',owner=id%2+1,
							tile=100+id,active=true,level=1,health=50,maxHealth=100} end
					end
					if frame>=2 then
						for id=3,8 do local u=s.units[id]; u.lastTile=u.tile; u.tile=100+id+frame%20 end
						s.UnitsChanged:Fire({}, {}); s.UnitsMoved:Fire({3,4,5,6,7,8})
					end
					local changed={}
					for _,page in r.core.pages do
						local tile=page.x+31
						buffer.writeu16(s.tileState,tile*2,frame%2+1); table.insert(changed,tile)
					end
					r:applyTileStates(s.tileState,changed)
					s.tick+=1; s.TickApplied:Fire(s.tick)
					e.frameImages={}; local result=r:step()
					if r.firstPaintRefreshed~=refreshed then held={}; refreshed=r.firstPaintRefreshed end
					local images=0; for _ in e.frameImages do images+=1 end
					t.ok(images<=1,'more than one displayed image uploaded in a frame')
					if images>0 then lastUpload=frame end
					for _,page in r.core.pages do
						local pixels=buffer.tostring(page.pixels)
						if held[page.id] then t.ok(pixels==held[page.id],'completed base page repainted before reveal') end
						if r.firstPaintUploaded[page.id] then held[page.id]=pixels end
					end
					if r.firstPaintBaseReady and r.core.pending>0 then queuedDuringHold=true end
					if r:isReady() then
						t.ok(frame>lastUpload,'reveal must retain the no-upload settling frame')
						t.eq(result.atlasUpload,false); t.ok(r.scene:isFirstPaintReady()); t.ok(r.coasts:ready())
						break
					end
					t.eq(r.root.Visible,false,'partial first paint became visible')
				end
				t.ok(r:isReady(),`session {session}: continuous confirmed traffic pinned first paint`)
				t.eq(readyCalls,1); t.eq(r:loadProgress(),1); t.ok(queuedDuringHold,'exercise queued live changes')
				t.ok(r.firstPaintWrites>=#r.core.pages and r.firstPaintWrites<=2*#r.core.pages,'more than one preparation/final upload per page')
				t.eq(r.firstPaintBytes,0); t.eq(next(r.firstPaintBuffers),nil)
				for _=1,80 do r:step(1e9,1e9) end
				t.eq(r.core.pending,0,'queued live revisions did not resume after reveal')
				t.ok(buffer.tostring(r.core.tileState)==buffer.tostring(s.tileState),'confirmed changes were lost while held')
				local H=luau.load(fs.readFile('tests/harness.luau'))()
				local map=H.mount('src/client/Map/OpenFront','OpenFront')
				local Coast=H.require(map.CoastRaster)
				local fresh=Coast.new(r.coasts.raster.geometry,r.coasts.resolution,1e9)
				for _=1,#fresh.pages+2 do
					if not Coast.pending(fresh) then break end
					Coast.prepare(fresh,r.core,1e9,1e9)
				end
				t.eq(Coast.pending(fresh),false,'fresh coast reference did not finish')
				for id,page in fresh.pages do
					t.ok(buffer.tostring(page.pixels)==buffer.tostring(r.coasts.raster.pages[id].pixels),'coast colours missed held live revisions')
				end
				t.ok(r.coasts:ready()); t.eq(readyCalls,1)
				r:destroy()
				for _,image in e.images do t.eq(image.destroyed,true,'native image survived leave/rematch') end
			end
		end)
	end
end
