local fs, luau, serde, process = require('@lune/fs'), require('@lune/luau'), require('@lune/serde'), require('@lune/process')
local source = fs.readFile('tests/OpenFrontEffectsHarness.luau')
source = source:gsub('image.WritePixelsBuffer=function%(_,_,size,pixels%)', 'image.WritePixelsBuffer=function(_,_,size,pixels) env.frameWrites = (env.frameWrites or 0) + 1; image.writes = (image.writes or 0) + 1;')
local e = luau.load(source)()()
local terrain = buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local w,h=2000,1000
local state = e.client()
state.width,state.height,state.you,state.startTick,state.tick=w,h,1,200,2000
state.tileState=buffer.create(w*h*2)
state.players,state.rosterOrder,state.names={},{},{}
local roster={}
for id=1,473 do
 local kind=if id==1 then 'HUMAN' elseif id<=73 then 'NATION' else 'BOT'
 local x,y=(id-1)%43*46+20,math.floor((id-1)/43)*87+20
 state.players[id]={id=`p{id}`,smallID=id,name=`Player {id}`,displayName=`Player {id}`,type=kind,troops=100000,alive=true,tiles=1000,allies={},embargoes={}}
 state.rosterOrder[id]=id;state.names[id]={x=x,y=y,size=20}
 roster[id]={id=`p{id}`,smallID=id,playerType=kind}
end
for tile=0,w*h-1 do
 local b=buffer.readu8(terrain,tile)
 if bit32.btest(b,128) and bit32.band(b,31)~=31 then
  buffer.writeu16(state.tileState,tile*2,1+math.floor((tile%w)/46)%43+math.floor(math.floor(tile/w)/87)%11*43)
 end
end
local parent=e.instance('Frame');parent.AbsoluteSize=require('@lune/roblox').Vector2.new(1920,1080)
local mode=process.args[1] or 'incremental'
local t=os.clock()
local r=e.Renderer.new(parent,terrain,w,h,{autoStep=false,firstPaint=mode})
r:setRoster(roster);r:applyTileStates(state.tileState);r:attachState(state)
local setup=(os.clock()-t)*1000
local times,uploads={},0
local frames=0
repeat
 frames+=1;e.frameWrites=0
 t=os.clock();local out=r:step();times[frames]=(os.clock()-t)*1000
 uploads+=e.frameWrites
 if mode=='full' then assert(e.frameWrites<=1,'multiple image uploads in loading frame') end
 assert(frames<10000,'load stalled')
until (if mode=='full' then r:isReady() else r.core.pending==0)
table.sort(times);local total=0;for _,n in times do total+=n end
local allWrites,pageWrites=0,0
for _,img in e.images do allWrites+=img.writes or 0;if img.Size.Y==h then pageWrites+=img.writes or 0 end end
print(serde.encode('json',{mode=mode,frames=frames,setupMs=setup,cpuMs=total,p50=times[math.ceil(frames*.5)],p95=times[math.ceil(frames*.95)],max=times[frames],nativeWriteShimCalls=uploads,allNativeWriteShimCalls=allWrites,pageWriteCalls=pageWrites,metrics=r:metrics()}))
r:destroy()
