--!strict
-- Reproducible desktop Lua/property proxy, not engine GUI/GPU/phone timing.
local fs, luau, rb, serde = require('@lune/fs'), require('@lune/luau'), require('@lune/roblox'), require('@lune/serde')
if require('@lune/process').args[1]=='late' then
	luau.load(fs.readFile('tests/OpenFrontLatePerf.luau'))()
	return
end
if require('@lune/process').args[1]=='names' then
	luau.load(fs.readFile('tests/OpenFrontNamesPerf.luau'))()
	return
end
local source = fs.readFile('tests/OpenFrontEffectsHarness.luau')
source = source:gsub('local o: any = {ClassName=class', 'local values: any = {ClassName=class')
source = source:gsub('o.GetPropertyChangedSignal=function', [[local o: any = setmetatable({}, {__index=values,__newindex=function(_,key,value)
	if type(value)~='function' then env.propertyWrites=(env.propertyWrites or 0)+1 end
	values[key]=value
end})
o.GetPropertyChangedSignal=function]])
source = source:gsub('node==root.BuildPreviewController or node==root.MapInput then',
	'node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
local make = luau.load(source)()
local terrain = buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local function quantile(a, q) local b=table.clone(a); table.sort(b); return b[math.clamp(math.ceil(#b*q),1,#b)] end
local function mean(a) local sum=0; for _,v in a do sum+=v end; return sum/#a end
local e=make()
local state=e.client()
state.width,state.height,state.you,state.startTick,state.tick=2000,1000,1,0,2000
state.tileState=buffer.create(2000*1000*2)
state.names,state.players,state.rosterOrder,state.units={},{},{},{}
local roster={}
for id=1,73 do
	local kind=if id==1 then 'HUMAN' else 'NATION'
	state.players[id]={id=`p{id}`,smallID=id,name=`Player {id}`,type=kind,troops=100000,alive=true,tiles=1000,allies={},embargoes={}}
	state.rosterOrder[id]=id; roster[id]={id=`p{id}`,smallID=id,playerType=kind}
	state.names[id]={x=(id-1)%13*150+70,y=math.floor((id-1)/13)*160+70,size=20}
end
for tile=0,2000000-1 do
	if bit32.btest(buffer.readu8(terrain,tile),128) then buffer.writeu16(state.tileState,tile*2,1+math.floor(tile/2000/100)%73) end
end
local kinds={'City','Port','Factory','Defense Post','SAM Launcher','Missile Silo'}
for id=1,600 do
	local tile=(25+math.floor((id-1)/30)*48)*2000+25+(id-1)%30*65
	state.units[id]={id=id,type=if id<=480 then kinds[(id-1)%6+1] else (if id<=590 then 'Trade Ship' else 'Atom Bomb'),
		owner=(id-1)%73+1,tile=tile,lastTile=tile,active=true,level=if id%12==0 then 2 else 1,
		underConstruction=id<=24,constructionStartTick=1995,targetTile=tile+10,missileTimerQueue={}}
end
local parent=e.instance('Frame'); parent.AbsoluteSize=rb.Vector2.new(1530,613)
local r=e.Renderer.new(parent,terrain,2000,1000,{autoStep=false,firstPaint='full'})
r:setRoster(roster); r:applyTileStates(state.tileState); r:attachState(state)
repeat e.now+=1/60; r:step() until r:isReady()
local origin=table.clone(r.camera)
local function frame(i,mode)
	e.now+=1/60
	local dispatch=os.clock()
	if mode~='idle' and i%6==0 then
		state.tick+=1
		local moved={}
		for id=481,600 do local u=state.units[id]; u.lastTile,u.tile=u.tile,(u.tile+1)%2000000; table.insert(moved,id) end
		state.UnitsMoved:Fire(moved,state.tick)
		local refs={}
		for patch=0,59 do
			local x=(patch*131+state.tick*3)%1970; local y=(patch*71+state.tick)%980
			for k=0,19 do local tile=y*2000+x+k; buffer.writeu16(state.tileState,tile*2,1+state.tick%73); table.insert(refs,tile) end
		end
		r:applyTileStates(state.tileState,refs); state.TickApplied:Fire(state.tick)
	end
	if mode=='pan' then
		local camera=table.clone(origin); camera.offsetX=origin.offsetX+math.sin(i*.02)*100; r:setCamera(camera)
	end
	dispatch=(os.clock()-dispatch)*1000
	local start=os.clock(); r:step(); return (os.clock()-start)*1000,dispatch
end
for _,mode in {'idle','busy','pan','zoom4'} do
	if mode=='zoom4' then local camera=table.clone(origin); camera.scale=4; camera.offsetX,camera.offsetY=0,0; r:setCamera(camera) end
	for i=1,120 do frame(i,mode) end
	e.propertyWrites=0; r:resetTimings()
	local samples,dispatch={},{}
	local allocated=#e.objects
	local uploads,bytes=r.core.uploads,r.core.uploadedBytes
	r.core.maxUploadAgeFrames=0
	local pendingMax=0
	for i=1,600 do local step,send=frame(i,mode); table.insert(samples,step); table.insert(dispatch,send); pendingMax=math.max(pendingMax,r.core.pending) end
	local gui,visible,structureGui=0,0,0
	for _,o in e.objects do
		if not o.destroyed and (o.ClassName=='Frame' or o.ClassName=='ImageLabel' or o.ClassName=='TextLabel') then gui+=1 end
	end
	for _,view in r.scene.unitViews do
		if view.root.Visible then visible+=1 end
		if view.structure then
			for _,o in e.objects do if not o.destroyed and (o==view.root or o.Parent==view.root or (o.Parent and o.Parent.Parent==view.root)) then structureGui+=1 end end
		end
	end
	print(serde.encode('json',{mode=mode,viewport={1530,613},units=600,structures=480,mobiles=120,players=73,
		stepMeanMs=mean(samples),stepP50Ms=quantile(samples,.5),stepP95Ms=quantile(samples,.95),stepMaxMs=quantile(samples,1),
		dispatchMeanMs=mean(dispatch),writes=e.propertyWrites,newInstances=#e.objects-allocated,gui=gui,structureGui=structureGui,
		visibleUnits=visible,pendingMax=pendingMax,pendingEnd=r.core.pending,uploadAgeMax=r.core.maxUploadAgeFrames,
		uploads=r.core.uploads-uploads,uploadBytes=r.core.uploadedBytes-bytes,metrics=r:metrics()}))
end
r:destroy()
for _,img in e.images do assert(img.destroyed,'image leak') end
