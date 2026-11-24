--!strict
-- The launch event's gift (Bruno, 2026-11-13; Catalog.LAUNCH_GIFT): LAUNCH
-- GIFT, STARTER PACK, the pack's three items as recon photos, FREE, ENDS IN
-- 6d 23h, CLAIM FREE and NOT NOW. Built like StarterOffer: reference pixels
-- (REF_W x REF_H), a dossier window on desktop, the full screen on a phone.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)

local Art = require(script.Parent.Parent.Art)
local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)

local C = Theme.color
local stencil, typed = Dossier.stencil, Dossier.typed

local GiftOffer = {}

local REF_W, REF_H = 1000, 640

export type Handle = { root: Frame, close: () -> (), setClaimed: () -> (), setFailed: () -> () }

-- `left`: seconds until the event ends. `claim` asks the server; the caller
-- answers with setClaimed or setFailed.
function GiftOffer.open(host: Instance, left: number, claim: () -> ()): Handle
	local w: Dossier.Window
	if Dossier.phone() then
		Dossier.style = { wash = Color3.fromHex("#D8342B"), art = "banner_gift" }
		local p = Dossier.phoneWindow(host, "LAUNCH GIFT")
		local k = math.min(p.width / REF_W, p.height / REF_H)
		local page = Kit.new("Frame", { Name = "Page", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(math.round(REF_W * k), math.round(REF_H * k)), Parent = p.body })
		w = Dossier.rescaled(p, k, page)
	else
		local root = Kit.root
		local height = math.min(REF_H + 120, if root then root.height - 40 else REF_H + 120)
		Dossier.style = { wash = Color3.fromHex("#D8342B"), art = "banner_gift", bannerH = 160 }
		w = Dossier.window(host, REF_W, REF_H + 120, height, 140)
		Dossier.headerPaper(w, 30, 34, 640, 110, -0.6)
		typed({ Text = "L A U N C H   G I F T", TextColor3 = C.stamp, TextSize = math.round(20 * w.k), Position = w.at(64, 30), Parent = w.header })
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
	typed({ Text = "Yours for good. A gift for playing in launch week.", TextColor3 = C.sheet, TextSize = math.round(22 * k), AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 258), Parent = w.body })

	-- FREE, big, with the gift glyph.
	local row = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 296), Size = sz(0, 96), AutomaticSize = Enum.AutomaticSize.X, Parent = w.body })
	Kit.list(Enum.FillDirection.Horizontal, math.round(16 * k), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
	Kit.glyph("gift", { ImageColor3 = C.hazard, Size = sz(70, 70), LayoutOrder = 1, Parent = row })
	stencil({ Text = "FREE", TextSize = math.min(100, math.round(84 * k)), TextColor3 = C.hazard, LayoutOrder = 2, Parent = row })

	-- The event's end, and what happens on CLAIM.
	local timer = stencil({ Text = "", TextSize = math.round(34 * k), TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 404), Parent = w.body })
	local note = typed({ Text = "One claim per player.", TextColor3 = C.sheetLine, TextSize = math.round(20 * k), AnchorPoint = Vector2.new(0.5, 0), Position = at(REF_W / 2, 448), Parent = w.body })

	local claimPlate = Dossier.plate(w.body, "CLAIM FREE", { AnchorPoint = Vector2.new(0.5, 0.5), Position = at(REF_W / 2 - 150, 548), Size = sz(400, 86), Parent = w.body }, math.round(40 * k))
	Dossier.clicky(claimPlate, 1.04)
	local busy, done = false, false
	claimPlate.Activated:Connect(function()
		if busy or done then
			return
		end
		busy = true
		claim()
	end)
	local notNow = Dossier.rivetPlate(w.body, "NOT NOW", math.round(26 * k), false, { Position = at(REF_W / 2 + 230, 548), Size = sz(240, 70), Parent = w.body })
	notNow.Activated:Connect(w.close)

	local endsAt = os.clock() + left
	local function paint()
		if not done then
			timer.Text = `ENDS IN {Kit.days(math.max(0, endsAt - os.clock()))}`
		end
	end
	paint()
	local conn = game:GetService("RunService").Heartbeat:Connect(paint)
	w.root.Destroying:Connect(function()
		conn:Disconnect()
	end)

	local function label(plate: Instance, text: string)
		local l = plate:FindFirstChild("Label", true)
		if l and l:IsA("TextLabel") then
			l.Text = text
		elseif plate:IsA("TextButton") then
			plate.Text = text
		end
	end
	return {
		root = w.root :: Frame,
		close = w.close,
		setClaimed = function()
			busy, done = false, true
			label(claimPlate, "CLAIMED")
			timer.Text = "UNLOCKED"
			note.Text = "Find them in your Arsenal."
			task.delay(1.6, w.close)
		end,
		setFailed = function()
			busy = false
			note.Text = "It didn't go through. Try again."
		end,
	}
end

return GiftOffer
