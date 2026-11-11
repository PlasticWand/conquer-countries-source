--!strict
-- Native-property/lifecycle shim; excludes GUI layout, native images and GPU.
local fs,luau,roblox = require('@lune/fs'),require('@lune/luau'),require('@lune/roblox')
return function(): any
	local Harness = luau.load(fs.readFile('tests/harness.luau'))()
	local root = Harness.mount('src/client/Map/OpenFront','OpenFront')
	local env: any = {objects={},images={},slots={},failFx=false}
	local function signal(): any
		local slots = {}; table.insert(env.slots,slots)
		return {Connect=function(_,fn)
			local slot={fn=fn,live=true}; table.insert(slots,slot)
			return {Disconnect=function() slot.live=false end}
		end,Fire=function(_,...)
			for _, slot in table.clone(slots) do if slot.live then slot.fn(...) end end
		end}
	end
	local function instance(class: string): any
		local o: any = {ClassName=class,Visible=true,AbsoluteSize=roblox.Vector2.new(844,390),AbsolutePosition=roblox.Vector2.zero,
			Destroying=signal(),signals={},destroyed=false}
		o.GetPropertyChangedSignal=function(_,key) o.signals[key]=o.signals[key] or signal(); return o.signals[key] end
		o.FindFirstChild=function(_,key)
			for _, child in env.objects do if child.Parent==o and child.Name==key and not child.destroyed then return child end end
			return nil
		end
		o.IsA=function(_,class)
			return class==o.ClassName or (class=='GuiObject' and (o.ClassName=='Frame' or o.ClassName=='TextLabel' or o.ClassName=='ImageLabel'))
		end
		o.GetDescendants=function()
			local out={}
			for _,child in env.objects do if not child.destroyed then
				local parent=child.Parent
				while parent do if parent==o then table.insert(out,child); break end; parent=parent.Parent end
			end end
			return out
		end
		o.Destroy=function()
			if o.destroyed then return end
			o.destroyed=true; o.Destroying:Fire()
			for _, child in env.objects do if child.Parent==o then child:Destroy() end end
		end
		table.insert(env.objects,o); return o
	end
	env.render=signal()
	env.uis={InputBegan=signal(),InputChanged=signal(),InputEnded=signal(),WindowFocusReleased=signal(),
		TextBoxFocused=signal(),GamepadDisconnected=signal(),GetFocusedTextBox=function() return nil end,
		IsKeyDown=function() return env.shift==true end}
	env.mapGui=instance('ScreenGui')
	env.playerGui={GetGuiObjectsAtPosition=function()
		return if env.blocked then {{Visible=true, BackgroundTransparency=0, IsDescendantOf=function() return false end}} else {}
	end}
	env.mouseTap=function(x:number,y:number)
		local input={UserInputType=roblox.Enum.UserInputType.MouseButton1,Position={X=x,Y=y,Z=0}}
		env.uis.InputBegan:Fire(input,false); env.uis.InputEnded:Fire(input,false)
	end
	local native = {typeof=function(value)
		if type(value)=='table' and value.ClassName then return 'Instance' end
		return typeof(value)
	end,Instance={new=instance},Vector2=roblox.Vector2,UDim=roblox.UDim,UDim2=roblox.UDim2,
		Color3=roblox.Color3,ColorSequence=roblox.ColorSequence,ColorSequenceKeypoint=roblox.ColorSequenceKeypoint,
		Enum=roblox.Enum,Content={fromObject=function(o) return o end},
		game={GetService=function(_,name)
			if name=='ReplicatedStorage' then return {Shared=Harness.shared()} end
			if name=='TextService' then return {GetTextSize=function(_,text,size,_font,_bounds)
				env.textMeasurements=(env.textMeasurements or 0)+1
				return roblox.Vector2.new((env.textWidths and env.textWidths[text] or #text*.5)*size,size)
			end} end
			if name=='EncodingService' then return luau.load(fs.readFile('tests/OpenFrontEncodingHarness.luau'))() end
			if name=='RunService' then return {RenderStepped=env.render} end
			if name=='UserInputService' then return env.uis end
			assert(name=='AssetService')
			return {CreateEditableImage=function(_,options)
				if env.failShips and options.Size.X==516 and options.Size.Y==516 then return nil end
				if env.failMobiles and options.Size.X==480 then return nil end
				if env.failStructures and options.Size.X==990 then return nil end
				if env.failFx and options.Size.Y==306 then return nil end
				if env.failStatus and options.Size.Y==448 then return nil end
				if env.failFallout and options.Size.X==256 and options.Size.Y==256 then return nil end
				local image: any = {Size=options.Size,destroyed=false}
				image.WritePixelsBuffer=function(_,_,size,pixels)
					assert(buffer.len(pixels)==size.X*size.Y*4)
					if env.recordUploads then env.uploads=env.uploads or {}; table.insert(env.uploads,image) end
				end
				image.Destroy=function() image.destroyed=true end
				table.insert(env.images,image); return image
			end}
		end}}
	-- Controlled scheduler for remote-preview lifecycle tests. Queued queries
	-- stay in flight until explicitly completed, including after pointer moves.
	env.now, env.pending = 0, {}
	local fireRender=env.render.Fire
	env.render.Fire=function(self,dt) env.now+=dt or 0; fireRender(self,dt or 0) end
	local previewTask = {spawn=function(fn)
		local job = {fn=fn, cancelled=false}; table.insert(env.pending,job); return job
	end, cancel=function(job) job.cancelled=true end}
	env.completeQuery=function()
		local job=table.remove(env.pending,1)
		assert(job, 'no preview request in flight')
		if not job.cancelled then job.fn() end
	end
	local loaded={}
	local function load(node: any): any
		if node~=root.EditableRenderer and node~=root.SceneOverlay and node~=root.EffectOverlay and node~=root.MapInput
			and node~=root.BuildPreviewController and node~=root.NameStatusOverlay then return Harness.require(node) end
		if loaded[node] then return loaded[node] end
		local globals=table.clone(native); globals.script,globals.require=node,load
		if node==root.BuildPreviewController then globals.task=previewTask end
		if node==root.BuildPreviewController or node==root.MapInput then globals.os={clock=function() return env.now end} end
		local module=luau.load(fs.readFile(node.path),{debugName=node.Name,environment=globals,injectGlobals=true})()
		loaded[node]=module; return module
	end
	env.Renderer,env.Scene,env.Effects=load(root.EditableRenderer),load(root.SceneOverlay),load(root.EffectOverlay)
	env.Preview=load(root.BuildPreviewController)
	env.policy=load(root.RenderPolicy)
	env.instance=instance
	env.client=function()
		local shared=Harness.shared()
		local state=Harness.require(shared.OpenFront.ClientState).new()
		state.ready,state.width,state.height,state.you=true,64,64,1
		state.tileState=buffer.create(64*64*2)
		state.players={[1]={id='me',smallID=1,name='Me',type='HUMAN',troops=100,spawnTile=0,alive=true},
			[2]={id='other',smallID=2,name='Other',type='HUMAN',troops=100,spawnTile=100,alive=true}}
		state.rosterOrder={1,2}
		return state
	end
	return env
end
