--!strict
-- Ported from OpenFront v0.35.2 (src/client/render/gl/passes/TerrainPass.ts; src/client/render/frame/Upload.ts; src/client/TransformHandler.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Thin Roblox sink for the independently testable full-resolution RasterCore.
local Core = require(script.Parent.RasterCore)
local Camera = require(script.Parent.CameraTransform)
local LabelPlacement = require(script.Parent.LabelPlacement)
local Terrain = require(script.Parent.TerrainColors)
local Overlay = require(script.Parent.SceneOverlay)
local Input = require(script.Parent.MapInput)
local Relations = require(script.Parent.Relations)
local Timings = require(script.Parent.RenderTimings)
local Policy = require(script.Parent.RenderPolicy)
local Defaults = require(script.Parent.RenderDefaults)
local Coasts = require(script.Parent.CoastOverlay)
local GuiLayers = require(script.Parent.MapGuiLayers)
local Renderer = {}
Renderer.__index = Renderer
local GOTO_INTERVAL_SECONDS = 0.016 -- Original: TransformHandler.GOTO_INTERVAL_MS.
export type ContextCallback = Input.ContextCallback
type Display = {image: EditableImage, label: ImageLabel, page: Core.Page}
export type Options = {autoStep: boolean?, budgetMs: number?, pixelBudget: number?, onError: ((string) -> ())?,
	firstPaint: ("full" | "incremental")?, firstPaintBudgetMs: number?, profile: boolean?, coasts: boolean?, guiHost: ScreenGui?}
type ReadyListener = {callback: () -> (), connected: boolean}
type CameraListener = {callback: () -> (), connected: boolean}
type WarshipListener = {callback: (number?) -> (), connected: boolean}
export type Renderer = typeof(setmetatable({} :: {
	core: Core.State, root: Frame, parent: GuiObject, camera: Camera.View, displays: {[number]: Display},
	labelOccluders: {LabelPlacement.Rect},
	connections: {RBXScriptConnection}, options: Options, destroyed: boolean, lastError: string?, fitPending: boolean,
	scene: any?, input: any?, filmCamera: any?, ownSpawnRing: boolean, territoryLabelsVisible: boolean,
	goToConnection: RBXScriptConnection?, goToTarget: {x: number, y: number, scale: number?, elapsed: number, first: boolean}?,
	ready: boolean, readyPending: boolean, readyListeners: {ReadyListener}, stateAttached: boolean, progress: number,
	firstPaintBaseReady: boolean, firstPaintRefreshed: boolean,
	cameraListeners: {[CameraListener]: boolean}, cameraStamp: Camera.View?,
	warshipListeners: {[WarshipListener]: boolean},
	firstPaintBuffers: {[number]: buffer}, firstPaintUploaded: {[number]: boolean}, firstPaintBytes: number,
	loadStarted: number, loadMs: number, loadFrames: number, firstPaintWrites: number,
	loadCpuMs: number, loadMaxStepMs: number, firstPaintPeakBytes: number,
	profiler: Timings.Timings,
	flagArt: any?,
	coasts: any?,
	guiLayers: any,
	rasterMaxMs: number, rasterBudgetMs: number,
}, Renderer))

local function notifyCamera(s:Renderer)
	local c,old=s.camera,s.cameraStamp
	if old and old.scale==c.scale and old.offsetX==c.offsetX and old.offsetY==c.offsetY
		and old.left==c.left and old.top==c.top and old.viewportWidth==c.viewportWidth and old.viewportHeight==c.viewportHeight then return end
	s.cameraStamp=table.clone(c)
	if next(s.cameraListeners)==nil then return end
	for listener in table.clone(s.cameraListeners) do
		if s.destroyed then break end
		if listener.connected then
			local ok,err=pcall(function() listener.callback(); return true end)
			if not ok then warn(`OpenFront camera callback: {err}`) end
		end
	end
end

function Renderer.onCameraChanged(s:Renderer,callback:()->()):()->()
	if s.destroyed then return function() end end
	local listener={callback=callback,connected=true}
	s.cameraListeners[listener]=true
	return function() listener.connected=false; s.cameraListeners[listener]=nil end
end

local function notifyWarship(s:Renderer,id:number?)
	for listener in table.clone(s.warshipListeners) do
		if s.destroyed and id~=nil then break end
		if listener.connected then
			local ok,err=pcall(function() listener.callback(id); return true end)
			if not ok then warn(`OpenFront warship callback: {err}`) end
		end
	end
end

-- Selection edges only; subscribing does not replay a previous tap.
function Renderer.onWarshipSelected(s:Renderer,callback:(number?)->()):()->()
	if s.destroyed then return function() end end
	local listener={callback=callback,connected=true}
	s.warshipListeners[listener]=true
	return function() listener.connected=false; s.warshipListeners[listener]=nil end
end

function Renderer.setWarshipPatrolVisible(s:Renderer,id:number?)
	if not s.destroyed and s.scene then s.scene:setWarshipPatrolVisible(id) end
end

-- Explicit presentation only. Callers choose a confirmed impact or local tap;
-- neither method sends a command, advances the camera or promises an outcome.
function Renderer.pulse(s:Renderer,kind:string,tile:number)
	if s.destroyed or not s.scene or tile~=math.floor(tile) or tile<0 or tile>=s.core.width*s.core.height then return end
	s.scene.feel:pulse(kind,tile,os.clock())
end
function Renderer.focusAt(s:Renderer,worldX:number,worldY:number)
	if (s.filmCamera and s.filmCamera.playing) or s.destroyed or not s.scene or worldX~=worldX or worldY~=worldY
		or math.abs(worldX)==math.huge or math.abs(worldY)==math.huge then return end
	s.scene.feel:focusAt(worldX,worldY,os.clock())
end

function Renderer.setTerritoryLabelsVisible(s:Renderer,visible:boolean)
	if s.destroyed or s.territoryLabelsVisible==visible then return end
	s.territoryLabelsVisible=visible
	if s.scene then s.scene.layers.Names.Visible=visible end
end

-- UI supplies visible occupied regions, already in absolute screen pixels.
-- Copy them: a HUD rebuild cannot mutate or retain GUI references in the map.
function Renderer.setLabelOccluders(s:Renderer,rects:{LabelPlacement.Rect})
	if s.destroyed then return end
	assert(#rects<=64,'too many label exclusion rectangles')
	local copy={}
	for _,rect in rects do
		for _,value in {rect.x,rect.y,rect.w,rect.h} do assert(value==value and math.abs(value)<math.huge,'invalid label rectangle') end
		assert(rect.w>=0 and rect.h>=0,'invalid label rectangle extent')
		if rect.w>0 and rect.h>0 then table.insert(copy,{x=rect.x,y=rect.y,w=rect.w,h=rect.h}) end
	end
	s.labelOccluders=copy
	if s.scene then s.scene.labelLayoutDirty=true; s.scene.costLayoutDirty=true; s.scene:layoutLabels() end
end

function Renderer.playerNameScreenRect(s:Renderer,id:number,unshifted:boolean?): LabelPlacement.Rect?
	if s.destroyed or not s.scene then return nil end
	return s.scene:nameScreenRect(id,unshifted)
end

-- Read the displayed eased pose, not the latest target anchor. The Names
-- parent's settings visibility is deliberately ignored for HUD toast anchors.
function Renderer.playerNameScreenPosition(s:Renderer,id:number):(number?,number?)
	if s.destroyed or not s.scene then return nil,nil end
	local view=s.scene.nameViews[id]
	if not view or not view.root.Visible or not view.sx or not view.sy then return nil,nil end
	if view.labelHidden then return nil,nil end
	local c=s.camera
	local raw=view.sourceSizing
	if not view.targeted and (not raw or raw.nameWorldScale*72*c.scale/c.viewportWidth<Defaults.name.cullThreshold) then return nil,nil end
	local x,y=Camera.worldToScreenCoordinates(c,view.sx/64,view.sy/64)
	x+=view.labelDx or 0; y+=view.labelDy or 0
	if x<c.left-300 or x>c.left+c.viewportWidth+300 or y<c.top-100 or y>c.top+c.viewportHeight+100 then return nil,nil end
	return x,y
end

-- Roblox equivalent of TerrainPass.draw: transform both shared page edges by
-- the same equation and integer rounding, so fractional zoom cannot open seams.
local function place(s: Renderer, d: Display)
	local x0, y0 = Camera.worldToScreenCoordinates(s.camera, d.page.x, d.page.y)
	local x1, y1 = Camera.worldToScreenCoordinates(s.camera, d.page.x + d.page.width, d.page.y + d.page.height)
	x0 = math.floor(x0 - s.camera.left + .5); y0 = math.floor(y0 - s.camera.top + .5)
	x1 = math.floor(x1 - s.camera.left + .5); y1 = math.floor(y1 - s.camera.top + .5)
	d.label.Position, d.label.Size = UDim2.fromOffset(x0, y0), UDim2.fromOffset(x1 - x0, y1 - y0)
end

local function writeDisplay(s: Renderer, page: Core.Page, x: number, y: number, w: number, h: number, pixels: buffer)
	local display = s.displays[page.id]
	if not display then
		local image = game:GetService("AssetService"):CreateEditableImage({Size = Vector2.new(page.width, page.height)})
		assert(image, `EditableImage allocation failed for full-resolution page {page.id} ({page.width}x{page.height}); no implicit stride fallback`)
		local label = Instance.new("ImageLabel")
		label.Name, label.BackgroundTransparency, label.BorderSizePixel = `Page{page.id}`, 1, 0
		label.ZIndex=0 -- coast 1, spawn 2, rails 3; explicit Sibling ordering
		label.ImageContent, label.ResampleMode = Content.fromObject(image), Enum.ResamplerMode.Pixelated
		local created: Display = {image = image, label = label, page = page}
		s.displays[page.id] = created; display = created
		place(s, created); label.Parent = s.root
	end
	display.image:WritePixelsBuffer(Vector2.new(x, y), Vector2.new(w, h), pixels)
end

local function notifyReady(listener: ReadyListener)
	if not listener.connected then return end
	listener.connected = false
	local ok, err = pcall(function() listener.callback(); return true end)
	if not ok then warn(`OpenFront ready listener: {err}`) end
end

-- Roblox adapter for TerrainPass.constructor / texture allocation. This
-- creates no scripts/remotes/assets and does not require server map modules.
function Renderer.new(parent: GuiObject, terrain: buffer, width: number, height: number, options: Options?): Renderer
	local settings: Options = options or {}
	assert((settings.budgetMs or 2) > 0 and (settings.pixelBudget or 65536) > 0, "invalid renderer budget")
	assert(settings.firstPaint == nil or settings.firstPaint == "full" or settings.firstPaint == "incremental", "invalid firstPaint mode")
	assert((settings.firstPaintBudgetMs or 30) > 0, "invalid firstPaint budget")
	local full = settings.firstPaint == "full"
	-- Flag artwork is supplied by the screen-UI package; pure map hosts may
	-- omit that sibling. A present module must still load successfully.
	local hasFlagArt = pcall(function() return script.Parent.Parent.Parent.Ui.FlagArt end)
	local flagArt = if hasFlagArt then require(script.Parent.Parent.Parent.Ui.FlagArt) else nil
	local root = Instance.new("Frame")
	root.Name, root.Size, root.BorderSizePixel = "OpenFrontMapCore", UDim2.fromScale(1, 1), 0
	root.BackgroundColor3 = Color3.fromRGB(table.unpack(Terrain.defaults.backgroundColor))
	root.ClipsDescendants, root.Parent = true, parent
	root.Visible = not full
	local s = setmetatable({root = root, parent = parent, displays = {}, connections = {}, options = settings, destroyed = false, lastError = nil, scene = nil, input = nil, ownSpawnRing = false, territoryLabelsVisible = true,
		ready = not full, readyPending = false, readyListeners = {}, cameraListeners = {}, warshipListeners = {}, stateAttached = false, progress = if full then 0 else 1,
		firstPaintBuffers = {}, firstPaintUploaded = {}, firstPaintBytes = 0, firstPaintBaseReady = false,
		firstPaintRefreshed = false,
		loadStarted = os.clock(), loadMs = 0, loadFrames = 0, firstPaintWrites = 0,
		loadCpuMs = 0, loadMaxStepMs = 0, firstPaintPeakBytes = 0,
		profiler = Timings.new(settings.profile),
		rasterMaxMs = if game:GetService('UserInputService').TouchEnabled then Policy.rasterTouchMaxMs else Policy.rasterDesktopMaxMs,
		rasterBudgetMs=Policy.rasterBaseMs,
		flagArt = flagArt,
		fitPending = parent.AbsoluteSize.X <= 0 or parent.AbsoluteSize.Y <= 0, labelOccluders = {},
		camera = {width = width, height = height, viewportWidth = math.max(1, parent.AbsoluteSize.X), viewportHeight = math.max(1, parent.AbsoluteSize.Y),
			left = parent.AbsolutePosition.X, top = parent.AbsolutePosition.Y, offsetX = 0, offsetY = 0, scale = 1}}, Renderer) :: any
	Camera.centerAll(s.camera)
	s.guiLayers=GuiLayers.new(root,settings.guiHost,Policy.splitMapGuis,{new=Instance.new,Enum=Enum,UDim2=UDim2})
	s.guiLayers:layout(s.camera)
	s.cameraStamp=table.clone(s.camera)
	local sink: Core.Sink = {
		write = function(page, x, y, w, h, pixels)
			if not s.ready then
				local staging = s.firstPaintBuffers[page.id]
				if not staging then
					staging = page.pixels
					s.firstPaintBuffers[page.id] = staging; s.firstPaintBytes += buffer.len(staging)
					s.firstPaintPeakBytes = math.max(s.firstPaintPeakBytes, s.firstPaintBytes)
				end
				-- RasterCore already copied this rectangle into the retained RGBA page.
				s.firstPaintUploaded[page.id] = false
			else
				writeDisplay(s, page, x, y, w, h, pixels)
			end
			if s.coasts then s.coasts:mark(page,x,y,w,h) end
		end,
		destroy = function()
			for _, d in s.displays do d.label:Destroy(); d.image:Destroy() end
			table.clear(s.displays); root:Destroy()
		end,
	}
	local ok, result = pcall(Core.new, terrain, width, height, sink)
	if not ok then s.guiLayers:destroy(); root:Destroy(); error(result, 2) end
	s.core = result
	if settings.coasts~=false and Policy.staticCoasts then
		s.coasts=Coasts.new(s,{Instance=Instance,Vector2=Vector2,UDim2=UDim2,Enum=Enum,Content=Content,
			allocate=function(size: Vector2) return game:GetService('AssetService'):CreateEditableImage({Size=size}) end},
			game:GetService('UserInputService').TouchEnabled)
	end
	local function resize()
		if s.destroyed then return end
		if s.camera.viewportWidth ~= parent.AbsoluteSize.X or s.camera.viewportHeight ~= parent.AbsoluteSize.Y
			or s.camera.left ~= parent.AbsolutePosition.X or s.camera.top ~= parent.AbsolutePosition.Y then
			-- Held coordinates belong to the old viewport. Consume their release
			-- and discard the retained touch ghost before changing the transform.
			if s.input then Input.cancel(s.input, true) end
		end
		if parent.AbsoluteSize.X <= 0 or parent.AbsoluteSize.Y <= 0 then return end
		s.camera.viewportWidth, s.camera.viewportHeight = parent.AbsoluteSize.X, parent.AbsoluteSize.Y
		s.camera.left, s.camera.top = parent.AbsolutePosition.X, parent.AbsolutePosition.Y
		if s.fitPending then Camera.centerAll(s.camera); s.fitPending = false else Camera.clampOffsets(s.camera) end
		s.guiLayers:layout(s.camera)
		for _, d in s.displays do place(s, d) end
		if s.scene then s.scene:setCamera() end
		if s.coasts then s.coasts:setCamera() end
		notifyCamera(s)
	end
	table.insert(s.connections, parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(resize))
	table.insert(s.connections, parent:GetPropertyChangedSignal("AbsolutePosition"):Connect(resize))
	table.insert(s.connections, root.Destroying:Connect(function() Renderer.destroy(s) end))
	table.insert(s.connections, root:GetPropertyChangedSignal("Visible"):Connect(function() s.guiLayers:show(root.Visible) end))
	if settings.autoStep ~= false then
		table.insert(s.connections, game:GetService("RunService").RenderStepped:Connect(function()
			local success, err = pcall(Renderer.step, s)
			if not success then
				if settings.onError then settings.onError(tostring(err)) else warn(err) end
			end
		end))
	end
	return s
end

-- Original frame Upload dispatch, budgeted by RasterCore. Allocation/upload
-- calls are non-preemptible; errors stop and free this controller immediately.
function Renderer.step(s: Renderer, budgetMs: number?, pixelBudget: number?): any
	assert(not s.destroyed, "renderer destroyed")
	local started = os.clock()
	local ok, result = pcall(function()
		if s.filmCamera then s.filmCamera:step() end
		Core.beginFrame(s.core)
		local loading = not s.ready
		if loading then s.loadFrames += 1 end
		if s.coasts then s.coasts:build(loading) end
		local prepareStarted = s.profiler:begin()
		local atlasUpload = s.scene ~= nil and s.scene:prepareFrame()
		-- Geometry is static. Coastal paint only consumes a shared image slot
		-- after changed source rows; retain three of four backlog frames for core.
		if not atlasUpload and s.coasts and (loading or not Core.hasPending(s.core) or s.core.frames%4==0) then
			atlasUpload=s.coasts:prepare(loading)
		end
		s.profiler:finish("prepare", prepareStarted)
		local output = {pixels = 0, uploads = 0, ms = 0, page = nil :: number?, atlasUpload = atlasUpload == true}
		-- Once every base page has been painted and uploaded, hold that complete
		-- confirmed image for coast composition and the settling frame. Live
		-- deltas stay queued; they resume under the normal budget after reveal.
		-- Otherwise an active match can keep first-use coasts waiting forever.
		if not atlasUpload and not (loading and (not s.stateAttached or s.firstPaintBaseReady)) then
			local rasterStarted = s.profiler:begin()
			local liveBudget=budgetMs or s.options.budgetMs
			local livePixels=pixelBudget or s.options.pixelBudget
			if not loading then
				local c=s.camera
				local x0,y0=Camera.screenToWorldCoordinatesFloat(c,c.left,c.top)
				local x1,y1=Camera.screenToWorldCoordinatesFloat(c,c.left+c.viewportWidth,c.top+c.viewportHeight)
				Core.setViewport(s.core,{x0=x0,y0=y0,x1=x1,y1=y1})
				if not liveBudget then
					-- Bounded catch-up: explicit caller budgets remain authoritative.
					local adaptive=math.min(s.rasterMaxMs,Policy.rasterBaseMs+math.max(0,s.core.pending-16)/32)
					liveBudget=adaptive
					livePixels=livePixels or math.min(Policy.rasterMaxPixels,math.floor(65536*adaptive/Policy.rasterBaseMs))
				end
			end
			s.rasterBudgetMs=liveBudget or Policy.rasterBaseMs
			local raster = Core.step(s.core, if loading then s.options.firstPaintBudgetMs or 30 else liveBudget,
				if loading then math.huge else livePixels, if loading then s.firstPaintUploaded else nil)
			s.profiler:finish("raster", rasterStarted)
			output.pixels, output.uploads, output.ms, output.page = raster.pixels, raster.uploads, raster.ms, raster.page
		end
		local page = if output.page then s.core.pages[output.page] else nil
		local uploaded = false
		if loading and page and page.head > #page.queue and s.firstPaintBuffers[page.id] and not s.firstPaintUploaded[page.id] then
			writeDisplay(s, page, 0, 0, page.width, page.height, s.firstPaintBuffers[page.id])
			s.firstPaintUploaded[page.id] = true; s.firstPaintWrites += 1; uploaded = true
		end
		if loading and not s.firstPaintBaseReady then
			local complete = true
			for _, p in s.core.pages do if not s.firstPaintUploaded[p.id] then complete = false; break end end
			s.firstPaintBaseReady = complete
		end
		if s.scene then s.scene:step() end
		if s.coasts then
			local used=s.coasts:stepViews(math.min(Policy.coastCreatesPerFrame,if s.scene then s.scene.newUnitBudget else 25))
			if s.scene then s.scene.newUnitBudget-=used end
		end
		if loading then
			local elapsed = (os.clock() - started) * 1000
			s.loadCpuMs += elapsed; s.loadMaxStepMs = math.max(s.loadMaxStepMs, elapsed)
			local complete = s.stateAttached and s.firstPaintBaseReady and not s.fitPending
				and s.scene ~= nil and s.scene:isFirstPaintReady()
				and (not s.coasts or s.coasts:ready())
			-- Preparation can outlast the base paint. Refresh edits queued up to
			-- this checkpoint once, including already-uploaded pages. Hold each
			-- refreshed page again, so continuing traffic cannot restart the pass.
			if complete and not s.firstPaintRefreshed then
				s.firstPaintRefreshed = true
				if Core.hasPending(s.core) then
					for _, p in s.core.pages do
						if s.core.deferred.count > 0 or p.head <= #p.queue then s.firstPaintUploaded[p.id] = nil end
					end
					s.firstPaintBaseReady, complete = false, false
				end
			end
			for _, p in s.core.pages do if not s.firstPaintUploaded[p.id] then complete = false; break end end
			s.progress = math.max(s.progress, math.min(.95, .9 * (1 - s.core.pending / s.core.blocks)))
			if complete and s.readyPending and not atlasUpload and not uploaded then
				if s.input then Input.cancel(s.input) end
				s.ready, s.progress, s.root.Visible = true, 1, true
				s.guiLayers:show(true)
				s.loadMs = (os.clock() - s.loadStarted) * 1000
				table.clear(s.firstPaintBuffers); table.clear(s.firstPaintUploaded); s.firstPaintBytes = 0
				local listeners = s.readyListeners; s.readyListeners = {}
				for _, listener in listeners do
					if s.destroyed then break end
					notifyReady(listener)
				end
			end
			s.readyPending = complete
		end
		return output
	end)
	s.profiler:finish("frame", started)
	if not ok then s.lastError = tostring(result); Renderer.destroy(s); error(result, 2) end
	return result
end

-- Full first paint waits for attachState, all page/atlas uploads, visible
-- server-anchor labels and one settling frame. The UI owns the loading cover.
function Renderer.isReady(s: Renderer): boolean return s.ready and not s.destroyed end
function Renderer.loadProgress(s: Renderer): number return s.progress end
function Renderer.resetTimings(s: Renderer) s.profiler:reset() end
function Renderer.setProfiling(s: Renderer, enabled: boolean) s.profiler.enabled = enabled; s.profiler:reset() end
-- Raw source territory fill, before terrain/alpha blending. Unknown IDs have
-- no colour; skin masks keep this primary colour and select a second shade.
function Renderer.playerColor(s: Renderer, smallID: number): Color3?
	local entry = s.core.palette[smallID]
	if not entry or s.destroyed then return nil end
	return Color3.new(entry.fill.r, entry.fill.g, entry.fill.b)
end
function Renderer.onReady(s: Renderer, callback: () -> ()): () -> ()
	local listener = {callback = callback, connected = not s.destroyed}
	if Renderer.isReady(s) then notifyReady(listener)
	elseif not s.destroyed then table.insert(s.readyListeners, listener) end
	return function() listener.connected = false end
end

-- Original GameView / WebGLFrameBuilder player registration.
function Renderer.setRoster(s: Renderer, players: {Core.Player})
	Core.setRoster(s.core, players)
	if s.scene then s.scene.unitsDirty,s.scene.unitCameraDirty=true,true end
end
-- Original GameView.update confirmed tile-state dispatch.
function Renderer.applyTileStates(s: Renderer, stateBuffer: buffer, changedTiles: {number}?)
	local own,fallout={},{}
	Core.applyTileStates(s.core, stateBuffer, changedTiles,if s.scene and changedTiles then {own=own,fallout=fallout} else nil)
	if s.scene then
		s.scene:tilesChanged(if changedTiles then own else nil)
		s.scene.effects:falloutTilesChanged(if changedTiles then fallout else nil)
	end
end
-- Original TerrainPass.applyTerrainRects for water-nuke edits.
function Renderer.applyTerrain(s: Renderer, terrain: buffer, changedTiles: {number}?)
	if s.coasts and not s.coasts.failed then
		local function different(tile: number): boolean
			local before,after=buffer.readu8(s.core.terrain,tile),buffer.readu8(terrain,tile)
			return bit32.band(before,128)~=bit32.band(after,128)
				or (not bit32.btest(before,128) and bit32.band(before,64)~=bit32.band(after,64))
		end
		if changedTiles then
			for _,tile in changedTiles do
				if different(tile) then s.coasts:invalidate(); break end
			end
		else
			for tile=0,s.core.width*s.core.height-1 do
				if different(tile) then s.coasts:invalidate(); break end
			end
		end
	end
	Core.applyTerrain(s.core, terrain, changedTiles)
end
-- Original frame Upload.updateRelations.
function Renderer.setRelations(s: Renderer, matrix: {size: number, data: buffer}) Core.setRelations(s.core, matrix) end
-- Original WebGLFrameBuilder.syncLocalPlayer.
function Renderer.setLocalPlayer(s: Renderer, smallID: number)
	Core.setLocalPlayer(s.core, smallID)
	if s.scene then s.scene:setLocalPlayer(smallID) end
end
-- Original: GameView.setOwnSpawnRing. The tutorial/UI owns activation;
-- ordinary matches keep source's false default, with no invented timeout.
function Renderer.setOwnSpawnRing(s: Renderer, active: boolean)
	if s.destroyed then return end
	s.ownSpawnRing = active
	if s.scene then s.scene:setOwnSpawnRing(active) end
end
-- Original GPURenderer.setHighlightOwner.
function Renderer.setHover(s: Renderer, smallID: number) Core.setHover(s.core, smallID) end

-- Original: TransformHandler.clearTarget. No scheduled work survives a
-- manual camera change, replacement destination or renderer destruction.
function Renderer.clearTarget(s: Renderer)
	if s.goToConnection then s.goToConnection:Disconnect(); s.goToConnection = nil end
	s.goToTarget = nil
end

local function refreshCamera(s: Renderer)
	s.fitPending = false
	s.guiLayers:layout(s.camera)
	for _, d in s.displays do place(s, d) end
	if s.scene then s.scene:setCamera() end
	if s.coasts then s.coasts:setCamera() end
	notifyCamera(s)
end

-- Original: TransformHandler.onGoToPlayer / goTo. Anchors are already world
-- tile coordinates; adding .5 would change the source destination. Roblox's
-- frame driver replaces setInterval, using its elapsed time and first 16ms.
function Renderer.goTo(s: Renderer, worldX: number, worldY: number, scale: number?)
	if s.destroyed or (s.filmCamera and s.filmCamera.playing) then return end
	assert(worldX == worldX and worldY == worldY and math.abs(worldX) < math.huge and math.abs(worldY) < math.huge,
		"invalid camera destination")
	assert(scale == nil or (scale > 0 and scale < math.huge), "invalid camera scale")
	Renderer.clearTarget(s)
	s.goToTarget = {x = worldX, y = worldY, scale = scale, elapsed = 0, first = true}
	s.goToConnection = game:GetService("RunService").RenderStepped:Connect(function(dt: number)
		local target = s.goToTarget
		if s.destroyed or not target then Renderer.clearTarget(s); return end
		target.elapsed += dt
		if target.elapsed < GOTO_INTERVAL_SECONDS then return end
		local elapsed = if target.first then 16 else target.elapsed * 1000
		target.elapsed, target.first = 0, false
		if Camera.goTo(s.camera, target.x, target.y, target.scale, elapsed) then Renderer.clearTarget(s); return end
		refreshCamera(s)
	end)
end

-- Original TransformHandler draw transform. A copied view prevents callers
-- changing camera state without updating all page positions together.
function Renderer.setCamera(s: Renderer, view: Camera.View)
	assert(not s.destroyed and view.width == s.core.width and view.height == s.core.height and view.scale > 0, "invalid camera")
	Renderer.clearTarget(s)
	s.camera = table.clone(view)
	refreshCamera(s)
end
-- Original TransformHandler.onMove.
function Renderer.pan(s: Renderer, dx: number, dy: number)
	if s.filmCamera and s.filmCamera.playing then return end
	Camera.onMove(s.camera, dx, dy); Renderer.setCamera(s, s.camera)
end
-- Original TransformHandler.onZoom (screen-space anchor includes left/top).
function Renderer.zoom(s: Renderer, x: number, y: number, delta: number)
	if s.filmCamera and s.filmCamera.playing then return end
	Camera.onZoom(s.camera, x, y, delta); Renderer.setCamera(s, s.camera)
end
-- Original TransformHandler.centerAll.
function Renderer.centerAll(s: Renderer, fit: number?)
	if s.filmCamera and s.filmCamera.playing then return end
	Camera.centerAll(s.camera, fit); Renderer.setCamera(s, s.camera)
end

-- Roblox measurement boundary: native pixel bytes exclude platform overhead.
function Renderer.metrics(s: Renderer): {[string]: number}
	local m = Core.metrics(s.core); m.allocatedImagePixelBytes, m.allocatedImages = 0, 0
	for _, d in s.displays do m.allocatedImages += 1; m.allocatedImagePixelBytes += d.page.width * d.page.height * 4 end
	if s.scene then for key, value in s.scene:metrics() do m[key] = value end end
	if s.coasts then for key,value in s.coasts:metrics() do m[key]=value end end
	-- firstPaintBuffers aliases RasterCore page backing; counted there.
	m.rasterBudgetMs,m.rasterMaxMs=s.rasterBudgetMs,s.rasterMaxMs
	m.firstPaintStagingBytes, m.firstPaintFrames, m.firstPaintMs = s.firstPaintBytes, s.loadFrames, s.loadMs
	m.firstPaintWrites, m.loadProgress = s.firstPaintWrites, s.progress
	m.firstPaintBaseReady = if s.firstPaintBaseReady then 1 else 0
	m.firstPaintCpuMs, m.firstPaintMaxStepMs, m.firstPaintPeakStagingBytes = s.loadCpuMs, s.loadMaxStepMs, s.firstPaintPeakBytes
	for key, value in s.profiler:metrics() do m[key] = value end
	local x0, y0 = Camera.worldToScreenCoordinates(s.camera, 0, 0)
	local x1, y1 = Camera.worldToScreenCoordinates(s.camera, s.core.width, s.core.height)
	m.mapLeft, m.mapTop, m.mapRight, m.mapBottom = x0 - s.camera.left, y0 - s.camera.top, x1 - s.camera.left, y1 - s.camera.top
	m.viewportWidth, m.viewportHeight, m.cameraScale = s.camera.viewportWidth, s.camera.viewportHeight, s.camera.scale
	if typeof(s.root) == "Instance" then
		local count,instances = 0,0
		local roots={s.root :: Instance}
		for _,gui in s.guiLayers.guis do table.insert(roots,gui) end
		for _,root in roots do
			instances+=1;if root:IsA("GuiObject") then count+=1 end
			for _,child in root:GetDescendants() do instances+=1;if child:IsA("GuiObject") then count+=1 end end
		end
		m.mapGuiObjects = count
		m.mapInstances,m.mapGuiComponents=instances,instances-count
		m.splitMapGuis=if s.guiLayers.enabled then 1 else 0
		m.mapScreenGuis=1+#s.guiLayers.guis
	end
	return m
end

-- Source frame inputs arrive only from confirmed ClientState. This adapter
-- listens to the decoded model; OpenFrontClient never parses unit packets.
function Renderer.attachState(s: Renderer, state: any)
	assert(not s.destroyed and s.scene == nil, "scene already attached")
	local ok, result = pcall(Overlay.new, s)
	if not ok then Renderer.destroy(s); error(result, 2) end
	s.scene = result
	local scene: any = s.scene :: any
	scene.layers.Names.Visible=s.territoryLabelsVisible
	scene.selection.onSingleChanged=function(id:number?) notifyWarship(s,id) end
	local function players()
		local out = {}
		for _, id in state.rosterOrder do table.insert(out, state.players[id]) end
		return out
	end
	local function syncRelations()
		local roster=players()
		Core.setRelations(s.core,Relations.matrix(roster))
		scene:setAffiliations(Relations.friendly(roster,state.you),Relations.clusters(roster))
	end
	local function syncNames()
		-- Even an empty confirmed table is authoritative. Never scan the map
		-- while waiting for the first placement/spawn update.
		scene:setNameAnchors(state.names)
	end
	scene:setRoster(players())
	Renderer.setLocalPlayer(s,state.you)
	scene:setUnits(state.units)
	scene:setRenderConfig(state:config())
	scene:setAttacks(state.attacks or {})
	scene:setDiplomacy(state.diplomacy)
	scene.plans = state.plans
	scene:setRailroads(state.railroads)
	scene:setTick(state.tick)
	scene:setSpawnPhase(state:inSpawnPhase())
	scene:setOwnSpawnRing(s.ownSpawnRing)
	syncNames(); syncRelations()
	s.stateAttached = true
	table.insert(s.connections,state.NamesChanged:Connect(syncNames))
	table.insert(s.connections,state.RelationsChanged:Connect(syncRelations))
	table.insert(s.connections,state.DiplomacyChanged:Connect(function() scene:setDiplomacy(state.diplomacy) end))
	table.insert(s.connections,state.AttacksChanged:Connect(function() scene:setAttacks(state.attacks) end))
	table.insert(s.connections,state.DiplomacyEvents:Connect(function(events: {any}) scene:diplomacyEvents(events, state.tick) end))
	table.insert(s.connections,state.Snapshot:Connect(function()
		scene.feel:reset(state.units)
		scene.artillery:reset(state.units)
		scene.effects:clearConquests()
		scene:clearStatusEvents(); scene:setDiplomacy(state.diplomacy)
	end))
	-- Takeover (ClientState.Rebound; Claude, 2026-11-12, agreed with Codex):
	-- the old nation's conquest feedback and status history go; the world's
	-- continuing effects stay.
	if state.Rebound then
		table.insert(s.connections,state.Rebound:Connect(function()
			scene.effects:clearConquests()
			scene:clearStatusEvents(); scene:setDiplomacy(state.diplomacy)
		end))
	end
	table.insert(s.connections,state.PhaseChanged:Connect(function()
		if state.winner~=nil then
			scene.feel:reset(state.units);scene.artillery:reset({});scene.artillery.stopped=true
			scene.effects:clearConquests()
		end
	end))
	table.insert(s.connections, state.RosterChanged:Connect(function() scene:setRoster(players()); syncRelations() end))
	table.insert(s.connections, state.StatsChanged:Connect(function() scene:setStats(players()) end))
	table.insert(s.connections, state.UnitsChanged:Connect(function(updates: {any}, removed: {number})
		scene:unitUpdates(updates,removed)
		scene:setUnits(state.units)
	end))
	table.insert(s.connections, state.Bonus:Connect(function(events: {any})
		-- Original: GameView.buildFrameEvents skips bonuses for unknown players.
		local known={}; for _, p in state.players do known[p.id]=true end
		local visible={}; for _, event in events do if known[event.player] then table.insert(visible,event) end end
		scene:bonuses(visible)
	end))
	-- ClientState's existing generic event signal already forwards unknown
	-- types. Also support a dedicated Conquest signal if its owner adds one.
	-- Snapshots never replay transient conquest feedback.
	table.insert(s.connections, (state.Conquest or state.DiplomacyEvents):Connect(function(events: {any})
		local conquests={}
		for _, e in events do if e.type=='ConquestEvent' then table.insert(conquests,e) end end
		if #conquests==0 then return end
		local me=state:me()
		if not me then return end
		local byID={}; for _, p in state.players do byID[p.id]=p.smallID end
		local visible={}
		for _, e in conquests do
			local id=byID[e.conqueredId]
			local anchor=if id then state.names[id] else nil
			if e.conquerorId==me.id and anchor then
				table.insert(visible,{x=anchor.x,y=anchor.y,gold=e.gold,tickAge=e.tickAge})
			end
		end
		scene:conquests(visible)
	end))
	table.insert(s.connections, state.UnitsMoved:Connect(function(ids: {number}) scene:setMoved(ids, state.tick) end))
	table.insert(s.connections, state.RailroadsChanged:Connect(function() scene:setRailroads(state.railroads) end))
	table.insert(s.connections, state.TickApplied:Connect(function(tick: number)
		scene:setTick(tick)
		scene:setSpawnPhase(state:inSpawnPhase())
	end))
end

-- The Map owns input lifecycle. OpenFrontClient keeps only the tile command.
function Renderer.bindInput(s: Renderer, playerGui: PlayerGui, mapGui: ScreenGui, onTap: (number) -> (), onMove: (({number},number)->())?, selectionAllowed:(()->boolean)?, onContext: ContextCallback?)
	assert(not s.destroyed and s.input == nil, "map input already bound")
	s.input = Input.new(s,playerGui,mapGui,function(tile:number)
		if not Renderer.isReady(s) then return end
		if s.scene then s.scene:inspectRange(tile) end
		if s.scene and onMove and not s.scene.spawnPhase and (selectionAllowed==nil or selectionAllowed()) then
			local result=s.scene.selection:tap(tile,s.core.width,bit32.band(buffer.readu8(s.core.terrain,tile),128)==0,
				s.scene.units,s.scene.unitOrder,s.core.localPlayer)
			if result.kind=='move' then
				s.scene.feel:move(result.ids,tile,os.clock())
				onMove(result.ids,tile); return
			end
			if result.kind=='select' then return end
		end
		onTap(tile)
	end, if onContext then function(tile: number, x: number, y: number)
		if Renderer.isReady(s) then onContext(tile, x, y) end
	end else nil)
end
function Renderer.selectionBox(s:Renderer,x1:number,y1:number,x2:number?,y2:number?)
	if not Renderer.isReady(s) or not s.scene then return end
	if x2==nil or y2==nil then s.scene.dragBox=nil; return end
	s.scene.dragBox={x1,y1,x2,y2}
end
function Renderer.completeSelectionBox(s:Renderer,x1:number,y1:number,x2:number,y2:number)
	if not Renderer.isReady(s) or not s.scene or s.scene.spawnPhase then return end
	s.scene.dragBox=nil
	s.scene.selection:box(s.scene.units,s.scene.unitOrder,s.core.localPlayer,x1,y1,x2,y2,function(tile:number)
		return Renderer.worldToScreen(s,tile%s.core.width,math.floor(tile/s.core.width))
	end)
end
function Renderer.selectAllWarships(s:Renderer)
	if Renderer.isReady(s) and s.scene and not s.scene.spawnPhase then s.scene.selection:toggleAll(s.scene.units,s.scene.unitOrder,s.core.localPlayer) end
end
function Renderer.clearSelection(s:Renderer)
	if s.scene then s.scene.selection:clear(); s.scene.dragBox=nil end
end
function Renderer.hasSelection(s: Renderer): boolean
	if not s.scene then return false end
	s.scene.selection:prune(s.scene.units, s.core.localPlayer)
	return #s.scene.selection.ids > 0
end
function Renderer.screenToTile(s: Renderer, x: number, y: number): number?
	if s.destroyed then return nil end
	local camera = s.camera
	if x < camera.left or y < camera.top or x >= camera.left + camera.viewportWidth
		or y >= camera.top + camera.viewportHeight then return nil end
	local tx, ty = Camera.screenToWorldCoordinates(s.camera, x, y)
	if tx < 0 or ty < 0 or tx >= s.core.width or ty >= s.core.height then return nil end
	return ty * s.core.width + tx
end
function Renderer.hoverAt(s: Renderer, x: number, y: number)
	local tile = Renderer.screenToTile(s, x, y)
	local owner = if tile then bit32.band(buffer.readu16(s.core.tileState, tile * 2), 4095) else 0
	Renderer.setHover(s, owner)
end
function Renderer.worldToScreen(s: Renderer, x: number, y: number): (number, number)
	return Camera.worldToScreenCoordinates(s.camera, x, y)
end
-- Original: NukeTrajectoryPass.update. Caller supplies the already-ported
-- NukeTrajectory control points while the build/launch aim is active.
function Renderer.setNukePreview(s: Renderer, data: any?)
	if s.scene then s.scene:setNukePreview(data) end
end
-- Source GhostPreviewData is supplied by the action/buildability controller.
-- This API renders its result only; it never invents placement validity/cost.
function Renderer.setBuildPreview(s:Renderer,data:any?) if s.scene then s.scene:setBuildPreview(data) end end
function Renderer.setHighlightStructureTypes(s:Renderer,types:{string}?)
	if s.scene then s.scene:setHighlightStructureTypes(types) end
end

-- Original TerrainPass.dispose and controller-owned connection cleanup.
function Renderer.destroy(s: Renderer)
	if s.destroyed then return end
	s.destroyed = true
	if s.filmCamera then s.filmCamera:destroy() end
	if s.scene then s.scene.selection:clear(); s.scene.selection.onSingleChanged=nil end
	for listener in s.warshipListeners do listener.connected=false end
	table.clear(s.warshipListeners)
	for listener in s.cameraListeners do listener.connected=false end
	table.clear(s.cameraListeners)
	for _, listener in s.readyListeners do listener.connected = false end
	table.clear(s.readyListeners); table.clear(s.firstPaintBuffers); table.clear(s.firstPaintUploaded); s.firstPaintBytes = 0
	Renderer.clearTarget(s)
	for _, connection in s.connections do connection:Disconnect() end
	table.clear(s.connections)
	if s.input then s.input:destroy(); s.input = nil end
	if s.scene then s.scene:destroy(); s.scene = nil end
	if s.coasts then s.coasts:destroy(); s.coasts=nil end
	s.guiLayers:destroy()
	Core.destroy(s.core)
end

return Renderer
