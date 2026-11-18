--!strict
-- Independent tile oracle plus native-property adapter/lifecycle checks.
-- These checks do not establish Roblox filtering, GUI/GPU cost or phone feel.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Reach=H.require(root.SabotageReach)
	local function setup(w:number,h:number,r:number,maxSide:number?):any
		local states=buffer.create(w*h*2)
		local c=Reach.new(w,h,function(tile) return bit32.band(buffer.readu16(states,tile*2),4095) end,maxSide)
		local function put(x:number,y:number,owner:number) buffer.writeu16(states,(y*w+x)*2,owner) end
		return c,states,put
	end
	local function drain(c:any)
		for _=1,20000 do if not c:pending() then return end;c:step(math.huge,4096) end
		error('reach work did not drain')
	end
	local function hit(c:any,x:number,y:number):boolean
		return buffer.readu8(c.pixels,(y*c.mw+x)*4+3)>0
	end
	local function oracle(c:any,states:buffer)
		local w,h=c.width,c.height
		local function own(x:number,y:number):boolean
			return bit32.band(buffer.readu16(states,(y*w+x)*2),4095)==c.owner
		end
		local border={}
		for y=0,h-1 do for x=0,w-1 do
			if own(x,y) and ((x>0 and not own(x-1,y)) or (x+1<w and not own(x+1,y))
				or (y>0 and not own(x,y-1)) or (y+1<h and not own(x,y+1))) then table.insert(border,{x=x,y=y}) end
		end end
		for py=0,c.mh-1 do for px=0,c.mw-1 do
			local x,y=c.xs[px+1],c.ys[py+1]
			local expected=false
			if not own(x,y) then for _,p in border do
				if (p.x-x)^2+(p.y-y)^2<=c.reach^2 then expected=true;break end
			end end
			t.eq(hit(c,px,py),expected,`reach {x},{y}`)
		end end
	end
	t.test('inclusive Euclidean 60-tile radius from a border tile, not Manhattan or a map-edge border',function()
		local c,s,put=setup(140,135,60);put(65,65,1);c:setActive(1,60);drain(c)
		t.ok(hit(c,125,65));t.ok(not hit(c,126,65));t.ok(hit(c,101,113));t.ok(not hit(c,102,113))
		t.ok(not hit(c,65,65),'own tile is untinted');oracle(c,s)
		for tile=0,140*135-1 do buffer.writeu16(s,tile*2,1) end
		c:tilesChanged(nil);drain(c);t.eq(#c.rows[0],0,'off-map neighbours do not create borders')
		t.ok(not hit(c,0,0));c:destroy()
	end)
	t.test('islands, holes, coastline neighbours and friendly territory still obey geometry only',function()
		local c,s,put=setup(47,35,7)
		for y=0,24 do for x=0,29 do put(x,y,1) end end
		for y=10,14 do for x=10,15 do put(x,y,2) end end
		put(43,32,1);put(36,12,3);c:setActive(1,7);drain(c);oracle(c,s)
		t.ok(hit(c,36,12),'affiliation eligibility is left to server preview')
		t.ok(not hit(c,11,2),'deep own interior is untinted');c:destroy()
	end)
	t.test('bounded downsample uses exact tile-centre samples and matches brute-force reach',function()
		local c,s,put=setup(157,103,11,41)
		for y=17,79 do for x=22,97 do if (x+y)%11~=0 then put(x,y,1) end end end
		c:setActive(1,11);drain(c);t.eq(c.mw,41);t.ok(c.mh<=41);oracle(c,s);c:destroy()
	end)
	t.test('idle frames, camera-independent use and rearming reuse completed geometry',function()
		local c,_,put=setup(80,60,10);put(25,25,1);c:setActive(1,10);drain(c)
		local rows,masks=c.scans,c.maskBuilds;local pixels=c.pixels
		for _=1,100 do c:step(1,4096) end
		c:setActive(1,nil);t.eq(c.active,false);c:setActive(1,10);drain(c)
		t.eq(c.scans,rows);t.eq(c.maskBuilds,masks);t.eq(c.pixels,pixels);c:destroy()
	end)
	t.test('only our ownership changes invalidate local rows; removals match fresh repaint',function()
		local c,s,put=setup(90,70,8);put(30,30,1);put(31,30,1);c:setActive(1,8);drain(c)
		local old=buffer.create(buffer.len(s));buffer.copy(old,0,s)
		put(80,50,2);buffer.writeu16(s,0,8192);c:tilesChanged({});drain(c)
		t.eq(c.scans,70);t.eq(c.maskBuilds,70)
		buffer.copy(old,0,s);put(30,30,2);c:tilesChanged({30*90+30});drain(c)
		t.eq(c.scans,73,'only affected row and its neighbours rescan');oracle(c,s)
		buffer.copy(old,0,s);put(31,30,2);c:tilesChanged({30*90+31});drain(c);oracle(c,s)
		t.ok(not hit(c,32,30));c:destroy()
	end)
	t.test('changes during yielded border/mask work cannot commit an obsolete row',function()
		local c,s,put=setup(300,40,6);put(1,1,1);c:setActive(1,6)
		c:step(math.huge,128);t.ok(c.job~=nil)
		local old=buffer.create(buffer.len(s));buffer.copy(old,0,s);put(2,0,1);c:tilesChanged({2})
		for _=1,1000 do
			if c.job and c.job.kind=='mask' then break end
			c:step(math.huge,128)
		end
		t.eq(c.job.kind,'mask');buffer.copy(old,0,s);put(1,1,2);c:tilesChanged({301})
		drain(c);oracle(c,s);c:destroy()
	end)
	t.test('inactive edits, snapshot and owner/reach replacement clear old work and pixels',function()
		local c,s,put=setup(45,40,8);put(8,8,1);put(34,30,2);c:setActive(1,8);drain(c)
		c:setActive(1,nil);local old=buffer.create(buffer.len(s));buffer.copy(old,0,s)
		put(8,8,0);put(20,20,1);c:tilesChanged({8*45+8,20*45+20})
		c:setActive(1,8);drain(c);oracle(c,s)
		c:tilesChanged(nil);t.ok(c:pending());drain(c);oracle(c,s)
		c:setActive(2,3);drain(c);oracle(c,s);t.ok(hit(c,35,30));t.ok(not hit(c,20,21))
		c:destroy();t.eq(c.pixels,nil);t.eq(c.job,nil);t.eq(next(c.rows),nil)
	end)
	t.test('coherent bounded upload blocks wait for math, then finish in at most eight image slots',function()
		local c,_,put=setup(800,600,60);put(300,200,1);c:setActive(1,60)
		t.eq(c:nextUpload(),nil);drain(c)
		local n=0
		while not c:clean() do
			local y,h=c:nextUpload();t.ok(y~=nil and h<=64);t.ok(c.mw*h*4<=131072);n+=1;c:uploaded(y)
		end
		t.ok(n<=8);c:destroy()
	end)
	t.test('continuous own-border traffic cannot require a quiet map for first presentation',function()
		local c,s,put=setup(180,140,9,90)
		for y=25,110 do for x=20,80 do put(x,y,1) end end
		c:prewarm(1,9);t.eq(c.active,false,'index prewarms before selection')
		local uploads=0
		for frame=1,1600 do
			if frame%3==0 then
				put(81,60,if frame%2==0 then 1 else 2);c:tilesChanged({60*180+81})
			end
			c:step(math.huge,512)
			local y=c:nextUpload();if y~=nil then c:uploaded(y);uploads+=1 end
			if c:presentable() then break end
		end
		t.ok(c:presentable(),'every block must progress amid traffic');t.ok(uploads>=2)
		c:setActive(1,9);drain(c);oracle(c,s);c:destroy()
	end)

	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function adapter():any
		local e=native();local s=e.client();s.startTick=0;s.gold=1e9
		local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
		local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,coasts=false})
		r:attachState(s);r:applyTileStates(s.tileState,nil)
		for _=1,30 do r:step(1e9,1e9) end
		return e,s,r,e.Preview.new(r,s,function() return nil end)
	end
	t.test('armed without a pointer, keeps target preview, follows camera, hides on deselect and cleans up',function()
		local e,s,r,p=adapter();buffer.writeu16(s.tileState,(20*64+20)*2,1);r:applyTileStates(s.tileState,{20*64+20})
		p:setChosen('Sabotage');p:step();t.eq(r.scene.buildPreview,nil,'no pointer needed')
		local a=r.scene.sabotageReach
		for _=1,80 do r:step(1e9,1e9) end
		t.ok(a.view.Visible);t.ok(a.shown)
		local scans=a.cache.scans;local uploads=a.uploads
		r:setCamera({width=64,height=64,viewportWidth=844,viewportHeight=390,left=17,top=23,offsetX=0,offsetY=0,scale=4})
		local x,y=r:worldToScreen(0,0);t.eq(a.view.Position,rb.UDim2.fromOffset(x-17,y-23))
		t.eq(a.view.Size,rb.UDim2.fromOffset(256,256));r:step(1e9,1e9);t.eq(a.cache.scans,scans);t.eq(a.uploads,uploads)
		p:setChosen('City');t.eq(a.view.Visible,false);p:setChosen('Sabotage');t.eq(a.view.Visible,true)
		p:destroy();t.eq(a.view.Visible,false);local image,view=a.image,a.view;r:destroy();t.ok(image.destroyed);t.ok(view.destroyed)
		t.eq(a.cache.pixels,nil);t.eq(a.scratch,nil)
	end)
	t.test('reach uploads share one displayed-image slot with live raster and snapshots hide stale masks',function()
		local e,s,r,p=adapter();buffer.writeu16(s.tileState,0,1);r:applyTileStates(s.tileState,{0});p:setChosen('Sabotage')
		e.recordUploads=true
		for i=1,100 do
			e.uploads={};r:step(1e9,1e9)
			local distinct={};for _,img in e.uploads do distinct[img]=true end
			local n=0;for _ in distinct do n+=1 end;t.ok(n<=1)
		end
		local a=r.scene.sabotageReach;t.ok(a.view.Visible);r:applyTileStates(s.tileState,nil);t.eq(a.view.Visible,false)
		r:setLocalPlayer(2);t.eq(a.view.Visible,false);t.eq(a.cache.owner,2)
		p:destroy();r:destroy()
	end)
	t.test('non-own ownership and cosmetic deltas do not invalidate; server reach survives pointer churn',function()
		local _,s,r,p=adapter();local c=r.scene.sabotageReach.cache;drain(c)
		local scans,rows=c.scans,c.maskBuilds
		buffer.writeu16(s.tileState,42*2,2);buffer.writeu16(s.tileState,50*2,8192)
		r:applyTileStates(s.tileState,{42,50});drain(c);t.eq(c.scans,scans);t.eq(c.maskBuilds,rows)
		p:setChosen('Sabotage');p.reply={sabotageAim={reach=12,readyAt=0,reason='out_of_reach'}}
		p:step();t.eq(c.reach,12);p:step();t.eq(c.reach,12)
		p:setChosen(nil);t.eq(c.active,false);p:destroy();r:destroy()
	end)
end
