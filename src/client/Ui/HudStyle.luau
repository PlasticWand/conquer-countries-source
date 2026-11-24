--!strict
-- Style B (Bruno, 2026-11-24: "Let's go with B", then "build B for the match
-- and the menu ... as close as possible to the mock ups"): the dark windows'
-- look carried to the match HUD and the main menu. Dark panels with a 3 px
-- near-black edge, a header strip washed in the panel's colour (faint at the
-- left, strong at the right, like a window's banner), light Oswald words,
-- gold plates for the main actions and red share chips. The mock-ups are the
-- "Match HUD dark theme" canvas (B, and Main menu in style B).
-- A wash is a colour gradient on the surface itself (dark at one end, the
-- wash at the other), so it needs no overlay frame: nothing for a list
-- layout to place, and no doubled colour where rounded pieces overlap.

local Dossier = require(script.Parent.Dossier)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

local F = Theme.font

local HudStyle = {}

HudStyle.BG = Color3.fromHex("#0F1A14") -- a panel (Dossier.DARK)
HudStyle.EDGE = Color3.fromHex("#0B1218") -- its edge
HudStyle.INSET = Color3.fromHex("#1E2A24") -- tracks, idle chips
HudStyle.TILE = Color3.fromHex("#18251E") -- build slots
HudStyle.TEXT = Color3.new(1, 1, 1)
HudStyle.MUTED = Color3.fromHex("#9FB3A6")
HudStyle.SOFT = Color3.fromHex("#C8C2B0")
HudStyle.CHIP_TEXT = Color3.fromHex("#E8E2D0")
HudStyle.GOOD = Color3.fromHex("#7BE08A")
HudStyle.BAD = Color3.fromHex("#FF6B5A")
HudStyle.GOLD = Color3.fromHex("#FFD75E")
HudStyle.BROWN = Color3.fromHex("#3B2200") -- words on a gold plate
HudStyle.GOLD_TOP = Color3.fromHex("#FFE58A")
HudStyle.GOLD_BOTTOM = Color3.fromHex("#E6A817")

-- The panels' colours (the windows' banner colours).
HudStyle.WASH = {
	green = Color3.fromHex("#3E9A4E"),
	red = Color3.fromHex("#D8452B"),
	gold = Color3.fromHex("#E6A817"),
	yellow = Color3.fromHex("#FFC21A"),
	blue = Color3.fromHex("#3A78C2"),
	purple = Color3.fromHex("#8A4FE0"),
	teal = Color3.fromHex("#1F9A9A"),
	pink = Color3.fromHex("#D8457E"),
	orange = Color3.fromHex("#E06A1F"),
	ember = Color3.fromHex("#FF5A12"),
	slate = Color3.fromHex("#6A7E90"),
}

-- `wash` seen through the dark at strength `s` (0 = all dark, 1 = all wash).
function HudStyle.mix(wash: Color3, s: number, base: Color3?): Color3
	return (base or HudStyle.BG):Lerp(wash, s)
end

-- Words on a strip of `wash`, light.
function HudStyle.tintText(wash: Color3, amount: number?): Color3
	return wash:Lerp(Color3.new(1, 1, 1), amount or 0.7)
end

-- Washes `surface` (its BackgroundColor3 becomes white under a gradient):
-- strength `from` at the left to `to` at the right, with optional stops
-- { position, strength }. Returns the gradient.
function HudStyle.wash(surface: GuiObject, wash: Color3, from: number, to: number, stops: { { number } }?, base: Color3?): UIGradient
	surface.BackgroundColor3 = Color3.new(1, 1, 1)
	surface.BackgroundTransparency = 0
	local keys = { ColorSequenceKeypoint.new(0, HudStyle.mix(wash, from, base)) }
	if stops then
		for _, s in stops do
			table.insert(keys, ColorSequenceKeypoint.new(s[1], HudStyle.mix(wash, s[2], base)))
		end
	end
	table.insert(keys, ColorSequenceKeypoint.new(1, HudStyle.mix(wash, to, base)))
	local existing = surface:FindFirstChild("Wash")
	if existing and existing:IsA("UIGradient") then
		existing.Color = ColorSequence.new(keys)
		return existing
	end
	return Kit.new("UIGradient", { Name = "Wash", Color = ColorSequence.new(keys), Parent = surface }) :: UIGradient
end

-- A dark panel: `className` Frame, ImageButton or TextButton.
function HudStyle.panel(className: string, props: { [string]: any }, radius: number?): any
	local inst = Kit.new(className, Dossier.merge({ BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0 }, props))
	if className == "ImageButton" or className == "TextButton" then
		inst.AutoButtonColor = false
		if className == "TextButton" then
			inst.Text = ""
		end
	end
	Kit.corner(radius or 16).Parent = inst
	Kit.stroke(HudStyle.EDGE, 3, 0).Parent = inst
	return inst
end

-- The header strip along a panel's top, washed in `wash`, its caption on the
-- left (after an optional icon). Clipping doesn't follow a rounded corner,
-- so the strip rounds its own top corners and two squares, each the colour
-- of its end, square off the bottom ones.
local HEAD_FROM, HEAD_TO = 0.2, 0.85
local function paintHeader(strip: Frame, wash: Color3)
	HudStyle.wash(strip, wash, HEAD_FROM, HEAD_TO)
	for _, child in strip:GetChildren() do
		if child:IsA("Frame") and child.Name == "Corner" then
			child.BackgroundColor3 = HudStyle.mix(wash, if child.AnchorPoint.X > 0.5 then HEAD_TO else HEAD_FROM)
		end
	end
end
function HudStyle.header(panel: GuiObject, height: number, wash: Color3, radius: number, caption: string?, icon: string?, textSize: number?): Frame
	local strip = Kit.new("Frame", { Name = "Header", BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, height), Parent = panel }) :: Frame
	Kit.corner(radius).Parent = strip
	for _, side in { 0, 1 } do
		Kit.new("Frame", { Name = "Corner", BorderSizePixel = 0, AnchorPoint = Vector2.new(side, 1), Position = UDim2.fromScale(side, 1), Size = UDim2.fromOffset(radius, radius), Parent = strip })
	end
	paintHeader(strip, wash)
	local size = textSize or math.round(height * 0.46)
	local x = math.round(height * 0.4)
	if icon then
		Kit.glyph(icon, { Name = "Icon", ImageColor3 = HudStyle.TEXT, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, x, 0.5, 0), Size = UDim2.fromOffset(size, size), ZIndex = 2, Parent = strip })
		x += size + 6
	end
	if caption then
		Kit.label({ Name = "Caption", Text = caption, FontFace = F.labelSemibold, TextSize = size, TextColor3 = HudStyle.TEXT, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, x, 0.5, 0), ZIndex = 2, Parent = strip })
	end
	return strip
end

-- Recolours a header strip (the clock's, when protection ends).
function HudStyle.setHeaderWash(strip: Frame, wash: Color3)
	paintHeader(strip, wash)
end

-- A label on the right of a header strip.
function HudStyle.headerRight(strip: Frame, text: string, color: Color3?, textSize: number?, font: Font?): TextLabel
	local h = strip.Size.Y.Offset
	return Kit.label({ Name = "Right", Text = text, FontFace = font or F.labelSemibold, TextSize = textSize or math.round(h * 0.46), TextColor3 = color or HudStyle.TEXT, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -math.round(h * 0.4), 0.5, 0), ZIndex = 2, Parent = strip })
end

-- The gold plate (SHOP, JOIN, PLAY): a top-to-bottom gold gradient; its
-- words are dark brown.
function HudStyle.goldPlate(props: { [string]: any }, radius: number?): ImageButton
	local b = Kit.new("ImageButton", Dossier.merge({ AutoButtonColor = false, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Image = "" }, props)) :: ImageButton
	Kit.corner(radius or 16).Parent = b
	Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(HudStyle.GOLD_TOP, HudStyle.GOLD_BOTTOM), Parent = b })
	Kit.stroke(HudStyle.EDGE, 3, 0).Parent = b
	b.Activated:Connect(Dossier.click)
	return b
end

-- A square icon button tinted `tint` at the top, fading to the panel colour
-- (or to `hot`, for the bright ones: resume, leave).
function HudStyle.iconButton(name: string, tint: Color3, props: { [string]: any }, hot: Color3?): TextButton
	local b = Kit.new("TextButton", Dossier.merge({ Name = name, Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromOffset(46, 46) }, props)) :: TextButton
	Kit.corner(13).Parent = b
	Kit.stroke(HudStyle.EDGE, 3, 0).Parent = b
	local bottom = hot or HudStyle.BG
	local grad = Kit.new("UIGradient", { Rotation = 70, Color = ColorSequence.new(tint, bottom), Parent = b }) :: UIGradient
	Kit.glyph(name, { Name = "Icon", ImageColor3 = if hot then HudStyle.TEXT else HudStyle.CHIP_TEXT, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(24, 24), Parent = b })
	b.MouseEnter:Connect(function()
		if Kit.covered(b) then
			return
		end
		grad.Color = ColorSequence.new(tint:Lerp(Color3.new(1, 1, 1), 0.15), bottom:Lerp(Color3.new(1, 1, 1), 0.08))
	end)
	b.MouseLeave:Connect(function()
		grad.Color = ColorSequence.new(tint, bottom)
	end)
	b.Activated:Connect(function()
		if Kit.onActivated then
			Kit.onActivated()
		end
	end)
	return b
end

-- An attack-share chip: red with a pale edge when chosen, else a dark inset.
-- Placed by its centre, like Dossier.rivetPlate, and returns the same pair.
local CHIP_ON = ColorSequence.new(Color3.fromHex("#F0624A"), Color3.fromHex("#B8301C"))
function HudStyle.chip(parent: Instance, text: string, textSize: number, on: boolean, props: { [string]: any }): (ImageButton, (boolean) -> ())
	local b = Kit.new("ImageButton", Dossier.merge({ AutoButtonColor = false, BorderSizePixel = 0, Image = "", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = HudStyle.INSET }, props)) :: ImageButton
	Kit.corner(10).Parent = b
	local grad = Kit.new("UIGradient", { Rotation = 90, Enabled = false, Color = CHIP_ON, Parent = b }) :: UIGradient
	local edge = Kit.stroke(Color3.fromHex("#FFB4A6"), 2, 0)
	edge.Parent = b
	local label = Kit.label({ Name = "Label", Text = text, FontFace = F.labelSemibold, TextSize = textSize, TextColor3 = HudStyle.CHIP_TEXT, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Parent = b })
	local function setOn(value: boolean)
		b.BackgroundColor3 = if value then Color3.new(1, 1, 1) else HudStyle.INSET
		grad.Enabled = value
		edge.Enabled = value
		label.FontFace = if value then F.labelBold else F.labelSemibold
		label.TextColor3 = if value then HudStyle.TEXT else HudStyle.CHIP_TEXT
	end
	setOn(on)
	b.Activated:Connect(Dossier.click)
	Dossier.clicky(b, 1.05)
	b.Parent = props.Parent
	return b, setOn
end

return HudStyle
