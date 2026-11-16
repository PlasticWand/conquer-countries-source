--!strict
-- Invite to party as a dossier window, laid out to Bruno's reference
-- (2026-10-27, docs/design/dossier-ui/party-reference.png, 1786 x 880): the
-- header paper, the yellow INVITE ROBLOX FRIENDS plate (Roblox's own invite
-- prompt), a note on a paper strip, then a folder listing your party, your
-- pending invites (with ACCEPT) and everyone on this server (with INVITE).
-- The window grows a row at a time for longer lists, then scrolls. On a
-- phone it fills the screen: the plate and the note at the top, the list in
-- the folder under them.

local Players = game:GetService("Players")
local SocialService = game:GetService("SocialService")

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)

local C = Theme.color
-- Invite rewards (Catalog.REFERRAL): the line under the invite plate.
local INVITE_LINE = `Friends who accept join you here. +{Kit.commas(Catalog.REFERRAL.stars)} stars for each new friend who plays!`

local Party = {}

export type View = { members: { { userId: number, name: string } }, invites: { { userId: number, name: string } } }

local K = 0.66 -- canvas units per reference pixel
local ROW = 78 -- a list row, in reference pixels
local MAX_EXTRA_ROWS = 4 -- the window grows this far, then the list scrolls

-- `send` fires the Party remote ({ op, userId }).
function Party.open(host: Instance, view: View?, send: (request: { [string]: any }) -> ()): Kit.Modal
	local me = Players.LocalPlayer

	-- What the folder lists: section titles, names and their buttons.
	type Line = { title: string?, name: string?, button: string?, yellow: boolean?, onClick: (() -> ())? }
	local lines: { Line } = {}
	local inParty: { [number]: boolean } = {}
	if view and #view.members > 1 then
		table.insert(lines, { title = "Your party" })
		for _, m in view.members do
			inParty[m.userId] = true
			table.insert(lines, { name = if m.userId == me.UserId then `{m.name} (you)` else m.name })
		end
		table.insert(lines, { name = "", button = "LEAVE PARTY", onClick = function()
			send({ op = "leave" })
		end })
	end
	if view and #view.invites > 0 then
		table.insert(lines, { title = "Invites" })
		for _, inv in view.invites do
			table.insert(lines, { name = inv.name, button = "ACCEPT", yellow = true, onClick = function()
				send({ op = "accept", userId = inv.userId })
			end })
		end
	end
	table.insert(lines, { title = "On this server" })
	local others = 0
	for _, p in Players:GetPlayers() do
		if p ~= me and not inParty[p.UserId] then
			others += 1
			table.insert(lines, { name = p.DisplayName, button = "INVITE", onClick = function()
				send({ op = "invite", userId = p.UserId })
			end })
		end
	end
	if others == 0 then
		table.insert(lines, { name = "Nobody else is on this server yet." })
	end

	-- The list's rows: section titles, then names with their buttons. Sizes in
	-- canvas units; `close` closes the window (LEAVE PARTY does).
	local function fill(list: ScrollingFrame, rowH: number, titleSize: number, nameSize: number, ruleW: number, buttonText: number, buttonH: number, buttonW: number, close: () -> ())
		Kit.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top).Parent = list
		for i, l in lines do
			local r = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -12, 0, rowH), LayoutOrder = i, Parent = list })
			if l.title then
				Dossier.stencil({ Text = string.upper(l.title), TextSize = titleSize, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.45), Parent = r })
				Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 0.95), Size = UDim2.fromOffset(ruleW, 2), Parent = r })
			else
				Dossier.typed({ Text = l.name or "", TextColor3 = C.inkBlack, TextSize = nameSize, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Parent = r })
				if l.button and l.onClick then
					local onClick = l.onClick
					local bw = if l.button == "LEAVE PARTY" then buttonW * 1.3 else buttonW
					local b, setYellow = Dossier.rivetPlate(r, l.button, buttonText, l.yellow == true, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(math.round(bw), buttonH), Parent = r })
					b.Activated:Connect(function()
						if b:GetAttribute("Done") then
							return
						end
						onClick()
						if l.button == "LEAVE PARTY" then
							close()
							return
						end
						b:SetAttribute("Done", true)
						setYellow(false)
						local label = b:FindFirstChild("Label") :: TextLabel?
						if label then
							label.Text = if l.button == "INVITE" then "SENT" else "DONE"
							label.TextTransparency = 0.4
						end
					end)
				end
			end
		end
	end

	-- Roblox's own invite prompt.
	local function inviteFriends()
		task.spawn(function()
			local ok, can = pcall(function()
				return SocialService:CanSendGameInviteAsync(me)
			end)
			if ok and can then
				pcall(function()
					-- (the launch data names the inviter for the reward, beside
					-- Roblox's own ReferredByPlayerId)
					local options = Instance.new("ExperienceInviteOptions")
					options.PromptMessage = `Invite friends: +{Kit.commas(Catalog.REFERRAL.stars)} stars for each new friend who plays!`
					options.LaunchData = `ref:{me.UserId}`
					SocialService:PromptGameInvite(me, options)
				end)
			end
		end)
	end

	if Dossier.phone() then
		local w = Dossier.phoneWindow(host, "INVITE TO PARTY")
		local at, sz = w.at, w.sz
		local roblox = Dossier.rivetPlate(w.body, "", 0, true, { Name = "InviteFriends", Position = at(w.width / 2, 46), Size = sz(w.width - 40, 82), Parent = w.body })
		local row = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = roblox })
		Kit.list(Enum.FillDirection.Horizontal, 20, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
		Kit.glyph("party", { ImageColor3 = C.inkBlack, Size = sz(48, 48), LayoutOrder = 1, Parent = row })
		Dossier.stencil({ Text = "INVITE ROBLOX FRIENDS", TextSize = 64, LayoutOrder = 2, Parent = row })
		roblox.Activated:Connect(inviteFriends)
		Dossier.typed({ Text = INVITE_LINE, TextColor3 = C.sheet, TextSize = 20, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(w.width / 2, 106), Parent = w.body })
		Dossier.cardArt("ImageLabel", "folder_card", { Name = "Folder", Position = at(14, 126), Size = sz(w.width - 28, w.height - 132), Parent = w.body })
		local list = Kit.scroll({ Name = "List", Position = at(40, 160), Size = sz(w.width - 110, w.height - 184), ScrollBarThickness = 8, ScrollBarImageColor3 = Color3.fromHex("#1E2019"), Parent = w.body })
		fill(list, 66, 54, 26, 420, 34, 54, 190, w.close)
		return (w :: any) :: Kit.Modal
	end

	-- The reference fits a title and one line; each extra line adds a row.
	local extra = math.clamp(#lines - 2, 0, MAX_EXTRA_ROWS)
	local refH = 880 + extra * ROW
	local w = Dossier.window(host, 1786, refH, math.round(refH * K), 36)
	local at, sz = w.at, w.sz
	local head = w.header

	-- Header.
	Dossier.headerPaper(w, 72, 52, 1622, 225, 0)
	Dossier.clip(head, w, 80, 135, 110, 0)
	Kit.glyph("party", { ImageColor3 = C.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = at(268, 162), Size = sz(118, 118), Parent = head })
	Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.2, BorderSizePixel = 0, Position = at(366, 105), Size = UDim2.fromOffset(2, math.round(128 * w.k)), Parent = head })
	Dossier.bigCaps(w, 120, { Text = "INVITE TO PARTY", AnchorPoint = Vector2.new(0, 0.5), Position = at(410, 165), Parent = head })
	Dossier.closeManila(head, at(1662, 152), sz(130, 116), w.close)

	-- INVITE ROBLOX FRIENDS.
	local roblox = Dossier.rivetPlate(w.body, "", 0, true, { Name = "InviteFriends", Position = at(893, 398), Size = sz(1362, 176), Parent = w.body })
	local row = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = roblox })
	Kit.list(Enum.FillDirection.Horizontal, math.round(40 * w.k), Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
	Kit.glyph("party", { ImageColor3 = C.inkBlack, Size = sz(80, 80), LayoutOrder = 1, Parent = row })
	Dossier.stencil({ Text = "INVITE ROBLOX FRIENDS", TextSize = Dossier.capSize(w, 52), LayoutOrder = 2, Parent = row })
	roblox.Activated:Connect(inviteFriends)
	local note = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Name = "Note", AnchorPoint = Vector2.new(0.5, 0.5), Position = at(895, 548), Size = sz(920, 82), Parent = w.body })
	Dossier.typed({ Text = INVITE_LINE, TextColor3 = C.inkBlack, TextSize = math.round(32 * w.k), AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Parent = note })

	-- The folder and its list.
	local folderH = refH - 880 + 250
	Dossier.cardArt("ImageLabel", "folder_card", { Name = "Folder", Position = at(48, 598), Size = sz(1660, folderH), Parent = w.body })
	Dossier.clip(w.body, w, 74, 680, 110, 0)
	Dossier.starStamp(w.body, w, 1565, 598 + folderH / 2 + 30, 160, 0.72)
	local list = Kit.scroll({ Name = "List", Position = at(140, 650), Size = sz(1420, folderH - 70), ScrollBarThickness = math.round(10 * w.k), ScrollBarImageColor3 = Color3.fromHex("#1E2019"), Parent = w.body })
	fill(list, math.round(ROW * w.k), Dossier.capSize(w, 40), math.round(32 * w.k), math.round(708 * w.k), Dossier.capSize(w, 24), math.round(62 * w.k), 230 * w.k, w.close)
	return (w :: any) :: Kit.Modal
end

return Party
