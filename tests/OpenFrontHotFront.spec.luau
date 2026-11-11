--!strict
return function(t)
	local fs,luau=require('@lune/fs'),require('@lune/luau')
	local make=luau.load(fs.readFile('tests/OpenFrontHotFrontHarness.luau'))()
	t.test('own rows bypass unrelated dirty rows inside the same block',function()
		local e=make();e.change(2)
		while e.core.pending>0 do e.Core.step(e.core,1e9,1e9) end
		local refs={}
		for tile=0,30*32-1 do buffer.writeu16(e.states,tile*2,16386);table.insert(refs,tile) end
		local own=31*32+16;local before=e.sink.pixel(16,31)
		buffer.writeu16(e.states,own*2,1);table.insert(refs,own)
		e.Core.applyTileStates(e.core,e.states,refs)
		for _=1,2 do e.Core.step(e.core,1e9,32) end
		t.ok(e.sink.pixel(16,31)~=before,'own priority stopped at the block boundary')
		e.Core.destroy(e.core)
	end)
	t.test('relations dirty touching borders instead of repainting the whole empire',function()
		local e=make(false,128,64)
		for y=0,63 do for x=0,127 do buffer.writeu16(e.states,(y*128+x)*2,if x<64 then 1 else 2) end end
		e.Core.applyTileStates(e.core,e.states)
		local matrix=buffer.create(16); e.Core.setRelations(e.core,{size=4,data=matrix})
		while e.core.pending>0 do e.Core.step(e.core,1e9,1e9) end
		local before=e.core.shadedPixels
		buffer.writeu8(matrix,1*4+3,1); buffer.writeu8(matrix,3*4+1,1)
		e.Core.setRelations(e.core,{size=4,data=matrix})
		t.eq(e.core.pending,0,'a nonadjacent alliance repainted own territory')
		buffer.writeu8(matrix,1*4+2,1);buffer.writeu8(matrix,2*4+1,1)
		e.Core.setRelations(e.core,{size=4,data=matrix})
		while e.core.pending>0 do e.Core.step(e.core,1e9,64) end
		t.eq(e.core.shadedPixels-before,128,'only the two touching border columns change')
		local other=make(false,128,64);other.Core.applyTileStates(other.core,e.states)
		other.Core.setRelations(other.core,{size=4,data=matrix})
		while other.core.pending>0 do other.Core.step(other.core,1e9,1e9) end
		for y=0,63 do for x=0,127 do t.eq(e.sink.pixel(x,y),other.sink.pixel(x,y)) end end
		e.Core.destroy(e.core);other.Core.destroy(other.core)
	end)
	t.test('relation changes across partial uploads, pending captures and a reentrant sink converge exactly',function()
		local e=make(false,64,32);local matrix=buffer.create(16)
		for y=0,31 do for x=0,63 do buffer.writeu16(e.states,(y*64+x)*2,if x<32 then 1 else 2) end end
		e.Core.applyTileStates(e.core,e.states);e.Core.setRelations(e.core,{size=4,data=matrix})
		while e.core.pending>0 do e.Core.step(e.core,1e9,1e9) end
		buffer.writeu8(matrix,6,1);buffer.writeu8(matrix,9,1);e.Core.setRelations(e.core,{size=4,data=matrix})
		e.Core.step(e.core,1e9,4)
		local tile=16*64+31;buffer.writeu16(e.states,tile*2,2);e.Core.applyTileStates(e.core,e.states,{tile})
		local original=e.core.sink.write;local once=true
		e.core.sink.write=function(...)
			original(...)
			if once then
				once=false;buffer.writeu8(matrix,6,2);buffer.writeu8(matrix,9,2)
				e.Core.setRelations(e.core,{size=4,data=matrix})
			end
		end
		while e.core.pending>0 do e.Core.step(e.core,1e9,16) end
		local other=make(false,64,32);other.Core.applyTileStates(other.core,e.states);other.Core.setRelations(other.core,{size=4,data=matrix})
		while other.core.pending>0 do other.Core.step(other.core,1e9,1e9) end
		for y=0,31 do for x=0,63 do t.eq(e.sink.pixel(x,y),other.sink.pixel(x,y)) end end
		buffer.fill(e.states,0,0);e.Core.applyTileStates(e.core,e.states)
		while e.core.pending>0 do e.Core.step(e.core,1e9,1e9) end
		t.eq(buffer.readstring(e.core.relationRows,0,buffer.len(e.core.relationRows)),string.rep('\0',buffer.len(e.core.relationRows)),
			'terrain-only bulk rows retained former foreign borders')
		e.Core.destroy(e.core);other.Core.destroy(other.core)
	end)
	t.test('hot ownership every six frames still reaches the image under a two-row service budget',function()
		local e=make();local frames=120
		for frame=1,frames do
			e.now+=1/60
			if (frame-1)%6==0 then e.change(if math.floor((frame-1)/6)%2==0 then 1 else 2) end
			e.Core.step(e.core,1e9,64)
		end
		t.ok(#e.sink.writes>=frames/2,'a continuously changing block never reached the display')
		-- Stop changing: the final image must agree exactly with current state.
		while e.core.pending>0 do e.now+=1/60;e.Core.step(e.core,1e9,64) end
		local other=make();other.Core.applyTileStates(other.core,e.states)
		while other.core.pending>0 do other.Core.step(other.core,1e9,1e9) end
		for y=0,31 do for x=0,31 do t.eq(e.sink.pixel(x,y),other.sink.pixel(x,y)) end end
		e.Core.destroy(e.core);other.Core.destroy(other.core)
	end)
	t.test('recent own-front ages expire while a blocked pending front still reports its current age',function()
		local e=make();e.change(1)
		for _=1,120 do e.now+=1/60;e.Core.beginFrame(e.core) end
		local waiting=e.Core.metrics(e.core)
		t.eq(waiting.visibleOwnPendingBlocks,1);t.ok(waiting.pendingOwnVisibleAgeFrames>=119)
		e.Core.step(e.core,1e9,64)
		local sent=e.Core.metrics(e.core)
		t.eq(sent.recentOwnUploadSamples,1);t.ok(sent.recentOwnUploadP95Frames>=119)
		t.eq(sent.recentOwnUploadMaxFrames,sent.recentOwnUploadP95Frames)
		while e.core.pending>0 do e.now+=1/60;e.Core.beginFrame(e.core);e.Core.step(e.core,1e9,1024) end
		e.now+=2.01
		local expired=e.Core.metrics(e.core)
		t.eq(expired.recentOwnUploadSamples,0);t.eq(expired.recentUploadMaxFrames,0)
		t.eq(expired.pendingOwnVisibleAgeFrames,0);t.ok(expired.maxUploadAgeFrames>=119,'lifetime diagnostic remains separate')
		t.ok(expired.ownTileUpdateGapMs>=2000)
		e.Core.destroy(e.core);t.eq(e.Core.metrics(e.core).cpuBufferBytes,0)
	end)
	t.test('own dirty markers clear after their rows upload even while enemy-only work keeps the block hot',function()
		local e=make();e.change(1);while e.core.pending>0 do e.Core.step(e.core,1e9,1024) end
		e.change(2)
		for frame=1,48 do
			e.now+=1/60
			if frame%6==0 then e.change(2+(if frame%12==0 then 16384 else 0)) end
			e.Core.step(e.core,1e9,64)
		end
		local m=e.Core.metrics(e.core)
		t.ok(m.pendingBlocks>0);t.eq(m.visibleOwnPendingBlocks,0);t.eq(m.pendingOwnVisibleAgeFrames,0)
		t.ok(m.ownTileUpdateGapMs>700,'enemy updates changed the own-input clock')
		e.Core.destroy(e.core)
	end)
	t.test('own visible work bypasses another page backlog while normal visible work keeps fairness turns',function()
		local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
		local C=raster.Core;local terrain=buffer.create(2048*32);buffer.fill(terrain,0,128)
		local states=buffer.create(2048*32*2);for tile=0,2048*32-1 do buffer.writeu16(states,tile*2,2) end
		local sink=raster.sink(2048,32);local core=C.new(terrain,2048,32,sink.backend)
		C.setRoster(core,{{id='you',smallID=1,playerType='HUMAN'},{id='enemy',smallID=2,playerType='NATION'}})
		C.setLocalPlayer(core,1);C.applyTileStates(core,states);raster.drain(core,1e9)
		C.setViewport(core,{x0=0,y0=0,x1=2048,y1=32});table.clear(sink.writes)
		local refs={};for x=4,1000,32 do local tile=16*2048+x;buffer.writeu16(states,tile*2,16386);table.insert(refs,tile) end
		local own=16*2048+1500;buffer.writeu16(states,own*2,1);table.insert(refs,own)
		C.applyTileStates(core,states,refs)
		t.eq(C.step(core,1e9,64).page,2,'own front waited behind the other page')
		for frame=1,16 do
			buffer.writeu16(states,own*2,if frame%2==0 then 1 else 2);C.applyTileStates(core,states,{own})
			local before=#sink.writes;local out=C.step(core,1e9,4)
			for i=before+1,#sink.writes do t.eq(sink.writes[i],out.page,'more than one page in a frame') end
		end
		local normal=false;for _,page in sink.writes do if page==1 then normal=true end end
		t.ok(normal,'own priority starved normal visible work');raster.drain(core,1e9)
		t.eq(core.pending,0);C.destroy(core)
	end)
	t.test('an update during the sink call cannot erase new dirty pixels',function()
		local e=make();e.change(1)
		local write=e.core.sink.write;local once=true
		e.core.sink.write=function(...)
			write(...)
			if once then once=false;e.change(2) end
		end
		e.Core.step(e.core,1e9,64)
		while e.core.pending>0 do e.Core.step(e.core,1e9,64) end
		local other=make();other.Core.applyTileStates(other.core,e.states)
		while other.core.pending>0 do other.Core.step(other.core,1e9,1024) end
		for y=0,31 do for x=0,31 do t.eq(e.sink.pixel(x,y),other.sink.pixel(x,y)) end end
		e.Core.destroy(e.core);other.Core.destroy(other.core)
	end)
	t.test('an own front reaches the image immediately behind two hundred visible pending blocks',function()
		local e=make(false,1024,256);e.change(2)
		while e.core.pending>0 do e.Core.step(e.core,1e9,1e9) end
		local refs={}
		for key=0,171 do
			local bx,by=key%32*32,math.floor(key/32)*32
			for y=by,by+31 do for x=bx,bx+31 do local tile=y*1024+x;buffer.writeu16(e.states,tile*2,3);table.insert(refs,tile) end end
		end
		local own=248*1024+1016;local original=e.sink.pixel(1016,248)
		buffer.writeu16(e.states,own*2,1);table.insert(refs,own);e.Core.applyTileStates(e.core,e.states,refs)
		t.ok(e.core.pending>=200)
		e.Core.step(e.core,1e9,4096)
		t.ok(e.sink.pixel(1016,248)~=original,'own ownership stayed behind visible backlog')
		t.ok(e.core.pending>0,'test did not retain competing visible work')
		e.Core.destroy(e.core)
	end)
	t.test('background page rotation survives a permanently hot own front on a different page',function()
		local e=make(false,3072,32);e.change(2)
		while e.core.pending>0 do e.Core.step(e.core,1e9,1e9) end
		e.Core.setViewport(e.core,{x0=0,y0=0,x1=32,y1=32});table.clear(e.sink.writes)
		local own=16*3072+16
		local refs={}
		for _,x in {1100,2200} do local tile=16*3072+x;buffer.writeu16(e.states,tile*2,3);table.insert(refs,tile) end
		e.Core.applyTileStates(e.core,e.states,refs)
		for frame=1,32 do
			buffer.writeu16(e.states,own*2,if frame%2==0 then 1 else 2);e.Core.applyTileStates(e.core,e.states,{own})
			e.Core.step(e.core,1e9,4)
		end
		local pages={};for _,page in e.sink.writes do pages[page]=true end
		t.ok(pages[1] and pages[2] and pages[3],'own priority reset background rotation')
		e.Core.destroy(e.core)
	end)
end
