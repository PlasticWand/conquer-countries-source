--!strict
-- Exact runtime contour/colour buffers; Python only lays out the comparison.
local fs,luau,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/serde')
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local G,C=H.require(root.CoastGeometry),H.require(root.CoastRaster)
local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
local Core=raster.Core
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local builder=G.new(terrain,2000,1000,4)
while not G.step(builder,1e9,1e9) do end
fs.writeDir('capture/coasts')
for _,resolution in {2,4} do
if resolution==2 then
	local alternate=G.new(terrain,2000,1000,2); while not G.step(alternate,1e9,1e9) do end
	builder.geometry=alternate.geometry
end
local crop={x=930,y=220,w=72,h=56,zoom=10,resolution=resolution}
for _,mode in {'neutral','owned'} do
	local sink=raster.sink(2000,1000); local core=Core.new(terrain,2000,1000,sink.backend)
	Core.setRoster(core,{{id='a',smallID=1,playerType='HUMAN',cosmetics={color={color='#b94a42'}}},
		{id='b',smallID=2,playerType='HUMAN',cosmetics={color={color='#49a0b8'}}}})
	local states=buffer.create(4000000)
	if mode=='owned' then for tile=0,1999999 do
		if bit32.btest(buffer.readu8(terrain,tile),128) then buffer.writeu16(states,tile*2,if tile%2000<970 then 1 else 2) end
	end end
	Core.applyTileStates(core,states); raster.drain(core,1e9)
	local out=buffer.create(crop.w*crop.h*4)
	for y=0,crop.h-1 do for x=0,crop.w-1 do buffer.writeu32(out,(y*crop.w+x)*4,sink.pixel(crop.x+x,crop.y+y)) end end
	local name=mode..(if resolution==2 then '-2x' else '')
	fs.writeFile('capture/coasts/'..name..'.rgba',buffer.tostring(out))
	local r=C.new(builder.geometry,resolution,1e9)
	while C.pending(r) do C.prepare(r,core,1e9,1e9) end
	local patches={}
	for id,chunk in builder.geometry.chunks do
		if chunk.x<crop.x+crop.w and chunk.x+32>crop.x and chunk.y<crop.y+crop.h and chunk.y+32>crop.y then
			local size=32*resolution
			local slot=r.slots[id]; local page=r.pages[slot.page]; local bytes=buffer.create(size*size*4)
			for row=0,size-1 do buffer.copy(bytes,row*size*4,page.pixels,((slot.y+row)*page.width+slot.x)*4,size*4) end
			local path=`capture/coasts/{name}-{id}.rgba`; fs.writeFile(path,buffer.tostring(bytes))
			table.insert(patches,{x=chunk.x,y=chunk.y,path=path})
		end
	end
	fs.writeFile('capture/coasts/'..name..'.json',serde.encode('json',{crop=crop,patches=patches}))
	Core.destroy(core)
end
end
