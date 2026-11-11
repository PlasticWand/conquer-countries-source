--!strict
-- Actual renderer/input/ClientState paths under the native-property shim.
-- These checks exclude native layout, GPU cost and real-device input feel.
return function(t)
	local fs,luau,roblox=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local function setup():any
		local e=native(); local s=e.client(); s.startTick=0
		s.units[1]={id=1,type='Warship',owner=1,active=true,tile=65,warship={patrolTile=0}}
		s.units[2]={id=2,type='Warship',owner=1,active=true,tile=64*40+40,warship={patrolTile=64*30+30}}
		s.units[3]={id=3,type='Warship',owner=2,active=true,tile=64*50+50,warship={patrolTile=65}}
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		r:attachState(s)
		local taps,moves,edges={},{},{}
		r:onWarshipSelected(function(id) table.insert(edges,id or false) end)
		r:bindInput(e.playerGui,e.mapGui,function(tile) table.insert(taps,tile) end,
			function(ids,tile) table.insert(moves,{ids=ids,tile=tile}) end)
		local function tap(tile:number)
			local x,y=r:worldToScreen(tile%64+.5,math.floor(tile/64)+.5); e.mouseTap(x,y)
		end
		return e,s,r,tap,edges,taps,moves
	end
	t.test('tap selection is consumed; the next water tap, including the same ship, moves once and emits nil',function()
		local _,s,r,tap,edges,taps,moves=setup()
		tap(65); t.eq(edges[1],1); t.eq(#taps,0); t.eq(#moves,0)
		tap(65); t.eq(edges[2],false); t.eq(#edges,2); t.eq(#taps,0)
		t.eq(#moves,1); t.eq(moves[1].ids[1],1); t.eq(moves[1].tile,65)
		t.eq(s.units[1].warship.patrolTile,0,'move leaves confirmed patrol untouched')
		tap(65); tap(0); t.eq(edges[3],1); t.eq(edges[4],false)
		t.eq(moves[2].tile,0); t.eq(#taps,0)
		tap(s.units[3].tile); t.eq(#edges,4); t.eq(taps[1],s.units[3].tile,'enemy ship is not selectable')
		r:destroy()
	end)
	t.test('Escape, ButtonB and explicit context clear emit only selection edges',function()
		local e,_,r,tap,edges=setup()
		for _,key in {roblox.Enum.KeyCode.Escape,roblox.Enum.KeyCode.ButtonB} do
			tap(65)
			e.uis.InputBegan:Fire({KeyCode=key,Position={X=0,Y=0}},false)
			t.eq(edges[#edges],false); t.eq(r:hasSelection(),false)
		end
		tap(65); r:clearSelection(); r:clearSelection()
		t.eq(#edges,6); t.eq(edges[6],false)
		r:destroy(); t.eq(#edges,6,'already clear teardown has no duplicate nil')
	end)
	t.test('confirmed death, removal, capture and viewer changes close the card before another render frame',function()
		for _,change in {'death','removal','capture','viewer'} do
			local _,s,r,tap,edges=setup(); tap(65)
			if change=='viewer' then r:setLocalPlayer(2)
			else
				if change=='death' then s.units[1].active=false
				elseif change=='capture' then s.units[1].owner=2 else s.units[1]=nil end
				s.UnitsChanged:Fire({},if change=='removal' then {1} else {})
			end
			t.eq(#edges,2,change); t.eq(edges[2],false); t.eq(r:hasSelection(),false)
			r:destroy()
		end
	end)
	t.test('box and select-all close tap cards even with one ship; pruning multi-selection never opens one',function()
		local _,s,r,tap,edges=setup(); tap(65)
		local x,y=r:worldToScreen(1,1)
		r:completeSelectionBox(x-1,y-1,x+1,y+1)
		t.eq(#edges,2); t.eq(edges[2],false); t.eq(#r.scene.selection.ids,1)
		r:clearSelection(); tap(65); r:selectAllWarships()
		t.eq(#edges,4); t.eq(edges[4],false); t.eq(#r.scene.selection.ids,2)
		s.units[2].owner=2; s.UnitsChanged:Fire({s.units[2]},{}); r:hasSelection()
		t.eq(#edges,4,'one remaining multi-selected ship does not open the card')
		r:clearSelection(); tap(65); r:selectAllWarships()
		t.eq(#edges,6); t.eq(edges[6],false,'select-all closes even when only one own ship remains')
		r:destroy()
	end)
	t.test('listeners disconnect, isolate errors and receive nil on active teardown without retaining callbacks',function()
		local _,_,r,tap,edges=setup()
		local calls=0
		local off=r:onWarshipSelected(function() calls+=1 end); off(); off()
		local offError=r:onWarshipSelected(function() error('expected listener error') end)
		tap(65); t.eq(edges[1],1); t.eq(calls,0); offError()
		local scene=r.scene; r:destroy()
		t.eq(edges[2],false); t.eq(#edges,2); t.eq(next(r.warshipListeners),nil)
		t.eq(scene.selection.onSingleChanged,nil)
		r:onWarshipSelected(function() calls+=1 end); r:setWarshipPatrolVisible(1)
		t.eq(calls,0); r:destroy(); t.eq(#edges,2)
	end)
	t.test('patrol uses confirmed centre and config radius, follows patrol updates, and reuses one own-style disc',function()
		local e,s,r=setup()
		r:setWarshipPatrolVisible(1); r:step(1e9,1e9)
		local f=r.scene.rangeViews.WarshipPatrol
		local radius=s:config():warshipPatrolRange()
		t.ok(f.Visible); t.near(f.Position.X.Offset,(.5-radius)*64,1e-3,'tile zero is a confirmed centre')
		t.near(f.Size.X.Offset,radius*128,1e-3)
		t.eq(f.BackgroundColor3,roblox.Color3.fromRGB(255,211,64)); t.near(f.BackgroundTransparency,.91,1e-6)
		local stroke=r.scene.rangeStrokes[f]; t.near(stroke.Thickness*r.camera.scale/64,3,1e-5)
		s.units[1].tile=64*10+10; s.UnitsMoved:Fire({1}); r:step(1e9,1e9)
		t.near(f.Position.X.Offset,(.5-radius)*64,1e-3,'moving boat does not drag the patrol centre')
		s.units[1].warship.patrolTile=64*30+20; s.UnitsChanged:Fire({s.units[1]},{}); r:step(1e9,1e9)
		t.near(f.Position.X.Offset,(20.5-radius)*64,1e-3); t.near(f.Position.Y.Offset,(30.5-radius)*64,1e-3)
		for _=1,12 do r:step(1e9,1e9) end
		local created=#e.objects
		for _=1,5 do r:step(1e9,1e9) end; t.eq(#e.objects,created)
		local layer=r.scene.layers.Ranges; local before=layer.Position
		r:pan(10,0); t.ok(layer.Position~=before,'existing geometry transforms before the next step')
		r:setWarshipPatrolVisible(2); r:step(1e9,1e9); t.eq(r.scene.rangeViews.WarshipPatrol,f)
		r:setWarshipPatrolVisible(nil); t.eq(f.Visible,false)
		r:destroy(); t.ok(f.destroyed)
	end)
	t.test('patrol never falls back to ship tile and hides on death, capture, wrong type or absent records',function()
		local _,s,r=setup()
		r:setWarshipPatrolVisible(1); r:step(1e9,1e9); local f=r.scene.rangeViews.WarshipPatrol
		for _,tile in {false,-1,4096,1.5} do
			s.units[1].warship.patrolTile=if tile==false then nil else tile
			r:step(1e9,1e9); t.eq(f.Visible,false)
		end
		s.units[1].warship=nil; r:step(1e9,1e9); t.eq(f.Visible,false)
		s.units[1].warship={patrolTile=0}; r:step(1e9,1e9); t.eq(f.Visible,true)
		for _,change in {'death','capture','type','removal'} do
			s.units[1]={id=1,type='Warship',active=true,owner=1,tile=65,warship={patrolTile=0}}
			r:setWarshipPatrolVisible(1); r:step(1e9,1e9); t.eq(f.Visible,true)
			if change=='death' then s.units[1].active=false elseif change=='capture' then s.units[1].owner=2
			elseif change=='type' then s.units[1].type='City' else s.units[1]=nil end
			s.UnitsChanged:Fire({},{}); t.eq(f.Visible,false,change)
		end
		r:setWarshipPatrolVisible(3); r:step(1e9,1e9); t.eq(f.Visible,false,'enemy request hidden')
		r:destroy()
	end)
	t.test('pinned warship ghost symbol is translucent, red when invalid or unaffordable, retained and cleared',function()
		local e,s,r=setup(); s.costs.Warship=500000; s.gold=2000000
		local allowed=true
		local p=e.Preview.new(r,s,function(tile,unit)
			return {tile=tile,unit=unit,buildable={type=unit,canBuild=if allowed then tile else false,canUpgrade=false,cost=500000}}
		end)
		p:setChosen('Warship'); p:setPendingTile(0); p:step(); r:step(1e9,1e9)
		local ghost=r.scene.warshipGhost
		t.ok(ghost and ghost.root.Visible,'mobile warship must draw a symbol as well as the circle and cost')
		t.eq(#ghost.parts,4); t.eq(ghost.root.Parent,r.scene.layers.Ground)
		t.near(ghost.root.Position.X.Scale,.5/64,1e-6); t.near(ghost.root.Size.X.Offset,13*64,1e-6)
		for band,part in ghost.parts do
			t.ok(part.Visible); t.eq(part.ImageRectOffset,roblox.Vector2.new(26,(band-1)*13))
			t.eq(part.ImageRectSize,roblox.Vector2.new(13,13)); t.near(part.ImageTransparency,.5,1e-6)
		end
		t.ok(r.scene.rangeViews.BuildRange.Visible); t.eq(r.scene.ghostCost.Text,'500K')
		t.eq(#r.scene.ghostRails,0,'no route line from the port')
		e.completeQuery(); p:step(); r:step(1e9,1e9)
		t.eq(r.scene.buildPreview.validated,true); t.ok(ghost.root.Visible)
		s.gold=0; p:step(); r:step(1e9,1e9)
		local red=roblox.Color3.fromRGB(255,75,69)
		t.eq(ghost.parts[1].ImageColor3,red,'unaffordable is red')
		s.gold=2000000; allowed=false; p:setPendingTile(64*20+25); p:step(); e.completeQuery(); p:step(); r:step(1e9,1e9)
		t.eq(ghost.parts[1].ImageColor3,red,'confirmed invalid is red')
		t.near(ghost.root.Position.X.Scale,25.5/64,1e-6); t.near(ghost.root.Position.Y.Scale,20.5/64,1e-6)
		e.blocked=true; r:pan(10,0); p:step(); r:step(1e9,1e9); t.ok(ghost.root.Visible)
		for tile=1300,1311 do
			p:setPendingTile(tile); p:step(); r:step(1e9,1e9)
			t.eq(r.scene.warshipGhost,ghost); t.near(ghost.parts[1].ImageTransparency,.5,1e-6,'alpha never compounds')
		end
		p:setChosen('City'); p:setPendingTile(0); p:step(); r:step(1e9,1e9)
		t.eq(ghost.root.Visible,false); t.ok(r.scene.ghostViews[1].root.Visible)
		p:setChosen('Warship'); p:setPendingTile(0); p:step(); r:step(1e9,1e9)
		t.ok(ghost.root.Visible); t.eq(r.scene.ghostViews[1].root.Visible,false)
		p:setPendingTile(nil); p:step(); r:step(1e9,1e9); t.eq(ghost.root.Visible,false)
		p:destroy(); r:destroy(); t.ok(ghost.root.destroyed); t.eq(r.scene,nil)
	end)
	t.test('pinned warship placement shows a patrol disc before and after validation, then moves and clears',function()
		local e,s,r=setup(); s.costs.Warship=500000; s.gold=2000000
		local p=e.Preview.new(r,s,function(tile,unit)
			return {tile=tile,unit=unit,buildable={type=unit,canBuild=tile,canUpgrade=false,cost=500000}}
		end)
		p:setChosen('Warship'); p:setPendingTile(0); p:step(); r:step(1e9,1e9)
		local radius=s:config():warshipPatrolRange(); local f=r.scene.rangeViews.BuildRange
		t.eq(r.scene.buildPreview.validated,false); t.ok(f.Visible); t.near(f.Size.X.Offset,radius*128,1e-3)
		e.completeQuery(); p:step(); r:step(1e9,1e9)
		t.eq(r.scene.buildPreview.validated,true); t.eq(r.scene.buildPreview.rangeRadius,radius)
		e.blocked=true; r:pan(10,0); p:step(); r:step(1e9,1e9); t.ok(f.Visible)
		p:setPendingTile(64*20+25); p:step(); r:step(1e9,1e9)
		t.near(f.Position.X.Offset,(25.5-radius)*64,1e-3)
		p:setPendingTile(nil); p:step(); r:step(1e9,1e9); t.eq(f.Visible,false)
		e.completeQuery(); p:step(); r:step(1e9,1e9); t.eq(f.Visible,false,'stale placement query cannot restore it')
		p:destroy(); r:destroy()
	end)
end
