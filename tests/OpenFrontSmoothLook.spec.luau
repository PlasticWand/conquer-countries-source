--!strict
-- Native-property and real-buffer regressions, not GPU/device evidence.
return function(t)
	local fs,luau,rb=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local root=H.mount('src/client/Map/OpenFront','OpenFront')
	local Art,Policy=H.require(root.ShipArt),H.require(root.RenderPolicy)
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local raster=luau.load(fs.readFile('tests/OpenFrontRasterHarness.luau'))()
	local Core=raster.Core
	local function setup()
		local e=native(); local s=e.client(); s.startTick=0; s.names={}
		for id,kind in {'Transport','Trade Ship','Warship'} do
			s.units[id]={id=id,type=kind,owner=1,tile=130+id,lastTile=129+id,active=true,
				health=50,maxHealth=100,warship=if kind=='Warship' then {patrolTile=0,veterancy=2} else nil}
		end
		local r=e.Renderer.new(e.instance('Frame'),buffer.create(4096),64,64,{autoStep=false})
		r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
		r:attachState(s); r:step(1e9,1e9)
		return e,s,r
	end
	local function finish(e,r)
		Art.build(r.scene.shipArt,1e9,1e9)
		e.recordUploads=true
		for _=1,8 do
			e.uploads={}; e.now+=1/60; r:step(1e9,1e9)
			local images={}; for _,img in e.uploads do images[img]=true end
			local count=0; for _ in images do count+=1 end; t.ok(count<=1,'ship atlas shares the displayed image slot')
		end
		assert(r.scene.shipArt.content,'original ship atlas should be displayed')
	end
	t.test('original art has three distinct hulls, antialiased coverage, transparent gutters and a stern wake',function()
		local a=Art.new(); a.needed=true
		Art.build(a,1e9,100); t.eq(a.cursor,100,'producer obeys its pixel cap')
		t.eq(Art.build(a,1e9,1e9),true)
		local partial=0
		for n=0,Art.width*Art.height-1 do
			local alpha=buffer.readu8(a.pixels,n*4+3)
			if alpha>0 and alpha<255 then partial+=1 end
		end
		t.ok(partial>100,'edge coverage must not be binary source pixels')
		for column=0,3 do
			local x,y=column%Art.columns*Art.cell,math.floor(column/Art.columns)*Art.cell
			for i=0,Art.cell-1 do
				t.eq(buffer.readu32(a.pixels,(y*Art.width+x+i)*4),0,'top gutter')
				t.eq(buffer.readu32(a.pixels,((y+i)*Art.width+x)*4),0,'left gutter')
			end
		end
		local signatures={}
		for column=0,2 do
			local signature=0
			for y=0,63 do for x=0,63 do local ink,alpha=Art.sample(column,(x+.5)/64-.5,(y+.5)/64-.5); signature+=ink*alpha end end
			t.ok(not signatures[signature],'each ship type has its own silhouette/deck'); signatures[signature]=true
			local _,wake=Art.sample(column,.10,.43); t.ok(wake>0,'small wake follows the stern')
		end
	end)
	t.test('all ship types use one smooth owner-tinted image, keep footprint and align selection/patrol',function()
		local e,s,r=setup(); finish(e,r)
		for id=1,3 do
			local v=r.scene.unitViews[id]
			t.eq(#v.parts,1); t.ok(v.smoothShip); t.eq(v.iconSlot,nil)
			t.eq(v.parts[1].ImageContent,r.scene.shipArt.content)
			t.eq(v.parts[1].ImageRectOffset,rb.Vector2.new((id-1)%2*258+1,math.floor((id-1)/2)*258+1),'correct type cell')
			t.eq(v.parts[1].ImageRectSize,rb.Vector2.new(256,256)); t.eq(v.parts[1].ResampleMode,rb.Enum.ResamplerMode.Default)
			-- Boats and trade ships at Bruno's 70% (RenderPolicy.transportScale).
			local footprint=if v.record.type=='Warship' then 13*64 else 13*64*.7
			t.near(v.parts[1].Rotation,90,1e-6); t.near(v.root.Size.X.Offset,footprint,1,'whole offset pixels')
			local color=r.core.palette[1].fill
			t.eq(v.parts[1].ImageColor3,rb.Color3.new(color.r,color.g,color.b))
		end
		local ship=r.scene.unitViews[3]; t.ok(ship.health.background.Visible); t.ok(ship.pips.Visible)
		r.scene.selection:tap(s.units[3].tile,64,true,s.units,{1,2,3},1); r:setWarshipPatrolVisible(3); r:step(1e9,1e9)
		local box=r.scene.selectionViews[1]; t.ok(box.Visible)
		t.near(box.Size.X.Offset,13*r.camera.scale,.5,'native pixel rounding')
		local disc=r.scene.rangeViews.WarshipPatrol; local radius=s:config():warshipPatrolRange()
		t.near(disc.Position.X.Offset,(.5-radius)*64,1e-3,'confirmed tile zero, not moving hull')
		local ships=r.scene.shipArt; r:destroy(); t.eq(ships.content,nil); t.eq(ships.pixels,nil)
		for _,img in e.images do t.ok(img.destroyed) end
	end)
	t.test('confirmed movement changes heading in the pose path; stopped ships retain heading without rotating health',function()
		local e,s,r=setup(); finish(e,r)
		local v=r.scene.unitViews[3]; local part=v.parts[1]
		for _,delta in {64,-1,-64,65,-65} do
			local old=s.units[3].tile
			s.units[3].lastTile,s.units[3].tile=old,old+delta
			s.tick+=1; s.UnitsMoved:Fire({3}); s.TickApplied:Fire(s.tick); r:step(1e9,1e9)
			t.near(part.Rotation,Art.heading(old+delta,old,64),1e-5)
			t.eq(v.parts[1],part); t.eq(v.root.Rotation,nil,'root/health/status remain upright in shim')
		end
		local angle=part.Rotation
		s.units[3].lastTile=s.units[3].tile; s.tick+=1; s.UnitsMoved:Fire({3}); s.TickApplied:Fire(s.tick); r:step(1e9,1e9); t.eq(part.Rotation,angle)
		local count=#e.objects; local position=v.root.Position
		r:pan(10,0); r:step(1e9,1e9)
		t.eq(#e.objects,count); t.eq(v.root.Position,position); t.eq(part.Rotation,angle)
		s.units[3].targetUnitId=99; s.UnitsChanged:Fire({},{}); r:step(1e9,1e9)
		t.ok(v.shipGradient.Enabled,'source combat signal retained as a midship band')
		t.eq(v.shipGradient.Color.Keypoints[1].Value,r.core.palette[1] and rb.Color3.new(r.core.palette[1].fill.r,r.core.palette[1].fill.g,r.core.palette[1].fill.b))
		t.eq(v.shipGradient.Color.Keypoints[3].Value,rb.Color3.fromRGB(200,0,0))
		r:destroy()
	end)
	t.test('pinned warship preview reuses smooth art with absolute opacity and invalid red, with no port route',function()
		local e,s,r=setup(); finish(e,r); s.costs.Warship=500000; s.gold=0
		local p=e.Preview.new(r,s,function(tile,kind) return {tile=tile,unit=kind,buildable={type=kind,canBuild=tile,canUpgrade=false,cost=500000}} end)
		p:setChosen('Warship'); p:setPendingTile(0); p:step(); e.completeQuery(); p:step(); r:step(1e9,1e9)
		local ghost=r.scene.warshipGhost
		t.eq(#ghost.parts,1); t.eq(ghost.parts[1].ImageRectSize,rb.Vector2.new(256,256))
		t.eq(ghost.parts[1].ImageColor3,rb.Color3.fromRGB(255,75,69)); t.near(ghost.parts[1].ImageTransparency,.5,1e-6)
		t.eq(#r.scene.ghostRails,0); t.ok(r.scene.rangeViews.BuildRange.Visible)
		for tile=400,420 do p:setPendingTile(tile); p:step(); r:step(1e9,1e9); t.near(ghost.parts[1].ImageTransparency,.5,1e-6) end
		p:setPendingTile(nil); p:step(); r:step(1e9,1e9); t.eq(ghost.root.Visible,false)
		p:destroy(); r:destroy()
	end)
	t.test('optional ship image refusal preserves source fallback, readiness and cleanup; uploads share one slot',function()
		local e,_,r=setup(); e.failShips=true; e.recordUploads=true; Art.build(r.scene.shipArt,1e9,1e9)
		for _=1,10 do
			e.uploads={}; r:step(1e9,1e9)
			local images={}; for _,img in e.uploads do images[img]=true end
			local count=0; for _ in images do count+=1 end; t.ok(count<=1,'one displayed image per frame')
		end
		t.eq(r.scene.shipArt.failed,true); t.eq(r.scene.shipArt.pixels,nil)
		local v=r.scene.unitViews[3]; t.ok(v.iconSlot.ready); t.eq(#v.parts,1); t.eq(v.smoothShip,false)
		r:destroy(); for _,img in e.images do t.ok(img.destroyed) end
	end)
	local roster={{id='a',smallID=1,playerType='HUMAN'},{id='b',smallID=2,playerType='HUMAN'}}
	local function map(w,h,soft)
		local terrain,states=buffer.create(w*h),buffer.create(w*h*2)
		for y=0,h-1 do for x=0,w-1 do
			local tile=y*w+x
			buffer.writeu8(terrain,tile,if x<5+math.floor(y/2) then 65 else 128+(x+y)%20)
			buffer.writeu16(states,tile*2,if x>w/2 then 2 elseif x>5+math.floor(y/2) then 1 else 0)
		end end
		local sink=raster.sink(w,h); local s=Core.new(terrain,w,h,sink.backend)
		Core.setEdgeSmoothing(s,soft); Core.setRoster(s,roster); Core.applyTileStates(s,states); raster.drain(s,1e9)
		return s,sink,terrain,states
	end
	t.test('soft map experiment defaults off, changes edges only and leaves confirmed terrain/ownership intact',function()
		t.eq(Policy.softMapEdges,false)
		local a,sa,terrain,states=map(80,40,false); local b,sb=map(80,40,true)
		local changed=0
		for y=0,39 do for x=0,79 do
			if sa.pixel(x,y)~=sb.pixel(x,y) then changed+=1 end
		end end
		t.ok(changed>0); t.eq(sa.pixel(70,20),sb.pixel(70,20),'land terrain interior stays sharp')
		t.eq(sa.pixel(2,20),sb.pixel(2,20),'water interior unchanged')
		t.eq(buffer.tostring(a.terrain),buffer.tostring(terrain)); t.eq(buffer.tostring(b.terrain),buffer.tostring(terrain))
		t.eq(buffer.tostring(a.tileState),buffer.tostring(states)); t.eq(buffer.tostring(b.tileState),buffer.tostring(states))
		t.eq(#a.pages,#b.pages); local pending=b.pending; Core.setEdgeSmoothing(b,true); t.eq(b.pending,pending)
		Core.setEdgeSmoothing(b,false); raster.drain(b,1e9)
		for y=0,39 do for x=0,79 do t.eq(sa.pixel(x,y),sb.pixel(x,y),'off restores source pixels exactly') end end
		Core.destroy(a); Core.destroy(b)
	end)
	t.test('soft incremental coast, ownership, diplomacy and hover across page/block seams equal a cold repaint',function()
		local a,sa,terrain,states=map(1027,39,true)
		local data=buffer.create(9)
		Core.setRelations(a,{size=3,data=data}); raster.drain(a,1e9)
		local function compare(label)
			local sb=raster.sink(1027,39); local b=Core.new(terrain,1027,39,sb.backend)
			Core.setEdgeSmoothing(b,true); Core.setRoster(b,roster); Core.setRelations(b,{size=3,data=data}); Core.setHover(b,a.hover)
			Core.applyTileStates(b,states); raster.drain(b,1e9)
			for y=0,38 do for x=0,1026 do t.eq(sa.pixel(x,y),sb.pixel(x,y),`{label} soft seam pixel {x},{y}`) end end
			Core.destroy(b)
		end
		local refs={0,31,32,1023,1024,1026,1027,1027*38+1026,1027*20+513}
		for _,tile in refs do buffer.writeu16(states,tile*2,1+16384) end
		Core.applyTileStates(a,states,refs); raster.drain(a,1e9); compare('ownership')
		for _,tile in refs do buffer.writeu8(terrain,tile,65) end
		Core.applyTerrain(a,terrain,refs); raster.drain(a,1e9); compare('coast')
		buffer.writeu8(data,5,2); buffer.writeu8(data,7,2)
		Core.setRelations(a,{size=3,data=data}); raster.drain(a,1e9); compare('diplomacy')
		Core.setHover(a,2); raster.drain(a,1e9); compare('hover')
		Core.destroy(a)
	end)
end
