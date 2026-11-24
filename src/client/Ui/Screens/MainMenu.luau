--!strict
-- The main menu as a classified dossier, laid out to Bruno's concept
-- (2026-10-26: docs/design/dossier-ui/main-menu-concept.png, 1024x572).
-- Every position below is in the concept's own pixels (`at`, `sz`), scaled
-- by K onto the 1920x1080 canvas, so the screen matches the picture:
--   - the folder, its title band "CONQUER COUNTRIES" and the taped TOP-SECRET
--     note (stars, the crate price, settings and sound)
--   - left: the "Military requisitions" spine and four folder cards: Party,
--     Armory (the Arsenal), Supply crates (the Locker), Flag Shop
--   - centre: the war map pinned to the board, and the World queue as the
--     "Deploy to frontline" note clipped to it
--   - right: the SOLO DEPLOYMENT stamp over the PLAY plate; PLAY lays the
--     deployment orders (map, difficulty, START, how to play) over the map
--   - bottom: the other public queues as field reports, and the credits bar
--     with "Fork of OpenFront · © OpenFront and Contributors"
--     (LICENSING_PLAN: first screen)
-- Phones (Root.compact) get their own layout of the same pieces
-- (`_buildCompact`), rebuilt if the screen changes size.
-- The art (icons, stamps, paper, plate) is UiAssets.dossier; without it the
-- screen falls back to glyphs and type. It only shows things and calls
-- `actions`; MenuController owns the remotes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CreditsText = require(Shared.CreditsText)
local Catalog = require(Shared.Store.Catalog)
local MapCatalog = require(Shared.MapCatalog)
local MenuModel = require(Shared.MenuModel)

local Dossier = require(script.Parent.Parent.Dossier)
local HudStyle = require(script.Parent.Parent.HudStyle)
local MenuCards = require(script.Parent.MenuCards)
local Art = require(script.Parent.Parent.Art)
local FieldMaps = require(script.Parent.Parent.FieldMaps)
local Kit = require(script.Parent.Parent.Kit)
local MapThumbs = require(script.Parent.Parent.MapThumbs)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)

local C = Theme.color
local F = Theme.font
local A = UiAssets.dossier

local MainMenu = {}
MainMenu.__index = MainMenu

export type Actions = {
	startSolo: (mapFolder: string, difficulty: string) -> (),
	-- A private server's match for everyone on it (2026-11-23; the owner only).
	startPrivate: ((mapFolder: string, kind: string) -> ())?,
	joinQueue: (id: string) -> (),
	leaveQueue: () -> (),
	watchQueue: (id: string) -> (),
	pickMap: (current: string, done: (folder: string) -> ()) -> (),
	openHowToPlay: () -> (),
	openSettings: () -> (),
	-- The credits and licence window (the credits bar).
	openCredits: (() -> ())?,
	toggleMusic: () -> (),
	openArsenal: () -> (),
	-- The Shop on a shelf (2026-11-23; nil = Featured).
	openShop: ((tab: string?) -> ())?,
	openLocker: () -> (),
	openFlagShop: () -> (),
	openParty: () -> (),
	-- The starter pack's offer (the red tag under the stars note).
	openStarter: (() -> ())?,
	-- The launch event's free starter pack (the same tag, gold, while claimable).
	openGift: (() -> ())?,
	-- Conquest General's window (the gold-edged card under it).
	openGeneral: (() -> ())?,
	-- The Campaign Pass window (the card under General's).
	openPass: (() -> ())?,
}

-- Concept pixels to canvas units (desktop). The phone layout is written in
-- canvas units, so it builds with K = 1.
local DESKTOP_K = 1920 / 1024
local K = DESKTOP_K
local STAGE_W, STAGE_H = 1920, 1072

-- A private match's modes, on the difficulty chips (Easy, Medium, Hard).
local PRIVATE_KIND: { [string]: string } = { Easy = "ffa", Medium = "team", Hard = "blitz" }
local PRIVATE_LABEL: { [string]: string } = { ffa = "FREE FOR ALL", team = "TEAMS", blitz = "BLITZ" }
local PRIVATE_LINE: { [string]: string } = {
	ffa = "Everyone for themselves, with the map's AI nations.",
	team = "Teams, shared out by the game; friends in a party stay together.",
	blitz = "Ten minutes; the most land wins.",
}

local function at(x: number, y: number): UDim2
	return UDim2.fromOffset(math.round(x * K), math.round(y * K))
end

local function sz(w: number, h: number): UDim2
	return UDim2.fromOffset(math.round(w * K), math.round(h * K))
end

-- A map thumbnail cell as an ImageLabel (blank until the page is uploaded).
function MainMenu.thumb(folder: string, props: { [string]: any }): ImageLabel
	local cell = MapThumbs.cells[folder]
	local image = Kit.new("ImageLabel", { BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Fit })
	if cell then
		image.Image = MapThumbs.PAGES[cell[1]] or ""
		image.ImageRectOffset = Vector2.new(cell[2] * MapThumbs.cellW, cell[3] * MapThumbs.cellH)
		image.ImageRectSize = Vector2.new(MapThumbs.cellW, MapThumbs.cellH)
	end
	for k, v in props do
		if k ~= "Parent" then
			(image :: any)[k] = v
		end
	end
	image.Parent = props.Parent
	return image
end

-- A map as a vintage field map (FieldMaps, scripts/art/field_maps.py).
function MainMenu.fieldMap(folder: string, props: { [string]: any }): ImageLabel
	local cell = FieldMaps.cells[folder]
	local image = Kit.new("ImageLabel", { BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Crop })
	if cell then
		image.Image = FieldMaps.PAGES[cell[1]] or ""
		image.ImageRectOffset = Vector2.new(cell[2] * FieldMaps.cellW, cell[3] * FieldMaps.cellH)
		image.ImageRectSize = Vector2.new(FieldMaps.cellW, FieldMaps.cellH)
	end
	for k, v in props do
		if k ~= "Parent" then
			(image :: any)[k] = v
		end
	end
	image.Parent = props.Parent
	return image
end

local click = Dossier.click
local stencil = Dossier.stencil
local typed = Dossier.typed
local surface = Dossier.surface
local inkButton = Dossier.inkButton
-- The deployment orders in the dark style (2026-11-23, like the Campaign
-- Pass): a dark sheet under a green banner, light words, soft buttons.
local ORDERS_WASH = Color3.fromHex("#2F9A5B")
local ORDERS_LABEL = Color3.fromHex("#FFD75E")
local ORDERS_TEXT = Color3.fromHex("#E6E0CC")
local function darkSheet(props: { [string]: any }, bannerH: number): Frame
	local sheet = Kit.new("Frame", Dossier.merge({ Name = "Sheet", BackgroundColor3 = Dossier.DARK, BorderSizePixel = 0 }, props)) :: Frame
	Kit.corner(12).Parent = sheet
	Kit.stroke(Color3.fromHex("#0B1218"), 4, 0).Parent = sheet
	local band = Dossier.banner(sheet, UDim2.new(1, 0, 0, bannerH), { wash = ORDERS_WASH, art = "banner_orders" }, 12)
	band.ZIndex = 0
	for _, d in band:GetChildren() do
		if d:IsA("GuiObject") then
			d.ZIndex = 0
		end
	end
	return sheet
end
local function softButton(b: GuiObject)
	b.BackgroundColor3 = Color3.fromHex("#2C3E33")
	Kit.stroke(Color3.fromHex("#7C9A86"), 2, 0).Parent = b
end
local plate = Dossier.plate

-- The label a public queue's action has.
local function actionText(row: any, mine: boolean): string
	if row.live then
		return "WATCH"
	elseif mine then
		return "LEAVE"
	elseif row.mode then
		return "JOIN TEAMS"
	end
	return "JOIN"
end

-- The desktop layout in style B (Bruno, 2026-11-24: "build B for ... the
-- menu ... as close as possible to the mock ups"): one dark sheet under a
-- gold-washed title banner; the four requisition cards, each a banner
-- photo washed in its window's colour; the live map with the frontline
-- card; General, Campaign and PLAY on the right; the three public queues
-- under teal headers; the credits strip along the foot. Positions are the
-- mock-up's pixels (Main menu in style B, the sheet 1286x758) scaled by MOCK
-- onto the canvas.
local MOCK = 1 / 0.736 -- the mock-up's screen pixels to canvas units
local function m(v: number): number
	return math.round(v * MOCK)
end
local function mAt(x: number, y: number): UDim2
	return UDim2.fromOffset(m(x), m(y))
end
local function mSz(w: number, h: number): UDim2
	return UDim2.fromOffset(m(w), m(h))
end
local SHEET = { x = 122, y = 22, w = 1747, h = 1030 } -- the sheet on the stage

-- The mock-up's type, exactly (Bruno, 2026-11-24: "the font size and
-- spacing just like the mock-up"). The browser sizes a font by its em,
-- Roblox by its whole line (ascent + descent), so the same number reads
-- smaller here: each face has its factor (Oswald measured from the two
-- screenshots: 1.42; the others from their line metrics).
local FACE = { oswald = 1.42, sans = 1.26, elite = 1.3 }
local HAIR = utf8.char(0x200A)
-- The mock-up's letter-spacing: a hair space (about 0.1 em) between letters,
-- `n` of them.
local function spaced(text: string, n: number?): string
	local chars = {}
	for _, code in utf8.codes(text) do
		table.insert(chars, utf8.char(code))
	end
	return table.concat(chars, string.rep(HAIR, n or 1))
end
-- A label in the mock-up's `px` CSS size of `face`, its box the CSS line
-- box: `lh` (line-height, nil = the font's own) times `lines`. Position it
-- by that box, as the mock-up's x/y place it.
local function mockText(props: { [string]: any }, px: number, face: string, lh: number?, lines: number?): TextLabel
	local factor = FACE[face]
	local size = math.round(px * factor * MOCK)
	local n = lines or 1
	local box = if lh then math.round(px * lh * MOCK) * n else size * n
	local font = if face == "sans" then F.bodySemibold elseif face == "elite" then F.typewriter else F.stencil
	-- Roblox caps TextSize at 100: past that, a UIScale makes up the rest.
	local grow = if size > 100 then size / 100 else 1
	local label = Kit.label(Dossier.merge({ FontFace = font, TextSize = math.min(size, 100), TextYAlignment = Enum.TextYAlignment.Center, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, math.round(box / grow)) }, props))
	if lh then
		label.LineHeight = lh / factor
	end
	if grow > 1 then
		Kit.new("UIScale", { Scale = grow, Parent = label })
	end
	return label
end

-- A banner photo washed dark at the left and `wash` at the right, under a
-- card's words (`from`, `mid`, `to`: how strongly the dark shows).
local function washedPhoto(parent: GuiObject, photo: string?, wash: Color3, radius: number, darkLeft: number?)
	local z = parent.ZIndex
	local image = if photo then A[photo] else nil
	if image and image ~= "" then
		local pic = Kit.new("ImageLabel", { Name = "Banner", BackgroundTransparency = 1, Image = image, ScaleType = Enum.ScaleType.Crop, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = parent })
		Kit.corner(radius).Parent = pic
	end
	local veil = Kit.new("Frame", { Name = "Wash", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = parent })
	Kit.corner(radius).Parent = veil
	local dark = Color3.fromHex("#0C120E")
	Kit.new("UIGradient", {
		Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, dark), ColorSequenceKeypoint.new(0.4, dark), ColorSequenceKeypoint.new(1, wash) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, darkLeft or 0.08), NumberSequenceKeypoint.new(0.4, 0.4), NumberSequenceKeypoint.new(1, 0.38) }),
		Parent = veil,
	})
	return veil
end

-- The darker gold lip under a gold plate (the mock-up's 6 px "shadow"), a
-- sibling just behind and below it, so the plate seems to stand up.
local function goldLip(plate: GuiObject, drop: number, radius: number)
	local lip = Kit.new("Frame", { Name = plate.Name .. "Lip", BackgroundColor3 = Color3.fromHex("#8A6200"), BorderSizePixel = 0, AnchorPoint = plate.AnchorPoint, Position = plate.Position + UDim2.fromOffset(0, drop), Size = plate.Size, ZIndex = plate.ZIndex - 1, Parent = plate.Parent })
	Kit.corner(radius).Parent = lip
	Kit.stroke(HudStyle.EDGE, 3, 0).Parent = lip
end

-- SOLO DEPLOYMENT over PLAY, centred together on the plate (the mock-up).
local function playWords(plate: GuiObject, kickSize: number, playSize: number, mock: boolean?)
	local stack = Kit.new("Frame", { Name = "Words", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = plate.ZIndex + 1, Parent = plate })
	Kit.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = stack
	if mock then
		-- (Desktop: the mock-up's 13 px kicker, spaced 0.16 em, over 64 px PLAY.)
		mockText({ Text = spaced("SOLO DEPLOYMENT", 2), FontFace = F.labelSemibold, TextColor3 = Color3.fromHex("#7A5300"), LayoutOrder = 1, ZIndex = plate.ZIndex + 1, Parent = stack }, kickSize, "oswald")
		mockText({ Text = "PLAY", TextColor3 = HudStyle.BROWN, LayoutOrder = 2, ZIndex = plate.ZIndex + 1, Parent = stack }, playSize, "oswald", 1)
		return
	end
	Dossier.stencil({ Text = spaced("SOLO DEPLOYMENT", 2), TextSize = kickSize, TextColor3 = Color3.fromHex("#7A5300"), LayoutOrder = 1, ZIndex = plate.ZIndex + 1, Parent = stack })
	Dossier.stencil({ Text = "PLAY", TextSize = playSize, LineHeight = 0.9, TextColor3 = HudStyle.BROWN, LayoutOrder = 2, ZIndex = plate.ZIndex + 1, Parent = stack })
end

-- A fade from clear to the sheet's dark along the foot of a banner.
local function footFade(parent: GuiObject, height: number)
	local f = Kit.new("Frame", { Name = "Foot", BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, height), ZIndex = parent.ZIndex, Parent = parent })
	Kit.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0), Parent = f })
end

function MainMenu.new(host: Frame, root: any, actions: Actions)
	local self = setmetatable({
		actions = actions,
		host = host,
		root = root,
		connections = {} :: { RBXScriptConnection },
		queued = nil :: string?,
		lobbyAt = nil :: number?,
		soloMap = "World",
		difficulty = "Medium",
		flagShopEndsAt = 0,
		flagId = nil :: string?,
		built = {} :: { RBXScriptConnection },
		musicOn = true,
		compact = false,
		builtW = 0,
		builtLeft = 0,
	}, MainMenu)

	local frame = Kit.new("Frame", { Name = "MainMenu", BackgroundColor3 = C.desk, BorderSizePixel = 0, ClipsDescendants = true, Size = UDim2.fromScale(1, 1), Parent = host })
	self.frame = frame
	Dossier.preload()

	-- The live map under the folder (seen on screens wider than the folder),
	-- drifting slowly, nearly dark.
	local aspect = UiAssets.BACKDROP_SIZE.X / UiAssets.BACKDROP_SIZE.Y
	local backdrop = Kit.new("Frame", { Name = "Backdrop", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1.16, 1.16), Parent = frame })
	Kit.new("UIAspectRatioConstraint", { AspectRatio = aspect, AspectType = Enum.AspectType.ScaleWithParentSize, DominantAxis = Enum.DominantAxis.Height, Parent = backdrop })
	for i, image in UiAssets.backdrop do
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = image, Position = UDim2.fromScale((i - 1) * 0.5, 0), Size = UDim2.fromScale(0.5, 1), ScaleType = Enum.ScaleType.Stretch, Parent = backdrop })
	end
	local drift = TweenService:Create(backdrop, TweenInfo.new(40, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Position = UDim2.new(0.5, -40, 0.5, 14) })
	drift:Play()
	self.drift = drift
	Kit.new("Frame", { Name = "Shade", BackgroundColor3 = C.desk, BackgroundTransparency = 0.12, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = frame })

	self:_build()
	-- A phone turned into a different size, or a window resized across the
	-- phone threshold, lays the menu out again.
	table.insert(self.connections, root.Changed.Event:Connect(function()
		if root.compact ~= self.compact or (root.compact and (math.abs(root.width - self.builtW) > 1 or math.abs(root.topLeft - self.builtLeft) > 1)) then
			self:_rebuild()
		end
	end))

	-- Countdowns tick locally between server updates.
	local acc = 0
	table.insert(self.connections, game:GetService("RunService").Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		self:_tick()
	end))
	return self
end

function MainMenu._buildDesktop(self: any)
	local actions = self.actions
	local aspect = UiAssets.BACKDROP_SIZE.X / UiAssets.BACKDROP_SIZE.Y
	local stage = Kit.new("Frame", { Name = "Stage", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(STAGE_W, STAGE_H), Parent = self.layer })
	self.stage = stage
	local S = SHEET

	-- The sheet.
	local sheet = Kit.new("Frame", { Name = "Sheet", BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, Position = UDim2.fromOffset(S.x, S.y), Size = UDim2.fromOffset(S.w, S.h), ZIndex = 2, Parent = stage })
	Kit.corner(24).Parent = sheet
	Kit.stroke(HudStyle.EDGE, 5, 0).Parent = sheet

	-- The title banner: the supply-drop photo, dark at the left, gold at the
	-- right, fading into the sheet.
	local banner = Kit.new("Frame", { Name = "TitleBanner", BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, m(132)), ZIndex = 2, Parent = sheet })
	Kit.corner(24).Parent = banner
	washedPhoto(banner, "banner_starter", HudStyle.WASH.gold, 24, 0.05)
	footFade(banner, m(50))
	mockText({ Text = "Fork of OpenFront", TextColor3 = Color3.fromHex("#F3D488"), Position = mAt(36, 14), ZIndex = 3, Parent = banner }, 15, "elite")
	mockText({ Name = "Title", Text = "CONQUER COUNTRIES", TextColor3 = HudStyle.TEXT, Position = mAt(32, 34), ZIndex = 3, Parent = banner }, 74, "oswald", 1)

	-- Top right: TOP SECRET, your stars, settings and sound.
	local corner = Kit.new("Frame", { Name = "Corner", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -m(24), 0, m(22)), Size = UDim2.fromOffset(0, m(44)), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 3, Parent = banner })
	Kit.list(Enum.FillDirection.Horizontal, m(10), Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent = corner
	local secret = Kit.new("Frame", { Name = "Secret", BackgroundColor3 = Color3.fromHex("#140804"), BackgroundTransparency = 0.3, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, Rotation = -3, LayoutOrder = 1, ZIndex = 3, Parent = corner })
	Kit.stroke(Color3.fromHex("#E0483C"), 2.5, 0).Parent = secret
	Kit.corner(8).Parent = secret
	Kit.padding(m(3), m(10)).Parent = secret
	mockText({ Text = spaced("TOP SECRET"), TextColor3 = Color3.fromHex("#FF7A6C"), ZIndex = 3, Parent = secret }, 14, "oswald")
	local stars = Kit.new("Frame", { Name = "Stars", BackgroundColor3 = Color3.fromHex("#140804"), BackgroundTransparency = 0.25, BorderSizePixel = 0, Size = UDim2.fromOffset(0, m(44)), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 3, Parent = corner })
	Kit.corner(13).Parent = stars
	Kit.stroke(HudStyle.GOLD, 1.5, 0.55).Parent = stars
	Kit.padding(0, m(14)).Parent = stars
	Kit.list(Enum.FillDirection.Horizontal, m(8), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = stars
	Kit.glyph("star", { ImageColor3 = HudStyle.GOLD, Size = UDim2.fromOffset(m(18), m(18)), LayoutOrder = 1, ZIndex = 3, Parent = stars })
	self.starsText = mockText({ Name = "Stars", Text = "…", TextColor3 = HudStyle.TEXT, LayoutOrder = 2, ZIndex = 3, Parent = stars }, 22, "oswald")
	local function cornerIcon(glyph: string, tint: string, order: number, tip: string, onClick: () -> ()): TextButton
		local b = HudStyle.iconButton(glyph, Color3.fromHex(tint), { Size = UDim2.fromOffset(m(44), m(44)), LayoutOrder = order, ZIndex = 3, Parent = corner })
		local glyphIcon = b:FindFirstChild("Icon") :: ImageLabel
		glyphIcon.Size = UDim2.fromOffset(m(22), m(22))
		glyphIcon.ZIndex = 3
		Dossier.clicky(b, 1.1)
		b.Activated:Connect(function()
			click()
			onClick()
		end)
		Kit.tip(b, function(card)
			Kit.text({ Text = tip, FontFace = F.uiBold, Parent = card })
		end)
		return b
	end
	cornerIcon("settings", "#264B78", 3, "Settings", actions.openSettings)
	self.soundSlash = Kit.slash(cornerIcon("music", "#22343F", 4, "Music", actions.toggleMusic))
	self:setMusicOn(self.musicOn)
	-- (The old crate-price badge: hidden since 2026-11-23, kept for setProfile.)
	local badge = Kit.new("TextButton", { Name = "CratePrice", Text = "", Visible = false, Parent = stage })
	self.crateText = stencil({ Text = "", Parent = badge })
	self.crateBadge = badge

	-- Left: MILITARY REQUISITIONS, up the edge.
	local spine = Kit.new("Frame", { Name = "Requisitions", BackgroundTransparency = 1, Position = mAt(12, 150), Size = mSz(22, 530), ZIndex = 2, Parent = sheet })
	mockText({ Text = spaced("MILITARY REQUISITIONS", 2), FontFace = F.labelSemibold, TextColor3 = Color3.fromHex("#7F948A"), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Rotation = -90, ZIndex = 2, Parent = spine }, 14, "oswald")

	-- The four requisition cards.
	local CARD_X, CARD_W, CARD_H, CARD_GAP = 44, 244, 124, 10
	local function requisition(name: string, title: string, kicker: string, i: number, photo: string, wash: Color3, sil: string, onClick: () -> ()): TextButton
		local y = 148 + (i - 1) * (CARD_H + CARD_GAP)
		local card = Kit.new("TextButton", { Name = name, Text = "", AutoButtonColor = false, BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = mAt(CARD_X + CARD_W / 2, y + CARD_H / 2), Size = mSz(CARD_W, CARD_H), ZIndex = 3, Parent = sheet }) :: TextButton
		Kit.corner(16).Parent = card
		Kit.stroke(HudStyle.EDGE, 4, 0).Parent = card
		washedPhoto(card, photo, wash, 16)
		mockText({ Name = "Kicker", Text = spaced(kicker), FontFace = F.labelSemibold, TextColor3 = wash:Lerp(Color3.new(1, 1, 1), 0.6), Position = mAt(18, 18), ZIndex = 5, Parent = card }, 12, "oswald")
		mockText({ Name = "Name", Text = title, TextColor3 = HudStyle.TEXT, Position = mAt(16, 36), ZIndex = 5, Parent = card }, 34, "oswald", 0.95)
		-- The cream silhouette (Codex), 78 square, hard at the right: further
		-- right than the mock-up so the flag's pole clears FLAG SHOP (Bruno).
		Kit.new("ImageLabel", { Name = "Icon", BackgroundTransparency = 1, Image = A[sil] or "", ImageTransparency = 0.1, ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -m(4), 0.5, 0), Size = mSz(78, 78), ZIndex = 4, Parent = card })
		Dossier.clicky(card, 1.03)
		card.Activated:Connect(function()
			click()
			onClick()
		end)
		return card
	end
	local W = HudStyle.WASH
	local party = requisition("Party", "PARTY", "PLAY WITH FRIENDS", 1, "banner_party", W.pink, "sil_party", actions.openParty)
	self.partyText = mockText({ Name = "Squad", Text = "", TextColor3 = Color3.fromHex("#F4D3E0"), Position = mAt(18, 76), Visible = false, ZIndex = 5, Parent = party }, 13, "elite")
	local armory = requisition("Armory", "SHOP", "WEAPONS & BOOSTS", 2, "banner_arsenal", W.gold, "sil_shop", function()
		if actions.openShop then
			actions.openShop(nil)
		else
			actions.openArsenal()
		end
	end)
	self:_dealRibbon(armory, UDim2.new(0, 0, 1, -m(24)), UDim2.new(1, 0, 0, m(24)), m(12 * FACE.oswald))
	local crates = requisition("Crates", "LOCKER", "CRATES & FLAGS", 3, "banner_locker", W.purple, "sil_locker", actions.openLocker)
	local lockerName = crates:FindFirstChild("Name") :: TextLabel
	self:_crateRibbon(crates, UDim2.new(0, 0, 1, -m(24)), UDim2.new(1, 0, 0, m(24)), m(12 * FACE.oswald), lockerName.Position)
	local shop = requisition("FlagShop", "FLAG SHOP", "NEW THIS WEEK", 4, "banner_flags", W.orange, "sil_flag", actions.openFlagShop)
	local ribbon = Kit.new("Frame", { Name = "Ribbon", BackgroundColor3 = W.orange, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, m(24)), ZIndex = 5, Parent = shop })
	Kit.corner(16).Parent = ribbon
	-- (Squares off the ribbon's top corners: only the card's bottom is round.)
	Kit.new("Frame", { BackgroundColor3 = W.orange, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.5, 0), ZIndex = 5, Parent = ribbon })
	self.flagEvent = mockText({ Text = "TODAY'S FLAGS", TextColor3 = HudStyle.TEXT, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, m(12), 0.5, 0), ZIndex = 6, Parent = ribbon }, 12, "oswald")
	self.flagTimer = mockText({ Text = "", TextColor3 = Color3.fromHex("#FFE3CC"), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -m(12), 0.5, 0), ZIndex = 6, Parent = ribbon }, 11, "sans")

	-- Centre: the live map in a dark frame.
	local map = Kit.new("Frame", { Name = "WarMap", BackgroundColor3 = HudStyle.EDGE, BorderSizePixel = 0, ClipsDescendants = true, Position = mAt(306, 148), Size = mSz(592, 380), ZIndex = 3, Parent = sheet })
	Kit.corner(16).Parent = map
	Kit.stroke(HudStyle.EDGE, 4, 0).Parent = map
	local viewH = m(380)
	local world = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(math.ceil(viewH * aspect), viewH), ZIndex = 3, Parent = map })
	for i, image in UiAssets.backdrop do
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = image, Position = UDim2.fromScale((i - 1) * 0.5, 0), Size = UDim2.fromScale(0.5, 1), ScaleType = Enum.ScaleType.Stretch, ZIndex = 3, Parent = world })
	end
	Kit.new("Frame", { Name = "Slate", BackgroundColor3 = Color3.fromRGB(20, 30, 28), BackgroundTransparency = 0.6, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = map })

	-- The featured public queue (World): DEPLOY TO FRONTLINE.
	-- (Bruno, 2026-11-24: "Same card, shorter", so more of the map shows.)
	local front = HudStyle.panel("Frame", { Name = "Frontline", Position = mAt(660, 168), Size = mSz(250, 196), ZIndex = 4, Parent = sheet }, 16)
	front.ClipsDescendants = false
	local frontHead = Kit.new("Frame", { Name = "Head", BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, m(98)), ZIndex = 4, Parent = front })
	Kit.corner(16).Parent = frontHead
	washedPhoto(frontHead, "banner_orders", W.green, 16)
	footFade(frontHead, m(30))
	mockText({ Text = "Orders", TextColor3 = Color3.fromHex("#A3D2AB"), Position = mAt(16, 12), ZIndex = 5, Parent = frontHead }, 13, "elite")
	mockText({ Text = "DEPLOY TO\nFRONTLINE", TextColor3 = HudStyle.TEXT, Position = mAt(14, 30), ZIndex = 5, Parent = frontHead }, 30, "oswald", 0.95, 2)
	local frontBtn = HudStyle.goldPlate({ Name = "Join", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, m(102)), Size = UDim2.new(1, -m(32), 0, m(52)), ZIndex = 6, Parent = front }, 14)
	goldLip(frontBtn, m(4), 14)
	local frontLabel = mockText({ Text = "JOIN", TextColor3 = HudStyle.BROWN, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 6, Parent = frontBtn }, 28, "oswald")
	Dossier.clicky(frontBtn, 1.05)
	local frontCount = mockText({ Text = "", FontFace = F.labelSemibold, TextColor3 = HudStyle.SOFT, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -m(12)), ZIndex = 5, Parent = front }, 13, "oswald")
	self.front = { frame = front, btn = frontBtn, label = frontLabel, count = frontCount, data = nil :: any }
	frontBtn.Activated:Connect(function()
		self:_press(self.front.data)
	end)

	-- Right: PLAY (General and Campaign sit above it, MenuCards).
	-- (Bruno, 2026-11-24: "Make it look like the mockup": the words centred
	-- together, a darker gold lip under the plate.)
	local play = HudStyle.goldPlate({ Name = "Play", AnchorPoint = Vector2.new(0.5, 0.5), Position = mAt(930 + 165, 410 + 56), Size = mSz(330, 112), ZIndex = 5, Parent = sheet }, 20)
	goldLip(play, m(6), 20)
	playWords(play, 13, 64, true)
	play.Activated:Connect(function()
		self:showSolo(true)
	end)
	Dossier.clicky(play, 1.05)

	-- Bottom: the other public queues, under teal headers.
	self.reports = {}
	local RW, RGAP = (954 - 28) / 3, 14
	for i = 1, 3 do
		local x = 306 + (i - 1) * (RW + RGAP)
		local card = Kit.new("TextButton", { Name = `Report{i}`, Text = "", AutoButtonColor = false, BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = mAt(x + RW / 2, 548 + 82), Size = mSz(RW, 164), ZIndex = 3, Parent = sheet }) :: TextButton
		Kit.corner(16).Parent = card
		Kit.stroke(HudStyle.EDGE, 4, 0).Parent = card
		local head = HudStyle.header(card, m(44), W.teal, 16)
		local header = mockText({ Text = "", TextColor3 = Color3.fromHex("#CFF3F3"), TextTruncate = Enum.TextTruncate.AtEnd, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, m(14), 0.5, 0), ZIndex = 4, Parent = head }, 14, "elite")
		header.AutomaticSize = Enum.AutomaticSize.None
		header.Size = UDim2.new(1, -m(120), 0, header.Size.Y.Offset)
		local tag = Kit.new("Frame", { Name = "Tag", BackgroundColor3 = Color3.fromHex("#080C0A"), BackgroundTransparency = 0.2, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -m(10), 0.5, 0), Size = mSz(70, 26), ZIndex = 4, Parent = head })
		Kit.corner(8).Parent = tag
		local dot = Kit.new("Frame", { BackgroundColor3 = C.ok, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, m(13), 0.5, 0), Size = mSz(8, 8), ZIndex = 4, Parent = tag })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
		local tagText = mockText({ Text = "LIVE", FontFace = F.labelSemibold, TextColor3 = HudStyle.TEXT, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, m(23), 0.5, 0), ZIndex = 4, Parent = tag }, 14, "oswald")
		local name = mockText({ Text = "", TextColor3 = HudStyle.TEXT, TextTruncate = Enum.TextTruncate.AtEnd, Position = mAt(14, 56), ZIndex = 4, Parent = card }, 28, "oswald")
		name.AutomaticSize = Enum.AutomaticSize.None
		name.Size = UDim2.new(1, -m(140), 0, name.Size.Y.Offset)
		-- A long name ("SOUTH AMERICA") shrinks to fit rather than cut off.
		Kit.new("UITextSizeConstraint", { MaxTextSize = name.TextSize, MinTextSize = 18, Parent = name })
		name.TextScaled = true
		local count = mockText({ Text = "", TextColor3 = HudStyle.MUTED, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, m(14), 1, -m(14)), ZIndex = 4, Parent = card }, 14, "sans")
		-- The map, or the team's soldiers, at the bottom right.
		local photo = Kit.new("Frame", { Name = "Photo", BackgroundColor3 = HudStyle.EDGE, BorderSizePixel = 0, ClipsDescendants = true, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -m(14), 1, -m(14)), Size = mSz(108, 76), ZIndex = 4, Parent = card })
		Kit.corner(10).Parent = photo
		local photoTape = Kit.new("Frame", { Name = "NoTape", BackgroundTransparency = 1, Parent = card })
		local team = Kit.new("ImageLabel", { Name = "Team", BackgroundTransparency = 1, Image = A.sil_team or "", ImageTransparency = 0.1, ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -m(14), 1, -m(14)), Size = mSz(108, 76), Visible = false, ZIndex = 4, Parent = card })
		local r: any
		Dossier.clicky(card, 1.03)
		card.Activated:Connect(function()
			click()
			self:_press(r.data)
		end)
		r = { frame = card, header = header, name = name, count = count, tag = tag, dot = dot, tagText = tagText, photo = photo, photoTape = photoTape, team = team, pic = nil :: Instance?, picFor = nil :: string?, data = nil :: any }
		Kit.tip(card, function(tip)
			Kit.text({ Text = if r.data then actionText(r.data, self.queued == r.data.id) else "", FontFace = F.uiBold, Parent = tip })
		end)
		self.reports[i] = r
	end

	-- The credits strip (LICENSING_PLAN 7(b) and 7(c); CC BY-SA attribution),
	-- which opens the credits and source window (Bruno, 2026-11-08).
	local bar = Kit.new("TextButton", { Name = "Credits", Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.fromHex("#0A120E"), BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, m(30)), ZIndex = 45, Parent = sheet })
	Kit.corner(24).Parent = bar
	Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#0A120E"), BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.5, 0), ZIndex = 45, Parent = bar })
	self:_creditsButton(bar)
	Kit.label({
		Text = CreditsText.BAR,
		FontFace = F.bodySemibold,
		TextSize = m(12 * FACE.sans),
		TextColor3 = HudStyle.MUTED,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ZIndex = 46,
		Parent = bar,
	})

	self:_buildOrders(stage)
	self.tagSizes = { mSz(70, 26), mSz(96, 26) }
end

-- The credits bar opens the credits window, with the menus' click.
function MainMenu._creditsButton(self: any, bar: TextButton)
	bar.Activated:Connect(function()
		if Kit.covered(bar) then
			return
		end
		Dossier.thud()
		if self.actions.openCredits then
			self.actions.openCredits()
		end
	end)
end

-- Lays the menu out for the screen: the phone layout or the desktop one.
function MainMenu._build(self: any)
	local root = self.root
	self.compact, self.builtW, self.builtLeft = root.compact, root.width, root.topLeft
	K = if self.compact then 1 else DESKTOP_K
	self.layer = Kit.new("Frame", { Name = "Layout", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = self.frame })
	if self.compact then
		self:_buildCompact()
	else
		self:_buildDesktop()
	end
	self:_buildStarterTag()
end

-- The starter pack's red tag under the stars note: STARTER PACK and its
-- countdown (setProfile shows it while the offer is for this player).
-- In front of Conquest General's card (Bruno, 2026-11-13): ZIndex 14 over its 13.
function MainMenu._buildStarterTag(self: any)
	local compact = self.compact
	local tag = Kit.new("TextButton", { Name = "StarterTag", Text = "", AutoButtonColor = false, BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = if compact then UDim2.new(1, -140, 0, 80) else UDim2.fromOffset(1690, 128), Size = if compact then UDim2.fromOffset(250, 56) else sz(150, 30), Rotation = -2, Visible = false, ZIndex = 14, Parent = if compact then self.layer else self.stage })
	Kit.corner(6).Parent = tag
	Kit.stroke(Color3.fromHex("#6E1A14"), 2, 0).Parent = tag
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = tag
	self.starterGlyph = Kit.glyph("gift", { ImageColor3 = C.sheet, Size = UDim2.fromOffset(if compact then 30 else 34, if compact then 30 else 34), LayoutOrder = 1, ZIndex = 14, Parent = tag })
	local words = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 14, Parent = tag })
	Kit.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = words
	self.starterTitle = stencil({ Text = "STARTER PACK", TextSize = if compact then 22 else 26, TextColor3 = C.sheet, LayoutOrder = 1, ZIndex = 14, Parent = words })
	self.starterTimer = stencil({ Text = "", TextSize = if compact then 16 else 18, TextColor3 = Color3.fromHex("#F3D9C8"), LayoutOrder = 2, ZIndex = 14, Parent = words })
	Dossier.clicky(tag, 1.06)
	tag.Activated:Connect(function()
		click()
		local view = self.lastView
		if view and view.gift == "claimable" then
			if self.actions.openGift then
				self.actions.openGift()
			end
		elseif self.actions.openStarter then
			self.actions.openStarter()
		end
	end)
	self.starterTag = tag
	self.starterStroke = tag:FindFirstChildOfClass("UIStroke")

	-- The General and Campaign cards (Bruno, 2026-11-23: option A, "Framed
	-- photos", where SOLO DEPLOYMENT was). Desktop: two wide cards stacked
	-- above PLAY; a phone: two tiles side by side.
	local host = self.stage
	local function sizeAndPlace(i: number): (Vector2, UDim2)
		if compact then
			local W = self.root.width
			-- (Bruno, 2026-11-23: smaller, further apart.)
			return Vector2.new(108, 88), UDim2.fromOffset(W - 140 + (if i == 1 then -62 else 62), 190)
		end
		-- Style B: the mock-up's 330x116 cards at x 930, y 148 and 278 on
		-- the sheet (SHEET, 1 / 0.736 canvas units a pixel).
		local k = 1 / 0.736
		return Vector2.new(math.round(330 * k), math.round(116 * k)), UDim2.fromOffset(SHEET.x + math.round((930 + 165) * k), SHEET.y + math.round((if i == 1 then 148 + 58 else 278 + 58) * k))
	end
	if Catalog.SUBSCRIPTION.id ~= "" then
		local size, pos = sizeAndPlace(1)
		self.generalCard = MenuCards.card(host, {
			name = "GeneralCard",
			title = "GENERAL",
			colors = { Color3.fromHex("#5B4A12"), Color3.fromHex("#B8860B"), Color3.fromHex("#FFD75E") },
			kickInk = Color3.fromHex("#3B2B00"),
			kickFill = Color3.fromHex("#FFE08A"),
			wash = HudStyle.WASH.gold,
			photo = "banner_general",
			picture = function(holder)
				if (A.arsenal_general or "") ~= "" then
					Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = A.arsenal_general, ScaleType = Enum.ScaleType.Crop, Size = UDim2.fromScale(1, 1), Parent = holder })
				end
			end,
			onPress = function()
				if self.actions.openGeneral then
					self.actions.openGeneral()
				end
			end,
		}, size, not compact, { Position = pos, Rotation = 0, ZIndex = 13 })
		self.generalCard.setKicker("MONTHLY")
		self.generalCard.setLine("A crate a day, +50% stars")
	end
	do
		local size, pos = sizeAndPlace(2)
		self.passCard = MenuCards.card(host, {
			name = "PassCard",
			title = "CAMPAIGN",
			colors = { Color3.fromHex("#1B1F5E"), Color3.fromHex("#4A2FB0"), Color3.fromHex("#8E6CFF") },
			kickInk = Color3.fromHex("#1B1F5E"),
			kickFill = Color3.fromHex("#BFB0FF"),
			wash = HudStyle.WASH.ember,
			photo = "arsenal_mega",
			picture = function(holder)
				Art.flag("o_campaign1_c", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.95, 0.9), Parent = holder })
			end,
			onPress = function()
				if self.actions.openPass then
					self.actions.openPass()
				end
			end,
		}, size, not compact, { Position = pos, Rotation = 0, ZIndex = 13 })
		self.passCard.root.Visible = false
	end
end

-- Today's Arsenal deal (Bruno, 2026-11-16): a red DEAL -40% ribbon on the
-- ARSENAL folder, like the Flag Shop's TODAY'S FLAGS; setProfile shows it
-- while the player has a deal today (Catalog.todaysDeal).
function MainMenu._dealRibbon(self: any, card: Instance, pos: UDim2, size: UDim2, textSize: number)
	self.dealRibbon = MainMenu._redRibbon("DealRibbon", `DEAL -{math.round(Catalog.DEAL.off * 100)}%`, card, pos, size, textSize)
	self.dealDay = nil
	self:_paintDeal()
end

-- A red ribbon across a requisition folder (hidden until shown).
-- Above the card's photo and wash (they sit at the card's own ZIndex; at the
-- default 1 the ribbon hid under them, showing only past the card's edge:
-- Bruno, 2026-11-24), and shaped like the Flag Shop's ribbon: the card's
-- rounded bottom, square on top.
function MainMenu._redRibbon(name: string, text: string, card: Instance, pos: UDim2, size: UDim2, textSize: number): Frame
	local z = if card:IsA("GuiObject") then card.ZIndex + 2 else 5
	local red = Color3.fromHex("#D8342B")
	local ribbon = Kit.new("Frame", { Name = name, BackgroundColor3 = red, BorderSizePixel = 0, Position = pos, Size = size, Visible = false, ZIndex = z, Parent = card }) :: Frame
	local round = card:FindFirstChildOfClass("UICorner")
	if round then
		Kit.new("UICorner", { CornerRadius = round.CornerRadius, Parent = ribbon })
		Kit.new("Frame", { Name = "Square", BackgroundColor3 = red, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.5, 0), ZIndex = z, Parent = ribbon })
	end
	stencil({ Text = text, TextSize = textSize, TextColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(size.Y.Offset / 2), 0.5, 0), ZIndex = z + 1, Parent = ribbon })
	return ribbon
end

-- The free crate (Bruno, 2026-11-16): a red FREE CRATE ribbon on the
-- LOCKER folder (SUPPLY CRATES until 2026-11-23) while it waits; the two-line name moves up to `namePos` for it.
function MainMenu._crateRibbon(self: any, card: Instance, pos: UDim2, size: UDim2, textSize: number, namePos: UDim2)
	self.crateRibbon = MainMenu._redRibbon("FreeCrateRibbon", "FREE CRATE", card, pos, size, textSize)
	local name = card:FindFirstChild("Name") :: TextLabel?
	self.crateName = name
	self.crateNameAt = if name then { normal = name.Position, raised = namePos } else nil
	self:_paintDeal()
end

-- Shows the ribbons for the profile view: the free crate's, and the deal's
-- for today (again at midnight UTC).
function MainMenu._paintDeal(self: any)
	local view = self.lastView
	if view == nil then
		return
	end
	if self.crateRibbon then
		local on = view.freeCrate == true
		self.crateRibbon.Visible = on
		if self.crateName and self.crateNameAt then
			self.crateName.Position = if on then self.crateNameAt.raised else self.crateNameAt.normal
		end
	end
	if self.dealRibbon == nil then
		return
	end
	local mine = {}
	for _, id in view.owned or {} do
		mine[id] = true
	end
	local player = Players.LocalPlayer
	self.dealDay = os.time() // 86400
	self.dealRibbon.Visible = Catalog.todaysDeal(if player then player.UserId else 0, os.time(), mine, view.dealDay) ~= nil
end

-- Builds the layout again and puts back what the screen was showing.
function MainMenu._rebuild(self: any)
	local party = self.partyText.Text
	local solo = self.orders.Visible
	for _, c in self.built do
		c:Disconnect()
	end
	table.clear(self.built)
	self.layer:Destroy()
	self:_build()
	self.partyText.Text = party
	if self.lastView then
		self:setProfile(self.lastView)
	end
	self.flagEvent.Text = string.upper(self.flagEventName or "Today's flags")
	if self.lastRows then
		self:setLobbies(self.lastRows, self.queued, self.queueState)
	end
	self:_tick()
	self:showSolo(solo)
end

-- The phone layout (Bruno, 2026-10-27: rearranged for a short, wide screen,
-- with bigger type and touch targets), in canvas units on Root's compact
-- canvas (W x 540; K = 1):
--   top      the title strip right of Roblox's buttons; stars, the crate
--            price, settings and sound on a note at the right
--   left     the four requisition folders, stacked
--   centre   the war map with the frontline note and its JOIN
--   right    the SOLO DEPLOYMENT stamp over PLAY
--   bottom   the three field reports, then the credits line
function MainMenu._buildCompact(self: any)
	local root, actions = self.root, self.actions
	local W = root.width
	local aspect = UiAssets.BACKDROP_SIZE.X / UiAssets.BACKDROP_SIZE.Y
	local stage = Kit.new("Frame", { Name = "Stage", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = self.layer })
	self.stage = stage
	local WASH = HudStyle.WASH

	-- Style B (2026-11-24): one dark sheet, as on desktop.
	local sheet = Kit.new("Frame", { Name = "Sheet", BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, Position = UDim2.fromOffset(4, 4), Size = UDim2.fromOffset(W - 8, 532), ZIndex = 1, Parent = stage })
	Kit.corner(18).Parent = sheet
	Kit.stroke(HudStyle.EDGE, 4, 0).Parent = sheet

	-- Top: the title banner (right of Roblox's buttons), with stars,
	-- settings and sound at its right end.
	local banner = Kit.new("Frame", { Name = "TitleBanner", BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 80), ZIndex = 2, Parent = sheet })
	Kit.corner(18).Parent = banner
	washedPhoto(banner, "banner_starter", WASH.gold, 18, 0.05)
	footFade(banner, 24)
	stencil({ Name = "Title", Text = "CONQUER COUNTRIES", TextSize = 46, TextColor3 = HudStyle.TEXT, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.max(16, root.topLeft + 4), 0.5, -2), ZIndex = 3, Parent = banner })
	local corner = Kit.new("Frame", { Name = "Corner", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, -2), Size = UDim2.fromOffset(0, 54), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 3, Parent = banner })
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent = corner
	local stars = Kit.new("Frame", { Name = "Stars", BackgroundColor3 = Color3.fromHex("#140804"), BackgroundTransparency = 0.25, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 54), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, ZIndex = 3, Parent = corner })
	Kit.corner(13).Parent = stars
	Kit.stroke(HudStyle.GOLD, 1.5, 0.55).Parent = stars
	Kit.padding(0, 14).Parent = stars
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = stars
	Kit.glyph("star", { ImageColor3 = HudStyle.GOLD, Size = UDim2.fromOffset(24, 24), LayoutOrder = 1, ZIndex = 3, Parent = stars })
	self.starsText = stencil({ Name = "Stars", Text = "…", TextSize = 34, TextColor3 = HudStyle.TEXT, LayoutOrder = 2, ZIndex = 3, Parent = stars })
	local function cornerIcon(glyph: string, tint: string, order: number, onClick: () -> ()): TextButton
		local b = HudStyle.iconButton(glyph, Color3.fromHex(tint), { Size = UDim2.fromOffset(54, 54), LayoutOrder = order, ZIndex = 3, Parent = corner })
		local glyphIcon = b:FindFirstChild("Icon") :: ImageLabel
		glyphIcon.Size = UDim2.fromOffset(30, 30)
		glyphIcon.ZIndex = 3
		Dossier.clicky(b, 1.1)
		b.Activated:Connect(function()
			click()
			onClick()
		end)
		return b
	end
	cornerIcon("settings", "#264B78", 2, actions.openSettings)
	self.soundSlash = Kit.slash(cornerIcon("music", "#22343F", 3, actions.toggleMusic))
	self:setMusicOn(self.musicOn)
	local badge = Kit.new("TextButton", { Name = "CratePrice", Text = "", Visible = false, Parent = stage })
	self.crateText = stencil({ Text = "", Parent = badge })
	self.crateBadge = badge

	-- Left: the four requisition cards.
	local function requisition(name: string, title: string, kicker: string, y: number, photo: string, wash: Color3, sil: string, onClick: () -> ()): TextButton
		local card = Kit.new("TextButton", { Name = name, Text = "", AutoButtonColor = false, BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(12 + 133, y + 48), Size = UDim2.fromOffset(266, 96), ZIndex = 3, Parent = stage }) :: TextButton
		Kit.corner(14).Parent = card
		Kit.stroke(HudStyle.EDGE, 3, 0).Parent = card
		washedPhoto(card, photo, wash, 14)
		Kit.label({ Name = "Kicker", Text = spaced(kicker), FontFace = F.labelSemibold, TextSize = 17, TextColor3 = wash:Lerp(Color3.new(1, 1, 1), 0.6), Position = UDim2.fromOffset(14, 8), ZIndex = 5, Parent = card })
		stencil({ Name = "Name", Text = title, TextSize = 46, LineHeight = 0.9, TextColor3 = HudStyle.TEXT, Position = UDim2.fromOffset(13, 26), ZIndex = 5, Parent = card })
		Kit.new("ImageLabel", { Name = "Icon", BackgroundTransparency = 1, Image = A[sil] or "", ImageTransparency = 0.1, ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(84, 70), ZIndex = 4, Parent = card })
		Dossier.clicky(card, 1.03)
		card.Activated:Connect(function()
			click()
			onClick()
		end)
		return card
	end
	local party = requisition("Party", "PARTY", "PLAY WITH FRIENDS", 86, "banner_party", WASH.pink, "sil_party", actions.openParty)
	self.partyText = typed({ Name = "Squad", Text = "", TextSize = 16, TextColor3 = Color3.fromHex("#F4D3E0"), Position = UDim2.fromOffset(14, 68), Visible = false, ZIndex = 4, Parent = party })
	local armory = requisition("Armory", "SHOP", "WEAPONS & BOOSTS", 192, "banner_arsenal", WASH.gold, "sil_shop", function()
		if actions.openShop then
			actions.openShop(nil)
		else
			actions.openArsenal()
		end
	end)
	self:_dealRibbon(armory, UDim2.new(0, 0, 1, -24), UDim2.new(1, 0, 0, 24), 18)
	local crates = requisition("Crates", "LOCKER", "CRATES & FLAGS", 298, "banner_locker", WASH.purple, "sil_locker", actions.openLocker)
	local lockerName = crates:FindFirstChild("Name") :: TextLabel
	self:_crateRibbon(crates, UDim2.new(0, 0, 1, -24), UDim2.new(1, 0, 0, 24), 18, lockerName.Position)
	local shop = requisition("FlagShop", "FLAG SHOP", "NEW THIS WEEK", 404, "banner_flags", WASH.orange, "sil_flag", actions.openFlagShop)
	local ribbon = Kit.new("Frame", { Name = "Ribbon", BackgroundColor3 = WASH.orange, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 26), ZIndex = 5, Parent = shop })
	Kit.corner(14).Parent = ribbon
	Kit.new("Frame", { BackgroundColor3 = WASH.orange, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.5, 0), ZIndex = 5, Parent = ribbon })
	self.flagEvent = stencil({ Text = "TODAY'S FLAGS", TextSize = 18, TextColor3 = HudStyle.TEXT, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), ZIndex = 6, Parent = ribbon })
	self.flagTimer = Kit.label({ Text = "", FontFace = F.bodyBold, TextSize = 15, TextColor3 = Color3.fromHex("#FFE3CC"), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), ZIndex = 6, Parent = ribbon })

	-- Right: PLAY (General and Campaign sit above it, MenuCards).
	local rx = W - 140
	local play = HudStyle.goldPlate({ Name = "Play", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(rx, 294), Size = UDim2.fromOffset(244, 96), ZIndex = 8, Parent = stage }, 18)
	goldLip(play, 5, 18)
	playWords(play, 16, 62)
	play.Activated:Connect(function()
		self:showSolo(true)
	end)
	Dossier.clicky(play, 1.05)

	-- Centre: the map, and the World queue's frontline card on it.
	local cx0, cx1 = 290, W - 278
	local map = Kit.new("Frame", { Name = "WarMap", BackgroundColor3 = HudStyle.EDGE, BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.fromOffset(cx0, 88), Size = UDim2.fromOffset(cx1 - cx0, 254), ZIndex = 3, Parent = stage })
	Kit.corner(14).Parent = map
	Kit.stroke(HudStyle.EDGE, 3, 0).Parent = map
	local world = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(math.ceil(254 * aspect), 254), ZIndex = 3, Parent = map })
	for i, image in UiAssets.backdrop do
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = image, Position = UDim2.fromScale((i - 1) * 0.5, 0), Size = UDim2.fromScale(0.5, 1), ScaleType = Enum.ScaleType.Stretch, ZIndex = 3, Parent = world })
	end
	Kit.new("Frame", { Name = "Slate", BackgroundColor3 = Color3.fromRGB(20, 30, 28), BackgroundTransparency = 0.6, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 3, Parent = map })

	local front = HudStyle.panel("Frame", { Name = "Frontline", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromOffset(cx1 - 8, 96), Size = UDim2.fromOffset(206, 196), ZIndex = 10, Parent = stage }, 14)
	local frontHead = Kit.new("Frame", { Name = "Head", BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 84), ZIndex = 10, Parent = front })
	Kit.corner(14).Parent = frontHead
	washedPhoto(frontHead, "banner_orders", WASH.green, 14)
	footFade(frontHead, 26)
	stencil({ Text = "DEPLOY TO\nFRONTLINE", TextSize = 32, LineHeight = 0.9, TextColor3 = HudStyle.TEXT, Position = UDim2.fromOffset(12, 10), ZIndex = 11, Parent = frontHead })
	local frontBtn = HudStyle.goldPlate({ Name = "Join", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 88), Size = UDim2.new(1, -24, 0, 58), ZIndex = 12, Parent = front }, 14)
	goldLip(frontBtn, 4, 14)
	local frontLabel = stencil({ Text = "JOIN", TextSize = 40, TextColor3 = HudStyle.BROWN, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 12, Parent = frontBtn })
	Dossier.clicky(frontBtn, 1.05)
	local frontCount = stencil({ Text = "", TextSize = 16, TextColor3 = HudStyle.SOFT, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.new(1, -16, 0, 36), ZIndex = 11, Parent = front })
	self.front = { frame = front, btn = frontBtn, label = frontLabel, count = frontCount, data = nil :: any }
	frontBtn.Activated:Connect(function()
		self:_press(self.front.data)
	end)

	-- Bottom: the other public queues, under teal headers.
	self.reports = {}
	local rw = (W - 10 - cx0 - 24) / 3
	for i = 1, 3 do
		local x = cx0 + (i - 1) * (rw + 12)
		local card = Kit.new("TextButton", { Name = `Report{i}`, Text = "", AutoButtonColor = false, BackgroundColor3 = HudStyle.BG, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x + rw / 2, 360 + 70), Size = UDim2.fromOffset(rw, 140), ZIndex = 5, Parent = stage }) :: TextButton
		Kit.corner(14).Parent = card
		Kit.stroke(HudStyle.EDGE, 3, 0).Parent = card
		local head = HudStyle.header(card, 40, WASH.teal, 14)
		local header = typed({ Text = "", TextColor3 = Color3.fromHex("#CFF3F3"), TextSize = 17, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.new(1, -112, 0, 22), ZIndex = 6, Parent = head })
		local tag = Kit.new("Frame", { Name = "Tag", BackgroundColor3 = Color3.fromHex("#080C0A"), BackgroundTransparency = 0.2, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(84, 30), ZIndex = 6, Parent = head })
		Kit.corner(8).Parent = tag
		local dot = Kit.new("Frame", { BackgroundColor3 = C.ok, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 14, 0.5, 0), Size = UDim2.fromOffset(10, 10), ZIndex = 6, Parent = tag })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
		local tagText = stencil({ Text = "LIVE", TextSize = 20, TextColor3 = HudStyle.TEXT, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 25, 0.5, 0), ZIndex = 6, Parent = tag })
		local name = stencil({ Text = "", TextSize = 32, TextColor3 = HudStyle.TEXT, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromOffset(rw - 112, 36), Position = UDim2.fromOffset(12, 48), ZIndex = 6, Parent = card })
		local count = Kit.label({ Text = "", FontFace = F.bodySemibold, TextColor3 = HudStyle.MUTED, TextSize = 17, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -10), ZIndex = 6, Parent = card })
		local photo = Kit.new("Frame", { Name = "Photo", BackgroundColor3 = HudStyle.EDGE, BorderSizePixel = 0, ClipsDescendants = true, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -10, 1, -10), Size = UDim2.fromOffset(92, 64), ZIndex = 6, Parent = card })
		Kit.corner(9).Parent = photo
		local photoTape = Kit.new("Frame", { Name = "NoTape", BackgroundTransparency = 1, Parent = card })
		local team = Kit.new("ImageLabel", { Name = "Team", BackgroundTransparency = 1, Image = A.sil_team or "", ImageTransparency = 0.1, ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -10, 1, -10), Size = UDim2.fromOffset(92, 64), Visible = false, ZIndex = 6, Parent = card })
		local r: any
		Dossier.clicky(card, 1.03)
		card.Activated:Connect(function()
			click()
			self:_press(r.data)
		end)
		r = { frame = card, header = header, name = name, count = count, tag = tag, dot = dot, tagText = tagText, photo = photo, photoTape = photoTape, team = team, pic = nil :: Instance?, picFor = nil :: string?, data = nil :: any }
		self.reports[i] = r
	end
	self.tagSizes = { UDim2.fromOffset(84, 30), UDim2.fromOffset(108, 30) }

	-- The credits line (LICENSING_PLAN 7(b) and 7(c); CC BY-SA attribution),
	-- which opens the credits and source window (Bruno, 2026-11-08).
	local bar = Kit.new("TextButton", { Name = "Credits", Text = "", AutoButtonColor = false, BackgroundColor3 = Color3.fromHex("#0A120E"), BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 26), ZIndex = 45, Parent = sheet })
	Kit.corner(18).Parent = bar
	Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#0A120E"), BorderSizePixel = 0, Size = UDim2.new(1, 0, 0.5, 0), ZIndex = 45, Parent = bar })
	self:_creditsButton(bar)
	Kit.label({
		Text = CreditsText.BAR,
		FontFace = F.uiSemi,
		TextSize = 15,
		TextColor3 = HudStyle.MUTED,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ZIndex = 46,
		Parent = bar,
	})

	self:_buildOrdersCompact(stage)
end

-- The deployment orders on a phone: a full-screen sheet.
function MainMenu._buildOrdersCompact(self: any, stage: Frame)
	local actions, root = self.actions, self.root
	local W, H = root.width, root.height
	-- On the layer, not the stage: the starter tag and General card sit on
	-- the layer above the stage, and showed through the sheet (Bruno's phone,
	-- 2026-11-10). The phone stage fills the layer, so positions don't change.
	local _ = stage
	local orders = Kit.new("Frame", { Name = "Orders", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 60, Visible = false, Parent = self.layer })
	self.orders = orders
	Kit.new("TextButton", { Name = "Blocker", Text = "", AutoButtonColor = false, BackgroundColor3 = C.desk, BackgroundTransparency = 0.3, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = orders })
	local paper = darkSheet({ Position = at(6, 6), Size = sz(W - 12, H - 12), Parent = orders }, 84)
	local pw = W - 12
	-- The header, clear of Roblox's buttons.
	local tx = math.max(24, root.topLeft - 6)
	Dossier.outline(stencil({ Text = "DEPLOYMENT ORDERS", TextSize = 56, TextColor3 = Color3.new(1, 1, 1), AnchorPoint = Vector2.new(0, 0.5), Position = at(tx, 38), Parent = paper }))
	Dossier.closeRed(paper, at(pw - 45, 38), sz(62, 62), function()
		click()
		self:showSolo(false)
	end)

	typed({ Text = "1. THEATRE OF OPERATIONS", TextSize = 19, TextColor3 = ORDERS_LABEL, Position = at(24, 84), Parent = paper })
	local mapRow = surface("ImageButton", "tex_manila", C.manila, { Name = "MapRow", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 110), Size = sz(pw - 40, 88), Parent = paper })
	Dossier.clicky(mapRow, 1.02)
	Kit.corner(5).Parent = mapRow
	Kit.stroke(C.manilaLine, 2, 0).Parent = mapRow
	local mapPhoto = Kit.new("Frame", { BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = at(12, 8), Size = sz(110, 72), Rotation = -3, Parent = mapRow })
	Kit.stroke(C.sheetLine, 1, 0).Parent = mapPhoto
	self.mapPhoto = mapPhoto
	self.mapText = stencil({ Text = "", TextSize = 48, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 140, 0.5, 0), Parent = mapRow })
	stencil({ Text = "CHANGE MAP  >", TextSize = 28, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -18, 0.5, 0), Parent = mapRow })
	mapRow.Activated:Connect(function()
		click()
		actions.pickMap(self.soloMap, function(folderName: string)
			self.soloMap = folderName
			self:_refreshSolo()
		end)
	end)

	typed({ Text = "2. THREAT LEVEL", TextSize = 19, TextColor3 = ORDERS_LABEL, Position = at(24, 212), Parent = paper })
	self.diffChips = {} :: { [string]: TextButton }
	local n = #MenuModel.DIFFICULTIES
	local chipW = (pw - 40 - (n - 1) * 12) / n
	for i, d in MenuModel.DIFFICULTIES do
		local chip = Kit.new("TextButton", { Name = d, Text = string.upper(MenuModel.difficultyName(d)), FontFace = F.stencil, TextSize = 32, AutoButtonColor = false, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(20 + (i - 1) * (chipW + 12) + chipW / 2, 270), Size = sz(chipW, 64), Parent = paper })
		Dossier.clicky(chip, 1.04)
		Kit.corner(4).Parent = chip
		Kit.stroke(C.inkBlack, 2, 0).Parent = chip
		chip.Activated:Connect(function()
			click()
			if self.privateMode then
				self.privateKind = PRIVATE_KIND[d] or self.privateKind
			else
				self.difficulty = d
			end
			self:_refreshSolo()
		end)
		self.diffChips[d] = chip
	end
	self.diffText = typed({
		Text = "",
		TextSize = 20,
		TextColor3 = ORDERS_TEXT,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.None,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = at(24, 312),
		Size = sz(pw - 48, 52),
		Parent = paper,
	})
	local by = H - 12 - 56
	local cancel = inkButton(paper, "CANCEL", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(115, by), Size = sz(190, 68), Parent = paper })
	Dossier.clicky(cancel, 1.04)
	cancel.Activated:Connect(function()
		self:showSolo(false)
	end)
	local howTo = inkButton(paper, "HOW TO PLAY", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(341, by), Size = sz(230, 68), Parent = paper })
	Dossier.clicky(howTo, 1.04)
	howTo.Activated:Connect(actions.openHowToPlay)
	for _, b in { cancel, howTo } do
		local label = b:FindFirstChild("Label") :: TextLabel
		label.TextSize = 32
		softButton(b)
	end
	local start = plate(paper, "START", { Name = "Start", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(pw - 185, by - 4), Size = sz(330, 92), Parent = paper }, 70)
	start.Activated:Connect(function()
		if self.privateMode and actions.startPrivate then
			actions.startPrivate(self.soloMap, self.privateKind or "ffa")
		else
			actions.startSolo(self.soloMap, self.difficulty)
		end
	end)
	Dossier.clicky(start, 1.04)
	self:_refreshSolo()
end

-- The deployment orders (solo setup), laid over the map and the note.
function MainMenu._buildOrders(self: any, stage: Frame)
	local actions = self.actions
	-- Above the folders' hit areas (30 + their z).
	local orders = Kit.new("Frame", { Name = "Orders", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 60, Visible = false, Parent = stage })
	self.orders = orders
	-- The whole screen dims, and clicks and hovers outside the sheet don't
	-- reach what's under it (the stage is centred, so 3x covers any screen).
	Kit.new("TextButton", { Name = "Blocker", Text = "", AutoButtonColor = false, BackgroundColor3 = C.desk, BackgroundTransparency = 0.3, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(3, 3), Parent = orders })
	local paper = darkSheet({ Position = at(268, 104), Size = sz(540, 326), Parent = orders }, 156)
	Dossier.outline(stencil({ Text = "DEPLOYMENT ORDERS", TextSize = 70, TextColor3 = Color3.new(1, 1, 1), Position = UDim2.fromOffset(48, 26), Parent = paper }))
	self.opText = typed({ Text = "Operation: solo · one commander against bots and nations", TextSize = 19, TextColor3 = ORDERS_TEXT, Position = UDim2.fromOffset(50, 112), Parent = paper })
	Dossier.closeRed(paper, UDim2.new(1, -50, 0, 50), UDim2.fromOffset(64, 64), function()
		click()
		self:showSolo(false)
	end)

	typed({ Text = "1. THEATRE OF OPERATIONS", TextSize = 20, TextColor3 = ORDERS_LABEL, Position = UDim2.fromOffset(50, 166), Parent = paper })
	local mapRow = surface("ImageButton", "tex_manila", C.manila, { Name = "MapRow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 198 + 46), Size = UDim2.new(1, -96, 0, 92), Parent = paper })
	Dossier.clicky(mapRow, 1.02)
	Kit.corner(5).Parent = mapRow
	Kit.stroke(C.manilaLine, 2, 0).Parent = mapRow
	local mapPhoto = Kit.new("Frame", { BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = UDim2.fromOffset(14, 8), Size = UDim2.fromOffset(116, 76), Rotation = -3, Parent = mapRow })
	Kit.stroke(C.sheetLine, 1, 0).Parent = mapPhoto
	self.mapPhoto = mapPhoto
	self.mapText = stencil({ Text = "", TextSize = 50, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 156, 0.5, 0), Parent = mapRow })
	typed({ Text = "CHANGE MAP  >", TextSize = 19, TextColor3 = C.inkBlack, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -22, 0.5, 0), Parent = mapRow })
	mapRow.MouseEnter:Connect(function()
		if Kit.covered(mapRow) then
			return
		end
		mapRow.BackgroundColor3 = C.manila:Lerp(Color3.new(1, 1, 1), 0.15)
		mapRow.ImageColor3 = Color3.fromRGB(255, 250, 238)
	end)
	mapRow.MouseLeave:Connect(function()
		mapRow.BackgroundColor3 = C.manila
		mapRow.ImageColor3 = Color3.new(1, 1, 1)
	end)
	mapRow.Activated:Connect(function()
		click()
		actions.pickMap(self.soloMap, function(folderName: string)
			self.soloMap = folderName
			self:_refreshSolo()
		end)
	end)

	typed({ Text = "2. THREAT LEVEL", TextSize = 20, TextColor3 = ORDERS_LABEL, Position = UDim2.fromOffset(50, 308), Parent = paper })
	local diffRow = Kit.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(48, 340), Size = UDim2.new(1, -96, 0, 58), Parent = paper })
	self.diffChips = {} :: { [string]: TextButton }
	for i, d in MenuModel.DIFFICULTIES do
		-- Placed by hand (centre-anchored for the click), 14 px apart.
		local chip = Kit.new("TextButton", { Name = d, Text = string.upper(MenuModel.difficultyName(d)), FontFace = F.stencil, TextSize = 30, AutoButtonColor = false, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, (i - 1) * 222 + 104, 0.5, 0), Size = UDim2.fromOffset(208, 56), Parent = diffRow })
		Dossier.clicky(chip, 1.05)
		Kit.corner(4).Parent = chip
		Kit.stroke(C.inkBlack, 2, 0).Parent = chip
		chip.Activated:Connect(function()
			click()
			if self.privateMode then
				self.privateKind = PRIVATE_KIND[d] or self.privateKind
			else
				self.difficulty = d
			end
			self:_refreshSolo()
		end)
		self.diffChips[d] = chip
	end
	self.diffText = typed({
		Text = "",
		TextSize = 19,
		TextColor3 = ORDERS_TEXT,
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.None,
		Size = UDim2.new(1, -96, 0, 50),
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(50, 412),
		Parent = paper,
	})
	local cancel = inkButton(paper, "CANCEL", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 48 + 90, 1, -36 - 30), Size = UDim2.fromOffset(180, 60), Parent = paper })
	Dossier.clicky(cancel, 1.06)
	cancel.Activated:Connect(function()
		self:showSolo(false)
	end)
	local howTo = inkButton(paper, "HOW TO PLAY", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 244 + 110, 1, -36 - 30), Size = UDim2.fromOffset(220, 60), Parent = paper })
	Dossier.clicky(howTo, 1.06)
	howTo.Activated:Connect(actions.openHowToPlay)
	softButton(cancel)
	softButton(howTo)
	local start = plate(paper, "START", { Name = "Start", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -48 - 190, 1, -28 - 50), Size = UDim2.fromOffset(380, 100), Parent = paper }, 76)
	start.Activated:Connect(function()
		if self.privateMode and actions.startPrivate then
			actions.startPrivate(self.soloMap, self.privateKind or "ffa")
		else
			actions.startSolo(self.soloMap, self.difficulty)
		end
	end)
	Dossier.clicky(start, 1.06)
	self:_refreshSolo()
end

function MainMenu.showSolo(self: any, on: boolean)
	self.orders.Visible = on
end

-- On a private server its owner's PLAY sets up a match for everyone here
-- (the sheet's chips pick the mode; Bruno, 2026-11-23).
function MainMenu.setPrivateMode(self: any, on: boolean)
	self.privateMode = on
	self.privateKind = self.privateKind or "ffa"
	if self.diffChips then
		self:_refreshSolo()
	end
end

function MainMenu._refreshSolo(self: any)
	local entry = MapCatalog.get(self.soloMap)
	self.mapText.Text = string.upper(if entry then entry.name else self.soloMap)
	if self.mapPic then
		self.mapPic:Destroy()
	end
	self.mapPic = MainMenu.fieldMap(self.soloMap, { Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4), Parent = self.mapPhoto })
	-- A private server (2026-11-23): the chips pick the mode instead.
	local private = self.privateMode == true
	for d, chip in self.diffChips do
		local kind = PRIVATE_KIND[d]
		local on = if private then kind == (self.privateKind or "ffa") else d == self.difficulty
		chip.Visible = not private or kind ~= nil
		chip.Text = if private and kind then PRIVATE_LABEL[kind] else string.upper(MenuModel.difficultyName(d))
		chip.BackgroundColor3 = if on then C.hazard else C.sheet
		chip.TextColor3 = C.inkBlack
	end
	self.diffText.Text = if private then PRIVATE_LINE[self.privateKind or "ffa"] else MenuModel.difficultyText(self.difficulty)
	if self.opText then
		self.opText.Text = if private then "Operation: private · everyone on this server, with AI nations" else "Operation: solo · one commander against bots and nations"
	end
end

function MainMenu._press(self: any, row: any)
	if row == nil then
		return
	end
	if row.live then
		self.actions.watchQueue(row.id)
	elseif self.queued == row.id then
		self.actions.leaveQueue()
	else
		self.actions.joinQueue(row.id)
	end
end

-- Public match rows from the server ({ rows, queued, queueState }). The
-- World queue is the frontline note; the others are the field reports.
-- `state`: "line" (every match full: finding a seat), "joining" (on the way
-- to the match's server) or "waiting" (seated, for the start).
function MainMenu.setLobbies(self: any, rows: { any }, queued: string?, state: string?)
	self.lastRows = rows
	self.queued = queued
	self.queueState = state
	self.lobbyAt = os.clock()
	local featured = nil
	for _, row in rows do
		if row.id == "world" then
			featured = row
		end
	end
	featured = featured or rows[1]
	self.front.data = featured
	local others = {}
	for _, row in rows do
		if row ~= featured then
			table.insert(others, row)
		end
	end
	for i, r in self.reports do
		r.data = others[i]
	end
	self:_tick()
end

-- Seconds left on a row's countdown, and how long a live one has run.
function MainMenu._clocks(self: any, row: any): (number?, number)
	local since = os.clock() - (self.lobbyAt or os.clock())
	local seconds = if row.seconds then math.max(0, row.seconds - since) else nil
	return seconds, (row.liveSeconds or 0) + since
end

function MainMenu._paintFront(self: any)
	local f = self.front
	local row = f.data
	f.frame.Visible = row ~= nil
	if row == nil then
		return
	end
	local mine = self.queued == row.id
	local seconds, ran = self:_clocks(row)
	f.label.Text = actionText(row, mine)
	local state = if mine then self.queueState else nil
	f.count.Text = if row.live
		then `LIVE · {row.players} PLAYING · {Kit.clock(ran)}`
		elseif state == "line" then "FINDING A SEAT…"
		elseif state == "joining" then "JOINING THE MATCH…"
		else `PLAYER COUNT: {row.players}/{row.capacity}` .. (if seconds then ` · {Kit.clock(seconds)}` else "")
	f.count.TextColor3 = if row.live or mine then HudStyle.BAD else HudStyle.SOFT
end

function MainMenu._paintReport(self: any, r: any)
	local row = r.data
	r.frame.Visible = row ~= nil
	if row == nil then
		return
	end
	local mine = self.queued == row.id
	local seconds = self:_clocks(row)
	-- (header: the kind; name: the map, or the team split; count: the seats)
	r.header.Text = if row.mode then `Team Game: {row.mapName}` elseif row.minutes then `Blitz · {row.minutes} min` else "Public Match"
	r.name.Text = if row.mode then string.upper(row.mode) else string.upper(row.mapName)
	r.count.Text = `{row.players}/{row.capacity} players`
	local state = if mine then self.queueState else nil
	r.tagText.Text = if row.live
		then "LIVE"
		elseif state == "line" then "IN LINE"
		elseif state == "joining" then "JOINING"
		elseif mine then (if seconds then Kit.clock(seconds) else "QUEUED")
		elseif seconds then Kit.clock(seconds)
		else "OPEN"
	r.dot.BackgroundColor3 = if row.live then C.red elseif mine then C.hazard else C.ok
	r.tag.Size = self.tagSizes[if mine then 2 else 1]
	-- The team queue shows its soldiers; map queues a photo of their map.
	local folder = nil
	for _, e in MapCatalog.all() do
		if e.type == row.mapType then
			folder = e.folder
		end
	end
	local useTeam = row.mode ~= nil or folder == nil
	r.team.Visible = useTeam
	r.photo.Visible = not useTeam
	r.photoTape.Visible = not useTeam
	if not useTeam and folder ~= r.picFor then
		r.picFor = folder
		if r.pic then
			r.pic:Destroy()
		end
		r.pic = MainMenu.fieldMap(folder :: string, { Size = UDim2.new(1, -16, 1, -16), Position = UDim2.fromOffset(8, 8), Parent = r.photo })
	end
end

function MainMenu._tick(self: any)
	self:_paintFront()
	for _, r in self.reports do
		self:_paintReport(r)
	end
	if self.flagShopEndsAt > 0 then
		-- "12d 7h", or a clock under a day, as in the Flag Shop (Bruno, 2026-11-11).
		self.flagTimer.Text = Kit.days(self.flagShopEndsAt - os.time())
	end
	self.partyText.Visible = self.partyText.Text ~= ""
	if self.dealDay ~= nil and os.time() // 86400 ~= self.dealDay then
		self:_paintDeal()
	end
	if self.giftEndsAt and self.starterTimer then
		self.starterTimer.Text = `FREE · {Kit.days(math.max(0, self.giftEndsAt - os.time()))}`
		-- The gold tag breathes while the gift waits (Bruno: "pulsing").
		local stroke = self.starterStroke
		if stroke then
			stroke.Thickness = 2 + 2 * (0.5 + 0.5 * math.sin(os.clock() * 4))
		end
	elseif self.starterEndsAt and self.starterTimer then
		self.starterTimer.Text = `ENDS IN {Kit.clock(math.max(0, self.starterEndsAt - os.time()))}`
	end
end

-- The player's profile view (stars, crate price).
function MainMenu.setProfile(self: any, view: { [string]: any })
	self.lastView = view
	self.starsText.Text = Kit.commas(view.stars or 0)
	if view.cratePrice then
		self.crateText.Text = tostring(view.cratePrice)
	end
	-- (Hidden since 2026-11-23: unlabelled, it read as a Robux balance;
	-- the first crate's price is on the Shop's Crates shelf.)
	self.crateBadge.Visible = false
	-- The starter pack: "ready" (not started: NEW) or "active" (counting);
	-- during the launch event, its free claim instead (gold: LAUNCH GIFT).
	local gift = view.gift == "claimable"
	self.starterTag.Visible = view.starter ~= nil or gift
	self.starterTag.BackgroundColor3 = if gift then C.hazard else C.stamp
	self.starterTitle.Text = if gift then "LAUNCH GIFT" else "STARTER PACK"
	self.starterTitle.TextColor3 = if gift then C.ink else C.sheet
	self.starterGlyph.ImageColor3 = if gift then C.ink else C.sheet
	self.starterTimer.TextColor3 = if gift then C.ink else Color3.fromHex("#F3D9C8")
	if self.starterStroke then
		self.starterStroke.Color = if gift then C.sheet else Color3.fromHex("#6E1A14")
		self.starterStroke.Thickness = 2
	end
	self.giftEndsAt = if gift and view.giftLeft then os.time() + view.giftLeft else nil
	self.starterEndsAt = if view.starter == "active" and view.starterLeft then os.time() + view.starterLeft else nil
	self.starterTimer.Text = if gift then "FREE" elseif view.starter == "ready" then "NEW · 48 HOURS" else ""
	self:_paintDeal()
	if self.generalCard then
		self.generalCard.setLine(if view.general == true then "Your perks are on" else "A crate a day, +50% stars")
	end
	-- The Campaign card: the season, your tier, the XP bar, and how many
	-- rewards wait to be claimed.
	local pass = view.pass
	if self.passCard then
		self.passCard.root.Visible = pass ~= nil
		if pass then
			local tier = math.min(30, pass.xp // 1000)
			self.passCard.setKicker(`SEASON {pass.season} · {math.max(1, math.ceil((pass.endsAt - os.time()) / 86400))} DAYS`)
			self.passCard.setLine(`Tier {tier} of 30`)
			self.passCard.setBar(if tier >= 30 then 1 else (pass.xp % 1000) / 1000)
			local function count(list: { number }, open: boolean): number
				if not open then
					return 0
				end
				local seen: { [number]: boolean } = {}
				for _, t in list do
					seen[t] = true
				end
				local n = 0
				for t = 1, tier do
					if not seen[t] then
						n += 1
					end
				end
				return n
			end
			self.passCard.setCount(count(pass.free, true) + count(pass.paid, pass.premium == true))
		end
	end
end

-- The sound button shows a slash while music is off (Bruno, 2026-10-28).
function MainMenu.setMusicOn(self: any, on: boolean)
	self.musicOn = on
	if self.soundSlash then
		self.soundSlash.Visible = not on
	end
end

-- The flag shop's next rotation (os.time of the next UTC midnight) and the
-- event it is running, if any.
function MainMenu.setFlagShop(self: any, newAt: number, eventName: string?)
	self.flagShopEndsAt = newAt
	self.flagEventName = eventName
	self.flagEvent.Text = string.upper(eventName or "Today's flags")
end

-- The flag on offer (the card shows the flag icon, as in the concept).
function MainMenu.setFlagCard(self: any, flagId: string)
	self.flagId = flagId
end

function MainMenu.setVisible(self: any, visible: boolean)
	self.frame.Visible = visible
	if visible then
		self:showSolo(false)
	end
end

function MainMenu.destroy(self: any)
	for _, c in self.connections do
		c:Disconnect()
	end
	for _, c in self.built do
		c:Disconnect()
	end
	self.drift:Cancel()
	self.frame:Destroy()
end

return MainMenu
