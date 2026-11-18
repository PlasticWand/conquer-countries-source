--!strict
-- Headless CPU only: no Roblox native image, GPU/layout, replication or phone.
local fs,luau,serde,process=require('@lune/fs'),require('@lune/luau'),require('@lune/serde'),require('@lune/process')
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local Reach=H.require(root.SabotageReach)
local results={}
for _,size in {{1024,512},{2048,1024}} do
	for trial=0,4 do -- one warmup, four recorded trials per size
	local w,h=size[1],size[2]
	local states=buffer.create(w*h*2)
	for y=math.floor(h*.12),math.floor(h*.88) do
		local east=math.floor(w*.7+math.sin(y*.03)*24)
		for x=math.floor(w*.08),east do buffer.writeu16(states,(y*w+x)*2,1) end
	end
	local c=Reach.new(w,h,function(tile) return bit32.band(buffer.readu16(states,tile*2),4095) end)
	local function finish():any
		local times={};local start=os.clock()
		while c:pending() do
			local at=os.clock();c:step();table.insert(times,(os.clock()-at)*1000)
		end
		table.sort(times)
		return {calls=#times,cpuMs=(os.clock()-start)*1000,p95Ms=times[math.ceil(#times*.95)] or 0,maxMs=times[#times] or 0}
	end
	c:prewarm(1,60);local cold=finish()
	local armed=os.clock();c:setActive(1,60);armed=(os.clock()-armed)*1000
	local sink=buffer.create(c.mw*c.mh*4)
	local writes,copyMs=0,0
	while not c:clean() do
		local y,rows=c:nextUpload();assert(y~=nil and rows~=nil)
		local pixels=buffer.create(c.mw*rows*4)
		local at=os.clock()
		buffer.copy(pixels,0,c.pixels,y*c.mw*4,buffer.len(pixels))
		buffer.copy(sink,y*c.mw*4,pixels)
		copyMs=math.max(copyMs,(os.clock()-at)*1000);writes+=1;c:uploaded(y)
	end
	local changes={}
	local y=math.floor(h*.5);local x=math.floor(w*.7+math.sin(y*.03)*24)
	for yy=y-8,y+8 do for xx=x-4,x+12 do
		local tile=yy*w+xx;buffer.writeu16(states,tile*2,1);table.insert(changes,tile)
	end end
	local scans=c.scans;local dispatch=os.clock();c:tilesChanged(changes);dispatch=(os.clock()-dispatch)*1000
	local delta=finish();delta.borderRows=c.scans-scans;delta.dispatchMs=dispatch
	local idle=os.clock();for _=1,1000 do c:step() end;idle=(os.clock()-idle)*1000/1000
	if trial>0 then table.insert(results,{trial=trial,width=w,height=h,cold=cold,delta=delta,idleMs=idle,
		warmArmMs=armed,initialWrites=writes,copySinkMaxMs=copyMs,maskBytes=buffer.len(c.pixels),borderEntries=c.borderEntries}) end
	c:destroy()
	end
end
local record={base=process.exec('git',{'rev-parse','HEAD'}).stdout:gsub('%s+$',''),workingTree=true,
	note='Unpaced Lune CPU slices and RGBA copy sink; excludes Roblox uploads, GUI/GPU, replication and phones. The .6ms budget is cooperative, not a hard frame ceiling.',trials=results}
local json=serde.encode('json',record,true)
fs.writeFile('tests/fixtures/OpenFrontSabotageReachBenchmark.json',json..'\n')
print(json)
