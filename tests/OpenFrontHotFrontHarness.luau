--!strict
-- Deterministic service-limited hot front: 10Hz edits, logical 60Hz frames.
local fs,luau,process=require('@lune/fs'),require('@lune/luau'),require('@lune/process')
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
return function(before: boolean?,width: number?,height: number?): any
	local w,h=width or 32,height or 32
	local source=fs.readFile('src/client/Map/OpenFront/RasterCore.luau')
	if before then
		local got=process.exec('git',{'show','3e591aa:src/client/Map/OpenFront/RasterCore.luau'})
		assert(got.ok,got.stderr); source=got.stdout
	end
	local env: any={now=0}
	env.Core=luau.load(source,{environment={script=root.RasterCore,require=H.require,os={clock=function() return env.now end}},injectGlobals=true})()
	env.sink=raster.sink(w,h)
	local terrain=buffer.create(w*h);buffer.fill(terrain,0,128)
	env.states=buffer.create(w*h*2)
	env.core=env.Core.new(terrain,w,h,env.sink.backend)
	env.Core.setRoster(env.core,{{id='you',smallID=1,playerType='HUMAN'},{id='enemy',smallID=2,playerType='NATION'},{id='other',smallID=3,playerType='NATION'}})
	env.Core.setLocalPlayer(env.core,1)
	env.Core.applyTileStates(env.core,env.states)
	while env.core.pending>0 do env.Core.step(env.core,1e9,1e9) end
	env.Core.setViewport(env.core,{x0=0,y0=0,x1=w,y1=h})
	table.clear(env.sink.writes)
	env.change=function(owner: number)
		local refs={}
		for tile=0,w*h-1 do buffer.writeu16(env.states,tile*2,owner);table.insert(refs,tile) end
		env.Core.applyTileStates(env.core,env.states,refs)
	end
	return env
end
