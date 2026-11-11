--!strict
-- Confirmed sinking and bounded recent presentation work; no GPU assertions.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local make=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Art,Fx,Masks=H.require(root.ShipArt),H.require(root.FxState),H.require(root.FalloutMasks)
	local function setup(count)
		local e=make(); e.uis.TouchEnabled=true; local s=e.client(); s.startTick=0; s.names={}
		for id=1,count do s.units[id]={id=id,type='Warship',owner=1,tile=128+id,lastTile=127+id,
			active=true,health=100,maxHealth=100,warship={state='patrolling',veterancy=0}} end
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false,firstPaint='full',coasts=false})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'}}); r:attachState(s)
		for _=1,200 do e.now+=1/60; r:step(1e9,1e9); if r:isReady() then break end end
		assert(r:isReady()); return e,s,r
	end
	t.test('moving decorated warships keep their pose path through zoom without changing hull or bar geometry',function()
		local e,s,r=setup(1);local unit=s.units[1]
		unit.health=50;unit.warship.veterancy=3;s.UnitsChanged:Fire({unit},{})
		for _=1,40 do e.now+=1/60;r:step(1e9,1e9) end
		local v=r.scene.unitViews[1];local hull=v.parts[1];local content=hull.ImageContent
		local size,barSize,barPosition=v.root.Size,v.health.background.Size,v.health.background.Position
		for _,zoom in {.8,3,10,.9} do
			local before=r.scene.unitPoseDraws or 0
			local camera=table.clone(r.camera);camera.scale=zoom;r:setCamera(camera)
			unit.lastTile=unit.tile;unit.tile+=1;s.tick+=1;s.UnitsMoved:Fire({1});s.TickApplied:Fire(s.tick)
			e.now+=1/60;r:step(1e9,1e9)
			t.ok((r.scene.unitPoseDraws or 0)>before,'moved warship used pose path at changed zoom')
			t.eq(v.root.Size,size);t.eq(v.health.background.Size,barSize);t.eq(v.health.background.Position,barPosition)
			t.eq(v.parts[1],hull);t.eq(hull.ImageContent,content);t.eq(v.pips.Text,'▰▰▰')
			local scale=1;for _,o in e.objects do if o.Parent==v.pips and o.ClassName=='UIScale' then scale=o.Scale end end
			t.near(v.pips.TextSize*scale,math.max(8/(zoom/64),3*64),1e-4)
			t.eq(v.record.tile,unit.tile);t.eq(v.pipZoom,zoom)
		end
		r:destroy()
	end)
	t.test('stable structure zoom refreshes only capped adornments with full-draw geometry through LOD changes',function()
		local e,s,r=setup(0)
		for id=1,80 do s.units[id]={id=id,type=({'City','Factory','Port'})[id%3+1],owner=1,active=true,tile=150+id,level=2,hasTrainStation=true,markedForDeletion=true} end
		s.UnitsChanged:Fire({},{});for _=1,120 do e.now+=1/60;r:step(1e9,1e9) end
		local Structure=H.require(root.StructureMath)
		for _,zoom in {2,2.4,5,1,3} do
			local c=table.clone(r.camera);c.scale=zoom;r:setCamera(c)
			for _=1,8 do
				local previous=r.scene.adornmentRefreshes or 0;e.now+=1/60;r:step(1e9,1e9)
				t.ok((r.scene.adornmentRefreshes or 0)-previous<=e.policy.adornmentUpdatesPerFrame)
			end
			local draws=r.scene.unitDraws or 0
			-- On a second, same-LOD zoom the inherited symbol keeps its atlas and
			-- record; the sweep updates text only, with no full unit draws.
			c=table.clone(r.camera);c.scale=zoom*1.01;r:setCamera(c)
			for _=1,8 do e.now+=1/60;r:step(1e9,1e9) end
			t.eq(r.scene.unitDraws,draws)
			local factor=Structure.presentationSize('City',c.scale)/64
			for id,v in r.scene.unitViews do
				local u=s.units[id];local size=v.size
				t.near(size,Structure.presentationSize(u.type,c.scale)/factor,1e-4)
				t.eq(v.root.Size,rb.UDim2.fromOffset(size,size));t.eq(v.lod,c.scale<=1.2)
				t.eq(v.level.Visible,c.scale>1.2)
				local function textGeometry(obj,expected,w,h)
					local scale=1;for _,o in e.objects do if o.Parent==obj and o.ClassName=='UIScale' then scale=o.Scale end end
					t.near(obj.TextSize*scale,expected,1e-4)
					if w then t.eq(obj.Size,rb.UDim2.fromOffset(w/scale,h/scale)) end
				end
				if v.level.Visible then textGeometry(v.level,math.max(10/factor,size*.35),size*.5,size*.4) end
				textGeometry(v.station,math.max(8/factor,size*.2),size*.35,size*.35)
				textGeometry(v.deletion,math.max(10/factor,size*.7));t.eq(v.deletion.Size,rb.UDim2.fromScale(1,1))
			end
		end
		r:destroy()
	end)
	t.test('full first paint prepares the existing FX atlas under the loading cover',function()
		local _,_,r=setup(1)
		t.ok(r.scene.effects.atlas~=nil,'the first combat effect must not synchronously decode/upload its atlas during play')
		r:destroy()
	end)
	t.test('confirmed warship sinking reuses owner-tinted smooth hull, retained heading and source lifetime, then resets its pooled view',function()
		local e,s,r=setup(1); local unit=s.units[1]
		local effects=r.scene.effects
		-- Warm the existing FX atlas and pool independently of the ship atlas.
		effects.state:deadUnit({type='Shell',tile=unit.tile,reachedTarget=true},e.now*1000)
		r:step(1e9,1e9); effects.state:clear(); effects:step(e.now*1000)
		local imageCount=#e.images
		unit.lastTile=unit.tile; s.tick+=1; s.UnitsMoved:Fire({1}); s.TickApplied:Fire(s.tick); r:step(1e9,1e9)
		t.eq(r.scene.unitViews[1].heading,90,'stopped ship retains its last confirmed heading')
		-- Integer controlled milliseconds keep the exact 1260ms expiry boundary
		-- independent of floating-point cancellation in the accumulated frame dt.
		e.now=math.ceil(e.now)
		unit.active=false; s.UnitsChanged:Fire({unit},{})
		local effect=effects.state.sprites[2]; local start=effect.start
		t.eq(effect.kind,5); t.eq(effect.lifetime,1260); t.eq(effect.shipOwner,1); t.eq(effect.shipHeading,90)
		t.eq(effects.state.sprites[1].kind,3,'source explosion remains')
		t.eq(effects.state.sprites[3].kind,7,'existing atlas supplies capped smoke')
		effects:step(start)
		local view=effects.sprites[2]; local c=r.core.palette[1].fill
		t.eq(view.ImageContent,r.scene.shipArt.content); t.eq(view.ImageRectOffset,rb.Vector2.new(1,Art.cell+1))
		t.eq(view.ImageRectSize,rb.Vector2.new(256,256)); t.eq(view.ImageColor3,rb.Color3.new(c.r,c.g,c.b))
		t.eq(view.Rotation,90); t.eq(view.ImageTransparency,0)
		effects:step(start+630)
		-- The explosion has expired; pooled slot 2 now carries the same hull.
		t.eq(effects.sprites[2],view)
		t.near(view.Rotation,101,1e-6); t.near(view.ImageTransparency,.5,1e-6)
		t.near(view.Size.X.Offset,13*64*.825,1); t.near(view.Size.Y.Offset,13*64*.675,1)
		s.UnitsChanged:Fire({unit},{}); t.eq(#effects.state.sprites,2,'duplicate inactive update does not replay')
		effects.state:deadUnit({type='Shell',tile=unit.tile,reachedTarget=true},start+1200)
		effects:step(start+1260)
		t.eq(#effects.state.sprites,1)
		-- Reuse the exact hull pool slot for an ordinary atlas effect too.
		effects.state:deadUnit({type='Shell',tile=unit.tile,reachedTarget=true},start+1260)
		effects:step(start+1260); t.eq(effects.sprites[2],view)
		t.eq(view.ImageContent,effects.content); t.eq(view.ImageColor3,rb.Color3.new(1,1,1)); t.eq(view.Rotation,0)
		t.eq(view.ResampleMode,rb.Enum.ResamplerMode.Pixelated); t.eq(#e.images,imageCount,'no new atlas or upload for sinking')
		effects:step(start+2000); t.eq(view.Visible,false)
		r:destroy(); for _,image in e.images do t.ok(image.destroyed) end
	end)
	t.test('transports and trade ships retain the source no-destruction-sprite path',function()
		local fx=Fx.new(64)
		for id,kind in {'Transport','Trade Ship'} do fx:unitUpdates({{id=id,type=kind,tile=10,active=false}},{},0) end
		t.eq(#fx.sprites,0); t.eq(#fx.shockwaves,0)
	end)
	t.test('retiring sinking views keeps at most the existing 32-spare pool references',function()
		local _,_,r=setup(1); local effects=r.scene.effects; effects.state.options.spriteCap=0
		for id=1,80 do effects.state:deadUnit({type='Warship',tile=130,owner=1},1000,90) end
		for _=1,4 do effects:step(1300) end
		t.eq(#effects.sprites,80)
		effects:step(2300); t.eq(#effects.sprites,32)
		local n=0; for _ in effects.sinkingViews do n+=1 end; t.ok(n<=32)
		r:destroy(); t.eq(next(effects.sinkingViews),nil)
	end)
	t.test('damaging 200 existing warships amortizes new health and veterancy views and reaches the same final display',function()
		local e,s,r=setup(200); local updates={}
		for _,u in s.units do u.health=50; u.warship.veterancy=2; table.insert(updates,u) end
		s.UnitsChanged:Fire(updates,{}); s.tick+=1; s.TickApplied:Fire(s.tick); r:step(1e9,1e9)
		local bars=0; for _,v in r.scene.unitViews do if v.health then bars+=1 end end
		t.ok(bars>0 and bars<=25,'new adornments share the 25-view allowance, rather than creating 200 bars at once')
		t.eq(r.scene.unitsPending,true)
		for _=1,15 do e.now+=1/60; r:step(1e9,1e9) end
		for _,v in r.scene.unitViews do
			t.ok(v.health.background.Visible); t.ok(v.pips.Visible); t.eq(v.adornmentPending,false)
		end
		t.eq(r.scene.unitsPending,false)
		e.writes={}; s.tick+=1; s.TickApplied:Fire(s.tick); r:step(1e9,1e9)
		t.eq(e.writes.Rotation or 0,0,'stationary heading causes no Rotation writes')
		t.eq(e.writes.ResampleMode or 0,0); t.eq(e.writes.ImageContent or 0,0)
		r:destroy()
	end)
	t.test('fallout initial and changed-pixel work stays clipped and budgeted when changes arrive mid-build',function()
		local masks=Masks.new(64,64,16,2,15000); local states=buffer.create(64*64*2)
		for tile=0,4095 do buffer.writeu16(states,tile*2,8192) end
		local m=masks:add(64*32+32,10,0)
		for _=1,45 do t.eq(masks:step(states,1),1) end
		-- Clear a processed pixel and a not-yet-processed pixel. Both must end
		-- transparent; neither may be dropped by the implicit initial traversal.
		local tiles={64*26+26,64*34+34}
		for _,tile in tiles do buffer.writeu16(states,tile*2,0) end
		masks:tilesChanged(tiles)
		for _=1,1000 do local n=masks:step(states,3); t.ok(n<=3); if m.remaining==0 then break end end
		t.eq(m.remaining,0)
		for _,tile in tiles do
			local index=math.floor((math.floor(tile/64)-m.y)/m.step)*16+math.floor((tile%64-m.x)/m.step)
			t.eq(buffer.readu32(m.pixels,index*4),0)
		end
	end)
end
