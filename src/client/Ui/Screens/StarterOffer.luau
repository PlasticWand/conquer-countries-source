--!strict
-- The starter pack's offer (RoWorld's, docs/design/ARSENAL_V2.md;
-- 2026-11-08): LIMITED-TIME OFFER, STARTER PACK, its three items as recon
-- photos, the regular price struck through beside the offer's with a red
-- discount sticker, ENDS IN 47:59:12 counting down, "Then it's gone for
-- good.", BUY NOW and NOT NOW. Laid out in reference pixels (REF_W x REF_H),
-- a dossier window on desktop and the full screen on a phone.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)

local Art = require(script.Parent.Parent.Art)
local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)

local C = Theme.color
local stencil, typed = Dossier.stencil, Dossier.typed

local StarterOffer = {}

local REF_W, REF_H = 1000, 640

export type Handle = { root: Frame, close: () -> (), setLeft: (number?) -> () }

-- `left`: seconds until the offer ends (nil: it hasn't started; it starts
-- now). `buy` opens Roblox's prompt.
function StarterOffer.open(host: Instance, left: number?, buy: () -> ()): Handle
	local w: Dossier.Window
	if Dossier.phone() then
		Dossier.style = { wash = Color3.fromHex("#E6A817"), art = "banner_starter" }
		local p = Dossier.phoneWindow(host, "STARTER PACK")
		local k = math.min(p.width / REF_W, p.height / REF_H)
		local page = Kit.new("Frame", { Name = "Page", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(math.round(REF_W * k), math.round(REF_H * k)), Parent = p.body })
		w = Dossier.rescaled(p, k, page)
	else
		local root = Kit.root
		local height = math.min(REF_H + 120, if root then root.height - 40 else REF_H + 120)
		Dossier.style = { wash = Color3.fromHex("#E6A817"), art = "banner_starter", bannerH = 170 }
		w = Dossier.window(host, REF_W, REF_H + 120, height, 140)
		Dossier.headerPaper(w, 30, 34, 640, 110, -0.6)
		typed({ Text = "L I M I T E D - T I M E   O F F E R", TextColor3 = C.stamp, TextSize = math.round(20 * w.k), Position = w.at(64, 30), Parent = w.header })
		-- Raised off the paper's bottom edge (Bruno, 2026-11-11, twice).
		Dossier.bigCaps(w, 52, { Text = "STARTER PACK", AnchorPoint = Vector2.new(0, 0.5), Position = w.at(60, 108), Parent = w.header })
		Dossier.closeManila(w.header, w.at(REF_W - 70, 84), w.sz(90, 86), w.close)
		w = Dossier.rescaled(w, w.k, (function()
			local page = Kit.new("Frame", { Name = "Page", BackgroundTransparency = 1, Position = w.at(0, 140), Size = w.sz(REF_W, REF_H), Parent = w.body })
			return page
		end)())
	end
	local at, sz, k = w.at, w.sz, w.k

	-- The three items, as photos in paper borders.
	for i, id in Catalog.STARTER.items do
		local item = Catalog.weapon(id)
		local x = 40 + (i - 1) * 315
		local frame = Kit.new("Frame", { Name = id, BackgroundColor3 = C.sheet, BorderSizePixel = 0, Position = at(x, 20), Size = sz(290, 220), Rotation = ({ -1.2, 0.6, -0.4 })[i], Parent = w.body })
		local pic = Art.card(id, { Position = UDim2.fromOffset(math.round(6 * k), math.round(6 * k)), Size = UDim2.new(1, -math.round(12 * k), 1, -math.round(52 * k)), Parent = frame })
		Dossier.age(pic)
		stencil({ Text = string.upper(if item then item.name else id), TextSize = math.round(30 * k), AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -math.round(8 * k)), Parent = frame })
		if i < 3 then
			stencil({ Text = "+", TextSize = math.round(56 * k), TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(x + 302, 130), Parent = w.body })
		end
	end
	typed({ Text = "Yours for good. Once per player.", TextColor3 = C.sheet, TextSize = math.round(22 * k), AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 258), Parent = w.body })

	-- The prices: the regular one struck through, the offer's, the sticker.
	local regular = Catalog.STARTER.regular
	local price = (Catalog.product(Catalog.STARTER.product) :: Catalog.Product).price
	local off = math.floor((1 - price / regular) * 100 + 0.5)
	local row = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 300), Size = sz(0, 90), AutomaticSize = Enum.AutomaticSize.X, Parent = w.body })
	Kit.list(Enum.FillDirection.Horizontal, math.round(22 * k), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
	local was = stencil({ Text = `R${regular}`, TextSize = math.round(44 * k), TextColor3 = Color3.fromHex("#E2D6BC"), LayoutOrder = 1, Parent = row })
	Kit.new("Frame", { Name = "Strike", BackgroundColor3 = C.stamp, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, math.round(8 * k), 0, math.max(2, math.round(4 * k))), Rotation = -8, Parent = was })
	local now = Kit.new("Frame", { BackgroundTransparency = 1, Size = sz(0, 90), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, Parent = row })
	Kit.list(Enum.FillDirection.Horizontal, math.round(8 * k), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = now
	Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, Size = sz(52, 52), LayoutOrder = 1, Parent = now })
	stencil({ Text = tostring(price), TextSize = math.min(100, math.round(80 * k)), TextColor3 = C.hazard, LayoutOrder = 2, Parent = now })
	local sticker = Kit.new("Frame", { BackgroundColor3 = C.stamp, BorderSizePixel = 0, Size = sz(110, 56), Rotation = 8, LayoutOrder = 3, Parent = row })
	Kit.corner(6).Parent = sticker
	stencil({ Text = `-{off}%`, TextSize = math.round(36 * k), TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = sticker })

	-- The deadline.
	local timer = stencil({ Text = "", TextSize = math.round(34 * k), TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 404), Parent = w.body })
	typed({ Text = "Then it's gone for good.", TextColor3 = C.sheetLine, TextSize = math.round(20 * k), AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 448), Parent = w.body })

	-- BUY NOW and NOT NOW.
	local buyPlate = Dossier.plate(w.body, "BUY NOW", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(REF_W / 2 - 150, 548), Size = sz(400, 86), Parent = w.body }, math.round(40 * k))
	Dossier.clicky(buyPlate, 1.04)
	buyPlate.Activated:Connect(buy)
	local notNow = Dossier.rivetPlate(w.body, "NOT NOW", math.round(26 * k), false, { Position = at(REF_W / 2 + 230, 548), Size = sz(240, 70), Parent = w.body })
	notNow.Activated:Connect(w.close)

	local endsAt = if left then os.clock() + left else nil
	local function paint()
		local s = if endsAt then math.max(0, endsAt - os.clock()) else Catalog.STARTER.durationS
		timer.Text = `ENDS IN {Kit.clock(s)}`
	end
	paint()
	local conn = game:GetService("RunService").Heartbeat:Connect(paint)
	w.root.Destroying:Connect(function()
		conn:Disconnect()
	end)
	return {
		root = w.root :: Frame,
		close = w.close,
		setLeft = function(s: number?)
			endsAt = if s then os.clock() + s else nil
		end,
	}
end

return StarterOffer
