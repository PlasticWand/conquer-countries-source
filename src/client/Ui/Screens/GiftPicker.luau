--!strict
-- Who a gift is for (Bruno, 2026-11-23: gift 3 crates, 5 crates or the
-- Campaign Pass to a friend in your party). A paper card over the window
-- `parent` lists the players the server allows (Store.giftTargets: your
-- party, and Roblox friends on this server); a pick tells the server, then
-- opens the gift's Robux prompt. Nothing is granted here.

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)

local C = Theme.color
local F = Theme.font
local stencil = Dossier.stencil

local GiftPicker = {}

local WHAT: { [string]: string } = {
	giftCrate3 = "3 CRATES",
	giftCrate5 = "5 CRATES",
	giftPass = "THE CAMPAIGN PASS",
}

-- `request` and `prompt` are the shop ctx's. `scale` sizes it (window k).
function GiftPicker.open(parent: GuiObject, product: string, request: (req: { [string]: any }) -> { [string]: any }?, prompt: (key: string) -> (), scale: number)
	local function px(n: number): number
		return math.round(n * scale)
	end
	local layer = Kit.new("TextButton", { Name = "GiftPicker", Text = "", AutoButtonColor = false, BackgroundColor3 = C.desk, BackgroundTransparency = 0.35, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 40, Parent = parent })
	local close = function()
		layer:Destroy()
	end
	layer.Activated:Connect(close)
	local card = Dossier.surface("ImageButton", "tex_paper", C.sheet, { Name = "Card", AutoButtonColor = false, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(px(520), px(420)), ZIndex = 41, Parent = layer })
	Kit.corner(px(8)).Parent = card
	Kit.stroke(C.sheetLine, 2, 0).Parent = card
	Kit.glyph("gift", { ImageColor3 = C.stamp, Position = UDim2.fromOffset(px(22), px(20)), Size = UDim2.fromOffset(px(40), px(40)), ZIndex = 42, Parent = card })
	stencil({ Text = `GIFT {WHAT[product] or ""}`, TextSize = px(34), Position = UDim2.fromOffset(px(74), px(20)), ZIndex = 42, Parent = card })
	local line = Kit.new("TextLabel", { BackgroundTransparency = 1, Text = "Who is it for?", FontFace = F.bodyBold, TextSize = px(18), TextColor3 = C.inkSoft, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, Position = UDim2.fromOffset(px(24), px(68)), Size = UDim2.new(1, -px(48), 0, px(44)), ZIndex = 42, Parent = card })
	Dossier.closeManila(card, UDim2.new(1, -px(26), 0, px(26)), UDim2.fromOffset(px(40), px(40)), close).ZIndex = 43
	local list = Kit.scroll({ Name = "List", Position = UDim2.fromOffset(px(20), px(118)), Size = UDim2.new(1, -px(40), 1, -px(138)), ScrollBarThickness = 6, ZIndex = 42, Parent = card })
	Kit.list(Enum.FillDirection.Vertical, px(8), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top).Parent = list

	task.spawn(function()
		local r = request({ op = "giftTargets" })
		if layer.Parent == nil then
			return
		end
		local targets = if r and type(r.targets) == "table" then r.targets else {}
		if #targets == 0 then
			line.Text = "No one to gift yet. Invite a friend to your party (PARTY on the menu), then come back."
			return
		end
		for i, t in targets do
			local b = Kit.new("TextButton", { Name = tostring(t.userId), Text = "", AutoButtonColor = false, BackgroundColor3 = C.manila, BorderSizePixel = 0, Size = UDim2.new(1, -px(8), 0, px(54)), LayoutOrder = i, ZIndex = 43, Parent = list })
			Kit.corner(px(6)).Parent = b
			Kit.stroke(C.manilaLine, 2, 0).Parent = b
			local ok, thumb = pcall(function()
				return game:GetService("Players"):GetUserThumbnailAsync(t.userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
			end)
			Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = if ok then thumb else "", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, px(10), 0.5, 0), Size = UDim2.fromOffset(px(40), px(40)), ZIndex = 44, Parent = b })
			stencil({ Text = string.upper(t.name), TextSize = px(24), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, px(62), 0.5, 0), ZIndex = 44, Parent = b })
			Dossier.clicky(b, 1.03)
			b.Activated:Connect(function()
				Dossier.click()
				local picked = request({ op = "giftPick", product = product, to = t.userId })
				if picked and picked.ok then
					close()
					prompt(product)
				else
					line.Text = "That friend can't get gifts right now."
				end
			end)
		end
	end)
	return close
end

return GiftPicker
