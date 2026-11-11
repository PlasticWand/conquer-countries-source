--!strict
-- 473-anchor CPU proxy; excludes native font/layout, hit testing, GPU and phone hardware.
local fs,luau,rb,serde,process=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox'),require('@lune/serde'),require('@lune/process')
local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then',
	'node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
if process.args[1]=='before' or process.args[2]=='before' then
	fs.writeDir('Temp/OpenFrontNamesBaseline')
	for _,name in {'SceneOverlay','NameStatusOverlay'} do
		local result=process.exec('git',{'show','dfc0551:src/client/Map/OpenFront/'..name..'.luau'})
		assert(result.ok,result.stderr); fs.writeFile('Temp/OpenFrontNamesBaseline/'..name..'.luau',result.stdout)
	end
	source=source:gsub('local env: any =',[[for _,name in {'SceneOverlay','NameStatusOverlay'} do root[name].path='Temp/OpenFrontNamesBaseline/'..name..'.luau' end
	local env: any =]],1)
end
local make=luau.load(source)(); local e=make(); local s=e.client()
s.width,s.height,s.startTick,s.tick=2000,1000,0,3000
s.tileState=buffer.create(4000000); s.players,s.rosterOrder,s.names={},{},{}
local roster={}
for id=1,473 do
	local kind=if id==1 then 'HUMAN' elseif id<=73 then 'NATION' else 'BOT'
	s.players[id]={id=`p{id}`,smallID=id,name=`Player {id}`,type=kind,troops=100000,alive=true,tiles=1000,allies={},embargoes={},flag='us'}
	s.rosterOrder[id]=id; roster[id]={id=`p{id}`,smallID=id,playerType=kind}
	s.names[id]={x=25+(id-1)%29*68,y=25+math.floor((id-1)/29)*58,size=if id<=73 then 25 else 15}
end
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local parent=e.instance('Frame'); parent.AbsoluteSize=rb.Vector2.new(1914,829)
local r=e.Renderer.new(parent,terrain,2000,1000,{autoStep=false,firstPaint='full'})
r.flagArt=luau.load(fs.readFile('src/client/Ui/FlagArt.luau'))()
r:setRoster(roster); r:attachState(s)
repeat e.now+=1/60; r:step(1e9,1e9) until r:isReady()
assert(r:metrics().nameViews==473,'fit workload must allocate all 473 visible names')
-- Exercise the baseline's normal nonzero TextBounds branch, not repeated
-- fallback glyph-layout work. Native text layout itself is not simulated.
for _,view in r.scene.nameViews do
	view.name.TextBounds=rb.Vector2.new(#view.text*.5*view.name.TextSize,view.name.TextSize)
end
local fit=table.clone(r.camera)
local function camera(scale,x,y)
	local c=table.clone(fit); c.scale=scale
	c.offsetX=x-1000-(c.viewportWidth/2-1000)/scale
	c.offsetY=y-500-(c.viewportHeight/2-500)/scale
	r:setCamera(c)
end
local serial=0
local function step(i,mode)
	serial+=1; e.now+=1/60
	if serial%6==0 then
		s.tick+=1
		for id,p in s.players do p.troops=100000+s.tick+id end
		s.StatsChanged:Fire(); s.TickApplied:Fire(s.tick)
		-- A sparse authoritative anchor update still supplies the whole table.
		if s.tick%30==0 then
			for id=1,73 do s.names[id].x+=if s.tick%60==0 then -1 else 1 end
			s.NamesChanged:Fire()
		end
	end
	if mode=='pan' then camera(fit.scale,1000+math.sin(i*.03)*100,500+math.cos(i*.02)*30)
	elseif mode=='zoom' then camera(.6+(1+math.sin(i*.015))*1.6,1000,493) end
	r:step()
end
for _,mode in {'idle','pan','zoom'} do
	r:setCamera(fit)
	for i=1,120 do step(i,mode) end
	r:resetTimings()
	for i=1,600 do step(i,mode) end
	local m=r:metrics()
	print(serde.encode('json',{mode=mode,anchors=473,frames=600,namesMsPerFrame=m.timing_names_totalMs/600,
		statusMsPerFrame=m.timing_status_totalMs/600,frameMs=m.timing_frame_totalMs/600,metrics=m,
		reference='dfc0551',viewport={1914,829},easingAnchors=73,units=0}))
end
r:destroy()
if process.args[1]=='before' or process.args[2]=='before' then
	-- Remove only our two exported files, leaving other agents' Temp work alone.
	for _,name in {'SceneOverlay','NameStatusOverlay'} do fs.removeFile('Temp/OpenFrontNamesBaseline/'..name..'.luau') end
	fs.removeDir('Temp/OpenFrontNamesBaseline')
end
