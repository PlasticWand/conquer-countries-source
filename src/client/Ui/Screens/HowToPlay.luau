--!strict
-- How to Play as a dossier window, laid out 1:1 to Bruno's reference
-- (2026-10-26, docs/design/dossier-ui/howtoplay-reference.png, 1483 x 1061):
-- seven numbered idea folders with an icon on a red stamped square (two per
-- row; the economy folder spans the width and lists every building) on a
-- scrolling page, then the CONTROLS strip, pinned under it. Bruno,
-- 2026-10-27: roomier and neat. Each folder has its number on the tab, its
-- title and text on one left edge with margins clear of the papers, and is
-- as tall as its text (measured once the font is known); a row's two
-- folders match. On a phone it fills the screen and each idea has a
-- full-width folder. Each of its headings (mouse, keys, touch) opens that
-- input's list on a paper card. Content and numbers come from HelpModel and
-- the match's config.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local HelpModel = require(Shared.HelpModel)
local EngineConfig = require(Shared.OpenFront.EngineConfig)

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)

local C = Theme.color
local F = Theme.font

local HowToPlay = {}

local WINDOW_H = 1000
local DISC = Color3.fromHex("#1F1D19")

-- Each idea's icon art by number (fallback: HelpModel's atlas icon).
local IDEA_ART = { "idea_target", "idea_sword", "idea_ship", "idea_handshake", "idea_buildings", "idea_radiation", "idea_crown" }
-- The idea icons' colours, for the atlas fallback.
local TONES: { [string]: Color3 } = { amber = C.hazard, red = C.stamp, cyan = Color3.fromHex("#2EC4E8"), violet = Color3.fromHex("#9A5BF0"), gold = C.hazard }
-- Building icon art by HelpModel icon.
local BUILDING_ART: { [string]: string } = { city = "bld_city", port = "bld_port", factory = "bld_factory", defense = "bld_defense", sam = "bld_sam", silo = "bld_silo", warship = "bld_warship" }

-- An idea folder's insides, in reference pixels.
local TAB_H = 46 -- the folder art's tab band
local TEXT_X = 150 -- titles and text start here, right of the icon
local RIGHT_GAP = 72 -- clear of the papers sticking out, and a margin
local TITLE_Y = 74 -- the title's centre
local BODY_Y = 114 -- the text's top, a clear gap under the title
local BOTTOM = 30
local ICON_X, ICON_Y, ICON_SIZE = 80, 120, 76
local TEXT_SIZE = 21
local LINE = 1.15
local ROW_GAP = 18
local LEFT, RIGHT, HALF, FULL = 40, 750, 690, 1405
-- The economy folder's building list: two columns, rows this tall.
local ROW = 70
-- folder_card.png (1024 x 430): its tab (x < 430, kept whole), then the
-- front panel from y 72.
local FOLDER_SLICE = Rect.new(430, 100, 970, 380)
local FOLDER_TOP = 72

-- `config` is the match's EngineConfig when in a match (nil: OpenFront's public defaults).
function HowToPlay.open(host: Instance, config: any?): Kit.Modal
	config = config or EngineConfig.new({ difficulty = "Medium", gameType = "Public" } :: any, false)
	local phone = Dossier.phone()
	Dossier.style = { wash = Color3.fromHex("#3E9A4E"), art = "banner_howto" }
	local w = if phone then Dossier.phoneWindow(host, "HOW TO PLAY") else Dossier.window(host, 1483, 1061, WINDOW_H, 36)
	local at, sz = w.at, w.sz
	local head = w.header
	-- Where the folders go: two a row on desktop, one a row on a phone.
	local left, right, half, full = LEFT, RIGHT, HALF, FULL
	if phone then
		left, full = 12, w.width - 24 - 14
		right, half = left, full
	end

	if not phone then
		-- Header.
		Dossier.headerPaper(w, 45, 15, 1150, 102, 0)
		Dossier.bigCaps(w, 62, { Text = "HOW TO PLAY", AnchorPoint = Vector2.new(0, 0.5), Position = at(118, 67), Parent = head })
		Dossier.starStamp(head, w, 675, 67, 82, 0.72)
		for _, y in { 54, 86 } do
			Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.4, BorderSizePixel = 0, Position = at(735, y), Size = UDim2.fromOffset(math.round(350 * w.k), 1), Parent = head })
		end
		Dossier.typed({ Text = "Conquer the world in seven ideas.", TextColor3 = C.inkBlack, TextSize = math.round(22 * w.k), AnchorPoint = Vector2.new(0, 0.5), Position = at(740, 70), Parent = head })
		local badge = Dossier.art("badge_soldier", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1300, 68), Size = sz(190, 128), Rotation = 2, Parent = head })
		if badge == nil then
			Dossier.icon("icon_party", "party", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1300, 68), Size = sz(110, 110), Parent = head })
		end
		Dossier.clip(head, w, 1216, 48, 80, -4)
		Dossier.closeManila(head, at(1428, 58), sz(72, 64), w.close)
	end

	local cards = HelpModel.cards(config)

	-- The page the folders scroll on, between the header and CONTROLS.
	local page = Kit.scroll({
		Name = "Ideas",
		Position = if phone then at(0, 0) else at(0, 124),
		Size = if phone then sz(w.width, w.height - 76) else sz(1462, 852),
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		ScrollBarThickness = math.round(10 * w.k),
		ScrollBarImageColor3 = Color3.fromHex("#1E2019"),
		Parent = w.body,
	})

	-- A folder's text: its label, words and width (reference pixels), and its
	-- height, estimated until the font is measured.
	type Body = { label: TextLabel, text: string, width: number, height: number }
	local bodies: { Body } = {}
	local function body(parent: Instance, text: string, width: number): Body
		local label = Dossier.typed({
			Text = text,
			TextColor3 = C.inkBlack,
			TextSize = math.round(TEXT_SIZE * w.k),
			LineHeight = LINE,
			TextWrapped = true,
			AutomaticSize = Enum.AutomaticSize.None,
			TextYAlignment = Enum.TextYAlignment.Top,
			Position = at(TEXT_X, BODY_Y),
			Size = sz(width, 40),
			Parent = parent,
		})
		local perLine = math.max(1, math.floor(width / (TEXT_SIZE * 0.6)))
		local b = { label = label, text = text, width = width, height = math.ceil(#text / perLine) * TEXT_SIZE * LINE }
		table.insert(bodies, b)
		return b
	end

	-- An idea folder: the number on its tab, the title, the icon on the red
	-- square, the text.
	local function idea(card: HelpModel.Card, ww: number): (GuiObject, Body)
		local folder = Dossier.cardArt("ImageLabel", "folder_card", { Name = `Idea{card.n}`, Size = sz(ww, 200), Parent = page })
		if folder:IsA("ImageLabel") and folder.Image ~= "" then
			-- Sliced, so the tab and edges keep their size on any folder.
			folder.ScaleType = Enum.ScaleType.Slice
			folder.SliceCenter = FOLDER_SLICE
			folder.SliceScale = TAB_H * w.k / FOLDER_TOP
		end
		local tag = Kit.new("Frame", { BackgroundColor3 = C.hazard, BorderSizePixel = 0, Position = at(26, 8), Size = sz(68, 36), Parent = folder })
		Kit.corner(3).Parent = tag
		Kit.stroke(Color3.fromHex("#A87C12"), 2, 0).Parent = tag
		Dossier.stencil({ Text = string.format("%02d", card.n), TextSize = Dossier.capSize(w, 22), AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, Parent = tag })
		Dossier.stencil({ Text = string.upper(card.title), TextSize = Dossier.capSize(w, 28), AnchorPoint = Vector2.new(0, 0.5), Position = at(TEXT_X, TITLE_Y), Parent = folder })
		-- The icon: a black disc on a red stamped square.
		local square = Dossier.art("red_square", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(ICON_X, ICON_Y), Size = sz(ICON_SIZE * 1.2, ICON_SIZE * 1.2), Rotation = -6, Parent = folder })
		if square == nil then
			local s = Kit.new("Frame", { BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(ICON_X, ICON_Y), Size = sz(ICON_SIZE * 1.1, ICON_SIZE * 1.1), Rotation = -6, Parent = folder })
			Kit.corner(3).Parent = s
		end
		local disc = Kit.new("Frame", { BackgroundColor3 = DISC, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(ICON_X, ICON_Y), Size = sz(ICON_SIZE, ICON_SIZE), Parent = folder })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = disc })
		local tone = TONES[card.tone] or C.hazard
		local iconProps = { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6), Parent = disc }
		if Dossier.art(IDEA_ART[card.n] or "", iconProps) == nil then
			Kit.glyph(card.icon, Dossier.merge({ ImageColor3 = tone }, iconProps))
		end
		return folder, body(folder, card.text, ww - TEXT_X - RIGHT_GAP)
	end

	-- Rows of folders, top to bottom; a row's folders share one height.
	type Row = { folders: { GuiObject }, bodies: { Body }, x: { number }, ww: number, under: number }
	local rows: { Row } = {}
	local function pair(a: HelpModel.Card, b: HelpModel.Card): GuiObject
		local fa, ba = idea(a, half)
		local fb, bb = idea(b, half)
		if phone then
			table.insert(rows, { folders = { fa }, bodies = { ba }, x = { left }, ww = full, under = 0 })
			table.insert(rows, { folders = { fb }, bodies = { bb }, x = { left }, ww = full, under = 0 })
		else
			table.insert(rows, { folders = { fa, fb }, bodies = { ba, bb }, x = { left, right }, ww = half, under = 0 })
		end
		return fa
	end
	pair(cards[1], cards[2])
	pair(cards[3], cards[4])

	-- Economy: full width, the building list in two columns under its text.
	local eco, ecoBody = idea(cards[5], full)
	local colW = (full - TEXT_X - RIGHT_GAP) / 2
	local list = Kit.new("Frame", { Name = "Buildings", BackgroundTransparency = 1, Size = sz(full, 4 * ROW), Parent = eco })
	Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.6, BorderSizePixel = 0, Position = at(TEXT_X + colW - 14, 0), Size = UDim2.fromOffset(1, math.round(4 * ROW * w.k)), Parent = list })
	for i, b in HelpModel.buildings(config) do
		-- Left column first (four), as in the reference.
		local col, rowN = if i <= 4 then 0 else 1, if i <= 4 then i - 1 else i - 5
		local x = TEXT_X + col * colW
		local y = rowN * ROW + 6
		local tile = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#2B2924"), BorderSizePixel = 0, Position = at(x, y), Size = sz(48, 44), Parent = list })
		Kit.corner(4).Parent = tile
		local iconProps = { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.72, 0.72), Parent = tile }
		if Dossier.art(BUILDING_ART[b.icon] or "", iconProps) == nil then
			Kit.glyph(b.icon, Dossier.merge({ ImageColor3 = C.hazard }, iconProps))
		end
		Dossier.stencil({ Text = b.name, FontFace = F.uiHeavy, TextSize = math.round(24 * w.k), Position = at(x + 64, y - 6), Parent = list })
		Dossier.typed({ Text = b.text, TextColor3 = C.inkBlack, TextSize = math.round(18 * w.k), LineHeight = 1.1, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, TextYAlignment = Enum.TextYAlignment.Top, Position = at(x + 64, y + 20), Size = sz(colW - 64 - 30, 44), Parent = list })
		Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.75, BorderSizePixel = 0, Position = at(x, rowN * ROW + ROW - 4), Size = UDim2.fromOffset(math.round((colW - 30) * w.k), 1), Parent = list })
	end
	table.insert(rows, { folders = { eco }, bodies = { ecoBody }, x = { left }, ww = full, under = 16 + 4 * ROW })
	Dossier.clip(eco, w, -4, 54, 84, 0)

	Dossier.clip(pair(cards[6], cards[7]), w, -10, 52, 84, 0)

	-- Places every folder from its text's height (and the economy folder's
	-- list under its text).
	local function layout()
		local y = 6
		for _, row in rows do
			local h = ICON_Y + ICON_SIZE / 2 + BOTTOM
			for _, b in row.bodies do
				h = math.max(h, BODY_Y + b.height + row.under + BOTTOM)
				b.label.Size = sz(b.width, b.height + 6)
			end
			for i, f in row.folders do
				f.Position = at(row.x[i], y)
				f.Size = sz(row.ww, h)
			end
			y += h + ROW_GAP
		end
		list.Position = at(0, BODY_Y + ecoBody.height + 16)
		page.CanvasSize = UDim2.fromOffset(0, math.round(y * w.k))
	end
	layout()

	-- Measures the text in its font (which may wait for it to load), then
	-- lays the folders out again.
	task.spawn(function()
		for _, b in bodies do
			local ok, bounds = pcall(function(): Vector2
				local params = Instance.new("GetTextBoundsParams")
				params.Text = b.text
				params.Font = F.typewriter
				params.Size = math.round(TEXT_SIZE * w.k)
				params.Width = math.round(b.width * w.k)
				return TextService:GetTextBoundsAsync(params)
			end)
			if ok then
				b.height = bounds.Y / w.k * LINE
			end
		end
		if w.root.Parent then
			layout()
		end
	end)

	-- The CONTROLS strip; each heading opens its list. Desktop places it at
	-- the reference's y = 1018; a phone along the body's foot, with the three
	-- headings sharing its width.
	local stripY = if phone then w.height - 38 else 1018
	local strip = Dossier.surface("ImageLabel", "tex_manila", C.manila, { Name = "Controls", Position = if phone then at(12, stripY - 32) else at(40, 986), Size = if phone then sz(w.width - 24, 64) else sz(1405, 66), Parent = w.body })
	Kit.corner(4).Parent = strip
	Kit.stroke(C.manilaLine, 2, 0.1).Parent = strip
	local label = Dossier.plate(w.body, "", { Name = "ControlsLabel", AnchorPoint = Vector2.new(0.5, 0.5), Position = if phone then at(12 + 110, stripY) else at(182, 1018), Size = sz(215, 58), Active = false, Parent = w.body }, 0)
	Dossier.stencil({ Text = "CONTROLS", TextSize = Dossier.capSize(w, 27), AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, Parent = label })
	Dossier.tape(label, w, "red_tape", 6, 10, 70, 22, 50)
	Dossier.tape(label, w, "red_tape", 210, 46, 70, 22, 50)
	-- The headings' centres and the dividers between them.
	local centres, popXs, segW = { 490, 842, 1188 }, { 520, 860, 1160 }, 320
	local dividers = { 666, 1030 }
	if phone then
		local x0 = 12 + 232
		segW = (w.width - 24 - 232) / 3
		centres = { x0 + segW / 2, x0 + segW * 1.5, x0 + segW * 2.5 }
		dividers = { x0 + segW, x0 + 2 * segW }
		popXs = {}
		for i, c in centres do
			popXs[i] = math.clamp(c, 12 + 280, w.width - 12 - 280)
		end
	end
	for _, x in dividers do
		Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.6, BorderSizePixel = 0, Position = at(x, stripY - 24), Size = UDim2.fromOffset(1, math.round(50 * w.k)), Parent = w.body })
	end

	local all = HelpModel.controls()
	local popup: GuiObject? = nil
	local function showList(title: string, list: { HelpModel.Control }, cx: number)
		if popup then
			local same = popup.Name == title
			popup:Destroy()
			popup = nil
			if same then
				return
			end
		end
		local rows = #list
		local hh = 70 + rows * 40
		local card = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { Name = title, AnchorPoint = Vector2.new(0.5, 1), Position = at(cx, stripY - 40), Size = sz(560, hh), ZIndex = 5, Parent = w.body })
		Kit.stroke(C.sheetLine, 2, 0).Parent = card
		Dossier.stencil({ Text = string.upper(title), TextSize = Dossier.capSize(w, 22), Position = at(24, 16), ZIndex = 5, Parent = card })
		for i, c in list do
			local y = 54 + (i - 1) * 40
			local key = Dossier.stencil({ Text = c.keys, TextSize = Dossier.capSize(w, 15), TextColor3 = C.sheet, BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0, Position = at(24, y), ZIndex = 5, Parent = card })
			Kit.corner(4).Parent = key
			Kit.padding(math.round(3 * w.k), math.round(10 * w.k)).Parent = key
			Dossier.typed({ Text = c.action, TextColor3 = C.inkBlack, TextSize = math.round(19 * w.k), Position = at(250, y + 6), ZIndex = 5, Parent = card })
		end
		popup = card
	end
	local function heading(iconName: string, glyph: string, i: number, title: string, sub: string?, list: { HelpModel.Control })
		local popX = popXs[i]
		local b = Kit.new("TextButton", { Name = title, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(centres[i], stripY), Size = sz(segW - 12, 58), Parent = w.body })
		Dossier.icon(iconName, glyph, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, math.round(30 * w.k), 0.5, 0), Size = sz(if iconName == "ctl_wasd" then 80 else 46, 46), Parent = b })
		Dossier.stencil({ Text = string.upper(title), TextSize = Dossier.capSize(w, 15), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(84 * w.k), if sub then 0.32 else 0.5, 0), Parent = b })
		if sub then
			Dossier.typed({ Text = sub, TextColor3 = C.inkBlack, TextSize = math.round(17 * w.k), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(84 * w.k), 0.72, 0), Parent = b })
		end
		Dossier.clicky(b, 1.04)
		b.Activated:Connect(function()
			Dossier.click()
			showList(title, list, popX)
		end)
		Kit.tip(b, function(card)
			Kit.text({ Text = "Click for the list", FontFace = F.uiBold, Parent = card })
		end)
	end
	heading("ctl_mouse", "mouse", 1, if phone then "Mouse" else "Mouse & keyboard", nil, all.mouse)
	heading("ctl_wasd", "keyboard", 2, "Keys", if phone then nil else "• Build  • Attack share", all.keys)
	heading("ctl_touch", "hand", 3, "Touch", nil, all.touch)
	return (w :: any) :: Kit.Modal
end

return HowToPlay
