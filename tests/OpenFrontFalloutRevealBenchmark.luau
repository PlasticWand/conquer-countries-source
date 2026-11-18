--!strict
-- Synthetic Hydrogen impact, real RGBA buffer sink. Excludes native/GPU/layout.
local fs,luau,serde,process=require('@lune/fs'),require('@lune/luau'),require('@lune/serde'),require('@lune/process')
local H=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
local Core=H.Core
local function stats(values:{number}):any
	table.sort(values)
	return {p50=values[math.ceil(#values*.5)],p95=values[math.ceil(#values*.95)],max=values[#values],samples=#values}
end
local function trial(enabled:boolean):any
		local w,h=320,256
		local terrain,states=buffer.create(w*h),buffer.create(w*h*2);buffer.fill(terrain,0,128)
		for tile=0,w*h-1 do buffer.writeu16(states,tile*2,1) end
		local sink=H.sink(w,h);local core=Core.new(terrain,w,h,sink.backend)
		Core.setRoster(core,{{id='me',smallID=1,playerType='HUMAN'}})
		Core.setLocalPlayer(core,1);Core.applyTileStates(core,states);H.drain(core,1e9)
		Core.setViewport(core,{x0=60,y0=0,x1=260,y1=256})
		core.falloutReveal.enabled=enabled
		local changed={}
		for y=28,228 do for x=60,260 do
			local d=(x-160)^2+(y-128)^2
			if d<=80^2 or (d<=100^2 and (x*17+y*31)%2==0) then
				local tile=y*w+x;buffer.writeu16(states,tile*2,8192);table.insert(changed,tile)
			end
		end end
		local started=os.clock();Core.applyTileStates(core,states,changed,{own={},fallout={}})
		local dispatch=(os.clock()-started)*1000
		local turns,firstUploads,firstPixels=0,core.uploads,core.uploadedBytes
		local frames={}
		while Core.hasPending(core) do
			turns+=1;assert(turns<300,'benchmark failed to drain')
			local result=Core.step(core,2.5,81920);table.insert(frames,result.ms)
		end
		local result={frames=frames,delay=turns,dispatch=dispatch,commit=core.falloutReveal.commitMs,
			uploads=core.uploads-firstUploads,pixels=(core.uploadedBytes-firstPixels)/4,scratch=buffer.len(core.falloutReveal.scratch)}
		Core.destroy(core)
		return result
end
local function summarize(trials:{any}):any
	local frames,delays,dispatch,commit={}, {}, {}, {}
	local uploads,pixels,maxScratch=0,0,0
	for _,r in trials do
		for _,v in r.frames do table.insert(frames,v) end
		table.insert(delays,r.delay);table.insert(dispatch,r.dispatch);table.insert(commit,r.commit)
		uploads+=r.uploads;pixels+=r.pixels;maxScratch=math.max(maxScratch,r.scratch)
	end
	return {frameMs=stats(frames),dispatchMs=stats(dispatch),completionFrames=stats(delays),commitMs=stats(commit),
		meanNativeWrites=uploads/#trials,meanUploadedPixels=pixels/#trials,maxRetainedScratchBytes=maxScratch}
end
-- Discard one warmup per mode, then alternate pair order to reduce order/GC bias.
trial(false);trial(true)
local baseline,coherent={},{}
for pair=1,12 do
	if pair%2==0 then table.insert(coherent,trial(true));table.insert(baseline,trial(false))
	else table.insert(baseline,trial(false));table.insert(coherent,trial(true)) end
end
print(serde.encode('json',{baseCommit=process.args[1] or 'uncommitted',workingTree=true,
	workload='12 synthetic Hydrogen impacts: inner 80/outer 100, 320x256 land, visible 200 tiles across',
	budgetMs=2.5,pixelBudget=81920,excludes='Roblox native upload, GUI/layout, GPU, replication and phone performance',
	baseline=summarize(baseline),coherent=summarize(coherent)},true))
