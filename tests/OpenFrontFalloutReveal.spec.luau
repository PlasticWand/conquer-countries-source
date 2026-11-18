--!strict
-- Real RGBA sink copies under deliberately small work slices. No native/GPU claim.
local fs,luau=require('@lune/fs'),require('@lune/luau')
local H=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
local Core=H.Core
local roster={{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='NATION'}}
local function setup(w:number,h:number):any
	local terrain,states=buffer.create(w*h),buffer.create(w*h*2)
	buffer.fill(terrain,0,128)
	for tile=0,w*h-1 do buffer.writeu16(states,tile*2,1) end
	local sink=H.sink(w,h)
	local core=Core.new(terrain,w,h,sink.backend);Core.setRoster(core,roster)
	Core.applyTileStates(core,states);H.drain(core,1e9)
	local records={};local write=sink.backend.write
	sink.backend.write=function(page,x,y,ww,hh,pixels)
		table.insert(records,{page=page.id,x=x,y=y,w=ww,h=hh})
		write(page,x,y,ww,hh,pixels)
	end
	return {core=core,states=states,sink=sink,records=records,w=w,h=h,terrain=terrain}
end
local function blast(a:any,cx:number,cy:number,inner:number,outer:number,reverse:boolean?):{number}
	local changed={}
	for y=math.max(0,cy-outer),math.min(a.h-1,cy+outer) do
		for x=math.max(0,cx-outer),math.min(a.w-1,cx+outer) do
			local d=(x-cx)^2+(y-cy)^2
			if d<=inner^2 or (d<=outer^2 and (x*17+y*31)%2==0) then
				local tile=y*a.w+x
				if buffer.readu16(a.states,tile*2)~=8192 then
					buffer.writeu16(a.states,tile*2,8192);table.insert(changed,tile)
				end
			end
		end
	end
	if reverse then table.sort(changed,function(a,b) return a>b end) end
	Core.applyTileStates(a.core,a.states,changed)
	return changed
end
local function image(a:any,id:number):string return buffer.tostring(a.sink.images[id].pixels) end
local function equalFresh(t:any,a:any)
	local b=setup(a.w,a.h)
	Core.setLocalPlayer(b.core,a.core.localPlayer)
	Core.applyTileStates(b.core,a.states);H.drain(b.core,1e9)
	for id in a.core.pages do t.ok(image(a,id)==image(b,id),`page {id} differs from fresh confirmed state`) end
	Core.destroy(b.core)
end
return function(t:any)
	t.test('Hydrogen burst stays completely old through partial block work then commits the exact full blob',function()
		local a=setup(320,256);local old=image(a,1);local native=a.sink.allocatedBytes
		local changed=blast(a,160,128,80,100)
		t.ok(#changed>20000);t.eq(#a.core.falloutReveal.regions,1)
		local turns,hidden=0,0
		while Core.hasPending(a.core) do
			turns+=1;t.ok(turns<160,'burst did not drain within row-derived bound')
			table.clear(a.records);local result=Core.step(a.core,1e9,512)
			t.ok(result.pixels<=543,'composition exceeded pixel slice plus one 32px row')
			if a.core.falloutReveal.commits==0 then t.eq(image(a,1),old,'partial dirty blocks became visible');hidden+=1 end
			for _,r in a.records do t.ok(r.w*r.h<=65536,'unbounded atomic native write') end
		end
		t.ok(hidden>4);t.eq(a.core.falloutReveal.commits,1)
		t.eq(#a.records,1);t.eq(a.sink.allocatedBytes,native,'a second native image was allocated')
		t.eq(buffer.len(a.core.falloutReveal.scratch),256*256*4)
		equalFresh(t,a);Core.destroy(a.core)
	end)

	t.test('Atom and overlapping fallout merge while later owner/fallout edits remain authoritative',function()
		local a=setup(192,160);local old=image(a,1)
		blast(a,80,80,12,30,true)
		for _=1,3 do Core.step(a.core,1e9,64) end
		t.eq(image(a,1),old)
		blast(a,90,80,12,30);t.eq(#a.core.falloutReveal.regions,1)
		local center=80*a.w+80
		buffer.writeu16(a.states,center*2,2);buffer.writeu16(a.states,0,2)
		Core.applyTileStates(a.core,a.states,{center,0})
		t.eq(buffer.readu16(a.core.tileState,center*2),2,'confirmed state was delayed with presentation')
		local before=a.sink.pixel(0,0);local progressed=false
		for _=1,300 do
			Core.step(a.core,1e9,64)
			if a.sink.pixel(0,0)~=before and #a.core.falloutReveal.regions>0 then progressed=true end
			if not Core.hasPending(a.core) then break end
		end
		t.ok(progressed,'unrelated live updates were held behind the blast')
		t.eq(Core.hasPending(a.core),false);equalFresh(t,a);Core.destroy(a.core)
	end)

	t.test('cross-page impacts retain the one-displayed-image-per-frame rule and coherent page pieces',function()
		local a=setup(1152,256);local old={image(a,1),image(a,2)}
		Core.setViewport(a.core,{x0=880,y0=0,x1=1024,y1=256}) -- other page is offscreen
		blast(a,1000,128,80,100)
		t.eq(#a.core.falloutReveal.regions,2)
		local committed={};local commitFrames={}
		for frame=1,160 do
			table.clear(a.records);Core.step(a.core,1e9,1024)
			local page=nil
			for _,r in a.records do
				if page then t.eq(r.page,page,'two displayed images updated in one frame') end
				page=r.page;committed[r.page]=true;t.ok(r.w*r.h<=65536)
			end
			if page then
				t.eq(a.core.pending,0,'one page revealed before the rest of this impact was prepared')
				table.insert(commitFrames,frame)
			end
			for id=1,2 do if not committed[id] then t.eq(image(a,id),old[id],'partial page piece leaked') end end
			if not Core.hasPending(a.core) then break end
		end
		t.eq(Core.hasPending(a.core),false);t.eq(a.core.falloutReveal.commits,2)
		t.eq(commitFrames[2],commitFrames[1]+1,'cross-page presentation did not use consecutive image slots')
		equalFresh(t,a);Core.destroy(a.core)
	end)

	t.test('disabled staging, oversized batches and capacity overflow retain bounded eventual progress',function()
		local a=setup(320,256);a.core.falloutReveal.enabled=false
		blast(a,160,128,80,100);t.eq(#a.core.falloutReveal.regions,0);H.drain(a.core,1e9);equalFresh(t,a)
		a.core.falloutReveal.enabled=true
		Core.applyTileStates(a.core,a.states)
		H.drain(a.core,1e9)
		-- A single batch spanning opposite map corners cannot fit the native-write cap.
		local changed={}
		for y=0,a.h-1 do for x=0,a.w-1 do
			local tile=y*a.w+x
			if buffer.readu16(a.states,tile*2)~=8192 then buffer.writeu16(a.states,tile*2,8192);table.insert(changed,tile) end
		end end
		Core.applyTileStates(a.core,a.states,changed)
		t.eq(a.core.falloutReveal.fallbacks,1);t.eq(#a.core.falloutReveal.regions,0)
		H.drain(a.core,1e9);equalFresh(t,a)
		local reveal=a.core.falloutReveal
		reveal.capacity=1
		reveal:add(a.core.pages[1],10,10,20,20,a.core.frames)
		reveal:add(a.core.pages[1],280,200,290,210,a.core.frames)
		t.eq(#reveal.regions,1);t.eq(reveal.fallbacks,2)
		H.drain(a.core,1e9);Core.destroy(a.core)
		t.eq(#reveal.regions,0);t.eq(buffer.len(reveal.scratch),0)
	end)

	t.test('snapshots discard old staging and reentrant commits retain newly dirtied rows',function()
		local a=setup(192,160)
		blast(a,80,80,12,30);Core.step(a.core,1e9,64)
		t.ok(#a.core.falloutReveal.regions>0)
		Core.applyTileStates(a.core,a.states);t.eq(#a.core.falloutReveal.regions,0);H.drain(a.core,1e9)
		local write=a.sink.backend.write;local fired=false
		a.sink.backend.write=function(page,x,y,w,h,pixels)
			write(page,x,y,w,h,pixels)
			if not fired and w*h>1024 then
				fired=true;local tile=80*a.w+130
				buffer.writeu16(a.states,tile*2,2);Core.applyTileStates(a.core,a.states,{tile})
			end
		end
		blast(a,130,80,12,30);H.drain(a.core,1e9)
		t.ok(fired);equalFresh(t,a);Core.destroy(a.core)
	end)

	t.test('small ongoing edits inside the staged border do not require a globally quiet map',function()
		local a=setup(320,256)
		Core.setLocalPlayer(a.core,1);Core.setViewport(a.core,{x0=0,y0=0,x1=320,y1=256})
		blast(a,160,128,80,100)
		local tile=10*a.w+40 -- clean land in the staged block-aligned margin
		for frame=1,400 do
			if frame%3==0 then
				buffer.writeu16(a.states,tile*2,1+frame%2);Core.applyTileStates(a.core,a.states,{tile})
			end
			Core.step(a.core,1e9,512)
			if #a.core.falloutReveal.regions==0 then break end
		end
		t.eq(#a.core.falloutReveal.regions,0,'live edits indefinitely restarted the reveal')
		H.drain(a.core,1e9);equalFresh(t,a);Core.destroy(a.core)
	end)

	t.test('the actual renderer sink keeps one native image per step during a staged reveal',function()
		local e=H.adapter();local w,h=160,128
		local terrain,states=buffer.create(w*h),buffer.create(w*h*2);buffer.fill(terrain,0,128)
		for tile=0,w*h-1 do buffer.writeu16(states,tile*2,1) end
		local r=e.Renderer.new(e.parent,terrain,w,h,{autoStep=false,coasts=false})
		r:setRoster(roster);r:applyTileStates(states)
		while Core.hasPending(r.core) do r:step(1e9,1e9) end
		local changed={}
		for y=40,87 do for x=40,87 do
			local tile=y*w+x;buffer.writeu16(states,tile*2,8192);table.insert(changed,tile)
		end end
		r:applyTileStates(states,changed);t.eq(#r.core.falloutReveal.regions,1)
		local frames=0
		while Core.hasPending(r.core) do
			frames+=1;t.ok(frames<160);table.clear(e.writes);r:step(1e9,128)
			local first=e.writes[1]
			for _,image in e.writes do t.eq(image,first) end
		end
		t.eq(r.core.falloutReveal.commits,1);t.eq(#e.images,1)
		r:destroy()
	end)

	t.test('the loading cover retains its existing first-paint path without live reveal gates',function()
		local e=H.adapter();local w,h=96,64
		local terrain,states=buffer.create(w*h),buffer.create(w*h*2);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.parent,terrain,w,h,{autoStep=false,firstPaint='full',coasts=false})
		-- A base page may have finished while other pages/scene are still loading.
		-- Drive the real core to that checkpoint, retaining the adapter's cover.
		Core.applyTileStates(r.core,states);H.drain(r.core,1e9)
		t.eq(r.core.pages[1].initialized,true);t.eq(r:isReady(),false)
		local changed={}
		for y=16,47 do for x=16,47 do
			local tile=y*w+x;buffer.writeu16(states,tile*2,8192);table.insert(changed,tile)
		end end
		r:applyTileStates(states,changed)
		t.eq(#r.core.falloutReveal.regions,0)
		t.eq(buffer.readu16(r.core.tileState,(16*w+16)*2),8192)
		t.eq(r.root.Visible,false);r:destroy()
	end)

	t.test('a newly dirty cross-page piece releases presentation priority for another live front',function()
		local a=setup(1152,256)
		Core.setLocalPlayer(a.core,1);H.drain(a.core,1e9)
		Core.setViewport(a.core,{x0=0,y0=0,x1=1152,y1=256})
		blast(a,1000,128,80,100)
		for _=1,160 do
			Core.step(a.core,1e9,1024)
			if a.core.falloutReveal.commits==1 then break end
		end
		t.eq(a.core.falloutReveal.commits,1)
		local region=a.core.falloutReveal.regions[1];local page=a.core.pages[region.page]
		local changed={}
		for y=page.y+region.y,page.y+region.y+region.h-1 do
			for x=page.x+region.x,page.x+region.x+region.w-1 do
				local tile=y*a.w+x;buffer.writeu16(a.states,tile*2,2);table.insert(changed,tile)
			end
		end
		Core.applyTileStates(a.core,a.states,changed)
		local old=a.sink.pixel(0,0);buffer.writeu16(a.states,0,2);Core.applyTileStates(a.core,a.states,{0})
		for _=1,16 do Core.step(a.core,1e9,1) end
		t.ok(a.sink.pixel(0,0)~=old,'presentation pinned the other native page')
		t.ok(#a.core.falloutReveal.regions>0,'fixture did not retain a partially prepared piece')
		H.drain(a.core,1e9);equalFresh(t,a);Core.destroy(a.core)
	end)

	t.test('deferred invalidation cannot publish a burst before its remaining rows are expanded',function()
		local a=setup(256,256);a.core.deferred.enabled=true
		local old=image(a,1);blast(a,128,128,80,100)
		t.ok(a.core.deferred.count>0);t.ok(#a.core.falloutReveal.regions>0)
		for frame=1,600 do
			Core.step(a.core,1e9,512)
			if a.core.deferred.count>0 then t.eq(a.core.falloutReveal.commits,0) end
			if a.core.falloutReveal.commits==0 then t.ok(image(a,1)==old,'deferred partial burst leaked') end
			if not Core.hasPending(a.core) then break end
		end
		t.eq(Core.hasPending(a.core),false);t.eq(a.core.falloutReveal.commits,1)
		equalFresh(t,a);Core.destroy(a.core)
	end)
end
