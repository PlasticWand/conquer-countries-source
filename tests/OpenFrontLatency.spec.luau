--!strict
-- Scheduling/lifecycle and exact pixel coverage; no native/device timing claims.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Core,Policy,Dirty,Masks=H.require(root.RasterCore),H.require(root.RenderPolicy),H.require(root.DeferredDirty),H.require(root.FalloutMasks)
	local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
	t.test('new own front rows cross both pages ahead of bulk repaint without losing old ages or final pixels',function()
		for _,deferred in {false,true} do
			local w,h=2048,96;local terrain=buffer.create(w*h);buffer.fill(terrain,0,128)
			local sink=raster.sink(w,h);local old=Policy.deferredOwnership;Policy.deferredOwnership=deferred
			local core=Core.new(terrain,w,h,sink.backend);Policy.deferredOwnership=old
			local roster={{id='a',smallID=1,playerType='HUMAN'},{id='b',smallID=2,playerType='HUMAN'}}
			Core.setRoster(core,roster);Core.setLocalPlayer(core,1)
			local states=buffer.create(w*h*2);for tile=0,w*h-1 do buffer.writeu16(states,tile*2,2) end
			Core.applyTileStates(core,states);while Core.hasPending(core) do Core.step(core,1e9,1e9) end
			Core.setViewport(core,{x0=0,y0=0,x1=w,y1=h})
			local refs={};for tile=0,w*h-1 do buffer.writeu16(states,tile*2,1);table.insert(refs,tile) end
			Core.applyTileStates(core,states,refs)
			local age=core.frames+1
			local tips={80*w+300,80*w+1400};local before={sink.pixel(300,80),sink.pixel(1400,80)}
			for _,tile in tips do buffer.writeu16(states,tile*2,1+16384) end
			Core.applyTileStates(core,states,tips)
			local arrived={}
			for frame=1,6 do
				table.clear(sink.writes);Core.step(core,1e9,64)
				local pages={};for _,id in sink.writes do pages[id]=true end;local n=0;for _ in pages do n+=1 end;t.ok(n<=1)
				for i,tile in tips do if sink.pixel(tile%w,math.floor(tile/w))~=before[i] then arrived[i]=true end end
			end
			t.ok(arrived[1] and arrived[2],`front did not pass bulk in mode {deferred}`)
			local m=Core.metrics(core);t.ok(m.recentOwnFrontUploadSamples>0)
			t.ok(m.recentOwnFrontUploadMaxFrames<=6,'front age must include confirmation/deferred time, separately from old bulk rows')
			t.ok(Core.hasPending(core),'front service must not erase the old transfer')
			local oldest=math.huge;for off=0,buffer.len(core.rowDirtySince)-4,4 do local v=buffer.readu32(core.rowDirtySince,off);if v>0 then oldest=math.min(oldest,v) end end
			t.ok(oldest<=age,'old dirty ages were rebased')
			while Core.hasPending(core) do Core.step(core,1e9,1e9) end
			local settled={};for i,page in core.pages do settled[i]=buffer.tostring(page.pixels) end
			Core.applyTileStates(core,states);t.eq(buffer.readstring(core.frontQueued,0,buffer.len(core.frontQueued)):find('[^%z]'),nil)
			while Core.hasPending(core) do Core.step(core,1e9,1e9) end
			for i,page in core.pages do t.eq(buffer.tostring(page.pixels),settled[i]) end
			Core.destroy(core);t.eq(buffer.len(core.frontDirtyRows),0);t.eq(buffer.len(core.frontRowSince),0)
		end
	end)
	t.test('normal turns service old foreign pixels despite a perpetually dirty own front in the same-age cohort',function()
		local w,h=128,64;local terrain=buffer.create(w*h);buffer.fill(terrain,0,128)
		local sink=raster.sink(w,h);local core=Core.new(terrain,w,h,sink.backend)
		Core.setRoster(core,{{id='a',smallID=1,playerType='HUMAN'},{id='b',smallID=2,playerType='HUMAN'}});Core.setLocalPlayer(core,1)
		local states=buffer.create(w*h*2)
		for tile=0,w*h-1 do buffer.writeu16(states,tile*2,if tile%w>=96 and math.floor(tile/w)>=32 then 1 else 2) end
		Core.applyTileStates(core,states);while Core.hasPending(core) do Core.step(core,1e9,1e9) end
		Core.setViewport(core,{x0=0,y0=0,x1=w,y1=h});local oldPixel=sink.pixel(0,0)
		buffer.writeu16(states,0,3);Core.applyTileStates(core,states,{0})
		local refs={};for y=32,63 do for x=96,127 do table.insert(refs,y*w+x) end end
		for frame=1,4 do
			for _,tile in refs do buffer.writeu16(states,tile*2,1+(if frame%2==1 then 16384 else 0)) end
			Core.applyTileStates(core,states,refs);Core.step(core,1e9,1)
		end
		t.ok(sink.pixel(0,0)~=oldPixel,'same-age priority partition starved the older foreign block')
		t.ok(Core.hasPending(core));Core.destroy(core)
	end)
	t.test('deferred small own work precedes old runs and bulk spans rotate without losing reservations',function()
		local d=Dirty.new(true,1000);d.width=2000
		for i=0,99 do t.ok(d:pushRun(i*2000,i*2000+255,true,1)) end
		local data=buffer.create(4096*4);for i=0,4095 do buffer.writeu32(data,i*4,250000+i) end
		d:pushBatch(data,0,4096,true,1);t.ok(d:push(500000,2,1,true,5,true))
		local visited={};d:step(function(item) table.insert(visited,item.tile) end,16,1e9,true)
		t.eq(visited[1],500000);t.ok(d.count>0)
		local bulkTiles=0;local iterations=0
		while d.count>0 do iterations+=1;t.ok(iterations<10000)
			d:step(function(item) if item.data then bulkTiles+=(item.last or item.tile)-item.tile+1 end end,1024,1e9,true)
		end
		t.eq(bulkTiles,4096);t.eq(d.batchBytes,0);t.eq(next(d.frontQueue),nil)
	end)
	t.test('bulk fallout invalidation handles sorted rings, unsorted edits and exact refreshed pixels within step quotas',function()
		local masks=Masks.new(256,256,64,2,15000);local states=buffer.create(256*256*2)
		for tile=0,256*256-1 do buffer.writeu16(states,tile*2,8192) end
		local m=masks:add(128*256+128,50,0)
		while m.remaining>0 do t.ok(masks:step(states,37)<=37) end;m.uploaded=m.revision
		local ring={};for y=60,196 do for x=60,196 do if (x-128)^2+(y-128)^2>51^2 then table.insert(ring,y*256+x) end end end
		local version=m.revision;masks:tilesChanged(ring);t.eq(m.revision,version,'bounding box overlap alone must not hide an unaffected glow')
		local edits=table.clone(ring);table.insert(edits,128*256+128);buffer.writeu16(states,(128*256+128)*2,0)
		masks:tilesChanged(edits);t.eq(m.revision,version+1);t.ok(m.remaining>0)
		while m.remaining>0 do t.ok(masks:step(states,37)<=37) end
		local fresh=Masks.new(256,256,64,2,15000);local expected=fresh:add(128*256+128,50,0)
		while expected.remaining>0 do fresh:step(states,1000) end
		t.eq(buffer.tostring(m.pixels),buffer.tostring(expected.pixels))
		table.sort(edits);buffer.writeu16(states,(128*256+128)*2,8192);masks:tilesChanged(edits)
		while m.remaining>0 do t.ok(masks:step(states,37)<=37) end
		fresh:clear();expected=fresh:add(128*256+128,50,0);while expected.remaining>0 do fresh:step(states,1000) end
		t.eq(buffer.tostring(m.pixels),buffer.tostring(expected.pixels));masks:clear()
	end)
	t.test('coast zoom reuses unparented high-water views within the existing cap and destroys all spares',function()
		local make=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))();local e=make();e.uis.TouchEnabled=true
		local w,h=256,256;local terrain=buffer.create(w*h)
		for tile=0,w*h-1 do buffer.writeu8(terrain,tile,if tile%w%8<4 then 128 else 5) end
		local s=e.client();s.width,s.height,s.startTick=w,h,0;s.tileState=buffer.create(w*h*2);s.names={}
		local r=e.Renderer.new(e.instance('Frame'),terrain,w,h,{autoStep=false,firstPaint='full'});r.coasts.api.now=function()return e.now end;r:attachState(s)
		for _=1,2000 do e.now+=1/60;r:step(1e9,1e9);if r:isReady() then break end end;t.ok(r:isReady())
		local fit=table.clone(r.camera);local creates=r.coasts.creates;t.ok(creates>32)
		local zoom=table.clone(fit);zoom.scale=12;r:setCamera(zoom)
		for _=1,30 do e.now+=1/60;r:step(1e9,1e9) end
		t.ok(#r.coasts.pool>32);local spares=table.clone(r.coasts.pool)
		for _,view in spares do t.eq(view.Parent,nil);t.eq(view.Visible,false) end
		for _=1,3 do
			r:setCamera(fit);for _=1,30 do e.now+=1/60;r:step(1e9,1e9);t.ok(r.coasts.viewCount+#r.coasts.pool<=e.policy.coastTouchViews) end
			r:setCamera(zoom);for _=1,30 do e.now+=1/60;r:step(1e9,1e9) end
		end
		t.eq(r.coasts.creates,creates);t.eq(r.coasts.deletes,0)
		r:destroy();t.eq(r.coasts,nil);for _,view in spares do t.eq(view.destroyed,true) end
	end)
	t.test('numeric fallout hot path retains exact source shader RGBA8 over terrain variants',function()
		local w,h=33,17;local terrain=buffer.create(w*h);local states=buffer.create(w*h*2)
		for tile=0,w*h-1 do buffer.writeu8(terrain,tile,tile%256);buffer.writeu16(states,tile*2,8192) end
		local sink=raster.sink(w,h);local core=Core.new(terrain,w,h,sink.backend);Core.applyTileStates(core,states)
		while Core.hasPending(core) do Core.step(core,1e9,1e9) end
		for tile=0,w*h-1 do
			local c=raster.Political.fill({owner=0,x=tile%w,y=math.floor(tile/w),defended=false,hovered=false,fallout=true},{r=0,g=0,b=0},{r=0,g=0,b=0},{borderType=0,relation=0})
			local bg=buffer.readu32(core.terrainLut,buffer.readu8(terrain,tile)*4);local rgb=4278190080
			for channel,value in {c.r,c.g,c.b} do rgb+=math.clamp(math.floor(value*255*c.a+bit32.band(bit32.rshift(bg,(channel-1)*8),255)*(1-c.a)+.5),0,255)*256^(channel-1) end
			t.eq(sink.pixel(tile%w,math.floor(tile/w)),rgb)
		end
		Core.destroy(core)
	end)
end
