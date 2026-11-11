--!strict
-- Executes the actual OpenFrontClient.start wiring with confirmed ClientState
-- and the native-property renderer shim; UI surfaces/remotes are test doubles.
return function(t)
	local fs,luau,roblox=require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
	local native=luau.load(fs.readFile('tests/OpenFrontEffectsHarness.luau'))()
	local H=luau.load(fs.readFile('tests/harness.luau'))()
	local feelCues=H.require(H.shared().OpenFront.FeelCues)
	local function signal():any
		local callbacks={}
		return {Connect=function(_,fn) table.insert(callbacks,fn) end,Fire=function(_,...)
			for _,fn in table.clone(callbacks) do fn(...) end
		end}
	end
	local function setup(compact: boolean?, split: boolean?): any
		local e=native(); local state=e.client(); state.startTick=0
		e.policy.splitMapGuis=split==true
		state.names={[2]={x=12,y=20,size=10}}
		local c: any = {e=e, state=state}
		local intents,contexts,queries={},{},{}
		local remotes={}
		for _,name in {'IntentResult','Snapshot','Tick','Status'} do remotes[name]={OnClientEvent=signal()} end
		remotes.Intent={FireServer=function(_,intent) table.insert(intents,intent) end}
		remotes.Start={FireServer=function() end}
		remotes.Tutorial={FireServer=function() end} -- (Claude, 2026-11-10: the tutorial's reports)
		remotes.Query={InvokeServer=function(_,request)
			table.insert(queries,request)
			local reply = {tile=request.tile,unit=request.unit,tick=state.tick,rangeWarning=false,
				buildable={type=request.unit,canBuild=false,canUpgrade=false,cost=125000,ghostRailPaths={},overlappingRailroads={}},
				nukeAim=if request.unit=='Atom Bomb' then {siloTile=0,sams={}} else nil}
			if c.holdQuery then
				c.queryThread, c.queryReply = coroutine.running(), reply
				return coroutine.yield()
			end
			return reply
		end}
		remotes.WaitForChild=function(_,name) return assert(remotes[name],name) end
		local stateModule,loaderModule,rendererModule,previewModule,hudModule,actionsModule={},{},{},{},{},{}
		-- 2026-10-24 screens (Claude): the root, menu, loading cover and map catalog.
		local rootModule,menuModule,loadingModule,catalogModule={},{},{},{}
		local tutorialModule={} -- (Claude, 2026-11-10: Ui/OpenFront/TutorialController)
		local audioModule,audioCuesModule,dossierModule,feelModule={},{},{},{}
		local of={ClientState=stateModule,MapLoader=loaderModule,AudioCues=audioCuesModule,FeelCues=feelModule}
		local skinsModule,productsModule={},{}
		local shared={WaitForChild=function() return of end,MapCatalog=catalogModule,Store={Skins=skinsModule,Products=productsModule}}
		local mapFolder={WaitForChild=function(self) return self end}
		local replicated={WaitForChild=function(_,name)
			if name=='Shared' then return shared elseif name=='OpenFrontRemotes' then return remotes else return mapFolder end
		end}
		local scriptTree={Parent={Map={OpenFront={EditableRenderer=rendererModule,BuildPreviewController=previewModule}},
			Ui={OpenFront={OfHud=hudModule,OfActions=actionsModule,Audio=audioModule,TutorialController=tutorialModule},Root=rootModule,Dossier=dossierModule,MenuController=menuModule,
				Screens={Loading=loadingModule}}}}
		local player={PlayerGui=e.playerGui,WaitForChild=function() return e.playerGui end}
		local renderer,preview,hudCallbacks,ui,hud,root
		local modules={
			[productsModule]={}, -- concurrent Takeover wiring imports the product catalog
			[tutorialModule]={new=function()
				local noop=function() end
				return {orderShare=function() return 1 end,floorHeld=noop,noteOrder=noop,noteBoat=noop,destroy=noop}
			end},
			[feelModule]=feelCues,
			[audioModule]={new=function()
				local noop=function() end
				return {play=noop,playAll=noop,playFor=noop,setLoop=noop,setPopRise=noop,preview=noop,setMusic=noop,setSettings=noop,setAmbience=noop,destroy=noop}
			end},
			[audioCuesModule]={new=function()
				local none=function() return {} end
				return {reset=function() end,units=none,messages=none,events=none,bonus=none,tick=none}
			end,ambience=function() return nil,0 end},
			[dossierModule]={},
			[stateModule]={new=function() return state end},
			[loaderModule]={readTerrain=function() local b=buffer.create(4096); buffer.fill(b,0,128); return b end},
			[rendererModule]={new=function(...)
				renderer=e.Renderer.new(...); return renderer
			end},
			[previewModule]={new=function(...)
				preview=e.Preview.new(...); return preview
			end},
			[hudModule]={new=function(_,_,_,callbacks)
				hudCallbacks=callbacks
				hud={match=e.instance('Frame'),slotsHost=e.instance('Frame'),ratio=.2,inMatch=true,
					shownDeath=true,shownWin=true,refreshes=0,
					showMatch=function(self,on) self.inMatch=on end,
					setRatio=function(self,ratio) self.ratio=ratio end,setMusicOn=function() end,
					_refreshAll=function(self) self.refreshes+=1 end,
					destroy=function(self) self.destroyed=true; self.match:Destroy(); self.slotsHost:Destroy() end}
				return hud
			end},
			[rootModule]={new=function()
				root={menu=e.instance('Frame'),match=e.instance('Frame'),modal=e.instance('Frame'),tip=e.instance('Frame'),
					showMatch=function() end,setUserScale=function() end,compact=compact==true,width=1200,
					Changed={Event=signal()}}
				return root
			end},
			[menuModule]={new=function()
				return {setVisible=function() end,openHowToPlay=function() end,openSettings=function() end,settings={},
					_applySettings=function() end,_shop=function() end}
			end},
			[loadingModule]={new=function()
				return {show=function() end,hide=function() end,setProgress=function() end}
			end},
			[catalogModule]={get=function() return nil end},
			[skinsModule]={mask=function() return nil end},
			[actionsModule]={new=function(_,_,actions)
				ui={chosen=nil,rocketDirectionUp=true,actions=actions,choose=function(self,unit) self.chosen=unit; actions.buildChosen(unit) end,
					onMapTap=function(self,tile)
						if self.chosen then actions.sendIntent({type='build_action',unit=self.chosen,tile=tile,
							rocketDirectionUp=self.rocketDirectionUp}); return true end
						return false
					end,markTap=function() end,openContext=function(_,tile,x,y) table.insert(contexts,{tile,x,y}) end,
					destroy=function(self) self.destroyed=true end}
				return ui
			end},
		}
		local client=luau.load(fs.readFile('src/client/OpenFrontClient.luau'),{debugName='OpenFrontClient',injectGlobals=true,
			environment={script=scriptTree,require=function(module) return assert(modules[module]) end,
				Instance={new=e.instance},UDim2=roblox.UDim2,Color3=roblox.Color3,Enum=roblox.Enum,
				task={spawn=function(fn,...) fn(...) end,delay=function() end},game={GetService=function(_,name)
					if name=='Players' then return {LocalPlayer=player} elseif name=='ReplicatedStorage' then return replicated
					elseif name=='StarterGui' then return {SetCoreGuiEnabled=function() end}
					elseif name=='RunService' then return {IsStudio=function() return false end,Heartbeat=signal()}
					elseif name=='UserInputService' then return e.uis
					elseif name=='GuiService' then return {GetGuiInset=function() return roblox.Vector2.new(0,0) end}
					else return {IsStudio=function() return false end} end
				end}}})()
		-- The renderer paints the whole map before it takes input (firstPaint = "full").
		function c.ready()
			for _=1,600 do
				if renderer:isReady() then return end
				e.render:Fire(1/60)
			end
			error('the renderer never became ready')
		end
		function c.latest() return renderer,preview,hudCallbacks,ui,hud,root end
		function c.rebuild()
			if compact then root.width+=20 else root.compact=true end
			root.Changed.Event:Fire()
		end
		function c.move(x,y)
			local sx,sy=renderer:worldToScreen(x,y)
			e.uis.InputChanged:Fire({UserInputType=roblox.Enum.UserInputType.MouseMovement,Position={X=sx,Y=sy}},false)
		end
		-- Run a preview worker until InvokeServer yields; deliberately deliver
		-- its response even after cancellation to exercise stale-result guards.
		function c.beginQuery()
			c.holdQuery=true
			local job=assert(table.remove(e.pending,1),'no preview worker queued')
			local thread=coroutine.create(job.fn)
			local ok,err=coroutine.resume(thread); assert(ok,err)
			assert(coroutine.status(thread)=='suspended','Query did not yield')
		end
		function c.finishQuery()
			local ok,err=coroutine.resume(c.queryThread,c.queryReply); assert(ok,err)
			c.queryThread,c.queryReply,c.holdQuery=nil,nil,false
		end
		c.remotes,c.intents,c.contexts,c.queries=remotes,intents,contexts,queries
		client.start(); state.Snapshot:Fire(); c.ready()
		return c
	end
	t.test('split ScreenGui wiring is match-owned across snapshots and menu teardown',function()
		local c=setup(false,true);c.ready()
		local r=c.latest();t.eq(r.guiLayers.enabled,true)
		local guis=table.clone(r.guiLayers.guis);t.eq(#guis,6)
		c.state.Snapshot:Fire();c.ready();t.eq(r.destroyed,true)
		for _,gui in guis do t.eq(gui.destroyed,true) end
		local nextR=c.latest();t.eq(nextR.guiLayers.enabled,true)
		guis=table.clone(nextR.guiLayers.guis)
		c.remotes.Status.OnClientEvent:Fire({phase='menu'})
		for _,gui in guis do t.eq(gui.destroyed,true) end
	end)
	t.test('map surface explicitly bypasses device insets, clipping and automatic image extension',function()
		local c=setup()
		local gui
		for _,obj in c.e.objects do if obj.Name=='OpenFrontMap' then gui=obj; break end end
		t.ok(gui)
		t.eq(gui.ScreenInsets,roblox.Enum.ScreenInsets.None)
		t.eq(gui.ClipToDeviceSafeArea,false)
		t.eq(gui.SafeAreaCompatibility,roblox.Enum.SafeAreaCompatibility.None)
		t.eq(gui.ZIndexBehavior,roblox.Enum.ZIndexBehavior.Sibling,'map passes retain rails/units/bars/names order')
		local renderer=c.latest(); renderer:destroy()
	end)
	t.test('idle solo deploy ticks keep the camera fixed until the spawn phase actually ends',function()
		local c=setup();local r=c.latest();c.state.startTick=nil
		local initial=table.clone(r.camera)
		for tick=1,120 do
			c.remotes.Tick.OnClientEvent:Fire({tick=tick,tiles=buffer.create(0),deployDeadline=130})
			c.e.render:Fire(.1)
			t.eq(r.goToTarget,nil,'a deploy tick started a flight')
			t.eq(r.camera.offsetX,initial.offsetX);t.eq(r.camera.offsetY,initial.offsetY);t.eq(r.camera.scale,initial.scale)
		end
		c.remotes.Tick.OnClientEvent:Fire({tick=130,tiles=buffer.create(0),startTick=130})
		t.ok(r.goToTarget,'the normal post-deploy fly-to was lost')
		r:destroy()
	end)
	t.test('context priority, query wiring, both fly-to callbacks and snapshot/menu teardown',function()
		local c=setup()
		local e,state,remotes,intents,contexts,queries=c.e,c.state,c.remotes,c.intents,c.contexts,c.queries
		local renderer,preview,hudCallbacks,ui=c.latest()
		t.eq(preview.rocketDirectionUp,true,'new renderer takes the current UI direction')
		ui.rocketDirectionUp=false; ui.actions.rocketDirectionChanged(false)
		t.eq(preview.rocketDirectionUp,false,'UI flip reaches the existing controller')
		local function right(tile)
			local x,y=renderer:worldToScreen(tile%64+.5,math.floor(tile/64)+.5)
			e.uis.InputBegan:Fire({UserInputType=roblox.Enum.UserInputType.MouseButton2,Position={X=x,Y=y}},false)
			return x,y
		end
		state.startTick=nil; right(0); t.eq(#contexts,0); state.startTick=0
		state.units[8]={id=8,type='Warship',owner=1,tile=10,active=true}; renderer.scene.selection.ids={8}
		ui:choose('City'); right(0); t.eq(ui.chosen,nil); t.eq(renderer:hasSelection(),true); t.eq(#contexts,0)
		right(0); t.eq(renderer:hasSelection(),false); t.eq(#contexts,0)
		local x,y=right(0); t.eq(contexts[1][1],0); t.near(contexts[1][2],x,1e-12); t.near(contexts[1][3],y,1e-12)
		t.eq(#intents,0)
		ui:choose('City'); preview:step(); e.completeQuery(); preview:step()
		t.eq(queries[1].kind,'build_preview'); t.eq(queries[1].tile,0); t.eq(queries[1].unit,'City')
		hudCallbacks.goToPlayer(2); t.eq(renderer.goToTarget.x,12); t.eq(renderer.goToTarget.y,20)
		ui.actions.goToPlayer(2); t.eq(renderer.goToTarget.x,12)
		local oldRenderer,oldPreview=renderer,preview
		state.Snapshot:Fire(); c.ready(); renderer,preview,hudCallbacks,ui=c.latest()
		t.eq(oldRenderer.destroyed,true); t.eq(oldPreview.destroyed,true)
		t.eq(preview.rocketDirectionUp,false,'replacement renderer keeps UI direction')
		ui:choose('City'); local sx,sy=renderer:worldToScreen(3.5,3.5); e.mouseTap(sx,sy)
		t.eq(intents[1].type,'build_action'); t.eq(intents[1].tile,195)
		local currentRenderer,currentPreview=renderer,preview
		remotes.Status.OnClientEvent:Fire({phase='menu'})
		t.eq(currentRenderer.destroyed,true); t.eq(currentPreview.destroyed,true)
		e.render:Fire(1); t.eq(currentRenderer.goToConnection,nil)
	end)
	for _,compact in {false,true} do
		local reason=if compact then 'compact width change' else 'compact flip'
		t.test(reason..' cancels the chosen build and visible ghost synchronously',function()
			local c=setup(compact)
			local r,p,_,ui,hud=c.latest()
			c.move(3.5,3.5); ui:choose('City'); p:step(); c.e.completeQuery(); p:step()
			t.ok(r.scene.buildPreview~=nil,'ghost exists before rebuild')
			hud.ratio=.75
			c.rebuild()
			local newR,newP,_,newUi,newHud=c.latest()
			t.eq(newR,r); t.eq(newP,p,'rebuild retains the renderer and preview controller')
			t.eq(ui.destroyed,true); t.eq(hud.destroyed,true)
			t.eq(newUi.chosen,nil); t.eq(p.chosen,nil,'retained preview choice cancelled')
			t.eq(r.scene.buildPreview,nil,'ghost clears without a render frame'); t.eq(r.scene.preview,nil)
			t.eq(newHud.ratio,.75); t.eq(newHud.inMatch,true)
			t.eq(newHud.shownDeath,true); t.eq(newHud.shownWin,true); t.eq(newHud.refreshes,1)
			c.e.mouseTap(r:worldToScreen(3.5,3.5))
			t.eq(c.intents[1].type,'tile_action','post-rebuild tap uses live action UI')
			t.eq(c.intents[1].ratio,.75)
			c.remotes.Status.OnClientEvent:Fire({phase='menu'})
		end)
		t.test(reason..' resets a flipped rocket arc to the new action UI default',function()
			local c=setup(compact)
			local r,p,_,ui=c.latest()
			c.move(30.5,30.5); ui:choose('Atom Bomb')
			ui.rocketDirectionUp=false; ui.actions.rocketDirectionChanged(false)
			p:step(); c.e.completeQuery(); p:step()
			t.ok(r.scene.preview~=nil,'flipped arc exists before rebuild'); t.eq(p.rocketDirectionUp,false)
			c.rebuild()
			local _,_,_,newUi=c.latest()
			t.eq(newUi.rocketDirectionUp,true); t.eq(p.rocketDirectionUp,true,'retained arc direction reset')
			t.eq(r.scene.preview,nil,'arc clears synchronously')
			-- No scene resize is needed for a Root-only UI scale/width change.
			-- A later choice and Query must use the reset direction and live UI.
			c.move(30.5,30.5); newUi:choose('Atom Bomb'); p:step(); c.e.completeQuery(); p:step()
			t.ok(r.scene.preview~=nil); t.eq(p.rocketDirectionUp,true)
			c.e.mouseTap(r:worldToScreen(30.5,30.5))
			t.eq(c.intents[1].type,'build_action'); t.eq(c.intents[1].rocketDirectionUp,true)
			c.remotes.Status.OnClientEvent:Fire({phase='menu'})
		end)
		t.test(reason..' ignores a Query response for the old choice even after reselecting it',function()
			local c=setup(compact)
			local r,p,_,ui=c.latest()
			c.move(30.5,30.5); ui:choose('Atom Bomb'); p:step(); c.beginQuery()
			t.eq(#c.queries,1); t.eq(c.queries[1].kind,'build_preview'); t.eq(p.inFlight,true)
			c.rebuild()
			local _,_,_,newUi=c.latest()
			c.move(30.5,30.5); newUi:choose('Atom Bomb')
			c.finishQuery()
			t.eq(p.reply,nil,'old Query cannot validate a newly selected identical build')
			t.eq(p.inFlight,false); t.eq(r.scene.buildPreview,nil); t.eq(r.scene.preview,nil)
			p:step(); t.eq(#c.e.pending,1)
			c.e.completeQuery(); p:step(); t.ok(r.scene.preview~=nil,'fresh query remains usable')
			c.remotes.Status.OnClientEvent:Fire({phase='menu'})
		end)
		t.test(reason..' consumes held map gestures and controls without a surface resize',function()
			for _,gesture in {'tap','drag','pinch','hold','box','gamepad'} do
				local c=setup(compact)
				local e=c.e
				local r,p=c.latest()
				local sx,sy=r:worldToScreen(30.5,30.5)
				local function input(kind,x,y,key)
					return {UserInputType=kind,Position={X=x,Y=y,Z=0},KeyCode=key}
				end
				e.shift=gesture=='box'
				local a=input(if e.shift then roblox.Enum.UserInputType.MouseButton1 else roblox.Enum.UserInputType.Touch,sx,sy)
				local b=input(roblox.Enum.UserInputType.Touch,sx+30,sy)
				e.uis.InputBegan:Fire(a,false)
				if gesture=='drag' then a.Position.X+=20; e.uis.InputChanged:Fire(a,false) end
				if gesture=='pinch' then e.uis.InputBegan:Fire(b,false) end
				if gesture=='hold' then e.render:Fire(.799) end
				if gesture=='gamepad' then
					e.uis.InputChanged:Fire(input(roblox.Enum.UserInputType.Gamepad1,1,0,roblox.Enum.KeyCode.Thumbstick1),false)
					e.uis.InputBegan:Fire(input(roblox.Enum.UserInputType.Gamepad1,0,0,roblox.Enum.KeyCode.ButtonR2),false)
				end
				c.rebuild()
				t.eq(r.input.press,nil,gesture..' press cancelled'); t.eq(#r.input.touchOrder,0)
				t.eq(r.input.mouseDown,false); t.eq(r.input.boxStart,nil); t.eq(r.scene.dragBox,nil)
				t.eq(r.input.longPressAt,nil); t.eq(r.input.contextActive,false)
				t.eq(r.input.stick.Magnitude,0); t.eq(r.input.zoomDirection,0)
				t.eq(r.input:pointerPosition(),nil,'retained pointer invalidated')
				local x,y,scale=r.camera.offsetX,r.camera.offsetY,r.camera.scale
				a.Position.X+=20; e.uis.InputChanged:Fire(a,false); e.render:Fire(1)
				e.uis.InputEnded:Fire(a,false); e.uis.InputEnded:Fire(b,false)
				t.eq(r.camera.offsetX,x); t.eq(r.camera.offsetY,y); t.eq(r.camera.scale,scale)
				t.eq(#c.intents,0,gesture..' release consumed'); t.eq(#c.contexts,0); t.eq(p.chosen,nil)
				e.shift=false; e.mouseTap(r:worldToScreen(30.5,30.5)); t.eq(#c.intents,1,'fresh tap still works')
				c.remotes.Status.OnClientEvent:Fire({phase='menu'})
			end
		end)
	end
	for _,teardown in {'snapshot','menu'} do
		t.test(teardown..' teardown after a HUD rebuild rejects an already running Query',function()
			local c=setup(true)
			c.rebuild()
			local r,p,_,ui=c.latest()
			c.move(30.5,30.5); ui:choose('Atom Bomb'); p:step(); c.beginQuery()
			local input=r.input
			if teardown=='snapshot' then c.state.Snapshot:Fire(); c.ready()
			else c.remotes.Status.OnClientEvent:Fire({phase='menu'}) end
			t.eq(r.destroyed,true); t.eq(p.destroyed,true); t.eq(input.destroyed,true)
			c.finishQuery(); c.e.render:Fire(1)
			t.eq(p.reply,nil); t.eq(p.chosen,nil); t.eq(p.ghostData,nil); t.eq(p.dataReply,nil)
			t.eq(#p.connections,0); t.eq(r.scene,nil); t.eq(r.input,nil)
			t.eq(#c.intents,0); t.eq(#c.contexts,0)
			if teardown=='snapshot' then
				local newR,newP=c.latest()
				t.ok(newR~=r); t.ok(newP~=p); t.eq(newP.reply,nil)
				t.eq(newR.scene.buildPreview,nil); t.eq(newR.scene.preview,nil)
				c.remotes.Status.OnClientEvent:Fire({phase='menu'})
			end
		end)
	end
end
