--!strict
-- Conquest General's window (RoWorld's General, docs/design/ARSENAL_V2.md;
-- Bruno, 2026-11-09): what the monthly subscription gives, its price, and
-- SUBSCRIBE, which opens Roblox's own prompt (Roblox bills and renews it;
-- the server's Store hears of it and the profile view says `general`). A
-- subscriber sees "Your perks are on" instead. Opened from the main menu's
-- General card. Laid out in reference pixels, a dossier window on desktop
-- and the full screen on a phone (as StarterOffer).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)
local Skins = require(Shared.Store.Skins)

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)

local C = Theme.color
local stencil, typed = Dossier.stencil, Dossier.typed

local GeneralOffer = {}

local REF_W, REF_H = 1000, 560
local GOLD = Color3.fromRGB(255, 205, 86)
local OLIVE = Color3.fromHex("#3A422C")

-- The subscription's icon as Bruno uploaded it in Creator Hub.
GeneralOffer.ICON = "rbxassetid://111235217936139"

export type Handle = { root: Frame, close: () -> () }

-- `subscribed`: the player is a General already. Three perk folders in a
-- row (as the Arsenal's), the price and SUBSCRIBE in a strip under them
-- (Bruno, 2026-11-09).
-- `onPrompt` runs when SUBSCRIBE shows Roblox's prompt (the Store funnel).
function GeneralOffer.open(host: Instance, subscribed: boolean, onPrompt: (() -> ())?): Handle
	local w: Dossier.Window
	if Dossier.phone() then
		Dossier.style = { wash = Color3.fromHex("#E6A817"), art = "banner_general" }
		local p = Dossier.phoneWindow(host, "GENERAL")
		local k = math.min(p.width / REF_W, p.height / REF_H)
		local page = Kit.new("Frame", { Name = "Page", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(math.round(REF_W * k), math.round(REF_H * k)), Parent = p.body })
		w = Dossier.rescaled(p, k, page)
	else
		local root = Kit.root
		local height = math.min(REF_H + 150, if root then root.height - 40 else REF_H + 150)
		Dossier.style = { wash = Color3.fromHex("#E6A817"), art = "banner_general", bannerH = 170 }
		w = Dossier.window(host, REF_W, REF_H + 150, height, 150)
		-- (800 wide: at 700 the title ran into the torn right edge; Bruno, 2026-11-09.)
		Dossier.headerPaper(w, 30, 34, 800, 116, -0.6)
		typed({ Text = "M O N T H L Y   S U B S C R I P T I O N", TextColor3 = C.stamp, TextSize = math.round(20 * w.k), Position = w.at(150, 30), Parent = w.header })
		Dossier.bigCaps(w, 50, { Text = "CONQUEST GENERAL", AnchorPoint = Vector2.new(0, 0.5), Position = w.at(146, 110), Parent = w.header }) -- (100: at 110 its letters dipped below the paper; Bruno, 2026-11-09)
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = GeneralOffer.ICON, Position = w.at(46, 46), Size = w.sz(90, 90), Parent = w.header })
		Dossier.closeManila(w.header, w.at(REF_W - 70, 88), w.sz(90, 86), w.close)
		local page = Kit.new("Frame", { Name = "Page", BackgroundTransparency = 1, Position = w.at(0, 150), Size = w.sz(REF_W, REF_H), Parent = w.body })
		w = Dossier.rescaled(w, w.k, page)
	end
	local at, sz, k = w.at, w.sz, w.k

	-- The three perks, each a folder with a print and its line.
	local skinId = Catalog.generalSkin(os.time())
	local skin = if skinId then Skins.get(skinId) else nil
	local PERKS = {
		{ title = "A CRATE A DAY", line = "Every day you play: a skin or a country flag you don't own yet" },
		{ title = "+50% STARS", line = "On every match, on top of 2x Stars" },
		{ title = "THE MONTH'S SKIN", line = if skin then `{skin.name}: yours to keep` else "Yours to keep" },
	}
	local cardW, cardH, gap = 290, 400, 25
	local x0 = (REF_W - (3 * cardW + 2 * gap)) / 2
	for i, perk in PERKS do
		local x = x0 + (i - 1) * (cardW + gap)
		local card = Dossier.cardArt("ImageLabel", "folder_portrait", { Name = `Perk{i}`, Position = at(x, 10), Size = sz(cardW, cardH), Parent = w.body })
		local print = Kit.new("Frame", { Name = "Print", BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = at(18, 34), Size = sz(cardW - 36, 200), Rotation = ({ -0.8, 0.6, -0.4 })[i], Parent = card })
		local inner = Kit.new("Frame", { Name = "Picture", BackgroundColor3 = Color3.fromHex("#2B2E22"), BorderSizePixel = 0, Position = UDim2.fromOffset(math.round(6 * k), math.round(6 * k)), Size = UDim2.new(1, -math.round(12 * k), 1, -math.round(12 * k)), ClipsDescendants = true, Parent = print })
		if i == 1 then
			Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.dossier.crate_wood or "", ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.55), Size = UDim2.fromScale(0.85, 0.85), Parent = inner })
			stencil({ Text = "DAILY", TextSize = math.round(26 * k), TextColor3 = GOLD, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -math.round(8 * k), 0, math.round(4 * k)), Rotation = 6, Parent = inner })
		elseif i == 2 then
			local row = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = inner })
			Kit.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
			stencil({ Text = "+50%", TextSize = math.min(100, math.round(84 * k)), TextColor3 = GOLD, LayoutOrder = 1, Parent = row })
			local stars = Kit.new("Frame", { BackgroundTransparency = 1, Size = sz(160, 36), LayoutOrder = 2, Parent = row })
			Kit.list(Enum.FillDirection.Horizontal, math.round(8 * k), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = stars
			for j = 1, 4 do
				Kit.glyph("star", { ImageColor3 = GOLD, Size = sz(30, 30), LayoutOrder = j, Parent = stars })
			end
		else
			-- The month's skin: the General's badge with a ribbon naming the
			-- month (Bruno, 2026-11-09: not the map).
			Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = GeneralOffer.ICON, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.44), Size = sz(130, 130), Parent = inner })
			local ribbon = Kit.new("Frame", { BackgroundColor3 = GOLD, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -math.round(10 * k)), Size = sz(220, 34), Rotation = -3, Parent = inner })
			Kit.corner(math.round(3 * k)).Parent = ribbon
			stencil({ Text = `{string.upper(os.date("!%B", os.time()) :: string)}  ·  LEGENDARY`, TextSize = math.round(20 * k), TextColor3 = C.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = ribbon })
		end
		stencil({ Text = perk.title, TextSize = math.round(34 * k), Position = at(22, 252), Parent = card })
		Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = at(22, 296), Size = sz(cardW - 44, 2), Parent = card })
		typed({ Text = perk.line, TextColor3 = C.inkBlack, TextSize = math.round(20 * k), TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, TextYAlignment = Enum.TextYAlignment.Top, Position = at(22, 306), Size = sz(cardW - 44, 80), Parent = card })
	end

	-- The strip under them: SUBSCRIBE and the price, or the General's welcome.
	if subscribed then
		local stamp = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(REF_W / 2, 476), Size = sz(560, 70), Rotation = -2, Parent = w.body })
		Kit.stroke(GOLD, math.max(2, math.round(4 * k)), 0).Parent = stamp
		stencil({ Text = "YOU'RE A GENERAL  ·  YOUR PERKS ARE ON", TextSize = math.round(32 * k), TextColor3 = GOLD, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = stamp })
	else
		local plate = Dossier.plate(w.body, "", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(REF_W / 2, 470), Size = sz(560, 86), Parent = w.body }, 0)
		Dossier.clicky(plate, 1.03)
		local row = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = plate })
		Kit.list(Enum.FillDirection.Horizontal, math.round(14 * k), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
		stencil({ Text = "SUBSCRIBE", TextSize = math.round(40 * k), LayoutOrder = 1, Parent = row })
		stencil({ Text = "·", TextSize = math.round(40 * k), LayoutOrder = 2, Parent = row })
		Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, ImageColor3 = C.inkBlack, Size = sz(34, 34), LayoutOrder = 3, Parent = row })
		stencil({ Text = `{Catalog.SUBSCRIPTION.robux} / MONTH`, TextSize = math.round(40 * k), LayoutOrder = 4, Parent = row })
		for _, t in { { 50, -1 }, { 510, 1 } } do
			Dossier.art("red_tape", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(t[1], 14), Size = sz(96, 26), Rotation = -40 * t[2], ScaleType = Enum.ScaleType.Stretch, ZIndex = 3, Parent = plate })
		end
		plate.Activated:Connect(function()
			if Catalog.SUBSCRIPTION.id ~= "" then
				if onPrompt then
					onPrompt()
				end
				MarketplaceService:PromptSubscriptionPurchase(Players.LocalPlayer, Catalog.SUBSCRIPTION.id)
			end
		end)
		typed({ Text = "Billed monthly by Roblox. Cancel any time in Roblox's settings.", TextColor3 = C.sheetLine, TextSize = math.round(17 * k), AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 524), Parent = w.body })
	end
	return { root = w.root :: Frame, close = w.close }
end

-- The main menu's General card (RoWorld's GeneralButton, in the dossier
-- look; Bruno, 2026-11-09): an olive card edged in gold with the four-star
-- badge, GENERAL in gold, a line cycling through the perks, a gold MONTHLY
-- tab on its corner, a breathing gold edge and a light crossing it every few
-- seconds. A General sees "Your perks are on". `size` in pixels. Returns the
-- button and a function setting whether the player is a General.
function GeneralOffer.card(parent: Instance, size: Vector2, props: { [string]: any }): (TextButton, (boolean) -> ())
	local s = size.Y / 56
	local card = Kit.new("TextButton", { Name = "GeneralCard", Text = "", AutoButtonColor = false, BackgroundColor3 = OLIVE, BorderSizePixel = 0, Size = UDim2.fromOffset(size.X, size.Y), ClipsDescendants = false, Parent = parent }) :: TextButton
	for k, v in props do
		(card :: any)[k] = v
	end
	Kit.corner(math.round(7 * s)).Parent = card
	local edge = Kit.stroke(GOLD, math.max(2, math.round(2.5 * s)), 0)
	edge.Parent = card
	local z = card.ZIndex
	Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = GeneralOffer.ICON, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, math.round(6 * s), 0.5, 0), Size = UDim2.fromOffset(math.round(44 * s), math.round(44 * s)), ZIndex = z, Parent = card })
	stencil({ Text = "GENERAL", TextSize = math.round(26 * s), TextColor3 = GOLD, Position = UDim2.fromOffset(math.round(58 * s), math.round(4 * s)), ZIndex = z, Parent = card })
	local line = typed({ Text = "", TextColor3 = Color3.fromHex("#F1E6C8"), TextSize = math.round(14 * s), Position = UDim2.fromOffset(math.round(58 * s), math.round(32 * s)), ZIndex = z, Parent = card })
	-- The MONTHLY tab on the corner.
	local tab = Kit.new("Frame", { BackgroundColor3 = GOLD, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, math.round(6 * s), 0, 0), Size = UDim2.fromOffset(math.round(66 * s), math.round(18 * s)), Rotation = 6, ZIndex = z + 1, Parent = card })
	Kit.corner(math.round(3 * s)).Parent = tab
	stencil({ Text = "MONTHLY", TextSize = math.round(13 * s), TextColor3 = C.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), ZIndex = z + 1, Parent = tab })
	-- The light that crosses it.
	local shine = Kit.new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = z, Parent = card })
	Kit.corner(math.round(7 * s)).Parent = shine
	local gradient = Kit.new("UIGradient", {
		Rotation = 20,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.42, 1),
			NumberSequenceKeypoint.new(0.5, 0.78),
			NumberSequenceKeypoint.new(0.58, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Offset = Vector2.new(-1, 0),
		Parent = shine,
	}) :: UIGradient
	Dossier.clicky(card, 1.06)

	local lines = { "A crate every day", "+50% stars a match", "The month's skin" }
	local general = false
	local t0 = os.clock()
	local conn = game:GetService("RunService").Heartbeat:Connect(function()
		local t = os.clock() - t0
		-- The gold edge breathes; the light crosses every 3.8 s.
		edge.Transparency = 0.15 + 0.15 * math.sin(t * 2.4)
		local phase = (t % 3.8) / 0.9
		gradient.Offset = Vector2.new(if phase <= 1 then -1 + 2 * phase else 1, 0)
		line.Text = if general then "Your perks are on" else lines[(math.floor(t / 2.6) % #lines) + 1]
	end)
	card.Destroying:Connect(function()
		conn:Disconnect()
	end)
	return card, function(on: boolean)
		general = on
	end
end

return GeneralOffer
