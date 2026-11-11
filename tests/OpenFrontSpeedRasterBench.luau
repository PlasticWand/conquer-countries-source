--!strict
-- Serial full-World callback/raster comparison; native layout/upload/GPU excluded.
local fs,luau,process,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/process'),require('@lune/serde')
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local Policy=H.require(root.RenderPolicy)
local old=process.exec('git',{'show','f18c754:src/client/Map/OpenFront/RasterCore.luau'});assert(old.ok,old.stderr)
local before=luau.load(old.stdout,{environment={script=root.RasterCore,require=H.require},injectGlobals=true})()
local after=H.require(root.RasterCore)
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local w,h=2000,1000
local initial=buffer.create(w*h*2);local land={}
for tile=0,w*h-1 do
	local byte=buffer.readu8(terrain,tile)
	if bit32.btest(byte,128) and bit32.band(byte,31)~=31 then
		buffer.writeu16(initial,tile*2,1+math.floor(tile%w/100)%20);table.insert(land,tile)
	end
end
local results={};local fingerprints={}
local function hash(core)
	local v=1
	for _,page in core.pages do for offset=0,buffer.len(page.pixels)-4,4 do v=(v*31+buffer.readu32(page.pixels,offset))%2147483647 end end
	return v
end
for _,variant in {'baseline','deferred'} do
	local Core=if variant=='baseline' then before else after
	Policy.deferredOwnership=variant=='deferred'
	for _,scenario in {'front1200','scatter1200','capture26000'} do
		local calls,bytes=0,0
		local core=Core.new(terrain,w,h,{write=function(_,_,_,ww,hh,pixels)
			assert(buffer.len(pixels)==ww*hh*4);calls+=1;bytes+=ww*hh*4
		end,destroy=function() end})
		local roster={};for id=1,20 do roster[id]={id=`p{id}`,smallID=id,playerType='HUMAN'} end
		Core.setRoster(core,roster);Core.setLocalPlayer(core,1)
		local states=buffer.create(buffer.len(initial));buffer.copy(states,0,initial)
		Core.applyTileStates(core,states)
		local function pending() return core.pending>0 or (core.deferred and core.deferred.count>0) end
		while pending() do Core.step(core,1e9,1e9) end
		calls,bytes=0,0;local shaded=core.shadedPixels
		local callback,frame={},{};local drainFrames,total=0,0
		local batches=if scenario=='capture26000' then 4 else 16
		for batch=1,batches do
			local refs={};local count=if scenario=='capture26000' then 26000 else 1200
			for k=1,count do
				local index=if scenario=='scatter1200' then (k*499+batch*1987)%#land+1 else (k+batch*30000)%#land+1
				local tile=land[index];table.insert(refs,tile)
				buffer.writeu16(states,tile*2,1+(buffer.readu16(states,tile*2)+batch)%20)
			end
			local started=os.clock();Core.applyTileStates(core,states,refs)
			local ms=(os.clock()-started)*1000;table.insert(callback,ms);total+=ms
			local frames=0
			while pending() do
				frames+=1;assert(frames<10000)
				started=os.clock();Core.step(core,2.5,81920);ms=(os.clock()-started)*1000
				table.insert(frame,ms);total+=ms
			end
			drainFrames=math.max(drainFrames,frames)
		end
		table.sort(callback);table.sort(frame)
		local sum=0;for _,ms in callback do sum+=ms end
		local fingerprint=hash(core)
		if variant=='baseline' then fingerprints[scenario]=fingerprint else assert(fingerprints[scenario]==fingerprint,'framebuffer mismatch '..scenario) end
		local record={variant=variant,scenario=scenario,batches=batches,callbackMeanMs=sum/#callback,callbackPeakMs=callback[#callback],
			frameP95Ms=frame[math.ceil(#frame*.95)],framePeakMs=frame[#frame],totalCpuMs=total,
			shadedPixels=core.shadedPixels-shaded,uploadCalls=calls,uploadedBytes=bytes,maxDrainFrames=drainFrames,fingerprint=fingerprint,
			queueFallbacks=if core.deferred then core.deferred.fallbacks else 0}
		table.insert(results,serde.encode('json',record));print(results[#results]);Core.destroy(core)
	end
end
if process.args[1] then fs.writeFile(process.args[1],table.concat(results,'\n')..'\n') end
