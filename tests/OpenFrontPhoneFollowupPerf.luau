--!strict
-- Bounded synthetic World relation-dispatch proxy, not native/device timings.
-- Baseline is our published cba537a Core, loaded with read-only git show.
local fs,luau,process,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/process'),require('@lune/serde')
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local before=process.args[1]=='before'
local source=fs.readFile('src/client/Map/OpenFront/RasterCore.luau')
if before then
	local result=process.exec('git',{'show','cba537a:src/client/Map/OpenFront/RasterCore.luau'})
	assert(result.ok,result.stderr);source=result.stdout
end
local C=luau.load(source,{environment={script=root.RasterCore,require=H.require},injectGlobals=true})()
local width,height=2000,1000
local terrain,states=buffer.create(width*height),buffer.create(width*height*2)
buffer.fill(terrain,0,128)
for y=0,height-1 do for x=0,width-1 do buffer.writeu16(states,(y*width+x)*2,if x<1900 then 1 else 2) end end
local core=C.new(terrain,width,height,{write=function() end,destroy=function() end})
C.setRoster(core,{{id='you',smallID=1,playerType='HUMAN'},{id='enemy',smallID=2,playerType='NATION'},{id='distant',smallID=3,playerType='NATION'}})
C.setLocalPlayer(core,1);C.applyTileStates(core,states)
local matrix=buffer.create(16);C.setRelations(core,{size=4,data=matrix})
local coldStarted=os.clock()
while core.pending>0 do C.step(core,1e9,1e9) end
local coldRasterMs=(os.clock()-coldStarted)*1000
local records={}
for _,case in {{name='nonadjacent',other=3},{name='touching',other=2}} do
	buffer.writeu8(matrix,4+case.other,1);buffer.writeu8(matrix,case.other*4+1,1)
	local started=os.clock();C.setRelations(core,{size=4,data=matrix});local ms=(os.clock()-started)*1000
	local dirty=0
	for key=0,core.blocks-1 do for row=0,31 do
		local mask=buffer.readu32(core.dirtyRows,key*128+row*4)
		while mask~=0 do dirty+=1;mask=bit32.band(mask,mask-1) end
	end end
	table.insert(records,serde.encode('json',{baseline=if before then 'cba537a' else 'working-tree',case=case.name,width=width,height=height,
		dispatchMs=ms,pendingBlocks=core.pending,dirtyPixels=dirty,coldRasterMs=coldRasterMs,cpuBufferBytes=C.metrics(core).cpuBufferBytes}))
	while core.pending>0 do C.step(core,1e9,1e9) end
end
C.destroy(core)
local output=table.concat(records,'\n')..'\n'
fs.writeFile('tests/fixtures/OpenFrontPhoneFollowupPerf.'..(if before then 'before' else 'after')..'.jsonl',output)
print(output)
