--!strict
-- Export exact runtime masks and a real World coast crop for visual review.
local fs,luau=require('@lune/fs'),require('@lune/luau')
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local Art=H.require(root.ShipArt)
fs.writeDir('capture/smooth-look')
local art=Art.new(); art.needed=true; Art.build(art,1e9,1e9)
fs.writeFile('capture/smooth-look/ships.rgba',buffer.tostring(art.pixels))
local harness=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
local Core=harness.Core
local world=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
-- North-west Europe crop: real terrain, synthetic two-owner boundary.
local w,h,x0,y0=128,96,920,200
local terrain,states=buffer.create(w*h),buffer.create(w*h*2)
for y=0,h-1 do for x=0,w-1 do
	local tile=y*w+x; local b=buffer.readu8(world,(y+y0)*2000+x+x0)
	buffer.writeu8(terrain,tile,b)
	if bit32.btest(b,128) then buffer.writeu16(states,tile*2,if x<50+math.floor(y*.45) then 1 else 2) end
end end
for _,soft in {false,true} do
	local sink=harness.sink(w,h); local s=Core.new(terrain,w,h,sink.backend)
	Core.setRoster(s,{{id='a',smallID=1,playerType='HUMAN',cosmetics={color={color='#b94a42'}}},
		{id='b',smallID=2,playerType='HUMAN',cosmetics={color={color='#49a0b8'}}}})
	Core.setEdgeSmoothing(s,soft); Core.applyTileStates(s,states); harness.drain(s,1e9)
	fs.writeFile('capture/smooth-look/'..(if soft then 'soft' else 'source')..'.rgba',buffer.tostring(s.pages[1].pixels))
	Core.destroy(s)
end
