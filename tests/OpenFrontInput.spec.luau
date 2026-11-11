--!strict
-- Meaningful gesture outcomes and lifecycle, with a mock UserInputService.
return function(t)
	local fs, luau, roblox = require("@lune/fs"), require("@lune/luau"), require("@lune/roblox")
	local Harness = luau.load(fs.readFile("tests/harness.luau"))()
	local root = Harness.mount("src/client/Map/OpenFront", "OpenFront")
	local function signal(): any
		local slots = {}
		return {Connect = function(_, fn)
			local item = {fn = fn, live = true}; table.insert(slots, item)
			return {Disconnect = function() item.live = false end}
		end, Fire = function(_, ...)
			for _, item in slots do if item.live then item.fn(...) end end
		end}
	end
	local focused,shift=false,false
	local service = {InputBegan = signal(), InputChanged = signal(), InputEnded = signal(),
		WindowFocusReleased=signal(),TextBoxFocused=signal(),GamepadDisconnected=signal(),
		GetFocusedTextBox=function() return if focused then {} else nil end,
		IsKeyDown=function(_,key) return shift and key==roblox.Enum.KeyCode.LeftShift end}
	local render = signal()
	local now = 0
	local fire = render.Fire
	render.Fire = function(self,dt) now += dt; fire(self,dt) end
	local Input = luau.load(fs.readFile("src/client/Map/OpenFront/MapInput.luau"), {
		debugName = "MapInput", environment = {script = root.MapInput,
			game = {GetService = function(_, name)
				if name == "UserInputService" then return service elseif name == "RunService" then return {RenderStepped = render} end
				error(name)
			end},
			Vector2 = roblox.Vector2, Enum = roblox.Enum, os = {clock=function() return now end}}, injectGlobals = true})()
	local blocks = false
	local mapGui = {}
	local playerGui = {GetGuiObjectsAtPosition = function()
		if not blocks then return {} end
		return {{Visible = true, BackgroundTransparency = 0, IsDescendantOf = function() return false end}}
	end}
	local taps, pans, zooms, hover,boxes,boxComplete,allSelected = {}, 0, 0, 0,0,0,0
	local contexts = {}
	local renderer = {camera = {left = 0, top = 0, viewportWidth = 844, viewportHeight = 390},
		screenToTile = function(_, x, _y) return if x >= 0 then math.floor(x) else nil end,
		pan = function() pans += 1 end, zoom = function() zooms += 1 end,
		hoverAt = function() hover += 1 end, setHover = function() hover += 1 end,
		selectionBox=function() boxes+=1 end,completeSelectionBox=function() boxComplete+=1 end,
		selectAllWarships=function() allSelected+=1 end,clearSelection=function() end}
	local s = Input.new(renderer, playerGui, mapGui, function(tile) table.insert(taps, tile) end,
		function(tile,x,y) table.insert(contexts,{tile,x,y}) end)
	local function event(kind, key, x, y, z)
		return {UserInputType = kind, KeyCode = key, Position = {X = x, Y = y, Z = z or 0}}
	end
	t.test("tap reaches confirmed tile; HUD hit and processed input stay out", function()
		local mouse = event(roblox.Enum.UserInputType.MouseButton1, nil, 32, 41)
		service.InputBegan:Fire(mouse, false); service.InputEnded:Fire(mouse)
		t.eq(#taps, 1); t.eq(taps[1], 32)
		blocks = true
		service.InputBegan:Fire(mouse, false); service.InputEnded:Fire(mouse)
		blocks = false
		service.InputBegan:Fire(mouse, true); service.InputEnded:Fire(mouse)
		t.eq(#taps, 1)
	end)
	t.test("drag out and back never fires a tile action; wheel/gamepad still work", function()
		local down = event(roblox.Enum.UserInputType.MouseButton1, nil, 30, 40)
		service.InputBegan:Fire(down, false)
		service.InputChanged:Fire(event(roblox.Enum.UserInputType.MouseMovement, nil, 70, 40), false)
		service.InputChanged:Fire(event(roblox.Enum.UserInputType.MouseMovement, nil, 30, 40), false)
		service.InputEnded:Fire(down)
		t.eq(#taps, 1); t.ok(pans >= 1)
		service.InputChanged:Fire(event(roblox.Enum.UserInputType.MouseWheel, nil, 30, 40, 1), false)
		t.eq(zooms, 1)
		service.InputBegan:Fire(event(roblox.Enum.UserInputType.Gamepad1, roblox.Enum.KeyCode.ButtonA, 0, 0), false)
		t.eq(taps[2], 422)
		service.InputChanged:Fire(event(roblox.Enum.UserInputType.MouseMovement, nil, 50, 60), false)
		t.eq(hover, 1)
		service.InputChanged:Fire(event(roblox.Enum.UserInputType.Gamepad1, roblox.Enum.KeyCode.Thumbstick1, .8, 0), false)
		local beforePan = pans
		render:Fire(1 / 60)
		t.ok(pans > beforePan)
		service.InputBegan:Fire(event(roblox.Enum.UserInputType.Gamepad1, roblox.Enum.KeyCode.ButtonR2, 0, 0), false)
		render:Fire(1 / 60)
		t.ok(zooms >= 2)
		service.InputEnded:Fire(event(roblox.Enum.UserInputType.Gamepad1, roblox.Enum.KeyCode.ButtonR2, 0, 0))
	end)
	t.test('focus, text entry, gamepad disconnection and modal cancel held controls and pending taps',function()
		for _, cancel in {service.WindowFocusReleased,service.TextBoxFocused,service.GamepadDisconnected} do
			local down=event(roblox.Enum.UserInputType.MouseButton1,nil,30,40)
			service.InputBegan:Fire(down,false)
			service.InputChanged:Fire(event(roblox.Enum.UserInputType.Gamepad1,roblox.Enum.KeyCode.Thumbstick1,.8,0),false)
			service.InputBegan:Fire(event(roblox.Enum.UserInputType.Gamepad1,roblox.Enum.KeyCode.ButtonR2,0,0),false)
			cancel:Fire()
			local p,z,n=pans,zooms,#taps
			render:Fire(1/60); service.InputEnded:Fire(down)
			t.eq(pans,p); t.eq(zooms,z); t.eq(#taps,n)
		end
		blocks=true
		local n=#taps
		service.InputBegan:Fire(event(roblox.Enum.UserInputType.Gamepad1,roblox.Enum.KeyCode.ButtonA,0,0),false)
		render:Fire(1/60); t.eq(#taps,n); blocks=false
		focused=true
		service.InputBegan:Fire(event(roblox.Enum.UserInputType.Gamepad1,roblox.Enum.KeyCode.ButtonA,0,0),false)
		t.eq(#taps,n); focused=false
	end)
	t.test('shift drag selects a box without a map order or camera pan; focus cancels the rectangle',function()
		shift=true
		local down=event(roblox.Enum.UserInputType.MouseButton1,nil,30,40)
		local beforePan,beforeTap=pans,#taps
		service.InputBegan:Fire(down,false)
		service.InputChanged:Fire(event(roblox.Enum.UserInputType.MouseMovement,nil,100,100),false)
		service.InputEnded:Fire(event(roblox.Enum.UserInputType.MouseButton1,nil,100,100))
		t.eq(pans,beforePan); t.eq(#taps,beforeTap); t.eq(boxComplete,1); t.ok(boxes>=2)
		service.InputBegan:Fire(down,false); service.WindowFocusReleased:Fire(); service.InputEnded:Fire(down)
		t.eq(boxComplete,1); t.eq(#taps,beforeTap); shift=false
		service.InputBegan:Fire(event(roblox.Enum.UserInputType.Gamepad1,roblox.Enum.KeyCode.ButtonY,0,0),false)
		t.eq(allSelected,1)
	end)
	t.test('right click forwards tile zero and exact screen coordinates, never a tap',function()
		local n=#taps
		local right=event(roblox.Enum.UserInputType.MouseButton2,nil,0,41)
		service.InputBegan:Fire(right,false); service.InputEnded:Fire(right)
		t.eq(#contexts,1); t.eq(contexts[1][1],0); t.eq(contexts[1][2],0); t.eq(contexts[1][3],41); t.eq(#taps,n)
		blocks=true; service.InputBegan:Fire(right,false); blocks=false
		service.InputBegan:Fire(right,true); t.eq(#contexts,1)
		service.InputBegan:Fire(event(roblox.Enum.UserInputType.MouseButton2,nil,-1,41),false); t.eq(#contexts,1)
	end)
	t.test('touch long press activates at 800ms once and consumes release and later motion',function()
		local touch=event(roblox.Enum.UserInputType.Touch,nil,24,40)
		local n,p=#taps,pans
		service.InputBegan:Fire(touch,false)
		render:Fire(.799); t.eq(#contexts,1)
		render:Fire(.001); t.eq(#contexts,2); t.eq(contexts[2][1],24)
		touch.Position.X=80; service.InputChanged:Fire(touch,false); render:Fire(1)
		service.InputEnded:Fire(touch); t.eq(pans,p); t.eq(#taps,n); t.eq(#contexts,2)
	end)
	t.test('drag, pinch, focus, release and modal cancel pending context timers',function()
		local before=#contexts
		local touch=event(roblox.Enum.UserInputType.Touch,nil,24,40)
		service.InputBegan:Fire(touch,false); touch.Position.X=40; service.InputChanged:Fire(touch,false)
		render:Fire(1); service.InputEnded:Fire(touch)
		for _, cancel in {service.WindowFocusReleased,service.TextBoxFocused,service.GamepadDisconnected} do
			service.InputBegan:Fire(touch,false); cancel:Fire(); render:Fire(1); service.InputEnded:Fire(touch)
		end
		service.InputBegan:Fire(touch,false); blocks=true; render:Fire(1); blocks=false; service.InputEnded:Fire(touch)
		local other=event(roblox.Enum.UserInputType.Touch,nil,80,40)
		service.InputBegan:Fire(touch,false); service.InputBegan:Fire(other,false); render:Fire(1)
		service.InputEnded:Fire(other); service.InputEnded:Fire(touch); render:Fire(1)
		t.eq(#contexts,before)
	end)
	t.test('long press uses time since pointer down, excluding a stalled frame before the press',function()
		local touch=event(roblox.Enum.UserInputType.Touch,nil,24,40)
		local count=#contexts
		service.InputBegan:Fire(touch,false)
		fire(render,5) -- preceding frame dt must not count as five seconds held
		t.eq(#contexts,count)
		render:Fire(.801); t.eq(#contexts,count+1); service.InputEnded:Fire(touch)
	end)
	t.test("two-finger pinch cancels tap and destroy disconnects all listeners", function()
		local first = event(roblox.Enum.UserInputType.Touch, nil, 50, 50)
		local second = event(roblox.Enum.UserInputType.Touch, nil, 80, 50)
		service.InputBegan:Fire(first, false); service.InputBegan:Fire(second, false)
		second.Position.X = 100
		service.InputChanged:Fire(second, false)
		service.InputEnded:Fire(second)
		local beforePan = pans
		first.Position.X = 65
		service.InputChanged:Fire(first, false)
		t.ok(pans > beforePan)
		service.InputEnded:Fire(first)
		t.eq(#taps, 2); t.ok(zooms >= 2)
		service.InputBegan:Fire(first,false) -- teardown with a pending 800ms hold
		s:destroy()
		service.InputBegan:Fire(first, false); service.InputEnded:Fire(first)
		t.eq(#taps, 2)
		local count=#contexts; render:Fire(2); t.eq(#contexts,count)
	end)
end
