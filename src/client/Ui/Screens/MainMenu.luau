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
local GeneralOffer = require(script.Parent.GeneralOffer)
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
	openLocker: () -> (),
	openFlagShop: () -> (),
	openParty: () -> (),
	-- The starter pack's offer (the red tag under the stars note).
	openStarter: (() -> ())?,
	-- The launch event's free starter pack (the same tag, gold, while claimable).
	openGift: (() -> ())?,
	-- Conquest General's window (the gold-edged card under it).
	openGeneral: (() -> ())?,
}

-- Concept pixels to canvas units (desktop). The phone layout is written in
-- canvas units, so it builds with K = 1.
local DESKTOP_K = 1920 / 1024
local K = DESKTOP_K
local STAGE_W, STAGE_H = 1920, 1072

local function at(x: number, y: number): UDim2
	return UDim2.fromOffset(math.round(x * K), math.round(y * K))
end

local function sz(w: number, h: number): UDim2
	return UDim2.fromOffset(math.round(w * K), math.round(h * K))
end

local RIBBON = Color3.fromHex("#D9702A")
local GOLD_BUTTON = Color3.fromHex("#E2AE2E")
local BADGE = Color3.fromHex("#3F9B4F")
local BAR = Color3.fromHex("#2A2924")
local METAL = Color3.fromHex("#3A3E3E")

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
local merge = Dossier.merge
local stencil = Dossier.stencil
local typed = Dossier.typed
local art = Dossier.art
local icon = Dossier.icon
local surface = Dossier.surface
local shadow = Dossier.shadow
local inkButton = Dossier.inkButton
local plate = Dossier.plate
local SPRING = Dossier.SPRING
local SETTLE = Dossier.SETTLE

-- How far each folder picture reaches past the card's front face (its tab
-- above, the papers peeking out at the right), as fractions of the face.
local FOLDER_ART: { [string]: { left: number, top: number, right: number, bottom: number } } = {
	-- Measured on art/dossier/*.png (the face of folder_card is x 13..973,
	-- y 58..404 of 1024x430, and so on).
	folder_card = { left = 0.014, top = 0.168, right = 0.053, bottom = 0.075 },
	folder_tall = { left = 0.013, top = 0.121, right = 0.049, bottom = 0.048 },
	folder_report = { left = 0.013, top = 0.145, right = 0.046, bottom = 0.057 },
}
-- Children of a folder card that make up the folder itself (under the text).
local FOLDER_PARTS = { Art = true, ArtShadow = true, Star = true, Tab = true }

-- Draws a card's text and icons over its folder picture.
local function overArt(card: GuiObject)
	for _, child in card:GetChildren() do
		if child:IsA("GuiObject") and not FOLDER_PARTS[child.Name] then
			child.ZIndex = math.max(child.ZIndex, 5)
		end
	end
end

-- A folder card: the folder picture `artName` when it's uploaded (the face
-- is the card's rect; the tab and the papers reach past it), else a manila
-- body with its tab at the top left, darker towards the bottom like stacked
-- folders. `tabW` is in concept pixels. A faded star stamp sits at `star`
-- (concept pixels on the face), if given.
local function folderCard(parent: Instance, name: string, x: number, y: number, w: number, h: number, tabW: number, z: number, artName: string?, star: { number }?): (ImageButton, Frame)
	-- Anchored at its centre, so the click squashes it about its middle.
	local props = { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(x + w / 2, y + h / 2), Size = sz(w, h), ZIndex = z }
	local shade = shadow(parent, props, z)
	local pads = if artName and (A[artName] or "") ~= "" then FOLDER_ART[artName] else nil
	if pads then
		local card = Kit.new("ImageButton", merge({ AutoButtonColor = false, BackgroundTransparency = 1, Image = "", Parent = parent }, props)) :: ImageButton
		-- The picture has its own outline, so the square shadow goes; a
		-- dark copy of the picture is its shadow instead.
		shade.Visible = false
		local box = {
			Position = UDim2.fromScale(-pads.left, -pads.top),
			Size = UDim2.fromScale(1 + pads.left + pads.right, 1 + pads.top + pads.bottom),
		}
		Kit.new("ImageLabel", { Name = "ArtShadow", BackgroundTransparency = 1, Image = A[artName :: string], ImageColor3 = Color3.new(0, 0, 0), ImageTransparency = 0.6, ScaleType = Enum.ScaleType.Stretch, Position = box.Position + UDim2.fromOffset(5, 8), Size = box.Size, ZIndex = 1, Parent = card })
		Kit.new("ImageLabel", { Name = "Art", BackgroundTransparency = 1, Image = A[artName :: string], ScaleType = Enum.ScaleType.Stretch, Position = box.Position, Size = box.Size, ZIndex = 2, Parent = card })
		if star then
			art("star_stamp", { Name = "Star", Position = at(star[1], star[2]), Size = sz(star[3], star[3]), ImageTransparency = 0.78, Rotation = -12, ZIndex = 3, Parent = card })
		end
		return card, shade
	end
	local card = surface("ImageButton", "tex_manila", C.manila, merge(props, { Parent = parent })) :: ImageButton
	Kit.corner(6).Parent = card
	Kit.stroke(C.manilaLine, 1.5, 0.2).Parent = card
	local tab = surface("ImageLabel", "tex_manila", C.manila, { Name = "Tab", Position = UDim2.fromOffset(0, math.round(-15 * K)), Size = sz(tabW, 21), Parent = card })
	Kit.corner(7).Parent = tab
	Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(222, 210, 186)), Parent = card })
	return card, shade
end


-- A strip of tape (art, else a translucent band).
local function tape(parent: Instance, name: string, x: number, y: number, w: number, h: number, rot: number, z: number, fallback: Color3): GuiObject
	local props = { Name = "Tape", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(x, y), Size = sz(w, h), Rotation = rot, ZIndex = z, ScaleType = Enum.ScaleType.Stretch, Parent = parent }
	return art(name, props)
		or Kit.new("Frame", { Name = "Tape", BackgroundColor3 = fallback, BackgroundTransparency = 0.2, BorderSizePixel = 0, AnchorPoint = props.AnchorPoint, Position = props.Position, Size = props.Size, Rotation = rot, ZIndex = z, Parent = parent })
end

local function pin(parent: Instance, x: number, y: number, z: number)
	-- The pin art stands on its needle: anchor its point on (x, y).
	local props = { Name = "Pin", AnchorPoint = Vector2.new(0.5, 0.75), Position = at(x, y), Size = sz(20, 28), ZIndex = z, Parent = parent }
	if art("pin", props) == nil then
		local p = Kit.new("Frame", { Name = "Pin", BackgroundColor3 = Color3.fromRGB(176, 44, 36), BorderSizePixel = 0, AnchorPoint = props.AnchorPoint, Position = props.Position, Size = sz(12, 12), ZIndex = z, Parent = parent })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = p })
		Kit.stroke(Color3.fromRGB(92, 20, 14), 2, 0).Parent = p
	end
end

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

-- The desktop layout, on the concept's stage.
function MainMenu._buildDesktop(self: any)
	local root, actions = self.root, self.actions
	local aspect = UiAssets.BACKDROP_SIZE.X / UiAssets.BACKDROP_SIZE.Y
	-- The concept's 1024x572 picture, scaled onto the canvas.
	local stage = Kit.new("Frame", { Name = "Stage", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(STAGE_W, STAGE_H), Parent = self.layer })
	self.stage = stage

	-- The folder, with a second one behind it and its tab at the top left.
	local behind = surface("ImageLabel", "tex_manila", C.manilaDark, { Name = "FolderBehind", Position = at(78, 18), Size = sz(922, 540), Rotation = 0.5, ImageColor3 = Color3.fromRGB(214, 200, 172), ZIndex = 1, Parent = stage })
	Kit.corner(8).Parent = behind
	local folder = surface("ImageLabel", "tex_manila", C.manila, { Name = "Folder", Position = at(62, 22), Size = sz(926, 532), ZIndex = 2, Parent = stage })
	Kit.corner(8).Parent = folder
	Kit.stroke(C.manilaLine, 1.5, 0.3).Parent = folder
	local folderTab = surface("ImageLabel", "tex_manila", C.manila, { Name = "FolderTab", Position = at(62, 12), Size = sz(275, 22), ZIndex = 2, Parent = stage })
	Kit.corner(8).Parent = folderTab

	-- Title band.
	local band = surface("ImageLabel", "tex_paper", C.sheet, { Name = "TitleBand", Position = at(68, 26), Size = sz(708, 78), ZIndex = 3, Parent = stage })
	if A.title_band ~= "" then
		-- The crumpled strip, stretched once over the band.
		band.Image, band.ScaleType = A.title_band, Enum.ScaleType.Stretch
	else
		Kit.stroke(C.sheetLine, 1, 0.3).Parent = band
	end
	local logo: any = art("logo", { Name = "Title", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(16 * K), 0.5, -2), Size = sz(616, 62), Parent = band })
		or stencil({ Name = "Title", Text = "CONQUER COUNTRIES", TextSize = 128, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(16 * K), 0.5, -2), Parent = band })
	local rule = Kit.new("Frame", { Name = "Rule", BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.15, BorderSizePixel = 0, Position = UDim2.fromOffset(math.round(16 * K), math.round(72 * K)), Size = UDim2.fromOffset(math.round(676 * K), 3), Parent = band })
	-- Keep the title clear of Roblox's own buttons at the top left.
	local function placeTitle()
		local s = root.scale.Scale
		local left = band.AbsolutePosition.X / s
		local x = math.max(math.round(16 * K), root.topLeft - left + 12)
		logo.Position = UDim2.new(0, x, 0.5, -2)
		rule.Position = UDim2.fromOffset(x, math.round(72 * K))
	end
	table.insert(self.built, root.Changed.Event:Connect(placeTitle))
	table.insert(self.built, band:GetPropertyChangedSignal("AbsolutePosition"):Connect(placeTitle))
	task.defer(placeTitle)

	-- The board everything is pinned to.
	local board = surface("ImageLabel", "tex_board", C.board, { Name = "Board", Position = at(66, 108), Size = sz(921, 434), ZIndex = 3, Parent = stage })
	if A.board ~= "" then
		-- The stained board, stretched once (its stains don't tile).
		board.Image, board.ScaleType = A.board, Enum.ScaleType.Stretch
	end
	Kit.corner(4).Parent = board
	Kit.stroke(C.boardDark, 2, 0).Parent = board

	-- Top right: the TOP-SECRET note.
	local noteProps = { Name = "Secret", Position = at(757, 12), Size = sz(228, 92), Rotation = 1.2, ZIndex = 12 }
	shadow(stage, noteProps, 11)
	local note = surface("ImageLabel", "tex_paper", C.sheet, merge(noteProps, { Parent = stage }))
	Kit.stroke(C.sheetLine, 1, 0.2).Parent = note
	if art("stamp_secret", { Name = "Stamp", Position = at(9, 7), Size = sz(140, 36), Rotation = -1, Parent = note }) == nil then
		local box = Kit.new("Frame", { Name = "Stamp", BackgroundTransparency = 1, Position = at(10, 9), Size = sz(136, 32), Rotation = -1, Parent = note })
		Kit.stroke(C.stamp, 3, 0).Parent = box
		stencil({ Text = "TOP-SECRET", TextSize = 46, TextColor3 = C.stamp, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = box })
	end
	local strip = surface("ImageLabel", "tex_manila", C.manilaDark, { Name = "Icons", Position = at(156, 16), Size = sz(66, 36), ImageColor3 = Color3.fromRGB(214, 200, 172), Parent = note })
	Kit.corner(5).Parent = strip
	local function noteIcon(name: string, glyph: string, x: number, tip: string, onClick: () -> ())
		local b = Kit.new("TextButton", { Name = glyph, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(x + 16, 18), Size = sz(32, 32), Parent = strip })
		icon(name, glyph, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz(24, 24), Parent = b })
		Dossier.clicky(b, 1.12)
		b.Activated:Connect(function()
			click()
			onClick()
		end)
		Kit.tip(b, function(card)
			Kit.text({ Text = tip, FontFace = F.uiBold, Parent = card })
		end)
		return b
	end
	noteIcon("icon_settings", "settings", 1, "Settings", actions.openSettings)
	self.soundSlash = Kit.slash(noteIcon("icon_sound", "music", 33, "Music", actions.toggleMusic))
	self:setMusicOn(self.musicOn)
	icon("icon_star", "star", { AnchorPoint = Vector2.new(0, 0.5), Position = at(11, 66), Size = sz(15, 15), Parent = note })
	self.starsText = stencil({ Name = "Stars", Text = "…", TextSize = 38, AnchorPoint = Vector2.new(0, 0.5), Position = at(29, 66), Parent = note })
	-- The green badge: Supply crates' price in Robux.
	local badge = Kit.new("TextButton", { Name = "CratePrice", Text = "", AutoButtonColor = false, BackgroundColor3 = BADGE, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(94 + 25, 54 + 12), Size = sz(50, 24), Visible = false, Parent = note })
	Dossier.clicky(badge, 1.15)
	Kit.corner(4).Parent = badge
	Kit.stroke(Color3.fromRGB(31, 90, 43), 2, 0).Parent = badge
	Kit.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = badge
	Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, Parent = badge })
	self.crateText = stencil({ Text = "", TextSize = 32, TextColor3 = C.sheet, LayoutOrder = 2, Parent = badge })
	self.crateBadge = badge
	badge.Activated:Connect(function()
		click()
		actions.openLocker()
	end)
	Kit.tip(badge, function(card)
		Kit.text({ Text = "Supply crate price", FontFace = F.uiBold, Parent = card })
	end)
	tape(note, "tape", 85, 88, 66, 20, 2, 0, C.tape)
	tape(note, "tape", 222, 62, 46, 18, 72, 0, C.tape)

	-- Left: the "Military requisitions" spine.
	local spine = surface("ImageLabel", "tex_manila", C.manilaDark, { Name = "Requisitions", Position = at(33, 128), Size = sz(38, 272), ImageColor3 = Color3.fromRGB(214, 200, 172), ZIndex = 4, Parent = stage })
	Kit.corner(7).Parent = spine
	Kit.stroke(C.manilaLine, 1.5, 0.2).Parent = spine
	stencil({ Text = "MILITARY REQUISITIONS", TextSize = 44, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Rotation = -90, Parent = spine })

	-- The four requisition cards, each overlapping the one above.
	local function requisition(name: string, text: string, y: number, h: number, z: number, iconName: string, glyph: string, iconAt: { number }, onClick: () -> ()): ImageButton
		local card, shade = folderCard(stage, name, 70, y, 192, h, 95, z, if h > 90 then "folder_tall" else "folder_card", { 96, h / 2 - 20, 40 })
		-- Pulled out to the right, tipped down (Bruno, 2026-10-26).
		local hit = self:_lift(card, shade, 48, 0, 4, function()
			click()
			onClick()
		end)
		Dossier.clicky(hit, 1, card, false)
		stencil({ Name = "Name", Text = text, TextSize = 54, LineHeight = 0.86, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(18 * K), 0, math.round(iconAt[5] * K)), Parent = card })
		icon(iconName, glyph, { Name = "Icon", Position = at(iconAt[1], iconAt[2]), Size = sz(iconAt[3], iconAt[4]), Parent = card })
		return card
	end
	local party = requisition("Party", "PARTY", 128, 80, 5, "icon_party", "party", { 126, 6, 58, 66, 38 }, actions.openParty)
	self.partyText = typed({ Name = "Squad", Text = "", TextSize = 18, TextColor3 = C.inkBlack, Position = at(18, 58), Visible = false, Parent = party })
	local armory = requisition("Armory", "ARSENAL", 216, 80, 6, "icon_armory", "silo", { 114, 14, 74, 50, 39 }, actions.openArsenal)
	self:_dealRibbon(armory, at(3, 56), sz(110, 21), 26)
	local crates = requisition("Crates", "SUPPLY\nCRATES", 304, 86, 7, "icon_crates", "chest", { 122, 14, 62, 56, 42 }, actions.openLocker)
	self:_crateRibbon(crates, at(3, 64), sz(124, 20), 25, at(18, 33))
	local shop = requisition("FlagShop", "FLAG\nSHOP", 398, 104, 8, "icon_flag", "flag", { 122, 10, 60, 60, 42 }, actions.openFlagShop)
	local ribbon = Kit.new("Frame", { Name = "Ribbon", BackgroundColor3 = RIBBON, BorderSizePixel = 0, Position = at(3, 75), Size = sz(192, 25), Parent = shop })
	Kit.stroke(Color3.fromRGB(120, 52, 14), 2, 0).Parent = ribbon
	self.flagEvent = stencil({ Text = "TODAY'S FLAGS", TextSize = 30, TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, -24, 0.5, 0), Parent = ribbon })
	self.flagTimer = typed({ Text = "", TextSize = 15, TextColor3 = C.sheet, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Parent = ribbon })
	-- Paperclips on the left edge of Party and the Flag Shop (Bruno's reference).
	art("paperclip", { Name = "Clip", Position = at(-6, 18), Size = sz(10, 34), Parent = party })
	art("paperclip", { Name = "Clip", Position = at(-6, 4), Size = sz(10, 34), Parent = shop })
	for _, card in { party, shop } do
		overArt(card)
	end
	for _, name in { "Armory", "Crates" } do
		overArt(stage:FindFirstChild(name) :: GuiObject)
	end

	-- Centre: the war map, pinned to the board.
	local mapProps = { Name = "WarMap", Position = at(272, 118), Size = sz(444, 282), ZIndex = 5 }
	shadow(stage, mapProps, 4)
	local map = Kit.new("Frame", merge({ BackgroundColor3 = METAL, BorderSizePixel = 0 }, merge(mapProps, { Parent = stage })))
	Kit.corner(3).Parent = map
	Kit.stroke(Color3.fromRGB(24, 26, 26), 2, 0).Parent = map
	local inset = math.round(6 * K)
	local view = Kit.new("Frame", { Name = "View", BackgroundColor3 = Color3.fromRGB(38, 92, 140), BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.fromOffset(inset, inset), Size = UDim2.new(1, -2 * inset, 1, -2 * inset), Parent = map })
	-- Cover the view by height (the sides crop).
	local viewH = math.round(282 * K) - 2 * inset
	local world = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(math.ceil(viewH * aspect), viewH), Parent = view })
	for i, image in UiAssets.backdrop do
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = image, Position = UDim2.fromScale((i - 1) * 0.5, 0), Size = UDim2.fromScale(0.5, 1), ScaleType = Enum.ScaleType.Stretch, Parent = world })
	end
	Kit.new("Frame", { Name = "Slate", BackgroundColor3 = Color3.fromRGB(34, 44, 44), BackgroundTransparency = 0.5, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = view })
	for gx = 1, 9 do
		Kit.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.88, BorderSizePixel = 0, Position = UDim2.new(gx / 10, 0, 0, 0), Size = UDim2.new(0, 1, 1, 0), Parent = view })
	end
	for gy = 1, 5 do
		Kit.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.88, BorderSizePixel = 0, Position = UDim2.new(0, 0, gy / 6, 0), Size = UDim2.new(1, 0, 0, 1), Parent = view })
	end
	-- Degree ticks along the edges.
	for t = 1, 39 do
		local long = t % 4 == 0
		Kit.new("Frame", { BackgroundColor3 = C.sheet, BackgroundTransparency = 0.35, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(t / 40, 0, 1, 0), Size = UDim2.fromOffset(1, if long then 12 else 6), Parent = view })
	end
	for t = 1, 23 do
		local long = t % 4 == 0
		Kit.new("Frame", { BackgroundColor3 = C.sheet, BackgroundTransparency = 0.35, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, t / 24, 0), Size = UDim2.fromOffset(if long then 12 else 6, 1), Parent = view })
	end
	icon("icon_compass", "target", { Name = "Compass", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(46, 228), Size = sz(48, 48), ImageColor3 = C.sheet, Parent = view })
	pin(stage, 286, 128, 6)

	-- The featured public queue (World): the frontline note.
	local frontProps = { Name = "Frontline", Position = at(545, 115), Size = sz(184, 186), Rotation = 2, ZIndex = 10 }
	shadow(stage, frontProps, 9)
	local front = surface("ImageLabel", "tex_paper", C.sheet, merge(frontProps, { Parent = stage }))
	Kit.stroke(C.sheetLine, 1, 0.2).Parent = front
	pin(front, 103, 13, 0)
	if art("paperclip", { Name = "Clip", Position = at(136, -8), Size = sz(18, 54), Parent = front }) == nil then
		local clip = Kit.new("Frame", { Name = "Clip", BackgroundTransparency = 1, Position = at(138, -8), Size = sz(14, 44), Parent = front })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = clip })
		Kit.stroke(Color3.fromRGB(150, 150, 150), 4, 0).Parent = clip
	end
	stencil({ Text = "DEPLOY TO\nFRONTLINE", TextSize = 62, LineHeight = 0.88, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, math.round(46 * K)), Parent = front })
	local frontBtn = Kit.new("TextButton", { Name = "Join", Text = "", AutoButtonColor = false, BackgroundColor3 = GOLD_BUTTON, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(92, 140), Size = sz(152, 48), Parent = front })
	Kit.corner(4).Parent = frontBtn
	Kit.stroke(C.inkBlack, 4, 0).Parent = frontBtn
	-- A darker lower half, like a pressed metal button.
	Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)), ColorSequenceKeypoint.new(0.55, Color3.new(1, 1, 1)), ColorSequenceKeypoint.new(1, Color3.fromRGB(205, 190, 160)) }), Parent = frontBtn })
	local frontLabel = stencil({ Text = "JOIN", TextSize = 56, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = frontBtn })
	Dossier.clicky(frontBtn, 1.06)
	frontBtn.MouseEnter:Connect(function()
		if Kit.covered(frontBtn) then
			return
		end
		frontBtn.BackgroundColor3 = C.hazard
	end)
	frontBtn.MouseLeave:Connect(function()
		frontBtn.BackgroundColor3 = GOLD_BUTTON
	end)
	local frontCount = stencil({ Text = "", TextSize = 24, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, math.round(173 * K)), Parent = front })
	self.front = { frame = front, btn = frontBtn, label = frontLabel, count = frontCount, data = nil :: any }
	frontBtn.Activated:Connect(function()
		click()
		self:_press(self.front.data)
	end)

	-- Right: solo deployment, the stamp over the PLAY plate.
	local stampProps = { Name = "SoloStamp", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(722 + 122, 178 + 71), Size = sz(244, 142), Rotation = -5, ZIndex = 7 }
	local soloStamp
	if A.stamp_solo ~= "" then
		soloStamp = Kit.new("ImageButton", merge({ AutoButtonColor = false, BackgroundTransparency = 1, Image = A.stamp_solo, ScaleType = Enum.ScaleType.Fit }, merge(stampProps, { Parent = stage })))
	else
		soloStamp = Kit.new("TextButton", merge({ Text = "", AutoButtonColor = false, BackgroundTransparency = 1 }, merge(stampProps, { Parent = stage })))
		Kit.corner(12).Parent = soloStamp
		Kit.stroke(C.stamp, 7, 0.05).Parent = soloStamp
		stencil({ Text = "SOLO", TextSize = 150, TextColor3 = C.stamp, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Parent = soloStamp })
		stencil({ Text = "DEPLOYMENT", TextSize = 64, TextColor3 = C.stamp, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -8), Parent = soloStamp })
	end
	-- Hovered, the stamp presses in like a rubber stamp; clicked, it thumps.
	Dossier.clicky(soloStamp, 0.94)
	local ink = TweenInfo.new(0.12)
	soloStamp.MouseEnter:Connect(function()
		if Kit.covered(soloStamp) then
			return
		end
		if soloStamp:IsA("ImageButton") then
			TweenService:Create(soloStamp, ink, { ImageColor3 = Color3.fromRGB(205, 200, 200) }):Play()
		end
	end)
	soloStamp.MouseLeave:Connect(function()
		if soloStamp:IsA("ImageButton") then
			TweenService:Create(soloStamp, ink, { ImageColor3 = Color3.new(1, 1, 1) }):Play()
		end
	end)
	local function openSolo()
		self:showSolo(true)
	end
	soloStamp.Activated:Connect(function()
		click()
		openSolo()
	end)
	local play = plate(stage, "PLAY", { Name = "Play", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(740 + 111, 329 + 32), Size = sz(222, 64), ZIndex = 8, Parent = stage }, 110)
	play.Activated:Connect(openSolo)
	Dossier.clicky(play, 1.06)
	-- Taped to the plate (positions relative to it), so they grow with it.
	tape(play, "red_tape", 12, 37, 80, 20, 56, 0, C.stamp)
	tape(play, "red_tape", 214, 15, 80, 20, 48, 0, C.stamp)

	-- Bottom: the other public queues, as field reports (three since Blitz,
	-- 2026-11-16: the free-for-all, Blitz and the team game).
	self.reports = {}
	local cw, gap = 220, 13
	for i = 1, 3 do
		local x = 285 + (i - 1) * (cw + gap)
		local card, shade = folderCard(stage, `Report{i}`, x, 425, cw, 140, 90, 5, "folder_report", { cw - 62, 62, 46 })
		-- Lifted up out of the folder.
		local r: any
		local hit = self:_lift(card, shade, 0, -48, 0, function()
			click()
			self:_press(r.data)
		end)
		Dossier.clicky(hit, 1, card, false)
		local header = typed({ Text = "", TextColor3 = C.inkBlack, TextSize = 20, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0, 0.5), Position = at(14, 22), Size = sz(cw - 92, 22), Parent = card })
		Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.25, BorderSizePixel = 0, Position = at(14, 36), Size = UDim2.fromOffset(math.round((cw - 28) * K), 2), Parent = card })
		local name = stencil({ Text = "", TextSize = 42, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, Size = sz(cw - 102, 44), TextYAlignment = Enum.TextYAlignment.Top, Position = at(14, 44), Parent = card })
		local count = typed({ Text = "", TextColor3 = C.inkBlack, TextSize = 20, AutomaticSize = Enum.AutomaticSize.None, Size = sz(cw - 102, 24), Position = at(14, 90), Parent = card })
		local tag = Kit.new("Frame", { Name = "Tag", BackgroundColor3 = C.inkBlack, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = at(cw - 8, 7), Size = sz(64, 24), Parent = card })
		Kit.corner(3).Parent = tag
		local dot = Kit.new("Frame", { BackgroundColor3 = C.red, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(10, 12), Size = sz(9, 9), Parent = tag })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
		local tagText = stencil({ Text = "LIVE", TextSize = 30, TextColor3 = C.sheet, AnchorPoint = Vector2.new(0, 0.5), Position = at(19, 12), Parent = tag })
		-- The map as a print with a white border, taped on at the top.
		local photo = Kit.new("Frame", { Name = "Photo", BackgroundColor3 = C.sheet, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = at(cw - 10, 42), Size = sz(82, 58), Rotation = 3, Parent = card })
		Kit.stroke(C.sheetLine, 1, 0).Parent = photo
		local photoTape = tape(card, "tape", cw - 70, 42, 46, 14, -4, 7, C.tape)
		local team = icon("icon_team", "troops", { Name = "Team", AnchorPoint = Vector2.new(1, 0), Position = at(cw - 12, 44), Size = sz(78, 56), Visible = false, Parent = card })
		overArt(card)
		r = { frame = card, header = header, name = name, count = count, tag = tag, dot = dot, tagText = tagText, photo = photo, photoTape = photoTape, team = team, pic = nil :: Instance?, picFor = nil :: string?, data = nil :: any }
		Kit.tip(hit, function(tip)
			Kit.text({ Text = if r.data then actionText(r.data, self.queued == r.data.id) else "", FontFace = F.uiBold, Parent = tip })
		end)
		self.reports[i] = r
	end

	-- The credits bar (LICENSING_PLAN 7(b) and 7(c); CC BY-SA attribution),
	-- which opens the credits and source window (Bruno, 2026-11-08). Above
	-- the folders' click areas (30+), which reach down over it.
	local bar = Kit.new("TextButton", { Name = "Credits", Text = "", AutoButtonColor = false, BackgroundColor3 = BAR, BorderSizePixel = 0, Position = at(62, 540), Size = sz(926, 22), ZIndex = 45, Parent = stage })
	self:_creditsButton(bar)
	Kit.label({
		Text = CreditsText.BAR,
		FontFace = F.ui,
		TextSize = 19,
		TextColor3 = C.sheet,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = bar,
	})

	self:_buildOrders(stage)
	self.tagSizes = { sz(64, 24), sz(78, 24) }
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
	local tag = Kit.new("TextButton", { Name = "StarterTag", Text = "", AutoButtonColor = false, BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = if compact then UDim2.new(1, -140, 0, 80) else at(871, 108), Size = if compact then UDim2.fromOffset(250, 56) else sz(150, 30), Rotation = -2, Visible = false, ZIndex = 14, Parent = if compact then self.layer else self.stage })
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

	-- Conquest General's card (Bruno, 2026-11-09: on the menu, as RoWorld
	-- does), under the starter tag, or in its place when there's none.
	if Catalog.SUBSCRIPTION.id ~= "" then
		-- (Desktop: on the stage, centred under the TOP-SECRET note.)
		local size = if compact then Vector2.new(250, 64) else Vector2.new(math.round(150 * K), math.round(40 * K))
		-- Anchored at its centre from the start: Dossier.clicky re-anchors a
		-- hovered button there and shifts it, so a top anchor here made the
		-- card jump up by half its height whenever the profile view set its
		-- position again (after a crate; Bruno, 2026-11-09).
		local card, setOn = GeneralOffer.card(if compact then self.layer else self.stage, size, { AnchorPoint = Vector2.new(0.5, 0.5), Rotation = 1.5, ZIndex = 13 })
		card.Activated:Connect(function()
			click()
			if self.actions.openGeneral then
				self.actions.openGeneral()
			end
		end)
		self.generalCard, self.setGeneralOn = card, setOn
		self.generalAt = {
			-- (Desktop: midway between the note's bottom edge, y 104, and the
			-- SOLO DEPLOYMENT stamp's red border, equal space above and below;
			-- Bruno, 2026-11-09, after 140 was too low and 108 too high.)
			-- (Centres: the card's top edge at 122 / 142, desktop 40 tall; phone
			-- top at 80 / 146, 64 tall.)
			high = if compact then UDim2.new(1, -140, 0, 80 + 32) else at(871, 122 + 20),
			low = if compact then UDim2.new(1, -140, 0, 146 + 32) else at(871, 142 + 20),
		}
		card.Position = self.generalAt.high
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
function MainMenu._redRibbon(name: string, text: string, card: Instance, pos: UDim2, size: UDim2, textSize: number): Frame
	local ribbon = Kit.new("Frame", { Name = name, BackgroundColor3 = C.stamp, BorderSizePixel = 0, Position = pos, Size = size, Visible = false, Parent = card })
	Kit.stroke(Color3.fromHex("#6E1A14"), 2, 0).Parent = ribbon
	stencil({ Text = text, TextSize = textSize, TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = ribbon })
	return ribbon
end

-- The free crate (Bruno, 2026-11-16): a red FREE CRATE ribbon on SUPPLY
-- CRATES while it waits; the two-line name moves up to `namePos` for it.
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

	-- The board everything is pinned to, under the title strip.
	local board = surface("ImageLabel", "tex_board", C.board, { Name = "Board", Position = at(6, 78), Size = sz(W - 12, 428), ZIndex = 1, Parent = stage })
	if A.board ~= "" then
		board.Image, board.ScaleType = A.board, Enum.ScaleType.Stretch
	end
	Kit.corner(4).Parent = board
	Kit.stroke(C.boardDark, 2, 0).Parent = board

	-- Top right: the note with stars, the crate price, settings and sound.
	local note = surface("ImageLabel", "tex_paper", C.sheet, { Name = "Secret", AnchorPoint = Vector2.new(1, 0), Position = at(W - 8, 6), Size = sz(0, 66), AutomaticSize = Enum.AutomaticSize.X, Rotation = 0.8, ZIndex = 12, Parent = stage })
	Kit.stroke(C.sheetLine, 1, 0.2).Parent = note
	Kit.padding(0, 12).Parent = note
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = note
	icon("icon_star", "star", { Size = sz(24, 24), LayoutOrder = 1, Parent = note })
	self.starsText = stencil({ Name = "Stars", Text = "…", TextSize = 40, LayoutOrder = 2, Parent = note })
	local badge = Kit.new("TextButton", { Name = "CratePrice", Text = "", AutoButtonColor = false, BackgroundColor3 = BADGE, BorderSizePixel = 0, Size = sz(0, 48), AutomaticSize = Enum.AutomaticSize.X, Visible = false, LayoutOrder = 3, Parent = note })
	Kit.corner(5).Parent = badge
	Kit.stroke(Color3.fromRGB(31, 90, 43), 2, 0).Parent = badge
	Kit.padding(0, 10).Parent = badge
	Kit.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = badge
	Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, Size = UDim2.fromOffset(26, 26), LayoutOrder = 1, Parent = badge })
	self.crateText = stencil({ Text = "", TextSize = 38, TextColor3 = C.sheet, LayoutOrder = 2, Parent = badge })
	self.crateBadge = badge
	Dossier.clicky(badge, 1.1)
	badge.Activated:Connect(function()
		click()
		actions.openLocker()
	end)
	local function noteIcon(name: string, glyph: string, order: number, onClick: () -> ())
		local b = surface("ImageButton", "tex_manila", C.manilaDark, { Name = glyph, Size = sz(58, 58), ImageColor3 = Color3.fromRGB(214, 200, 172), LayoutOrder = order, Parent = note })
		Kit.corner(6).Parent = b
		icon(name, glyph, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz(36, 36), Parent = b })
		Dossier.clicky(b, 1.1)
		b.Activated:Connect(function()
			click()
			onClick()
		end)
		return b
	end
	noteIcon("icon_settings", "settings", 4, actions.openSettings)
	self.soundSlash = Kit.slash(noteIcon("icon_sound", "music", 5, actions.toggleMusic))
	self:setMusicOn(self.musicOn)

	-- Top: the title strip, from right of Roblox's buttons to the note.
	local left = root.topLeft
	local band = surface("ImageLabel", "tex_paper", C.sheet, { Name = "TitleBand", Position = at(left, 8), Size = sz(math.max(200, W - 8 - 340 - left), 62), ZIndex = 3, Parent = stage })
	if A.title_band ~= "" then
		band.Image, band.ScaleType = A.title_band, Enum.ScaleType.Stretch
	end
	if art("logo", { Name = "Title", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 14, 0.5, 0), Size = UDim2.new(1, -28, 0, 46), Parent = band }) == nil then
		stencil({ Name = "Title", Text = "CONQUER COUNTRIES", TextSize = 50, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 14, 0.5, 0), Parent = band })
	end

	-- Left: the four requisition folders, each overlapping the one above.
	local function requisition(name: string, text: string, y: number, z: number, iconName: string, glyph: string, onClick: () -> ()): ImageButton
		local h = 100
		local card, shade = folderCard(stage, name, 12, y, 266, h, 130, z, "folder_card", { 150, 24, 52 })
		-- Pulled out to the right, tipped down, as on desktop.
		local hit = self:_lift(card, shade, 26, 0, 3, function()
			click()
			onClick()
		end)
		Dossier.clicky(hit, 1, card, false)
		stencil({ Name = "Name", Text = text, TextSize = 38, LineHeight = 0.86, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(14, 50), Parent = card })
		icon(iconName, glyph, { Name = "Icon", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromOffset(256, 50), Size = sz(78, 70), Parent = card })
		return card
	end
	local party = requisition("Party", "PARTY", 84, 5, "icon_party", "party", actions.openParty)
	self.partyText = typed({ Name = "Squad", Text = "", TextSize = 17, TextColor3 = C.inkBlack, Position = at(14, 72), Visible = false, Parent = party })
	local armory = requisition("Armory", "ARSENAL", 190, 6, "icon_armory", "silo", actions.openArsenal)
	self:_dealRibbon(armory, at(4, 70), sz(150, 26), 30)
	local crates = requisition("Crates", "SUPPLY\nCRATES", 296, 7, "icon_crates", "chest", actions.openLocker)
	self:_crateRibbon(crates, at(4, 68), sz(160, 26), 30, UDim2.fromOffset(14, 36))
	local shop = requisition("FlagShop", "FLAG SHOP", 402, 8, "icon_flag", "flag", actions.openFlagShop)
	-- The flag shop's name moves up for its event ribbon.
	local shopName = shop:FindFirstChild("Name") :: TextLabel
	shopName.Position = UDim2.fromOffset(14, 34)
	local ribbon = Kit.new("Frame", { Name = "Ribbon", BackgroundColor3 = RIBBON, BorderSizePixel = 0, Position = at(4, 66), Size = sz(258, 28), Parent = shop })
	Kit.stroke(Color3.fromRGB(120, 52, 14), 2, 0).Parent = ribbon
	self.flagEvent = stencil({ Text = "TODAY'S FLAGS", TextSize = 32, TextColor3 = C.sheet, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Parent = ribbon })
	self.flagTimer = typed({ Text = "", TextSize = 16, TextColor3 = C.sheet, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Parent = ribbon })
	art("paperclip", { Name = "Clip", Position = at(-6, 14), Size = sz(12, 38), Parent = party })
	for _, card in { party, armory, crates, shop } do
		overArt(card)
	end

	-- Right: solo deployment, the stamp over the PLAY plate.
	local rx = W - 140
	local stampProps = { Name = "SoloStamp", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(rx, 152), Size = sz(236, 138), Rotation = -5, ZIndex = 7 }
	local soloStamp
	if A.stamp_solo ~= "" then
		soloStamp = Kit.new("ImageButton", merge({ AutoButtonColor = false, BackgroundTransparency = 1, Image = A.stamp_solo, ScaleType = Enum.ScaleType.Fit }, merge(stampProps, { Parent = stage })))
	else
		soloStamp = Kit.new("TextButton", merge({ Text = "", AutoButtonColor = false, BackgroundTransparency = 1 }, merge(stampProps, { Parent = stage })))
		Kit.stroke(C.stamp, 5, 0.05).Parent = soloStamp
		stencil({ Text = "SOLO", TextSize = 90, TextColor3 = C.stamp, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Parent = soloStamp })
	end
	Dossier.clicky(soloStamp, 0.94)
	local function openSolo()
		self:showSolo(true)
	end
	soloStamp.Activated:Connect(function()
		click()
		openSolo()
	end)
	local play = plate(stage, "PLAY", { Name = "Play", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(rx, 288), Size = sz(244, 92), ZIndex = 8, Parent = stage }, 80)
	play.Activated:Connect(openSolo)
	Dossier.clicky(play, 1.06)
	tape(play, "red_tape", 14, 50, 80, 20, 56, 0, C.stamp)
	tape(play, "red_tape", 232, 18, 80, 20, 48, 0, C.stamp)

	-- Centre: the war map, and the World queue's frontline note on it.
	local cx0, cx1 = 290, W - 278
	local mapProps = { Name = "WarMap", Position = at(cx0, 88), Size = sz(cx1 - cx0, 254), ZIndex = 5 }
	shadow(stage, mapProps, 4)
	local map = Kit.new("Frame", merge({ BackgroundColor3 = METAL, BorderSizePixel = 0 }, merge(mapProps, { Parent = stage })))
	Kit.corner(3).Parent = map
	Kit.stroke(Color3.fromRGB(24, 26, 26), 2, 0).Parent = map
	local view = Kit.new("Frame", { Name = "View", BackgroundColor3 = Color3.fromRGB(38, 92, 140), BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12), Parent = map })
	local world = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(math.ceil(242 * aspect), 242), Parent = view })
	for i, image in UiAssets.backdrop do
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = image, Position = UDim2.fromScale((i - 1) * 0.5, 0), Size = UDim2.fromScale(0.5, 1), ScaleType = Enum.ScaleType.Stretch, Parent = world })
	end
	Kit.new("Frame", { Name = "Slate", BackgroundColor3 = Color3.fromRGB(34, 44, 44), BackgroundTransparency = 0.5, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = view })
	for gx = 1, 5 do
		Kit.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.88, BorderSizePixel = 0, Position = UDim2.new(gx / 6, 0, 0, 0), Size = UDim2.new(0, 1, 1, 0), Parent = view })
	end
	for gy = 1, 3 do
		Kit.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.88, BorderSizePixel = 0, Position = UDim2.new(0, 0, gy / 4, 0), Size = UDim2.new(1, 0, 0, 1), Parent = view })
	end
	pin(stage, cx0 + 14, 98, 6)

	local frontProps = { Name = "Frontline", AnchorPoint = Vector2.new(1, 0), Position = at(cx1 - 8, 96), Size = sz(206, 236), Rotation = 2, ZIndex = 10 }
	shadow(stage, frontProps, 9)
	local front = surface("ImageLabel", "tex_paper", C.sheet, merge(frontProps, { Parent = stage }))
	Kit.stroke(C.sheetLine, 1, 0.2).Parent = front
	pin(front, 103, 12, 0)
	stencil({ Text = "DEPLOY TO\nFRONTLINE", TextSize = 38, LineHeight = 0.88, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 28), Parent = front })
	local frontBtn = Kit.new("TextButton", { Name = "Join", Text = "", AutoButtonColor = false, BackgroundColor3 = GOLD_BUTTON, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 148), Size = sz(172, 66), Parent = front })
	Kit.corner(4).Parent = frontBtn
	Kit.stroke(C.inkBlack, 3, 0).Parent = frontBtn
	Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)), ColorSequenceKeypoint.new(0.55, Color3.new(1, 1, 1)), ColorSequenceKeypoint.new(1, Color3.fromRGB(205, 190, 160)) }), Parent = frontBtn })
	local frontLabel = stencil({ Text = "JOIN", TextSize = 48, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = frontBtn })
	Dossier.clicky(frontBtn, 1.06)
	local frontCount = stencil({ Text = "", TextSize = 22, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 188), Size = sz(194, 40), Parent = front })
	self.front = { frame = front, btn = frontBtn, label = frontLabel, count = frontCount, data = nil :: any }
	frontBtn.Activated:Connect(function()
		click()
		self:_press(self.front.data)
	end)

	-- Bottom: the other public queues, as field reports (three since Blitz).
	self.reports = {}
	local rw = (W - 10 - cx0 - 24) / 3
	for i = 1, 3 do
		local x = cx0 + (i - 1) * (rw + 12)
		local card, shade = folderCard(stage, `Report{i}`, x, 362, rw, 140, 110, 5, "folder_report", { rw - 66, 80, 50 })
		local r: any
		local hit = self:_lift(card, shade, 0, -26, 0, function()
			click()
			self:_press(r.data)
		end)
		Dossier.clicky(hit, 1, card, false)
		local header = typed({ Text = "", TextColor3 = C.inkBlack, TextSize = 18, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0, 0.5), Position = at(12, 20), Size = sz(rw - 104, 24), Parent = card })
		Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.25, BorderSizePixel = 0, Position = at(12, 34), Size = UDim2.fromOffset(math.round(rw - 24), 2), Parent = card })
		local name = stencil({ Text = "", TextSize = 36, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, Size = sz(rw - 112, 40), TextYAlignment = Enum.TextYAlignment.Top, Position = at(12, 44), Parent = card })
		local count = typed({ Text = "", TextColor3 = C.inkBlack, TextSize = 18, AutomaticSize = Enum.AutomaticSize.None, Size = sz(rw - 112, 24), Position = at(12, 88), Parent = card })
		local tag = Kit.new("Frame", { Name = "Tag", BackgroundColor3 = C.inkBlack, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = at(rw - 8, 6), Size = sz(84, 30), Parent = card })
		Kit.corner(3).Parent = tag
		local dot = Kit.new("Frame", { BackgroundColor3 = C.red, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(13, 15), Size = sz(10, 10), Parent = tag })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
		local tagText = stencil({ Text = "LIVE", TextSize = 28, TextColor3 = C.sheet, AnchorPoint = Vector2.new(0, 0.5), Position = at(24, 15), Parent = tag })
		local photo = Kit.new("Frame", { Name = "Photo", BackgroundColor3 = C.sheet, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = at(rw - 10, 44), Size = sz(92, 64), Rotation = 3, Parent = card })
		Kit.stroke(C.sheetLine, 1, 0).Parent = photo
		local photoTape = tape(card, "tape", rw - 64, 46, 48, 14, -4, 7, C.tape)
		local team = icon("icon_team", "troops", { Name = "Team", AnchorPoint = Vector2.new(1, 0), Position = at(rw - 12, 46), Size = sz(88, 62), Visible = false, Parent = card })
		overArt(card)
		r = { frame = card, header = header, name = name, count = count, tag = tag, dot = dot, tagText = tagText, photo = photo, photoTape = photoTape, team = team, pic = nil :: Instance?, picFor = nil :: string?, data = nil :: any }
		self.reports[i] = r
	end
	self.tagSizes = { sz(84, 30), sz(108, 30) }

	-- The credits line (LICENSING_PLAN 7(b) and 7(c); CC BY-SA attribution),
	-- which opens the credits and source window (Bruno, 2026-11-08).
	local bar = Kit.new("TextButton", { Name = "Credits", Text = "", AutoButtonColor = false, BackgroundColor3 = BAR, BorderSizePixel = 0, Position = at(6, 512), Size = sz(W - 12, 24), ZIndex = 45, Parent = stage })
	self:_creditsButton(bar)
	Kit.label({
		Text = CreditsText.BAR,
		FontFace = F.ui,
		TextSize = 16,
		TextColor3 = C.sheet,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
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
	local paper = surface("ImageLabel", "tex_paper", C.sheet, { Name = "Sheet", Position = at(6, 6), Size = sz(W - 12, H - 12), Parent = orders })
	Kit.stroke(C.sheetLine, 2, 0).Parent = paper
	local pw = W - 12
	-- The header, clear of Roblox's buttons.
	local tx = math.max(24, root.topLeft - 6)
	stencil({ Text = "DEPLOYMENT ORDERS", TextSize = 56, AnchorPoint = Vector2.new(0, 0.5), Position = at(tx, 38), Parent = paper })
	art("stamp_secret", { AnchorPoint = Vector2.new(1, 0.5), Position = at(pw - 92, 38), Size = sz(190, 50), Rotation = 6, Parent = paper })
	local close = Kit.new("TextButton", { Name = "Close", Text = "", AutoButtonColor = false, BackgroundColor3 = C.inkBlack, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(pw - 45, 38), Size = sz(62, 62), Parent = paper })
	Kit.corner(6).Parent = close
	Kit.glyph("close", { ImageColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz(30, 30), Parent = close })
	Dossier.clicky(close, 1.08)
	close.Activated:Connect(function()
		click()
		self:showSolo(false)
	end)
	Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = at(20, 74), Size = sz(pw - 40, 2), Parent = paper })

	typed({ Text = "1. THEATRE OF OPERATIONS", TextSize = 19, TextColor3 = C.inkBlack, Position = at(24, 84), Parent = paper })
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

	typed({ Text = "2. THREAT LEVEL", TextSize = 19, TextColor3 = C.inkBlack, Position = at(24, 212), Parent = paper })
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
			self.difficulty = d
			self:_refreshSolo()
		end)
		self.diffChips[d] = chip
	end
	self.diffText = typed({
		Text = "",
		TextSize = 20,
		TextColor3 = C.inkBlack,
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
	end
	local start = plate(paper, "START", { Name = "Start", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(pw - 185, by - 4), Size = sz(330, 92), Parent = paper }, 70)
	start.Activated:Connect(function()
		actions.startSolo(self.soloMap, self.difficulty)
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
	local paper = surface("ImageLabel", "tex_paper", C.sheet, { Name = "Sheet", Position = at(268, 104), Size = sz(540, 326), Rotation = -1, Parent = orders })
	Kit.stroke(C.sheetLine, 2, 0).Parent = paper
	tape(paper, "tape", 30, 2, 70, 20, -30, 0, C.tape)
	tape(paper, "tape", 510, 2, 70, 20, 30, 0, C.tape)
	stencil({ Text = "DEPLOYMENT ORDERS", TextSize = 70, Position = UDim2.fromOffset(48, 26), Parent = paper })
	typed({ Text = "Operation: solo · one commander against bots and nations", TextSize = 19, Position = UDim2.fromOffset(50, 112), Parent = paper })
	if art("stamp_secret", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -110, 0, 34), Size = UDim2.fromOffset(250, 64), Rotation = 6, Parent = paper }) == nil then
		local classified = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -110, 0, 36), Size = UDim2.fromOffset(230, 56), Rotation = 6, Parent = paper })
		Kit.stroke(C.stamp, 3, 0.1).Parent = classified
		stencil({ Text = "TOP-SECRET", TextSize = 40, TextColor3 = C.stamp, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = classified })
	end
	local close = Kit.new("TextButton", { Name = "Close", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -48, 0, 48), Size = UDim2.fromOffset(56, 56), Parent = paper })
	Dossier.clicky(close, 1.12)
	Kit.glyph("close", { ImageColor3 = C.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(28, 28), Parent = close })
	close.Activated:Connect(function()
		click()
		self:showSolo(false)
	end)
	Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = UDim2.fromOffset(48, 148), Size = UDim2.new(1, -96, 0, 2), Parent = paper })

	typed({ Text = "1. THEATRE OF OPERATIONS", TextSize = 20, TextColor3 = C.inkBlack, Position = UDim2.fromOffset(50, 166), Parent = paper })
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

	typed({ Text = "2. THREAT LEVEL", TextSize = 20, TextColor3 = C.inkBlack, Position = UDim2.fromOffset(50, 308), Parent = paper })
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
			self.difficulty = d
			self:_refreshSolo()
		end)
		self.diffChips[d] = chip
	end
	self.diffText = typed({
		Text = "",
		TextSize = 19,
		TextColor3 = C.inkBlack,
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
	local start = plate(paper, "START", { Name = "Start", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -48 - 190, 1, -28 - 50), Size = UDim2.fromOffset(380, 100), Parent = paper }, 76)
	start.Activated:Connect(function()
		actions.startSolo(self.soloMap, self.difficulty)
	end)
	Dossier.clicky(start, 1.06)
	self:_refreshSolo()
end

-- A folder pops out on hover: moved by (dx, dy) canvas units and turned by
-- `rot` degrees with a spring, brighter, drawn over its neighbours, its
-- shadow longer and darker; it settles back on leave. An invisible hit area
-- stays where the folder rests, so a folder that moves out from under the
-- pointer doesn't flicker. A click calls `onOpen`. With no hover (a phone),
-- a tap pops the folder out with its rustle and opens it a moment later
-- (Bruno, 2026-10-27); a click on a folder already out thuds. Returns the
-- hit area.
local POP_BEFORE_OPEN = 0.25
function MainMenu._lift(self: any, card: ImageButton, shade: Frame, dx: number, dy: number, rot: number, onOpen: () -> ()): TextButton
	local pos, turn, z = card.Position, card.Rotation, card.ZIndex
	local shadePos, shadeSize = shade.Position, shade.Size
	local hit = Kit.new("TextButton", { Name = card.Name .. "Hit", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = card.AnchorPoint, Position = pos, Size = card.Size, Rotation = turn, ZIndex = 30 + z, Parent = card.Parent })
	-- With folder art, the shadow is a dark copy of the picture inside the card.
	local artShadow = card:FindFirstChild("ArtShadow") :: ImageLabel?
	local artShadowPos = if artShadow then artShadow.Position else nil
	local hovering = false
	local poppedAt = 0
	local function pop()
		hovering = true
		poppedAt = os.clock()
		card.ZIndex, shade.ZIndex = 21, 20
		card.ImageColor3 = Color3.fromRGB(255, 250, 238)
		card.BackgroundColor3 = C.manila:Lerp(Color3.new(1, 1, 1), 0.15)
		TweenService:Create(card, SPRING, { Position = pos + UDim2.fromOffset(dx, dy), Rotation = turn + rot }):Play()
		TweenService:Create(shade, SPRING, { Position = shadePos + UDim2.fromOffset(dx + 8, dy + 12), Size = shadeSize + UDim2.fromOffset(6, 6), Rotation = turn + rot, BackgroundTransparency = 0.5 }):Play()
		if artShadow and artShadowPos then
			TweenService:Create(artShadow, SPRING, { Position = artShadowPos + UDim2.fromOffset(8, 12), ImageTransparency = 0.45 }):Play()
		end
		Dossier.rustle()
	end
	hit.MouseEnter:Connect(function()
		if not Kit.covered(hit) then
			pop()
		end
	end)
	local function settle()
		hovering = false
		card.ImageColor3 = Color3.new(1, 1, 1)
		card.BackgroundColor3 = C.manila
		local back = TweenService:Create(card, SETTLE, { Position = pos, Rotation = turn })
		back.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and not hovering then
				card.ZIndex, shade.ZIndex = z, z
			end
		end)
		back:Play()
		TweenService:Create(shade, SETTLE, { Position = shadePos, Size = shadeSize, Rotation = turn, BackgroundTransparency = 0.68 }):Play()
		if artShadow and artShadowPos then
			TweenService:Create(artShadow, SETTLE, { Position = artShadowPos, ImageTransparency = 0.6 }):Play()
		end
	end
	hit.MouseLeave:Connect(settle)
	hit.Activated:Connect(function()
		if hovering then
			if os.clock() - poppedAt >= POP_BEFORE_OPEN then
				Dossier.thud()
			end
		else
			pop()
		end
		-- Opens once the pop has had its moment; the window then covers the
		-- menu, and no MouseLeave follows.
		task.delay(math.max(0, POP_BEFORE_OPEN - (os.clock() - poppedAt)), function()
			if hit.Parent then
				onOpen()
				task.delay(0.15, settle)
			end
		end)
	end)
	return hit
end

function MainMenu.showSolo(self: any, on: boolean)
	self.orders.Visible = on
end

function MainMenu._refreshSolo(self: any)
	local entry = MapCatalog.get(self.soloMap)
	self.mapText.Text = string.upper(if entry then entry.name else self.soloMap)
	if self.mapPic then
		self.mapPic:Destroy()
	end
	self.mapPic = MainMenu.fieldMap(self.soloMap, { Size = UDim2.new(1, -8, 1, -8), Position = UDim2.fromOffset(4, 4), Parent = self.mapPhoto })
	for d, chip in self.diffChips do
		local on = d == self.difficulty
		chip.BackgroundColor3 = if on then C.inkBlack else C.sheet
		chip.TextColor3 = if on then C.hazard else C.inkBlack
	end
	self.diffText.Text = MenuModel.difficultyText(self.difficulty)
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
	f.count.TextColor3 = if row.live or mine then C.stamp else C.inkBlack
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
	self.crateBadge.Visible = view.cratePrice ~= nil
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
		self.generalCard.Position = if self.starterTag.Visible then self.generalAt.low else self.generalAt.high
		self.setGeneralOn(view.general == true)
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
