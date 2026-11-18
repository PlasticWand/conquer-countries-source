--!strict
-- Pure shot math plus real renderer/input wiring under the native-property shim.
-- Does not establish native frame pacing, OBS capture or GPU performance.
return function(t)
	local fs, luau = require("@lune/fs"), require("@lune/luau")
	local root = t.mount("src/client/Map/OpenFront", "OpenFront")
	local Film = t.load(root.FilmCamera)
	local function shot(): any
		return {duration = 4, keyframes = {
			{t = 0, x = 10, y = 20, zoom = 2},
			{t = 4, x = 90, y = 60, zoom = 8},
		}}
	end
	local function setup(studio: boolean?): (any, any, any, any)
		local e = luau.load(fs.readFile("tests/OpenFrontEffectsHarness.luau"))()()
		local r = e.Renderer.new(e.instance("Frame"), buffer.create(4096), 64, 64, {autoStep = false, coasts = false})
		r:attachState(e.client())
		local taps = 0
		r:bindInput(e.playerGui, e.mapGui, function() taps += 1 end)
		local player = e.instance("Player")
		local module = luau.load(fs.readFile("src/client/Map/OpenFront/FilmCameraController.luau"), {
			injectGlobals = true, environment = {
				script = {Parent = {FilmCamera = root.FilmCamera}}, require = function() return Film end,
				game = {GetService = function() return {IsStudio = function() return studio ~= false end} end},
				Instance = {new = e.instance}, os = {clock = function() return e.now end},
				warn = function(message) e.warning = message end,
			},
		})()
		local controller = module.new(r, player, function() e.cancelledPreview = (e.cancelledPreview or 0) + 1 end)
		e.taps = function() return taps end
		return e, r, controller, player
	end

	t.test("linear centres and logarithmic zoom reach exact keyframes", function()
		local s = Film.prepare(shot())
		local a = Film.sample(s, 0)
		t.eq(a.x, 10); t.eq(a.y, 20); t.eq(a.zoom, 2)
		local middle = Film.sample(s, 2)
		t.eq(middle.x, 50); t.eq(middle.y, 40); t.near(middle.zoom, 4, 1e-12)
		local b = Film.sample(s, 4)
		t.eq(b.x, 90); t.eq(b.y, 60); t.eq(b.zoom, 8)
	end)

	t.test("destination easing, irregular segments and final hold", function()
		local s = Film.prepare({duration = 8, keyframes = {
			{t = 0, x = 0, y = 20, zoom = 1},
			{t = 4, x = 100, y = 60, zoom = 16, easing = "smoothstep"},
			{t = 6, x = 200, y = 100, zoom = 4, easing = "linear"},
		}})
		local p = Film.sample(s, 1)
		t.eq(p.x, 15.625); t.eq(p.y, 26.25); t.near(p.zoom, 16 ^ .15625, 1e-12)
		t.eq(Film.sample(s, 4).x, 100)
		t.eq(Film.sample(s, 5).x, 150); t.near(Film.sample(s, 5).zoom, 8, 1e-12)
		for _, elapsed in {6, 8, 100} do
			p = Film.sample(s, elapsed); t.eq(p.x, 200); t.eq(p.zoom, 4)
		end
		t.eq(Film.sample(s, -5).x, 0)
	end)

	t.test("copied shots, static shots and free off-map centres", function()
		local input = shot(); local s = Film.prepare(input)
		input.keyframes[1].x = 123; table.clear(input.keyframes)
		t.eq(Film.sample(s, 0).x, 10)
		local static = Film.prepare({duration = 1, keyframes = {{t = 0, x = -100, y = 10000, zoom = .1}}})
		t.eq(Film.sample(static, 100).x, -100)
		t.eq(Film.sample(static, 100).y, 10000)
	end)

	t.test("invalid timelines and nonfinite geometry are rejected", function()
		for _, duration in {0, -1, math.huge, 0 / 0} do
			local s = shot(); s.duration = duration; t.errors(function() Film.prepare(s) end)
		end
		for _, mutate in {
			function(s) s.keyframes = {} end,
			function(s) s.keyframes[1].t = 1 end,
			function(s) s.keyframes[2].t = 0 end,
			function(s) s.keyframes[2].t = 5 end,
			function(s) s.keyframes[2].easing = "bounce" end,
			function(s) s.keyframes[2].zoom = 0 end,
			function(s) s.keyframes[2].x = math.huge end,
			function(s) s.keyframes[2].y = 0 / 0 end,
			function(s) s.keyframes.extra = {} end,
		} do
			local s = shot(); mutate(s); t.errors(function() Film.prepare(s) end)
		end
		t.errors(function() Film.sample(Film.prepare(shot()), math.huge) end)
	end)

	t.test("live games create neither endpoint nor renderer hook", function()
		local _, r, c, player = setup(false)
		t.eq(c, nil); t.eq(r.filmCamera, nil); t.eq(player:FindFirstChild("OpenFrontFilmCamera"), nil)
		r:destroy()
	end)

	t.test("render step uses wall time before drawing and holds ownership at the end", function()
		local e, r, c = setup()
		local endpoint = c.endpoint
		t.eq(endpoint.OnInvoke("status").playing, false)
		r:goTo(2, 3, 5); t.ok(r.goToTarget)
		t.eq(endpoint.OnInvoke("play", shot()), true)
		t.eq(r.goToTarget, nil); t.eq(e.cancelledPreview, 1)
		t.eq(r.scene.layers.Names.Visible, true, "labels retained")
		local draw = r.scene.step
		local seen
		r.scene.step = function(self) seen = r.camera.scale; draw(self) end
		e.now = 2; r:step(1e9, 1e9)
		t.near(seen, 4, 1e-12, "camera applied before scene draw")
		local x, y = r:worldToScreen(50, 40)
		t.near(x, r.camera.left + r.camera.viewportWidth / 2, 1e-9)
		t.near(y, r.camera.top + r.camera.viewportHeight / 2, 1e-9)
		e.now = 100; r:step(1e9, 1e9)
		t.eq(endpoint.OnInvoke("status").playing, true)
		t.eq(endpoint.OnInvoke("status").t, 4); t.eq(r.camera.scale, 8)
		endpoint.OnInvoke("stop"); t.eq(endpoint.OnInvoke("status").t, nil)
		r:destroy()
	end)

	t.test("mouse, touch, gamepad and automatic camera paths cannot compete", function()
		local e, r, c = setup()
		c.endpoint.OnInvoke("play", shot())
		local before = table.clone(r.camera)
		r:pan(100, 100); r:zoom(10, 10, -120); r:centerAll(); r:goTo(0, 0, 10)
		t.eq(r.goToTarget, nil); t.eq(r.camera.offsetX, before.offsetX); t.eq(r.camera.scale, before.scale)
		-- Actual input callbacks cancel ownership/held controls, not just movement.
		e.mouseTap(400, 190); t.eq(e.taps(), 0)
		local roblox = require("@lune/roblox")
		local touch = {UserInputType = roblox.Enum.UserInputType.Touch, Position = {X = 400, Y = 190, Z = 0}}
		e.uis.InputBegan:Fire(touch, false)
		t.eq(#r.input.touchOrder, 0)
		e.uis.InputBegan:Fire({UserInputType = roblox.Enum.UserInputType.Gamepad1,
			KeyCode = roblox.Enum.KeyCode.ButtonR2, Position = {X = 0, Y = 0, Z = 0}}, false)
		t.eq(r.input.zoomDirection, 0)
		c.endpoint.OnInvoke("stop")
		r:pan(20, 0); t.ok(r.camera.offsetX ~= before.offsetX, "normal controls restored at last pose")
		r:goTo(10, 20, 3); t.ok(r.goToTarget)
		r:destroy()
	end)

	t.test("resize preserves exact float centre and replacement restarts elapsed time", function()
		local e, r, c = setup()
		c.endpoint.OnInvoke("play", shot())
		e.now = 1
		r.camera.viewportWidth, r.camera.viewportHeight, r.camera.left, r.camera.top = 1920, 1080, 24, 36
		r:step(1e9, 1e9)
		local x, y = r:worldToScreen(30, 30)
		t.near(x, 984, 1e-9); t.near(y, 576, 1e-9)
		c.endpoint.OnInvoke("play", {duration = 1, keyframes = {{t = 0, x = -10, y = 20, zoom = 3}}})
		t.eq(c.endpoint.OnInvoke("status").t, 0); t.eq(r.camera.scale, 3)
		r:destroy()
	end)

	t.test("invalid commands, camera errors and renderer teardown release ownership", function()
		local e, r, c, player = setup()
		c.endpoint.OnInvoke("play", shot())
		t.errors(function() c.endpoint.OnInvoke("play", {}) end)
		t.eq(c.playing, false)
		c.endpoint.OnInvoke("play", shot())
		t.errors(function() c.endpoint.OnInvoke("unknown") end)
		t.eq(c.playing, false)
		c.endpoint.OnInvoke("play", shot())
		local setCamera = r.setCamera
		r.setCamera = function() error("camera fixture") end
		e.now = 2; r:step(1e9, 1e9)
		t.eq(c.playing, false); t.ok(e.warning); t.eq(r.destroyed, false)
		r.setCamera = setCamera
		c.endpoint.OnInvoke("play", shot())
		local endpoint = c.endpoint
		r:destroy()
		t.eq(c.destroyed, true); t.eq(c.playing, false); t.eq(r.filmCamera, nil)
		t.eq(endpoint.destroyed, true); t.eq(endpoint.OnInvoke, nil)
		t.eq(player:FindFirstChild("OpenFrontFilmCamera"), nil)
	end)

	t.test("loading refuses play and destroying the endpoint restores control", function()
		local _, r, c, player = setup()
		r.ready = false
		t.errors(function() c.endpoint.OnInvoke("play", shot()) end)
		t.eq(c.playing, false)
		r.ready = true
		c.endpoint.OnInvoke("play", shot())
		c.endpoint:Destroy()
		t.eq(c.destroyed, true); t.eq(r.filmCamera, nil)
		t.eq(player:FindFirstChild("OpenFrontFilmCamera"), nil)
		r:goTo(10, 20, 3); t.ok(r.goToTarget)
		r.root:Destroy(); t.eq(r.destroyed, true)
	end)

	t.test("box fitting uses height and width in portrait and landscape and copies inputs", function()
		local box = {x = 40, y = 50, w = 100, h = 1000}
		local input = {duration = 3, keyframes = {{t = 0, box = box, fit = .9}}}
		local s = Film.prepare(input)
		box.h = 1
		local p = Film.sample(s, 0, 1080, 1920)
		t.near(p.zoom, 1920 / 1000 * .9, 1e-12)
		t.eq(p.x, 40); t.eq(p.y, 50)
		t.near(Film.sample(s, 3, 1920, 1080).zoom, 1080 / 1000 * .9, 1e-12)
		local wide = Film.prepare({duration = 1, keyframes = {{t = 0, box = {x = 0, y = 0, w = 1000, h = 100}}}})
		t.near(Film.sample(wide, 0, 1080, 1920).zoom, 1.08, 1e-12)
		t.errors(function() Film.sample(s, 0) end)
	end)

	t.test("box interpolation and safe frame fit are recomputed at the current viewport", function()
		local frame = {x = 60/1080, y = 310/1920, w = 820/1080, h = 940/1920}
		local s = Film.prepare({duration = 4, frame = frame, keyframes = {
			{t = 0, box = {x = 10, y = 20, w = 100, h = 100}},
			{t = 4, box = {x = 90, y = 60, w = 100, h = 1000}},
		}})
		frame.w = 1
		local p = Film.sample(s, 2, 1080, 1920)
		t.eq(p.x, 50); t.eq(p.y, 40); t.near(p.zoom, math.sqrt(8.2 * .94), 1e-12)
		t.near(Film.sample(s, 2, 540, 960).zoom, p.zoom / 2, 1e-12)
	end)

	t.test("portrait resize centres the box in the safe frame without stretching map pages", function()
		local e, r, c = setup()
		local rb = require("@lune/roblox")
		c.endpoint.OnInvoke("play", {duration = 5, frame = {x = 60/1080, y = 310/1920, w = 820/1080, h = 940/1920},
			keyframes = {{t = 0, box = {x = 32, y = 32, w = 20, h = 40}, fit = .9}}})
		for _, dimensions in {{1080,1920},{540,960},{1920,1080}} do
			r.parent.AbsoluteSize = rb.Vector2.new(dimensions[1], dimensions[2])
			r.parent.AbsolutePosition = rb.Vector2.new(24,36)
			r.parent:GetPropertyChangedSignal("AbsoluteSize"):Fire()
			local x,y = r:worldToScreen(32,32)
			t.near(x,24+dimensions[1]*470/1080,1e-9)
			t.near(y,36+dimensions[2]*780/1920,1e-9)
			r:step(1e9,1e9)
			local x1,y1 = r:worldToScreen(33,33)
			t.near(x1-x,y1-y,1e-9,"uniform map scale")
			for _,d in r.displays do
				t.near(d.label.Size.X.Offset/d.page.width,d.label.Size.Y.Offset/d.page.height, .04,"page aspect")
			end
		end
		r:destroy()
	end)

	t.test("filming labels resize with export height and restore source sizing on stop and errors", function()
		local e,r,c = setup()
		local s = r.scene
		s:setNameAnchors({[1]={x=20,y=20,size=300},[2]={x=40,y=40,size=1}})
		local view = table.clone(r.camera); view.viewportWidth,view.viewportHeight=1080,1920; r:setCamera(view)
		local input = {duration=5,labelPixels=60,keyframes={{t=0,x=32,y=32,zoom=4}}}
		c.endpoint.OnInvoke("play",input)
		for _=1,4 do r:step(1e9,1e9) end
		local v=s.nameViews[1]
		local function pixels(line) return line.TextSize*v.scale.Scale*s.worldScale.Scale end
		t.near(pixels(v.name),60,1e-6);t.near(pixels(v.troops),42,1e-6)
		t.ok(not s.nameViews[2] or not s.nameViews[2].sourceVisible,"film override revived source-culled name")
		view=table.clone(r.camera);view.viewportWidth,view.viewportHeight=540,960;r:setCamera(view)
		r:step(1e9,1e9)
		t.near(pixels(v.name),30,1e-6);t.near(pixels(v.troops),21,1e-6)
		c.endpoint.OnInvoke("stop");r:step(1e9,1e9)
		t.eq(s.filmLabelPixels,nil);t.near(pixels(v.name),960*.08,1e-5)
		-- Same name em on both sides still needs troop spacing/size restored.
		input.keyframes[1].zoom=30/(v.sourceSizing.nameWorldScale*48)
		c.endpoint.OnInvoke("play",input);r:step(1e9,1e9)
		t.near(pixels(v.name),30,1e-5);t.near(pixels(v.troops),21,1e-5)
		t.near(v.name.Size.X.Offset*v.scale.Scale*s.worldScale.Scale,300,1e-5,"wide film shot clipped the fixed-size name container")
		c.endpoint.OnInvoke("stop");r:step(1e9,1e9)
		t.near(pixels(v.name),30,1e-5);t.near(pixels(v.troops),18,1e-5)
		c.endpoint.OnInvoke("play",input)
		t.errors(function() c.endpoint.OnInvoke("play",{}) end)
		t.eq(s.filmLabelPixels,nil)
		r:destroy()
	end)

	t.test("invalid boxes, safe frames and label overrides release film ownership", function()
		for _,box in {{x=0,y=0,w=0,h=10},{x=0,y=0,w=1,h=math.huge},{x=0/0,y=0,w=1,h=1}} do
			t.errors(function() Film.prepare({duration=1,keyframes={{t=0,box=box}}}) end)
		end
		for _,frame in {{x=0,y=0,w=1.1,h=1},{x=-.1,y=0,w=1,h=1},{x=0,y=0,w=1,h=0}} do
			local input=shot();input.frame=frame;t.errors(function() Film.prepare(input) end)
		end
		for _,pixels in {0,-1,201,math.huge,0/0} do
			local input=shot();input.labelPixels=pixels;t.errors(function() Film.prepare(input) end)
		end
		t.errors(function() Film.prepare({duration=1,keyframes={{t=0,box={x=0,y=0,w=1,h=1},fit=2}}}) end)
		t.errors(function() Film.prepare({duration=1,keyframes={{t=0,box={x=0,y=0,w=1,h=1},zoom=2}}}) end)
	end)
end
