--!strict
-- The loading cover for a match (docs/design/rofront-ui-pass.md, instant
-- map), in the dossier look (2026-10-27): the dark desk, the map's name on a
-- torn paper strip, a hazard-yellow progress bar in a dark slot, and a tip
-- typed on a note. Full screen over the map while the renderer paints the
-- whole map (firstPaint = "full"); removed on the renderer's onReady, so the
-- first frame the player sees has terrain, territories, borders and names.

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)

local C = Theme.color

local Loading = {}
Loading.__index = Loading

local TIP_SIZE, TIP_MIN = 20, 12

local TIPS = {
	"Tip: the attack bar sets the share of your troops each click sends.",
	"Tip: right-click any land for the action menu.",
	"Tip: cities raise your troop limit; ports and factories earn gold.",
	"Tip: a Defense Post makes attacks on nearby land slow and costly.",
	"Tip: allies can't attack each other. Breaking an alliance makes you a traitor.",
}

function Loading.new(host: Frame)
	local frame = Kit.new("Frame", { Name = "Loading", BackgroundColor3 = C.desk, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 40, Visible = false, Parent = host })
	-- Swallow clicks so nothing under the cover reacts.
	Kit.new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 40, AutoButtonColor = false, Parent = frame })
	local box = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(820, 360), ZIndex = 41, Parent = frame })
	local strip = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Name = "Title", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(820, 150), ZIndex = 41, Parent = box })
	Dossier.art("star_stamp", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -80, 0.5, 0), Size = UDim2.fromOffset(100, 100), ImageTransparency = 0.72, Rotation = -10, ZIndex = 41, Parent = strip })
	local title = Dossier.stencil({ Text = "", TextSize = 66, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -10), ZIndex = 41, Parent = strip })
	-- (10 higher than at first, off the strip's torn edge: Bruno, 2026-11-11.)
	local sub = Dossier.typed({ Text = "Preparing the map", TextColor3 = C.inkBlack, TextSize = 22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 1, -40), ZIndex = 41, Parent = strip })
	-- The progress bar: a dark slot with a hazard-yellow fill.
	local track = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#2E2F24"), BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 186), Size = UDim2.fromOffset(640, 30), ZIndex = 41, Parent = box })
	Kit.corner(4).Parent = track
	Kit.stroke(Color3.fromHex("#14150F"), 2, 0).Parent = track
	local fill = Kit.new("Frame", { BackgroundColor3 = C.hazard, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 42, Parent = track })
	Kit.corner(4).Parent = fill
	local note = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 250), Size = UDim2.fromOffset(760, 64), Rotation = -0.6, ZIndex = 41, Parent = box })
	Kit.stroke(C.sheetLine, 1.5, 0).Parent = note
	-- One line, inside the note's edges: a long tip types smaller (Bruno,
	-- 2026-11-11: long ones ran under the note's sides).
	local tip = Dossier.typed({ Text = "", TextColor3 = C.inkBlack, TextSize = TIP_SIZE, TextWrapped = false, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(1, -48, 1, 0), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 41, Parent = note })
	local function fit()
		local size = TIP_SIZE
		tip.TextSize = size
		while size > TIP_MIN and tip.AbsoluteSize.X > 0 and tip.TextBounds.X > tip.AbsoluteSize.X do
			size -= 1
			tip.TextSize = size
		end
	end
	-- (Again once the font has loaded or the screen's size changes.)
	tip:GetPropertyChangedSignal("Text"):Connect(fit)
	tip:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	tip:GetPropertyChangedSignal("TextBounds"):Connect(function()
		if tip.TextBounds.X > tip.AbsoluteSize.X and tip.TextSize > TIP_MIN then
			fit()
		end
	end)
	Dossier.typed({ Text = "Fork of OpenFront  ·  © OpenFront and Contributors", TextSize = 16, TextColor3 = C.sheetLine, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16), ZIndex = 41, Parent = frame })
	return setmetatable({ frame = frame, title = title, sub = sub, fill = fill, tip = tip, shownAt = 0 }, Loading)
end

function Loading.show(self: any, mapName: string)
	self.title.Text = string.upper(mapName)
	self.fill.Size = UDim2.fromScale(0, 1)
	self.tip.Text = TIPS[math.random(1, #TIPS)]
	self.frame.Visible = true
	self.shownAt = os.clock()
end

function Loading.setProgress(self: any, fraction: number)
	self.fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
end

function Loading.hide(self: any)
	self.frame.Visible = false
end

function Loading.isShown(self: any): boolean
	return self.frame.Visible
end

return Loading
