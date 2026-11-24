--!strict
-- The Shop (Bruno, 2026-11-23: option A of the shop redesign, "one
-- counter", after the fast-food menu audit): one window with five shelves on
-- a tab rail at the left. Every item is the same card: picture, name, a line
-- saying what it does, and ONE price in the same place (OWNED; a star unlock
-- the player can afford; else the Robux price, a star bar above it showing
-- how far along they are). A card opens its sheet, which holds both ways to
-- pay and the details.
--   FEATURED  the starter pack (or today's deal) as the hero, then offers
--   WEAPONS   the Arsenal on three shelves: Strike, Army, Defence
--   CRATES    the crate, its odds, and a ladder: free, stars, first, 3, 5
--   FLAGS     the limited event's flags and today's flags
--   BOOSTS    2x Stars and Conquest General
-- One layout serves desktop and phone: everything is placed in reference
-- units inside the body (`w.at`, `w.sz`; the window scales them).
-- Nothing is granted here: the server decides (Store) and pushes the view.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)
local FlagShop = require(Shared.Store.FlagShop)
local Profile = require(Shared.Store.Profile)

local Art = require(script.Parent.Parent.Art)
local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)
local Shops = require(script.Parent.Shops)
local GiftPicker = require(script.Parent.GiftPicker)
local DarkWindow = require(script.Parent.Parent.DarkWindow)

local C = Theme.color
local F = Theme.font
local P = Shops.parts
local stencil = Dossier.stencil
local typed = Dossier.typed
local age = Dossier.age

local Shop = {}

Shop.TABS = { "featured", "weapons", "crates", "flags", "boosts" }
local TAB_TITLE: { [string]: string } = { featured = "FEATURED", weapons = "WEAPONS", crates = "CRATES", flags = "FLAGS", boosts = "BOOSTS" }
-- Each tab's ink icon (UiAssets.dossier) and the UI glyph used until it's in.
local TAB_ICON: { [string]: { string } } = {
	featured = { "icon_star", "star" },
	weapons = { "icon_armory", "silo" },
	crates = { "icon_crates", "chest" },
	flags = { "icon_flag", "flag" },
	boosts = { "icon_boost", "bolt" },
}
local TAB_LINE: { [string]: string } = {
	featured = "This week's best offers.",
	weapons = "Weapons unlock for good. Earn stars in every match, or skip the wait with Robux.",
	crates = "Skins colour your land; flags fly beside your name.",
	flags = "Your flag flies beside your name on the map. Yours to keep.",
	boosts = "Earn stars faster.",
}

-- The Arsenal's shelves, cheapest first (Bruno's tiers, 2026-11-23).
Shop.SHELVES = {
	{ title = "STRIKE", line = "bombs and air power", ids = { "w_scatter", "w_mega", "w_airstrike", "w_railgun" } },
	{ title = "ARMY", line = "more troops, new fronts", ids = { "w_fieldworks", "w_reinforce", "w_paratroopers" } },
	{ title = "DEFENCE", line = "hold the line, slow them down", ids = { "w_coastal", "w_sabotage", "w_artillery", "w_rapidreload" } },
}
-- A card's one line, verb first, in the player's terms.
Shop.DOES = {
	w_reinforce = "Call in +20% of your troop limit every 30 s",
	w_mega = "A nuke with 4x an Atom Bomb's blast area",
	w_scatter = "An Atom Bomb that drops 4 to 6 extra warheads",
	w_artillery = "Batteries shell every enemy within 45 tiles",
	w_airstrike = "Airfields bomb a 15-tile circle 156 tiles away",
	w_railgun = "Hit anywhere; knocks a building down a level",
	w_fieldworks = "Dig in at a front: defends like a post for 60 s",
	w_coastal = "Shore guns sink enemy boats within 40 tiles",
	w_sabotage = "Switch off an enemy SAM, silo, gun or port",
	w_paratroopers = "Fly troops 120 tiles to strike behind the front",
	w_rapidreload = "Every reload of yours takes half as long",
	b_double = "Every match pays double stars, forever",
	w_general = "A crate a day, +50% stars and the month's skin",
}
-- The first weapon we point a new player to (while they don't own it).
Shop.START_HERE = "w_reinforce"
-- About what a match pays (a 9-minute Medium match, now and then a win),
-- for "about N matches".
Shop.STARS_PER_MATCH = 800

export type Ctx = Shops.Ctx & {
	tab: string?,
	adReady: boolean?,
	openStarter: () -> (),
	openGeneral: () -> (),
	openLocker: () -> (),
	shelf: ((tab: string) -> ())?,
}

local RAIL_W = 150
-- Each Arsenal shelf's tile colour.
local SHELF_TONE: { [string]: string } = { STRIKE = "strike", ARMY = "army", DEFENCE = "defence" }
local PAD = 12
local GAP = 14
local SCROLLBAR = 16
local DIM = Color3.fromHex("#E8DFC6")
-- The dark style (Bruno, 2026-11-23: "do all the windows in that style").
local WHITE = Color3.new(1, 1, 1)
local LIGHT = Color3.fromHex("#E8E2D0")
local BROWN = Color3.fromHex("#3B2200")
local TONES = DarkWindow.TONES
local GLOW = DarkWindow.GLOW
-- A tile's text: white with a soft dark outline, readable on any tone.
local function outline(label: TextLabel)
	Kit.new("UIStroke", { Color = Color3.new(0, 0, 0), Thickness = 1.5, Transparency = 0.45, Parent = label })
end

-- "about 12 matches" for what a player is short of (at least 1).
function Shop.matchesFor(short: number): number
	return math.max(1, math.round(short / Shop.STARS_PER_MATCH))
end

-- How many crates for what, and what a crate comes to in each (Robux).
local function eachOf(key: string, n: number): (number, number)
	local p = (Catalog.product(key) :: Catalog.Product).price
	local single = (Catalog.product("crate1") :: Catalog.Product).price
	local each = p / n
	return math.round(each), math.round((1 - each / single) * 100)
end

function Shop.open(host: Instance, ctx: Ctx): Kit.Modal
	local view = ctx.view
	local memo: { [string]: any } = ctx.memo or {}
	memo.scroll = memo.scroll or {}
	local mine = P.owned(view)
	local phone = Dossier.phone()
	local player = Players.LocalPlayer
	local deal = Catalog.todaysDeal(if player then player.UserId else 0, os.time(), mine, view.dealDay)

	-- The window (the dark style): the banner header, the body under it.
	local BANNER = 150
	local dw = DarkWindow.open(host, {
		title = "SHOP",
		kicker = "Weapons, crates, flags and boosts",
		subtitle = " ",
		art = if (UiAssets.dossier.banner_shop or "") ~= "" then "banner_shop" else "arsenal_scatter",
		wash = Color3.fromHex("#E6A817"),
		bannerH = BANNER,
	})
	local w: Dossier.Window = dw
	local subline: TextLabel? = dw.subtitle
	local x0, y0, BW, BH = 14, BANNER - 6, w.width - 28, w.height - BANNER - 6
	local at, sz, k = w.at, w.sz, w.k
	local function ts(n: number): number
		return math.round(n * k)
	end

	-- Your stars, in a dark pill at the banner's right.
	do
		local pill = Kit.new("Frame", { Name = "Stars", BackgroundColor3 = Color3.fromHex("#140804"), BackgroundTransparency = 0.25, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, ts(12)), Size = sz(0, 56), AutomaticSize = Enum.AutomaticSize.X, Parent = dw.right })
		Kit.corner(ts(10)).Parent = pill
		Kit.stroke(DarkWindow.GOLD, 2, 0.3).Parent = pill
		Kit.padding(0, ts(16)).Parent = pill
		local r = P.row(pill, ts(8))
		r.AutomaticSize = Enum.AutomaticSize.X
		r.Size = UDim2.fromScale(0, 1)
		Kit.glyph("star", { ImageColor3 = DarkWindow.GOLD, Size = sz(30, 30), LayoutOrder = 1, Parent = r })
		stencil({ Text = Kit.commas(view.stars or 0), TextSize = ts(40), TextColor3 = WHITE, LayoutOrder = 2, Parent = r })
	end

	-- Timers (deal, starter, flags) repaint once a second while open.
	local tickers: { () -> () } = {}
	local acc = 0
	local conn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 1 then
			acc = 0
			for _, f in tickers do
				f()
			end
		end
	end)
	w.root.Destroying:Connect(function()
		conn:Disconnect()
	end)

	-- Pieces ----------------------------------------------------------------------------------

	local function has(wpn: Catalog.Weapon): boolean
		return mine[wpn.id] == true or (wpn.pass ~= nil and view.doubleStars == true) or (wpn.subscription == true and view.general == true)
	end

	-- A stamp on a picture's corner (TODAY -40%, START HERE, NEW).
	local function stamp(parent: GuiObject, text: string, color: Color3, ink: Color3)
		local s = Kit.new("Frame", { Name = "Stamp", BackgroundColor3 = color, BorderSizePixel = 0, Position = at(6, 6), AutomaticSize = Enum.AutomaticSize.XY, Rotation = -4, ZIndex = parent.ZIndex + 4, Parent = parent })
		Kit.corner(4).Parent = s
		Kit.padding(ts(4), ts(9)).Parent = s
		stencil({ Text = text, TextSize = ts(20), TextColor3 = ink, ZIndex = s.ZIndex, Parent = s })
	end

	-- The one price: a plate centred at (cx, cy) in `parent`.
	--   { kind = "robux", amount, was? }   yellow, the Robux mark
	--   { kind = "stars", amount, ok }     yellow when affordable, else dim
	--   { kind = "owned", text? }           manila, no action
	--   { kind = "free", text }             yellow with a gift
	local function plate(parent: Instance, cx: number, cy: number, pw: number, ph: number, price: { [string]: any }, onBuy: (() -> ())?): GuiObject
		-- Type sized so the row fits the plate: a mark or icon (about 1.5 caps
		-- wide), a gap, then about 0.9 caps a character (Oswald's stencil
		-- caps), plus a struck-through regular price before a deal's.
		local words = if price.text then price.text
			elseif price.kind == "stars" and price.ok and not price.short then `UNLOCK {Kit.commas(price.amount or 0)}`
			elseif price.kind == "owned" then "OWNED"
			else Kit.commas(price.amount or 0)
		local chars = #words + (if price.was then #tostring(price.was) * 0.75 + 1 else 0)
		local cap = math.min(26, ph * 0.42, (pw - 34) / (1.6 + 0.9 * chars))
		if price.kind == "robux" then
			local p = P.pricePlate(w, parent, cx, cy, pw, ph, price.amount, cap, price.was)
			if onBuy then
				p.Activated:Connect(onBuy)
			end
			return p
		elseif price.kind == "owned" then
			local b, r = P.manilaButton(w, parent, cx, cy, pw, ph)
			Kit.glyph("check", { ImageColor3 = C.inkBlack, Size = sz(cap * 1.1, cap * 1.1), LayoutOrder = 1, Parent = r })
			stencil({ Text = price.text or "OWNED", TextSize = Dossier.capSize(w, cap), LayoutOrder = 2, Parent = r })
			return b
		elseif price.kind == "stars" and not price.ok then
			local b, r = P.manilaButton(w, parent, cx, cy, pw, ph)
			Kit.glyph("star", { ImageColor3 = C.inkBlack, ImageTransparency = 0.35, Size = sz(cap * 1.1, cap * 1.1), LayoutOrder = 1, Parent = r })
			stencil({ Text = Kit.commas(price.amount), TextSize = Dossier.capSize(w, cap), TextTransparency = 0.4, LayoutOrder = 2, Parent = r })
			return b
		end
		local p = Dossier.plate(parent, "", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(cx, cy), Size = sz(pw, ph), Parent = parent }, 0)
		local r = P.row(p, ts(10))
		local glyph = if price.glyph then price.glyph elseif price.kind == "free" then "gift" else "star"
		Kit.glyph(glyph, { ImageColor3 = C.inkBlack, Size = sz(cap * 1.1, cap * 1.1), LayoutOrder = 1, Parent = r })
		stencil({ Text = words, TextSize = Dossier.capSize(w, cap), LayoutOrder = 2, Parent = r })
		Dossier.clicky(p, 1.04)
		if onBuy then
			local busy = false
			p.Activated:Connect(function()
				if busy then
					return
				end
				busy = true
				onBuy()
				busy = false
			end)
		end
		return p
	end

	-- A lifted folder card at (x, y) in `parent`: the picture, name, line,
	-- an optional star bar (0..1) or small foot line, and the price plate.
	-- Tapping the card (not the plate) calls `onOpen`.
	type CardSpec = {
		name: string,
		does: string,
		picture: (frame: Frame) -> GuiObject,
		stamp: { text: string, color: Color3, ink: Color3 }?,
		tone: string?, -- DarkWindow.TONES key (default navy)
		bar: number?,
		barText: string?,
		foot: string?,
		price: { [string]: any },
		onBuy: (() -> ())?,
		onOpen: (() -> ())?,
	}
	local function cardHeight(cw: number): number
		local picH = math.round(cw * 0.56)
		return 12 + picH + 10 + 34 + 52 + 16 + 56 + 14
	end
	local function card(parent: Instance, x: number, y: number, cw: number, spec: CardSpec): GuiObject
		local ch = cardHeight(cw)
		local picH = math.round(cw * 0.56)
		local cell = Kit.new("TextButton", { Name = spec.name, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = at(x, y), Size = sz(cw, ch), Parent = parent })
		local shade = Kit.new("Frame", { Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.68, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 3, 0.5, 6), Size = UDim2.new(1, -10, 1, -12), Parent = cell })
		Kit.corner(8).Parent = shade
		local tone = TONES[spec.tone or "navy"] or TONES.navy
		local face = DarkWindow.tile(cell, tone[1], tone[2], GLOW[spec.tone or ""], k)
		local frame = Kit.new("Frame", { Name = "Print", BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = at(10, 12), Size = sz(cw - 20, picH), Parent = face })
		local pic = spec.picture(frame)
		age(pic)
		if spec.stamp then
			stamp(frame, spec.stamp.text, spec.stamp.color, spec.stamp.ink)
		end
		local y1 = 12 + picH + 8
		outline(stencil({ Text = string.upper(spec.name), TextSize = ts(30), TextColor3 = WHITE, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, Position = at(14, y1), Size = sz(cw - 28, 34), Parent = face }))
		Kit.new("TextLabel", { Name = "Does", BackgroundTransparency = 1, Text = spec.does, FontFace = F.bodyBold, TextSize = ts(19), TextColor3 = LIGHT, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = at(14, y1 + 36), Size = sz(cw - 28, 48), Parent = face })
		local y2 = y1 + 36 + 52
		if spec.bar then
			-- How far along in stars, with the star price beside it.
			local tagW = if spec.barText then 22 + #spec.barText * 9 else 0
			if spec.barText then
				local tag = Kit.new("Frame", { Name = "StarPrice", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = at(cw - 14, y2 + 6), Size = sz(tagW, 22), Parent = face })
				Kit.list(Enum.FillDirection.Horizontal, ts(3), Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent = tag
				Kit.glyph("star", { ImageColor3 = DarkWindow.GOLD, Size = sz(15, 15), LayoutOrder = 1, Parent = tag })
				stencil({ Text = spec.barText, TextSize = ts(17), TextColor3 = LIGHT, LayoutOrder = 2, Parent = tag })
			end
			local track = Kit.new("Frame", { Name = "Bar", BackgroundColor3 = Color3.fromHex("#1A1A1A"), BorderSizePixel = 0, Position = at(14, y2 + 2), Size = sz(cw - 28 - tagW - 6, 8), Parent = face })
			Kit.corner(4).Parent = track
			local fill = Kit.new("Frame", { BackgroundColor3 = C.hazard, BorderSizePixel = 0, Size = UDim2.fromScale(math.clamp(spec.bar, 0.02, 1), 1), Parent = track })
			Kit.corner(4).Parent = fill
		elseif spec.foot then
			Kit.new("TextLabel", { Name = "Foot", BackgroundTransparency = 1, Text = spec.foot, FontFace = F.bodyBold, TextSize = ts(15), TextColor3 = LIGHT, Position = at(14, y2 - 4), Size = sz(cw - 28, 18), Parent = face })
		end
		plate(face, cw / 2, ch - 14 - 28, cw - 28, 54, spec.price, spec.onBuy)
		if spec.onOpen then
			cell.Activated:Connect(function()
				Dossier.click()
				;(spec.onOpen :: () -> ())()
			end)
		end
		Dossier.liftTile(cell, face, shade, 6)
		return cell
	end

	-- A shelf's heading on the board: the title and a typed line.
	local function heading(parent: Instance, y: number, title: string, line: string, big: boolean?): number
		local r = Kit.new("Frame", { Name = "Heading", BackgroundTransparency = 1, Position = at(2, y), Size = sz(700, if big then 44 else 36), Parent = parent })
		Kit.list(Enum.FillDirection.Horizontal, ts(14), Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom).Parent = r
		stencil({ Text = title, TextSize = ts(if big then 40 else 32), TextColor3 = C.sheet, LayoutOrder = 1, Parent = r })
		typed({ Text = line, TextSize = ts(17), TextColor3 = DIM, LayoutOrder = 2, Parent = r })
		return y + (if big then 48 else 40)
	end

	-- The content area right of the rail, one scrolling page per shelf.
	local cx0 = x0 + PAD + RAIL_W + GAP
	local CW = BW - (cx0 - x0) - PAD
	local CH = BH - PAD
	local innerW = CW - SCROLLBAR
	local function page(name: string): ScrollingFrame
		local s = Kit.scroll({ Name = name, Position = at(cx0, y0 + 6), Size = sz(CW, CH), ScrollingDirection = Enum.ScrollingDirection.Y, AutomaticCanvasSize = Enum.AutomaticSize.None, ScrollBarThickness = 8, ScrollBarImageColor3 = Color3.fromHex("#6B5A3A"), Parent = w.body })
		return s
	end
	local function finish(s: ScrollingFrame, bottom: number)
		s.CanvasSize = UDim2.fromOffset(0, math.round((bottom + 16) * k))
	end

	-- Weapons --------------------------------------------------------------------------------

	local sheetLayer: Frame? = nil
	local openSheet: (Catalog.Weapon) -> ()

	local function weaponPrice(wpn: Catalog.Weapon): ({ [string]: any }, (() -> ())?)
		if has(wpn) then
			return { kind = "owned", text = if wpn.subscription then "ACTIVE" else "OWNED" }, nil
		end
		local stars = view.stars or 0
		if wpn.stars and stars >= wpn.stars then
			return { kind = "stars", amount = wpn.stars, ok = true }, function()
				local r = ctx.request({ op = "unlock", id = wpn.id })
				if r and r.ok then
					ctx.reveal(wpn.id)
				end
			end
		end
		if wpn.subscription then
			return { kind = "robux", amount = Catalog.SUBSCRIPTION.robux }, function()
				ctx.openGeneral()
			end
		end
		local key = wpn.product or wpn.pass
		local dealKey = if wpn == deal then Catalog.dealProduct(wpn) else nil
		local dealProduct = if dealKey then Catalog.product(dealKey) else nil
		local regular = if key then Catalog.product(key) else nil
		local product = dealProduct or regular
		if product == nil then
			return { kind = "owned", text = "SOON" }, nil
		end
		local buyKey = product.key
		return { kind = "robux", amount = product.price, was = if dealProduct and regular then regular.price else nil }, function()
			ctx.prompt(buyKey)
		end
	end

	local function weaponCard(parent: Instance, x: number, y: number, cw: number, wpn: Catalog.Weapon, tone: string?)
		local price, onBuy = weaponPrice(wpn)
		local stars = view.stars or 0
		local st = nil
		if wpn == deal then
			st = { text = `TODAY -{math.round(Catalog.DEAL.off * 100)}%`, color = C.stamp, ink = C.sheet }
		elseif wpn.id == Shop.START_HERE and not has(wpn) then
			st = { text = "START HERE", color = C.hazard, ink = C.inkBlack }
		end
		card(parent, x, y, cw, {
			name = wpn.name,
			does = Shop.DOES[wpn.id] or wpn.desc,
			picture = function(frame)
				return Art.card(wpn.id, { Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8), Parent = frame })
			end,
			stamp = st,
			tone = tone,
			bar = if not has(wpn) and wpn.stars and stars < wpn.stars then stars / wpn.stars else nil,
			barText = if wpn.stars then Kit.commas(wpn.stars) else nil,
			foot = if not has(wpn) and wpn.stars == nil and not wpn.pass and not wpn.subscription then "ROBUX ONLY" else nil,
			price = price,
			onBuy = onBuy,
			onOpen = function()
				openSheet(wpn)
			end,
		})
	end

	local function columns(minW: number): (number, number)
		local cols = math.max(2, math.floor((innerW + GAP) / (minW + GAP)))
		return cols, (innerW - (cols - 1) * GAP) / cols
	end

	local function weaponsPage(): ScrollingFrame
		local s = page("Weapons")
		local cols, cw = columns(230)
		local ch = cardHeight(cw)
		local y = 0
		for _, shelf in Shop.SHELVES do
			y = heading(s, y, shelf.title, shelf.line)
			local i = 0
			for _, id in shelf.ids do
				local wpn = Catalog.weapon(id)
				if wpn then
					weaponCard(s, (i % cols) * (cw + GAP), y + (i // cols) * (ch + GAP), cw, wpn, SHELF_TONE[shelf.title])
					i += 1
				end
			end
			y += ((i + cols - 1) // cols) * (ch + GAP) + 6
		end
		finish(s, y)
		return s
	end

	-- A weapon's sheet: the picture, what it does, its two facts, and both
	-- ways to pay (stars with how far along you are, and Robux).
	openSheet = function(wpn: Catalog.Weapon)
		if sheetLayer then
			sheetLayer:Destroy()
		end
		local layer = Kit.new("TextButton", { Name = "Sheet", Text = "", AutoButtonColor = false, BackgroundColor3 = C.desk, BackgroundTransparency = 0.3, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 10, Parent = w.window }) :: any
		sheetLayer = layer
		local function close()
			if sheetLayer == layer then
				sheetLayer = nil
			end
			layer:Destroy()
		end
		layer.Activated:Connect(close)
		local PW, PH = math.min(980, BW - 60), math.min(470, BH - 30)
		local px, py = x0 + (BW - PW) / 2, y0 + (BH - PH) / 2 + (if phone then 0 else -20)
		local panel = Kit.new("TextButton", { Name = "Panel", Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BorderSizePixel = 0, Position = at(px, py), Size = sz(PW, PH), ZIndex = 11, Parent = layer })
		Kit.corner(ts(14)).Parent = panel
		Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromHex("#22343F"), Color3.fromHex("#0F1A14")), Parent = panel })
		Kit.stroke(DarkWindow.GOLD, 2, 0.4).Parent = panel
		local picW = math.round(PW * 0.38)
		local frame = Kit.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Position = at(22, 24), Size = sz(picW, math.round(picW * 0.72)), Rotation = -1, Parent = panel })
		age(Art.card(wpn.id, { Position = UDim2.fromOffset(5, 5), Size = UDim2.new(1, -10, 1, -10), Parent = frame }))
		local rx = 22 + picW + 26
		local rw = PW - rx - 24
		outline(stencil({ Text = string.upper(wpn.name), TextSize = ts(52), TextColor3 = WHITE, Position = at(rx, 18), Parent = panel }))
		local product = if wpn.product then Catalog.product(wpn.product) elseif wpn.pass then Catalog.product(wpn.pass) else nil
		local long = Shop.DOES[wpn.id] or wpn.desc
		if product then
			local after = string.match(product.desc, ":%s*(.+)$")
			long = if after then string.upper(string.sub(after, 1, 1)) .. string.sub(after, 2) else product.desc
		end
		Kit.new("TextLabel", { BackgroundTransparency = 1, Text = long, FontFace = F.bodyBold, TextSize = ts(23), TextColor3 = LIGHT, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = at(rx, 84), Size = sz(rw, 84), Parent = panel })
		for i, bullet in wpn.bullets do
			local fx = rx + (i - 1) * (rw / 2 + 4)
			local chip = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#2C3E4A"), BorderSizePixel = 0, Position = at(fx, 176), Size = sz(rw / 2 - 8, 56), Parent = panel })
			Kit.corner(6).Parent = chip
			Kit.stroke(Color3.fromHex("#4A6070"), 1, 0).Parent = chip
			Kit.new("TextLabel", { BackgroundTransparency = 1, Text = bullet, FontFace = F.bodyBold, TextSize = ts(19), TextColor3 = WHITE, TextWrapped = true, Position = at(10, 4), Size = sz(rw / 2 - 28, 48), Parent = chip })
		end
		-- Both ways to pay, side by side.
		local stars = view.stars or 0
		local payY = PH - 108
		local half = (PW - 66) / 2
		if has(wpn) then
			plate(panel, PW / 2, payY + 34, PW - 48, 64, { kind = "owned", text = if wpn.subscription then "ACTIVE" else "OWNED" })
		else
			local robuxPrice, robuxBuy = weaponPrice(wpn)
			if robuxPrice.kind == "stars" then
				-- (Affordable with stars: the Robux price sits beside it anyway.)
				local key = wpn.product
				local p = if key then Catalog.product(key) else nil
				robuxPrice = if p then { kind = "robux", amount = p.price } else robuxPrice
				robuxBuy = if p then function()
					ctx.prompt(p.key)
				end else nil
			end
			if wpn.stars then
				local ok = stars >= wpn.stars
				plate(panel, 24 + half / 2, payY + 30, half, 60, { kind = "stars", amount = wpn.stars, ok = ok }, if ok then function()
					local r = ctx.request({ op = "unlock", id = wpn.id })
					if r and r.ok then
						close()
						ctx.reveal(wpn.id)
					end
				end else nil)
				local note = if ok then "Earned in matches: unlock it now" else `You have {Kit.commas(stars)} · about {Shop.matchesFor(wpn.stars - stars)} more matches`
				Kit.new("TextLabel", { BackgroundTransparency = 1, Text = note, FontFace = F.bodyBold, TextSize = ts(17), TextColor3 = LIGHT, Position = at(24, payY + 66), Size = sz(half, 22), Parent = panel })
			end
			local rxp = if wpn.stars then 42 + half + half / 2 else PW / 2
			plate(panel, rxp, payY + 30, if wpn.stars then half else PW - 48, 60, robuxPrice, robuxBuy)
			Kit.new("TextLabel", { BackgroundTransparency = 1, Text = if wpn == deal then "Yours for good · today's deal" else "Yours for good", FontFace = F.bodyBold, TextSize = ts(17), TextColor3 = LIGHT, Position = at(rxp - (if wpn.stars then half else PW - 48) / 2, payY + 66), Size = sz(if wpn.stars then half else PW - 48, 22), Parent = panel })
		end
		Dossier.closeManila(panel, at(PW - 26, 26), sz(44, 44), close)
	end

	-- Crates ---------------------------------------------------------------------------------

	local function cratesPage(): ScrollingFrame
		local s = page("Crates")
		-- On a phone the odds box goes under the offers, as a wide strip, so
		-- the offers get the whole width (placed once their height is known).
		local boxW = if phone then innerW else math.round(innerW * 0.26)
		local boxH = if phone then 196 else 400
		local boxHost = Kit.new("Frame", { Name = "Crate", BackgroundTransparency = 1, Position = at(0, 4), Size = sz(boxW, boxH), Parent = s })
		local box = DarkWindow.tile(boxHost, TONES.crate[1], TONES.crate[2], nil, k)
		if phone then
			Dossier.art("crate_wood", { Position = at(18, 23), Size = sz(150, 150), Parent = box })
			outline(stencil({ Text = "COSMETIC CRATE", TextSize = ts(34), TextColor3 = WHITE, Position = at(186, 30), Parent = box }))
			Kit.new("TextLabel", { BackgroundTransparency = 1, Text = "A territory skin or a country flag you don't own yet", FontFace = F.bodyBold, TextSize = ts(19), TextColor3 = WHITE, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = at(186, 80), Size = sz(boxW - 186 - 280, 70), Parent = box })
		else
			Dossier.art("crate_wood", { AnchorPoint = Vector2.new(0.5, 0), Position = at(boxW / 2, 26), Size = sz(150, 150), Parent = box })
			outline(stencil({ Text = "COSMETIC CRATE", TextSize = ts(36), TextColor3 = WHITE, AnchorPoint = Vector2.new(0.5, 0), Position = at(boxW / 2, 182), Parent = box }))
			Kit.new("TextLabel", { BackgroundTransparency = 1, Text = "A territory skin or a country flag you don't own yet", FontFace = F.bodyBold, TextSize = ts(17), TextColor3 = WHITE, TextWrapped = true, Position = at(18, 222), Size = sz(boxW - 36, 44), Parent = box })
		end
		-- The odds: under the name on desktop, a column at the right on a phone.
		local oddsX, oddsY, oddsGap = if phone then boxW - 260 else 32, if phone then 46 else 284, if phone then 34 else 26
		for i, o in Profile.CRATE_ODDS do
			local y = oddsY + (i - 1) * oddsGap
			local sw = Kit.new("Frame", { BackgroundColor3 = P.RARITY_SWATCH[o.rarity], BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(oddsX, y), Size = sz(16, 16), Parent = box })
			Kit.corner(3).Parent = sw
			Kit.stroke(C.inkBlack, 1, 0.5).Parent = sw
			outline(stencil({ Text = Catalog.RARITY_NAME[o.rarity], FontFace = F.typewriter, TextSize = ts(if phone then 24 else 20), TextColor3 = WHITE, AnchorPoint = Vector2.new(0, 0.5), Position = at(oddsX + 18, y), Parent = box }))
			outline(stencil({ Text = `{o.percent}%`, FontFace = F.typewriter, TextSize = ts(if phone then 24 else 20), TextColor3 = WHITE, AnchorPoint = Vector2.new(1, 0.5), Position = at(boxW - 24, y), Parent = box }))
		end

		-- Two rows (Bruno, 2026-11-23: "the panels seem very cramped"): the
		-- packs big on top, the single crates (free, stars, the first one)
		-- smaller under them. Every panel is one button.
		type Offer = { title: string, line: string, art: string, badge: string?, ribbon: string?, ribbonColor: Color3?, price: { [string]: any }, onBuy: (() -> ())?, big: boolean?, gift: string?, tone: string? }
		local each3, save3 = eachOf("crate3", 3)
		local each5, save5 = eachOf("crate5", 5)
		local packs: { Offer } = {
			{ title = "3 CRATES", line = `{each3} R$ each · save {save3}%`, art = "crate_pile3", badge = "x3", ribbon = "MOST CHOSEN", price = { kind = "robux", amount = (Catalog.product("crate3") :: Catalog.Product).price }, onBuy = function()
				ctx.prompt("crate3")
			end, big = true, gift = "giftCrate3", tone = "crate" },
			{ title = "5 CRATES", line = `{each5} R$ each · save {save5}%`, art = "crate_pile5", badge = "x5", ribbon = "BEST VALUE", price = { kind = "robux", amount = (Catalog.product("crate5") :: Catalog.Product).price }, onBuy = function()
				ctx.prompt("crate5")
			end, gift = "giftCrate5", tone = "legendary" },
		}
		local singles: { Offer } = {}
		if view.freeCrate then
			table.insert(singles, { title = "FREE CRATE", line = "One crate on us", art = "crate_ad", badge = "gift", ribbon = "FREE", ribbonColor = P.GREEN, price = { kind = "free", text = "OPEN" }, onBuy = function()
				local res = ctx.request({ op = "freeCrate" })
				if res and res.ok and res.item then
					ctx.crate(res.item)
				end
			end })
		elseif ctx.adReady then
			table.insert(singles, { title = "FREE CRATE", line = "Watch a short ad", art = "crate_ad", badge = "play", ribbon = "FREE", ribbonColor = P.GREEN, price = { kind = "free", text = "WATCH AD", glyph = "play" }, onBuy = function()
				ctx.request({ op = "adCrate" })
			end })
		end
		local canStars = (view.stars or 0) >= Profile.CRATE_STARS
		table.insert(singles, { title = "1 CRATE", line = if canStars then `About {Shop.matchesFor(Profile.CRATE_STARS)} matches of stars` else `{Kit.commas(Profile.CRATE_STARS - (view.stars or 0))} more stars`, art = "crate_stars", badge = "star", price = { kind = "stars", amount = Profile.CRATE_STARS, ok = canStars, short = true }, onBuy = if canStars then function()
			local r = ctx.request({ op = "crate" })
			if r and r.ok and r.item then
				ctx.crate(r.item)
			end
		end else nil })
		if view.crateKey == "crateFirst" then
			local regular = (Catalog.product("crate1") :: Catalog.Product).price
			table.insert(singles, { title = "FIRST CRATE", line = "Your first one, once", art = "crate_wood", ribbon = "FIRST ONE", price = { kind = "robux", amount = view.cratePrice or 15, was = regular }, onBuy = function()
				ctx.prompt("crateFirst")
			end })
		end

		-- One panel: a button with the picture at the left, the title, a
		-- line and the price; the whole of it buys.
		local function panel(o: Offer, x: number, y: number, pw: number, ph: number)
			local cell = Kit.new("TextButton", { Name = o.title, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = at(x, y), Size = sz(pw, ph), Parent = s })
			local shade = Kit.new("Frame", { Name = "Shadow", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.68, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 3, 0.5, 6), Size = UDim2.new(1, -6, 1, -8), Parent = cell })
			Kit.corner(8).Parent = shade
			local toneName = o.tone or (if o.ribbonColor then "army" elseif o.price.kind == "stars" then "stars" else "rare")
			local tone = TONES[toneName] or TONES.navy
			local face = DarkWindow.tile(cell, tone[1], tone[2], if o.big then DarkWindow.GOLD else GLOW[toneName], k)
			local big = ph > 180
			local pic = math.min(ph - (if big then 40 else 24), math.round(pw * 0.4))
			local holder = Kit.new("Frame", { Name = "Picture", BackgroundTransparency = 1, Position = at(10, math.round((ph - pic) / 2) + (if big then 6 else 0)), Size = sz(pic, pic), Parent = face })
			if Dossier.art(o.art, { Size = UDim2.fromScale(1, 1), Parent = holder }) == nil then
				-- (Until the drawn art is in: the crate with a badge.)
				Dossier.art("crate_wood", { Size = UDim2.fromScale(1, 1), Parent = holder })
				if o.badge then
					local fill = if o.badge == "play" then C.stamp elseif o.badge == "star" or o.badge == "gift" then C.hazard else C.inkBlack
					local b = Kit.new("Frame", { BackgroundColor3 = fill, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromScale(0.4, 0.4), Parent = holder })
					Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = b })
					Kit.stroke(C.sheet, 2, 0).Parent = b
					if o.badge == "x3" or o.badge == "x5" then
						stencil({ Text = o.badge, TextSize = ts(pic * 0.16), TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = b })
					else
						Kit.glyph(o.badge, { ImageColor3 = if o.badge == "play" then C.sheet else C.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.55, 0.55), Parent = b })
					end
				end
			end
			if o.ribbon then
				local rb = Kit.new("Frame", { BackgroundColor3 = o.ribbonColor or C.hazard, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = at(pw - 16, 0), AutomaticSize = Enum.AutomaticSize.XY, ZIndex = face.ZIndex + 2, Parent = face })
				Kit.corner(4).Parent = rb
				Kit.padding(ts(4), ts(10)).Parent = rb
				stencil({ Text = o.ribbon, TextSize = ts(19), TextColor3 = if o.ribbonColor then C.sheet else C.inkBlack, ZIndex = rb.ZIndex, Parent = rb })
			end
			local tx = 10 + pic + 14
			local tw = pw - tx - 14
			outline(stencil({ Text = o.title, TextSize = ts(if big then 44 else 30), TextColor3 = WHITE, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, Position = at(tx, if big then 22 else 14), Size = sz(tw, if big then 48 else 34), Parent = face }))
			Kit.new("TextLabel", { BackgroundTransparency = 1, Text = o.line, FontFace = F.bodyBold, TextSize = ts(if big then 21 else 18), TextColor3 = WHITE, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = at(tx, if big then 74 else 50), Size = sz(tw, 48), Parent = face })
			local plateH = if big then 58 else 46
			plate(face, tx + tw / 2, ph - 14 - plateH / 2, tw, plateH, o.price, o.onBuy)
			-- Gift it to a friend (Bruno, 2026-11-23): a chip over the picture.
			if o.gift then
				local giftKey = o.gift
				local chip = Kit.new("TextButton", { Name = "Gift", Text = "", AutoButtonColor = false, BackgroundColor3 = C.stamp, BorderSizePixel = 0, Position = at(14, ph - 44), Size = sz(96, 32), ZIndex = face.ZIndex + 3, Parent = face })
				Kit.corner(5).Parent = chip
				Kit.stroke(Color3.fromHex("#6E1A14"), 2, 0).Parent = chip
				local cr = P.row(chip, ts(5))
				Kit.glyph("gift", { ImageColor3 = C.sheet, Size = sz(18, 18), LayoutOrder = 1, ZIndex = chip.ZIndex, Parent = cr })
				stencil({ Text = "GIFT", TextSize = ts(18), TextColor3 = C.sheet, LayoutOrder = 2, ZIndex = chip.ZIndex, Parent = cr })
				Dossier.clicky(chip, 1.06)
				chip.Activated:Connect(function()
					Dossier.click()
					GiftPicker.open(w.window, giftKey, ctx.request, ctx.prompt, k)
				end)
			end
			if o.onBuy then
				local busy = false
				cell.Activated:Connect(function()
					if busy then
						return
					end
					busy = true
					Dossier.click()
					;(o.onBuy :: () -> ())()
					busy = false
				end)
				Dossier.liftTile(cell, face, shade, 6)
			end
		end

		local lx = if phone then 0 else boxW + GAP + 6
		local lw = innerW - lx
		local top = 18
		local bigH, smallH = 228, 150
		local pw2 = (lw - GAP) / 2
		for i, o in packs do
			panel(o, lx + (i - 1) * (pw2 + GAP), top, pw2, bigH)
		end
		local y2 = top + bigH + GAP + 6
		local n = #singles
		local perRow = if phone then math.min(n, 2) else n
		local pw3 = (lw - (perRow - 1) * GAP) / math.max(perRow, 1)
		for i, o in singles do
			local col, rowN = (i - 1) % math.max(perRow, 1), (i - 1) // math.max(perRow, 1)
			panel(o, lx + col * (pw3 + GAP), y2 + rowN * (smallH + GAP + 6), pw3, smallH)
		end
		local rows = math.max(1, math.ceil(n / math.max(perRow, 1)))
		local rh = y2 + rows * smallH + (rows - 1) * (GAP + 6) - top
		if phone then
			-- The odds strip under the offers.
			boxHost.Position = at(0, top + rh + 16)
			rh += boxH + 16
		end
		-- The collection lives in the Locker.
		local total, haveN = 0, 0
		for _, c in Catalog.cosmetics() do
			if Catalog.crateable(c) then
				total += 1
				if mine[c.id] then
					haveN += 1
				end
			end
		end
		typed({ Text = `Your collection: {haveN} of {total}`, TextSize = ts(19), TextColor3 = DIM, Position = at(lx, top + rh + 26), Parent = s })
		local lock, lr = P.manilaButton(w, s, lx + lw - 130, top + rh + 38, 260, 48)
		stencil({ Text = "OPEN LOCKER", TextSize = ts(30), LayoutOrder = 1, Parent = lr })
		lock.Activated:Connect(ctx.openLocker)
		finish(s, math.max(boxH + 8, top + rh + 70))
		return s
	end

	-- Flags ----------------------------------------------------------------------------------

	local function flagsPage(): ScrollingFrame
		local s = page("Flags")
		local offers = FlagShop.offers(os.time())
		local cols, tw = columns(if phone then 175 else 180)
		local picH = math.round((tw - 20) * 0.62)
		local th = 12 + picH + 116
		local y = 0
		local function tile(id: string, i: number)
			local item = Catalog.get(id)
			if item == nil then
				return
			end
			local cell = Kit.new("TextButton", { Name = id, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = at(((i - 1) % cols) * (tw + GAP), y + ((i - 1) // cols) * (th + GAP)), Size = sz(tw, th), Parent = s })
			local shade = Kit.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.68, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 3, 0.5, 6), Size = UDim2.new(1, -10, 1, -12), Parent = cell })
			Kit.corner(8).Parent = shade
			local rarity: string = item.rarity
			local tone = TONES[rarity] or TONES.common
			local face = DarkWindow.tile(cell, tone[1], tone[2], GLOW[rarity], k)
			age(Art.flag(id, { Position = at(10, 12), Size = sz(tw - 20, picH), Parent = face }))
			outline(stencil({ Text = item.name, TextColor3 = WHITE, TextSize = ts(26), TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 0), Position = at(tw / 2, picH + 16), Size = sz(tw - 12, 28), Parent = face }))
			stencil({ Text = string.upper(Catalog.RARITY_NAME[item.rarity]), TextSize = ts(18), TextColor3 = tone[1], AnchorPoint = Vector2.new(0.5, 0), Position = at(tw / 2, picH + 44), Parent = face })
			local product = Catalog.product(Catalog.flagProduct(item.rarity)) :: Catalog.Product
			local owned = mine[id] == true
			local function buy()
				if owned then
					return
				end
				local r = ctx.request({ op = "chooseFlag", id = id })
				if r and r.ok then
					ctx.prompt(product.key)
				end
			end
			plate(face, tw / 2, th - 28, tw - 20, 42, if owned then { kind = "owned" } else { kind = "robux", amount = product.price }, if owned then nil else buy)
			cell.Activated:Connect(buy)
			Dossier.liftTile(cell, face, shade, 6)
		end
		local function timer(label: TextLabel, endsAt: number, prefix: string)
			local function paint()
				local left = endsAt - os.time()
				label.Text = `{prefix} {if left > 86400 then Kit.days(left) else Kit.clock(math.max(0, left))}`
			end
			paint()
			table.insert(tickers, paint)
		end
		local function rows(list: { string })
			for i, id in list do
				tile(id, i)
			end
			y += ((#list + cols - 1) // cols) * (th + GAP) + 8
		end
		if offers.event then
			y = heading(s, y, string.upper(offers.event.name), "limited")
			local t = stencil({ Text = "", TextSize = ts(24), TextColor3 = C.hazard, AnchorPoint = Vector2.new(1, 0), Position = at(innerW, y - 36), Parent = s })
			timer(t, offers.event.endsAt, "ENDS IN")
			rows(offers.event.flags)
		end
		y = heading(s, y, "TODAY'S FLAGS", "4 new every day")
		local t = stencil({ Text = "", TextSize = ts(24), TextColor3 = C.hazard, AnchorPoint = Vector2.new(1, 0), Position = at(innerW, y - 36), Parent = s })
		timer(t, offers.nextDailyAt, "NEW IN")
		rows(offers.daily)
		typed({ Text = "Flags from OpenFront (CC BY-SA 4.0) and our own", TextColor3 = DIM, TextSize = ts(15), AnchorPoint = Vector2.new(1, 0), Position = at(innerW, y), Parent = s })
		finish(s, y + 24)
		return s
	end

	-- A wide offer card: a square picture at the left, name, line, price.
	local function offerCard(parent: Instance, x: number, y: number, ow: number, oh: number, spec: { name: string, does: string, picture: (Frame) -> GuiObject, price: { [string]: any }, onBuy: (() -> ())?, onOpen: (() -> ())? })
		local cell = Kit.new("TextButton", { Name = spec.name, Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = at(x, y), Size = sz(ow, oh), Parent = parent })
		local face = DarkWindow.tile(cell, TONES.navy[1], TONES.navy[2], nil, k)
		local ps = oh - 24
		local frame = Kit.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Position = at(12, 12), Size = sz(ps, ps), Parent = face })
		age(spec.picture(frame))
		local tx = 12 + ps + 14
		local tw = ow - tx - 12
		outline(stencil({ Text = string.upper(spec.name), TextSize = ts(28), TextColor3 = WHITE, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, Position = at(tx, 10), Size = sz(tw, 32), Parent = face }))
		Kit.new("TextLabel", { BackgroundTransparency = 1, Text = spec.does, FontFace = F.bodyBold, TextSize = ts(17), TextColor3 = WHITE, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = at(tx, 44), Size = sz(tw, oh - 44 - 58), Parent = face })
		plate(face, tx + tw / 2, oh - 34, tw, 46, spec.price, spec.onBuy)
		if spec.onOpen then
			cell.Activated:Connect(spec.onOpen)
		end
		return cell
	end

	-- Featured -------------------------------------------------------------------------------

	local function featuredPage(): ScrollingFrame
		local s = page("Featured")
		local y = 0
		local heroH = 290
		local starter = view.starter
		if starter == "ready" or starter == "active" then
			-- The starter pack as the hero: three pictures, the price struck
			-- through, the clock (its 48 hours start when it is first opened).
			local hero = Kit.new("TextButton", { Name = "Hero", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = at(0, 4), Size = sz(innerW, heroH), Parent = s })
			DarkWindow.tile(hero, TONES.gold[1], TONES.gold[2], GLOW.legendary, k)
			local picW = math.min(170, (innerW * 0.55 - 40) / 3)
			for i, id in Catalog.STARTER.items do
				local fx = 18 + (i - 1) * (picW + 12)
				local frame = Kit.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Position = at(fx, 30), Size = sz(picW, picW), Rotation = (i - 2) * 1.5, ZIndex = 3, Parent = hero })
				age(Art.card(id, { Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8), Parent = frame }))
				local wpn = Catalog.weapon(id)
				outline(stencil({ Text = string.upper(if wpn then wpn.name else id), TextSize = ts(20), TextColor3 = WHITE, ZIndex = 3, AnchorPoint = Vector2.new(0.5, 0), Position = at(fx + picW / 2, 30 + picW + 10), Parent = hero }))
			end
			local ix = 18 + 3 * (picW + 12) + 16
			local iw = innerW - ix - 18
			local kicker = typed({ Text = "", TextSize = ts(17), TextColor3 = C.stamp, ZIndex = 3, Position = at(ix, 22), Parent = hero })
			local drawnAt = os.clock()
			local function paintKicker()
				if starter == "active" then
					kicker.Text = `ONCE PER PLAYER · ENDS IN {Kit.clock(math.max(0, (view.starterLeft or 0) - (os.clock() - drawnAt)))}`
				else
					kicker.Text = "ONCE PER PLAYER · FOR 48 HOURS"
				end
			end
			paintKicker()
			table.insert(tickers, paintKicker)
			stencil({ Text = "STARTER PACK", TextSize = ts(56), TextColor3 = BROWN, ZIndex = 3, Position = at(ix, 46), Parent = hero })
			Kit.new("TextLabel", { BackgroundTransparency = 1, ZIndex = 3, Text = "Two big bombs for good, and every match pays double stars.", FontFace = F.bodyBold, TextSize = ts(20), TextColor3 = BROWN, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = at(ix, 112), Size = sz(iw, 52), Parent = hero })
			local product = Catalog.product(Catalog.STARTER.product) :: Catalog.Product
			stencil({ Text = `SEPARATELY <s>{Catalog.STARTER.regular}</s>`, RichText = true, TextSize = ts(22), TextColor3 = BROWN, ZIndex = 3, Position = at(ix, 170), Parent = hero })
			plate(hero, ix + iw / 2, heroH - 50, iw, 60, { kind = "robux", amount = product.price }, ctx.openStarter)
			hero.Activated:Connect(ctx.openStarter)
		elseif deal then
			-- No starter pack: today's deal is the hero.
			local hw = math.min(innerW, 520)
			weaponCard(s, 0, 4, hw, deal, "strike")
			heroH = cardHeight(hw)
		else
			heroH = -14
		end
		y = 4 + heroH + 18
		-- The offers under it, three to a row.
		type Offer = { name: string, does: string, picture: (Frame) -> GuiObject, price: { [string]: any }, onBuy: (() -> ())?, onOpen: (() -> ())? }
		local offers: { Offer } = {}
		if deal and (starter == "ready" or starter == "active") then
			local price, onBuy = weaponPrice(deal)
			table.insert(offers, { name = "Today's deal", does = `{deal.name}, {math.round(Catalog.DEAL.off * 100)}% off until 00:00 UTC`, picture = function(f)
				return Art.card(deal.id, { Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6), Parent = f })
			end, price = price, onBuy = onBuy, onOpen = function()
				openSheet(deal)
			end })
		end
		if Catalog.SUBSCRIPTION.id ~= "" and view.general ~= true then
			table.insert(offers, { name = "Conquest General", does = "A crate a day, +50% stars, the month's skin", picture = function(f)
				return Art.card("w_general", { Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6), Parent = f })
			end, price = { kind = "robux", amount = Catalog.SUBSCRIPTION.robux }, onBuy = ctx.openGeneral, onOpen = ctx.openGeneral })
		end
		local flagOffers = FlagShop.offers(os.time())
		if flagOffers.event and flagOffers.event.flags[1] then
			local first = flagOffers.event.flags[1]
			table.insert(offers, { name = `{flagOffers.event.name} flags`, does = `{#flagOffers.event.flags} limited flags, gone in {Kit.days(flagOffers.event.endsAt - os.time())}`, picture = function(f)
				return Art.flag(first, { Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6), Parent = f })
			end, price = { kind = "go", text = "SEE ALL", glyph = "flag" }, onBuy = function()
				memo.switchTo("flags")
			end, onOpen = function()
				memo.switchTo("flags")
			end })
		end
		table.insert(offers, { name = "5 crates", does = "Skins and flags you don't own yet", picture = function(f)
			return Dossier.art("crate_wood", { Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -12), Parent = f }) :: any
		end, price = { kind = "robux", amount = (Catalog.product("crate5") :: Catalog.Product).price }, onBuy = function()
			ctx.prompt("crate5")
		end })
		local cols = if innerW > 900 then 3 else 2
		local ow = (innerW - (cols - 1) * GAP) / cols
		local oh = 150
		for i, o in offers do
			offerCard(s, ((i - 1) % cols) * (ow + GAP), y + ((i - 1) // cols) * (oh + GAP), ow, oh, o)
		end
		y += ((#offers + cols - 1) // cols) * (oh + GAP)
		finish(s, y)
		return s
	end

	-- Boosts ---------------------------------------------------------------------------------

	-- A boost's picture: its icon on a dark print (no photos for these yet).
	local function glyphPicture(glyph: string): (Frame) -> GuiObject
		return function(frame: Frame): GuiObject
			local back = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#2A2E22"), BorderSizePixel = 0, Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8), Parent = frame })
			Kit.glyph(glyph, { ImageColor3 = C.hazard, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.42, 0.66), Parent = back })
			return back
		end
	end

	local function boostsPage(): ScrollingFrame
		local s = page("Boosts")
		local cols, cw = columns(230)
		local ch = cardHeight(cw)
		local y = heading(s, 0, "STARS", "earn them faster")
		local i = 0
		for _, wpn in { Catalog.weapon("b_double"), Catalog.weapon("w_general") } do
			if wpn and (not wpn.subscription or Catalog.SUBSCRIPTION.id ~= "") then
				local price, onBuy = weaponPrice(wpn)
				local id = wpn.id
				card(s, (i % cols) * (cw + GAP), y, cw, {
					tone = "gold",
					name = wpn.name,
					does = Shop.DOES[id] or wpn.desc,
					picture = function(frame)
						return Art.card(id, { Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8), Parent = frame })
					end,
					price = price,
					onBuy = onBuy,
					onOpen = if wpn.subscription then ctx.openGeneral else nil,
				})
				i += 1
			end
		end
		-- Star Boost: an hour of double stars, shown with what's left.
		local left = view.starBoostLeft or 0
		card(s, (i % cols) * (cw + GAP), y, cw, {
			name = "Star Boost",
			tone = "stars",
			does = if left > 0 then `Double stars: {math.ceil(left / 60)} min of play left` else "Double stars for an hour of play",
			picture = glyphPicture("star"),
			price = { kind = "robux", amount = (Catalog.product("starBoost") :: Catalog.Product).price },
			onBuy = function()
				ctx.prompt("starBoost")
			end,
		})
		i += 1
		y += ((i + cols - 1) // cols) * (ch + GAP)
		-- The in-match boosts: bought here, kept for a match; offered there
		-- when they help.
		y = heading(s, y, "IN A MATCH", "bought now, kept until you use one")
		local boosts = view.boosts or {}
		local IN_MATCH = {
			{ key = "warChest", name = "War Chest", glyph = "gold", does = "Gold now: three minutes of your income" },
			{ key = "rearm", name = "Instant Rearm", glyph = "reload", does = "Every silo and launcher reloads at once" },
			{ key = "secondSpawn", name = "Second Spawn", glyph = "flag", does = "Wiped out early? Start again where you pick" },
		}
		for j, b in IN_MATCH do
			local have = boosts[b.key] or 0
			card(s, ((j - 1) % cols) * (cw + GAP), y + ((j - 1) // cols) * (ch + GAP), cw, {
				name = b.name,
				tone = "navy",
				does = b.does,
				picture = glyphPicture(b.glyph),
				foot = if have > 0 then `YOU HAVE {have}` else nil,
				price = { kind = "robux", amount = (Catalog.product(b.key) :: Catalog.Product).price },
				onBuy = function()
					ctx.prompt(b.key)
				end,
			})
		end
		y += ((#IN_MATCH + cols - 1) // cols) * (ch + GAP)
		finish(s, y)
		return s
	end

	-- The rail and switching ------------------------------------------------------------------

	local builders: { [string]: () -> ScrollingFrame } = { featured = featuredPage, weapons = weaponsPage, crates = cratesPage, flags = flagsPage, boosts = boostsPage }
	local pages: { [string]: ScrollingFrame? } = {}
	local setters: { [string]: (boolean) -> () } = {}
	local current: string? = nil
	local function show(tab: string)
		if current == tab then
			return
		end
		local was = if current then pages[current] else nil
		if current and was then
			memo.scroll[current] = was.CanvasPosition.Y
			was.Visible = false
		end
		current = tab
		memo.tab = tab
		local pg = pages[tab]
		if pg == nil then
			pg = builders[tab]()
			pages[tab] = pg
		end
		assert(pg, "a page")
		pg.Visible = true
		pg.CanvasPosition = Vector2.new(0, memo.scroll[tab] or 0)
		for name, set in setters do
			set(name == tab)
		end
		if subline then
			subline.Text = TAB_LINE[tab] or ""
		end
		if ctx.shelf then
			ctx.shelf(tab)
		end
	end
	memo.switchTo = show

	local tags: { [string]: { text: string, color: Color3 } } = {}
	if view.starter == "ready" or view.starter == "active" then
		local product = Catalog.product(Catalog.STARTER.product) :: Catalog.Product
		tags.featured = { text = `-{math.round((1 - product.price / Catalog.STARTER.regular) * 100)}%`, color = C.stamp }
	end
	if deal then
		tags.weapons = { text = "DEAL", color = C.stamp }
	end
	if view.freeCrate or ctx.adReady then
		tags.crates = { text = "FREE", color = P.GREEN }
	end
	if FlagShop.offers(os.time()).event then
		tags.flags = { text = "LIMITED", color = C.stamp }
	end
	for i, tab in Shop.TABS do
		local ty = y0 + 10 + (i - 1) * (64 + 12)
		local b = Kit.new("TextButton", { Name = "Tab_" .. tab, Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(x0 + PAD + RAIL_W / 2, ty + 32), Size = sz(RAIL_W, 60), Parent = w.body })
		Kit.corner(ts(10)).Parent = b
		local grad = Kit.new("UIGradient", { Rotation = 90, Parent = b })
		local edge = Kit.stroke(DarkWindow.GOLD, 2, 0.6)
		edge.Parent = b
		local r = Kit.new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = b })
		Kit.list(Enum.FillDirection.Horizontal, ts(8), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = r
		local icon = Kit.glyph(TAB_ICON[tab][2], { Size = sz(24, 24), LayoutOrder = 1, Parent = r })
		local label = stencil({ Text = TAB_TITLE[tab], TextSize = ts(if phone then 24 else 22), LayoutOrder = 2, Parent = r })
		setters[tab] = function(on: boolean)
			grad.Color = if on then ColorSequence.new(Color3.fromHex("#FFE58A"), Color3.fromHex("#E6A817")) else ColorSequence.new(Color3.fromHex("#2A3A32"), Color3.fromHex("#18241E"))
			edge.Transparency = if on then 0 else 0.6
			icon.ImageColor3 = if on then BROWN else DarkWindow.GOLD
			label.TextColor3 = if on then BROWN else WHITE
		end
		Dossier.clicky(b, 1.05)
		b.Activated:Connect(function()
			show(tab)
		end)
		local tag = tags[tab]
		if tag then
			local t = Kit.new("Frame", { Name = "Tag", BackgroundColor3 = tag.color, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, ts(8), 0, ts(2)), AutomaticSize = Enum.AutomaticSize.XY, Rotation = 4, ZIndex = b.ZIndex + 3, Parent = b })
			Kit.corner(3).Parent = t
			Kit.padding(ts(2), ts(6)).Parent = t
			stencil({ Text = tag.text, TextSize = ts(16), TextColor3 = C.sheet, ZIndex = t.ZIndex, Parent = t })
		end
	end
	local first = ctx.tab or memo.tab or "featured"
	if builders[first] == nil then
		first = "featured"
	end
	-- (Featured with nothing to feature opens on Weapons.)
	if first == "featured" and not (view.starter == "ready" or view.starter == "active") and deal == nil then
		first = "weapons"
	end
	show(first)
	return (w :: any) :: Kit.Modal
end

return Shop
