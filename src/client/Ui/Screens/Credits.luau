--!strict
-- Credits and licences as a dossier window (Bruno, 2026-11-08: RoWorld on the
-- credits screen; docs/LICENSING_PLAN.md). Opened from the main menu's
-- credits bar. The words are Shared/CreditsText; this lays them out on a
-- scrolling paper page, with the source address in a box players can
-- select and copy (AGPL-3.0 section 13: offer the source prominently).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CreditsText = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CreditsText"))

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)

local C = Theme.color
local F = Theme.font

local Credits = {}

local WINDOW_H = 900
local REF_W, REF_H = 1300, 1000
local PAGE_TOP = 170

function Credits.open(host: Instance): Kit.Modal
	local phone = Dossier.phone()
	local w: Dossier.Window
	local page: ScrollingFrame
	local pad, titleSize, textSize
	if phone then
		w = Dossier.phoneWindow(host, "CREDITS")
		page = Kit.scroll({ Name = "Page", Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 1, -12), Parent = w.body })
		pad, titleSize, textSize = 14, 30, 19
	else
		w = Dossier.window(host, REF_W, REF_H, WINDOW_H, 36)
		Dossier.headerPaper(w, 45, 15, 900, 110, -0.5)
		Dossier.bigCaps(w, 66, { Text = "CREDITS", AnchorPoint = Vector2.new(0, 0.5), Position = w.at(110, 70), Parent = w.header })
		Dossier.closeRed(w.header, w.at(REF_W - 70, 72), w.sz(84, 84), w.close)
		page = Kit.scroll({ Name = "Page", Position = w.at(50, PAGE_TOP), Size = w.sz(REF_W - 100, REF_H - PAGE_TOP - 50), Parent = w.body })
		pad, titleSize, textSize = 22, math.round(34 * w.k * 1.1), math.round(22 * w.k * 1.1)
	end
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.CanvasSize = UDim2.new()
	page.ScrollBarThickness = 8
	page.ScrollBarImageColor3 = Color3.fromHex("#1E2019")
	-- The page itself is the paper: a background Frame inside the scrolling
	-- page didn't draw in Studio (its children did), so the colour sits here.
	page.BackgroundColor3 = C.sheet
	page.BackgroundTransparency = 0
	Kit.stroke(C.sheetLine, 1, 0.2).Parent = page

	-- Every section, typed on that paper.
	local sheet = Kit.new("Frame", { Name = "Sheet", BackgroundTransparency = 1, Size = UDim2.new(1, -14, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = page })
	Kit.padding(pad, pad + 6).Parent = sheet
	Kit.list(Enum.FillDirection.Vertical, math.round(pad * 0.6)).Parent = sheet

	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	for i, section in CreditsText.sections(game.PlaceVersion) do
		if i > 1 then
			Kit.new("Frame", { Name = "Rule", BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.75, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), LayoutOrder = nextOrder(), Parent = sheet })
		end
		Dossier.stencil({ Name = "Title", Text = section.title, TextSize = titleSize, TextColor3 = C.stamp, LayoutOrder = nextOrder(), Parent = sheet })
		for j, line in section.lines do
			Dossier.typed({
				Name = "Line",
				Text = line,
				TextSize = textSize,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				LayoutOrder = nextOrder(),
				Parent = sheet,
			})
			-- The source address right after "free to download at:".
			if j == 2 and section.copy then
				local box = Kit.new("TextBox", {
					Name = "Source",
					Text = section.copy,
					TextEditable = false,
					ClearTextOnFocus = false,
					FontFace = F.uiBold,
					TextSize = textSize + 2,
					TextColor3 = C.inkBlack,
					TextXAlignment = Enum.TextXAlignment.Left,
					BackgroundColor3 = C.manila,
					BorderSizePixel = 0,
					Size = UDim2.new(1, 0, 0, math.round((textSize + 2) * 1.9)),
					LayoutOrder = nextOrder(),
					Parent = sheet,
				}) :: TextBox
				Kit.padding(0, 12).Parent = box
				Kit.stroke(C.manilaLine, 1.5, 0).Parent = box
				-- Clicking selects the whole address, ready to copy.
				box.Focused:Connect(function()
					box.CursorPosition = #box.Text + 1
					box.SelectionStart = 1
				end)
			end
		end
	end

	return { root = w.root, window = w.window, header = w.header, body = w.body, close = w.close }
end

return Credits
