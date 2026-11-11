--!strict
-- Actual Runner.buildPreview CPU on a synthetic, static land match. This is
-- neither a native server capture nor a rail-heavy late-game match.
local fs,luau,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/serde')
local H=luau.load(fs.readFile('tests/harness.luau'))();local S=H.shared()
local Game,Map,Config,Runner=H.require(S.OpenFront.Game),H.require(S.OpenFront.GameMap),H.require(S.OpenFront.EngineConfig),H.require(S.OpenFront.Runner)
local function map(w,h) local terrain=buffer.create(w*h);buffer.fill(terrain,0,128);return Map.new(w,h,terrain,w*h) end
local game=Game.new({{id='me',name='Me',clientID='me',playerType='HUMAN'},{id='other',name='Other',clientID='other',playerType='HUMAN'}},
	{},map(2000,1000),map(1000,500),Config.new({gameMode='Free For All',gameType='Singleplayer',difficulty='Medium'},false))
game.startTick,game._ticks=0,1000
local me,other=game:playerByClientID('me'),game:playerByClientID('other')
for _,p in {me,other} do p:addGold(1e15);p:setTroops(1e6) end
for y=400,599 do for x=200,499 do game:conquer(me,y*2000+x) end end
for y=400,599 do for x=1200,1499 do game:conquer(other,y*2000+x) end end
me:setSpawnTile(500*2000+250);other:setSpawnTile(500*2000+1250)
for i=1,100 do
	other:buildUnit('SAM Launcher',(400+math.floor((i-1)/10)*20)*2000+1200+(i-1)%10*25,{})
end
me:buildUnit('Missile Silo',500*2000+250,{})
local runner=setmetatable({game=game},Runner)
local build=me.buildableUnits;local buildMs=0
me.buildableUnits=function(self,...) local at=os.clock();local result=build(self,...);buildMs+=(os.clock()-at)*1000;return result end
local rail=game:railNetwork();local paths=rail.computeGhostRailPaths;local pathsMs=0
rail.computeGhostRailPaths=function(self,...) local at=os.clock();local result=paths(self,...);pathsMs+=(os.clock()-at)*1000;return result end
for _,kind in {'City','Factory','SAM Launcher','Atom Bomb'} do
	local times={};buildMs,pathsMs=0,0
	for i=1,120 do
		local tile=(470+i%10)*2000+350+i%20
		local at=os.clock();local reply=runner:buildPreview('me',tile,kind)
		assert(reply and reply.buildable)
		table.insert(times,(os.clock()-at)*1000)
	end
	table.sort(times);local total=0;for _,v in times do total+=v end
	print(serde.encode('json',{kind=kind,count=#times,meanMs=total/#times,p95Ms=times[math.ceil(#times*.95)],maxMs=times[#times],
		buildableMeanMs=buildMs/#times,ghostRailMeanMs=pathsMs/#times,enemySams=100,railStations=0}))
end
