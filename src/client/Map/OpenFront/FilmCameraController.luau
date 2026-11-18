--!strict
-- Studio-only camera ownership for actual gameplay capture. HUD and names stay visible.
local Film = require(script.Parent.FilmCamera)
local Controller = {}
Controller.__index = Controller

function Controller.new(renderer: any, player: Player, onPlay: () -> ()): any
	if not game:GetService("RunService"):IsStudio() then return nil end
	assert(not renderer.destroyed and renderer.filmCamera == nil, "film camera already attached or renderer destroyed")
	assert(player:FindFirstChild("OpenFrontFilmCamera") == nil, "film camera endpoint already exists")
	local self: any = setmetatable({renderer = renderer, playing = false, destroyed = false,
		shot = nil, started = nil, onPlay = onPlay, connections = {}}, Controller)
	local endpoint = Instance.new("BindableFunction")
	endpoint.Name = "OpenFrontFilmCamera"
	self.endpoint = endpoint
	renderer.filmCamera = self
	endpoint.OnInvoke = function(command: string, shot: any): any
		local ok, result = pcall(function(): any
			assert(not self.destroyed, "film camera destroyed")
			if command == "play" then
				self:stop()
				local prepared = Film.prepare(shot)
				assert(renderer:isReady(), "wait for the map to finish loading before filming")
				renderer:clearTarget()
				if renderer.input then renderer.input:cancel(true) end
				self.onPlay()
				self.shot, self.started, self.playing = prepared, os.clock(), true
				if renderer.scene then renderer.scene:setFilmLabelPixels(prepared.labelPixels) end
				self:apply(0)
				return true
			elseif command == "stop" then
				self:stop()
				return true
			elseif command == "status" then
				return {playing = self.playing, t = if self.playing then math.clamp(os.clock() - self.started, 0, self.shot.duration) else nil}
			end
			error("unknown film camera command")
		end)
		if not ok then self:stop(); error(result, 0) end
		return result
	end
	table.insert(self.connections, endpoint.Destroying:Connect(function() self:destroy() end))
	endpoint.Parent = player
	return self
end

function Controller.apply(self: any, elapsed: number)
	local view: any = table.clone(self.renderer.camera)
	local pose = Film.sample(self.shot, elapsed, view.viewportWidth, view.viewportHeight)
	view.scale = pose.zoom
	local f = self.shot.frame
	local centreX = view.viewportWidth * (if f then f.x + f.w / 2 else .5)
	local centreY = view.viewportHeight * (if f then f.y + f.h / 2 else .5)
	-- Exact float centre, including inset/non-square viewports. No clamping:
	-- the normal free camera and shots beyond map edges remain available.
	view.offsetX = pose.x - view.width / 2 - (centreX - view.width / 2) / view.scale
	view.offsetY = pose.y - view.height / 2 - (centreY - view.height / 2) / view.scale
	assert(math.abs(view.offsetX) < math.huge and math.abs(view.offsetY) < math.huge, "film pose exceeds camera precision")
	local old = self.renderer.camera
	if old.scale ~= view.scale or old.offsetX ~= view.offsetX or old.offsetY ~= view.offsetY then
		self.renderer:setCamera(view)
	end
end

-- Called by Renderer.step before scene/raster work, never an unordered second
-- RenderStepped connection. Elapsed wall time avoids frame-count-dependent motion.
function Controller.step(self: any)
	if not self.playing then return end
	local ok, err = pcall(function() self:apply(os.clock() - self.started) end)
	if not ok then self:stop(); warn(`OpenFront film camera: {err}`) end
end

function Controller.stop(self: any)
	self.playing, self.shot, self.started = false, nil, nil
	if self.renderer.scene then self.renderer.scene:setFilmLabelPixels(nil) end
	if self.renderer.input then self.renderer.input:cancel(true) end
end

function Controller.destroy(self: any)
	if self.destroyed then return end
	self.destroyed = true
	self:stop()
	if self.renderer.filmCamera == self then self.renderer.filmCamera = nil end
	for _, connection in self.connections do connection:Disconnect() end
	table.clear(self.connections)
	self.endpoint.OnInvoke = nil
	self.endpoint:Destroy()
end

return Controller
