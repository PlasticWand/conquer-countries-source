local fs,luau= require('@lune/fs'), require('@lune/luau')
local source=fs.readFile('tests/OpenFrontEffectsHarness.luau')
source=source:gsub('image.WritePixelsBuffer=function%(_,_,size,pixels%)', 'image.WritePixelsBuffer=function(_,pos,size,pixels) env.frameWrites=(env.frameWrites or 0)+1; image.pixels=image.pixels or buffer.create(image.Size.X*image.Size.Y*4); for y=0,size.Y-1 do buffer.copy(image.pixels,((pos.Y+y)*image.Size.X+pos.X)*4,pixels,y*size.X*4,size.X*4) end;')
local make=luau.load(source)()
local H=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
return function(t)
local function test(name,fn) t.test(name,fn) end
local function setup(w,h,count)
 local e=make();local state=e.client();state.width,state.height=w,h
 state.tileState=buffer.create(w*h*2);state.players,state.rosterOrder,state.names={},{},{}
 local roster={}
 for id=1,count or 2 do
  state.players[id]={id=`p{id}`,smallID=id,name=`Player{id}`,type='HUMAN',alive=true,troops=100,tiles=id,allies={},embargoes={}}
  state.rosterOrder[id]=id;state.names[id]={x=id%(w-1),y=id%(h-1),size=40}
  roster[id]={id=`p{id}`,smallID=id,playerType='HUMAN'}
 end
 local terrain=buffer.create(w*h);buffer.fill(terrain,0,128)
 for i=0,w*h-1 do buffer.writeu16(state.tileState,i*2,1+i%(count or 2)) end
 local r=e.Renderer.new(e.instance('Frame'),terrain,w,h,{autoStep=false,firstPaint='full',firstPaintBudgetMs=1})
 r:setRoster(roster);r:applyTileStates(state.tileState)
 return e,r,state,terrain,roster
end
local function step(e,r)
 e.frameWrites=0;local out=r:step();assert(e.frameWrites<=1,'one image per frame');return out
end
local function drain(e,r)
 local old=0
 for _=1,2000 do
  assert(not r.root.Visible or r:isReady(),'partial root exposed')
  step(e,r);assert(r:loadProgress()>=old,'progress regressed');old=r:loadProgress()
  if r:isReady() then return end
 end
 error('ready stalled')
end
test('snapshot required, all pages exact, settling frame and callback lifecycle',function()
 local e,r,state,terrain,roster=setup(1027,39)
 local calls,cancelled=0,0
 r:onReady(function()calls+=1 end);local off=r:onReady(function()cancelled+=1 end);off()
 for _=1,100 do step(e,r) end
 assert(not r:isReady() and not r.root.Visible,'ready before confirmed state')
 r:attachState(state)
 local priorUploads=r.firstPaintWrites
 while not r:isReady() do
  local old=r.firstPaintWrites;step(e,r)
  if r.firstPaintWrites>old then assert(not r:isReady(),'no settling frame') end
 end
 assert(r.root.Visible and calls==1 and cancelled==0 and r:loadProgress()==1)
 assert(r.firstPaintWrites>=priorUploads and r.firstPaintBytes==0 and next(r.firstPaintBuffers)==nil)
 r:onReady(function()calls+=1 end);step(e,r);assert(calls==2)
 local sink=H.sink(1027,39);local core=H.Core.new(terrain,1027,39,sink.backend)
 H.Core.setRoster(core,roster);H.Core.setLocalPlayer(core,1);H.Core.applyTileStates(core,state.tileState);H.drain(core)
 for _,d in r.displays do for y=0,d.page.height-1 do for x=0,d.page.width-1 do
  assert(buffer.readu32(d.image.pixels,(y*d.page.width+x)*4)==sink.pixel(d.page.x+x,d.page.y+y),'first paint pixel mismatch')
 end end end
 H.Core.destroy(core);r:destroy();assert(not r:isReady());for _,img in e.images do assert(img.destroyed) end
end)
test('empty server anchors never trigger fallback, delayed anchors are placed',function()
 local e,r,state=setup(64,64);state.names={};r:attachState(state);step(e,r)
 assert(r.scene.nameAnchorMode=='server' and r.scene.nameScan==nil)
 state.names={[1]={x=20,y=20,size=40},[2]={x=40,y=40,size=40}}
 state.NamesChanged:Fire();drain(e,r)
 assert(r.scene.nameViews[1] and r.scene.nameViews[2] and r.scene.namesPlaced)
 r:destroy()
end)
test('visible labels deferred across frames are complete before readiness',function()
 local e,r,state=setup(128,128,80);r:attachState(state)
 step(e,r);local n=0;for _ in r.scene.nameViews do n+=1 end
 assert(n<=25 and not r:isReady(),'name creation budget')
 drain(e,r);for id=1,80 do assert(r.scene.nameViews[id],'visible name missing') end
 r:destroy()
end)
test('live invalidation of an uploaded page is included before reveal',function()
 local e,r,state=setup(1027,39);r:attachState(state)
 while not r.firstPaintUploaded[1] do step(e,r) end
 buffer.writeu16(state.tileState,0,2+8192);r:applyTileStates(state.tileState,{0})
 drain(e,r);assert(r.firstPaintWrites>=3,'uploaded page was not refreshed')
 local first=r.displays[1].image.pixels
 local sink=H.sink(1027,39);local core=H.Core.new(r.core.terrain,1027,39,sink.backend)
 H.Core.setRoster(core,r.core.roster);H.Core.setLocalPlayer(core,1);H.Core.applyTileStates(core,state.tileState);H.drain(core)
 assert(buffer.readu32(first,0)==sink.pixel(0,0));H.Core.destroy(core);r:destroy()
end)
test('teardown cancels ready listeners and input is excluded while loading',function()
 local e,r,state=setup(64,64);r:attachState(state)
 local tap,context,ready=0,0,0
 r:onReady(function()ready+=1 end)
 r:bindInput(e.playerGui,e.mapGui,function()tap+=1 end,nil,nil,function()context+=1 end)
 e.mouseTap(400,200);assert(tap==0 and context==0)
 r:destroy();e.render:Fire(.1);assert(ready==0 and next(r.readyListeners)==nil and r.firstPaintBytes==0)
end)
test('a press begun under loading cannot become a release order after reveal',function()
 local e,r,state=setup(64,64);r:attachState(state)
 local taps=0;r:bindInput(e.playerGui,e.mapGui,function()taps+=1 end)
 local input={UserInputType=require('@lune/roblox').Enum.UserInputType.MouseButton1,Position={X=400,Y=200,Z=0}}
 e.uis.InputBegan:Fire(input,false);drain(e,r);e.uis.InputEnded:Fire(input,false)
 assert(taps==0);e.mouseTap(400,200);assert(taps==1)
 r:destroy()
end)
test('allocation failure cleans staged pages and never fires ready',function()
 local e,r,state=setup(64,64);r:attachState(state);e.failStatus=true
 local called=0;r:onReady(function()called+=1 end)
 local ok=pcall(function()drain(e,r)end)
 assert(not ok and r.destroyed and called==0 and r.firstPaintBytes==0 and next(r.firstPaintBuffers)==nil)
 for _,img in e.images do assert(img.destroyed) end
end)
test('spawn/status/unit atlases and dense units share the loading budget',function()
 local e,r,state=setup(128,128,80)
 state.players[1].spawnTile=0;state.players[2].spawnTile=100
 for id=1,80 do state.units[id]={id=id,type='City',owner=1,tile=1000+id,active=true,level=1} end
 r:attachState(state);drain(e,r)
 for id=1,80 do assert(r.scene.unitViews[id],'unit missing before ready') end
 assert(r.scene.effects.atlas and r.scene.nameStatus.atlas,'atlas missing before ready')
 assert(r:metrics().firstPaintPeakStagingBytes==128*128*4)
 r:destroy()
end)
test('incremental updates restore the live pixel budget after ready',function()
 local e,r,state=setup(64,64);r:attachState(state);drain(e,r)
 for i=0,4095 do buffer.writeu16(state.tileState,i*2,2) end
 r:applyTileStates(state.tileState);r.options.pixelBudget=1
 local out=step(e,r);assert(out.pixels<=32 and r.core.pending>0 and r.root.Visible)
 r:destroy()
end)
end
