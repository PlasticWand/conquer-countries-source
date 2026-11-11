--!strict
-- Serial desktop-host measurement of real buffers and renderer scheduling.
-- Touch means viewport/CPU policy, not simulated phone hardware or GPU uploads.
local fs,luau,rb,serde=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox'),require('@lune/serde')
local auditRef=require('@lune/process').args[1]
local audit=luau.load(fs.readFile('tests/OpenFrontRecentPerfHarness.luau'))()
local make=if auditRef then function() return audit(if auditRef=='working' then nil else auditRef) end
	else luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
local folder='../reference/openfront-v0.35.2/resources/maps/'
local function summary(a)
	local ordered=table.clone(a); table.sort(ordered); local sum=0
	for _,n in a do sum+=n end
	return {mean=sum/#a,p95=ordered[math.ceil(#a*.95)],max=ordered[#a]}
end
for _,map in {{name='World',file='world/map.bin',w=2000,h=1000},{name='PangaeaCompact',file='pangaea/map4x.bin',w=500,h=500}} do
	local terrain=buffer.fromstring(fs.readFile(folder..map.file))
	assert(buffer.len(terrain)==map.w*map.h)
	local coastTiles={}
	for y=1,map.h-2 do for x=1,map.w-2 do
		local tile=y*map.w+x
		if bit32.btest(buffer.readu8(terrain,tile),128) then
			for _,n in {tile-1,tile+1,tile-map.w,tile+map.w} do
				if not bit32.btest(buffer.readu8(terrain,n),128) then table.insert(coastTiles,tile); break end
			end
		end
	end end
	for _,touch in {true,false} do
		local e=make(); e.uis.TouchEnabled=touch
		for _,variant in {'baseline','cold','cached'} do
			local s=e.client(); s.width,s.height,s.startTick,s.tick=map.w,map.h,0,100
			s.tileState=buffer.create(map.w*map.h*2); s.units,s.names,s.railroads={},{},{}
			for tile=0,map.w*map.h-1 do
				if bit32.btest(buffer.readu8(terrain,tile),128) then buffer.writeu16(s.tileState,tile*2,if tile%map.w<map.w/2 then 1 else 2) end
			end
			local parent=e.instance('Frame'); parent.AbsoluteSize=if touch then rb.Vector2.new(844,390) else rb.Vector2.new(1530,613)
			local start=os.clock()
			local r=e.Renderer.new(parent,terrain,map.w,map.h,{autoStep=false,firstPaint='full',coasts=variant~='baseline'})
			if r.coasts then r.coasts.api.now=function() return e.now end end
			r:setRoster({{id='me',smallID=1,playerType='HUMAN'},{id='other',smallID=2,playerType='HUMAN'}})
			r:applyTileStates(s.tileState)
			r:attachState(s)
			local frames=0; local maxStep=0
			repeat
				e.now+=1/60; local step=os.clock(); r:step(); maxStep=math.max(maxStep,(os.clock()-step)*1000)
				frames+=1; assert(frames<8192,'coast loading did not drain')
			until r:isReady()
			local loadMs=(os.clock()-start)*1000
			print(serde.encode('json',{map=map.name,w=map.w,h=map.h,touch=touch,variant=variant,phase='load',wallMs=loadMs,frames=frames,maxStepMs=maxStep,metrics=r:metrics()}))
			if variant~='cached' then
				local fit=table.clone(r.camera)
				for _,mode in {'idle','pan','coastEdits'} do
					local function step(i)
						e.now+=1/60
						if mode=='pan' then
							local c=table.clone(fit); c.scale=1.5
							local cx,cy=map.w*.50+math.sin(i*.03)*25,map.h*.30+math.cos(i*.02)*15
							c.offsetX=cx-map.w/2-(c.viewportWidth/2-map.w/2)/c.scale
							c.offsetY=cy-map.h/2-(c.viewportHeight/2-map.h/2)/c.scale
							r:setCamera(c)
						elseif mode=='coastEdits' and i%6==0 then
							local refs={}; s.tick+=1
							for k=0,95 do
								local tile=coastTiles[math.floor(k/96*#coastTiles)+1]
								buffer.writeu16(s.tileState,tile*2,1+s.tick%2); table.insert(refs,tile)
							end
							r:applyTileStates(s.tileState,refs); s.TickApplied:Fire(s.tick)
						end
						r:step()
					end
					for i=1,120 do step(i) end
					local times={}; local queuePeak=0; local pixelStart=r.coasts and r.coasts.raster.uploadedPixels or 0
					local composed=r.coasts and r.coasts.raster.composed or 0
					local count=#e.objects
					for i=1,240 do
						e.recordUploads=true; e.uploads={}; local frameStart=os.clock(); step(i)
						table.insert(times,(os.clock()-frameStart)*1000)
						local seen={}; for _,img in e.uploads do seen[img]=true end
						local pages=0; for _ in seen do pages+=1 end; assert(pages<=1,'more than one displayed image updated')
						if r.coasts then queuePeak=math.max(queuePeak,r.coasts.raster.pendingCount) end
					end
					local endQueue=r.coasts and r.coasts.raster.pendingCount or 0
					local settle=0
					while r.core.pending>0 or (r.coasts and not r.coasts:ready()) do
						e.now+=1/60; r:step(); settle+=1; assert(settle<8192,'coast colour backlog did not drain')
					end
					print(serde.encode('json',{map=map.name,touch=touch,variant=variant,phase=mode,frames=240,editsPerTick=if mode=='coastEdits' then 96 else 0,
						frame=summary(times),newInstances=#e.objects-count,queuePeak=queuePeak,endQueue=endQueue,settleFrames=settle,
						coastUploadPixels=r.coasts and r.coasts.raster.uploadedPixels-pixelStart or 0,
						coastComposedCells=r.coasts and r.coasts.raster.composed-composed or 0,metrics=r:metrics()}))
				end
			end
			r:destroy()
		end
		for _,img in e.images do assert(img.destroyed,'native image leak') end
	end
end
