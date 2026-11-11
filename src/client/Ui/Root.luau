--!strict
-- The screen root for the 2026-10-24 screens: one ScreenGui laid out on a
-- 1920x1080 canvas and scaled uniformly to the screen (min of width and height
-- ratios, times the player's UI size setting). Layers, back to front:
--   Menu   the main menu and its cards
--   Match  the in-match HUD
--   Modal  dialogs (Kit.modal) over either
--   Tip    the shared tooltip
-- `topLeft` is the canvas x where our top-left icon row may start: right of
-- Roblox's own buttons (GuiService.TopbarInset), so the row never covers them.
--
-- Phones (Bruno, 2026-10-27): landscape only, and a viewport whose shorter
-- side is under PHONE_H px is `compact`: the canvas is Theme.COMPACT_H units tall instead (about
-- twice the size on screen), screens use their phone layouts, and the UI
-- keeps out of the notch and home bar (DeviceSafeInsets; a desk-coloured
-- backdrop fills behind). `width` x `height` is the canvas in units.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

local Root = {}
Root.__index = Root

export type Root = {
	gui: ScreenGui,
	scale: UIScale,
	menu: Frame,
	match: Frame,
	modal: Frame,
	tip: Frame,
	userScale: number,
	topLeft: number,
	compact: boolean,
	width: number,
	height: number,
	connections: { RBXScriptConnection },
	Changed: BindableEvent,
}

local MIN_SCALE = 0.55
local PHONE_H = 540

function Root.new(): any
	local gui = Kit.new("ScreenGui", {
		Name = "ConquestUi",
		ResetOnSpawn = false,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10,
	}) :: ScreenGui
	-- Behind the safe area's edges (the notch side, the home bar).
	local backdrop = Kit.new("ScreenGui", { Name = "ConquestBackdrop", ResetOnSpawn = false, ScreenInsets = Enum.ScreenInsets.None, DisplayOrder = -1 }) :: ScreenGui
	Kit.new("Frame", { BackgroundColor3 = Theme.color.desk, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = backdrop })
	local scale = Kit.new("UIScale", { Parent = gui }) :: UIScale
	local function layer(name: string, z: number): Frame
		return Kit.new("Frame", { Name = name, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = gui })
	end
	local self = setmetatable({
		gui = gui,
		scale = scale,
		menu = layer("Menu", 1),
		match = layer("Match", 2),
		modal = layer("Modal", 3),
		tip = layer("Tip", 4),
		userScale = 1,
		topLeft = 72,
		compact = false,
		width = Theme.CANVAS_W,
		height = Theme.CANVAS_H,
		backdrop = backdrop,
		connections = {},
		Changed = Instance.new("BindableEvent"),
	}, Root) :: any
	self.match.Visible = false
	Kit.tipLayer = self.tip
	Kit.tipScale = scale
	Kit.root = self
	local function rescale()
		local view = if Workspace.CurrentCamera then Workspace.CurrentCamera.ViewportSize else Vector2.new(1920, 1080)
		-- The safe area, once the gui has one.
		local area = if gui.AbsoluteSize.Y > 0 then gui.AbsoluteSize else view
		-- A phone either way up (it may start upright before the landscape
		-- lock turns it); a viewport not laid out yet keeps the last answer.
		if view.X > 50 and view.Y > 50 then
			self.compact = math.min(view.X, view.Y) < PHONE_H
		end
		if self.compact then
			-- By the shorter side, so an upright start isn't drawn huge.
			scale.Scale = math.min(area.X, area.Y) / Theme.COMPACT_H * self.userScale
		else
			local s = math.min(area.X / Theme.CANVAS_W, area.Y / Theme.CANVAS_H) * self.userScale
			scale.Scale = math.max(MIN_SCALE, s)
		end
		self.width, self.height = area.X / scale.Scale, area.Y / scale.Scale
		local inset = GuiService.TopbarInset
		-- Roblox's buttons end at inset.Min.X (screen pixels); leave a gap.
		self.topLeft = math.max(16, (inset.Min.X - gui.AbsolutePosition.X + 8) / scale.Scale)
		self.Changed:Fire()
	end
	rescale()
	if Workspace.CurrentCamera then
		table.insert(self.connections, Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale))
	end
	table.insert(self.connections, GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(rescale))
	table.insert(self.connections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale))
	self.rescale = rescale
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	-- Landscape only, either way up. StarterGui holds the same value (the Rojo
	-- project and the place), which covers loading and arriving on a new server
	-- before this runs.
	playerGui.ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor
	backdrop.Parent = playerGui
	gui.Parent = playerGui
	rescale()
	return self
end

-- The player's UI size setting (0.8 .. 1.25).
function Root.setUserScale(self: any, value: number)
	self.userScale = math.clamp(value, 0.8, 1.25)
	self.rescale()
end

-- Shows the menu or the match HUD.
function Root.showMatch(self: any, inMatch: boolean)
	self.menu.Visible = not inMatch
	self.match.Visible = inMatch
	-- The map fills a match's screen, and the map's input treats anything
	-- drawn over it as UI in the way.
	self.backdrop.Enabled = not inMatch
end

function Root.destroy(self: any)
	for _, c in self.connections do
		c:Disconnect()
	end
	self.Changed:Destroy()
	self.gui:Destroy()
	self.backdrop:Destroy()
end

return Root
