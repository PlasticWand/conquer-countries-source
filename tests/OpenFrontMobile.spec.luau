--!strict
-- Phone coordinate/input regressions in the native-property shim. Native
-- safe-area delivery, GUI layout and real touch feel remain Studio/device checks.
return function(t)
	local fs, luau, rb = require("@lune/fs"), require("@lune/luau"), require("@lune/roblox")
	local make = luau.load(fs.readFile("tests/OpenFrontEffectsHarness.luau"))()
	local function event(kind, x, y)
		return {UserInputType = kind, Position = {X = x, Y = y, Z = 0}}
	end
	local function setup(width, height, left, top)
		local e = make()
		local parent = e.instance("Frame")
		parent.AbsoluteSize, parent.AbsolutePosition = rb.Vector2.new(width, height), rb.Vector2.new(left or 0, top or 0)
		local terrain = buffer.create(200 * 100); buffer.fill(terrain, 0, 128)
		local r = e.Renderer.new(parent, terrain, 200, 100, {autoStep = false})
		local taps, contexts, panels = {}, {}, {}
		e.playerGui.GetGuiObjectsAtPosition = function(_, x, y)
			local hits = {}
			for _, panel in panels do
				if x >= panel.x and x < panel.x + panel.w and y >= panel.y and y < panel.y + panel.h then table.insert(hits, panel) end
			end
			return hits
		end
		r:bindInput(e.playerGui, e.mapGui, function(tile) table.insert(taps, tile) end, nil, nil,
			function(tile, x, y) table.insert(contexts, {tile, x, y}) end)
		local function panel(x, y, w, h)
			table.insert(panels, {x = x, y = y, w = w, h = h, Active = true, Visible = true,
				BackgroundTransparency = 1, IsDescendantOf = function() return false end})
		end
		return e, r, parent, taps, contexts, panel, panels
	end
	t.test("pinch uses source two-times distance gain and accumulates its one-pixel threshold", function()
		local e,r,_,taps=setup(874,402)
		local c=table.clone(r.camera); c.scale=4; r:setCamera(c)
		local a,b=event(rb.Enum.UserInputType.Touch,300,200),event(rb.Enum.UserInputType.Touch,400,200)
		e.uis.InputBegan:Fire(a,false); e.uis.InputBegan:Fire(b,false)
		b.Position.X=400.6; e.uis.InputChanged:Fire(b,false)
		t.near(r.camera.scale,4,1e-6,'subpixel motion must accumulate before zooming')
		b.Position.X=401.2; e.uis.InputChanged:Fire(b,false)
		t.near(r.camera.scale,4/(1-1.2*2/600),1e-5)
		b.Position.X=431.2; e.uis.InputChanged:Fire(b,false)
		t.near(r.camera.scale,4/(1-1.2*2/600)/(1-30*2/600),1e-5)
		e.uis.InputEnded:Fire(b,false); e.uis.InputEnded:Fire(a,false)
		t.eq(#taps,0,'pinch release must never order troops'); r:destroy()
	end)
	t.test("viewport size or offset changes cancel tap, drag, pinch, context hold and box selection", function()
		for _, change in {"AbsoluteSize", "AbsolutePosition"} do
			for _, gesture in {"tap", "drag", "pinch", "hold", "box"} do
				local e, r, parent, taps, contexts = setup(874, 402)
				e.shift = gesture == "box"
				local kind = if gesture == "box" then rb.Enum.UserInputType.MouseButton1 else rb.Enum.UserInputType.Touch
				local a, b = event(kind, 230, 130), event(rb.Enum.UserInputType.Touch, 350, 130)
				e.uis.InputBegan:Fire(a, false)
				if gesture == "drag" then a.Position.X = 250; e.uis.InputChanged:Fire(a, false) end
				if gesture == "pinch" then e.uis.InputBegan:Fire(b, false) end
				if gesture == "hold" then e.render:Fire(.799) end
				if change == "AbsoluteSize" then parent.AbsoluteSize = rb.Vector2.new(667, 375)
				else parent.AbsolutePosition = rb.Vector2.new(24, 18) end
				parent:GetPropertyChangedSignal(change):Fire()
				t.eq(r.input.press, nil, gesture .. " held after " .. change)
				t.eq(#r.input.touchOrder, 0); t.eq(r.input.mouseDown, false); t.eq(r.input.boxStart, nil)
				t.eq(r.input:pointerPosition(), nil, "stale preview pointer")
				local oldX, oldY, oldScale = r.camera.offsetX, r.camera.offsetY, r.camera.scale
				a.Position.X += 20; e.uis.InputChanged:Fire(a, false)
				t.eq(r.camera.offsetX, oldX); t.eq(r.camera.offsetY, oldY); t.eq(r.camera.scale, oldScale)
				e.render:Fire(1)
				e.uis.InputEnded:Fire(a); e.uis.InputEnded:Fire(b)
				t.eq(#taps, 0); t.eq(#contexts, 0)
				t.eq(r.scene and r.scene.dragBox, nil)
				-- A fresh deliberate tap still works after layout settles.
				local fresh = event(rb.Enum.UserInputType.Touch, 230, 130)
				e.uis.InputBegan:Fire(fresh, false); e.uis.InputEnded:Fire(fresh)
				t.eq(#taps, 1)
				r:destroy()
			end
		end
	end)
	t.test("transient zero viewport cancels input; duplicate layout signals preserve a valid hold", function()
		local e, r, parent, taps, contexts = setup(667, 375)
		local a = event(rb.Enum.UserInputType.Touch, 230, 130)
		e.uis.InputBegan:Fire(a, false)
		parent:GetPropertyChangedSignal("AbsoluteSize"):Fire()
		e.render:Fire(.8); t.eq(#contexts, 1)
		e.uis.InputEnded:Fire(a); t.eq(#taps, 0)
		e.uis.InputBegan:Fire(a, false)
		parent.AbsoluteSize = rb.Vector2.zero; parent:GetPropertyChangedSignal("AbsoluteSize"):Fire()
		e.uis.InputEnded:Fire(a); e.render:Fire(1)
		t.eq(#taps, 0); t.eq(#contexts, 1)
		r:destroy()
	end)
	t.test("a modal appearing between frames consumes release outside its bounds", function()
		for _, kind in {rb.Enum.UserInputType.Touch, rb.Enum.UserInputType.MouseButton1} do
			local e, r, _, taps, contexts, panel = setup(874, 402)
			local a = event(kind, 230, 130)
			e.uis.InputBegan:Fire(a, false)
			panel(420, 180, 100, 100) -- covers map centre, not the held pointer
			e.uis.InputEnded:Fire(a) -- no RenderStepped between opening and release
			t.eq(#taps, 0); t.eq(#contexts, 0)
			r:destroy()
		end
	end)
	t.test("a release consumed by Roblox UI cannot issue the held map command", function()
		for _, kind in {rb.Enum.UserInputType.Touch, rb.Enum.UserInputType.MouseButton1} do
			local e, r, _, taps, contexts = setup(874, 402)
			local a = event(kind, 230, 130)
			e.uis.InputBegan:Fire(a, false)
			-- CoreGui is outside PlayerGui's hit-test list. UIS still marks its
			-- consumed release even if no render or motion event intervenes.
			e.uis.InputEnded:Fire(a, true)
			t.eq(#taps, 0); t.eq(#contexts, 0)
			r:destroy()
		end
	end)
	t.test("UI second touch and tracked fingers crossing an Active sheet cancel immediately", function()
		for _, mode in {"second", "drag", "pinch"} do
			local e, r, _, taps, contexts, panel = setup(874, 402)
			panel(500, 0, 374, 402)
			local a, b = event(rb.Enum.UserInputType.Touch, 230, 130), event(rb.Enum.UserInputType.Touch, 350, 130)
			e.uis.InputBegan:Fire(a, false)
			if mode == "pinch" then e.uis.InputBegan:Fire(b, false) end
			local oldX, oldY, oldScale = r.camera.offsetX, r.camera.offsetY, r.camera.scale
			if mode == "second" then b.Position.X = 550; e.uis.InputBegan:Fire(b, true)
			else a.Position.X = 550; e.uis.InputChanged:Fire(a, false) end
			t.eq(r.camera.offsetX, oldX); t.eq(r.camera.offsetY, oldY); t.eq(r.camera.scale, oldScale)
			t.eq(r.input.press, nil); t.eq(#r.input.touchOrder, 0)
			a.Position.X = 230; e.uis.InputEnded:Fire(a); e.uis.InputEnded:Fire(b); e.render:Fire(1)
			t.eq(#taps, 0); t.eq(#contexts, 0)
			r:destroy()
		end
	end)
	t.test("right side sheets block their pixels while uncovered map still accepts tap and context", function()
		for _, size in {{874, 402}, {667, 375}} do
			local w, h = size[1], size[2]
			local e, r, _, taps, contexts, panel = setup(w, h, 17, 23)
			panel(17 + w * .55, 23, w * .45, h)
			local x, y = r:worldToScreen(60.25, 40.75)
			local a = event(rb.Enum.UserInputType.Touch, x, y)
			local expected = r:screenToTile(a.Position.X, a.Position.Y)
			e.uis.InputBegan:Fire(a, false); e.uis.InputEnded:Fire(a)
			t.eq(taps[1], expected)
			e.uis.InputBegan:Fire(a, false); e.render:Fire(.8); e.uis.InputEnded:Fire(a)
			t.eq(#taps, 1); t.eq(#contexts, 1); t.eq(contexts[1][1], expected)
			local covered = event(rb.Enum.UserInputType.Touch, 17 + w * .8, 23 + h * .4)
			e.uis.InputBegan:Fire(covered, false); e.render:Fire(1); e.uis.InputEnded:Fire(covered)
			t.eq(#taps, 1); t.eq(#contexts, 1)
			r:destroy()
		end
	end)
	t.test("off-viewport coordinates cannot pick clipped map tiles", function()
		local _, r = setup(667, 375, 35, 21)
		local view = table.clone(r.camera); view.scale = 8; view.offsetX, view.offsetY = 0, 0
		r:setCamera(view)
		for _, point in {{34, 130}, {702, 130}, {230, 20}, {230, 396}} do
			t.eq(r:screenToTile(point[1], point[2]), nil)
		end
		t.ok(r:screenToTile(35, 21) ~= nil)
		r:destroy()
	end)
	t.test("pinch preview stays hidden with one finger navigating; processed motion consumes the gesture", function()
		local e, r, _, taps, contexts = setup(874, 402)
		local a, b = event(rb.Enum.UserInputType.Touch, 230, 130), event(rb.Enum.UserInputType.Touch, 350, 130)
		e.uis.InputBegan:Fire(a, false); e.uis.InputBegan:Fire(b, false)
		t.eq(r.input:pointerPosition(), nil)
		e.uis.InputEnded:Fire(b)
		t.eq(r.input:pointerPosition(), nil)
		a.Position.X = 250; e.uis.InputChanged:Fire(a, false)
		t.eq(r.input:pointerPosition(), nil)
		e.uis.InputEnded:Fire(a)
		t.ok(r.input:pointerPosition() ~= nil, "completed gesture retains last touch")
		t.eq(#taps, 0); t.eq(#contexts, 0)
		e.uis.InputBegan:Fire(a, false); e.uis.InputChanged:Fire(a, true); e.uis.InputEnded:Fire(a)
		t.eq(#taps, 0); t.eq(#contexts, 0)
		r:destroy()
	end)
	t.test("touch query and floating ghost share offset viewport projection; resize rejects late reply", function()
		for _, size in {{874, 402}, {667, 375}} do
			local e, r, parent, _, _, panel, panels = setup(size[1], size[2], 35, 21)
			local s = e.client(); s.width, s.height, s.startTick, s.gold = 200, 100, 0, 2000000
			s.tileState = buffer.create(200 * 100 * 2); s.names = {}
			r:attachState(s)
			local queries = {}
			local p = e.Preview.new(r, s, function(tile, unit)
				table.insert(queries, tile)
				return {tile = tile, unit = unit, tick = s.tick, rangeWarning = false,
					buildable = {type = unit, canBuild = tile, canUpgrade = false, cost = 125000, ghostRailPaths = {}, overlappingRailroads = {}}}
			end)
			local x, y = r:worldToScreen(80.25, 40.75)
			local a = event(rb.Enum.UserInputType.Touch, x, y)
			e.uis.InputBegan:Fire(a, false); e.uis.InputEnded:Fire(a)
			p:setChosen("City"); p:step(); e.completeQuery(); p:step()
			t.eq(queries[1], 40 * 200 + 80)
			t.near(r.scene.buildPreview.tileX, 79.75, 1e-5)
			t.near(r.scene.buildPreview.tileY, 40.25, 1e-5)
			panel(x - 5, y - 5, 10, 10); p:step(); t.eq(r.scene.buildPreview, nil)
			table.clear(panels)
			e.now += .06; p:step(); t.eq(#e.pending, 1)
			parent.AbsolutePosition = rb.Vector2.new(50, 30); parent:GetPropertyChangedSignal("AbsolutePosition"):Fire()
			e.completeQuery(); p:step()
			t.eq(p.reply, nil); t.eq(r.scene.buildPreview, nil); t.eq(#e.pending, 0)
			p:destroy(); r:destroy()
		end
	end)
end
