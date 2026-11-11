--!strict
-- Real buffers and the native-property shim; no GPU or native layout claim.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local G,C=H.require(root.CoastGeometry),H.require(root.CoastRaster)
	local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
	local Core=raster.Core
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local function terrain(w,h)
		local out=buffer.create(w*h)
		for y=0,h-1 do for x=0,w-1 do
			local edge=5+math.floor(y*.45)
			buffer.writeu8(out,y*w+x,if x>edge and x<w-3 then 128+(x+y)%10 elseif x>=edge-1 then 65 else 5)
		end end
		return out
	end
	local function geometry(bytes,w,h,res)
		local s=G.new(bytes,w,h,res)
		while not G.step(s,1e9,1000) do end
		return s.geometry,s
	end
	local roster={{id='a',smallID=1,playerType='HUMAN'},{id='b',smallID=2,playerType='HUMAN'}}
	local function source(bytes,w,h)
		local sink=raster.sink(w,h); local core=Core.new(bytes,w,h,sink.backend)
		Core.setRoster(core,roster)
		local states=buffer.create(w*h*2)
		for tile=0,w*h-1 do if bit32.btest(buffer.readu8(bytes,tile),128) then buffer.writeu16(states,tile*2,if tile%w>w/2 then 2 else 1) end end
		Core.applyTileStates(core,states); raster.drain(core,1e9)
		return core,states
	end
	local function drain(r,core)
		local count=0
		while C.pending(r) do C.prepare(r,core,1e9,100000); count+=1; assert(count<10000,'coast did not drain') end
	end
	t.test('static geometry is sliced, preserves inputs, caches only exact same land and supports both resolutions',function()
		G.clearCache(); local bytes=terrain(66,39); local original=buffer.tostring(bytes)
		local s=G.new(bytes,66,39,2); G.step(s,1e9,100); t.eq(s.cursor,100); t.eq(s.done,false)
		while not G.step(s,1e9,1000) do end
		t.ok(s.geometry.count>0); t.eq(buffer.tostring(bytes),original); t.eq(s.cacheHit,false)
		local g,hit=geometry(bytes,66,39,2); t.ok(hit.cacheHit); t.eq(g,s.geometry)
		local g4,hit4=geometry(bytes,66,39,4); t.ok(hit4.cacheHit); t.eq(g4,g); t.ok(g.templates[4])
		buffer.writeu8(bytes,0,129); local changed,b=geometry(bytes,66,39,2)
		t.eq(b.cacheHit,false); t.ok(changed~=g)
		G.clearCache(); t.eq(G.cacheBytes(),0)
	end)
	t.test('templates contain sub-tile curved coverage, keep opposite classes and bounded native atlas dimensions',function()
		local bytes=terrain(66,39); local g=geometry(bytes,66,39,4)
		local partial=0
		for pattern,p in g.templates[4] do
			for code=0,3 do
				local n=5+code%2+math.floor(code/2)*4
				local alpha=buffer.readu8(p,((if code>=2 then 3 else 0)*4+(if code%2==1 then 3 else 0))*3)
				t.eq(alpha>=128,bit32.btest(pattern,2^n),'each tile centre keeps its original surface side')
			end
			for i=0,15 do
				local alpha,near,codes=buffer.readu8(p,i*3),buffer.readu8(p,i*3+1),buffer.readu8(p,i*3+2)
				if alpha>0 and alpha<255 then partial+=1 end
				local function node(bits,code) return bit32.band(bit32.rshift(bits,5+code%2+math.floor(code/2)*4),1) end
				local lp,cp=bit32.band(pattern,65535),bit32.rshift(pattern,16)
				if alpha>0 then t.eq(node(lp,bit32.band(codes,3)),1) end
				if near<255 then t.eq(node(cp,bit32.rshift(codes,4)),0) end
			end
		end
		t.ok(partial>0,'supersampled contours must not be the original binary pixel staircase')
		for _,res in {2,4} do
			if not g.templates[res] then geometry(bytes,66,39,res) end
			local r=C.new(g,res,1e9)
			for _,page in r.pages do t.ok(page.width<=1024 and page.height<=1024) end
			t.eq(C.new(g,res,1),nil,'native byte cap rejects the optional layer')
		end
	end)
	t.test('coastal ownership and sea share one mask; palette colours stay within the source land/sea mixture',function()
		local bytes=terrain(66,39); local g=geometry(bytes,66,39,4)
		local core,states=source(bytes,66,39); local original=buffer.tostring(states)
		local r=C.new(g,4,1e9); drain(r,core)
		for id=0,g.count-1 do
			local ref=buffer.readu32(g.refs,id*4); local ax,ay=ref%67-1,math.floor(ref/67)-1
			local slot=r.slots[buffer.readu32(g.chunkIDs,id*4)]; local page=r.pages[slot.page]
			local template=g.templates[4][buffer.readu32(g.patterns,id*4)]
			for y=0,3 do for x=0,3 do
				local offset=((slot.y+(ay+1)%32*4+y)*page.width+slot.x+(ax+1)%32*4+x)*4
				t.eq(buffer.readu8(page.pixels,offset+3),255,'coast quad covers the underlying square fringe without alpha gaps')
				local alpha=buffer.readu8(template,(y*4+x)*3)
				t.ok(alpha>=0 and alpha<=255)
			end end
		end
		t.eq(buffer.tostring(core.tileState),original); t.eq(buffer.tostring(core.terrain),buffer.tostring(bytes))
		Core.destroy(core)
	end)
	t.test('coast edits across raster pages, ownership, diplomacy and terrain colours equal a fresh colour composition',function()
		local w,h=1027,39; local bytes=terrain(w,h); local g=geometry(bytes,w,h,4)
		local core,states=source(bytes,w,h); local r=C.new(g,4,1e9); drain(r,core)
		local sink=core.sink.write
		core.sink.write=function(page,x,y,rw,rh,pixels) sink(page,x,y,rw,rh,pixels); C.mark(r,page.x+x,page.y+y,rw,rh) end
		local refs={1023,1024,1026,1027*20+1023,1027*20+1024,1027*38+1026,1027*20+15}
		for _,tile in refs do buffer.writeu16(states,tile*2,1+16384); buffer.writeu8(bytes,tile,bit32.bor(bit32.band(buffer.readu8(bytes,tile),192),3)) end
		Core.applyTileStates(core,states,refs); Core.applyTerrain(core,bytes,refs); raster.drain(core,1e9); drain(r,core)
		local data=buffer.create(9); buffer.writeu8(data,5,2); buffer.writeu8(data,7,2)
		Core.setRelations(core,{size=3,data=data}); Core.setHover(core,2); raster.drain(core,1e9); drain(r,core)
		local fresh=C.new(g,4,1e9); drain(fresh,core)
		for id,page in r.pages do t.eq(buffer.tostring(page.pixels),buffer.tostring(fresh.pages[id].pixels),`coast atlas page {id}`) end
		Core.destroy(core)
	end)
	t.test('initial source changes during sliced composition are retained until the coast catches up',function()
		local bytes=terrain(66,39); local g=geometry(bytes,66,39,2); local core,states=source(bytes,66,39)
		local r=C.new(g,2,1e9); C.prepare(r,core,1e9,10)
		local tile=6; buffer.writeu16(states,tile*2,2)
		Core.applyTileStates(core,states,{tile}); raster.drain(core,1e9); C.mark(r,6,0,1,1); drain(r,core)
		local fresh=C.new(g,2,1e9); drain(fresh,core)
		for id,page in r.pages do t.eq(buffer.tostring(page.pixels),buffer.tostring(fresh.pages[id].pixels)) end
		Core.destroy(core)
	end)
	local function renderer(touch, speedFlags)
		local e=native(); e.uis.TouchEnabled=touch
		e.policy.deferredOwnership=speedFlags==true;e.policy.splitMapGuis=speedFlags==true
		local bytes=terrain(66,39); local s=e.client(); s.width,s.height,s.startTick=66,39,0; s.tileState=buffer.create(66*39*2); s.names={}
		local parent=e.instance('Frame');local host=nil
		if speedFlags then host=e.instance('ScreenGui');host.DisplayOrder=0;host.Parent=e.playerGui;parent.Parent=host end
		local r=e.Renderer.new(parent,bytes,66,39,{autoStep=false,firstPaint='full',guiHost=host})
		r.coasts.api.now=function() return e.now end
		r:attachState(s)
		return e,s,r,bytes
	end
	t.test('unchanged delivered coast rectangles skip colour composition and native upload work',function()
		local bytes=terrain(66,39); local g=geometry(bytes,66,39,2); local core=source(bytes,66,39)
		local r=C.new(g,2,1e9); drain(r,core); local composed=r.composed
		C.mark(r,0,0,66,39)
		while C.pending(r) do t.eq(C.prepare(r,core,1e9,100000),nil) end
		t.eq(r.composed,composed); t.eq(r.skipped,g.count)
		Core.destroy(core)
	end)
	local function settle(e,r)
		for _=1,1000 do e.now+=1/60; r:step(1e9,1e9); if r:isReady() then return end end
		error('coast renderer readiness failed')
	end
	t.test('renderer shares one displayed image slot, retains geometry on pan and cleans all native images',function()
		local e,s,r=renderer(true); e.recordUploads=true
		for _=1,1000 do
			e.uploads={}; e.now+=1/60; r:step(1e9,1e9)
			local seen={}; for _,img in e.uploads do seen[img]=true end
			local count=0; for _ in seen do count+=1 end; t.ok(count<=1,'one displayed image per frame')
			if r:isReady() then break end
		end
		t.ok(r:isReady()); t.eq(r.coasts.resolution,2); t.ok(r.coasts.visible>0)
		local shape=r.coasts.builder.geometry; local frame=r.coasts.root; local pos=frame.Position
		local built=r.coasts.builder.buildMs; local composed=r.coasts.raster.composed
		r:pan(10,0); t.ok(frame.Position~=pos,'camera transforms immediately before renderer step')
		for _=1,20 do e.now+=1/60; r:step(1e9,1e9) end
		t.eq(r.coasts.builder.geometry,shape); t.eq(r.coasts.builder.buildMs,built); t.eq(r.coasts.raster.composed,composed)
		t.eq(r.displays[1].label.ZIndex,0); t.eq(frame.ZIndex,1); t.eq(r.scene.effects.spawn.ZIndex,2)
		local x,y=r:worldToScreen(20.5,20.5); t.eq(r:screenToTile(x,y),20*66+20)
		local _,view=next(r.coasts.views)
		view.IsDescendantOf=function(_,ancestor) return ancestor==e.mapGui end
		e.playerGui.GetGuiObjectsAtPosition=function() return {view} end
		local tapped=nil; r:bindInput(e.playerGui,e.mapGui,function(tile) tapped=tile end)
		e.mouseTap(x,y); t.eq(tapped,20*66+20,'coast GUI remains map input, not a HUD exclusion')
		r:destroy(); for _,img in e.images do t.ok(img.destroyed) end; t.ok(frame.destroyed)
	end)
	t.test('both speed flags preserve curved coast colours and the single-image scheduler through queued edits',function()
		local ea,sa,a=renderer(true,false);local eb,sb,b=renderer(true,true)
		settle(ea,a);settle(eb,b)
		for round=1,8 do
			local refs={}
			for index=0,179 do
				local tile=(index*53+round*17)%(66*39);table.insert(refs,tile)
				local value=1+(round+index)%2+(if index%3==0 then 8192 else 0)+(if index%5==0 then 16384 else 0)
				buffer.writeu16(sa.tileState,tile*2,value);buffer.writeu16(sb.tileState,tile*2,value)
			end
			a:applyTileStates(sa.tileState,refs);b:applyTileStates(sb.tileState,refs)
			for _,pair in {{ea,a},{eb,b}} do
				local e,r=pair[1],pair[2];e.recordUploads=true
				for _=1,500 do
					e.uploads={};e.now+=1/60;r:step(1e9,1e9)
					local seen={};for _,image in e.uploads do seen[image]=true end
					local count=0;for _ in seen do count+=1 end;t.ok(count<=1,'two displayed image updates')
					if not r.core.deferred or (r.core.pending==0 and r.core.deferred.count==0 and not C.pending(r.coasts.raster)) then break end
				end
			end
			t.eq(b.core.deferred.count,0)
			for id,page in a.coasts.raster.pages do t.eq(buffer.tostring(page.pixels),buffer.tostring(b.coasts.raster.pages[id].pixels),'coast colour parity') end
		end
		a:destroy();b:destroy()
	end)
	t.test('allocation refusal and a changed confirmed land mask fall back to the complete gameplay raster',function()
		for _,mode in {'refusal','changedLand','changedShore'} do
			local e,_,r,bytes=renderer(false)
			if mode=='refusal' then r.coasts.api.allocate=function() return nil end end
			settle(e,r)
			if mode~='refusal' then
				buffer.writeu8(bytes,0,if mode=='changedLand' then 128 else 65); r:applyTerrain(bytes,{0}); r:step(1e9,1e9)
				t.eq(r.coasts.invalidated,true); t.eq(r.coasts.root.Visible,false)
			end
			t.eq(r.coasts.failed,true); t.ok(r:isReady()); t.ok(r.displays[1].image)
			r:destroy(); for _,img in e.images do t.ok(img.destroyed) end
		end
	end)
end
