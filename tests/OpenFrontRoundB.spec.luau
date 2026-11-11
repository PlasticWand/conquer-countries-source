--!strict
-- Native-property regressions; no native layout/GPU claim.
return function(t)
local fs,luau,rb= require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
source=source:gsub('local o: any = {ClassName=class','local values: any = {ClassName=class')
source=source:gsub('o.GetPropertyChangedSignal=function',[[local o: any = setmetatable({}, {__index=values,__newindex=function(_,key,value)
 if type(value)~='function' then values.writes=(values.writes or 0)+1 end; values[key]=value end})
 o.GetPropertyChangedSignal=function]])
source=source:gsub('node==root.BuildPreviewController or node==root.MapInput then','node==root.BuildPreviewController or node==root.MapInput or node==root.SceneOverlay or node==root.EffectOverlay then')
local make=luau.load(source)()
local H=luau.load(fs.readFile('tests/harness.luau'))()
local root=H.mount('src/client/Map/OpenFront','OpenFront')
local Flag,Visual=H.require(root.NameFlag),H.require(root.UnitVisuals)
local NameLine=H.require(root.NameLine)
local art=luau.load(fs.readFile('src/client/Ui/FlagArt.luau'))()
local function setup(full)
 local e=make();local s=e.client();s.startTick=0;s.names={[1]={x=15,y=15,size=20},[2]={x=40,y=40,size=20}}
 local terrain=buffer.create(4096);buffer.fill(terrain,0,128)
 local r=e.Renderer.new(e.instance('Frame'),terrain,64,64,{autoStep=false,firstPaint=if full then 'full' else nil})
 r.flagArt=art;r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
 return e,s,r
end
local function step(e,r,dt) e.now+=dt or .02;r:step() end
t.test('source name visibility follows zoom on its first frame in both directions',function()
 local e,s,r=setup();s.names[1].size=4;r:attachState(s);step(e,r,.11)
 local v=r.scene.nameViews[1]
 for _,zoom in {.2,4,.2,4} do
  local c=table.clone(r.camera);c.scale=zoom;r:setCamera(c);step(e,r,.001)
  local sizing=H.require(root.LabelMath).size(4,2*zoom/r.camera.viewportWidth,false,false,false)
  t.eq(v.root.Visible,sizing.visible,`source LOD at {zoom}, stored zoom {v.sourceZoom}`)
 end
 r:destroy()
end)
t.test('source rail fade remains opt-in and settles on maintenance without delaying camera transforms',function()
 local e,s,r=setup();s.railroads={[1]={138,139,140}};r:attachState(s)
 e.policy.sourceRailFade=true
 local c=table.clone(r.camera);c.scale=4;r:setCamera(c);step(e,r,.11)
 t.eq(r.scene.visibleRails,3)
 c=table.clone(r.camera);c.scale=2;r:setCamera(c);step(e,r,.11)
 t.near(r.scene.railLines[1].ImageTransparency,.5,1e-6,'source fade differs')
 e.policy.sourceRailFade=false;r.scene:setCamera();step(e,r,.001)
 t.eq(r.scene.layers.Rails.Visible,false);t.eq(r.scene.visibleRails,0,'default far rails retained the phone regression')
 r:destroy()
end)
t.test('fast pans move retained rails immediately and refresh their frustum on maintenance',function()
 local e=make();local s=e.client();s.width,s.height,s.names=2000,32,{}
 s.tileState=buffer.create(2000*32*2);s.railroads={[1]={2100,2101,2102},[2]={3800,3801,3802}}
 local terrain=buffer.create(2000*32);buffer.fill(terrain,0,128)
 local r=e.Renderer.new(e.instance('Frame'),terrain,2000,32,{autoStep=false});r:attachState(s)
 local c=table.clone(r.camera);c.scale=4;c.offsetX=100-1000-(c.viewportWidth-2000)/8
 c.offsetY=1.5-16-(c.viewportHeight-32)/8
 r:setCamera(c);step(e,r,.11);t.eq(r.scene.visibleRails,3)
 local position=r.scene.layers.Rails.Position
 r:pan(-1700*4,0);t.ok(r.scene.layers.Rails.Position~=position,'rails did not inherit the pan')
 step(e,r,.11)
 t.eq(r.scene.visibleRails,3);t.eq(r.scene.railLines[1].Position.X.Offset>=1800*64,true,'new tracks waited for maintenance')
 r:destroy()
end)
t.test('built-in timing uses bounded storage, toggles, resets and measures live controller calls',function()
 local Timings=H.require(root.RenderTimings);local timings=Timings.new(false)
 timings:finish('frame',timings:begin());assert(timings:metrics().timing_frame_calls==0)
 timings.enabled=true;for _=1,1300 do timings:finish('frame',timings:begin()) end
 assert(#timings.buckets.frame.values==1200 and timings:metrics().timing_frame_calls==1300)
 timings:reset();assert(timings:metrics().timing_frame_calls==0 and #timings.buckets.frame.values==0)
 local e,s,r=setup();r:attachState(s);step(e,r)
 local m=r:metrics();assert(m.timing_frame_calls==1 and m.timing_scene_calls==1 and m.timing_names_calls==1 and m.timing_units_calls==1)
 r:setProfiling(false);step(e,r);assert(r:metrics().timing_frame_calls==0)
 r:setProfiling(true);step(e,r);assert(r:metrics().timing_frame_calls==1)
 r:destroy()
end)
t.test('anchor easing keeps its source tail after 1.5 seconds and reuses interpolation storage',function()
 local e,s,r=setup();r:attachState(s);step(e,r)
 r.scene:setNameAnchors({[1]={x=1000,y=1000,size=80},[2]=s.names[2]});step(e,r,.5)
 local tr=r.scene.nameTransitions[1];local current=tr.current
 step(e,r,1.1)
 local Labels=H.require(root.LabelMath)
 assert(tr.current==current and current.x==Labels.lerp(tr.x,tr.target.x,e.now-tr.time))
 assert(current.x~=tr.target.x,'source tail snapped at 1.5 seconds')
 local target=r.scene.names[1]
 r.scene:setNameAnchors({[1]={x=1000,y=1000,size=80},[2]=s.names[2]})
 assert(r.scene.names[1]==target and r.scene.nameTransitions[1]==tr,'unchanged targets copied')
 r:destroy()
end)
t.test('idle units avoid property writes; confirmed changes, camera and lazy structure labels redraw',function()
 local e,s,r=setup();s.units[1]={id=1,type='City',owner=1,tile=100,level=1,active=true}
 r:attachState(s);step(e,r)
 local v=r.scene.unitViews[1];assert(v and not v.level and not v.station and not v.deletion)
	for _=1,10 do step(e,r) end -- finish asynchronous composed-icon preparation
 local writes=v.parts[1].writes;local pose=v.root.writes
 for _=1,5 do step(e,r) end
 assert(v.parts[1].writes==writes and v.root.writes==pose,'static unit redrawn')
 local color=v.iconSlot.fill
 s.units[1].owner=2;s.UnitsChanged:Fire({},{});step(e,r)
 assert(v.iconSlot.fill~=color,'capture did not invalidate')
 s.units[1].level=3;r.camera.scale=4;r.scene:setCamera();step(e,r)
 assert(v.level and v.level.Visible and v.level.Text=='3')
 assert(not v.station and not v.deletion)
 s.units[1].hasTrainStation=true;s.units[1].markedForDeletion=30;s.UnitsChanged:Fire({},{});step(e,r)
 assert(v.station.Visible and v.deletion.Visible and v.progress.background.Visible)
 s.units[1].level=1;s.units[1].hasTrainStation=false;s.units[1].markedForDeletion=nil;s.UnitsChanged:Fire({},{});step(e,r)
 assert(not v.level.Visible and not v.station.Visible and not v.deletion.Visible and not v.progress)
 s.units={};s.UnitsChanged:Fire({}, {1});step(e,r);assert(v.root.destroyed)
 r:destroy()
end)
t.test('smooth missiles include the final interpolation frame, stop idle writes and clear on capture/death',function()
 local e,s,r=setup();s.units[1]={id=1,type='Atom Bomb',owner=1,tile=12,lastTile=10,active=true}
 r:attachState(s);r.scene:setMoved({1},0);r.scene:setTick(0);step(e,r,0)
 local v=r.scene.unitViews[1];local start=v.root.Position.X.Scale
 step(e,r,.05);local mid=v.root.Position.X.Scale;assert(mid>start)
 step(e,r,.06);local done=v.root.Position.X.Scale;assert(done>mid)
 local writes=v.root.writes;step(e,r,.2);assert(v.root.writes==writes)
 s.units[1].active=false;s.UnitsChanged:Fire({},{});step(e,r);assert(not v.root.Visible)
 r:destroy()
end)
t.test('name caches retain live troops, outlines, target boost and status expiry',function()
 local e,s,r=setup();s.players[1].tiles=10;s.players[2].tiles=5
 r:attachState(s);step(e,r);step(e,r)
 local v=r.scene.nameViews[1];local rootWrites=v.root.writes;local textWrites=v.name.writes
 step(e,r,.11);assert(v.root.writes==rootWrites and v.name.writes==textWrites,'unchanged layout/style rewritten')
 local troops=v.troops.Text;s.players[1].troops=50000;s.StatsChanged:Fire();step(e,r,.6);assert(v.troops.Text~=troops)
 s.players[1].name='Renamed';s.StatsChanged:Fire();step(e,r,.11);assert(v.name.Text=='Renamed')
 s.players[1].traitor=true;s.players[1].traitorUntil=20;s.StatsChanged:Fire();step(e,r,.11)
 assert(r.scene.statuses[1].traitor and #r.scene.nameStatus.animations==1)
 s.players[1].traitor=false;s.players[1].traitorUntil=0;s.StatsChanged:Fire();step(e,r,.11)
 assert(not r.scene.statuses[1].traitor and #r.scene.nameStatus.animations==0)
 r:destroy()
end)
t.test('human head shots follow confirmed identity, inline order, culling, toggles and teardown',function()
 local e,s,r=setup();s.players[1].userId=1642763318;s.players[1].flag='us'
 r:attachState(s);step(e,r);step(e,r,.11)
 local v=r.scene.nameViews[1];local head=v.head
 assert(head and head.Visible and head.Image=='rbxthumb://type=AvatarHeadShot&id=1642763318&w=150&h=150')
 local circular=false;for _,o in e.objects do if o.Parent==head and o.ClassName=='UICorner' then circular=o.CornerRadius.Scale==.5 end end
 assert(circular,'head was not clipped round')
 local scale=v.scale.Scale
 local flagRight=(v.flag.Position.X.Offset+v.flag.Size.X.Offset)*scale
 local headLeft=head.Position.X.Offset*scale;local headRight=(head.Position.X.Offset+head.Size.X.Offset)*scale
 local textLeft=v.width/2+v.name.Position.X.Offset*scale-#v.text*.5*v.pixels/2
 assert(flagRight<=headLeft+scale and headRight<=textLeft+scale,'flag/head/name order or spacing')
 assert(math.abs((v.flag.Position.X.Offset*scale+textLeft+#v.text*.5*v.pixels)/2-v.width/2)<=scale,'row is not centred')
 assert(v.troops.Position.X.Offset==0,'troops no longer centred under row')
 local cached=r.scene.headImages[1642763318];local writes=head.writes
 step(e,r,.11);assert(head.writes==writes and r.scene.headImages[1642763318]==cached,'idle head rewritten')
 local x,y=r:playerNameScreenPosition(1);assert(x and y,'name anchor unavailable')
 r:setTerritoryLabelsVisible(false);assert(not r.scene.layers.Names.Visible)
 local hiddenX,hiddenY=r:playerNameScreenPosition(1);assert(hiddenX==x and hiddenY==y,'toggle lost toast anchor')
 r:setTerritoryLabelsVisible(true)
 for _,kind in {'BOT','NATION','HUMAN'} do
  s.players[1].type=kind;s.players[1].userId=if kind=='HUMAN' then nil else 1642763318
  s.StatsChanged:Fire();step(e,r,.11);assert(not head.Visible and head.Image=='','non-human/nil retained a head')
  assert(v.flag.Visible,'country flag lost')
  local shade=if kind=='BOT' then .4 elseif kind=='NATION' then .3 else 0
  t.near(v.name.TextColor3.R,shade,1e-6);t.eq(v.troops.TextColor3,v.name.TextColor3)
 end
 for _,id in {-1,0,1.5,math.huge} do
  s.players[1].userId=id;s.StatsChanged:Fire();step(e,r,.11);assert(not head.Visible,'invalid/Studio id shown')
 end
 s.players[1].userId=1642763318;s.StatsChanged:Fire();step(e,r,.11)
 assert(head.Visible and v.head==head and r.scene.headImages[1642763318]==cached,'head not reused')
 local fit=table.clone(r.camera);local away=table.clone(fit);away.offsetX=10000;r:setCamera(away);step(e,r,.01)
 s.players[1].userId=12345;s.StatsChanged:Fire();step(e,r,.11)
 r:setCamera(fit);step(e,r,.001);assert(head.Image:find('id=12345&',1,true),'reveal retained stale head')
 local urls=r.scene.headImages;r:destroy();assert(head.destroyed and next(urls)==nil,'head/cache leaked after teardown')
end)

t.test('bots, nations and Studio humans never allocate a head even with supplied ids',function()
 local e,s,r=setup();s.players[1].type='BOT';s.players[1].userId=12345
 s.players[2].type='NATION';s.players[2].userId=67890
 r:attachState(s);step(e,r);assert(not r.scene.nameViews[1].head and not r.scene.nameViews[2].head)
 s.players[1].type='HUMAN';s.players[1].userId=-1;s.StatsChanged:Fire();step(e,r,.11)
 assert(not r.scene.nameViews[1].head and next(r.scene.headImages)==nil)
 r:destroy()
end)

t.test('country/store flag crop, inline sizing, measured width, replacement and cleanup',function()
 local e,s,r=setup();s.players[1].flag='us';r:attachState(s);step(e,r)
 local v=r.scene.nameViews[1];assert(v.flag.Visible)
 local d=Flag.resolve(art,'f_us');assert(v.flag.Image==d.page and v.flag.ImageRectSize==rb.Vector2.new(92,68))
 assert(v.flag.ImageRectOffset==rb.Vector2.new(d.x,d.y))
	local ratio=v.flag.Size.X.Offset/v.flag.Size.Y.Offset;assert(math.abs(ratio-1.5)<.02, tostring(v.flag.Size)..' ratio='..tostring(ratio))
 v.name.TextBounds=rb.Vector2.new(80,20);r.scene:setCamera();step(e,r,.11)
 local expected=NameLine.layout(#v.text*.5*v.pixels,v.pixels,true,false).flagX
 local width=math.max(30*64,math.min(600*64,v.pixels*10))
 assert(math.abs(v.flag.Position.X.Offset-(width/2+expected)/v.scale.Scale)<=1,'integer GUI offset')
 local image=v.flag;s.players[1].flag='o_comet_trail';s.StatsChanged:Fire();step(e,r,.11)
 assert(v.flag==image and v.flag.ImageRectSize==rb.Vector2.new(188,140))
 s.players[1].flag='unknown_flag';s.StatsChanged:Fire();step(e,r,.11);assert(not image.Visible)
 s.players[1].flag='us';s.StatsChanged:Fire();step(e,r,.11);assert(image.Visible)
 assert(Flag.resolve(art,'US').key=='f_us' and Flag.resolve(art,nil)==nil)
 local truncated=string.sub(string.rep('A',31)..utf8.char(0x1f680),1,32)
 assert(Flag.halfWidth(truncated)==Flag.halfWidth(string.rep('A',31)),'partial UTF-8 suffix crashed flag fallback')
 r:destroy();assert(image.destroyed)
end)
t.test('flags stay outside text at zoom 1.9, 4 and 8 through long names, anchor sizes and replacement',function()
 local e,s,r=setup();s.players[1].flag='us'
 local long=string.rep('W',32);e.textWidths={Me=1.6,[long]=25,['South Africa']=5.1}
 r:attachState(s);step(e,r)
 local v=r.scene.nameViews[1]
 for _,text in {'Me',long,'South Africa'} do
  s.players[1].name=text;s.StatsChanged:Fire();step(e,r,.11)
  local measured=e.textMeasurements
  for _,size in {4,20,45} do
   r.scene:setNameAnchors({[1]={x=15,y=15,size=size},[2]=s.names[2]});step(e,r,4)
   for _,zoom in {1.9,4,8} do
    local c=table.clone(r.camera);c.scale=zoom;r:setCamera(c)
    v.name.TextBounds=rb.Vector2.new(zoom*7,1) -- Deliberately unrelated native bounds.
    step(e,r,.11)
    local textLeft=v.width/2+v.name.Position.X.Offset*v.scale.Scale-e.textWidths[text]*v.pixels/2
    local flagRight=(v.flag.Position.X.Offset+v.flag.Size.X.Offset)*v.scale.Scale
    assert(math.abs(flagRight+v.pixels*.03-textLeft)<=2*v.scale.Scale,'flag intersects measured text edge')
    assert(e.textMeasurements==measured,'zoom or anchor change remeasured the same font/string')
   end
  end
 end
 assert(e.textMeasurements==3,'measure each distinct displayed string once')
 r:destroy();assert(r.scene==nil)
end)
t.test('one easing name leaves unrelated text, flags and status layouts alone and keeps the easing tail',function()
 local e,s,r=setup();s.players[1].flag='us';s.players[2].flag='us'
 r:attachState(s);step(e,r);step(e,r,.11)
 r.scene:setNameAnchors({[1]={x=16,y=15,size=20},[2]=s.names[2]});step(e,r,.001)
 local v=r.scene.nameViews[2];local visits=r.scene.nameVisits
 local nameWrites,flagWrites,rootWrites=v.name.writes,v.flag.writes,v.root.writes
 local statusDraws=r.scene.nameStatusDraws
 step(e,r,.001)
 assert(r.scene.nameVisits-visits==1,'one transition caused a full roster draw')
 assert(v.name.writes==nameWrites and v.flag.writes==flagWrites and v.root.writes==rootWrites)
 assert(r.scene.nameStatusDraws==statusDraws,'unchanged status decoration rebuilt')
 step(e,r,1.6);local tr=r.scene.nameTransitions[1]
 local x=tr.current.x;step(e,r,.001)
 assert(tr.current.x>x and tr.current.x~=tr.target.x,'source tail stopped at the old 1.5s cutoff')
 r:destroy()
end)
t.test('culled names retain views and reveal current text, flag, troops and status without a delayed tick',function()
 local e,s,r=setup();s.players[1].flag='us';s.players[1].tiles=10;r:attachState(s);step(e,r);step(e,r,.11)
 local fit=table.clone(r.camera);local v=r.scene.nameViews[1]
 local away=table.clone(fit);away.offsetX=10000;r:setCamera(away);step(e,r,.01);assert(not v.root.Visible)
 local writes=v.name.writes;local measures=e.textMeasurements
 s.players[1].name='Renamed';s.players[1].flag='o_comet_trail';s.players[1].troops=50000
 s.players[1].traitor=true;s.players[1].traitorUntil=100;s.StatsChanged:Fire();step(e,r,.6)
 assert(v.name.writes==writes and e.textMeasurements==measures,'hidden name styled')
 r:setCamera(fit);step(e,r,.001)
 assert(r.scene.nameViews[1]==v and v.root.Visible and v.name.Text=='Renamed')
 assert(v.flagData.key=='o_comet_trail' and v.troops.Text=='5.00K')
 assert(v.statusRecord.traitor,'reveal lost traitor status')
 assert(#r.scene.nameStatus.animations==1,`expected flashing traitor, got {#r.scene.nameStatus.animations}`)
 local alpha=r.scene.nameStatus.animations[1].base.ImageTransparency
 step(e,r,.01);assert(#r.scene.nameStatus.animations==1)
 assert(r.scene.nameStatus.animations[1].base.ImageTransparency~=alpha,'incremental refresh lost flashing')
 r:destroy()
end)
t.test('troop display keys preserve source formatting boundaries and unchanged text avoids writes',function()
 local Labels=H.require(root.LabelMath)
 for _,base in {0,9990,10000,99990,100000,999990,1000000,9999990,10000000,99999990,100000000,10000000000,100000000000} do
  local prior={}
  for i=-10,10 do
   local n=math.max(0,base+i*.1);local key,mag=Labels.troopDisplayKey(n)
   local token=`{mag}:{key}`;local text=Labels.renderTroops(n)
   assert(not prior[token] or prior[token]==text,'equal cache key changed source formatting')
   prior[token]=text
  end
 end
 local e,s,r=setup();s.players[1].troops=100001;r:attachState(s);step(e,r)
 local v=r.scene.nameViews[1];local writes=v.troops.writes
 s.players[1].troops=100002;s.StatsChanged:Fire();step(e,r,.6)
 assert(v.troops.writes==writes,'rounded unchanged troop text was rewritten')
 s.players[1].troops=110000;s.StatsChanged:Fire();step(e,r,.01)
 assert(v.troops.writes==writes,'troops changed before their source bucket was due')
 step(e,r,.6);assert(v.troops.Text=='11.0K' and v.troops.writes>writes)
 r:destroy()
end)
t.test('confirmed own and other troop cuts retain source stagger without an extra maintenance delay',function()
 local e,s,r=setup();s.players[1].troops=100000;s.players[2].troops=100000
 r:attachState(s);e.now=.2;r:step()
 t.eq(r.scene.localPlayer,1)
 local own,other=r.scene.nameViews[1],r.scene.nameViews[2]
 t.eq(own.troops.Text,'10.0K');t.eq(other.troops.Text,'10.0K')
 s.players[1].troops=50000;s.players[2].troops=50000
 e.now=.21;s.StatsChanged:Fire();r:step()
 t.eq(r.scene.roster[1].troops,50000,'confirmed own value did not reach the overlay')
 t.eq(own.troops.Text,'10.0K','own label bypassed the source 500ms bucket')
 t.eq(other.troops.Text,'10.0K','other label bypassed the source 500ms bucket')
 e.now=.39;r:step()
 e.now=.401;s.StatsChanged:Fire();r:step()
 t.eq(other.troops.Text,'5.00K','other slot missed its staggered bucket on confirmed stats')
 t.eq(own.troops.Text,'10.0K','own slot refreshed before its source bucket')
 e.now=.495;s.StatsChanged:Fire();r:step()
 local maintenance=r.scene.lastNameMaintenance
 e.now=.501;s.StatsChanged:Fire();r:step()
 t.eq(own.troops.Text,'5.00K','own slot waited for maintenance after its bucket changed')
 t.eq(r.scene.lastNameMaintenance,maintenance,'test did not exercise a non-maintenance stats refresh')
 r:destroy()
end)

t.test('source LOD-hidden names reappear after zoom settles without a camera or state event',function()
 local e,s,r=setup();s.players[1].flag='us';r:attachState(s);step(e,r)
 local v=r.scene.nameViews[1];local c=table.clone(r.camera);c.scale=.1;r:setCamera(c);step(e,r,.001);step(e,r,.11)
 assert(not v.root.Visible,'source size culling did not hide name')
 c.scale=4;r:setCamera(c);step(e,r,.001);step(e,r,.11)
 assert(r.scene.nameViews[1]==v and v.root.Visible and v.flag.Visible,'settled zoom retained a culled name')
 assert(math.abs(v.strokes[1].Thickness*v.scale.Scale*r.scene.worldScale.Scale-NameLine.outline(v.pixels*r.scene.worldScale.Scale))<.00001)
 r:destroy()
end)
t.test('missile moves never use ground pose-only, cross cells on Missiles and refresh shell trails',function()
 local e=make();local s=e.client();s.width,s.height,s.startTick=384,4,0;s.names={};s.tileState=buffer.create(384*4*2)
 local terrain=buffer.create(384*4);buffer.fill(terrain,0,128)
 local r=e.Renderer.new(e.instance('Frame'),terrain,384,4,{autoStep=false})
 r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
 local kinds={'Atom Bomb','Hydrogen Bomb','MIRV','Mega Nuke','MIRV Warhead','SAMMissile','Shell'}
 for id,kind in kinds do s.units[id]={id=id,type=kind,owner=1,tile=384+126,lastTile=384+125,active=true} end
 r:attachState(s);step(e,r,.2)
 local poses=r.scene.unitPoseDraws or 0
 local ids={1,2,3,4,5,6,7}
 for tick=1,2 do
  s.tick=tick
  for _,u in s.units do u.lastTile,u.tile=u.tile,u.tile+5 end
  s.UnitsMoved:Fire(ids);s.TickApplied:Fire(tick)
  for _,fraction in {.25,.5,1} do
   e.now=r.scene.tickTime+fraction*.1;r:step()
   for id,u in s.units do
    local v=r.scene.unitViews[id];local expected=Visual.unit(u,384,r.camera.scale,fraction,true)
    assert(v.root.Parent==r.scene.layers.Missiles,'confirmed move changed pass')
    assert(math.abs(v.worldX-expected.x)<.00001,'first post-tick frame snapped ahead')
    assert(math.abs(v.root.Position.X.Scale-(expected.x+.5)/384)<.00001)
   end
   assert((r.scene.unitPoseDraws or 0)==poses,'missile used ground pose shortcut')
  end
  local trail=r.scene.unitViews[7].trail;local last=s.units[7].lastTile
  local origin=math.floor(last%384/128)*128
  assert(trail.Visible and trail.Parent.Name==`Units{math.floor(last%384/128)}_0`)
  assert(math.abs(trail.Position.X.Offset-((last%384+.5-origin)*64-13*64/2))<=1)
  assert(trail.Size.X.Scale==0 and trail.Size.X.Offset==13*64)
 end
 s.units[7].lastTile=s.units[7].tile;s.UnitsMoved:Fire({7});s.TickApplied:Fire(3);step(e,r,.01)
 assert(not r.scene.unitViews[7].trail.Visible,'stationary shell retained its old trail')
 r:destroy()
end)
t.test('flag and human head creation share the budget and finish before first reveal',function()
 -- Full paint's row slices (f64fb61) and coast gate (a480ec4) can outlast
 -- 100 calls. Exercise both ordinary and exhausted slices, without changing
 -- the shared 25-view creation allowance or the reveal condition.
 for _,budgetMs in {30,1e-9} do
  local e,s,r=setup(true);s.players,s.rosterOrder,s.names={},{},{}
  r.options.firstPaintBudgetMs=budgetMs
  for id=1,60 do
   s.players[id]={id=`p{id}`,smallID=id,type='HUMAN',userId=100+id,name=`P{id}`,flag='us',alive=true,troops=10,allies={},embargoes={}}
   s.rosterOrder[id]=id;s.names[id]={x=5+id%8*6,y=5+math.floor(id/8)*6,size=20}
  end
  r:attachState(s)
  local maxFrames=r.core.height*math.ceil(r.core.width/H.require(root.RasterCore).BLOCK)+32 -- 128 block rows + preparation/reveal
  for frame=1,maxFrames do
   local before=0;for _,v in r.scene.nameViews do before+=1;if v.flag then before+=1 end;if v.head then before+=1 end end
   step(e,r)
   local after=0;for _,v in r.scene.nameViews do after+=1;if v.flag then after+=1 end;if v.head then after+=1 end end
   assert(after-before<=25,'flag budget bypass')
   assert(r.root.Visible==r:isReady(),'loading cover released before full paint')
   if frame==100 and budgetMs<1 then
    assert(not r:isReady() and r.core.pending>0,'exhausted slices must exercise the old cutoff')
   end
   if r:isReady() then break end
  end
  assert(r:isReady())
  for id=1,60 do assert(r.scene.nameViews[id].flag.Visible and r.scene.nameViews[id].head.Visible,'revealed without flag/head') end
  r:destroy()
 end
end)
t.test('renderer colour lookup and fit expose drawn fill and symmetric wide-viewport bounds',function()
 local e,s,r=setup();assert(r:playerColor(0)==nil and r:playerColor(300)==nil)
 local p=r.core.palette[1].fill;assert(r:playerColor(1)==rb.Color3.new(p.r,p.g,p.b))
 local parent=e.instance('Frame');parent.AbsoluteSize=rb.Vector2.new(1914,829)
 local wide=e.Renderer.new(parent,buffer.create(2000*1000),2000,1000,{autoStep=false})
 local m=wide:metrics();assert(m.mapLeft==128 and m.mapRight==1786 and m.mapTop==0 and m.mapBottom==829)
 wide:destroy()
 r:resetTimings();assert(r:metrics().timing_frame_calls==0)
 r:destroy();assert(r:playerColor(1)==nil)
end)
t.test('all store bit grids/scale sample correctly; second shades contrast on light/dark and ignore local border',function()
 local R=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))();local Core=R.Core
 local skins=luau.load(fs.readFile('src/shared/Store/Skins.luau'))()
 local Political=H.require(root.PoliticalColors)
 local terrain=buffer.create(96*96);buffer.fill(terrain,0,128)
 local tiles=buffer.create(96*96*2);for tile=0,96*96-1 do buffer.writeu16(tiles,tile*2,1) end
 for _,skin in skins.LIST do for _,hex in {'#e0e5ef','#161b28'} do
  local sink=R.sink(96,96);local c=Core.new(terrain,96,96,sink.backend)
  local mask=skins.mask(skin.id)
  Core.setRoster(c,{{id='a',smallID=1,playerType='HUMAN',cosmetics={color={color=hex}},pattern=mask}})
  Core.setLocalPlayer(c,1);Core.applyTileStates(c,tiles);R.drain(c)
  local entry=c.palette[1];local shade=entry.secondary
  assert(math.abs(entry.fill.r*.299+entry.fill.g*.587+entry.fill.b*.114-shade.r*.299-shade.g*.587-shade.b*.114)>.17)
  for y=20,55 do for x=20,55 do
   local px,py=bit32.rshift(x,mask.scale)%mask.width,bit32.rshift(y,mask.scale)%mask.height
   local secondary=skin.rows[py+1]:sub(px+1,px+1)=='#'
   local color=Political.fill({owner=1,x=x,y=y,defended=false,hovered=false,secondaryPattern=secondary},entry.fill,shade,{borderType=0,relation=0})
   local base=buffer.readu32(c.terrainLut,128*4);local actual=sink.pixel(x,y)
   for channel,k in {'r','g','b'} do
    local shift=(channel-1)*8;local expected=math.floor(color[k]*255*color.a+bit32.band(bit32.rshift(base,shift),255)*(1-color.a)+.5)
    assert(bit32.band(bit32.rshift(actual,shift),255)==expected,skin.id..' bit/scale/blend')
   end
  end end
  Core.setLocalPlayer(c,2);assert(c.palette[1].secondary.r==shade.r and c.palette[1].secondary.g==shade.g)
  Core.destroy(c)
 end end
 local sink=R.sink(96,96);local c=Core.new(terrain,96,96,sink.backend)
 Core.setRoster(c,{{id='a',smallID=1,playerType='HUMAN',pattern=skins.mask('s_stripes'),cosmetics={pattern={colorPalette={primaryColor='#112233',secondaryColor='#abcdef'}}}}})
 assert(c.palette[1].secondary.r==171/255 and c.palette[1].secondary.b==239/255);Core.destroy(c)
end)
t.test('Mega Nuke uses Atom sprite/interpolation, config radii, nuke trails/status and impact/interception FX',function()
 local u={id=1,type='Mega Nuke',owner=2,tile=10,lastTile=8,targetTile=60,active=true}
 local v=Visual.unit(u,64,1,.5);assert(v.column==3 and v.x==9 and v.missile and v.flicker and Visual.isSmoothed(u.type))
 local t=Visual.telegraph(u,64,0,0,{nukeMagnitudes=function(_,kind)assert(kind=='Mega Nuke');return {inner=25,outer=61}end})
 assert(t.inner==25 and t.outer==61)
 local trail=H.require(root.TrailManager).new(64,64);trail:update({[1]=u},{1},{[1]=true});assert(trail.values[8]==4098)
 trail:update({},{});assert(next(trail.values)==nil)
 local status=H.require(root.PlayerStatus).new():compute({{smallID=1,alive=true},{smallID=2,alive=true}}, {[1]=u},buffer.create(8192),1,{},0,nil)
 assert(status[2].nukeActive)
 local fx=H.require(root.FxState).new(64);u.reachedTarget=true;fx:deadUnit(u,0)
 assert(#fx.sprites>0 and #fx.shockwaves==1)
 local intercepted=H.require(root.FxState).new(64);u.reachedTarget=false;intercepted:deadUnit(u,0)
 assert(intercepted.shockwaves[1].radius==40)
end)
t.test('Mega Nuke preview reads confirmed silo/readiness/magnitudes and draws SAM-intercepted arc',function()
 local e,s,r=setup();s.gold=1e9;s.units[1]={id=1,type='Missile Silo',owner=1,tile=0,level=1,active=true,missileTimerQueue={}}
 local original=s:config();s.config=function()return setmetatable({nukeMagnitudes=function(_,kind)assert(kind=='Mega Nuke');return {inner=24,outer=60}end},{__index=original})end
 r:attachState(s)
 local p=e.Preview.new(r,s,function()error('manual reply')end)
 p:setChosen('Mega Nuke');p.reply={unit='Mega Nuke',tile=65,tick=0,buildable={type='Mega Nuke',canBuild=65,canUpgrade=false,cost=10,ghostRailPaths={},overlappingRailroads={}},rangeWarning=false,nukeAim={siloTile=0,sams={{x=1,y=1,r=20}}}}
 p:draw(65,1,1,false);assert(r.scene.buildPreview.rangeRadius==60 and r.scene.buildPreview.canAfford and r.scene.preview)
 s.units[1].missileTimerQueue={0};p.dataReply=nil;p:draw(65,1,1,false);assert(not r.scene.buildPreview.canAfford)
 p:draw(65,1,1,true);assert(r.scene.buildPreview==nil and r.scene.preview.tSamIntercept<=.9999)
 p:destroy();r:destroy()
end)
end

