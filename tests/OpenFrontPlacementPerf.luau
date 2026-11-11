--!strict
-- Paired synthetic CPU/property proxy. Fake query delay is not server CPU
-- or measured Roblox network latency. Never run beside another Lune benchmark.
local fs,luau,process,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/process'),require('@lune/roblox')
local revision=process.args[1]
local source=fs.readFile('tests/OpenFrontWideZoomHarness.luau')
source=source:sub(1,(source:find('local function stats%(values%)') :: number)-1)..'return make'
source=source:gsub("{'SceneOverlay','UnitVisuals'}","{'SceneOverlay','UnitVisuals','BuildPreviewController','EditableRenderer'}")
source=source:gsub('local values: any = {ClassName=class','local values: any = {ImageTransparency=0,ClassName=class')
source=source:gsub('overrides%[name%]=result.stdout',function() return [[local code=result.stdout
	if name=='SceneOverlay' then
		for _,entry in {{'drawTrajectories%(self%)','previewTrajectory'},{'drawBuildPreview%(self%)','previewGhost'},{'drawSams%(self,fraction%)','previewRanges'}} do
			code=code:gsub('([;\n]%s*)'..entry[1],function(prefix) return prefix..'do local stamp=self.profiler:begin();'..entry[1]:gsub('%%','')..';self.profiler:finish("'..entry[2]..'",stamp) end' end)
		end
	end
	overrides[name]=code]] end)
local make=luau.load(source)()
local e=make(revision)
local s=e.client(); s.width,s.height,s.startTick,s.tick=2000,1000,0,1000
s.players,s.rosterOrder,s.names,s.units={},{},{},{}
s.tileState=buffer.create(4000000)
local roster={}
for id=1,73 do
	s.players[id]={id=if id==1 then 'me' else `p{id}`,smallID=id,name=`Nation {id}`,type='HUMAN',troops=100000,alive=true,tiles=10000,allies={},embargoes={}}
	s.rosterOrder[id]=id; roster[id]={id=s.players[id].id,smallID=id,playerType='HUMAN'}
	s.names[id]={x=50+(id-1)%12*155,y=70+math.floor((id-1)/12)*135,size=25}
end
local sams={}
for id=1,400 do
	local x,y=100+(id-1)%25*72,150+math.floor((id-1)/25)*42
	local kind=if id<=100 then 'SAM Launcher' else 'City'
	s.units[id]={id=id,type=kind,owner=if id<=100 then 2 else 1,tile=y*2000+x,active=true,level=1}
	if id<=100 then table.insert(sams,{x=x,y=y,r=70}) end
end
s.units[401]={id=401,type='Missile Silo',owner=1,tile=600*2000+200,active=true,level=1}
s.gold=1e9
local parent=e.instance('Frame');parent.AbsoluteSize=rb.Vector2.new(844,390)
local terrain=buffer.create(2000000);buffer.fill(terrain,0,128)
local r=e.Renderer.new(parent,terrain,2000,1000,{autoStep=false,firstPaint='full',firstPaintBudgetMs=1e9})
r:setRoster(roster);r:attachState(s)
for _=1,1000 do e.now+=1/60;r:step(1e9,1e9);if r:isReady() then break end end
assert(r:isReady());r:bindInput(e.playerGui,e.mapGui,function() end)
local queries,queryCpu=0,0
local p=e.Preview.new(r,s,function(tile,unit)
	local start=os.clock();queries+=1
	local reply={tile=tile,unit=unit,tick=s.tick,rangeWarning=false,
		buildable={type=unit,canBuild=tile or false,canUpgrade=false,cost=125000,ghostRailPaths={},overlappingRailroads={}},
		nukeAim=if unit=='Atom Bomb' then {siloTile=s.units[401].tile,sams=table.clone(sams)} else nil}
	queryCpu+=(os.clock()-start)*1000
	return reply
end)
local function stats(a)
	table.sort(a);local sum=0;for _,v in a do sum+=v end
	return {mean=sum/#a,p95=a[math.ceil(#a*.95)],max=a[#a]}
end
for _,kind in {'City','Factory','SAM Launcher','Atom Bomb'} do for _,moving in {false,true} do
	p:setChosen(nil);p:setChosen(kind);r:setHighlightStructureTypes({kind})
	local frames,controller={},{};local queryDue=0;local ghostFrames,aimFrames=0,0
	for frame=1,240 do
		e.now+=1/60
		local x=if moving then 900+math.sin(frame*.04)*100 else 900
		local y=if moving then 500+math.cos(frame*.04)*50 else 500
		local sx,sy=r:worldToScreen(x+.5,y+.5)
		e.uis.InputChanged:Fire({UserInputType=rb.Enum.UserInputType.MouseMovement,Position={X=sx,Y=sy}},false)
		if p.setPendingTile and not moving then p:setPendingTile(y*2000+x) end
		if #e.pending>0 and frame>=queryDue then e.completeQuery() end
		local before=#e.pending;local start=os.clock();p:step();local controllerMs=(os.clock()-start)*1000
		if #e.pending>before then queryDue=frame+3 end -- synthetic 50ms reply
		if frame%6==0 then s.tick+=1;r.scene:setTick(s.tick);s.StatsChanged:Fire() end
		start=os.clock();r:step(1e9,1e9);local frameMs=(os.clock()-start)*1000
		if frame==120 then r.profiler:reset();e.writes=0;queries,queryCpu=0,0 end
		if frame>120 then
			table.insert(frames,frameMs);table.insert(controller,controllerMs)
			if r.scene.buildPreview then ghostFrames+=1 end;if r.scene.preview then aimFrames+=1 end
		end
	end
	print(require('@lune/serde').encode('json',{revision=revision or 'working',kind=kind,moving=moving,
		frames=stats(frames),controller=stats(controller),queries=queries,fakeQueryCpuMs=queryCpu,writes=e.writes,ghostFrames=ghostFrames,aimFrames=aimFrames,
		metrics=r:metrics()}))
end end
p:destroy();r:destroy()
