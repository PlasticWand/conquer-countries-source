--!strict
-- Actual scene/property proxy, World, 600 ships, 60 owners, 10Hz movement.
-- Serial baseline/after only; no native GUI, GPU or real-phone simulation.
local fs,luau,rb,serde,process=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox'),require('@lune/serde'),require('@lune/process')
local variant=process.args[1] or 'after'
local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
source=source:gsub('local o: any = {ClassName=class','local values: any = {ClassName=class')
source=source:gsub('o.GetPropertyChangedSignal=function',[[local o: any
o=setmetatable({}, {__index=values,__newindex=function(_,key,value)
	if type(value)~='function' then env.propertyWrites=(env.propertyWrites or 0)+1 end
	if key=='Parent' then
		env.children=env.children or {}
		if values.Parent and env.children[values.Parent] then env.children[values.Parent][o]=nil end
		if value then env.children[value]=env.children[value] or {}; env.children[value][o]=true end
	end
	values[key]=value
end})
o.GetPropertyChangedSignal=function]])
source=source:gsub('for _, child in env.objects do if child.Parent==o then child:Destroy%(%) end end',
	'for child in table.clone((env.children or {})[o] or {}) do child:Destroy() end',1)
source=source:gsub('o.destroyed=true; o.Destroying:Fire%(%)','o.destroyed=true; o.Destroying:Fire(); o.Parent=nil',1)
source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then',
	'node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
local baseline=nil
if variant=='baseline' then
	local result=process.exec('git',{'show',(process.args[2] or '9787430')..':src/client/Map/OpenFront/SceneOverlay.luau'})
	assert(result.ok,result.stderr); baseline=result.stdout
	source=source:gsub('fs.readFile%(node.path%)',"(if node==root.SceneOverlay then baseline else fs.readFile(node.path))")
end
local make=luau.load(source,{environment={baseline=baseline},injectGlobals=true})()
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local e=make(); e.uis.TouchEnabled=true
local s=e.client(); s.width,s.height,s.startTick,s.tick=2000,1000,0,100
s.tileState=buffer.create(4000000); s.units,s.names,s.players,s.rosterOrder={},{},{},{}
local roster={}
for id=1,60 do
	s.players[id]={id=`p{id}`,smallID=id,name=`P{id}`,type='HUMAN',alive=true,troops=1000,allies={},embargoes={}}
	s.rosterOrder[id]=id; roster[id]={id=`p{id}`,smallID=id,playerType='HUMAN'}
end
for id=1,600 do
	local tile=(50+math.floor((id-1)/40)*60)*2000+20+(id-1)%40*48
	s.units[id]={id=id,type=({'Transport','Trade Ship','Warship'})[(id-1)%3+1],owner=(id-1)%60+1,
		active=true,tile=tile,lastTile=tile-1,health=100,maxHealth=100}
end
local parent=e.instance('Frame'); parent.AbsoluteSize=rb.Vector2.new(844,390)
local cold=os.clock()
local r=e.Renderer.new(parent,terrain,2000,1000,{autoStep=false,firstPaint='full'})
r:setRoster(roster); r:attachState(s)
local frames=0
repeat e.now+=1/60; r:step(); frames+=1; assert(frames<4096,'readiness did not drain') until r:isReady()
local coldMs=(os.clock()-cold)*1000
for _=1,120 do e.now+=1/60; r:step() end
local fit=table.clone(r.camera)
for _,mode in {'stationary','movingPan'} do
	local function step(i)
		e.now+=1/60
		if mode=='movingPan' then
			if i%6==0 then
				s.tick+=1; local ids={}
				for id,u in s.units do u.lastTile=u.tile; u.tile+=if i%120<60 then 1 else 2000; table.insert(ids,id) end
				s.UnitsMoved:Fire(ids); s.TickApplied:Fire(s.tick)
			end
			local c=table.clone(fit); c.offsetX+=math.sin(i*.03)*25; c.offsetY+=math.cos(i*.02)*15; r:setCamera(c)
		end
		r:step()
	end
	for i=1,120 do step(i) end
	e.recordUploads=true; e.uploads={}; e.propertyWrites=0
	local count=#e.objects; local samples={}; local sum=0
	for i=1,240 do local start=os.clock(); step(i); local ms=(os.clock()-start)*1000; sum+=ms; table.insert(samples,ms) end
	table.sort(samples)
	local gui,parts=0,0
	for _,o in e.objects do
		if not o.destroyed and (o.ClassName=='Frame' or o.ClassName=='ImageLabel' or o.ClassName=='TextLabel') then gui+=1 end
	end
	for _,v in r.scene.unitViews do parts+=#v.parts end
	print(serde.encode('json',{variant=variant,baseline=if variant=='baseline' then (process.args[2] or '9787430')..' SceneOverlay' else nil,mode=mode,ships=600,owners=60,
		frames=240,viewport='844x390',coldMs=coldMs,loadingFrames=frames,meanMs=sum/240,p95Ms=samples[228],maxMs=samples[240],
		propertyWrites=e.propertyWrites,newInstances=#e.objects-count,gui=gui,shipImages=parts,uploads=#e.uploads,metrics=r:metrics()}))
end
r:destroy(); for _,img in e.images do assert(img.destroyed,'image leak') end
