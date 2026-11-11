--!strict
-- Ported from RoWorld 2be8efb (src/client/UI/TitleScreen.luau, the queue card), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- The waiting room on a public match's own server (Bruno, 2026-11-04: the
-- second menu after JOIN looked like being moved to another menu server). In
-- the dossier look: the lobby's field map fills the desk behind, the map's
-- name on a torn paper strip, the countdown in hazard yellow, who is here on
-- a pinned note, and LEAVE. After the match it says it is taking you back to
-- the lobby (with BACK TO LOBBY if the teleport hasn't happened after a
-- while). The words come from Shared/WaitingRoom; this only lays them out.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapCatalog = require(Shared.MapCatalog)
local Model = require(Shared.WaitingRoom)

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local MainMenu = require(script.Parent.MainMenu)

local C = Theme.color

local WaitingRoom = {}
WaitingRoom.__index = WaitingRoom

export type Actions = {
	leave: () -> (),
	retry: () -> (),
}

-- The box is laid out in phone canvas units (540 tall) and grown on desktop.
local BOX_W, BOX_H = 860, 470
local DESKTOP_GROW = 1.55

local function folderOf(mapType: string?): string?
	if mapType == nil then
		return nil
	end
	for _, e in MapCatalog.all() do
		if e.type == mapType then
			return e.folder
		end
	end
	return nil
end

function WaitingRoom.new(host: Frame, root: any, actions: Actions)
	local frame = Kit.new("Frame", { Name = "WaitingRoom", BackgroundColor3 = C.desk, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 30, Visible = false, Parent = host })
	-- Swallow clicks so the menu under it never reacts.
	Kit.new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 30, AutoButtonColor = false, Parent = frame })
	local mapHolder = Kit.new("Frame", { Name = "Map", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 30, Parent = frame })
	Kit.new("Frame", { Name = "Shade", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 31, Parent = frame })

	local box = Kit.new("Frame", { Name = "Box", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(BOX_W, BOX_H), ZIndex = 32, Parent = frame })
	local grow = Kit.new("UIScale", { Parent = box }) :: UIScale

	-- The map's name on the torn paper strip, the kind of match above it.
	local strip = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Name = "Title", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(BOX_W, 132), ZIndex = 32, Parent = box })
	Dossier.art("star_stamp", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -70, 0.5, 0), Size = UDim2.fromOffset(84, 84), ImageTransparency = 0.72, Rotation = -10, ZIndex = 32, Parent = strip })
	local kicker = Dossier.typed({ Text = "", TextColor3 = C.stamp, TextSize = 20, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 22), ZIndex = 33, Parent = strip })
	local title = Dossier.stencil({ Text = "", TextSize = 54, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 12), ZIndex = 33, Parent = strip })

	-- The countdown.
	local status = Dossier.typed({ Text = "", TextColor3 = C.sheet, TextSize = 24, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0, BOX_W / 2, 0, 148), ZIndex = 32, Parent = box })
	local clock = Dossier.stencil({ Text = "", TextColor3 = C.hazard, TextSize = 76, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0, BOX_W / 2, 0, 178), ZIndex = 32, Parent = box })

	-- Who is here, on a pinned note.
	local note = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { Name = "Players", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0, BOX_W / 2, 0, 272), Size = UDim2.fromOffset(700, 96), Rotation = -0.6, ZIndex = 32, Parent = box })
	Kit.stroke(C.sheetLine, 1.5, 0).Parent = note
	Dossier.art("pin", { AnchorPoint = Vector2.new(0.5, 0.75), Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.fromOffset(20, 28), ZIndex = 34, Parent = note })
	local count = Dossier.stencil({ Text = "", TextSize = 28, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), ZIndex = 33, Parent = note })
	local names = Dossier.typed({ Text = "", TextColor3 = C.inkBlack, TextSize = 19, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 50), Size = UDim2.new(1, -40, 0, 40), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 33, Parent = note })

	-- LEAVE (before the match) or BACK TO LOBBY (a return teleport that hasn't
	-- happened): one plate, at least 44 px tall on a phone.
	local button = Dossier.rivetPlate(box, "LEAVE", 26, false, { Name = "Leave", Position = UDim2.new(0, BOX_W / 2, 0, 420), Size = UDim2.fromOffset(240, 64), ZIndex = 33, Parent = box })
	local buttonLabel = button:FindFirstChild("Label") :: TextLabel?
	for _, d in button:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = 34
		end
	end
	local small = Dossier.typed({ Text = "", TextSize = 16, TextColor3 = C.sheetLine, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -14), ZIndex = 32, Parent = frame })

	local self = setmetatable({
		frame = frame,
		root = root,
		mapHolder = mapHolder,
		mapFor = nil :: string?,
		grow = grow,
		kicker = kicker,
		title = title,
		status = status,
		clock = clock,
		note = note,
		count = count,
		names = names,
		button = button,
		buttonLabel = buttonLabel,
		small = small,
		room = nil :: Model.Room?,
		roomAt = os.clock(),
		returningAt = nil :: number?,
		connections = {} :: { RBXScriptConnection },
		paintAt = 0,
	}, WaitingRoom)

	table.insert(self.connections, button.Activated:Connect(function()
		if self.returningAt then
			self.returningAt = os.clock() -- the retry restarts the wait
			actions.retry()
		elseif self.room ~= nil or self.frame.Visible then
			actions.leave()
		end
	end))
	local function layout()
		grow.Scale = if root.compact then 1 else DESKTOP_GROW
	end
	layout()
	if root.Changed then
		table.insert(self.connections, root.Changed.Event:Connect(layout))
	end
	table.insert(self.connections, RunService.Heartbeat:Connect(function()
		if frame.Visible and os.clock() - self.paintAt >= 0.2 then
			self:_paint()
		end
	end))
	return self
end

function WaitingRoom._setMap(self: any, mapType: string?)
	local folder = folderOf(mapType)
	if folder == self.mapFor then
		return
	end
	self.mapFor = folder
	for _, c in self.mapHolder:GetChildren() do
		c:Destroy()
	end
	if folder then
		MainMenu.fieldMap(folder, { Size = UDim2.fromScale(1, 1), ZIndex = 30, Parent = self.mapHolder })
	end
end

function WaitingRoom._paint(self: any)
	self.paintAt = os.clock()
	local v = if self.returningAt
		then Model.returning(os.clock() - self.returningAt)
		else Model.view(self.room, os.clock() - self.roomAt)
	self.kicker.Text = v.kicker
	self.title.Text = v.title
	self.status.Text = v.status
	self.clock.Text = v.clock or ""
	self.clock.Visible = v.clock ~= nil
	self.count.Text = v.count
	self.names.Text = v.names
	self.note.Visible = v.count ~= ""
	self.small.Text = v.note
	self.button.Visible = v.leave or v.retry
	if self.buttonLabel then
		self.buttonLabel.Text = if v.retry then "BACK TO LOBBY" else "LEAVE"
	end
	self.button.Size = UDim2.fromOffset(if v.retry then 320 else 240, 64)
end

-- The server's room (nil fields: the lobby isn't found yet).
function WaitingRoom.setRoom(self: any, room: Model.Room?)
	local old = self.room
	if room and room.mapName and old and old.seconds and room.seconds then
		-- (never back up a second for jitter: Model.smooth)
		local predicted = math.max(0, old.seconds - (os.clock() - self.roomAt))
		local smoothed = Model.smooth(predicted, room.seconds)
		if smoothed ~= room.seconds then
			room = table.clone(room :: any)
			room.seconds = smoothed
		end
	end
	self.room = if room and room.mapName then room else nil
	self.roomAt = os.clock()
	self:_setMap(if room then (room :: any).mapType else nil)
	self:_paint()
end

-- The return teleport has begun.
function WaitingRoom.setReturning(self: any)
	if self.returningAt == nil then
		self.returningAt = os.clock()
	end
	self:_paint()
end

function WaitingRoom.isReturning(self: any): boolean
	return self.returningAt ~= nil
end

function WaitingRoom.setVisible(self: any, visible: boolean)
	self.frame.Visible = visible
	if visible then
		self:_paint()
	end
end

function WaitingRoom.destroy(self: any)
	for _, c in self.connections do
		c:Disconnect()
	end
	self.frame:Destroy()
end

return WaitingRoom
