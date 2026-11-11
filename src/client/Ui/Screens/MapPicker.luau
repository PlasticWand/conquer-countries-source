--!strict
-- Choose a map as a dossier window, laid out 1:1 to Bruno's reference
-- (2026-10-26, docs/design/dossier-ui/mappicker-reference.png, 1455 x 1081):
-- folder tabs over OpenFront's map categories (MapCatalog), a scrolling grid
-- of map folders (a relief map, the name and the size; the chosen one has a
-- yellow outline), CANCEL, HOW TO PLAY and START, and the CC BY-SA credit.
-- Clicking a folder chooses it; START hands it back to the deployment orders
-- (Bruno: the orders sheet still starts the match). On a phone it fills the
-- screen: the tabs scroll sideways under the header, four folders a row
-- (their insides scaled to the card), the buttons along the foot.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local MapCatalog = require(ReplicatedStorage:WaitForChild("Shared").MapCatalog)

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local ReliefMaps = require(script.Parent.Parent.ReliefMaps)
local Theme = require(script.Parent.Parent.Theme)

local C = Theme.color

local MapPicker = {}

local WINDOW_H = 960
-- The reference's tab edges, in order (MapCatalog.TABS); extra tabs share
-- what's left.
local TAB_X = { 40, 220, 365, 520, 680, 858, 1083, 1252, 1410 }

-- A map as a relief map (ReliefMaps, scripts/art/relief_maps.py).
function MapPicker.relief(folder: string, props: { [string]: any }): ImageLabel
	local cell = ReliefMaps.cells[folder]
	local image = Kit.new("ImageLabel", { BackgroundTransparency = 1, ScaleType = Enum.ScaleType.Crop })
	if cell then
		image.Image = ReliefMaps.PAGES[cell[1]] or ""
		image.ImageRectOffset = Vector2.new(cell[2] * ReliefMaps.cellW, cell[3] * ReliefMaps.cellH)
		image.ImageRectSize = Vector2.new(ReliefMaps.cellW, ReliefMaps.cellH)
	end
	for k, v in props do
		if k ~= "Parent" then
			(image :: any)[k] = v
		end
	end
	image.Parent = props.Parent
	return image
end

-- `openHelp` opens How to Play over the picker.
function MapPicker.open(host: Instance, current: string, done: (folder: string) -> (), openHelp: (() -> ())?): Kit.Modal
	local chosen = current
	local phone = Dossier.phone()
	local w = if phone then Dossier.phoneWindow(host, "CHOOSE A MAP") else Dossier.window(host, 1455, 1081, WINDOW_H, 36)
	local at, sz = w.at, w.sz
	local head = w.header

	local compass: ImageLabel? = nil
	local gridPos, gridSize, cellW
	if phone then
		gridPos, gridSize = at(12, 64), sz(w.width - 24, w.height - 64 - 102)
		cellW = (w.width - 24 - 10 - 14 - 3 * 12) / 4
	else
		-- Header.
		Dossier.headerPaper(w, 30, 52, 805, 133, 0)
		Dossier.bigCaps(w, 74, { Text = "CHOOSE A MAP", AnchorPoint = Vector2.new(0, 0.5), Position = at(98, 118), Parent = head })
		Dossier.art("stamp_secret", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1198, 125), Size = sz(360, 96), Rotation = -6, Parent = head })
		Dossier.clip(head, w, 1328, 70, 90, -6)
		Dossier.closeManila(head, at(1388, 90), sz(66, 62), w.close)

		-- The board's decoration, where a short tab leaves room for it.
		compass = Dossier.art("compass_big", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1185, 690), Size = sz(360, 360), ImageTransparency = 0.25, Parent = w.body })
		-- The dark band the tabs stand on.
		Kit.new("Frame", { BackgroundColor3 = C.boardDark, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = at(30, 258), Size = sz(1395, 6), Parent = w.body })
		gridPos, gridSize = at(30, 272), sz(1400, 590)
		cellW = 330
	end
	-- A folder's insides are laid out for a 330-wide card; `f` scales them.
	local f = cellW / 330
	local function cat(x: number, y: number): UDim2
		return at(x * f, y * f)
	end
	local function csz(x: number, y: number): UDim2
		return sz(x * f, y * f)
	end

	-- The grid.
	local grid = Kit.scroll({ Name = "Maps", Position = gridPos, Size = gridSize, ScrollBarThickness = math.round(10 * w.k), ScrollBarImageColor3 = Color3.fromHex("#1E2019"), Parent = w.body })
	-- Four folders a row (Bruno, 2026-10-27).
	Kit.new("UIGridLayout", { CellSize = csz(330, 273), CellPadding = if phone then sz(12, 12) else sz(13, 16), SortOrder = Enum.SortOrder.LayoutOrder, Parent = grid })
	Kit.new("UIPadding", { PaddingTop = UDim.new(0, math.round(10 * w.k)), PaddingLeft = UDim.new(0, math.round(10 * w.k)), Parent = grid })
	local outlines: { [string]: UIStroke } = {}
	local function paintChosen()
		for folder, stroke in outlines do
			stroke.Enabled = folder == chosen
		end
	end

	local tabs: { [string]: GuiObject } = {}
	local current_: string? = nil
	local function show(tabId: string)
		if current_ == tabId then
			return
		end
		local slide = current_ ~= nil
		current_ = tabId
		for id, t in tabs do
			local on = id == tabId
			t.BackgroundColor3 = if on then C.hazard else C.manila
			;(t :: any).ImageTransparency = if on then 1 else 0
		end
		for _, child in grid:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		table.clear(outlines)
		grid.CanvasPosition = Vector2.zero
		local entries = MapCatalog.inTab(tabId)
		if compass then
			compass.Visible = #entries <= 3
		end
		for i, entry in entries do
			local cell = Kit.new("TextButton", { Name = entry.folder, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, LayoutOrder = i, Parent = grid })
			local shade = Kit.new("Frame", { Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.68, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 3, 0.5, 6), Size = UDim2.new(1, -12, 1, -12), Parent = cell })
			Kit.corner(8).Parent = shade
			local face = Dossier.cardArt("ImageLabel", "tile_folder", { Name = "Face", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -8, 1, -8), Parent = cell })
			local outline = Kit.stroke(C.hazard, 6, 0)
			outline.Parent = face
			outlines[entry.folder] = outline
			Dossier.clip(face, w, 28 * f, 26 * f, 70 * f, 0)
			-- The map, printed with a white border.
			local print_ = Kit.new("Frame", { Name = "Print", BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = cat(40, 26), Size = csz(268, 148), Parent = face })
			MapPicker.relief(entry.folder, { Position = UDim2.fromOffset(math.round(6 * w.k), math.round(6 * w.k)), Size = UDim2.new(1, -math.round(12 * w.k), 1, -math.round(12 * w.k)), Parent = print_ })
			Dossier.stencil({ Text = entry.name, TextSize = math.round(Dossier.capSize(w, 23) * f), AnchorPoint = Vector2.new(0, 0.5), Position = cat(34, 196), Size = csz(240, 34), AutomaticSize = Enum.AutomaticSize.None, TextTruncate = Enum.TextTruncate.AtEnd, Parent = face })
			Dossier.typed({ Text = string.gsub(MapCatalog.sizeText(entry), "×", "x"), TextColor3 = C.inkBlack, TextSize = math.max(16, math.round(21 * w.k * f)), AnchorPoint = Vector2.new(0, 0.5), Position = cat(34, 230), Parent = face })
			Dossier.starStamp(face, w, 282 * f, 212 * f, 74 * f, 0.72)
			Dossier.liftTile(cell, face, shade, 8)
			cell.Activated:Connect(function()
				chosen = entry.folder
				paintChosen()
			end)
		end
		paintChosen()
		if slide then
			grid.Position = gridPos + UDim2.fromOffset(math.round(60 * w.k), 0)
			TweenService:Create(grid, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = gridPos }):Play()
		end
	end

	-- Folder tabs (on a phone, a row that scrolls sideways).
	local list = MapCatalog.tabs()
	local tabRow: ScrollingFrame? = nil
	if phone then
		local r = Kit.scroll({ Name = "Tabs", Position = at(12, 2), Size = sz(w.width - 24, 58), ScrollingDirection = Enum.ScrollingDirection.X, AutomaticCanvasSize = Enum.AutomaticSize.X, ScrollBarThickness = 0, Parent = w.body })
		Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = r
		tabRow = r
	end
	for i, tab in list do
		local x0 = TAB_X[i] or TAB_X[#TAB_X]
		local x1 = TAB_X[i + 1] or (x0 + 150)
		local t = Dossier.surface("ImageButton", "tex_manila", C.manila, if tabRow then { Name = tab.id, Size = sz(0, 54), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = i, Parent = tabRow } else { Name = tab.id, Position = at(x0, 200), Size = sz(x1 - x0 - 6, 62), Parent = w.body })
		Kit.corner(8).Parent = t
		Kit.stroke(C.manilaLine, 2, 0.1).Parent = t
		local label = Dossier.typed({ Text = tab.label, TextColor3 = C.inkBlack, TextSize = if phone then 24 else math.round(25 * w.k), AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, Parent = t })
		if phone then
			label.AutomaticSize = Enum.AutomaticSize.X
			label.Size = UDim2.fromScale(0, 1)
			Kit.padding(0, 18).Parent = t
		end
		t.Activated:Connect(function()
			Dossier.click()
			show(tab.id)
		end)
		tabs[tab.id] = t
	end
	show("featured")

	if phone then
		-- CANCEL, HOW TO PLAY, START along the foot, the credit above them.
		local by = w.height - 42
		Dossier.typed({ Text = "Maps from OpenFront, CC BY-SA 4.0", TextColor3 = C.sheet, TextSize = 15, AnchorPoint = Vector2.new(0, 0.5), Position = at(22, w.height - 90), Parent = w.body })
		local cancel = Dossier.rivetPlate(w.body, "CANCEL", 40, false, { Name = "Cancel", Position = at(12 + 105, by), Size = sz(210, 68), Parent = w.body })
		cancel.Activated:Connect(w.close)
		local help = Dossier.rivetPlate(w.body, "HOW TO PLAY", 40, false, { Name = "HowToPlay", Position = at(12 + 222 + 130, by), Size = sz(260, 68), Parent = w.body })
		help.Activated:Connect(function()
			if openHelp then
				openHelp()
			end
		end)
		local start = Dossier.plate(w.body, "START", { Name = "Start", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(w.width - 12 - 160, by - 4), Size = sz(320, 80), Parent = w.body }, 64)
		Dossier.clicky(start, 1.04)
		start.Activated:Connect(function()
			done(chosen)
			w.close()
		end)
		return (w :: any) :: Kit.Modal
	end

	-- CANCEL, HOW TO PLAY, START.
	local cancel = Dossier.rivetPlate(w.body, "CANCEL", Dossier.capSize(w, 26), false, { Name = "Cancel", Position = at(225, 921), Size = sz(330, 82), Parent = w.body })
	cancel.Activated:Connect(w.close)
	local help = Dossier.rivetPlate(w.body, "HOW TO PLAY", Dossier.capSize(w, 26), false, { Name = "HowToPlay", Position = at(597, 921), Size = sz(365, 82), Parent = w.body })
	help.Activated:Connect(function()
		if openHelp then
			openHelp()
		end
	end)
	local start = Dossier.plate(w.body, "", { Name = "Start", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1140, 905), Size = sz(505, 126), Parent = w.body }, 0)
	Dossier.bigCaps(w, 66, { Text = "START", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = start })
	Dossier.clicky(start, 1.04)
	Dossier.tape(start, w, "red_tape", 30, 22, 100, 28, 34)
	Dossier.tape(start, w, "red_tape", 478, 22, 100, 28, -34)
	start.Activated:Connect(function()
		done(chosen)
		w.close()
	end)

	-- The credit bar.
	local bar = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#2A2924"), BorderSizePixel = 0, Position = at(30, 996), Size = sz(1395, 36), Parent = w.body })
	Dossier.typed({ Text = "Maps from OpenFront, CC BY-SA 4.0", TextColor3 = C.sheet, TextSize = math.round(18 * w.k), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(40 * w.k), 0.5, 0), Parent = bar })
	return (w :: any) :: Kit.Modal
end

return MapPicker
