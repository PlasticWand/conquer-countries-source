--!strict
-- Late-match desktop property proxy. Phone means viewport/touch CPU budget;
-- this does not simulate phone hardware, native GUI, upload or GPU time.
local fs,luau,rb,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox'),require('@lune/serde')
local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
source=source:gsub('local o: any = {ClassName=class','local values: any = {ClassName=class')
source=source:gsub('o.GetPropertyChangedSignal=function',[[local o: any
o = setmetatable({}, {__index=values,__newindex=function(_,key,value)
	if type(value)~='function' then env.propertyWrites=(env.propertyWrites or 0)+1 end
	values[key]=value
end})
o.GetPropertyChangedSignal=function]])
-- Native destruction visits a subtree; the general test shim scans its
-- inventory. Index parents here so that mock bookkeeping cannot fabricate
-- quadratic cache/rail destruction hitches in the measured windows.
source=source:gsub("values%[key%]=value",[[if key=='Parent' then
		env.children=env.children or {}
		if values.Parent and env.children[values.Parent] then env.children[values.Parent][o]=nil end
		if value then env.children[value]=env.children[value] or {}; env.children[value][o]=true end
	end
	values[key]=value]],1)
source=source:gsub('for _, child in env.objects do if child.Parent==o then child:Destroy%(%) end end',
	'for child in table.clone((env.children or {})[o] or {}) do child:Destroy() end',1)
source=source:gsub('o.destroyed=true; o.Destroying:Fire%(%)','o.destroyed=true; o.Destroying:Fire(); o.Parent=nil',1)
source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then',
	'node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
if require('@lune/process').args[2]=='before' then
	local process=require('@lune/process')
	fs.writeDir('Temp/OpenFrontLateBaseline')
	for _,name in {'SceneOverlay','StructureAtlas','SpriteAtlas','RasterCore','EditableRenderer','EffectOverlay'} do
		local result=process.exec('git',{'show','33d041b:src/client/Map/OpenFront/'..name..'.luau'})
		assert(result.ok,result.stderr)
		fs.writeFile('Temp/OpenFrontLateBaseline/'..name..'.luau',result.stdout)
	end
	-- Reproducible reference modules, exported read-only from 33d041b into
	-- Temp/OpenFrontLateBaseline. Never execute inside the upstream checkout.
	source=source:gsub('local env: any =',[[for _,name in {'SceneOverlay','StructureAtlas','SpriteAtlas','RasterCore','EditableRenderer','EffectOverlay'} do
		root[name].path='Temp/OpenFrontLateBaseline/'..name..'.luau'
	end
	local env: any =]],1)
end
local make=luau.load(source)()
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local function summary(a) local b=table.clone(a); table.sort(b); local sum=0; for _,v in a do sum+=v end; return {mean=sum/#a,p50=b[math.ceil(#a*.5)],p95=b[math.ceil(#a*.95)],max=b[#a]} end
for _,device in {'desktop','phoneBudget'} do
	local e=make(); e.uis.TouchEnabled=device=='phoneBudget'
	local s=e.client(); s.width,s.height,s.startTick,s.tick=2000,1000,0,3000
	s.tileState=buffer.create(2000000*2); s.players,s.rosterOrder,s.units,s.names,s.railroads={},{},{},{},{}
	local roster={}
	for id=1,101 do
		local kind=if id==1 then 'HUMAN' else 'NATION'
		s.players[id]={id=`p{id}`,smallID=id,name=`Player {id}`,type=kind,troops=100000,alive=true,tiles=1000,allies={},embargoes={}}
		s.rosterOrder[id]=id; roster[id]={id=`p{id}`,smallID=id,playerType=kind}
		s.names[id]={x=(id-1)%17*115+40,y=math.floor((id-1)/17)*145+40,size=25}
	end
	for tile=0,1999999 do if bit32.btest(buffer.readu8(terrain,tile),128) then buffer.writeu16(s.tileState,tile*2,1+math.floor(tile/2000/80)%101) end end
	local kinds={'City','Port','Factory','Defense Post','SAM Launcher','Missile Silo'}
	local mobiles={'Trade Ship','Transport','Warship','Train','Shell'}
	for id=1,2000 do
		local tile=(20+math.floor((id-1)/50)*24)*2000+20+(id-1)%50*39
		s.units[id]={id=id,type=if id<=1400 then kinds[(id-1)%6+1] elseif id>1990 then 'Atom Bomb' else mobiles[(id-1)%5+1],
			owner=(id-1)%101+1,tile=tile,lastTile=tile-1,active=true,level=if id%12==0 then 2 else 1,
			underConstruction=id<=30,constructionStartTick=2995,missileTimerQueue={},targetTile=tile+10,trainType='Engine'}
	end
	for row=0,6 do local path={}; for x=950,1049 do table.insert(path,(490+row)*2000+x) end; s.railroads[row+1]=path end
	local parent=e.instance('Frame'); parent.AbsoluteSize=if device=='desktop' then rb.Vector2.new(1530,613) else rb.Vector2.new(844,390)
	local r=e.Renderer.new(parent,terrain,2000,1000,{autoStep=false,firstPaint='full'})
	r:setRoster(roster); r:applyTileStates(s.tileState); r:attachState(s)
	repeat e.now+=1/60; r:step() until r:isReady()
	local fit=table.clone(r.camera)
	local function camera(scale,x,y)
		local c=table.clone(fit); c.scale=scale
		c.offsetX=x-1000-(c.viewportWidth/2-1000)/scale
		c.offsetY=y-500-(c.viewportHeight/2-500)/scale
		r:setCamera(c)
	end
	-- Visit dense track once, reproducing a retained rail pool after zoom-out.
	camera(8,1000,493); for _=1,80 do e.now+=1/60; r:step() end
	r:setCamera(fit)
	local function cachePending(cache) return cache and cache.queue[cache.head]~=nil end
	for _=1,4096 do
		e.now+=1/60; r:step()
		if not cachePending(r.scene.structureCache) and not cachePending(r.scene.mobileCache) and r.core.pending==0 then break end
	end
	local serial,latencies,batches,committed=0,{},{},{}
	for key=0,r.core.blocks-1 do committed[key]=buffer.readu32(r.core.revisions,key*4) end
	local sink=r.core.sink.write
	r.core.sink.write=function(page,x,y,w,h,pixels)
		sink(page,x,y,w,h,pixels)
		for by=math.floor((page.y+y)/32),math.floor((page.y+y+h-1)/32) do
			for bx=math.floor((page.x+x)/32),math.floor((page.x+x+w-1)/32) do
				local key=by*r.core.columns+bx; committed[key]=buffer.readu32(r.core.revisions,key*4)
			end
		end
	end
	local function frame(i,mode)
		serial+=1; e.now+=1/60
		local batchRefs=nil
		local dispatch=os.clock()
		if mode~='idle' and i%6==0 then
			s.tick+=1
			local moved={}
			for id=1401,2000 do local u=s.units[id]; u.lastTile,u.tile=u.tile,(u.tile+1)%2000000; table.insert(moved,id) end
			s.UnitsMoved:Fire(moved,s.tick)
			local refs={}
			for patch=0,149 do
				local x=(patch*131+s.tick*3)%1970; local y=(patch*71+s.tick)%980
				for k=0,19 do local tile=y*2000+x+k; buffer.writeu16(s.tileState,tile*2,1+s.tick%101); table.insert(refs,tile) end
			end
			r:applyTileStates(s.tileState,refs); s.TickApplied:Fire(s.tick); batchRefs=refs
		end
		if mode=='pan' then camera(fit.scale,1000+math.sin(i*.03)*100,500+math.cos(i*.02)*30)
		elseif mode=='zoom' then camera(.6+(1+math.sin(i*.015))*1.6,1000,493) end
		dispatch=(os.clock()-dispatch)*1000
		if batchRefs then
			local revisions={}
			for _,tile in batchRefs do
				local x,y=tile%2000,math.floor(tile/2000)
				for by=math.floor(math.max(0,y-1)/32),math.floor(math.min(999,y+1)/32) do
					for bx=math.floor(math.max(0,x-1)/32),math.floor(math.min(1999,x+1)/32) do
						local key=by*r.core.columns+bx; revisions[key]=buffer.readu32(r.core.revisions,key*4)
					end
				end
			end
			table.insert(batches,{frame=serial,revisions=revisions})
		end
		local start=os.clock(); r:step(); local elapsed=(os.clock()-start)*1000
		for i=#batches,1,-1 do
			local batch=batches[i]; local ready=true
			for key,revision in batch.revisions do
				-- A progressive row write is not proof that the entire block is
				-- caught up. New Core publishes revisions only after all dirty rows.
				local displayed=if r.core.committedRevisions then buffer.readu32(r.core.committedRevisions,key*4) else committed[key]
				if displayed<revision then ready=false; break end
			end
			if ready then table.insert(latencies,serial-batch.frame+1); table.remove(batches,i) end
		end
		return elapsed,dispatch
	end
	for _,mode in {'idle','pan','zoom'} do
		r:setCamera(fit)
		for i=1,120 do frame(i,mode) end
		latencies={}; batches={}
		e.propertyWrites=0; r:resetTimings(); r.core.maxUploadAgeFrames=0
		local steps,dispatch={},{}
		local count=#e.objects; local shaded=r.core.shadedPixels or 0
		local pixels,uploads,bytes=r.core.paintedPixels,r.core.uploads,r.core.uploadedBytes
		local pending=0
		for i=1,600 do local step,send=frame(i,mode); table.insert(steps,step); table.insert(dispatch,send); pending=math.max(pending,r.core.pending) end
		local gui,components,rails=0,0,0
		for _,o in e.objects do
			local ancestor=o
			while ancestor and ancestor~=r.root do ancestor=ancestor.Parent end
			if not o.destroyed and ancestor==r.root then
			if o.ClassName=='Frame' or o.ClassName=='TextLabel' or o.ClassName=='ImageLabel' then
				gui+=1; local p=o.Parent
				while p and p~=r.root do if p==r.scene.layers.Rails then rails+=1; break end; p=p.Parent end
			else components+=1 end
		end end
		print(serde.encode('json',{device=device,mode=mode,units=2000,structures=1400,editsPerTick=3000,railTiles=700,
			step=summary(steps),dispatch=summary(dispatch),
			ownershipLatencyFrames=if #latencies>0 then summary(latencies) else nil,incompleteBatches=#batches,writes=e.propertyWrites,newInstances=#e.objects-count,
			gui=gui,components=components,railGui=rails,pendingMax=pending,pendingEnd=r.core.pending,
			shadedPixels=if r.core.shadedPixels then r.core.shadedPixels-shaded else nil,paintedPixels=r.core.paintedPixels-pixels,uploads=r.core.uploads-uploads,uploadBytes=r.core.uploadedBytes-bytes,metrics=r:metrics()}))
	end
	r:destroy(); for _,image in e.images do assert(image.destroyed,'image leak') end
end
