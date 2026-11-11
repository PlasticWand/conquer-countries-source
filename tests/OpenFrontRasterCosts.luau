--!strict
-- CPU raster diagnostic: full-resolution World, 150 dispersed 20-tile fronts.
-- Sink copies RGBA rows. No engine/GPU upload or real-phone timing is simulated.
local fs,luau,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/serde')
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local harness=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local process=require('@lune/process')
local variant=process.args[1] or 'off'
local baseline: string?=nil
if variant=='baseline' then
	local result=process.exec('git',{'show','9787430:src/client/Map/OpenFront/RasterCore.luau'})
	assert(result.ok,result.stderr); baseline=result.stdout
elseif variant=='before' then root.RasterCore.path='Temp/OpenFrontLateBaseline/RasterCore.luau' end
for _,mode in {'fronts','scattered'} do
	for _,probe in {false,true} do
		local code=baseline or fs.readFile(root.RasterCore.path)
		if probe then
			code=code:gsub('local kind, relation = 0, 0','local borderStarted=os.clock(); local kind, relation = 0, 0')
			code=code:gsub('(local defended = [^\n]+)','s.probeBorder=(s.probeBorder or 0)+(os.clock()-borderStarted); %1',1)
		end
		local Core=luau.load(code,{environment={script=root.RasterCore,require=H.require},injectGlobals=true})()
		local sink=harness.sink(2000,1000); local sinkMs=0
		local write=sink.backend.write
		sink.backend.write=function(...) local start=os.clock(); write(...); sinkMs+=(os.clock()-start)*1000 end
		local core=Core.new(terrain,2000,1000,sink.backend)
		if Core.setEdgeSmoothing then Core.setEdgeSmoothing(core,variant=='soft') end
		Core.setRoster(core,{{id='a',smallID=1,playerType='HUMAN'},{id='b',smallID=2,playerType='HUMAN'},{id='c',smallID=3,playerType='HUMAN'}})
		local state=buffer.create(4000000); for tile=0,1999999 do buffer.writeu16(state,tile*2,1) end
		Core.applyTileStates(core,state)
		local coldStart=os.clock()
		while core.pending>0 do Core.step(core,1e9,1e9) end
		local coldPaintMs=(os.clock()-coldStart)*1000
		local coldUploadPixels=core.paintedPixels
		local oldPixels,oldUploads=core.paintedPixels,core.uploads; local oldShaded=core.shadedPixels or oldPixels
		sinkMs=0; core.probeBorder=0
		local dispatch,total,frames,maxFrames,changed=0,0,0,0,0
		local oldCompose=core.composeMs or 0
		for tick=1,30 do
			local refs={}
			for patch=0,149 do
				local x=(patch*131+tick*3)%1970; local y=(patch*71+tick)%980
				for k=0,19 do
					local tile=if mode=='fronts' then y*2000+x+k else (math.floor(patch/50)*10*32+33+math.floor(k/2)*3)*2000+patch%50*32+1+(tick%2)+k%2*27
					table.insert(refs,tile); buffer.writeu16(state,tile*2,2+math.floor(tick/2)%2)
				end
			end
			for _,tile in refs do if buffer.readu16(core.tileState,tile*2)~=buffer.readu16(state,tile*2) then changed+=1 end end
			local start=os.clock(); Core.applyTileStates(core,state,refs); dispatch+=(os.clock()-start)*1000
			local count=0
			while core.pending>0 do local result=Core.step(core,2.5,131072); total+=result.ms; count+=1 end
			frames+=count; maxFrames=math.max(maxFrames,count)
		end
		print(serde.encode('json',{variant=variant,baseline=if variant=='baseline' then '9787430' else nil,mode=mode,probe=probe,coldPaintMs=coldPaintMs,coldUploadPixels=coldUploadPixels,submittedTiles=90000,changedTiles=changed,composeMs=if core.composeMs then core.composeMs-oldCompose else nil,dispatchMs=dispatch,rasterMs=total,sinkCopyMs=sinkMs,borderProbeMs=core.probeBorder*1000,
			uploadPixels=core.paintedPixels-oldPixels,shadedPixels=(core.shadedPixels or core.paintedPixels)-oldShaded,blocks=core.uploads-oldUploads,
			meanFrames=frames/30,maxFrames=maxFrames,cpuBufferBytes=Core.metrics(core).cpuBufferBytes}))
		Core.destroy(core)
	end

end
