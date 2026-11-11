--!strict
-- Serial World / phone-policy audit, comparable snapshot modules via git show.
-- The measured calls include confirmation callbacks; no sim/server execution.
local fs,luau,rb,serde,process=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox'),require('@lune/serde'),require('@lune/process')
local ref=process.args[1]
if ref=='working' then ref=nil end
local variant=process.args[2] or 'default'
local records={}
local make=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
local e=make(ref,variant=='baseline'); e.uis.TouchEnabled=true
if variant~='default' then
	e.policy.splitMapGuis=variant=='split' or variant=='both'
	e.policy.deferredOwnership=variant=='deferred' or variant=='both'
end
local terrain=buffer.fromstring(fs.readFile('../reference/openfront-v0.35.2/resources/maps/world/map.bin'))
local s=e.client(); s.width,s.height,s.startTick,s.tick=2000,1000,0,100
s.units,s.names={},{}; s.tileState=buffer.create(4000000)
for id=1,795 do
	local tile=(50+math.floor((id-1)/40)*40)*2000+20+(id-1)%40*48
	s.units[id]={id=id,type=if id>600 then 'Defense Post' else ({'Transport','Trade Ship','Warship'})[(id-1)%3+1],
		owner=if id>600 then 2 else 1+(id%2),active=true,tile=tile,lastTile=tile-1,health=100,maxHealth=100,level=1,
		warship=if id<=600 and id%3==0 then {state='patrolling',veterancy=0} else nil}
end
local parent=e.instance('Frame'); parent.AbsoluteSize=rb.Vector2.new(844,390)
local host=e.instance('ScreenGui');host.DisplayOrder=0;host.Parent=e.playerGui;parent.Parent=host
local r=e.Renderer.new(parent,terrain,2000,1000,{autoStep=false,firstPaint='full',coasts=false,guiHost=host})
r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}}); r:attachState(s)
for _=1,4096 do e.now+=1/60; r:step(); if r:isReady() then break end end
assert(r:isReady()); local fit=table.clone(r.camera)
local function record(mode,frames,step)
	e.writes,e.changedWrites={},{}; e.recordUploads=true; e.uploads={}; r.profiler:reset()
	local samples={}; local startObjects=#e.objects
	local guiSizes={};local scopeVisits=0
	for _,object in e.objects do if not object.destroyed and object:IsA('GuiObject') then
		local parentGui=object.Parent
		while parentGui and parentGui.ClassName~='ScreenGui' do parentGui=parentGui.Parent end
		if parentGui then guiSizes[parentGui]=(guiSizes[parentGui] or 0)+1 end
	end end
	e.trackGui=true
	for i=1,frames do
		e.dirtyGuis={}
		local started=os.clock(); e.now+=1/60; step(i); r:step(); table.insert(samples,(os.clock()-started)*1000)
		for gui in e.dirtyGuis do scopeVisits+=guiSizes[gui] or 0 end
	end
	e.trackGui=false
	table.sort(samples); local sum=0; for _,ms in samples do sum+=ms end
	local m=r:metrics(); local timing={}
	for _,key in {'units','fx','previewRanges','prepare','frame'} do for _,stat in {'meanMs','p95Ms','maxMs'} do timing[key..'_'..stat]=m['timing_'..key..'_'..stat] end end
	local components={}; for _,o in e.objects do if not o.destroyed then components[o.ClassName]=(components[o.ClassName] or 0)+1 end end
	local record=serde.encode('json',{ref=ref or 'working',variant=variant,mode=mode,frames=frames,meanMs=sum/frames,p95Ms=samples[math.ceil(frames*.95)],maxMs=samples[#samples],
		dirtyGuiObjectVisitsProxy=scopeVisits,scopeNote='sum of changed ScreenGui subtree sizes fixed at scenario start; not engine layout cost',
		writes=e.writes,changedWrites=e.changedWrites,newInstances=#e.objects-startObjects,components=components,timing=timing,uploads=#e.uploads,
		defenseProbeTiles=m.defenseProbeTiles,rangeViews=m.rangeViews,falloutMasks=m.falloutMasks,falloutMaskVisits=m.falloutMaskVisits,fxSprites=m.fxSprites})
	table.insert(records,record);print(record)
end
for _=1,120 do e.now+=1/60; r:step() end
record('idle795',240,function() end)
record('move600',240,function(i)
	if i%6==0 then
		s.tick+=1; local ids={}
		for id=1,600 do local u=s.units[id]; u.lastTile=u.tile; u.tile+=if i%120<60 then 1 else 2000; table.insert(ids,id) end
		s.UnitsMoved:Fire(ids); s.TickApplied:Fire(s.tick)
	end
	local c=table.clone(fit); c.offsetX+=math.sin(i*.03)*25; c.offsetY+=math.cos(i*.02)*15; r:setCamera(c)
end)
record('move600Still',240,function(i)
	if i==1 then r:setCamera(fit) end
	if i%6==0 then
		s.tick+=1;local ids={}
		for id=1,600 do local u=s.units[id];u.lastTile=u.tile;u.tile+=1;table.insert(ids,id) end
		s.UnitsMoved:Fire(ids);s.TickApplied:Fire(s.tick)
	end
end)
record('healthCombat200',240,function(i)
	if i%6==0 then
		s.tick+=1; local updates={}
		for id=3,600,3 do local u=s.units[id]; u.health=50+i%10; u.targetUnitId=1; u.warship.veterancy=2; table.insert(updates,u) end
		s.UnitsChanged:Fire(updates,{}); s.TickApplied:Fire(s.tick)
	end
end)
record('defenseRanges195',240,function(i)
	if i==1 then
		local refs={}
		for id=601,795 do local tile=s.units[id].tile-30*2000; buffer.writeu16(s.tileState,tile*2,1); table.insert(refs,tile) end
		r:applyTileStates(s.tileState,refs)
		s.attacks={{outgoing=true,attacker=1,target=2,troops=50}}; s.AttacksChanged:Fire()
	end
end)
s.attacks={}; s.AttacksChanged:Fire()
-- New effects: source explosions, capped lingering sprites, four masks. The
-- masks sample real world-sized buffers, with fallout confirmed in all tiles.
for tile=0,1999999 do buffer.writeu16(s.tileState,tile*2,8192) end
r:applyTileStates(s.tileState); while r.core.pending>0 do e.now+=1/60; r:step() end
record('impact4ThenRest',240,function(i)
	if i==1 then
		local updates={}
		for id=1,4 do table.insert(updates,{id=10000+id,type='Hydrogen Bomb',tile=(250+id*100)*2000+500,owner=2,active=false,reachedTarget=true}) end
		s.UnitsChanged:Fire(updates,{})
	end
end)
record('defenseDestruction24',240,function(i)
	if i==1 then
		local updates={}; for id=601,624 do local u=s.units[id]; u.active=false; table.insert(updates,u) end
		s.UnitsChanged:Fire(updates,{})
	end
end)
record('warshipSinking24',240,function(i)
	if i==1 then
		local updates={}; for id=3,72,3 do local u=s.units[id]; u.active=false; table.insert(updates,u) end
		s.UnitsChanged:Fire(updates,{})
	end
end)
r:destroy(); for _,image in e.images do assert(image.destroyed,'image leak') end
if process.args[3] then fs.writeFile(process.args[3],table.concat(records,'\n')..'\n') end
