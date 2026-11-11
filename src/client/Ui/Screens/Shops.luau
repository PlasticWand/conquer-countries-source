--!strict
-- The shops as dossier windows over the menu, laid out 1:1 to Bruno's
-- references (2026-10-26, docs/design/dossier-ui/{locker,arsenal,flagshop}-
-- reference.png). Positions are in each picture's own pixels (`at`, `sz`),
-- scaled so the window is WINDOW_H canvas units tall. Drawn from the player's
-- profile view; purchases go through `ctx`:
--   Arsenal    three weapon folders: an aged picture, name, one line, two
--              bullets, then OWNED, or a star unlock bar and a Robux plate
--   Locker     the crate folder (odds by rarity, single, 3-pack, stars, the
--              first-crate discount) and the Skins / Flags tabs over a grid
--              of WEARING / EQUIP / LOCKED cards
--   Flag Shop  the limited event ("ends in") and today's flags ("new in"),
--              each a folder with an aged flag, name, rarity and price
-- Nothing is granted here: the server decides (Store) and pushes the view.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)
local FlagShop = require(Shared.Store.FlagShop)
local Profile = require(Shared.Store.Profile)

local Art = require(script.Parent.Parent.Art)
local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)

local C = Theme.color
local F = Theme.font
local A = UiAssets.dossier

local stencil = Dossier.stencil
local typed = Dossier.typed
local art = Dossier.art
local merge = Dossier.merge

local Shops = {}

export type Ctx = {
	view: any, -- Store/Profile.View
	request: (req: { [string]: any }) -> { [string]: any }?,
	prompt: (productKey: string) -> (),
	reveal: (itemId: string) -> (),
	-- A crate bought with stars gave this item: play the crate opening.
	crate: (itemId: string) -> (),
	-- Kept by the controller while the shop is open, across redraws: the
	-- Locker's tab and scroll, whether its crate has dropped in.
	memo: { [string]: any }?,
}

-- Every window is this tall on the 1920x1080 canvas.
local WINDOW_H = 1000

-- Rarity colours that read on paper.
local RARITY_INK: { [string]: Color3 } = {
	common = Color3.fromHex("#6B6B66"),
	rare = Color3.fromHex("#2C66C9"),
	epic = Color3.fromHex("#8B2FD1"),
	legendary = Color3.fromHex("#E2761B"),
}
-- The Locker's odds swatches.
local RARITY_SWATCH: { [string]: Color3 } = {
	common = Color3.fromHex("#C9C6BC"),
	rare = Color3.fromHex("#2F8BF0"),
	epic = Color3.fromHex("#A132F0"),
	legendary = Color3.fromHex("#F2B724"),
}
local GREEN = Color3.fromHex("#3F9B4F")
local GOLD_INK = Color3.fromHex("#D29A12")
local ROBUX_DARK = Color3.fromHex("#3A3A36")

local function owned(view: any): { [string]: boolean }
	local out = {}
	for _, id in view.owned or {} do
		out[id] = true
	end
	return out
end

local capSize = Dossier.capSize
local bigCaps = Dossier.bigCaps
local age = Dossier.age
local cardArt = Dossier.cardArt
local headerPaper = Dossier.headerPaper
local starStamp = Dossier.starStamp
local pin = Dossier.pin
local clip = Dossier.clip
local tape = Dossier.tape

-- The Robux mark in a small green box, as on the references' plates.
local function robuxMark(parent: Instance, size: number, order: number): Frame
	local box = Kit.new("Frame", { Name = "Robux", BackgroundColor3 = GREEN, BorderSizePixel = 0, Size = UDim2.fromOffset(size, size), LayoutOrder = order, Parent = parent })
	Kit.corner(math.max(3, math.round(size * 0.2))).Parent = box
	Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.72, 0.72), Parent = box })
	return box
end

-- A row of centred parts on a button (icon, text).
local function row(parent: Instance, gap: number): Frame
	local r = Kit.new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = parent })
	Kit.list(Enum.FillDirection.Horizontal, gap, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = r
	return r
end

-- A yellow plate with the Robux mark and a price (or a check and OWNED).
local function pricePlate(w: Dossier.Window, parent: Instance, cx: number, cy: number, ww: number, hh: number, price: number?, cap: number): ImageButton
	local p = Dossier.plate(parent, "", { AnchorPoint = Vector2.new(0.5, 0.5), Position = w.at(cx, cy), Size = w.sz(ww, hh), Parent = parent }, 0)
	local r = row(p, math.round(14 * w.k))
	if price then
		robuxMark(r, math.round(cap * 1.5 * w.k), 1)
		stencil({ Text = Kit.commas(price), TextSize = capSize(w, cap), LayoutOrder = 2, Parent = r })
	else
		-- Just the word, centred on the plate (Bruno, 2026-10-26: no check).
		r:Destroy()
		stencil({ Text = "OWNED", TextSize = capSize(w, cap), AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, Parent = p })
	end
	Dossier.clicky(p, 1.04)
	return p
end

-- Red tape over the ends of an Arsenal card's 370 x 92 plate, on the plate
-- itself so it grows and squashes with it (as PLAY's, Bruno 2026-11-02).
local function tapePlate(w: Dossier.Window, plate: ImageButton): ImageButton
	tape(plate, w, "red_tape", 10, 21, 70, 22, 58)
	tape(plate, w, "red_tape", 360, 21, 70, 22, -58)
	return plate
end

-- A manila button (secondary actions) with a centred row of parts.
local function manilaButton(w: Dossier.Window, parent: Instance, cx: number, cy: number, ww: number, hh: number): (ImageButton, Frame)
	local b = Dossier.surface("ImageButton", "tex_manila", C.manila, { AnchorPoint = Vector2.new(0.5, 0.5), Position = w.at(cx, cy), Size = w.sz(ww, hh), Parent = parent })
	Kit.corner(5).Parent = b
	Kit.stroke(C.manilaLine, 2, 0).Parent = b
	Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(225, 214, 190)), Parent = b })
	b.Activated:Connect(Dossier.click)
	Dossier.clicky(b, 1.03)
	return b, row(b, math.round(12 * w.k))
end

-- Phones ---------------------------------------------------------------------------------------
-- Each shop fills the screen on a phone (Bruno, 2026-10-27), laid out in canvas
-- units on Dossier.phoneWindow, with the same pieces as on desktop.

-- Your stars on a taped note in a phone window's header, left of `right`.
local function phoneStars(w: Dossier.Window, stars: number, right: number)
	local note = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { Name = "Stars", AnchorPoint = Vector2.new(1, 0.5), Position = w.at(right, 39), Size = w.sz(0, 56), AutomaticSize = Enum.AutomaticSize.X, Rotation = 1, Parent = w.header })
	Kit.stroke(C.sheetLine, 1, 0.2).Parent = note
	Kit.padding(0, 14).Parent = note
	local r = row(note, 8)
	r.AutomaticSize = Enum.AutomaticSize.X
	r.Size = UDim2.fromScale(0, 1)
	Kit.glyph("star", { ImageColor3 = C.inkBlack, Size = UDim2.fromOffset(28, 28), LayoutOrder = 1, Parent = r })
	stencil({ Text = Kit.commas(stars), TextSize = 40, LayoutOrder = 2, Parent = r })
end

-- The Arsenal: the three weapon folders side by side.
local function arsenalPhone(host: Instance, ctx: Ctx): Kit.Modal
	local view = ctx.view
	local mine = owned(view)
	local w = Dossier.phoneWindow(host, "ARSENAL")
	local at, sz = w.at, w.sz
	phoneStars(w, view.stars or 0, w.width - 84)
	-- Rows of three; more rows scroll down (Bruno, 2026-11-08).
	local n = #Catalog.ARSENAL
	local shown = math.min(n, 3)
	local cardW = (w.width - 32 - (shown - 1) * 14) / shown
	local cardH = w.height - 22
	local rows = math.ceil(n / 3)
	local shelf = Kit.scroll({ Name = "Folders", Size = UDim2.fromScale(1, 1), ScrollingDirection = Enum.ScrollingDirection.Y, AutomaticCanvasSize = Enum.AutomaticSize.None, CanvasSize = UDim2.fromOffset(0, math.round(4 + rows * cardH + (rows - 1) * 14)), ScrollBarThickness = 6, ScrollBarImageColor3 = Color3.fromHex("#1E2019"), Parent = w.body })
	for i, wpn in Catalog.ARSENAL do
		local col, line = (i - 1) % 3, (i - 1) // 3
		local card = cardArt("ImageLabel", "folder_portrait", { Name = wpn.id, Position = at(16 + col * (cardW + 14), 2 + line * (cardH + 14)), Size = sz(cardW, cardH), Parent = shelf })
		-- The photo in a paper border.
		local photoH = math.min(150, cardW * 0.48)
		local frame = Kit.new("Frame", { Name = "Print", BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = at(14, 30), Size = sz(cardW - 28, photoH), Rotation = if col == 1 then 0.6 else -0.4, Parent = card })
		local pic = Art.card(wpn.id, { Position = UDim2.fromOffset(5, 5), Size = UDim2.new(1, -10, 1, -10), Parent = frame })
		age(pic)
		local y = 30 + photoH + 14
		stencil({ Text = string.upper(wpn.name), TextSize = 42, Position = at(18, y), Parent = card })
		Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = at(18, y + 50), Size = sz(cardW - 36, 2), Parent = card })
		typed({ Text = wpn.desc, TextColor3 = C.inkBlack, TextSize = 20, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, TextYAlignment = Enum.TextYAlignment.Top, Position = at(18, y + 58), Size = sz(cardW - 36, 48), Parent = card })
		for j, bullet in wpn.bullets do
			local by = y + 118 + (j - 1) * 26
			local dot = Kit.new("Frame", { BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(24, by), Size = sz(9, 9), Parent = card })
			Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
			stencil({ Text = string.upper(bullet), TextSize = 22, TextColor3 = C.stamp, AnchorPoint = Vector2.new(0, 0.5), Position = at(38, by), Parent = card })
		end

		-- The buy plate at the foot of the folder, the star unlock above it.
		local cx, plateY = cardW / 2, cardH - 50
		local has = mine[wpn.id] or (wpn.pass ~= nil and view.doubleStars) or (wpn.subscription == true and view.general == true)
		if has then
			pricePlate(w, card, cx, plateY, cardW - 40, 70, nil, 26)
		else
			if wpn.stars then
				local stars = view.stars or 0
				local affordable = stars >= wpn.stars
				local bar, br = manilaButton(w, card, cx, plateY - 66, cardW - 40, 54)
				local fill = Kit.new("Frame", { Name = "Fill", BackgroundColor3 = if affordable then C.hazard else Color3.fromHex("#C9B27A"), BorderSizePixel = 0, Size = UDim2.fromScale(math.clamp(stars / wpn.stars, 0, 1), 1), ZIndex = bar.ZIndex, Parent = bar })
				Kit.corner(5).Parent = fill
				br.ZIndex = bar.ZIndex + 1
				Kit.glyph("star", { ImageColor3 = C.inkBlack, Size = UDim2.fromOffset(28, 28), LayoutOrder = 1, ZIndex = br.ZIndex, Parent = br })
				stencil({ Text = if affordable then `UNLOCK · {Kit.commas(wpn.stars)}` else Kit.commas(wpn.stars), TextSize = 40, LayoutOrder = 2, ZIndex = br.ZIndex, Parent = br })
				bar.Activated:Connect(function()
					if affordable then
						local r = ctx.request({ op = "unlock", id = wpn.id })
						if r and r.ok then
							ctx.reveal(wpn.id)
						end
					end
				end)
			end
			local key = wpn.product or wpn.pass
			-- (Conquest General: Roblox's subscription prompt, its monthly price.)
			local product: { key: string, price: number }? = if wpn.subscription then { key = "general", price = Catalog.SUBSCRIPTION.robux } elseif key then Catalog.product(key) else nil
			if product then
				local buy = pricePlate(w, card, cx, plateY, cardW - 40, 70, product.price, 26)
				buy.Activated:Connect(function()
					ctx.prompt(product.key)
				end)
			end
		end
	end
	return (w :: any) :: Kit.Modal
end

-- Arsenal --------------------------------------------------------------------------------

-- Reference: arsenal-reference.png, 1409 x 1116.
function Shops.arsenal(host: Instance, ctx: Ctx): Kit.Modal
	if Dossier.phone() then
		return arsenalPhone(host, ctx)
	end
	local view = ctx.view
	local mine = owned(view)
	local w = Dossier.window(host, 1409, 1116, WINDOW_H, 36)
	local at, sz = w.at, w.sz
	local head = w.header

	-- Header: the shield, ARSENAL, the line under it, a faded star.
	headerPaper(w, 35, 40, 987, 152, 0)
	clip(head, w, 38, 190, 92, -24)
	local shield = Dossier.surface("ImageLabel", "", C.hazard, { Position = at(48, 55), Size = sz(94, 94), Parent = head })
	Kit.corner(6).Parent = shield
	Kit.stroke(Color3.fromHex("#A87C12"), 2, 0).Parent = shield
	Dossier.icon("icon_shield", "shield", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.68, 0.68), Parent = shield })
	bigCaps(w, 86, { Text = "ARSENAL", AnchorPoint = Vector2.new(0, 0.5), Position = at(166, 116), Parent = head })
	typed({
		Text = "Unlock new weapons with stars. Every match earns stars; public matches earn the most.",
		TextColor3 = C.inkBlack,
		TextSize = math.round(19 * w.k),
		TextWrapped = true,
		AutomaticSize = Enum.AutomaticSize.None,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = at(626, 96),
		Size = sz(310, 84),
		Parent = head,
	})
	starStamp(head, w, 975, 95, 92, 0.75)

	-- Your stars on a taped note, and the close button.
	local noteProps = { Position = at(1030, 50), Size = sz(252, 135), Rotation = 2, Parent = head }
	Dossier.shadow(head, noteProps, 1)
	local note = Dossier.surface("ImageLabel", "tex_paper", C.sheet, noteProps)
	Kit.stroke(C.sheetLine, 1, 0.2).Parent = note
	local count = Dossier.plate(note, "", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(130, 57), Size = sz(206, 70), Active = false, Parent = note }, 0)
	local cr = row(count, math.round(10 * w.k))
	Kit.glyph("star", { ImageColor3 = C.inkBlack, Size = UDim2.fromOffset(math.round(40 * w.k), math.round(40 * w.k)), LayoutOrder = 1, Parent = cr })
	stencil({ Text = Kit.commas(view.stars or 0), TextSize = capSize(w, 30), LayoutOrder = 2, Parent = cr })
	tape(note, w, "tape", 140, 128, 110, 30, 2)
	pin(head, w, 1242, 50)
	Dossier.closeManila(head, at(1335, 98), sz(90, 86), w.close)

	-- The folders in rows of three; more rows scroll down (Bruno, 2026-11-08:
	-- the Arsenal grows past three, and scrolls vertically).
	local n = #Catalog.ARSENAL
	local rows = math.ceil(n / 3)
	local shelf = Kit.scroll({ Name = "Folders", Position = at(0, 200), Size = sz(1409, 770), ScrollingDirection = Enum.ScrollingDirection.Y, AutomaticCanvasSize = Enum.AutomaticSize.None, CanvasSize = UDim2.fromOffset(0, math.round((20 + rows * 750) * w.k)), ScrollBarThickness = 8, ScrollBarImageColor3 = Color3.fromHex("#1E2019"), Parent = w.body })
	for i, wpn in Catalog.ARSENAL do
		local col, line = (i - 1) % 3, (i - 1) // 3
		local x0 = 40 + col * 445
		local card = cardArt("ImageLabel", "folder_portrait", { Name = wpn.id, Position = at(x0, 15 + line * 750), Size = sz(430, 735), Parent = shelf })
		local function rel(x: number, y: number): UDim2
			return at(x, y)
		end
		-- The aged picture in a paper border.
		local frame = Kit.new("Frame", { Name = "Print", BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = rel(20, 46), Size = sz(386, 270), Rotation = if col == 1 then 0.6 else -0.4, Parent = card })
		local pic = Art.card(wpn.id, { Position = UDim2.fromOffset(math.round(6 * w.k), math.round(6 * w.k)), Size = UDim2.new(1, -math.round(12 * w.k), 1, -math.round(12 * w.k)), Parent = frame })
		age(pic)
		if col == 1 then
			clip(card, w, 368, 10, 82, 6)
		end
		stencil({ Text = string.upper(wpn.name), TextSize = capSize(w, 33), AnchorPoint = Vector2.new(0, 0.5), Position = rel(28, 362), Parent = card })
		Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = rel(28, 390), Size = UDim2.fromOffset(math.round(370 * w.k), 2), Parent = card })
		typed({ Text = wpn.desc, TextColor3 = C.inkBlack, TextSize = math.round(24 * w.k), TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, TextYAlignment = Enum.TextYAlignment.Top, Position = rel(28, 405), Size = sz(370, 56), Parent = card })
		for j, bullet in wpn.bullets do
			local y = 478 + (j - 1) * 33
			local dot = Kit.new("Frame", { BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = rel(36, y), Size = sz(10, 10), Parent = card })
			Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
			stencil({ Text = string.upper(bullet), TextSize = capSize(w, 15), TextColor3 = C.stamp, AnchorPoint = Vector2.new(0, 0.5), Position = rel(58, y), Parent = card })
		end
		starStamp(card, w, 340, 560, 104, 0.78)

		local has = mine[wpn.id] or (wpn.pass ~= nil and view.doubleStars) or (wpn.subscription == true and view.general == true)
		if has then
			tapePlate(w, pricePlate(w, card, 215, 665, 370, 92, nil, 34))
		else
			if wpn.stars then
				-- The star unlock: a bar filling towards the price.
				local stars = view.stars or 0
				local affordable = stars >= wpn.stars
				local bar, br = manilaButton(w, card, 215, 590, 370, 54)
				local fill = Kit.new("Frame", { Name = "Fill", BackgroundColor3 = if affordable then C.hazard else Color3.fromHex("#C9B27A"), BorderSizePixel = 0, Size = UDim2.fromScale(math.clamp(stars / wpn.stars, 0, 1), 1), ZIndex = bar.ZIndex, Parent = bar })
				Kit.corner(5).Parent = fill
				br.ZIndex = bar.ZIndex + 1
				Kit.glyph("star", { ImageColor3 = C.inkBlack, Size = UDim2.fromOffset(math.round(30 * w.k), math.round(30 * w.k)), LayoutOrder = 1, ZIndex = br.ZIndex, Parent = br })
				stencil({ Text = if affordable then `UNLOCK · {Kit.commas(wpn.stars)}` else Kit.commas(wpn.stars), TextSize = capSize(w, 22), LayoutOrder = 2, ZIndex = br.ZIndex, Parent = br })
				bar.Activated:Connect(function()
					if affordable then
						local r = ctx.request({ op = "unlock", id = wpn.id })
						if r and r.ok then
							ctx.reveal(wpn.id)
						end
					end
				end)
				Kit.tip(bar, function(tip)
					Kit.text({ Text = if affordable then "Unlock with stars" else `{Kit.commas(wpn.stars - stars)} more stars`, FontFace = F.uiBold, Parent = tip })
				end)
			end
			local key = wpn.product or wpn.pass
			-- (Conquest General: Roblox's subscription prompt, its monthly price.)
			local product: { key: string, price: number }? = if wpn.subscription then { key = "general", price = Catalog.SUBSCRIPTION.robux } elseif key then Catalog.product(key) else nil
			if product then
				local buy = tapePlate(w, pricePlate(w, card, 215, 665, 370, 92, product.price, 34))
				buy.Activated:Connect(function()
					ctx.prompt(product.key)
				end)
			end
		end
	end

	-- The board's stamps and tape.
	art("stamp_secret", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1165, 1012), Size = sz(420, 100), Rotation = -12, ImageTransparency = 0.3, Parent = w.body })
	tape(w.body, w, "tape", 150, 975, 130, 36, -3)
	return (w :: any) :: Kit.Modal
end

-- Locker and crates --------------------------------------------------------------------------

local DROP = TweenInfo.new(0.75, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
-- Bounce Out first touches down about 36% of the way in.
local LANDS_AT = 0.27
local GLINT = TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, false, 2.6)

-- The supply crate (Bruno, 2026-10-27): a wooden crate that drops in, lands
-- with a bounce, a thud and a puff of dust, then rests with a slow glint
-- across it, with no shadow (Bruno). It drops once per open; a redraw shows
-- it resting. `size` is in reference pixels; the art's base sits a third of
-- it below the centre.
local function supplyCrate(w: Dossier.Window, parent: Instance, centre: UDim2, size: number, memo: { [string]: any })
	local pic: GuiObject? = art("crate_wood", { Name = "SupplyCrate", AnchorPoint = Vector2.new(0.5, 0.5), Position = centre, Size = w.sz(size, size), Parent = parent })
	if pic == nil then
		-- Before the art is uploaded: the chest glyph on a dark disc.
		local disc = Kit.new("Frame", { Name = "SupplyCrate", BackgroundColor3 = Color3.fromHex("#2E2A22"), BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = centre, Size = w.sz(size * 0.84, size * 0.84), Parent = parent })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = disc })
		Kit.stroke(Color3.fromHex("#8C7A58"), 3, 0.3).Parent = disc
		Kit.glyph("chest", { ImageColor3 = C.hazard, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6), Parent = disc })
		pic = disc
	end
	local crate = pic :: GuiObject
	local tweens: { Tween } = {}
	local function run(target: Instance, info: TweenInfo, goal: { [string]: any })
		local t = TweenService:Create(target, info, goal)
		table.insert(tweens, t)
		t:Play()
	end
	-- The glint: a white copy of the crate's shape with a bright band
	-- sweeping across it.
	local glint = art("crate_glint", { Name = "Glint", Size = UDim2.fromScale(1, 1), ImageTransparency = 0.45, Parent = crate })
	if glint then
		local band = Kit.new("UIGradient", {
			Rotation = 20,
			Offset = Vector2.new(-1, 0),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.4, 1),
				NumberSequenceKeypoint.new(0.5, 0),
				NumberSequenceKeypoint.new(0.6, 1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = glint,
		})
		run(band, GLINT, { Offset = Vector2.new(1, 0) })
	end
	crate.Destroying:Connect(function()
		for _, t in tweens do
			t:Cancel()
		end
	end)
	if memo.crateDropped then
		return
	end
	memo.crateDropped = true
	crate.Position = centre - w.at(0, 300)
	crate.Rotation = -8
	run(crate, DROP, { Position = centre })
	run(crate, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Rotation = 0 })
	task.delay(LANDS_AT, function()
		if crate.Parent == nil then
			return
		end
		Dossier.thud()
		local dust = art("dust_puff", { Name = "Dust", AnchorPoint = Vector2.new(0.5, 1), Position = centre + w.at(0, size * 0.38), Size = w.sz(size * 0.7, size * 0.3), ImageTransparency = 0.05, Parent = parent })
		if dust then
			local puff = TweenService:Create(dust, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = w.sz(size * 1.6, size * 0.55), ImageTransparency = 1 })
			puff.Completed:Connect(function()
				dust:Destroy()
			end)
			puff:Play()
		end
	end)
end

-- The crate folder's width on a phone.
local PHONE_CRATE_W = 300

-- The Locker's crate folder on a phone, at the left of the body: the crate,
-- the odds, the first-crate price, the plates. The count sits in the header.
local function lockerCratePhone(w: Dossier.Window, ctx: Ctx, memo: { [string]: any }, have: number, total: number)
	local view = ctx.view
	local at, sz = w.at, w.sz
	-- The count, left of the tabs, where the screen leaves it room after the
	-- title (about 210 wide).
	local noteRight = w.width - 84 - 316
	if noteRight - 250 > Kit.root.topLeft + 220 then
		local note = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { Name = "Count", AnchorPoint = Vector2.new(1, 0.5), Position = at(noteRight, 39), Size = sz(0, 50), AutomaticSize = Enum.AutomaticSize.X, Rotation = -1, Parent = w.header })
		Kit.stroke(C.sheetLine, 1, 0.2).Parent = note
		Kit.padding(0, 12).Parent = note
		stencil({ Text = `{have} OF {total} UNLOCKED`, TextSize = 36, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Parent = note })
		Kit.new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Parent = note })
	end

	local cw = PHONE_CRATE_W
	local crate = cardArt("ImageLabel", "folder_portrait", { Name = "Crate", Position = at(14, 0), Size = sz(cw, w.height - 6), Parent = w.body })
	supplyCrate(w, crate, at(cw / 2, 64), 130, memo)
	stencil({ Text = "COSMETIC CRATE", TextSize = 44, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(cw / 2, 136), Parent = crate })
	for i, o in Profile.CRATE_ODDS do
		local y = 168 + (i - 1) * 24
		local sw = Kit.new("Frame", { BackgroundColor3 = RARITY_SWATCH[o.rarity], BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(34, y), Size = sz(16, 16), Parent = crate })
		Kit.corner(3).Parent = sw
		Kit.stroke(C.inkBlack, 1, 0.5).Parent = sw
		stencil({ Text = Catalog.RARITY_NAME[o.rarity], FontFace = F.typewriter, TextSize = 20, AnchorPoint = Vector2.new(0, 0.5), Position = at(52, y), Parent = crate })
		stencil({ Text = `{o.percent}%`, FontFace = F.typewriter, TextSize = 20, AnchorPoint = Vector2.new(1, 0.5), Position = at(cw - 26, y), Parent = crate })
	end
	if view.crateKey == "crateFirst" then
		local regular = Catalog.product("crate1") :: Catalog.Product
		typed({ Text = `First crate: {view.cratePrice} instead of {regular.price}`, TextColor3 = C.inkBlack, TextSize = 17, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(cw / 2, 266), Parent = crate })
	end
	local single = pricePlate(w, crate, cw / 2, 306, cw - 36, 54, view.cratePrice or 49, 24)
	single.Activated:Connect(function()
		ctx.prompt(view.crateKey or "crate1")
	end)
	local three = Catalog.product("crate3") :: Catalog.Product
	local pack, pr = manilaButton(w, crate, cw / 2, 362, cw - 36, 46)
	Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, ImageColor3 = ROBUX_DARK, Size = UDim2.fromOffset(28, 28), LayoutOrder = 1, Parent = pr })
	stencil({ Text = `{three.price}  ·  3 CRATES`, TextSize = 36, LayoutOrder = 2, Parent = pr })
	pack.Activated:Connect(function()
		ctx.prompt("crate3")
	end)
	local canStars = (view.stars or 0) >= Profile.CRATE_STARS
	local starsBtn, sr = manilaButton(w, crate, cw / 2, 416, cw - 36, 46)
	Kit.glyph("star", { ImageColor3 = C.inkBlack, Size = UDim2.fromOffset(28, 28), LayoutOrder = 1, Parent = sr })
	stencil({ Text = if canStars then `OR {Kit.commas(Profile.CRATE_STARS)}` else `{Kit.commas(Profile.CRATE_STARS)} STARS`, TextSize = 36, TextTransparency = if canStars then 0 else 0.45, LayoutOrder = 2, Parent = sr })
	starsBtn.Activated:Connect(function()
		if canStars then
			local r = ctx.request({ op = "crate" })
			if r and r.ok and r.item then
				ctx.crate(r.item)
			end
		end
	end)
end

-- Reference: locker-reference.png, 1496 x 1051.
function Shops.locker(host: Instance, ctx: Ctx): Kit.Modal
	local view = ctx.view
	local memo: { [string]: any } = ctx.memo or {}
	memo.scroll = memo.scroll or {}
	local mine = owned(view)
	local total, have = 0, 0
	for _, c in Catalog.cosmetics() do
		if Catalog.crateable(c) or mine[c.id] or c.set ~= "country" then
			total += 1
			if mine[c.id] then
				have += 1
			end
		end
	end
	-- On a phone (Bruno, 2026-10-27): full screen, the crate folder at the left,
	-- the tabs in the header and the grid filling the rest.
	local phone = Dossier.phone()
	local w = if phone then Dossier.phoneWindow(host, "LOCKER") else Dossier.window(host, 1496, 1051, WINDOW_H, 36)
	local at, sz = w.at, w.sz
	local head = w.header

	if phone then
		lockerCratePhone(w, ctx, memo, have, total)
	else
		-- Header: LOCKER on torn paper, the count, a faded star, TOP SECRET, close.
		headerPaper(w, 15, 40, 650, 178, -1)
		clip(head, w, 52, 95, 88, -4)
		bigCaps(w, 88, { Text = "LOCKER", AnchorPoint = Vector2.new(0, 0.5), Position = at(92, 108), Rotation = -1, Parent = head })
		stencil({ Text = `{have} OF {total} UNLOCKED`, TextSize = capSize(w, 25), AnchorPoint = Vector2.new(0, 0.5), Position = at(97, 180), Rotation = -1, Parent = head })
		starStamp(head, w, 555, 128, 112, 0.72)
		art("stamp_secret", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1135, 125), Size = sz(440, 110), Rotation = -8, Parent = head })
		Dossier.closeRed(head, at(1417, 80), sz(88, 88), w.close)

		-- The crate folder.
		local crate = cardArt("ImageLabel", "folder_portrait", { Name = "Crate", Position = at(30, 212), Size = sz(462, 816), Parent = w.body })
		local function c(x: number, y: number): UDim2
			return at(x - 30, y - 212)
		end
		starStamp(crate, w, 388 - 30, 408 - 212, 92, 0.72)
		supplyCrate(w, crate, c(255, 368), 262, memo)
		stencil({ Text = "COSMETIC CRATE", TextSize = capSize(w, 30), AnchorPoint = Vector2.new(0.5, 0.5), Position = c(258, 482), Parent = crate })
		typed({
			Text = "A territory skin or a country flag you don't own yet",
			TextColor3 = C.inkBlack,
			TextSize = math.round(24 * w.k),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Center,
			AutomaticSize = Enum.AutomaticSize.None,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = c(258, 508),
			Size = sz(380, 54),
			Parent = crate,
		})
		for i, o in Profile.CRATE_ODDS do
			local y = 585 + (i - 1) * 37
			local sw = Kit.new("Frame", { BackgroundColor3 = RARITY_SWATCH[o.rarity], BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = c(89, y), Size = sz(22, 22), Parent = crate })
			Kit.corner(3).Parent = sw
			Kit.stroke(C.inkBlack, 1, 0.5).Parent = sw
			stencil({ Text = Catalog.RARITY_NAME[o.rarity], FontFace = F.typewriter, TextSize = math.round(26 * w.k), AnchorPoint = Vector2.new(0, 0.5), Position = c(115, y), Parent = crate })
			stencil({ Text = `{o.percent}%`, FontFace = F.typewriter, TextSize = math.round(26 * w.k), AnchorPoint = Vector2.new(1, 0.5), Position = c(447, y), Parent = crate })
		end
		local single = pricePlate(w, crate, 261 - 30, 767 - 212, 393, 75, view.cratePrice or 49, 30)
		single.Activated:Connect(function()
			ctx.prompt(view.crateKey or "crate1")
		end)
		local three = Catalog.product("crate3") :: Catalog.Product
		local pack, pr = manilaButton(w, crate, 261 - 30, 848 - 212, 393, 60)
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, ImageColor3 = ROBUX_DARK, Size = UDim2.fromOffset(math.round(34 * w.k), math.round(34 * w.k)), LayoutOrder = 1, Parent = pr })
		stencil({ Text = `{three.price}  ·  3 CRATES`, TextSize = capSize(w, 22), LayoutOrder = 2, Parent = pr })
		pack.Activated:Connect(function()
			ctx.prompt("crate3")
		end)
		local canStars = (view.stars or 0) >= Profile.CRATE_STARS
		local starsBtn, sr = manilaButton(w, crate, 261 - 30, 916 - 212, 393, 58)
		Kit.glyph("star", { ImageColor3 = C.inkBlack, Size = UDim2.fromOffset(math.round(34 * w.k), math.round(34 * w.k)), LayoutOrder = 1, Parent = sr })
		stencil({ Text = `OR {Kit.commas(Profile.CRATE_STARS)}`, TextSize = capSize(w, 22), TextTransparency = if canStars then 0 else 0.45, LayoutOrder = 2, Parent = sr })
		starsBtn.Activated:Connect(function()
			if canStars then
				local r = ctx.request({ op = "crate" })
				if r and r.ok and r.item then
					ctx.crate(r.item)
				end
			end
		end)
		Kit.tip(starsBtn, function(tip)
			Kit.text({ Text = if canStars then "Open a crate with stars" else `{Kit.commas(Profile.CRATE_STARS - (view.stars or 0))} more stars`, FontFace = F.uiBold, Parent = tip })
		end)
		if view.crateKey == "crateFirst" then
			local regular = Catalog.product("crate1") :: Catalog.Product
			typed({ Text = `Your first crate: {view.cratePrice} instead of {regular.price}`, TextColor3 = C.inkBlack, TextSize = math.round(21 * w.k), AnchorPoint = Vector2.new(0.5, 0.5), Position = c(232, 970), Parent = crate })
		end
	end

	-- Skins / Flags tabs and the grid.
	local tabs: { [string]: ImageButton } = {}
	local labels: { [string]: TextLabel } = {}
	local function tabButton(id: string, text: string, x: number): ImageButton
		local b = Kit.new("ImageButton", { Name = text, AutoButtonColor = false, BackgroundColor3 = C.manila, BorderSizePixel = 0, Image = "", ScaleType = Enum.ScaleType.Stretch, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(x, if phone then 39 else 230), Size = sz(if phone then 140 else 150, if phone then 58 else 62), Parent = head })
		Kit.corner(6).Parent = b
		Kit.stroke(C.manilaLine, 2, 0).Parent = b
		labels[id] = stencil({ Text = text, TextSize = capSize(w, if phone then 20 else 24), AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, Parent = b })
		Dossier.clicky(b, 1.04)
		b.Activated:Connect(Dossier.click)
		tabs[id] = b
		return b
	end
	local area, cellW, cellH, gap
	if phone then
		tabButton("skin", "SKINS", w.width - 84 - 228)
		tabButton("flag", "FLAGS", w.width - 84 - 80)
		-- As many columns as fit, cards about 160 wide.
		local areaW = w.width - PHONE_CRATE_W - 34
		area = Kit.new("Frame", { Name = "GridArea", BackgroundTransparency = 1, ClipsDescendants = true, Position = at(PHONE_CRATE_W + 24, 0), Size = sz(areaW, w.height - 4), Parent = w.body })
		gap = 12
		local cols = math.max(3, math.floor((areaW - 20) / (160 + gap)))
		cellW = math.floor((areaW - 20 - (cols - 1) * gap) / cols)
		cellH = math.floor(cellW * 1.04)
	else
		tabButton("skin", "SKINS", 580)
		tabButton("flag", "FLAGS", 742)
		clip(head, w, 652, 222, 72, 8)
		area = Kit.new("Frame", { Name = "GridArea", BackgroundTransparency = 1, ClipsDescendants = true, Position = at(498, 278), Size = sz(962, 742), Parent = w.body })
		cellW, cellH = math.round(213 * w.k), math.round(220 * w.k)
		gap = math.round(14 * w.k)
	end
	local grid: ScrollingFrame? = nil

	local function tile(parent: Instance, order: number, name: string, status: string, statusColor: Color3, worn: boolean, picture: (face: GuiObject) -> (), onClick: (() -> ())?, tipFill: ((card: Frame) -> ())?)
		local cell = Kit.new("TextButton", { Name = name, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, LayoutOrder = order, Parent = parent })
		local shade = Kit.new("Frame", { Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.68, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 3, 0.5, 5), Size = UDim2.new(1, -8, 1, -8), Parent = cell })
		Kit.corner(8).Parent = shade
		local face = cardArt("ImageLabel", "tile_card", { Name = "Face", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -6, 1, -6), Parent = cell })
		if worn then
			Kit.stroke(C.hazard, 4, 0).Parent = face
		end
		picture(face)
		Dossier.typed({ Text = name, TextColor3 = C.inkBlack, TextSize = if phone then 20 else math.round(25 * w.k), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, math.round(cellH * 162 / 220)), Size = UDim2.new(1, -12, 0, math.round(cellH * 30 / 220)), AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Parent = face })
		stencil({ Text = status, TextSize = if phone then 30 else capSize(w, 17), TextColor3 = statusColor, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, math.round(cellH * 192 / 220)), Parent = face })
		Dossier.liftTile(cell, face, shade, 8)
		if onClick then
			cell.Activated:Connect(onClick)
		end
		if tipFill then
			Kit.tip(cell, tipFill)
		end
	end

	local current: string? = nil
	local function show(kind: string)
		if current == kind then
			return
		end
		local slide = current ~= nil
		current = kind
		memo.tab = kind
		for id, b in tabs do
			local on = id == kind
			b.BackgroundColor3 = if on then C.hazard else C.manila
			b.Image = if on then A.plate_play else ""
			b.BackgroundTransparency = if on and A.plate_play ~= "" then 1 else 0
			labels[id].TextColor3 = C.inkBlack
		end
		if grid then
			grid:Destroy()
		end
		local g = Kit.scroll({ Name = "Grid", Size = UDim2.fromScale(1, 1), ScrollBarThickness = math.round(11 * w.k), ScrollBarImageColor3 = Color3.fromHex("#1E2019"), Parent = area })
		grid = g
		Kit.new("UIGridLayout", { CellSize = UDim2.fromOffset(cellW, cellH), CellPadding = UDim2.fromOffset(gap, gap), SortOrder = Enum.SortOrder.LayoutOrder, Parent = g })
		Kit.new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingLeft = UDim.new(0, 8), Parent = g })
		local list = {}
		for _, item in Catalog.cosmetics() do
			-- (A General skin shows from its month on: they're lined up a year ahead.)
			local early = item.set == "general" and not mine[item.id] and not Catalog.generalReleased(item.id, os.time())
			if item.kind == kind and not early and (Catalog.crateable(item) or mine[item.id] or item.set ~= "country") then
				table.insert(list, item)
			end
		end
		-- Owned first, then by rarity and name.
		local order = { legendary = 1, epic = 2, rare = 3, common = 4 }
		table.sort(list, function(a, b)
			local ma, mb = mine[a.id] and 0 or 1, mine[b.id] and 0 or 1
			if ma ~= mb then
				return ma < mb
			end
			if order[a.rarity] ~= order[b.rarity] then
				return order[a.rarity] < order[b.rarity]
			end
			return a.name < b.name
		end)
		local wearing = view.equipped and view.equipped[kind]
		local edge = math.round(cellW * 16 / 213)
		local picBox = { Position = UDim2.fromOffset(edge, edge), Size = UDim2.new(1, -2 * edge, 0, math.round(cellH * 122 / 220)) }
		tile(g, 0, "None", if wearing == nil then "WEARING" else "TAKE OFF", if wearing == nil then GOLD_INK else C.inkFaded, wearing == nil, function(face)
			local blank = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#3C3D2C"), BorderSizePixel = 0, Position = picBox.Position, Size = picBox.Size, Parent = face })
			art("star_stamp", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.9), ImageTransparency = 0.55, Parent = blank })
		end, if wearing ~= nil
			then function()
				ctx.request({ op = "equip", kind = kind, id = nil })
			end
			else nil)
		for i, item in list do
			local has = mine[item.id]
			local worn = wearing == item.id
			local status = if worn then "WEARING" elseif has then "EQUIP" else "LOCKED"
			local color = if worn then GOLD_INK elseif has then Color3.fromHex("#2E8A3E") else C.stamp
			tile(g, i, item.name, status, color, worn, function(face)
				local pic = if kind == "skin" then Art.skin(item.id, merge({ Parent = face }, picBox)) else Art.flag(item.id, merge({ Parent = face }, picBox))
				if not has then
					pic.ImageTransparency = 0.25
				end
				age(pic)
			end, if has and not worn
				then function()
					ctx.request({ op = "equip", kind = kind, id = item.id })
				end
				else nil, function(card)
				Kit.text({ Text = item.name, FontFace = F.uiHeavy, TextSize = 18, Parent = card })
				Kit.text({ Text = Catalog.RARITY_NAME[item.rarity], FontFace = F.uiBold, TextSize = 15, TextColor3 = RARITY_SWATCH[item.rarity], Parent = card })
				Kit.text({ Text = if has then "Click to wear it" elseif item.set == "country" or kind == "skin" then "From crates" else "From the Flag Shop", TextSize = 15, TextColor3 = C.fgSoft, Parent = card })
			end)
		end
		-- A redraw (say, after equipping) keeps the page where it was.
		local saved = memo.scroll[kind]
		if saved then
			g.CanvasPosition = saved
			g:GetPropertyChangedSignal("AbsoluteCanvasSize"):Once(function()
				g.CanvasPosition = saved
			end)
		end
		g:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			memo.scroll[kind] = g.CanvasPosition
		end)
		-- A tab switch swaps the page in from the side.
		if slide then
			g.Position = UDim2.fromOffset(math.round(60 * w.k), 0)
			TweenService:Create(g, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(0, 0) }):Play()
		end
	end
	tabs.skin.Activated:Connect(function()
		show("skin")
	end)
	tabs.flag.Activated:Connect(function()
		show("flag")
	end)
	show(memo.tab or "skin")

	if not phone then
		starStamp(w.body, w, 1420, 985, 110, 0.75)
		typed({ Text = "Flags from OpenFront (CC BY-SA 4.0) and our own", TextColor3 = C.sheet, TextSize = math.round(17 * w.k), AnchorPoint = Vector2.new(1, 0.5), Position = at(1470, 1036), Parent = w.body })
	end
	return (w :: any) :: Kit.Modal
end

-- Flag Shop ------------------------------------------------------------------------------------

-- The Flag Shop on a phone: the event's flags, then today's, as rows of
-- folders scrolling under the header.
local function flagShopPhone(host: Instance, ctx: Ctx): Kit.Modal
	local view = ctx.view
	local mine = owned(view)
	local offers = FlagShop.offers(os.time())
	local w = Dossier.phoneWindow(host, "FLAG SHOP")
	local at, sz = w.at, w.sz
	local timers: { { label: TextLabel, at: number, prefix: string } } = {}

	local area = Kit.scroll({ Name = "Flags", Position = at(12, 0), Size = sz(w.width - 24, w.height - 6), ScrollBarThickness = 8, ScrollBarImageColor3 = Color3.fromHex("#1E2019"), AutomaticCanvasSize = Enum.AutomaticSize.None, Parent = w.body })
	local areaW = w.width - 24 - 14
	local gap = 12
	local cols = math.max(3, math.floor((areaW + gap) / (200 + gap)))
	local tileW = (areaW - (cols - 1) * gap) / cols
	local picH = math.round((tileW - 28) * 0.62)
	local tileH = 14 + picH + 122

	-- A strip naming a row, with its countdown on a note at the right.
	local y = 4
	local function strip(text: string, at_: number, prefix: string)
		local band = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Position = at(0, y), Size = sz(areaW, 54), Parent = area })
		stencil({ Text = text, TextSize = 48, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 18, 0.5, 1), Parent = band })
		local t = stencil({ Text = "", TextSize = 36, TextColor3 = C.stamp, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -18, 0.5, 1), Parent = band })
		table.insert(timers, { label = t, at = at_, prefix = prefix })
		y += 64
	end
	local function flagTile(id: string, i: number)
		local item = Catalog.get(id)
		if item == nil then
			return
		end
		local col = (i - 1) % cols
		local cell = Kit.new("TextButton", { Name = id, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = at(col * (tileW + gap), y + ((i - 1) // cols) * (tileH + gap)), Size = sz(tileW, tileH), Parent = area })
		local shade = Kit.new("Frame", { Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.68, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 3, 0.5, 6), Size = UDim2.new(1, -10, 1, -12), Parent = cell })
		Kit.corner(8).Parent = shade
		local face = cardArt("ImageLabel", "tile_folder", { Name = "Face", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = cell })
		local pic = Art.flag(id, { Position = at(14, 16), Size = sz(tileW - 28, picH), Parent = face })
		age(pic)
		stencil({ Text = item.name, TextSize = 34, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(tileW / 2, picH + 36), Size = sz(tileW - 16, 34), Parent = face })
		stencil({ Text = string.upper(Catalog.RARITY_NAME[item.rarity]), TextSize = 26, TextColor3 = RARITY_INK[item.rarity], AnchorPoint = Vector2.new(0.5, 0.5), Position = at(tileW / 2, picH + 62), Parent = face })
		local has = mine[id]
		local product = Catalog.product(Catalog.flagProduct(item.rarity)) :: Catalog.Product
		local plate = pricePlate(w, face, tileW / 2, tileH - 30, tileW - 28, 46, if has then nil else product.price, 20)
		local function buy()
			if has then
				return
			end
			local r = ctx.request({ op = "chooseFlag", id = id })
			if r and r.ok then
				ctx.prompt(product.key)
			end
		end
		plate.Activated:Connect(buy)
		cell.Activated:Connect(buy)
		Dossier.liftTile(cell, face, shade, 6)
	end
	local function rows(list: { string })
		for i, id in list do
			flagTile(id, i)
		end
		y += ((#list + cols - 1) // cols) * (tileH + gap) + 6
	end
	if offers.event then
		strip(string.upper(`{offers.event.name} flags`), offers.event.endsAt, "ENDS IN")
		rows(offers.event.flags)
	end
	strip("TODAY'S FLAGS", offers.nextDailyAt, "NEW IN")
	rows(offers.daily)
	typed({ Text = "Flags from OpenFront (CC BY-SA 4.0) and our own", TextColor3 = C.sheet, TextSize = 16, AnchorPoint = Vector2.new(1, 0), Position = at(areaW, y), Parent = area })
	area.CanvasSize = UDim2.fromOffset(0, math.round(y + 30))

	local function tick()
		for _, t in timers do
			local left = t.at - os.time()
			t.label.Text = `{t.prefix} {if left > 86400 then Kit.days(left) else Kit.clock(left)}`
		end
	end
	tick()
	local acc = 0
	local conn = game:GetService("RunService").Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			tick()
		end
	end)
	w.root.Destroying:Connect(function()
		conn:Disconnect()
	end)
	return (w :: any) :: Kit.Modal
end

-- The "You got" card on a phone: the print at the left; the name, what it
-- is and NICE at the right.
local function revealPhone(host: Instance, itemId: string): Kit.Modal
	local c = Catalog.get(itemId)
	local wpn = Catalog.weapon(itemId)
	local w = Dossier.phoneWindow(host, "YOU GOT")
	local at, sz = w.at, w.sz
	local W, H = w.width, w.height
	local half = W / 2
	cardArt("ImageLabel", "folder_card", { Name = "Folder", Position = at(16, 10), Size = sz(W - 32, H - 26), Parent = w.body })
	local printW = math.min(half - 40, (H - 80) * 1.5)
	local print_ = Kit.new("Frame", { Name = "Print", BackgroundColor3 = C.sheet, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(half / 2 + 16, H / 2 + 4), Size = sz(printW, printW / 1.5), Rotation = -1.5, Parent = w.body })
	local inner = { Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 1, -20) }
	local pic
	if c then
		pic = if c.kind == "skin" then Art.skin(itemId, merge({ Parent = print_ }, inner)) else Art.flag(itemId, merge({ Parent = print_ }, inner))
	elseif wpn then
		pic = Art.card(itemId, merge({ Parent = print_ }, inner))
	end
	if pic then
		age(pic)
		local grunge = pic:FindFirstChild("Grunge") :: ImageLabel?
		if grunge then
			grunge.ImageTransparency = 0.6
		end
	end
	local rx = half + (half - 32) / 2
	local label = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Name = "Name", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(rx, H * 0.26), Size = sz(half - 70, 96), Rotation = -0.5, Parent = w.body })
	local name = if c then c.name elseif wpn then wpn.name else itemId
	stencil({ Text = string.upper(name), TextSize = 64, TextScaled = false, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.new(1, -24, 1, 0), Position = UDim2.fromOffset(12, 0), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, Parent = label })
	if c then
		stencil({ Text = string.upper(Catalog.RARITY_NAME[c.rarity]), TextSize = 48, TextColor3 = RARITY_INK[c.rarity], AnchorPoint = Vector2.new(0.5, 0.5), Position = at(rx, H * 0.26 + 82), Parent = w.body })
	elseif wpn then
		local where = if wpn.weapon == "reinforcements"
			then "Unlocked for good. In a match, tap the Reinforce button."
			elseif wpn.weapon then "Unlocked for good. It's the last slot in your build drawer in every match."
			else "Yours for good."
		typed({ Text = where, TextColor3 = C.inkBlack, TextSize = 22, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0.5, 0), Position = at(rx, H * 0.26 + 62), Size = sz(half - 90, 80), Parent = w.body })
	end
	local nice = Dossier.rivetPlate(w.body, "NICE", 64, true, { Name = "Nice", Position = at(rx, H - 86), Size = sz(half - 90, 90), Parent = w.body })
	nice.Activated:Connect(w.close)
	return (w :: any) :: Kit.Modal
end


-- Reference: flagshop-reference.png, 1312 x 1199.
function Shops.flagShop(host: Instance, ctx: Ctx): Kit.Modal
	if Dossier.phone() then
		return flagShopPhone(host, ctx)
	end
	local view = ctx.view
	local mine = owned(view)
	local offers = FlagShop.offers(os.time())
	local w = Dossier.window(host, 1312, 1199, WINDOW_H, 36)
	local at, sz = w.at, w.sz
	local head = w.header
	local timers: { { label: TextLabel, at: number, prefix: string } } = {}

	-- Header.
	headerPaper(w, 60, 38, 782, 170, -0.5)
	clip(head, w, 46, 120, 92, -6)
	starStamp(head, w, 120, 135, 102, 0.72)
	bigCaps(w, 72, { Text = "FLAG SHOP", AnchorPoint = Vector2.new(0, 0.5), Position = at(172, 100), Parent = head })
	Kit.label({ Text = "New flags every day", FontFace = F.uiHeavy, TextColor3 = C.inkBlack, TextSize = math.round(32 * w.k), AnchorPoint = Vector2.new(0, 0.5), Position = at(176, 165), Parent = head })
	Dossier.icon("icon_flag", "flag", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(752, 128), Size = sz(120, 140), Parent = head })
	if offers.event then
		art(offers.event.stamp, { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1018, 112), Size = sz(320, 128), Rotation = -4, Parent = head })
		local noteProps = { Position = at(1050, 172), Size = sz(212, 46), Rotation = -1, Parent = head }
		Dossier.shadow(head, noteProps, 1)
		local note = Dossier.surface("ImageLabel", "tex_paper", C.sheet, noteProps)
		local t = stencil({ Text = "", TextSize = capSize(w, 18), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = note })
		table.insert(timers, { label = t, at = offers.event.endsAt, prefix = "ENDS IN" })
	end
	pin(head, w, 65, 228)
	Dossier.closeRed(head, at(1262, 96), sz(74, 74), w.close)

	-- The flags, scrolling under the header.
	local area = Kit.scroll({ Name = "Flags", Position = at(40, 222), Size = sz(1240, 960), ScrollBarThickness = math.round(10 * w.k), ScrollBarImageColor3 = Color3.fromHex("#1E2019"), AutomaticCanvasSize = Enum.AutomaticSize.None, Parent = w.body })
	local function a(x: number, y: number): UDim2
		return at(x - 40, y - 222)
	end
	local COLS = { 80, 372, 665, 955 }
	local function flagTile(id: string, x: number, y: number, h: number, picTop: number, picH: number, plateDy: number, plateH: number)
		local item = Catalog.get(id)
		if item == nil then
			return
		end
		local cell = Kit.new("TextButton", { Name = id, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = a(x, y), Size = sz(278, h), Parent = area })
		local shade = Kit.new("Frame", { Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.68, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 3, 0.5, 6), Size = UDim2.new(1, -10, 1, -12), Parent = cell })
		Kit.corner(8).Parent = shade
		local face = cardArt("ImageLabel", "tile_folder", { Name = "Face", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = cell })
		local pic = Art.flag(id, { Position = at(22, picTop), Size = sz(230, picH), Parent = face })
		age(pic)
		local nameY = picTop + picH + 22
		stencil({ Text = item.name, TextSize = capSize(w, 20), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, math.round(nameY * w.k)), Parent = face })
		stencil({ Text = string.upper(Catalog.RARITY_NAME[item.rarity]), TextSize = capSize(w, 13), TextColor3 = RARITY_INK[item.rarity], AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, math.round((nameY + 29) * w.k)), Parent = face })
		local has = mine[id]
		local product = Catalog.product(Catalog.flagProduct(item.rarity)) :: Catalog.Product
		local plate = pricePlate(w, face, 139, nameY + plateDy, 224, plateH, if has then nil else product.price, 20)
		local function buy()
			if has then
				return
			end
			local r = ctx.request({ op = "chooseFlag", id = id })
			if r and r.ok then
				ctx.prompt(product.key)
			end
		end
		plate.Activated:Connect(buy)
		cell.Activated:Connect(buy)
		Dossier.liftTile(cell, face, shade, 8)
	end

	local y = 230
	if offers.event then
		local flags = offers.event.flags
		for i, id in flags do
			local col, rowN = (i - 1) % 4, (i - 1) // 4
			flagTile(id, COLS[col + 1], y + rowN * 325, 308, 30, 150, 69, 46)
		end
		local rows = (#flags + 3) // 4
		-- The big faded star fills the empty end of the last row.
		local empty = rows * 4 - #flags
		if empty >= 2 then
			local startX = COLS[4 - empty + 1]
			starStamp(area, w, (startX + 1232) / 2 - 40, y + (rows - 1) * 325 + 156 - 222, 270, 0.7)
		end
		y += rows * 325 - 12
	end

	-- Today's flags.
	local strip = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Position = a(65, y), Size = sz(1200, 66), Parent = area })
	stencil({ Text = "TODAY'S FLAGS", TextSize = capSize(w, 30), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(34 * w.k), 0.5, 2), Parent = strip })
	Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = UDim2.new(0, math.round(310 * w.k), 0, math.round(46 * w.k)), Size = UDim2.fromOffset(math.round(605 * w.k), 2), Parent = strip })
	local newNote = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { Position = a(1015, y - 6), Size = sz(225, 62), Rotation = 1, Parent = area })
	Kit.stroke(C.sheetLine, 1, 0.2).Parent = newNote
	local nt = stencil({ Text = "", TextSize = capSize(w, 18), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = newNote })
	table.insert(timers, { label = nt, at = offers.nextDailyAt, prefix = "NEW IN" })
	y += 72
	for i, id in offers.daily do
		local col, rowN = (i - 1) % 4, (i - 1) // 4
		flagTile(id, COLS[col + 1], y + rowN * 240, 228, 20, 108, 57, 40)
	end
	y += ((#offers.daily + 3) // 4) * 240
	area.CanvasSize = UDim2.fromOffset(0, math.round((y - 222 + 10) * w.k))
	typed({ Text = "Flags from OpenFront (CC BY-SA 4.0) and our own", TextColor3 = C.sheet, TextSize = math.round(17 * w.k), AnchorPoint = Vector2.new(1, 0.5), Position = at(1290, 1186), Parent = w.body })

	local function tick()
		for _, t in timers do
			local left = t.at - os.time()
			t.label.Text = `{t.prefix} {if left > 86400 then Kit.days(left) else Kit.clock(left)}`
		end
	end
	tick()
	local acc = 0
	local conn = game:GetService("RunService").Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			tick()
		end
	end)
	w.root.Destroying:Connect(function()
		conn:Disconnect()
	end)
	return (w :: any) :: Kit.Modal
end

-- "You got" card for a crate, an unlock or a flag, laid out to Bruno's
-- reference (2026-10-27, docs/design/dossier-ui/reveal-reference.png,
-- 1329 x 1183): the header paper (gift, YOU GOT, a faded star, red stripes,
-- the X), a folder with the item as an aged print, its name on a paper
-- strip, the rarity (or where to find a weapon), and the NICE plate.
function Shops.reveal(host: Instance, itemId: string): Kit.Modal
	if Dossier.phone() then
		return revealPhone(host, itemId)
	end
	local c = Catalog.get(itemId)
	local wpn = Catalog.weapon(itemId)
	local w = Dossier.window(host, 1329, 1183, 820, 36)
	local at, sz = w.at, w.sz
	local head = w.header

	-- Header.
	headerPaper(w, 75, 62, 1215, 178, 0)
	Kit.glyph("gift", { ImageColor3 = C.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(170, 152), Size = sz(104, 104), Parent = head })
	bigCaps(w, 82, { Text = "YOU GOT", AnchorPoint = Vector2.new(0, 0.5), Position = at(245, 150), Parent = head })
	Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.2, BorderSizePixel = 0, Position = at(130, 228), Size = UDim2.fromOffset(math.round(690 * w.k), 3), Parent = head })
	starStamp(head, w, 955, 150, 140, 0.7)
	for i = 0, 1 do
		local stripe = art("red_tape", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1120 + i * 60, 150), Size = sz(210, 26), Rotation = 60, ScaleType = Enum.ScaleType.Stretch, Parent = head })
		if stripe == nil then
			Kit.new("Frame", { BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1120 + i * 60, 150), Size = sz(200, 18), Rotation = 60, Parent = head })
		end
	end
	local x = Kit.new("TextButton", { Name = "Close", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(1240, 155), Size = sz(84, 84), Parent = head })
	Kit.glyph("close", { ImageColor3 = C.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.62, 0.62), Parent = x })
	Dossier.clicky(x, 1.1)
	x.Activated:Connect(w.close)

	-- The folder, the print, the name.
	cardArt("ImageLabel", "folder_card", { Name = "Folder", Position = at(55, 300), Size = sz(1200, 690), Parent = w.body })
	starStamp(w.body, w, 200, 770, 230, 0.72)
	local print_ = Kit.new("Frame", { Name = "Print", BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = at(345, 312), Size = sz(642, 418), Parent = w.body })
	local inner = { Position = UDim2.fromOffset(math.round(12 * w.k), math.round(12 * w.k)), Size = UDim2.new(1, -math.round(24 * w.k), 1, -math.round(24 * w.k)) }
	local pic
	if c then
		pic = if c.kind == "skin" then Art.skin(itemId, merge({ Parent = print_ }, inner)) else Art.flag(itemId, merge({ Parent = print_ }, inner))
	elseif wpn then
		pic = Art.card(itemId, merge({ Parent = print_ }, inner))
	end
	if pic then
		age(pic)
		-- Large, the overlay's worn edge reads as a dark frame: lighter here.
		local grunge = pic:FindFirstChild("Grunge") :: ImageLabel?
		if grunge then
			grunge.ImageTransparency = 0.6
		end
	end
	local label = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Name = "Name", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(664, 798), Size = sz(560, 108), Rotation = -0.5, Parent = w.body })
	local name = if c then c.name elseif wpn then wpn.name else itemId
	stencil({ Text = string.upper(name), TextSize = capSize(w, 50), AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Center, Parent = label })
	if c then
		stencil({ Text = string.upper(Catalog.RARITY_NAME[c.rarity]), TextSize = capSize(w, 26), TextColor3 = RARITY_INK[c.rarity], AnchorPoint = Vector2.new(0.5, 0.5), Position = at(664, 882), Parent = w.body })
	elseif wpn then
		local where = if wpn.weapon == "reinforcements"
			then "Unlocked for good. In a match, press R or the Reinforce button."
			elseif wpn.weapon then "Unlocked for good. It's in your build bar in every match, after the bombs."
			else "Yours for good."
		typed({ Text = where, TextColor3 = C.inkBlack, TextSize = math.round(26 * w.k), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Center, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(664, 892), Size = sz(900, 70), Parent = w.body })
	end
	local nice = Dossier.rivetPlate(w.body, "NICE", capSize(w, 52), true, { Name = "Nice", Position = at(670, 1003), Size = sz(1110, 140), Parent = w.body })
	nice.Activated:Connect(w.close)
	return (w :: any) :: Kit.Modal
end

return Shops
