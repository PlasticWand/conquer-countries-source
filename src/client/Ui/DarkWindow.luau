--!strict
-- The dark window (Bruno, 2026-11-23: "Can we do all the windows in that
-- style?", after the Campaign Pass): a dark body under a banner header (a
-- picture washed in the window's colour, a kicker, the title, a subtitle,
-- a right-hand area for live numbers), the red X in the corner, centred on
-- a dimmed screen. Returns a Dossier.Window, so callers lay out with
-- `at`/`sz` in reference units: desktop 1240 x 720 scaled to the screen,
-- a phone its full canvas at k = 1. `bannerH` is in those units.

local Dossier = require(script.Parent.Dossier)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local UiAssets = require(script.Parent.UiAssets)

local C = Theme.color
local F = Theme.font
local stencil = Dossier.stencil
local typed = Dossier.typed

local DarkWindow = {}

DarkWindow.BG = Color3.fromHex("#0F1A14")
DarkWindow.STRIP = Color3.fromHex("#0A120E")
DarkWindow.GOLD = Color3.fromHex("#FFD75E")

export type Spec = {
	title: string, -- "\n" for two lines
	kicker: string?,
	subtitle: string?,
	art: string?, -- UiAssets.dossier name (a banner, or a photo cropped to fit)
	wash: Color3, -- the banner's colour, strongest at the right
	bannerH: number?,
	titleSize: number?,
	onClose: (() -> ())?,
}

export type Dark = Dossier.Window & {
	banner: Frame,
	right: Frame, -- the banner's right area (above the X's row, clear of it)
	subtitle: TextLabel?,
	kicker: TextLabel?,
	bannerH: number,
}

function DarkWindow.open(host: Instance, spec: Spec): Dark
	local r = Kit.root
	local phone = Dossier.phone()
	local refW, refH, k
	if phone then
		refW, refH, k = math.floor(r.width * 0.99), math.floor(r.height * 0.98), 1
	else
		refW, refH = 1240, 720
		k = math.min(r.width * 0.84 / refW, r.height * 0.86 / refH)
	end
	local function at(x: number, y: number): UDim2
		return UDim2.fromOffset(math.round(x * k), math.round(y * k))
	end
	local function sz(w: number, h: number): UDim2
		return UDim2.fromOffset(math.round(w * k), math.round(h * k))
	end
	local function ts(n: number): number
		return math.round(n * k)
	end
	Kit.hideTip()
	local root = Kit.new("Frame", { Name = "Modal", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = host }) :: Frame
	Kit.new("TextButton", { Name = "Scrim", Text = "", AutoButtonColor = false, BackgroundColor3 = C.desk, BackgroundTransparency = 0.25, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = root })
	local window = Kit.new("Frame", { Name = "Window", BackgroundColor3 = DarkWindow.BG, BorderSizePixel = 0, ClipsDescendants = true, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz(refW, refH), Parent = root }) :: Frame
	Kit.corner(ts(16)).Parent = window
	local edge = Kit.new("Frame", { Name = "Edge", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz(refW, refH), ZIndex = 20, Parent = root })
	Kit.corner(ts(16)).Parent = edge
	Kit.stroke(Color3.fromHex("#0B1218"), math.max(3, ts(6)), 0).Parent = edge
	local body = Kit.new("Frame", { Name = "Body", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = window }) :: Frame
	local header = Kit.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = window }) :: Frame
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		Kit.hideTip()
		root:Destroy()
		if spec.onClose then
			spec.onClose()
		end
	end

	-- The banner: the picture, washed in the window's colour toward the
	-- right and dark toward the left, fading into the body at its foot.
	local bannerH = spec.bannerH or 200
	local banner = Kit.new("Frame", { Name = "Banner", BackgroundColor3 = spec.wash:Lerp(Color3.new(0, 0, 0), 0.75), BorderSizePixel = 0, ClipsDescendants = true, Size = sz(refW, bannerH), Parent = body }) :: Frame
	local image = if spec.art then UiAssets.dossier[spec.art] else nil
	if image and image ~= "" then
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = image, ScaleType = Enum.ScaleType.Crop, Size = UDim2.fromScale(1, 1), Parent = banner })
	end
	local wash = Kit.new("Frame", { BackgroundColor3 = spec.wash, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = banner })
	Kit.new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.85), NumberSequenceKeypoint.new(0.5, 0.45), NumberSequenceKeypoint.new(1, 0.35) }), Parent = wash })
	local shade = Kit.new("Frame", { BackgroundColor3 = spec.wash:Lerp(Color3.new(0, 0, 0), 0.9), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = banner })
	Kit.new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(0.5, 0.6), NumberSequenceKeypoint.new(1, 1) }), Parent = shade })
	local foot = Kit.new("Frame", { BackgroundColor3 = DarkWindow.BG, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = banner })
	Kit.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.6, 1), NumberSequenceKeypoint.new(1, 0) }), Parent = foot })

	local y = 22
	local kicker: TextLabel? = nil
	if spec.kicker then
		-- (On a phone it starts right of Roblox's buttons, which sat over it.)
		local kx = if phone then math.max(32, r.topLeft + 10) else 32
		kicker = typed({ Text = spec.kicker, TextSize = ts(20), TextColor3 = spec.wash:Lerp(Color3.new(1, 1, 1), 0.55), Position = at(kx, y), ZIndex = 3, Parent = banner })
		y += 30
	end
	local lines = #string.split(spec.title, "\n")
	local tsize = spec.titleSize or (if lines > 1 then 70 else 76)
	local title = stencil({ Text = spec.title, TextSize = ts(tsize), LineHeight = 0.82, TextColor3 = Color3.new(1, 1, 1), Position = at(28, y), ZIndex = 3, Parent = banner })
	Kit.new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = math.max(1, ts(2.5)), Transparency = 0.45, Parent = title })
	local subtitle: TextLabel? = nil
	if spec.subtitle then
		local sub = Kit.new("TextLabel", { BackgroundTransparency = 1, Text = spec.subtitle, FontFace = F.bodyBold, TextSize = ts(19), TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = at(32, y + tsize * 0.86 * lines + 6), Size = sz(refW * 0.55, 24), ZIndex = 3, Parent = banner })
		Kit.new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1, Transparency = 0.5, Parent = sub })
		subtitle = sub
	end
	-- The right area: from the middle to the X.
	local right = Kit.new("Frame", { Name = "Right", BackgroundTransparency = 1, Position = at(refW * 0.5, 14), Size = sz(refW * 0.5 - 96, bannerH - 28), ZIndex = 3, Parent = banner }) :: Frame
	Dossier.closeRed(header, at(refW - 40, 40), sz(56, 56), close)

	return {
		root = root,
		window = window,
		header = header,
		body = body,
		close = close,
		at = at,
		sz = sz,
		k = k,
		width = refW,
		height = refH,
		banner = banner,
		right = right,
		kicker = kicker,
		subtitle = subtitle,
		bannerH = bannerH,
	} :: any
end

-- A gradient tile face for the dark windows: `colors` light (top) to dark,
-- an optional glow edge. Fills `parent`.
function DarkWindow.tile(parent: Instance, light: Color3, dark: Color3, glow: Color3?, k: number): Frame
	local face = Kit.new("Frame", { Name = "Face", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = parent }) :: Frame
	Kit.corner(math.round(12 * k)).Parent = face
	Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(light, dark), Parent = face })
	Kit.stroke(glow or Color3.fromHex("#FFF6DA"), if glow then math.max(2, math.round(4 * k)) else 1, if glow then 0 else 0.55).Parent = face
	return face
end

-- Tile colours by role (light, dark), shared by the dark windows.
DarkWindow.TONES = {
	legendary = { Color3.fromHex("#FFF2B3"), Color3.fromHex("#A06A00") },
	epic = { Color3.fromHex("#E4CFFF"), Color3.fromHex("#4A1F99") },
	rare = { Color3.fromHex("#CFE6FF"), Color3.fromHex("#1C4B99") },
	common = { Color3.fromHex("#E6E2D6"), Color3.fromHex("#5C5A50") },
	title = { Color3.fromHex("#FFB4A6"), Color3.fromHex("#7A1D0F") },
	crate = { Color3.fromHex("#FFCF94"), Color3.fromHex("#7A3D0A") },
	stars = { Color3.fromHex("#9FF2E5"), Color3.fromHex("#0F5F56") },
	strike = { Color3.fromHex("#FFC2A0"), Color3.fromHex("#8A2A10") },
	army = { Color3.fromHex("#CDEBB0"), Color3.fromHex("#2F5A1E") },
	defence = { Color3.fromHex("#BFD8FF"), Color3.fromHex("#1E3F7A") },
	gold = { Color3.fromHex("#FFE9A0"), Color3.fromHex("#A87400") },
	navy = { Color3.fromHex("#9FB8D8"), Color3.fromHex("#17304E") },
} :: { [string]: { Color3 } }
DarkWindow.GLOW = {
	legendary = Color3.fromHex("#FFC83C"),
	epic = Color3.fromHex("#A064FF"),
	title = Color3.fromHex("#FF7A5C"),
} :: { [string]: Color3 }

return DarkWindow
