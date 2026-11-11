--!strict
-- Ported from OpenFront v0.35.2 (src/client/InputHandler.ts; src/client/controllers/MapLayerController.ts; src/client/TransformHandler.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
-- Roblox touch, mouse and gamepad gestures are adaptations on the source camera.
local Input = {}
Input.__index = Input
local SLOP = 8
local LONG_PRESS_SECONDS = 0.8 -- Original: InputHandler.LONG_PRESS_MS = 800.
export type ContextCallback = (tile: number, screenX: number, screenY: number) -> ()

-- Cancel gesture ownership as well as held controls: a later release must
-- never turn a focus/text/modal interruption into a map command.
function Input.cancel(s: any, invalidatePointer: boolean?)
	if s.boxStart then s.renderer:selectionBox(0,0) end
	s.boxStart=nil
	s.longPressAt, s.contextActive = nil, false
	s.pinchDistance = nil
	s.press,s.last,s.mouseDown,s.cancelTap,s.maxTravel=nil,nil,false,true,0
	s.stick,s.zoomDirection=Vector2.zero,0
	table.clear(s.touches); table.clear(s.touchOrder)
	if invalidatePointer then s.pointer, s.suspended = nil, true end
end

-- Last pointer is retained after a touch release, like source mousePos. UI,
-- focus and camera gestures temporarily hide previews without losing it.
function Input.pointerPosition(s: any): (number?, number?)
	local pos = s.pointer
	if s.destroyed or s.suspended or not pos or s.isBlocked(pos) or s.isModal()
		or s.boxStart or #s.touchOrder >= 2 or (#s.touchOrder > 0 and s.cancelTap)
		or (s.press and s.maxTravel > SLOP) then return nil, nil end
	return pos.X, pos.Y
end

function Input.new(renderer: any, playerGui: PlayerGui, mapGui: ScreenGui, onTap: (number) -> (), onContext: ContextCallback?): any
	local s: any = setmetatable({renderer = renderer, gui = playerGui, mapGui = mapGui, onTap = onTap,
		connections = {}, touches = {}, touchOrder = {}, press = nil, last = nil, mouseDown = false,
		cancelTap = false, maxTravel = 0, stick = Vector2.zero, zoomDirection = 0, destroyed = false,
		pointer = nil, suspended = false, longPressAt = nil, contextActive = false}, Input)
	local service = game:GetService("UserInputService")
	local render = game:GetService("RunService").RenderStepped
	local function blocked(pos: Vector2): boolean
		for _, obj in playerGui:GetGuiObjectsAtPosition(pos.X, pos.Y) do
			if not obj:IsDescendantOf(mapGui) and not (renderer.guiLayers and renderer.guiLayers:contains(obj))
				and obj.Visible and (obj.Active or obj.BackgroundTransparency < 1) then return true end
		end
		return false
	end
	s.isBlocked = blocked
	s.isModal = function(): boolean
		local camera = renderer.camera
		return service:GetFocusedTextBox() ~= nil
			or blocked(Vector2.new(camera.left+camera.viewportWidth/2,camera.top+camera.viewportHeight/2))
	end
	local function interrupted(pos: Vector2?): boolean
		if s.isModal() or (pos and blocked(pos)) then return true end
		-- A sheet may cover either finger after a pinch has acquired the map.
		for _, touch in s.touches do if blocked(touch) then return true end end
		return false
	end
	table.insert(s.connections,service.WindowFocusReleased:Connect(function() Input.cancel(s); s.suspended=true; renderer:setHover(0) end))
	table.insert(s.connections,service.TextBoxFocused:Connect(function() Input.cancel(s); s.suspended=true end))
	table.insert(s.connections,service.GamepadDisconnected:Connect(function() Input.cancel(s) end))
	local function finish(pos: Vector2)
		if not s.cancelTap and s.press and s.maxTravel <= SLOP and (pos - s.press).Magnitude <= SLOP
			and not interrupted(pos) then
			local tile = renderer:screenToTile(pos.X, pos.Y)
			if tile ~= nil then onTap(tile) end
		end
		s.press, s.last, s.cancelTap, s.maxTravel = nil, nil, false, 0
		s.longPressAt, s.contextActive = nil, false
	end
	local function context(pos: Vector2)
		if onContext == nil or blocked(pos) or s.isModal() then return end
		local tile = renderer:screenToTile(pos.X, pos.Y)
		if tile ~= nil then onContext(tile, pos.X, pos.Y) end
	end
	table.insert(s.connections, service.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local pointer = input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.MouseButton2
		if processed or interrupted(if pointer then pos else nil) then Input.cancel(s); return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if blocked(pos) then return end
			s.pointer, s.suspended = pos, false
			s.mouseDown, s.press, s.last, s.maxTravel, s.cancelTap = true, pos, pos, 0, false
			if service:IsKeyDown(Enum.KeyCode.LeftShift) or service:IsKeyDown(Enum.KeyCode.RightShift) then
				s.boxStart=pos; s.cancelTap=true; renderer:selectionBox(pos.X,pos.Y,pos.X,pos.Y)
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			if blocked(pos) then return end
			Input.cancel(s)
			s.pointer, s.suspended = pos, false
			context(pos)
		elseif input.UserInputType == Enum.UserInputType.Touch then
			if blocked(pos) then return end
			s.pointer, s.suspended = pos, false
			s.touches[input] = pos; table.insert(s.touchOrder, input)
			if #s.touchOrder == 1 then
				s.press, s.last, s.maxTravel, s.cancelTap = pos, pos, 0, false
				s.longPressAt, s.contextActive = if onContext then os.clock() else nil, false
			else
				s.cancelTap = true; s.press = nil; s.longPressAt = nil; s.contextActive = false
				if #s.touchOrder == 2 then
					s.pinchDistance = (s.touches[s.touchOrder[1]] - s.touches[s.touchOrder[2]]).Magnitude
				end
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonA then
			local camera = renderer.camera
			local x,y=camera.left+camera.viewportWidth/2,camera.top+camera.viewportHeight/2
			if blocked(Vector2.new(x,y)) then return end
			local tile = renderer:screenToTile(x,y)
			if tile ~= nil then onTap(tile) end
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 then s.zoomDirection = 1
		elseif input.KeyCode == Enum.KeyCode.ButtonL2 then s.zoomDirection = -1
		elseif input.KeyCode == Enum.KeyCode.ButtonY then renderer:selectAllWarships()
		elseif input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then renderer:clearSelection()
		end
	end))
	table.insert(s.connections, service.InputChanged:Connect(function(input: InputObject, processed: boolean)
		local pos = Vector2.new(input.Position.X, input.Position.Y)
		local tracked = input.UserInputType == Enum.UserInputType.MouseMovement
			or (input.UserInputType == Enum.UserInputType.Touch and s.touches[input] ~= nil)
		if interrupted(if tracked then pos else nil) or (tracked and processed) then
			Input.cancel(s); renderer:setHover(0); return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement then s.pointer, s.suspended = pos, false end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			if not processed and not blocked(pos) then renderer:zoom(pos.X, pos.Y, -input.Position.Z * 120) end
		elseif input.UserInputType == Enum.UserInputType.MouseMovement and s.mouseDown and s.last then
			if s.boxStart then renderer:selectionBox(s.boxStart.X,s.boxStart.Y,pos.X,pos.Y); s.last=pos; return end
			if s.press then s.maxTravel = math.max(s.maxTravel, (pos - s.press).Magnitude) end
			if s.maxTravel > SLOP then renderer:pan(pos.X - s.last.X, pos.Y - s.last.Y) end
			s.last = pos
		elseif input.UserInputType == Enum.UserInputType.MouseMovement then
			if blocked(pos) then renderer:setHover(0) else renderer:hoverAt(pos.X, pos.Y) end
		elseif input.UserInputType == Enum.UserInputType.Touch and s.touches[input] then
			s.pointer = pos
			if s.contextActive then s.touches[input] = pos; return end
			if #s.touchOrder == 2 then
				local a, b = s.touchOrder[1], s.touchOrder[2]
				local other = if a == input then s.touches[b] else s.touches[a]
				if other then
					local distance = (pos - other).Magnitude
					local delta = distance - (s.pinchDistance or distance)
					-- Original: InputHandler.onPointerMove. Accumulate distance
					-- until >1px, then use the source 2x gain (not 4x).
					if math.abs(delta) > 1 then
						local centre = (pos + other) / 2
						renderer:zoom(centre.X, centre.Y, -delta * 2)
						s.pinchDistance = distance
					end
				end
			elseif #s.touchOrder == 1 and s.last then
				if s.press then s.maxTravel = math.max(s.maxTravel, (pos - s.press).Magnitude) end
				if s.maxTravel > SLOP then s.longPressAt=nil; renderer:pan(pos.X - s.last.X, pos.Y - s.last.Y) end
				s.last = pos
			end
			s.touches[input] = pos
		elseif input.KeyCode == Enum.KeyCode.Thumbstick1 then
			if not processed and service:GetFocusedTextBox() == nil then s.stick = Vector2.new(input.Position.X, input.Position.Y) end
		end
	end))
	table.insert(s.connections, service.InputEnded:Connect(function(input: InputObject, processed: boolean)
		if (input.UserInputType == Enum.UserInputType.MouseButton1 and s.mouseDown)
			or (input.UserInputType == Enum.UserInputType.Touch and s.touches[input] ~= nil) then
			if processed or interrupted(Vector2.new(input.Position.X, input.Position.Y)) then Input.cancel(s); return end
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 and s.mouseDown then
			s.mouseDown = false
			if s.boxStart then
				local start=s.boxStart; s.boxStart=nil
				if not blocked(Vector2.new(input.Position.X,input.Position.Y)) then renderer:completeSelectionBox(start.X,start.Y,input.Position.X,input.Position.Y)
				else renderer:selectionBox(0,0) end
				s.press,s.last=nil,nil
			else finish(Vector2.new(input.Position.X,input.Position.Y)) end
		elseif input.UserInputType == Enum.UserInputType.Touch and s.touches[input] then
			s.pointer = Vector2.new(input.Position.X, input.Position.Y)
			s.longPressAt = nil
			s.touches[input] = nil
			for i, tracked in s.touchOrder do if tracked == input then table.remove(s.touchOrder, i); break end end
			s.pinchDistance = if #s.touchOrder == 2 then (s.touches[s.touchOrder[1]] - s.touches[s.touchOrder[2]]).Magnitude else nil
			if #s.touchOrder == 0 then finish(Vector2.new(input.Position.X, input.Position.Y))
			else
				s.press, s.last, s.cancelTap, s.maxTravel = nil, s.touches[s.touchOrder[1]], true, SLOP + 1
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonR2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			s.zoomDirection = 0
		elseif input.KeyCode == Enum.KeyCode.Thumbstick1 then
			s.stick = Vector2.zero
		end
	end))
	-- Gamepad navigation is Roblox-specific: continuous stick pan and held
	-- trigger zoom at the viewport centre. Source TransformHandler still owns
	-- all camera maths and clamps.
	table.insert(s.connections, render:Connect(function(dt: number)
		local camera=renderer.camera
		if interrupted(if s.press then s.pointer or s.press else nil) then
			Input.cancel(s); return
		end
		if s.longPressAt ~= nil then
			if os.clock() - s.longPressAt >= LONG_PRESS_SECONDS and #s.touchOrder == 1 and s.press then
				s.longPressAt, s.contextActive, s.cancelTap = nil, true, true
				context(s.press)
			end
		end
		if s.stick.Magnitude > .15 then renderer:pan(s.stick.X * 540 * dt, -s.stick.Y * 540 * dt) end
		if s.zoomDirection ~= 0 then
			renderer:zoom(camera.left + camera.viewportWidth / 2, camera.top + camera.viewportHeight / 2,
				-s.zoomDirection * 360 * dt)
		end
	end))
	return s
end
function Input.destroy(s: any)
	if s.destroyed then return end
	s.destroyed = true
	Input.cancel(s)
	for _, c in s.connections do c:Disconnect() end
	table.clear(s.connections); table.clear(s.touches); table.clear(s.touchOrder)
end
return Input
