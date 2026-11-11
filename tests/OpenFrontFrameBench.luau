local fs,luau,serde,process= require('@lune/fs'),require('@lune/luau'),require('@lune/serde'),require('@lune/process')
local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
source=source:gsub('local o: any = {ClassName=class','local values: any = {ClassName=class')
source=source:gsub('o.GetPropertyChangedSignal=function',[[local o: any = setmetatable({}, {__index=values,__newindex=function(_,key,value)
 if type(value)~='function' then env.propertyWrites=(env.propertyWrites or 0)+1 end
 values[key]=value
 end})
 o.GetPropertyChangedSignal=function]])
source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then','node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
local e=luau.load(source)()()
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local w,h=2000,1000
local state=e.client();state.width,state.height,state.you,state.startTick,state.tick=w,h,1,200,2000
state.tileState=buffer.create(w*h*2);state.players,state.rosterOrder,state.names={},{},{}
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
 if bit32.btest(b,128) and bit32.band(b,31)~=31 then buffer.writeu16(state.tileState,tile*2,1+math.floor((tile%w)/46)%43+math.floor(math.floor(tile/w)/87)%11*43) end
end
state.units={}
local kinds={'City','Port','Factory','Defense Post','SAM Launcher','Missile Silo'}
for id=1,150 do state.units[id]={id=id,type=kinds[(id-1)%6+1],owner=id%473+1,tile=id*12347%(w*h),active=true,level=1} end
for id=151,250 do state.units[id]={id=id,type=if id<=240 then 'Transport' else 'Atom Bomb',owner=id%473+1,tile=id*12347%(w*h),lastTile=id*12347%(w*h),active=true,level=1,targetTile=300000+id} end
local parent=e.instance('Frame');parent.AbsoluteSize=require('@lune/roblox').Vector2.new(1914,829)
local r=e.Renderer.new(parent,terrain,w,h,{autoStep=false,firstPaint='full'})
r:setRoster(roster);r:applyTileStates(state.tileState);r:attachState(state)
repeat e.now+=1/60;r:step() until r:isReady()
local function frame(i)
 e.now+=1/60
 if i%6==0 then
  state.tick+=1
  local moved={}
  for id=151,250 do local u=state.units[id];u.lastTile=u.tile;u.tile=(u.tile+1)%(w*h);table.insert(moved,id) end
  state.UnitsChanged:Fire({},{});state.UnitsMoved:Fire(moved,state.tick)
  for _,p in state.players do p.troops+=1 end
  state.StatsChanged:Fire();state.TickApplied:Fire(state.tick)
 end
 r:step()
end
for i=1,120 do frame(i) end
e.propertyWrites=0;r:resetTimings()
local started=os.clock();local allocated=#e.objects
for i=1,1200 do frame(i) end
local cpu=(os.clock()-started)*1000
local gui,all=0,0
for _,o in e.objects do if not o.destroyed then all+=1;if o.ClassName=='Frame' or o.ClassName=='ImageLabel' or o.ClassName=='TextLabel' then gui+=1 end end end
print(serde.encode('json',{scenario='World terrain, 473 fixed anchors, 150 structures + 100 mobiles (10 nukes), 10 Hz confirmed updates, 1200 unpaced logical frames, native-property shim; excludes GUI layout/GPU',cpuMs=cpu,propertyWrites=e.propertyWrites,newInstances=#e.objects-allocated,liveGuiObjects=gui,liveInstances=all,metrics=r:metrics()}))
r:destroy()
