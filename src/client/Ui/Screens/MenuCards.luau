--!strict
-- The main menu's two feature cards, General and Campaign (Bruno,
-- 2026-11-23: option A "Framed photos", in the SOLO DEPLOYMENT stamp's
-- place): a brass frame around a strong colour (gold for General, royal
-- purple for Campaign), the picture as a tilted photo, a kicker tag, the
-- title, one live line, and a light that sweeps across. Campaign adds the
-- XP bar and a red count of rewards waiting. `wide` lays the photo at the
-- left (desktop); otherwise the photo sits on top (a phone's narrow tile).

local RunService = game:GetService("RunService")

local Dossier = require(script.Parent.Parent.Dossier)
local HudStyle = require(script.Parent.Parent.HudStyle)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)

local C = Theme.color
local F = Theme.font
local stencil = Dossier.stencil
local typed = Dossier.typed

local MenuCards = {}

export type Spec = {
	name: string,
	title: string,
	colors: { Color3 }, -- dark, mid, light
	kickInk: Color3,
	kickFill: Color3,
	picture: (holder: Frame) -> (),
	onPress: () -> (),
	-- Style B (Bruno, 2026-11-24): a dark card over a banner photo, washed
	-- in `wash` toward the right, the picture framed in it at the left.
	wash: Color3?,
	photo: string?, -- a UiAssets.dossier name
}

export type Card = {
	root: TextButton,
	setKicker: (string) -> (),
	setLine: (string) -> (),
	setBar: (number?) -> (), -- 0..1, nil hides it
	setCount: (number) -> (), -- the red count; 0 hides it
	destroy: () -> (),
}

local BRASS = Color3.fromHex("#D9B25A")

function MenuCards.card(parent: Instance, spec: Spec, size: Vector2, wide: boolean, props: { [string]: any }): Card
	local s = math.min(size.X / 230, size.Y / 84) -- 1 = the desktop reference card
	if not wide then
		s = size.X / 120
	end
	local function px(n: number): number
		return math.round(n * s)
	end
	local root = Kit.new("TextButton", { Name = spec.name, Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(size.X, size.Y), ClipsDescendants = false, Parent = parent }) :: TextButton
	for k, v in props do
		(root :: any)[k] = v
	end
	local z = root.ZIndex
	local wash = spec.wash
	local radius = if wash then px(11) else px(9)
	Kit.corner(radius).Parent = root
	if wash then
		root.BackgroundColor3 = HudStyle.BG
		Kit.stroke(HudStyle.EDGE, math.max(2, px(2.2)), 0).Parent = root
		local image = if spec.photo then UiAssets.dossier[spec.photo] else nil
		if image and image ~= "" then
			local pic = Kit.new("ImageLabel", { Name = "Banner", BackgroundTransparency = 1, Image = image, ScaleType = Enum.ScaleType.Crop, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = root })
			Kit.corner(radius).Parent = pic
		end
		local veil = Kit.new("Frame", { Name = "Wash", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = root })
		Kit.corner(radius).Parent = veil
		local dark = Color3.fromHex("#0C120E")
		Kit.new("UIGradient", {
			Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, dark), ColorSequenceKeypoint.new(0.45, dark), ColorSequenceKeypoint.new(1, wash) }),
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(0.45, 0.45), NumberSequenceKeypoint.new(1, 0.4) }),
			Parent = veil,
		})
	else
		Kit.new("UIGradient", { Rotation = 30, Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, spec.colors[1]), ColorSequenceKeypoint.new(0.55, spec.colors[2]), ColorSequenceKeypoint.new(1, spec.colors[3]) }), Parent = root })
		Kit.stroke(BRASS, math.max(2, px(4)), 0).Parent = root
		-- An inner dark line inside the brass, like the mockup's double frame.
		local inner = Kit.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(px(3), px(3)), Size = UDim2.new(1, -px(6), 1, -px(6)), ZIndex = z, Parent = root })
		Kit.corner(px(7)).Parent = inner
		Kit.stroke(spec.colors[1], math.max(1, px(1.5)), 0.2).Parent = inner
	end

	-- The photo, tilted, in a paper border.
	local photo = Kit.new("Frame", { Name = "Photo", BackgroundColor3 = Color3.fromHex("#F7F1E3"), BorderSizePixel = 0, ZIndex = z + 1, Parent = root })
	if wash then
		-- Framed square in the card's colour, upright (style B).
		photo.BackgroundColor3 = wash:Lerp(Color3.new(1, 1, 1), 0.25)
		Kit.corner(px(6)).Parent = photo
		if wide then
			photo.Position = UDim2.fromOffset(px(10), px(10))
			photo.Size = UDim2.new(0, px(80), 1, -px(20))
		else
			photo.AnchorPoint = Vector2.new(0.5, 0)
			photo.Position = UDim2.new(0.5, 0, 0, px(8))
			photo.Size = UDim2.new(1, -px(22), 0.42, 0)
		end
	elseif wide then
		photo.Position = UDim2.fromOffset(px(8), px(8))
		photo.Size = UDim2.new(0, px(82), 1, -px(16))
		photo.Rotation = -2.5
	else
		photo.AnchorPoint = Vector2.new(0.5, 0)
		photo.Position = UDim2.new(0.5, 0, 0, px(8))
		photo.Size = UDim2.new(1, -px(22), 0.42, 0)
		photo.Rotation = -2
	end
	local inset = if wash then px(2) else px(3)
	local holder = Kit.new("Frame", { BackgroundColor3 = spec.colors[1], BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.fromOffset(inset, inset), Size = UDim2.new(1, -2 * inset, 1, -2 * inset), ZIndex = z + 1, Parent = photo })
	if wash then
		Kit.corner(px(5)).Parent = holder
	end
	spec.picture(holder)
	for _, d in holder:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = z + 1
		end
	end

	-- The words.
	local text = Kit.new("Frame", { Name = "Words", BackgroundTransparency = 1, ZIndex = z + 2, Parent = root })
	if wide then
		text.Position = UDim2.fromOffset(px(98), px(8))
		text.Size = UDim2.new(1, -px(106), 1, -px(14))
	else
		text.Position = UDim2.new(0, px(8), 0.42, px(10))
		text.Size = UDim2.new(1, -px(16), 0.58, -px(14))
	end
	local kick = Kit.new("Frame", { BackgroundColor3 = spec.kickFill, BackgroundTransparency = if wash then 1 else 0, BorderSizePixel = 0, AutomaticSize = Enum.AutomaticSize.XY, ZIndex = z + 2, Parent = text })
	Kit.corner(px(3)).Parent = kick
	Kit.padding(px(2), if wash then 0 else px(5)).Parent = kick
	local kickText = typed({ Text = "", TextSize = px(if wide then 11 else 10), TextColor3 = if wash then wash:Lerp(Color3.new(1, 1, 1), 0.55) else spec.kickInk, ZIndex = z + 2, Parent = kick })
	if wash then
		kickText.FontFace = F.labelSemibold
	end
	local title = stencil({ Text = spec.title, TextSize = px(if wide then 34 else 22), TextColor3 = Color3.new(1, 1, 1), Position = UDim2.fromOffset(0, px(if wide then 15 else 12)), ZIndex = z + 2, Parent = text })
	Kit.new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = math.max(1, px(1.2)), Transparency = 0.45, Parent = title })
	local line = Kit.new("TextLabel", { BackgroundTransparency = 1, Text = "", FontFace = F.bodyBold, TextSize = px(if wide then 13 else 11), TextColor3 = if wash then Color3.fromHex("#F1E8CF") else Color3.fromHex("#FFF6E0"), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(0, px(if wide then 50 else 40)), Size = UDim2.new(1, 0, 0, px(15)), Visible = wide, ZIndex = z + 2, Parent = text })
	local barBack = Kit.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.55, BorderSizePixel = 0, Position = UDim2.fromOffset(0, px(if wide then 66 else 34)), Size = UDim2.new(1, -px(4), 0, px(7)), Visible = false, ZIndex = z + 2, Parent = text })
	Kit.corner(px(4)).Parent = barBack
	local barFill = Kit.new("Frame", { BackgroundColor3 = if wash then Color3.fromHex("#FFB21A") else Color3.fromHex("#FFD75E"), BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = z + 2, Parent = barBack })
	Kit.corner(px(4)).Parent = barFill
	local dot = Kit.new("Frame", { Name = "Count", BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -px(4), 0, px(4)), Size = UDim2.fromOffset(px(22), px(22)), Visible = false, ZIndex = z + 4, Parent = root })
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
	Kit.stroke(Color3.new(1, 1, 1), math.max(1, px(1.5)), 0.2).Parent = dot
	local count = stencil({ Text = "", TextSize = px(14), TextColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = z + 4, Parent = dot })

	-- The light that sweeps across every 3.8 s.
	local shine = Kit.new("Frame", { Name = "Shine", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = z + 3, Parent = root })
	Kit.corner(radius).Parent = shine
	local sweep = Kit.new("UIGradient", {
		Rotation = 20,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.42, 1),
			NumberSequenceKeypoint.new(0.5, 0.7),
			NumberSequenceKeypoint.new(0.58, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Offset = Vector2.new(-1, 0),
		Parent = shine,
	}) :: UIGradient
	local t0 = os.clock()
	local conn = RunService.Heartbeat:Connect(function()
		local t = (os.clock() - t0) % 3.8
		sweep.Offset = Vector2.new(if t < 1.2 then -1 + t / 0.6 else 1, 0)
	end)
	root.Destroying:Connect(function()
		conn:Disconnect()
	end)

	Dossier.clicky(root, 1.04)
	root.Activated:Connect(function()
		Dossier.click()
		spec.onPress()
	end)

	return {
		root = root,
		setKicker = function(v: string)
			kickText.Text = v
		end,
		setLine = function(v: string)
			line.Text = v
		end,
		setBar = function(v: number?)
			barBack.Visible = v ~= nil
			barFill.Size = UDim2.fromScale(math.clamp(v or 0, 0, 1), 1)
		end,
		setCount = function(n: number)
			dot.Visible = n > 0
			count.Text = tostring(n)
		end,
		destroy = function()
			root:Destroy()
		end,
	}
end

return MenuCards
