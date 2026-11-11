--!strict
-- Controlled presentation time and real renderer properties; no native feel/GPU claim.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Feel=H.require(root.FeelState)
	local native=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local function count(items:any):number local n=0; for _ in items do n+=1 end; return n end
	local function unit(id:number,kind:string?,owner:number?):any
		return {id=id,type=kind or 'City',owner=owner or 1,tile=64*32+32,level=1,active=true,underConstruction=true,constructionStartTick=0}
	end
	local function setup(split:boolean?):any
		local e=native()
		e.policy.splitMapGuis=split==true
		e.mapGui.DisplayOrder=0
		local s=e.client(); s.startTick=0
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false,guiHost=e.mapGui,coasts=false})
		r:attachState(s)
		for _=1,100 do r:step(1e9,1e9) end
		r:setCamera({width=64,height=64,viewportWidth=844,viewportHeight=390,left=0,top=0,offsetX=0,offsetY=0,scale=4})
		return e,s,r
	end
	local function update(s:any,u:any)
		s.units[u.id]=u; s.UnitsChanged:Fire({u},{})
	end

	t.test('copied baselines suppress snapshots, foreign capture, inactive records and invisible births',function()
		local f=Feel.new(); local old=unit(1); local foreign=unit(2,nil,2)
		f:seed({[1]=old,[2]=foreign})
		old.underConstruction=false
		f:updates({old},{},1,function() return true end,0)
		t.ok(f.units[1].complete,'mutable input did not erase the old construction flag')
		t.eq(f.units[1].settle,false)
		foreign.owner=1; f:updates({foreign},{},1,function() return true end,0)
		t.eq(f.units[2],nil,'a capture is not a new build')
		local inactive=unit(3); inactive.active=false
		f:updates({inactive,unit(4),unit(5,nil,2)},{},1,function() return false end,0)
		t.eq(count(f.units),1)
		f:seed({[1]=old}); t.eq(count(f.units),0)
		f:updates({old},{},1,function() return true end,1); t.eq(count(f.units),0)
	end)

	t.test('continuous own construction and level edges fire once, cancel on loss, and have bounded caps',function()
		local f=Feel.new(); local u=unit(1)
		f:seed({[1]=u}); u.underConstruction=false; u.level=2
		f:updates({u},{},1,function() return true end,0)
		t.ok(f.units[1].complete); t.ok(f.units[1].upgrade)
		f:expire(.3); f:updates({u},{},1,function() return true end,.3); t.eq(count(f.units),0)
		local updates={}; for i=2,30 do table.insert(updates,unit(i)) end
		f:updates(updates,{},1,function() return true end,1); t.eq(count(f.units),Feel.unitCap)
		local capture=updates[1]; capture.owner=2
		f:updates({capture},{3},1,function() return true end,1); t.eq(f.units[2],nil); t.eq(f.units[3],nil)
		for i=1,30 do f:pulse('impact',i,0,1) end
		t.eq(#f.pulses,Feel.pulseCap); t.eq(f.pulses[1].x,27)
		f:pulse('unsupported',0,0,1); t.eq(#f.pulses,Feel.pulseCap)
		f:focusAt(0,0,1); f:expire(1.31)
		t.eq(count(f.units),0); t.eq(#f.pulses,0); t.ok(f.focus.pending)
		f:expire(6.01); t.eq(f.focus,nil,'unseen focus has a bounded wait')
	end)

	t.test('authoring curves reach exact settle endpoints and marks grow at far zoom',function()
		t.near(Feel.settle(0),.90,1e-8); t.near(Feel.settle(.065),1.08,1e-8)
		t.near(Feel.settle(.16),1,1e-8); t.near(Feel.numeral(.10),1.25,1e-8); t.near(Feel.numeral(.2),1,1e-8)
		local far=Feel.mark('impact',0,.2); local close=Feel.mark('impact',0,8); t.ok(far>close)
		local radius,alpha=Feel.mark('focus',.13,4); t.near(radius,12,1e-8); t.eq(alpha,0)
		local _,ended=Feel.mark('focus',.30,4); t.near(ended,1,1e-8)
	end)

	t.test('loss shares pulse caps, has one visible alert, and offscreen events never queue',function()
		local _,_,r=setup(); local f=r.scene.feel
		local camera=table.clone(r.camera); camera.viewportWidth,camera.viewportHeight=128,128; r:setCamera(camera)
		r:pulse('loss',0); t.eq(#f.state.pulses,0)
		r:pulse('loss',64*32+32); r:step(1e9,1e9)
		t.eq(#f.state.pulses,1); t.eq(f.state.pulses[1].kind,'loss')
		local ring=f.markRings[1]; t.ok(ring.frame.Visible); t.eq(ring.stroke.Color,rb.Color3.fromRGB(245,77,70))
		local start=f.state.pulses[1].start
		local before=ring.frame.Size.X.Offset; f:step(start+.2); t.ok(ring.frame.Size.X.Offset<before)
		for _=1,12 do r:pulse('loss',64*32+32) end
		t.eq(#f.state.pulses,1)
		for _=1,12 do r:pulse('impact',64*32+32) end
		t.eq(#f.state.pulses,Feel.pulseCap)
		f.state.pulses={}; r:pulse('loss',64*32+32); f:step(f.state.pulses[1].start+.401)
		t.eq(#f.state.pulses,0); t.eq(ring.frame.Visible,false)
		r:destroy()
	end)

	t.test('only a continuously own active transport reaching its target splashes, once',function()
		local f=Feel.new(64); local u=unit(1,'Transport'); u.targetTile=0
		f:seed({[1]=u}); u.active=false; u.reachedTarget=true
		f:updates({u},{},1,function() return true end,0)
		t.eq(#f.pulses,1); t.eq(f.pulses[1].kind,'landing'); t.eq(f.pulses[1].x,.5); t.eq(f.pulses[1].y,.5)
		f:updates({u},{},1,function() return true end,.1); t.eq(#f.pulses,1,'duplicate final did not splash twice')
		f:atTile('home',0,.1); t.eq(#f.pulses,1); t.eq(f.pulses[1].kind,'home','confirmed caller home replaces splash')
		for _,mode in {'retreat','missing','unknown','foreign','offscreen'} do
			local boat=unit(2,'Transport'); f:seed(if mode=='unknown' then {} else {[2]=boat})
			boat.active=false; boat.reachedTarget=mode~='missing'; boat.retreating=mode=='retreat'
			if mode=='foreign' then boat.owner=2 end
			f:updates({boat},{2},1,function() return mode~='offscreen' end,0)
			t.eq(#f.pulses,0,mode..' did not invent a landing')
		end
	end)

	t.test('warship input acknowledgement precedes callback; only a matching changed patrol confirms once',function()
		local e,s,r=setup(); local a=unit(1,'Warship'); a.warship={patrolTile=1}
		local b=unit(2,'Warship'); b.warship={patrolTile=1}
		s.units={[1]=a,[2]=b}; s.Snapshot:Fire(); r.scene:setUnits(s.units)
		local f=r.scene.feel; local calls=0
		r:bindInput(e.playerGui,e.mapGui,function() error('warship move became a tile action') end,function(ids,tile)
			calls+=1; t.eq(f.state.pulses[#f.state.pulses].kind,'move'); t.eq(f.state.orders[1].tile,tile)
			t.eq(#ids,2); t.eq(a.warship.patrolTile,1)
		end)
		r.scene.selection.ids={1,2}
		local tile=64*34+34; local x,y=r:worldToScreen(34.5,34.5); e.mouseTap(x,y)
		t.eq(calls,1); t.eq(#f.state.orders,1)
		a.warship.patrolTile=2; update(s,a); t.eq(#f.state.pulses,1,'different destination did not confirm')
		a.warship.patrolTile=tile; update(s,a); t.eq(#f.state.pulses,2); t.eq(f.state.pulses[2].kind,'moveConfirmed')
		b.warship.patrolTile=tile; update(s,b); update(s,a); t.eq(#f.state.pulses,2); t.eq(#f.state.orders,0)
		r:step(1e9,1e9); t.eq(f.markRings[2].stroke.Color,rb.Color3.fromRGB(139,226,188))
		f.state:move({1},0,s.units,1,0); f.state:expire(3.01); t.eq(#f.state.orders,0)
		f.state:move({1},0,s.units,1,4); s.Snapshot:Fire(); t.eq(#f.state.orders,0)
		r:destroy()
	end)

	t.test('pending warship orders are copied, superseded, capped and pruned without claiming acceptance',function()
		local f=Feel.new(64); local units={}
		for id=1,6 do local u=unit(id,'Warship'); u.warship={patrolTile=0}; units[id]=u end
		f:seed(units)
		local ids={1,2}; f:move(ids,10,units,1,0); ids[1]=6
		t.ok(f.orders[1].ids[1]); t.eq(f.orders[1].ids[6],nil)
		f:move({1},11,units,1,.1); t.eq(f.orders[1].ids[1],nil)
		units[1].warship.patrolTile=10; f:updates({units[1]},{},1,function() return true end,.2)
		t.eq(f.pulses[#f.pulses].kind,'move','superseded destination did not confirm')
		units[1].owner=2; f:updates({units[1]},{},1,function() return true end,.3); f:expire(.3)
		t.eq(#f.orders,1,'the other ship retains its original order')
		f:updates({},{2},1,function() return true end,.4); f:expire(.4); t.eq(#f.orders,0)
		units[1].owner=1
		for id=1,6 do f:move({id},100+id,units,1,1) end
		t.eq(#f.orders,4); t.eq(#f.pulses,Feel.pulseCap)
		f:seed(units); t.eq(#f.orders,0); t.eq(#f.pulses,0)
	end)

	t.test('real own symbol settles without moving root, progress or ranges; completion and numeral reuse slots',function()
		local e,s,r=setup(); local u=unit(1); update(s,u); r:step(1e9,1e9)
		local feel=r.scene.feel; local slot=feel.slots[1]; local view=r.scene.unitViews[1]
		t.ok(slot and slot.symbol.Visible); t.eq(view.parts[1].Parent,slot.symbol)
		local position,size=view.root.Position,view.root.Size
		local bar=view.progress.background; local barSize=bar.Size
		feel:step(.065); t.near(slot.scale.Scale,1.08,1e-6)
		t.eq(view.root.Position,position); t.eq(view.root.Size,size); t.eq(bar.Size,barSize)
		t.eq(bar.Parent,view.root,'progress is outside the animated symbol')
		t.eq(slot.dust[1].Visible,true)
		feel:step(.30); t.eq(view.parts[1].Parent,view.root); t.eq(slot.scale.Scale,1)
		e.now=.4; u.underConstruction=false; u.level=2; update(s,u); r:step(1e9,1e9)
		t.ok(slot.rim.Visible); t.eq(slot.levelScale.Parent,view.level)
		t.eq(view.level.AnchorPoint,rb.Vector2.new(.5,.5))
		feel:step(.50); t.near(slot.levelScale.Scale,1.25,1e-6)
		feel:step(.70); t.eq(slot.levelScale.Parent,nil); t.eq(slot.rim.Visible,false)
		t.eq(#feel.slots,1)
		r:destroy()
	end)

	t.test('boat hull and landing accent follow confirmed movement and never replay a snapshot',function()
		local e,s,r=setup(); local u=unit(2,'Transport'); u.targetTile=0
		update(s,u); r:step(1e9,1e9)
		local f=r.scene.feel; local slot=f.slots[1]
		t.ok(slot.rim.Visible); t.ok(slot.landing.Visible,'tile zero is a real landing target')
		t.eq(slot.dust[1].Visible,false)
		local at=slot.rim.Position; e.now=.05; u.tile+=1; update(s,u); r:step(1e9,1e9)
		t.ok(slot.rim.Position~=at); t.eq(count(f.state.units),1)
		s.Snapshot:Fire(); t.eq(count(f.state.units),0); t.eq(slot.landing.Visible,false)
		t.eq(r.scene.unitViews[2].parts[1].Parent,r.scene.unitViews[2].root)
		update(s,u); r:step(1e9,1e9); t.eq(count(f.state.units),0)
		r:destroy()
	end)

	t.test('removal and viewer changes restore pooled symbol parents before scene destruction and suppress replay',function()
		local e,s,r=setup(); update(s,unit(1)); r:step(1e9,1e9)
		local f=r.scene.feel; local slot=f.slots[1]; local old=r.scene.unitViews[1].root
		s.units[1]=nil; s.UnitsChanged:Fire({},{1})
		t.ok(old.destroyed); t.eq(slot.symbol.destroyed,false); t.eq(slot.symbol.Parent,f.root)
		update(s,unit(2)); r:step(1e9,1e9); t.eq(#f.slots,1); t.eq(slot.id,2)
		r:setLocalPlayer(2); t.eq(count(f.state.units),0); t.eq(slot.symbol.Parent,f.root)
		r:setLocalPlayer(1); update(s,s.units[2]); r:step(1e9,1e9); t.eq(count(f.state.units),0)
		local objects=#e.objects
		for _=1,20 do r:pulse('impact',64*32+32); r:step(1e9,1e9) end
		local pooled=#e.objects
		for _=1,20 do r:pulse('impact',64*32+32); r:step(1e9,1e9) end
		t.ok(pooled>objects); t.eq(#e.objects,pooled,'pulse pool did not grow after reaching its cap')
		r:destroy(); t.ok(slot.symbol.destroyed); t.ok(slot.levelScale.destroyed)
	end)

	t.test('public pulses and focus use full-bleed screen coordinates in both modes without uploads, and clean up',function()
		for _,split in {false,true} do
			local e,s,r=setup(split); local f=r.scene.feel
			local camera=table.clone(r.camera); camera.left,camera.top=27,39; r:setCamera(camera)
			e.recordUploads=true; e.uploads={}; local imageCount=#e.images
			local before=table.clone(r.camera)
			r:focusAt(10000,10000); r:step(1e9,1e9); t.ok(f.state.focus.pending)
			r:pulse('impact',64*32+32); r:focusAt(32.5,32.5); r:step(1e9,1e9)
			t.eq(f.state.focus.pending,false)
			t.eq(#e.images,imageCount); t.eq(#e.uploads,0)
			t.eq(r.camera.offsetX,before.offsetX); t.eq(r.camera.scale,before.scale)
			t.eq(f.root.Parent,if split then r.guiLayers.roots.Effects else r.root)
			local sx,sy=r:worldToScreen(32.5,32.5)
			local bar=f.marks[1][1]; t.ok(bar.Visible)
			t.ok(math.abs(bar.Position.X.Offset-(sx-27))<30); t.ok(math.abs(bar.Position.Y.Offset-(sy-39))<30)
			local at=bar.Position; r:pan(15,7); f:step(f.state.pulses[1].start)
			local sx2,sy2=r:worldToScreen(32.5,32.5)
			t.near(bar.Position.X.Offset-at.X.Offset,sx2-sx,1e-4); t.near(bar.Position.Y.Offset-at.Y.Offset,sy2-sy,1e-4)
			for _=1,40 do r:pulse('impact',0); r:pulse('tap',64*32+32) end
			r:step(1e9,1e9); t.eq(#f.state.pulses,Feel.pulseCap); t.ok(#f.marks<=Feel.pulseCap+1)
			for _,kind in {'loss','landing','home','move','moveConfirmed'} do r:pulse(kind,64*32+32); r:step(1e9,1e9) end
			t.eq(#e.images,imageCount); t.eq(#e.uploads,0); t.ok(#f.markRings<=Feel.pulseCap+1)
			s.winner='me'; s.PhaseChanged:Fire(); t.eq(#f.state.pulses,0); t.eq(f.state.focus,nil)
			for _,ring in f.markRings do t.eq(ring.frame.Visible,false) end
			local rootGui=f.root; r:destroy(); t.ok(rootGui.destroyed); t.eq(next(f.state.seen),nil)
			r:pulse('impact',0); r:focusAt(0,0)
		end
	end)
end
