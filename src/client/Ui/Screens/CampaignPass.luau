--!strict
-- The Campaign Pass window (Bruno, 2026-11-23: option B "Operation road",
-- "make the Campaign window look exactly the same" as the mockup; season 1
-- "OPERATION IRON ROAD"; Store/Pass). A dark window whose header is the
-- season's banner (bright orange clouds, the two-line name, your tier and
-- XP, the red X), then a road of 30 tier markers zigzagging across it, lit
-- dashed gold up to your tier, with the premium prize above each marker and
-- the free one below (tiles coloured by what they give; exclusives glow,
-- claimable tiles pulse), and a slim strip at the bottom: today's missions
-- as chips (a WEEK tab for this week's) and the PREMIUM button. Laid out
-- in a 1240 x 720 reference, scaled to the screen (desktop and phone).
-- Nothing is granted here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)
local Pass = require(Shared.Store.Pass)

local Art = require(script.Parent.Parent.Art)
local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)
local Shops = require(script.Parent.Shops)
local GiftPicker = require(script.Parent.GiftPicker)

local C = Theme.color
local F = Theme.font
local P = Shops.parts
local A = UiAssets.dossier
local stencil = Dossier.stencil
local typed = Dossier.typed

local CampaignPass = {}

export type Ctx = {
	view: any,
	request: (req: { [string]: any }) -> { [string]: any }?,
	prompt: (productKey: string) -> (),
	-- What a claim gave: crate items play the crate opening, an item its reveal.
	got: (items: { string }, fromCrate: boolean) -> (),
	memo: { [string]: any }?,
}

local REF_W, REF_H = 1240, 720
local BANNER_H = 250
local STRIP_Y, STRIP_H = 626, 84
local STEP = 196 -- a tier column
local TILE_W, TILE_H = 132, 118
local NODE = 46
local ZIG = 34 -- the road's swing above and below its middle

local BG = Color3.fromHex("#0F1A14")
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local GOLD = Color3.fromHex("#FFD75E")
local ROAD = Color3.fromHex("#6B5A3A")

-- Tile colours by what a reward is (light, dark) and the glow of the best.
local TONES: { [string]: { Color3 } } = {
	legendary = { Color3.fromHex("#FFF2B3"), Color3.fromHex("#A06A00") },
	epic = { Color3.fromHex("#E4CFFF"), Color3.fromHex("#4A1F99") },
	rare = { Color3.fromHex("#CFE6FF"), Color3.fromHex("#1C4B99") },
	title = { Color3.fromHex("#FFB4A6"), Color3.fromHex("#7A1D0F") },
	crate = { Color3.fromHex("#FFCF94"), Color3.fromHex("#7A3D0A") },
	stars = { Color3.fromHex("#9FF2E5"), Color3.fromHex("#0F5F56") },
}
local GLOW: { [string]: Color3 } = {
	legendary = Color3.fromHex("#FFC83C"),
	epic = Color3.fromHex("#A064FF"),
	title = Color3.fromHex("#FF7A5C"),
}
local RANK = { common = 1, rare = 2, epic = 3, legendary = 4 }

local function toneOf(r: Pass.Reward): (string, Catalog.Cosmetic?)
	local best: Catalog.Cosmetic? = nil
	local items: { string } = r.items or {}
	for _, id in items do
		local c = Catalog.get(id)
		if c and (best == nil or RANK[c.rarity] > RANK[(best :: Catalog.Cosmetic).rarity]) then
			best = c
		end
	end
	if best then
		if best.kind == "title" and best.rarity ~= "legendary" then
			return "title", best
		end
		local rarity: string = best.rarity
		return if rarity == "common" then "rare" else rarity, best
	end
	return if (r.crates or 0) > 0 then "crate" else "stars", nil
end

local function caption(r: Pass.Reward, best: Catalog.Cosmetic?): string
	if best then
		if best.kind == "title" then
			return if r.stars then "TITLE + STARS" else "TITLE"
		end
		local extra = #(r.items or {}) - 1
		return string.upper(best.name) .. (if extra > 0 then ` +{extra}` else "")
	elseif (r.crates or 0) > 0 then
		return if r.crates == 1 then "1 CRATE" else `{r.crates} CRATES`
	end
	return Kit.commas(r.stars or 0)
end

function CampaignPass.open(host: Instance, ctx: Ctx): Kit.Modal
	local view = ctx.view
	local pass = view.pass
	local memo: { [string]: any } = ctx.memo or {}
	local phone = Dossier.phone()
	-- The reference fits the screen: nearly all of a phone, most of a desktop.
	local r = Kit.root
	local k = math.min(r.width * (if phone then 0.99 else 0.84) / REF_W, r.height * (if phone then 0.98 else 0.86) / REF_H)
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
	local window = Kit.new("Frame", { Name = "Window", BackgroundColor3 = BG, BorderSizePixel = 0, ClipsDescendants = true, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz(REF_W, REF_H), Parent = root }) :: Frame
	Kit.corner(ts(16)).Parent = window
	local edge = Kit.new("Frame", { Name = "Edge", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = sz(REF_W, REF_H), ZIndex = 20, Parent = root })
	Kit.corner(ts(16)).Parent = edge
	Kit.stroke(Color3.fromHex("#0B1218"), math.max(3, ts(6)), 0).Parent = edge
	local header = Kit.new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = window }) :: Frame
	local body = Kit.new("Frame", { Name = "Body", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = window }) :: Frame
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		Kit.hideTip()
		root:Destroy()
	end
	local modal = { root = root, window = window, header = header, body = body, close = close }

	local tickers: { () -> () } = {}
	local pulses: { UIStroke } = {}
	local acc, clock = 0, 0
	local conn = RunService.Heartbeat:Connect(function(dt)
		clock += dt
		local a = 0.5 + 0.5 * math.sin(clock * 4)
		for _, s in pulses do
			s.Color = WHITE:Lerp(GOLD, a)
		end
		acc += dt
		if acc >= 1 then
			acc = 0
			for _, f in tickers do
				f()
			end
		end
	end)
	root.Destroying:Connect(function()
		conn:Disconnect()
	end)
	Dossier.closeRed(header, at(REF_W - 40, 40), sz(56, 56), close)

	if pass == nil then
		local _, starts = Pass.season(os.time())
		typed({ Text = `The first season starts in {Kit.days(math.max(0, starts - os.time()))}.`, TextSize = ts(28), TextColor3 = WHITE, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = body })
		return (modal :: any) :: Kit.Modal
	end
	local tier, into = Pass.tier(pass.xp)
	local claimed = { free = {} :: { [number]: boolean }, premium = {} :: { [number]: boolean } }
	for _, t in pass.free do
		claimed.free[t] = true
	end
	for _, t in pass.paid do
		claimed.premium[t] = true
	end

	-- The banner: the season's photo, washed orange to the right and dark to
	-- the left, fading into the window at its foot.
	local banner = Kit.new("Frame", { Name = "Banner", BackgroundColor3 = Color3.fromHex("#2A0E05"), BorderSizePixel = 0, ClipsDescendants = true, Size = sz(REF_W, BANNER_H), Parent = body })
	if (A.arsenal_mega or "") ~= "" then
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = A.arsenal_mega, ScaleType = Enum.ScaleType.Crop, Size = UDim2.fromScale(1, 1), Parent = banner })
	end
	local ember = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#FF5A12"), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = banner })
	Kit.new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.85), NumberSequenceKeypoint.new(0.5, 0.45), NumberSequenceKeypoint.new(1, 0.35) }), Parent = ember })
	local shade = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#140804"), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = banner })
	Kit.new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(0.5, 0.6), NumberSequenceKeypoint.new(1, 1) }), Parent = shade })
	local foot = Kit.new("Frame", { BackgroundColor3 = BG, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = banner })
	Kit.new("UIGradient", { Rotation = 90, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.55, 1), NumberSequenceKeypoint.new(1, 0) }), Parent = foot })
	local kick = typed({ Text = "", TextSize = ts(22), TextColor3 = Color3.fromHex("#FFB36B"), Position = at(36, 30), ZIndex = 3, Parent = banner })
	local function paintKick()
		kick.Text = `Season {pass.season} · ends in {math.max(1, math.ceil((pass.endsAt - os.time()) / 86400))} days`
	end
	paintKick()
	table.insert(tickers, paintKick)
	local words = string.split(Pass.name(pass.season), " ")
	local line1 = table.remove(words, 1) or ""
	local title = stencil({ Text = `{line1}\n{table.concat(words, " ")}`, TextSize = ts(84), LineHeight = 0.82, TextColor3 = WHITE, Position = at(32, 62), ZIndex = 3, Parent = banner })
	Kit.new("UIStroke", { Color = BLACK, Thickness = math.max(1, ts(2.5)), Transparency = 0.45, Parent = title })
	local sub = Kit.new("TextLabel", { BackgroundTransparency = 1, Text = "30 tiers. Every match moves you along the road.", FontFace = F.bodyBold, TextSize = ts(20), TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, Position = at(36, 194), Size = sz(600, 26), ZIndex = 3, Parent = banner })
	Kit.new("UIStroke", { Color = BLACK, Thickness = 1, Transparency = 0.5, Parent = sub })
	-- Your tier and XP at the right (clear of the X), and the gift.
	local rx = REF_W - 96
	local tierText = stencil({ Text = `TIER {tier}`, TextSize = ts(66), TextColor3 = WHITE, AnchorPoint = Vector2.new(1, 0), Position = at(rx, 26), ZIndex = 3, Parent = banner })
	Kit.new("UIStroke", { Color = BLACK, Thickness = math.max(1, ts(2)), Transparency = 0.5, Parent = tierText })
	local bar = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#2A1A10"), BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = at(rx, 108), Size = sz(300, 20), ZIndex = 3, Parent = banner })
	Kit.corner(ts(10)).Parent = bar
	local fill = Kit.new("Frame", { BackgroundColor3 = GOLD, BorderSizePixel = 0, Size = UDim2.fromScale(math.clamp(into / Pass.XP_PER_TIER, 0.03, 1), 1), ZIndex = 3, Parent = bar })
	Kit.corner(ts(10)).Parent = fill
	Kit.new("UIGradient", { Color = ColorSequence.new(Color3.fromHex("#FFE58A"), Color3.fromHex("#F0B429")), Parent = fill })
	local xpLine = Kit.new("TextLabel", { BackgroundTransparency = 1, Text = if tier >= Pass.TIERS then "Every tier reached" else `{Kit.commas(into)} / {Kit.commas(Pass.XP_PER_TIER)} XP to tier {tier + 1}`, FontFace = F.bodyBold, TextSize = ts(18), TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = at(rx, 134), Size = sz(300, 24), ZIndex = 3, Parent = banner })
	Kit.new("UIStroke", { Color = BLACK, Thickness = 1, Transparency = 0.5, Parent = xpLine })
	local gift = Kit.new("TextButton", { Name = "GiftPass", Text = "", AutoButtonColor = false, BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = at(rx, 172), Size = sz(200, 36), ZIndex = 3, Parent = banner })
	Kit.corner(ts(6)).Parent = gift
	Kit.stroke(Color3.fromHex("#6E1A14"), 2, 0).Parent = gift
	local gr = P.row(gift, ts(6))
	Kit.glyph("gift", { ImageColor3 = WHITE, Size = sz(20, 20), LayoutOrder = 1, ZIndex = 3, Parent = gr })
	stencil({ Text = "GIFT THE PASS", TextSize = ts(20), TextColor3 = WHITE, LayoutOrder = 2, ZIndex = 3, Parent = gr })
	Dossier.clicky(gift, 1.05)
	gift.Activated:Connect(function()
		Dossier.click()
		GiftPicker.open(window, "giftPass", ctx.request, ctx.prompt, k)
	end)

	-- The road: it starts 30 above the banner's foot (the tiles overlap its
	-- fade, as in the mockup) and ends at the strip.
	local roadTop = BANNER_H - 30
	local roadH = STRIP_Y - roadTop
	local mid = roadH / 2 + 4
	local road = Kit.scroll({ Name = "Road", Position = at(0, roadTop), Size = sz(REF_W, roadH), ScrollingDirection = Enum.ScrollingDirection.X, AutomaticCanvasSize = Enum.AutomaticSize.None, CanvasSize = UDim2.fromOffset(math.round((Pass.TIERS * STEP + 140) * k), 0), ScrollBarThickness = math.max(4, ts(7)), ScrollBarImageColor3 = Color3.fromHex("#6B5A3A"), ZIndex = 3, Parent = body })
	local function nodeAt(t: number): (number, number)
		return 110 + (t - 1) * STEP, mid + (if t % 2 == 1 then ZIG else -ZIG)
	end
	local function segment(x1: number, y1: number, x2: number, y2: number, lit: boolean)
		local dx, dy = x2 - x1, y2 - y1
		local len = math.sqrt(dx * dx + dy * dy)
		local rot = math.deg(math.atan2(dy, dx))
		local s = Kit.new("Frame", { BackgroundColor3 = if lit then Color3.fromHex("#8A6A2A") else ROAD, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at((x1 + x2) / 2, (y1 + y2) / 2), Size = sz(len + 8, 20), Rotation = rot, ZIndex = 3, Parent = road })
		Kit.corner(ts(6)).Parent = s
		if lit then
			-- The lit stretch: gold dashes down its middle.
			local n = math.max(1, math.floor(len / 26))
			for i = 0, n - 1 do
				local f = (i + 0.5) / n
				Kit.new("Frame", { BackgroundColor3 = GOLD, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(x1 + dx * f, y1 + dy * f), Size = sz(15, 8), Rotation = rot, ZIndex = 4, Parent = road })
			end
		end
	end
	local px, py = 0, mid
	for t = 1, Pass.TIERS do
		local nx, ny = nodeAt(t)
		segment(px, py, nx, ny, tier >= t)
		px, py = nx, ny
	end
	segment(px, py, px + 140, mid, false)

	local busy = false
	local function claim(track: string, t: number)
		if busy then
			return
		end
		busy = true
		local reward = Pass.reward(track, t)
		local res = ctx.request({ op = "passClaim", track = track, tier = t })
		busy = false
		if res and res.ok and res.items and #res.items > 0 and reward then
			ctx.got(res.items, (reward.crates or 0) > 0 and #(reward.items or {}) == 0)
		end
	end

	local function tile(track: string, t: number, cx: number, cy: number)
		local reward = Pass.reward(track, t) :: Pass.Reward
		local tone, best = toneOf(reward)
		local colors = TONES[tone]
		local done = claimed[track][t] == true
		local locked = track == "premium" and not pass.premium
		local can = tier >= t and not done and not locked
		local cell = Kit.new("TextButton", { Name = `{track}{t}`, Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(cx, cy), Size = sz(TILE_W, TILE_H), ZIndex = 5, Parent = road })
		Kit.corner(ts(12)).Parent = cell
		Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(colors[1], colors[2]), Parent = cell })
		local glow = GLOW[tone]
		local stroke = Kit.stroke(if can then GOLD elseif glow then glow else Color3.fromHex("#FFF6DA"), if can or glow then math.max(2, ts(4)) else 1, if can or glow then 0 else 0.5)
		stroke.Parent = cell
		if can then
			table.insert(pulses, stroke)
		end
		local picH = TILE_H * 0.58
		if best and best.kind == "title" then
			local plate = Kit.new("Frame", { BackgroundColor3 = BLACK, BackgroundTransparency = 0.6, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, ts(12 + picH / 2)), Size = sz(TILE_W - 28, picH * 0.5), ZIndex = 5, Parent = cell })
			Kit.corner(ts(6)).Parent = plate
			stencil({ Text = string.upper(best.name), TextSize = ts(if #best.name > 7 then 22 else 26), TextColor3 = Color3.fromHex("#FFE0D4"), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 5, Parent = plate })
		elseif best then
			local holder = Kit.new("Frame", { BackgroundColor3 = WHITE, BackgroundTransparency = if best.kind == "skin" then 0 else 1, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, ts(10)), Size = sz(TILE_W * 0.76, picH), ZIndex = 5, Parent = cell })
			Kit.corner(ts(6)).Parent = holder
			local pic = Art.cosmetic(best :: any, { Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6), Parent = holder })
			pic.ZIndex = 5
		elseif (reward.crates or 0) > 0 then
			Dossier.art(if (reward.crates or 0) >= 5 then "crate_pile5" elseif (reward.crates or 0) >= 2 then "crate_pile3" else "crate_wood", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, ts(8)), Size = sz(TILE_W * 0.72, picH), ZIndex = 5, Parent = cell })
		else
			Kit.glyph("star", { ImageColor3 = WHITE, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, ts(14)), Size = sz(picH * 0.75, picH * 0.75), ZIndex = 5, Parent = cell })
		end
		local label = stencil({ Text = caption(reward, best), TextSize = ts(18), TextColor3 = WHITE, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -ts(6)), Size = UDim2.new(1, -ts(8), 0, ts(22)), ZIndex = 5, Parent = cell })
		Kit.new("UIStroke", { Color = BLACK, Thickness = 1.5, Transparency = 0.35, Parent = label })
		if done then
			local veil = Kit.new("Frame", { BackgroundColor3 = BLACK, BackgroundTransparency = 0.5, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 6, Parent = cell })
			Kit.corner(ts(12)).Parent = veil
			Kit.glyph("check", { ImageColor3 = Color3.fromHex("#7BD06A"), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = sz(52, 52), ZIndex = 6, Parent = veil })
		elseif locked then
			local veil = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#0A0A14"), BackgroundTransparency = 0.72, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 6, Parent = cell })
			Kit.corner(ts(12)).Parent = veil
			local lock = Kit.new("Frame", { BackgroundColor3 = BLACK, BackgroundTransparency = 0.4, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -ts(6), 0, ts(6)), Size = sz(26, 26), ZIndex = 7, Parent = cell })
			Kit.corner(ts(5)).Parent = lock
			Kit.glyph("lock", { ImageColor3 = Color3.fromHex("#FFC83C"), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.68, 0.68), ZIndex = 7, Parent = lock })
		end
		if can then
			Dossier.clicky(cell, 1.06)
			cell.Activated:Connect(function()
				Dossier.click()
				claim(track, t)
			end)
		elseif locked then
			cell.Activated:Connect(function()
				ctx.prompt("campaignPass")
			end)
		end
	end

	for t = 1, Pass.TIERS do
		local nx, ny = nodeAt(t)
		local on = tier >= t
		local node = Kit.new("Frame", { Name = `Tier{t}`, BackgroundColor3 = if on then Color3.fromHex("#E9C02E") else Color3.fromHex("#2A2A2A"), BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(nx, ny), Size = sz(NODE, NODE), ZIndex = 6, Parent = road })
		Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = node })
		Kit.stroke(if on then WHITE else Color3.fromHex("#888888"), math.max(2, ts(4)), 0).Parent = node
		stencil({ Text = tostring(t), TextSize = ts(24), TextColor3 = if on then C.inkBlack else WHITE, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 7, Parent = node })
		tile("premium", t, nx, ny - NODE / 2 - 10 - TILE_H / 2)
		tile("free", t, nx, ny + NODE / 2 + 10 + TILE_H / 2)
	end
	-- Which row is which.
	type RowTag = { text: string, y: number, color: Color3 }
	local rowTags: { RowTag } = { { text = "PREMIUM", y = BANNER_H - 18, color = GOLD }, { text = "FREE", y = STRIP_Y - 26, color = Color3.fromHex("#9FD8FF") } }
	for _, tag in rowTags do
		local label = stencil({ Text = tag.text, TextSize = ts(18), TextColor3 = tag.color, Position = at(18, tag.y), ZIndex = 9, Parent = body })
		Kit.new("UIStroke", { Color = BLACK, Thickness = 1.5, Transparency = 0.2, Parent = label })
	end
	-- Start the road at the first prize waiting, else just before your tier.
	local focus = math.max(1, tier)
	for t = 1, math.min(tier, Pass.TIERS) do
		if not claimed.free[t] or (pass.premium and not claimed.premium[t]) then
			focus = t
			break
		end
	end
	road.CanvasPosition = Vector2.new(math.max(0, (focus - 2) * STEP * k), 0)

	-- The strip: TODAY / WEEK tabs, the missions as chips, PREMIUM.
	local strip = Kit.new("Frame", { Name = "Strip", BackgroundColor3 = Color3.fromHex("#0A120E"), BorderSizePixel = 0, Position = at(0, STRIP_Y), Size = sz(REF_W, STRIP_H + 10), ZIndex = 8, Parent = body })
	local buyW = if pass.premium then 0 else 290
	local chipsX = 132
	local chipsW = REF_W - chipsX - 16 - (if buyW > 0 then buyW + 16 else 0)
	local showing: string = memo.passMissions or "daily"
	local chipsHost = Kit.new("Frame", { BackgroundTransparency = 1, Position = at(chipsX, 10), Size = sz(chipsW, STRIP_H - 18), ZIndex = 8, Parent = strip })
	local tabs: { [string]: TextButton } = {}
	local function paintChips()
		for _, c in chipsHost:GetChildren() do
			c:Destroy()
		end
		local list = if showing == "weekly" then pass.weekly else pass.daily
		local n = math.max(1, #list)
		local cw = (chipsW - (n - 1) * 10) / n
		for i, m in list do
			local done = m.progress >= m.goal
			local chip = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#F2E8D1"), BorderSizePixel = 0, Position = at((i - 1) * (cw + 10), 0), Size = sz(cw, STRIP_H - 18), ZIndex = 8, Parent = chipsHost })
			Kit.corner(ts(8)).Parent = chip
			Kit.new("TextLabel", { BackgroundTransparency = 1, Text = m.text, FontFace = F.bodyBold, TextSize = ts(17), TextColor3 = if done then C.inkSoft else C.inkBlack, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = at(12, 8), Size = sz(cw - 96, 22), ZIndex = 8, Parent = chip })
			local xp = Kit.new("Frame", { BackgroundColor3 = if done then Color3.fromHex("#5E9E55") else Color3.fromHex("#2EA35B"), BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = at(cw - 10, 8), Size = sz(76, 24), ZIndex = 8, Parent = chip })
			Kit.corner(ts(5)).Parent = xp
			stencil({ Text = if done then "DONE" else `+{m.xp}`, TextSize = ts(17), TextColor3 = WHITE, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 8, Parent = xp })
			local track = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#D7C9A4"), BorderSizePixel = 0, Position = at(12, 40), Size = sz(cw - 24, 10), ZIndex = 8, Parent = chip })
			Kit.corner(ts(5)).Parent = track
			local f = Kit.new("Frame", { BackgroundColor3 = if done then Color3.fromHex("#5E9E55") else Color3.fromHex("#E9C02E"), BorderSizePixel = 0, Size = UDim2.fromScale(math.clamp(m.progress / m.goal, 0, 1), 1), ZIndex = 8, Parent = track })
			Kit.corner(ts(5)).Parent = f
		end
		for id, b in tabs do
			local on = id == showing
			b.BackgroundColor3 = if on then Color3.fromHex("#E9C02E") else Color3.fromHex("#22302A")
			local l = b:FindFirstChildWhichIsA("TextLabel")
			if l then
				l.TextColor3 = if on then C.inkBlack else Color3.fromHex("#C9D4C2")
			end
		end
	end
	type Tab = { id: string, text: string }
	local tabList: { Tab } = { { id = "daily", text = "TODAY" }, { id = "weekly", text = "WEEK" } }
	for i, t in tabList do
		local b = Kit.new("TextButton", { Name = t.text, Text = "", AutoButtonColor = false, BorderSizePixel = 0, Position = at(14, 10 + (i - 1) * 34), Size = sz(104, 30), ZIndex = 8, Parent = strip })
		Kit.corner(ts(6)).Parent = b
		stencil({ Text = t.text, TextSize = ts(18), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = 8, Parent = b })
		tabs[t.id] = b
		b.Activated:Connect(function()
			Dossier.click()
			showing = t.id
			memo.passMissions = showing
			paintChips()
		end)
	end
	paintChips()
	if not pass.premium then
		local product = Catalog.product("campaignPass") :: Catalog.Product
		local buy = Kit.new("TextButton", { Name = "Premium", Text = "", AutoButtonColor = false, BackgroundColor3 = WHITE, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = at(REF_W - 16, 8), Size = sz(buyW, STRIP_H - 14), ZIndex = 8, Parent = strip })
		Kit.corner(ts(10)).Parent = buy
		Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromHex("#FFD75E"), Color3.fromHex("#E6A817")), Parent = buy })
		local glow = Kit.stroke(Color3.fromHex("#FFF2B3"), math.max(2, ts(3)), 0)
		glow.Parent = buy
		table.insert(pulses, glow)
		local row = P.row(buy, ts(8))
		row.Size = UDim2.new(1, 0, 0.62, 0)
		row.ZIndex = 8
		stencil({ Text = "PREMIUM", TextSize = ts(30), TextColor3 = Color3.fromHex("#3B2200"), LayoutOrder = 1, ZIndex = 8, Parent = row })
		P.robuxMark(row, ts(28), 2)
		stencil({ Text = tostring(product.price), TextSize = ts(30), TextColor3 = Color3.fromHex("#3B2200"), LayoutOrder = 3, ZIndex = 8, Parent = row })
		Kit.new("TextLabel", { BackgroundTransparency = 1, Text = "2 skins, 3 flags, 4 titles, match effects", FontFace = F.bodyBold, TextSize = ts(15), TextColor3 = Color3.fromHex("#5A3A00"), Position = UDim2.fromScale(0, 0.58), Size = UDim2.fromScale(1, 0.36), ZIndex = 8, Parent = buy })
		for _, d in row:GetDescendants() do
			if d:IsA("GuiObject") then
				d.ZIndex = 8
			end
		end
		Dossier.clicky(buy, 1.04)
		buy.Activated:Connect(function()
			Dossier.click()
			ctx.prompt("campaignPass")
		end)
	end
	return (modal :: any) :: Kit.Modal
end

return CampaignPass
