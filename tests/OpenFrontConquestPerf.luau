--!strict
-- Serial, real-World renderer workload. Wall times include instrumented GUI
-- property shims, not native GUI/layout, EditableImage writes, GPU or server.
local fs,luau,rb,serde,process=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox'),require('@lune/serde'),require('@lune/process')
local variant=process.args[1] or 'off'
local make=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
local e=make(process.args[3],process.args[3]~=nil); e.uis.TouchEnabled=false
e.policy.splitMapGuis=variant=='split' or variant=='both'
e.policy.deferredOwnership=variant=='deferred' or variant=='both'
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local w,h=2000,1000
local s=e.client();s.width,s.height,s.startTick,s.tick=w,h,0,100
s.units,s.names,s.players,s.rosterOrder={},{},{},{}
s.tileState=buffer.create(w*h*2)
local land,foreign={},{}
for tile=0,w*h-1 do
	local byte=buffer.readu8(terrain,tile)
	if bit32.btest(byte,128) and bit32.band(byte,31)~=31 then
		local owner=if tile%w<700 then 1 else 2+math.floor((tile%w-700)/130)+10*math.floor(tile/w/100)
		buffer.writeu16(s.tileState,tile*2,owner);table.insert(land,tile)
		if owner~=1 then table.insert(foreign,tile) end
	end
end
local roster={}
for id=1,140 do
	local x,y=if id==1 then 450 else 700+(id-2)%10*130,if id==1 then 500 else math.floor((id-2)/10)*70+30
	local p={id=`p{id}`,smallID=id,name=`Country {id}`,type=if id==1 then 'HUMAN' else 'NATION',playerType=if id==1 then 'HUMAN' else 'NATION',troops=100000,alive=true}
	s.players[id]=p;table.insert(s.rosterOrder,id);table.insert(roster,p)
	s.names[id]={x=x,y=y,size=18,display=true}
end
for id=1,1000 do
	local tile=land[(id*499)%#land+1]
	local kind=if id<=500 then ({'Transport','Trade Ship','Warship'})[(id-1)%3+1] else ({'City','Factory','Defense Post','SAM Launcher'})[(id-1)%4+1]
	s.units[id]={id=id,type=kind,owner=if id%4==0 then 1 else 2+id%100,active=true,tile=tile,lastTile=tile-1,health=100,maxHealth=100,level=2,
		warship=if kind=='Warship' then {state='patrolling',veterancy=1} else nil}
end
local host=e.instance('ScreenGui');host.DisplayOrder=0;host.Parent=e.playerGui
local parent=e.instance('Frame');parent.AbsoluteSize=rb.Vector2.new(1280,720);parent.Parent=host
local r=e.Renderer.new(parent,terrain,w,h,{autoStep=false,firstPaint='full',coasts=true,guiHost=host})
r:setRoster(roster);r:attachState(s);r:applyTileStates(s.tileState)
for _=1,10000 do e.now+=1/60;r:step();if r:isReady() then break end end
assert(r:isReady(),'first paint did not complete')
local fit=table.clone(r.camera)
-- Components are timed with the real host clock even though visual lifetime
-- clocks are controlled at 60Hz, so pending animations actually advance.
local component,peaks={},{}
local callDepth,rendererFrameMs=0,0
local function wrap(o,key,label)
	local original=o[key]
	o[key]=function(self,...)
		callDepth+=1
		local t=os.clock();local result=original(self,...)
		local ms=(os.clock()-t)*1000
		callDepth-=1;if callDepth==0 then rendererFrameMs+=ms end
		component[label]=(component[label] or 0)+ms;peaks[label]=math.max(peaks[label] or 0,ms)
		return result
	end
end
wrap(r,'applyTileStates','confirm');wrap(r,'setCamera','camera')
wrap(r.scene,'step','scene');wrap(r.scene,'setTick','tick')
wrap(r.scene.effects,'step','effects');wrap(r.scene.feel,'step','feel')
wrap(r.scene.defense,'tilesChanged','defenseConfirm')
wrap(e.Core,'applyTileStates','coreConfirm')
wrap(r,'step','step');wrap(r,'pulse','pulse')
for _,key in {'setMoved','unitUpdates','setUnits','setSpawnPhase','conquests'} do wrap(r.scene,key,key) end
local results={}
local cursor=0
local function confirm(count,scatter)
	local refs={}
	for k=1,count do
		local tile=foreign[(cursor+(if scatter then k*499 else k))%#foreign+1]
		buffer.writeu16(s.tileState,tile*2,if buffer.readu16(s.tileState,tile*2)==1 then 2 else 1)
		table.insert(refs,tile)
	end
	cursor=(cursor+count+67)%#foreign
	r:applyTileStates(s.tileState,refs)
end
local function tick()
	s.tick+=1;local ids={}
	for id=1,500 do local u=s.units[id];u.lastTile=u.tile;u.tile=(u.tile+1)%(w*h);table.insert(ids,id) end
	s.UnitsMoved:Fire(ids);s.TickApplied:Fire(s.tick)
end
local function sweep(i)
	local c=table.clone(fit)
	c.scale=fit.scale*(1+3*(.5+.5*math.sin(i*.018)))
	c.offsetX+=math.sin(i*.025)*180;c.offsetY+=math.cos(i*.021)*110
	r:setCamera(c)
end
local function feel(i)
	if i%30==1 then
		r:pulse('impact',500*w+800);r:pulse('loss',500*w+820)
		r.scene:conquests({{x=800,y=500,gold=1234,tickAge=0},{x=810,y=500,gold=2345,tickAge=0}})
		local id=2000+i;local u={id=id,type='City',owner=1,tile=500*w+800,active=true,level=1,underConstruction=true}
		s.units[id]=u;s.UnitsChanged:Fire({u},{})
	elseif i%30==12 then
		local u=s.units[2000+i-11];u.underConstruction=false;u.level=2;s.UnitsChanged:Fire({u},{})
	elseif i%30==29 then
		local id=2000+i-28;s.units[id]=nil;s.UnitsChanged:Fire({},{id})
	end
end
local function record(name,frames,step)
	for _=1,120 do e.now+=1/60;r:step() end
	component,peaks={},{};e.writes,e.changedWrites={},{};e.uploads={};e.recordUploads=true;r:setProfiling(true)
	local samples,raster,gross={},{},{};local uploadFrames,bytes,maxImages,maxPending=0,0,0,0
	local oldWrite=r.core.sink.write
	r.core.sink.write=function(page,x,y,ww,hh,pixels) bytes+=ww*hh*4;return oldWrite(page,x,y,ww,hh,pixels) end
	for i=1,frames do
		local oldUploads=#e.uploads;rendererFrameMs=0;local t=os.clock();e.now+=1/60;step(i);local output=r:step()
		table.insert(gross,(os.clock()-t)*1000);table.insert(samples,rendererFrameMs);table.insert(raster,output.ms)
		local images={};for j=oldUploads+1,#e.uploads do images[e.uploads[j]]=true end
		local n=0;for _ in images do n+=1 end;assert(n<=1,'more than one displayed image updated')
		maxImages=math.max(maxImages,n);if n>0 then uploadFrames+=1 end
		maxPending=math.max(maxPending,r.core.pending)
	end
	r.core.sink.write=oldWrite
	local timings=r:metrics();local measuredComponents=table.clone(component);local measuredPeaks=table.clone(peaks)
	local uploads=#e.uploads;local measuredBytes=bytes
	local drain=0
	while (r.core.pending>0 or r.core.deferred.count>0) and drain<2000 do drain+=1;e.now+=1/60;r:step() end
	assert(drain<2000,'backlog did not drain')
	table.sort(samples);table.sort(raster);table.sort(gross);local sum,grossSum=0,0
	for _,ms in samples do sum+=ms end;for _,ms in gross do grossSum+=ms end
	local objects,gui=0,0;for _,o in e.objects do if not o.destroyed then objects+=1;if o:IsA('GuiObject') then gui+=1 end end end
	for key,value in measuredComponents do measuredComponents[key]=value/frames end
	local timing={};for key,value in timings do if key:sub(1,7)=='timing_' then timing[key]=value end end
	local m=r:metrics()
	local fingerprint=1
	for _,page in r.core.pages do for offset=0,buffer.len(page.pixels)-4,4 do fingerprint=(fingerprint*31+buffer.readu32(page.pixels,offset))%2147483647 end end
	local data={variant=variant,scenario=name,frames=frames,meanMs=sum/frames,p95Ms=samples[math.ceil(frames*.95)],maxMs=samples[#samples],rasterP95Ms=raster[math.ceil(frames*.95)],componentMeanMs=measuredComponents,componentMaxMs=measuredPeaks,timing=timing,
		grossMeanMs=grossSum/frames,grossP95Ms=gross[math.ceil(frames*.95)],grossMaxMs=gross[#gross],
		uploads=uploads,uploadFrames=uploadFrames,uploadedBytes=measuredBytes,totalUploadsWithDrain=#e.uploads,maxImagesPerFrame=maxImages,guiObjects=gui,instances=objects,maxPendingBlocks=maxPending,drainFrames=drain,writes=e.writes,changedWrites=e.changedWrites,
		ownFraction=(#land-#foreign)/#land,landTiles=#land,queueFallbacks=r.core.deferred.fallbacks,coastSegments=m.coastSegments,fingerprint=fingerprint}
	local line=serde.encode('json',data);table.insert(results,line);print(line)
end
record('idle',240,function() end)
record('panZoom',360,function(i) sweep(i);if i%6==0 then tick() end end)
record('frontPanZoom',360,function(i) sweep(i);if i%6==0 then confirm(1200,true);tick() end end)
for _,count in {5000,15000,30000} do
	record(`conquest{count}PanZoom`,360,function(i)
		sweep(i);if i%6==0 then tick() end
		if i==1 or i==121 or i==241 then confirm(count,false) end
	end)
end
s.attacks={};for id=2,12 do table.insert(s.attacks,{outgoing=true,attacker=1,target=id,troops=10000}) end;s.AttacksChanged:Fire()
record('attacking30000PanZoom',360,function(i)
	sweep(i);if i%6==0 then tick() end
	if i==1 or i==121 or i==241 then confirm(30000,false) end
end)
record('feelPanZoom',240,function(i) sweep(i);feel(i);if i%6==0 then tick() end end)
r:destroy();for _,image in e.images do assert(image.destroyed,'image leaked') end
if process.args[2] then fs.writeFile(process.args[2],table.concat(results,'\n')..'\n') end
