--!strict
-- The classified-dossier look (Bruno, 2026-10-26: docs/design/dossier-ui/),
-- shared by the main menu and the windows over it (Locker, Arsenal, Flag
-- Shop): stencil and typewriter text, paper surfaces, the yellow plate, the
-- click squash with its stamp thud, the paper rustle, and the window shell.
-- The art is UiAssets.dossier; without it everything falls back to flat
-- colours, glyphs and type.

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local UiAssets = require(script.Parent.UiAssets)

local C = Theme.color
local F = Theme.font
local A = UiAssets.dossier

local Dossier = {}
-- The art ids, for screens that pick a piece by name.
Dossier.A = A

-- Hover motion: a springy pop out, a plain settle back.
Dossier.SPRING = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
Dossier.SETTLE = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- The paper sound on a folder hover and the stamp thud on every click
-- (Creator Store, free; Bruno's picks, 2026-10-26/27).
local RUSTLE_ID = "rbxassetid://71787587486911"
local THUD_ID = "rbxassetid://9114026242"

-- MenuController sets this from the player's Sounds setting.
Dossier.soundsOn = true
-- In a match OpenFrontClient sets this to play Bruno's HUD click instead of
-- the menus' thud (2026-10-30).
Dossier.clickOverride = nil :: (() -> ())?

local SOUNDS: { [string]: { id: string, volume: number } } = {
	Thud = { id = THUD_ID, volume = 0.6 },
	Rustle = { id = RUSTLE_ID, volume = 0.5 },
}
local sounds: { [string]: Sound? } = {}
local lastPlayed: { [string]: number } = {}

local function sound(name: string): Sound
	local s = sounds[name]
	if s and s.Parent then
		return s
	end
	local def = SOUNDS[name]
	local made = Kit.new("Sound", { Name = "Dossier" .. name, SoundId = def.id, Volume = def.volume, Parent = SoundService }) :: Sound
	sounds[name] = made
	return made
end

local function play(name: string, gap: number)
	local now = os.clock()
	if not Dossier.soundsOn or now - (lastPlayed[name] or 0) < gap then
		return
	end
	lastPlayed[name] = now
	SoundService:PlayLocalSound(sound(name))
end

function Dossier.thud()
	local override = Dossier.clickOverride
	if override then
		override()
		return
	end
	play("Thud", 0.05)
end

-- At most a few times a second.
function Dossier.rustle()
	play("Rustle", 0.15)
end

-- Loads both sounds now, so the first click isn't silent.
function Dossier.preload()
	for name in SOUNDS do
		sound(name)
	end
end

function Dossier.click()
	if Kit.onActivated then
		Kit.onActivated()
	end
end

function Dossier.merge(defaults: { [string]: any }, props: { [string]: any }): { [string]: any }
	for k, v in props do
		defaults[k] = v
	end
	return defaults
end
local merge = Dossier.merge

-- Heavy condensed caps in ink.
-- Whether `parent` is a dark window's own header or body (2026-11-23): ink
-- placed straight on it turns light, and the paper props (clips, stamps,
-- pins, tape) stay off it. Light tiles inside keep their ink.
local function onDarkSurface(parent: any): boolean
	if typeof(parent) ~= "Instance" or not parent:IsA("GuiObject") then
		return false
	end
	local up = parent.Parent
	return up ~= nil and up:GetAttribute("DarkStyle") == true and (parent.Name == "Header" or parent.Name == "Body" or parent.Name == "Board")
end
Dossier.onDarkSurface = onDarkSurface
local DARK_INK = Color3.fromHex("#F4ECD8")
local DARK_FADED = Color3.fromHex("#C9C2AE")

function Dossier.stencil(props: { [string]: any }): TextLabel
	local label = Kit.label(merge({ FontFace = F.stencil, TextColor3 = C.inkBlack, TextSize = 40 }, props))
	if onDarkSurface(props.Parent) and (props.TextColor3 == nil or props.TextColor3 == C.inkBlack or props.TextColor3 == C.inkFaded) then
		label.TextColor3 = DARK_INK
	end
	return label
end
local stencil = Dossier.stencil

-- Typewriter text on paper.
function Dossier.typed(props: { [string]: any }): TextLabel
	local label = Kit.label(merge({ FontFace = F.typewriter, TextColor3 = C.inkFaded, TextSize = 18 }, props))
	if onDarkSurface(props.Parent) then
		if props.TextColor3 == nil or props.TextColor3 == C.inkBlack or props.TextColor3 == C.inkFaded then
			label.TextColor3 = DARK_FADED
		elseif props.TextColor3 == C.stamp then
			label.TextColor3 = Color3.fromHex("#FFD75E")
		end
	end
	return label
end

local PAPER_PROPS = { stamp_secret = true, star_stamp = true, paperclip = true, pin = true }

-- A piece of dossier art, or nil when it isn't uploaded.
function Dossier.art(name: string, props: { [string]: any }): ImageLabel?
	if (A[name] or "") == "" then
		return nil
	end
	if (PAPER_PROPS[name] or string.sub(name, 1, 4) == "tape") and onDarkSurface(props.Parent) then
		return nil
	end
	return Kit.new("ImageLabel", merge({ BackgroundTransparency = 1, Image = A[name], ScaleType = Enum.ScaleType.Fit }, props))
end
local art = Dossier.art

-- An icon: the dossier art, else the atlas glyph in ink.
function Dossier.icon(name: string, glyph: string, props: { [string]: any }): ImageLabel
	return art(name, props) or Kit.glyph(glyph, merge({ ImageColor3 = C.inkBlack }, props))
end

-- A textured surface (a Frame-like ImageLabel or a clickable ImageButton):
-- the tiled texture over a flat fallback colour.
function Dossier.surface(className: string, tex: string, color: Color3, props: { [string]: any }): any
	local inst = Kit.new(className, {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Image = A[tex] or "",
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(256, 256),
	})
	if className == "ImageButton" then
		inst.AutoButtonColor = false
	end
	for k, v in props do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	inst.Parent = props.Parent
	return inst
end
local surface = Dossier.surface

-- A picture spread over a box (`stretch` art, e.g. a torn paper strip), else
-- the tiled texture `tex`.
function Dossier.sheet(className: string, stretch: string, tex: string, color: Color3, props: { [string]: any }): any
	local inst = surface(className, tex, color, props)
	if (A[stretch] or "") ~= "" then
		inst.Image = A[stretch]
		inst.ScaleType = Enum.ScaleType.Stretch
		inst.BackgroundTransparency = 1
	end
	return inst
end

-- A soft shadow under a surface (same place, size and turn, nudged down).
function Dossier.shadow(parent: Instance, props: { [string]: any }, z: number): Frame
	local s = Kit.new("Frame", {
		Name = "Shadow",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.68,
		BorderSizePixel = 0,
		AnchorPoint = props.AnchorPoint or Vector2.zero,
		Position = (props.Position :: UDim2) + UDim2.fromOffset(5, 8),
		Size = props.Size,
		Rotation = props.Rotation or 0,
		ZIndex = z,
		Parent = parent,
	})
	Kit.corner(5).Parent = s
	return s
end

-- A small ink button on paper (CANCEL, HOW TO PLAY).
function Dossier.inkButton(parent: Instance, text: string, props: { [string]: any }): TextButton
	local button = Kit.new("TextButton", merge({ Text = "", AutoButtonColor = false, BackgroundColor3 = C.inkBlack, BorderSizePixel = 0 }, props))
	Kit.corner(4).Parent = button
	stencil({ Name = "Label", Text = text, TextSize = 26, TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = button })
	button.MouseEnter:Connect(function()
		if Kit.covered(button) then
			return
		end
		button.BackgroundColor3 = C.stamp
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundColor3 = C.inkBlack
	end)
	button.Activated:Connect(Dossier.click)
	button.Parent = props.Parent
	return button
end

-- The yellow plate (PLAY, START, prices): the plate art, else flat hazard
-- yellow. Place it by its centre (AnchorPoint 0.5, 0.5) so it squashes
-- evenly. `text` may be "" when the caller lays out its own label.
function Dossier.plate(parent: Instance, text: string, props: { [string]: any }, textSize: number): ImageButton
	local button = Kit.new("ImageButton", merge({
		AutoButtonColor = false,
		BackgroundColor3 = C.hazard,
		BackgroundTransparency = if A.plate_play ~= "" then 1 else 0,
		BorderSizePixel = 0,
		Image = A.plate_play,
		ScaleType = Enum.ScaleType.Stretch,
	}, props))
	if A.plate_play == "" then
		Kit.corner(6).Parent = button
		Kit.stroke(C.inkBlack, 5, 0).Parent = button
	end
	if text ~= "" then
		stencil({ Name = "Label", Text = text, TextSize = textSize, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = button })
	end
	button.Activated:Connect(Dossier.click)
	button.Parent = props.Parent
	return button
end

-- Every button's click (Bruno, 2026-10-26: the SOLO stamp's thump): the
-- `target` (the button, or a picture under a hit area) squashes on press
-- and springs back, with the stamp thud. Hovered, it sits at `hover` (1 =
-- unchanged). The target must be anchored at its centre: UIScale scales about
-- the anchor point. `thud` false leaves the sound to the caller.
-- A UIScale grows about its object's AnchorPoint, so a hovered thing is
-- re-anchored at its centre first, staying where it is (Bruno, 2026-10-29:
-- every hover grows from the middle, never the top-left corner). Layouts
-- place children ignoring AnchorPoint, so there only the anchor changes; an
-- automatically sized object outside a layout is left as it is.
local CENTRE = Vector2.new(0.5, 0.5)
function Dossier.centreAnchor(target: GuiObject)
	local a = target.AnchorPoint
	if a == CENTRE then
		return
	end
	local parent = target.Parent
	if parent and parent:FindFirstChildWhichIsA("UIGridStyleLayout") then
		target.AnchorPoint = CENTRE
		return
	end
	if target.AutomaticSize ~= Enum.AutomaticSize.None then
		return
	end
	local s = target.Size
	target.Position += UDim2.new(s.X.Scale * (0.5 - a.X), s.X.Offset * (0.5 - a.X), s.Y.Scale * (0.5 - a.Y), s.Y.Offset * (0.5 - a.Y))
	target.AnchorPoint = CENTRE
end

function Dossier.clicky(button: GuiButton, hover: number, target: GuiObject?, thud: boolean?): UIScale
	local scaled: GuiObject = target or button
	local s = Kit.new("UIScale", { Parent = scaled })
	local over = false
	-- A separate target (a menu folder, a tile's face) is placed and
	-- animated by its owner, which anchors it itself.
	local function centre()
		if target == nil then
			Dossier.centreAnchor(button)
		end
	end
	button.MouseEnter:Connect(function()
		if Kit.covered(button) then
			return
		end
		centre()
		over = true
		TweenService:Create(s, Dossier.SPRING, { Scale = hover }):Play()
	end)
	button.MouseLeave:Connect(function()
		over = false
		TweenService:Create(s, Dossier.SETTLE, { Scale = 1 }):Play()
	end)
	button.MouseButton1Down:Connect(function()
		-- A tap on touch has no hover first.
		centre()
		TweenService:Create(s, TweenInfo.new(0.06), { Scale = hover * 0.9 }):Play()
	end)
	button.MouseButton1Up:Connect(function()
		TweenService:Create(s, Dossier.SPRING, { Scale = if over then hover else 1 }):Play()
	end)
	if thud ~= false then
		button.Activated:Connect(Dossier.thud)
	end
	return s
end

-- A tile in a grid (its cell is a layout slot, so the picture moves inside
-- it): hovering lifts `face` by `rise` px with a darker shadow under it,
-- clicking squashes it. `face` must be anchored at its centre, at the cell's
-- centre; `shade` is its shadow, placed the same way and nudged down.
function Dossier.liftTile(cell: GuiButton, face: GuiObject, shade: GuiObject?, rise: number)
	local home = face.Position
	local shadeHome = if shade then shade.Position else nil
	Dossier.clicky(cell, 1, face)
	cell.MouseEnter:Connect(function()
		if Kit.covered(cell) then
			return
		end
		TweenService:Create(face, Dossier.SPRING, { Position = home - UDim2.fromOffset(0, rise) }):Play()
		if shade and shadeHome then
			TweenService:Create(shade, Dossier.SPRING, { Position = shadeHome - UDim2.fromOffset(-2, rise - 6), BackgroundTransparency = 0.5 }):Play()
		end
	end)
	cell.MouseLeave:Connect(function()
		TweenService:Create(face, Dossier.SETTLE, { Position = home }):Play()
		if shade and shadeHome then
			TweenService:Create(shade, Dossier.SETTLE, { Position = shadeHome, BackgroundTransparency = 0.68 }):Play()
		end
	end)
end

export type Window = {
	root: Frame,
	window: Frame,
	header: Frame,
	body: GuiObject,
	close: () -> (),
	-- Reference pixels to canvas units.
	at: (x: number, y: number) -> UDim2,
	sz: (w: number, h: number) -> UDim2,
	k: number,
	-- The layout's size in its own units (the reference picture; on a phone,
	-- the body in canvas units).
	width: number,
	height: number,
}

-- A dossier window over the menu, laid out in the pixels of Bruno's
-- reference picture (`refW` x `refH`), scaled to `height` canvas units: a
-- dimmed desk behind, a manila folder with its tab at the top left, and the
-- stained board inside from `boardTop` (reference pixels) down. The desk takes
-- every click and hover meant for what is under it, and doesn't close the
-- window (Bruno, 2026-10-27: a stray click loses nothing). The close button
-- is the caller's (its style differs per window); `close` closes.
function Dossier.window(host: Instance, refW: number, refH: number, height: number, boardTop: number, onClose: (() -> ())?): Window
	local k = height / refH
	-- A tooltip shown for something under the window would stay stuck on top.
	Kit.hideTip()
	local function at(x: number, y: number): UDim2
		return UDim2.fromOffset(math.round(x * k), math.round(y * k))
	end
	local function sz(w: number, h: number): UDim2
		return UDim2.fromOffset(math.round(w * k), math.round(h * k))
	end
	local root = Kit.new("Frame", { Name = "Modal", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = host }) :: Frame
	Kit.new("TextButton", { Name = "Scrim", Text = "", AutoButtonColor = false, BackgroundColor3 = C.desk, BackgroundTransparency = 0.25, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = root })
	-- The dark style (Bruno, 2026-11-23: every window like the Campaign
	-- Pass): a dark body, a banner washed in the window's colour over its
	-- header (Dossier.style, set by the caller before opening), a soft rim.
	local style: { [string]: any } = Dossier.style or {}
	Dossier.style = nil
	local window = Kit.new("Frame", { Name = "Window", BackgroundColor3 = Dossier.DARK, BorderSizePixel = 0, ClipsDescendants = false, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz(refW, refH), Parent = root }) :: Frame
	window:SetAttribute("DarkStyle", true)
	Kit.corner(math.round(16 * k)).Parent = window
	Kit.stroke(Color3.fromHex("#0B1218"), math.max(3, math.round(6 * k)), 0).Parent = window
	Dossier.banner(window, sz(refW, style.bannerH or math.max(boardTop, 200)), style, math.round(16 * k))
	local header = Kit.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = window }) :: Frame
	local body = Kit.new("Frame", { Name = "Body", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = window }) :: Frame
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		Kit.hideTip()
		root:Destroy()
		if onClose then
			onClose()
		end
	end
	return { root = root, window = window, header = header, body = body, close = close, at = at, sz = sz, k = k, width = refW, height = refH }
end

-- The dark style (2026-11-23) ---------------------------------------------------------------
Dossier.DARK = Color3.fromHex("#0F1A14")
-- Set just before opening a window: { wash: Color3?, art: string?, bannerH: number? }
-- (bannerH in the window's reference pixels).
Dossier.style = nil :: { [string]: any }?

-- A banner: the picture (a banner_* art, or any photo), washed in `wash`
-- toward the right and dark toward the left, fading into the body.
function Dossier.banner(parent: Instance, size: UDim2, style: { [string]: any }, radius: number): Frame
	local wash: Color3 = style.wash or Color3.fromHex("#C9902A")
	local band = Kit.new("Frame", { Name = "Banner", BackgroundColor3 = wash:Lerp(Color3.new(0, 0, 0), 0.75), BorderSizePixel = 0, ClipsDescendants = true, Size = size, ZIndex = 1, Parent = parent }) :: Frame
	Kit.corner(radius).Parent = band
	local image = if style.art then A[style.art] else nil
	if image and image ~= "" then
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = image, ScaleType = Enum.ScaleType.Crop, Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = band })
	end
	local tint = Kit.new("Frame", { BackgroundColor3 = wash, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = band })
	Kit.new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.85), NumberSequenceKeypoint.new(0.5, 0.45), NumberSequenceKeypoint.new(1, 0.35) }), Parent = tint })
	local shade = Kit.new("Frame", { BackgroundColor3 = wash:Lerp(Color3.new(0, 0, 0), 0.9), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = band })
	Kit.new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.5, 0.6), NumberSequenceKeypoint.new(1, 1) }), Parent = shade })
	local foot = Kit.new("Frame", { BackgroundColor3 = Dossier.DARK, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 1, Parent = band })
	Kit.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.6, 1), NumberSequenceKeypoint.new(1, 0) }), Parent = foot })
	-- Clipping doesn't follow a rounded corner, so each layer rounds its own
	-- (the strong wash showed a square top-right corner; Bruno, 2026-11-24).
	for _, layer in band:GetChildren() do
		if layer:IsA("GuiObject") then
			Kit.corner(radius).Parent = layer
		end
	end
	return band
end

-- Whether `inst` is inside a dark-style window.
function Dossier.inDark(inst: Instance?): boolean
	local node = inst
	while node do
		if node:GetAttribute("DarkStyle") then
			return true
		end
		node = node.Parent
	end
	return false
end

-- A soft dark outline that keeps white text readable on any colour.
function Dossier.outline(label: TextLabel): TextLabel
	Kit.new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1.5, Transparency = 0.45, Parent = label })
	return label
end

-- A phone's windows fill the screen (Bruno, 2026-10-27).
Dossier.PHONE_HEADER = 78

-- A phone window whose content is laid out in a reference picture's pixels
-- at scale `k`, inside `body` (say, a scrolling page in the window's body).
function Dossier.rescaled(w: Window, k: number, body: GuiObject): Window
	local function at(x: number, y: number): UDim2
		return UDim2.fromOffset(math.round(x * k), math.round(y * k))
	end
	local function sz(x: number, y: number): UDim2
		return UDim2.fromOffset(math.round(x * k), math.round(y * k))
	end
	return { root = w.root, window = w.window, header = w.header, body = body, close = w.close, at = at, sz = sz, k = k, width = w.width / k, height = w.height / k }
end

-- True when the screen root is laid out for a phone (Root.compact).
function Dossier.phone(): boolean
	return Kit.root ~= nil and Kit.root.compact == true
end

-- A window on a phone: the stained board fills the safe area, with a band
-- along the top for the header (the title right of Roblox's buttons, the
-- red close button at the right; callers add tabs and notes in the gap
-- between, lined up leftwards from x = width - 84) and the body under it.
-- Everything is in canvas units (`at`, `sz`, k = 1); `width` x `height` is
-- the body.
function Dossier.phoneWindow(host: Instance, title: string, onClose: (() -> ())?): Window
	local r = Kit.root
	local W, H = r.width, r.height
	Kit.hideTip()
	local function at(x: number, y: number): UDim2
		return UDim2.fromOffset(math.round(x), math.round(y))
	end
	local function sz(w: number, h: number): UDim2
		return UDim2.fromOffset(math.round(w), math.round(h))
	end
	local root = Kit.new("Frame", { Name = "Modal", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50, Parent = host }) :: Frame
	Kit.new("TextButton", { Name = "Scrim", Text = "", AutoButtonColor = false, BackgroundColor3 = C.desk, BackgroundTransparency = 0, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = root })
	local style: { [string]: any } = Dossier.style or {}
	Dossier.style = nil
	local window = Kit.new("Frame", { Name = "Window", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = root }) :: Frame
	window:SetAttribute("DarkStyle", true)
	local board = Kit.new("Frame", { Name = "Board", BackgroundColor3 = Dossier.DARK, BorderSizePixel = 0, Position = at(4, 4), Size = sz(W - 8, H - 8), ZIndex = 1, Parent = window })
	Kit.corner(10).Parent = board
	Kit.stroke(Color3.fromHex("#0B1218"), 3, 0).Parent = board
	Dossier.banner(board, sz(W - 8, Dossier.PHONE_HEADER + 10), style, 10)
	local header = Kit.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = sz(W, Dossier.PHONE_HEADER), ZIndex = 3, Parent = window }) :: Frame
	local body = Kit.new("Frame", { Name = "Body", BackgroundTransparency = 1, Position = at(0, Dossier.PHONE_HEADER), Size = sz(W, H - Dossier.PHONE_HEADER), ZIndex = 2, Parent = window }) :: Frame
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		Kit.hideTip()
		root:Destroy()
		if onClose then
			onClose()
		end
	end
	-- The title on a torn paper strip, clear of Roblox's buttons.
	local left = math.max(12, r.topLeft - 4)
	local strip = Kit.new("Frame", { Name = "Title", BackgroundTransparency = 1, Position = at(left, 8), Size = sz(0, 62), AutomaticSize = Enum.AutomaticSize.X, Parent = header })
	Kit.padding(0, 6).Parent = strip
	local t = stencil({ Text = title, TextSize = 56, TextColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Parent = strip })
	Kit.new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 0.45, Parent = t })
	Kit.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Parent = strip })
	Dossier.closeRed(header, at(W - 42, 39), sz(62, 62), close)
	return { root = root, window = window, header = header, body = body, close = close, at = at, sz = sz, k = 1, width = W, height = H - Dossier.PHONE_HEADER }
end

-- Text size for stencil caps `cap` reference pixels tall (Oswald's caps are
-- about half its size). Roblox caps TextSize at 100: see bigCaps.
function Dossier.capSize(w: Window, cap: number): number
	return math.min(100, math.round(cap / 0.5 * w.k))
end

-- A window title, whose caps need more than TextSize 100: drawn at 100 and
-- scaled up.
function Dossier.bigCaps(w: Window, cap: number, props: { [string]: any }): TextLabel
	local dark = onDarkSurface(props.Parent)
	local label = stencil(merge({ TextSize = 100 }, props))
	if dark then
		label.TextColor3 = Color3.new(1, 1, 1)
	end
	if dark then
		Kit.new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 2, Transparency = 0.45, Parent = label })
	end
	Kit.new("UIScale", { Scale = cap / 0.5 * w.k / 100, Parent = label })
	return label
end

-- A picture made to look like an aged print: warmed, dusty, scratched.
function Dossier.age(pic: GuiObject)
	local z = pic.ZIndex
	Kit.new("Frame", { Name = "Sepia", BackgroundColor3 = Color3.fromRGB(150, 112, 62), BackgroundTransparency = 0.84, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = pic })
	art("photo_grunge", { Name = "Grunge", ScaleType = Enum.ScaleType.Stretch, Size = UDim2.fromScale(1, 1), ImageTransparency = 0.15, ZIndex = z, Parent = pic })
end

-- A card or folder picture filling `props`' box: the art, else manila.
function Dossier.cardArt(className: string, artName: string, props: { [string]: any }): any
	-- In a dark window a card is a clean rounded tile, light so its ink
	-- text still reads, with a soft glow edge.
	if Dossier.inDark(props.Parent) then
		local tile = Kit.new(className, merge({ BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Image = "", AutoButtonColor = if className == "ImageButton" then false else nil }, props))
		Kit.corner(10).Parent = tile
		Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromHex("#FBF4E4"), Color3.fromHex("#E2D2AC")), Parent = tile })
		Kit.stroke(Color3.fromHex("#FFE9A8"), 2, 0.35).Parent = tile
		return tile
	end
	if (A[artName] or "") ~= "" then
		return Kit.new(className, merge({ BackgroundTransparency = 1, Image = A[artName], ScaleType = Enum.ScaleType.Stretch, AutoButtonColor = if className == "ImageButton" then false else nil }, props))
	end
	local inst = Dossier.surface(className, "tex_manila", C.manila, props)
	Kit.corner(8).Parent = inst
	Kit.stroke(C.manilaLine, 2, 0.1).Parent = inst
	return inst
end

-- The torn paper strip a window's title sits on.
function Dossier.headerPaper(w: Window, x: number, y: number, ww: number, hh: number, rot: number): ImageLabel
	-- (A dark window's title sits right on its banner.)
	if Dossier.inDark(w.window) then
		return Kit.new("ImageLabel", { Name = "HeaderPaper", BackgroundTransparency = 1, Image = "", Position = w.at(x, y), Size = w.sz(ww, hh), Parent = w.header }) :: ImageLabel
	end
	local paper = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Name = "HeaderPaper", Position = w.at(x, y), Size = w.sz(ww, hh), Rotation = rot, Parent = w.header })
	if A.header_paper == "" then
		Kit.stroke(C.sheetLine, 1, 0.2).Parent = paper
	end
	return paper
end

function Dossier.starStamp(parent: Instance, w: Window, cx: number, cy: number, size: number, alpha: number)
	art("star_stamp", { Name = "Star", AnchorPoint = Vector2.new(0.5, 0.5), Position = w.at(cx, cy), Size = w.sz(size, size), ImageTransparency = alpha, Rotation = -10, Parent = parent })
end

function Dossier.pin(parent: Instance, w: Window, x: number, y: number)
	art("pin", { Name = "Pin", AnchorPoint = Vector2.new(0.5, 0.75), Position = w.at(x, y), Size = w.sz(30, 42), ZIndex = 4, Parent = parent })
end

function Dossier.clip(parent: Instance, w: Window, cx: number, cy: number, h: number, rot: number)
	art("paperclip", { Name = "Clip", AnchorPoint = Vector2.new(0.5, 0.5), Position = w.at(cx, cy), Size = w.sz(h * 0.28, h), Rotation = rot, ZIndex = 4, Parent = parent })
end

function Dossier.tape(parent: Instance, w: Window, name: string, cx: number, cy: number, ww: number, hh: number, rot: number)
	art(name, { Name = "Tape", AnchorPoint = Vector2.new(0.5, 0.5), Position = w.at(cx, cy), Size = w.sz(ww, hh), Rotation = rot, ScaleType = Enum.ScaleType.Stretch, ZIndex = 4, Parent = parent })
end

-- A small riveted metal plate (On/Off, CANCEL, HOW TO PLAY): yellow when
-- `on`, else pale. Centre-anchored, with the click squash. `setOn` repaints.
-- The riveted plates' faces inside their pictures (art/dossier/upload): the
-- yellow one has an empty strip below, the pale one above, so uncropped a
-- plate turning yellow jumped up under its label (Bruno, 2026-10-27).
local PLATE_FACE: { [string]: { Vector2 } } = {
	plate_rivet_yellow = { Vector2.new(0, 1), Vector2.new(482, 157) },
	plate_rivet_pale = { Vector2.new(0, 13), Vector2.new(470, 148) },
}

-- A bigger invisible tap area for a small control on a phone (audit F12;
-- Apple's minimum is 44 points, and GUI units here are points). Nothing
-- changes on screen. `onActivate` runs for taps that land on the pad;
-- `maxW`/`maxH` cap it in the button's own units so neighbours' pads never
-- overlap (nil: no cap). Where the button sits freely the pad goes behind
-- it, so a direct tap still hits the button (its squash and sound); in a
-- laid-out row it goes on top, centred (a sibling would be laid out too).
-- Does nothing off a phone or when the button is already big enough.
Dossier.MIN_TAP = 44
function Dossier.hitPad(button: GuiButton, onActivate: () -> (), maxW: number?, maxH: number?): GuiButton?
	if Kit.root == nil or Kit.root.compact ~= true then
		return nil
	end
	local parent = button.Parent
	if parent == nil then
		return nil
	end
	local laidOut = parent:FindFirstChildWhichIsA("UIGridStyleLayout") ~= nil
	local pad = Kit.new("TextButton", {
		Name = button.Name .. "HitPad",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Selectable = false,
		ZIndex = if laidOut then button.ZIndex + 1 else button.ZIndex - 1,
	}) :: TextButton
	local base = button.Size
	local function fit()
		local w, h = base.X.Offset, base.Y.Offset
		-- points per unit of the button's own space (UIScales included)
		local k = if w > 0 then button.AbsoluteSize.X / w else 0
		if k <= 0 then
			return
		end
		local pw = math.max(w, Dossier.MIN_TAP / k)
		local ph = math.max(h, Dossier.MIN_TAP / k)
		if maxW then
			pw = math.max(w, math.min(pw, maxW))
		end
		if maxH then
			ph = math.max(h, math.min(ph, maxH))
		end
		pad.Size = UDim2.fromOffset(pw, ph)
		if laidOut then
			pad.Position = UDim2.fromScale(0.5, 0.5)
		else
			local p, a = button.Position, button.AnchorPoint
			pad.Position = UDim2.new(p.X.Scale, p.X.Offset + (0.5 - a.X) * w, p.Y.Scale, p.Y.Offset + (0.5 - a.Y) * h)
		end
	end
	fit()
	button:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	button:GetPropertyChangedSignal("Position"):Connect(fit)
	button:GetPropertyChangedSignal("Visible"):Connect(function()
		pad.Visible = button.Visible
	end)
	pad.Visible = button.Visible
	pad.Activated:Connect(function()
		Dossier.thud()
		onActivate()
	end)
	button.Destroying:Connect(function()
		pad:Destroy()
	end)
	pad.Parent = if laidOut then button else parent
	return pad
end

function Dossier.rivetPlate(parent: Instance, text: string, textSize: number, on: boolean, props: { [string]: any }): (ImageButton, (boolean) -> ())
	local b = Kit.new("ImageButton", merge({ AutoButtonColor = false, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Stretch, AnchorPoint = Vector2.new(0.5, 0.5) }, props))
	local stroke: UIStroke? = nil
	local function setOn(value: boolean)
		local name = if value then "plate_rivet_yellow" else "plate_rivet_pale"
		if (A[name] or "") ~= "" then
			b.Image = A[name]
			b.ImageRectOffset, b.ImageRectSize = PLATE_FACE[name][1], PLATE_FACE[name][2]
			b.BackgroundTransparency = 1
		else
			b.Image = ""
			b.BackgroundTransparency = 0
			b.BackgroundColor3 = if value then C.hazard else C.sheet
			if stroke == nil then
				Kit.corner(5).Parent = b
				stroke = Kit.stroke(C.inkBlack, 2, 0.2)
				;(stroke :: UIStroke).Parent = b
			end
		end
	end
	setOn(on)
	if text ~= "" then
		stencil({ Name = "Label", Text = text, TextSize = textSize, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, Parent = b })
	end
	b.Activated:Connect(Dossier.click)
	Dossier.clicky(b, 1.05)
	b.Parent = props.Parent
	return b, setOn
end

-- The in-match HUD's framed manila plaque (9-sliced art, else manila with a
-- dark frame). `className` is ImageLabel or ImageButton.
function Dossier.plaque(className: string, props: { [string]: any }): any
	if (A.hud_plaque or "") ~= "" then
		local inst = Kit.new(className, merge({ BackgroundTransparency = 1, BorderSizePixel = 0, Image = A.hud_plaque, ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(36, 36, 476, 220), SliceScale = 0.5 }, props))
		if className == "ImageButton" then
			inst.AutoButtonColor = false
		end
		return inst
	end
	local inst = surface(className, "tex_manila", C.manila, props)
	Kit.corner(4).Parent = inst
	Kit.stroke(Color3.fromHex("#3A2A1A"), 3, 0).Parent = inst
	return inst
end

-- The dark riveted rail the HUD's plaques sit on (9-sliced art, else flat).
function Dossier.rail(props: { [string]: any }): ImageLabel
	if (A.hud_rail or "") ~= "" then
		return Kit.new("ImageLabel", merge({ BackgroundTransparency = 1, BorderSizePixel = 0, Image = A.hud_rail, ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(48, 48, 976, 112), SliceScale = 0.5 }, props))
	end
	local inst = Kit.new("ImageLabel", merge({ BackgroundColor3 = Color3.fromHex("#4A4532"), BorderSizePixel = 0, Image = "" }, props))
	Kit.corner(6).Parent = inst
	Kit.stroke(Color3.fromHex("#2A2618"), 3, 0).Parent = inst
	return inst
end

-- The red enamel close button with a white X (centre at `pos`).
function Dossier.closeRed(parent: Instance, pos: UDim2, size: UDim2, onClose: () -> ()): ImageButton
	local b = Kit.new("ImageButton", { Name = "Close", AutoButtonColor = false, BackgroundColor3 = C.stamp, BackgroundTransparency = if A.close_red ~= "" then 1 else 0, BorderSizePixel = 0, Image = A.close_red, ScaleType = Enum.ScaleType.Stretch, AnchorPoint = Vector2.new(0.5, 0.5), Position = pos, Size = size, Rotation = 4, Parent = parent })
	if A.close_red == "" then
		Kit.corner(6).Parent = b
	end
	Kit.glyph("close", { ImageColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.48, 0.48), Parent = b })
	Dossier.clicky(b, 1.08)
	b.Activated:Connect(onClose)
	return b
end

-- A manila close button with a black X (centre at `pos`).
function Dossier.closeManila(parent: Instance, pos: UDim2, size: UDim2, onClose: () -> ()): ImageButton
	-- (A dark window uses the red X everywhere.)
	if onDarkSurface(parent) then
		local side = math.max(size.X.Offset, size.Y.Offset)
		return Dossier.closeRed(parent, pos, UDim2.fromOffset(side, side), onClose)
	end
	local b = surface("ImageButton", "tex_manila", C.manila, { Name = "Close", AnchorPoint = Vector2.new(0.5, 0.5), Position = pos, Size = size, Parent = parent })
	Kit.corner(6).Parent = b
	Kit.stroke(C.manilaLine, 2, 0).Parent = b
	Kit.glyph("close", { ImageColor3 = C.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.5, 0.5), Parent = b })
	Dossier.clicky(b, 1.08)
	b.Activated:Connect(onClose)
	return b
end

return Dossier
