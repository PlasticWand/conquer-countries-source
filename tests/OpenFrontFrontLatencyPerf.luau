--!strict
-- Reuses the full-World fixture only; no sim, packet, HUD or native/GPU timing.
local fs,luau,process,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/process'),require('@lune/serde')
local source=fs.readFile('tests/OpenFrontConquestPerf.luau'):match('^(.-)%-%- Components')
assert(source)
local fixture=luau.load(source..'\nreturn {e=e,r=r,s=s,fit=fit,land=land,foreign=foreign,w=w,h=h,variant=variant}',{injectGlobals=true})()
local e,r,s,fit,land,foreign,w,h=fixture.e,fixture.r,fixture.s,fixture.fit,fixture.land,fixture.foreign,fixture.w,fixture.h
-- Coast culling follows logical camera time, not unpaced host wall time.
r.coasts.api.now=function() return e.now end
for row=0,6 do local path={};for x=950,1049 do table.insert(path,(490+row)*w+x) end;s.railroads[row+1]=path end
s.RailroadsChanged:Fire()
local components,peaks={},{}
local depth,frameMs=0,0
local function wrap(o,key,label)
	local old=o[key];o[key]=function(self,...)
		depth+=1;local t=os.clock();local result=old(self,...);local ms=(os.clock()-t)*1000
		depth-=1;if depth==0 then frameMs+=ms end
		components[label]=(components[label] or 0)+ms;peaks[label]=math.max(peaks[label] or 0,ms)
		return result
	end
end
for _,key in {'step','setCamera','applyTileStates'} do wrap(r,key,key) end
for _,key in {'setTick','setMoved','setUnits','unitUpdates','setNameAnchors'} do wrap(r.scene,key,key) end
wrap(r.scene.effects,'step','fx');wrap(r.scene.effects.masks,'tilesChanged','maskInvalidation')
wrap(r.coasts,'stepViews','coastViews');wrap(r.coasts,'prepare','coastPrepare')
local records={}
local tracking={};local tipAges={};local frame=0
local requestedTips,offscreenTips=0,0
local oldSink=r.core.sink.write
r.core.sink.write=function(page,x,y,ww,hh,pixels)
	local x0,y0=page.x+x,page.y+y
	for by=math.floor(y0/32),math.floor((y0+hh-1)/32) do for bx=math.floor(x0/32),math.floor((x0+ww-1)/32) do
		local key=by*r.core.columns+bx;local tips=tracking[key]
		if tips then for tile,started in tips do
			local tx,ty=tile%w,math.floor(tile/w)
			if tx>=x0 and ty>=y0 and tx<x0+ww and ty<y0+hh then table.insert(tipAges,frame-started+1);tips[tile]=nil end
		end end
	end end
	return oldSink(page,x,y,ww,hh,pixels)
end
local function visible(tile)
	local c=r.camera;local x,y=tile%w+.5,math.floor(tile/w)+.5
	local sx,sy=(x-c.width/2-c.offsetX)*c.scale+c.width/2,(y-c.height/2-c.offsetY)*c.scale+c.height/2
	return sx>=0 and sy>=0 and sx<c.viewportWidth and sy<c.viewportHeight
end
local tipCursor=1
local function fronts(count)
	local refs={};local tries=0
	while #refs<count and tries<#land do
		tipCursor=tipCursor%#land+1;tries+=1
		local tile=land[(tipCursor*499)%#land+1]
		if visible(tile) then
			requestedTips+=1
			buffer.writeu16(s.tileState,tile*2,if buffer.readu16(s.tileState,tile*2)==1 then 2 else 1)
			table.insert(refs,tile)
			local key=math.floor(tile/w/32)*r.core.columns+math.floor(tile%w/32)
			tracking[key]=tracking[key] or {};tracking[key][tile]=tracking[key][tile] or frame
		end
	end
	r:applyTileStates(s.tileState,refs)
end
local function capture(count)
	local refs={};for i=1,count do local tile=foreign[i];table.insert(refs,tile);buffer.writeu16(s.tileState,tile*2,if buffer.readu16(s.tileState,tile*2)==1 then 2 else 1) end
	r:applyTileStates(s.tileState,refs)
end
local directions={}
local function tick()
	s.tick+=1;local moved={}
	for id=1,500 do
		local u=s.units[id];local x=u.tile%w;local direction=directions[id] or 1
		if x==w-1 then direction=-1 elseif x==0 then direction=1 end
		directions[id]=direction;u.lastTile=u.tile;u.tile+=direction;table.insert(moved,id)
	end
	s.UnitsMoved:Fire(moved);s.TickApplied:Fire(s.tick)
end
local function sweep(i)
	local c=table.clone(fit);c.scale=.75+2.25*(.5+.5*math.sin(i*.022))
	c.offsetX+=math.sin(i*.025)*250;c.offsetY+=math.cos(i*.017)*160;r:setCamera(c)
end
local serial=10000
local destroyed=0
local function prepareBlast()
	local refs={}
	for y=240,440 do for x=950,1250 do local tile=y*w+x
		if bit32.btest(buffer.readu8(r.core.terrain,tile),128) then buffer.writeu16(s.tileState,tile*2,1);table.insert(refs,tile) end
	end end
	r:applyTileStates(s.tileState,refs);destroyed=0
	for id=1,320 do s.units[20000+id]={id=20000+id,type='Defense Post',tile=(280+id%50)*w+1080+id%80,owner=1,active=true,level=2} end
	s.UnitsChanged:Fire({},{});r.scene.effects.state:clear();r.scene.effects.masks:clear()
	for _=1,1000 do e.now+=1/60;r:step();if r.core.pending==0 and r.coasts:ready() then break end end
end
local function impact(kind,x,y,destruction)
	local radius=s:config():nukeMagnitudes(kind).outer
	local refs={}
	for yy=math.max(0,y-radius),math.min(h-1,y+radius) do for xx=math.max(0,x-radius),math.min(w-1,x+radius) do
		local tile=yy*w+xx
		if (xx-x)^2+(yy-y)^2<=radius^2 and bit32.btest(buffer.readu8(r.core.terrain,tile),128) then
			buffer.writeu16(s.tileState,tile*2,8192);table.insert(refs,tile)
		end
	end end
	r:applyTileStates(s.tileState,refs)
	local updates={}
	serial+=1;table.insert(updates,{id=serial,type=kind,tile=y*w+x,targetTile=y*w+x,owner=2,active=false,reachedTarget=true})
	for _=1,destruction do destroyed+=1;local u=s.units[20000+destroyed];if u then u.active=false;table.insert(updates,u) end end
	s.UnitsChanged:Fire(updates,{})
end
local function percentile(a,p) table.sort(a);return a[math.max(1,math.ceil(#a*p))] or 0 end
local function run(name,n,action)
	for _=1,180 do e.now+=1/60;r:step() end
	r:setCamera(fit);tracking={};tipAges={};requestedTips,offscreenTips=0,0;components,peaks={},{};r.profiler:reset()
	e.recordUploads=true;e.uploads={};local samples,own,anyAge={}, {},{}
	local before=r:metrics();local maxCreates,maxDeletes,maxImages,maxGap,lastTipUpload,maxRailCreates,maxRailDeletes=0,0,0,0,0,0,0,0
	for i=1,n do
		frame=i;frameMs=0;e.now+=1/60;local oldUploads=#e.uploads
		local creates,deletes=r.coasts.creates,r.coasts.deletes
		local railCreates,railDeletes=r.scene.railCreates or 0,r.scene.railDeletes or 0
		local tipsBefore=#tipAges;action(i)
		-- Foreground latency only: a tip leaving the viewport is censored, not
		-- counted as a visible stall when the camera returns much later.
		for _,tips in tracking do for tile in tips do if not visible(tile) then tips[tile]=nil;offscreenTips+=1 end end end
		r:step();table.insert(samples,frameMs)
		maxCreates=math.max(maxCreates,r.coasts.creates-creates);maxDeletes=math.max(maxDeletes,r.coasts.deletes-deletes)
		maxRailCreates=math.max(maxRailCreates,(r.scene.railCreates or 0)-railCreates);maxRailDeletes=math.max(maxRailDeletes,(r.scene.railDeletes or 0)-railDeletes)
		if #tipAges>tipsBefore then if lastTipUpload>0 then maxGap=math.max(maxGap,i-lastTipUpload) end;lastTipUpload=i end
		local sample=r.core.recentAges[r.core.recentCursor]
		if sample and sample.frame==r.core.frames then table.insert(anyAge,sample.age);if sample.ownAge>=0 then table.insert(own,sample.ownAge) end end
		local images={};for j=oldUploads+1,#e.uploads do images[e.uploads[j]]=true end;local imagesCount=0;for _ in images do imagesCount+=1 end
		assert(imagesCount<=1,'one-image rule');maxImages=math.max(maxImages,imagesCount)
	end
	local measured=r:metrics();local means=table.clone(components);local maxes=table.clone(peaks);local uploadCalls=#e.uploads
	local drain=0
	while (r.core.pending>0 or r.core.deferred.count>0 or not r.coasts:ready()) and drain<5000 do
		drain+=1;frame=n+drain;e.now+=1/60;r:step()
	end
	assert(drain<5000,'backlog stuck')
	local sum=0;for _,ms in samples do sum+=ms end;for key,value in means do means[key]=value/n end
	local hash=1;for _,page in r.core.pages do for off=0,buffer.len(page.pixels)-4,4 do hash=(hash*31+buffer.readu32(page.pixels,off))%2147483647 end end
	local objects=0;for _,o in e.objects do if not o.destroyed and o:IsA('GuiObject') then objects+=1 end end
	local timings={};for key,value in measured do if key:sub(1,7)=='timing_' then timings[key]=value end end
	local result={scenario=name,variant=fixture.variant,ref=process.args[3] or 'working',frames=n,meanMs=sum/n,p95Ms=percentile(samples,.95),maxMs=percentile(samples,1),
		frameSamplesMs=samples,
		ownP95Frames=percentile(own,.95),ownMaxFrames=percentile(own,1),allP95Frames=percentile(anyAge,.95),allMaxFrames=percentile(anyAge,1),
		frontTipP95Frames=percentile(tipAges,.95),frontTipMaxFrames=percentile(tipAges,1),frontTipSamples=#tipAges,maxFrontUploadGap=maxGap,
		requestedTips=requestedTips,offscreenTips=offscreenTips,
		componentMeanMs=means,componentMaxMs=maxes,timing=timings,uploadCalls=uploadCalls,maxImagesPerFrame=maxImages,guiObjects=objects,
		coastCreates=measured.coastViewCreates-before.coastViewCreates,coastDeletes=measured.coastViewDeletes-before.coastViewDeletes,
		maxCoastCreatesPerFrame=maxCreates,maxCoastDeletesPerFrame=maxDeletes,drainFrames=drain,fingerprint=hash,
		railCreates=(r.scene.railCreates or 0)-(before.railCreates or 0),maxRailCreatesPerFrame=maxRailCreates,maxRailDeletesPerFrame=maxRailDeletes,
		maskVisits=measured.falloutMaskVisits,fxSprites=measured.fxSprites,pendingBlocks=measured.pendingBlocks}
	result.recentOwnFrontUploadP95Frames=measured.recentOwnFrontUploadP95Frames
	result.recentOwnFrontUploadMaxFrames=measured.recentOwnFrontUploadMaxFrames
	local line=serde.encode('json',result);print(line);table.insert(records,line)
end
run('capture178kFixed',720,function(i) if i==1 then capture(178000) end;if i%6==0 then fronts(12);tick() end end)
run('capture178kSweep',720,function(i) sweep(i);if i==1 then capture(178000) end;if i%6==0 then fronts(12);tick() end end)
run('front1200Sweep',480,function(i) sweep(i);if i%6==0 then fronts(1200);tick() end end)
prepareBlast()
run('atomHydrogenSweep',600,function(i)
	sweep(i);if i%6==0 then fronts(12);tick() end
	if i==1 then impact('Atom Bomb',1100,300,40) elseif i==61 then impact('Hydrogen Bomb',1130,320,120) end
end)
prepareBlast()
run('mirv24Sweep',600,function(i)
	sweep(i);if i%6==0 then fronts(12);tick() end
	if i<=19 and i%6==1 then for k=1,6 do impact('MIRV Warhead',1080+k*10,290+math.floor(i/6)*15,12) end end
end)
run('cameraOnlySweep',480,function(i) sweep(i);if i%6==0 then tick() end end)
run('railCameraSweep',600,function(i)
	local c=table.clone(fit);c.scale=2+6*(.5+.5*math.sin(i*.025))
	c.offsetX=1000+math.sin(i*.021)*100-w/2-(c.viewportWidth/2-w/2)/c.scale
	c.offsetY=493-h/2-(c.viewportHeight/2-h/2)/c.scale;r:setCamera(c)
	if i%6==0 then tick() end
end)
r:destroy();for _,img in e.images do assert(img.destroyed,'image leak') end
if process.args[2] then fs.writeFile(process.args[2],table.concat(records,'\n')..'\n') end
