--!strict
-- Late empire navigation proxy. No native layout, GPU, network or phone cost.
local fs,luau,rb,process=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox'),require('@lune/process')
local overridesByRevision={}
local function make(revision: string?): any
	local overrides={}
	if revision then
		overrides=overridesByRevision[revision]
		if not overrides then
			overrides={}
			for _,name in {'SceneOverlay','UnitVisuals'} do
				local result=process.exec('git',{'show',revision..':src/client/Map/OpenFront/'..name..'.luau'})
				assert(result.ok,result.stderr);overrides[name]=result.stdout
			end
			-- The archived scene predates attack-range presentation. This
			-- workload has no attacks; adapt only the new orchestration hook,
			-- leaving its measured rail/name/unit code untouched.
			overrides.SceneOverlay=overrides.SceneOverlay:gsub('return Overlay',
				'function Overlay.setAttacks(_self:any,_attacks:{any}) end\nreturn Overlay',1)
			overridesByRevision[revision]=overrides
		end
	end
	local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
	source=source:gsub('local o: any = {ClassName=class','local values: any = {ClassName=class')
	source=source:gsub('o.GetPropertyChangedSignal=function',[[local o: any
		o=setmetatable({}, {__index=values,__newindex=function(_,key,value)
			if type(value)~='function' then env.writes=(env.writes or 0)+1 end
			if key=='Parent' then
				env.children=env.children or {}
				if values.Parent and env.children[values.Parent] then env.children[values.Parent][o]=nil end
				if value then env.children[value]=env.children[value] or {};env.children[value][o]=true end
			end
			values[key]=value
		end})
		o.GetPropertyChangedSignal=function]])
	source=source:gsub('for _, child in env.objects do if child.Parent==o then child:Destroy%(%) end end',
		'for child in table.clone((env.children or {})[o] or {}) do child:Destroy() end',1)
	source=source:gsub('o.destroyed=true; o.Destroying:Fire%(%)',[[o.destroyed=true; o.Destroying:Fire();o.Parent=nil
		if o:IsA('GuiObject') then env.liveGui-=1;env.deletedGui=(env.deletedGui or 0)+1 end]],1)
	source=source:gsub('table.insert%(env.objects,o%); return o',[[if o:IsA('GuiObject') then
		env.liveGui=(env.liveGui or 0)+1;env.createdGui=(env.createdGui or 0)+1
	end
	table.insert(env.objects,o); return o]],1)
	source=source:gsub('node~=root.EditableRenderer and', 'node~=root.UnitVisuals and node~=root.EditableRenderer and',1)
	source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then',
		'node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
	source=source:gsub('fs.readFile%(node.path%)','(zoomOverrides[node.Name] or fs.readFile(node.path))')
	return luau.load(source,{environment={zoomOverrides=overrides},injectGlobals=true})()()
end
local function stats(values)
	local sorted=table.clone(values);table.sort(sorted);local sum=0
	for _,value in values do sum+=value end
	return {mean=sum/#values,p95=sorted[math.ceil(#sorted*.95)],max=sorted[#sorted]}
end
return function(revision: string?,frames: number?): any
	local e=make(revision);e.uis.TouchEnabled=true
	local s=e.client();s.width,s.height,s.startTick,s.tick=2000,1000,0,6000
	s.players,s.rosterOrder,s.units,s.names,s.railroads={},{},{},{},{}
	s.tileState=buffer.create(2000*1000*2)
	local roster={}
	for id=1,170 do
		s.players[id]={id=`p{id}`,smallID=id,name=`Nation {id}`,type=if id==1 then 'HUMAN' else 'NATION',flag='us',
			troops=100000,alive=true,tiles=10000,allies={},embargoes={}}
		s.rosterOrder[id]=id;roster[id]={id=`p{id}`,smallID=id,playerType=if id==1 then 'HUMAN' else 'NATION'}
		s.names[id]={x=40+(id-1)%17*115,y=40+math.floor((id-1)/17)*100,size=20}
	end
	local terrain=buffer.create(2000*1000);buffer.fill(terrain,0,128)
	for tile=0,2000*1000-1 do buffer.writeu16(s.tileState,tile*2,1) end
	local kinds={'City','Port','Factory','Defense Post','SAM Launcher','Missile Silo'}
	for id=1,1000 do
		local tile=(30+math.floor((id-1)/40)*38)*2000+30+(id-1)%40*48
		s.units[id]={id=id,type=if id<=700 then kinds[(id-1)%6+1] else 'Warship',owner=1,tile=tile,lastTile=tile,
			-- Legacy navigation baseline: only warships had health UI. Structures
			-- are undamaged; Arsenal damage presentation has separate fixtures.
			active=true,level=3,health=if id>700 then 50 else nil,maxHealth=if id>700 then 100 else nil,
			warship=if id>700 then {veterancy=2} else nil,hasTrainStation=id%3==0}
	end
	for row=0,11 do
		local path={};for x=100,1899 do table.insert(path,(225+row*50)*2000+x) end
		s.railroads[row+1]=path
	end
	local parent=e.instance('Frame');parent.AbsoluteSize=rb.Vector2.new(2064,943)
	local r=e.Renderer.new(parent,terrain,2000,1000,{autoStep=false,firstPaint='full',firstPaintBudgetMs=1e9})
	r.flagArt=luau.load(fs.readFile('src/client/Ui/FlagArt.luau'))()
	r:setRoster(roster);r:applyTileStates(s.tileState);r:attachState(s)
	local function step() e.now+=1/60;r:step(1e9,1e9) end
	for _=1,1000 do step();if r:isReady() then break end end
	assert(r:isReady(),'wide zoom load did not settle')
	local base=table.clone(r.camera)
	local function camera(zoom,x,y)
		local c=table.clone(base);c.scale=zoom
		c.offsetX=x-1000-(c.viewportWidth/2-1000)/zoom
		c.offsetY=y-500-(c.viewportHeight/2-500)/zoom
		r:setCamera(c)
	end
	-- Warm all unit/flag caches and the close rail pool, then return to fit.
	camera(8,1000,500);for _=1,80 do step() end
	r:setCamera(base);for _=1,120 do step() end
	local result={revision=revision or 'working-tree',units=1000,names=170,railTiles=21600,viewport={2064,943},windows={}}
	for _,mode in {'wide','close'} do
		local elapsed,scene,names,units={},{},{},{}
		local peakGui,maxCreated,maxDeleted=e.liveGui,0,0
		local beforeCreates,beforeDeletes=e.createdGui,e.deletedGui or 0
		r:resetTimings();e.writes=0
		for i=1,frames or 120 do
			local created,deleted=e.createdGui,e.deletedGui or 0
			local started=os.clock()
			local scale=if mode=='wide' then .85+(1+math.sin(i*.065))*.85 else 3.2+(1+math.sin(i*.065))*2.4
			camera(scale,1000+math.sin(i*.09)*400,500+math.cos(i*.07)*140)
			if i%6==0 then s.tick+=1;s.TickApplied:Fire(s.tick) end
			step();table.insert(elapsed,(os.clock()-started)*1000)
			table.insert(scene,r.profiler.buckets.scene.last)
			table.insert(names,r.profiler.buckets.names.last)
			table.insert(units,r.profiler.buckets.units.last)
			peakGui=math.max(peakGui,e.liveGui)
			maxCreated=math.max(maxCreated,e.createdGui-created);maxDeleted=math.max(maxDeleted,(e.deletedGui or 0)-deleted)
		end
		result.windows[mode]={frame=stats(elapsed),scene=stats(scene),names=stats(names),units=stats(units),peakGui=peakGui,
			createdGui=e.createdGui-beforeCreates,deletedGui=(e.deletedGui or 0)-beforeDeletes,maxCreatedGui=maxCreated,maxDeletedGui=maxDeleted,
			propertyWrites=e.writes,railGui=#r.scene.railLines,railRebuilds=r.scene.railRebuilds,railVisits=r.scene.railVisits}
	end
	r:destroy();return result
end
