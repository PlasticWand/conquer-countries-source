--!strict
-- Wires the main menu and its dialogs to the server (docs/design/
-- rofront-ui-pass.md): the Menu remote (public rows, your queue, your
-- party), Start (solo, queue, watch), Party (invite, accept, leave) and the
-- player's settings. The screens only draw; this owns their lifetimes.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)
local FlagShop = require(Shared.Store.FlagShop)
local PlayerSettings = require(Shared.PlayerSettings)
local Products = require(Shared.Store.Products) :: { [string]: number }
local Tutorial = require(Shared.Tutorial)
local WaitingRoomModel = require(Shared.WaitingRoom)

local CrateOpening = require(script.Parent.Crate.CrateOpening)
local Dossier = require(script.Parent.Dossier)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local Credits = require(script.Parent.Screens.Credits)
local HowToPlay = require(script.Parent.Screens.HowToPlay)
local MainMenu = require(script.Parent.Screens.MainMenu)
local MapPicker = require(script.Parent.Screens.MapPicker)
local Party = require(script.Parent.Screens.Party)
local Settings = require(script.Parent.Screens.Settings)
local Shops = require(script.Parent.Screens.Shops)
local StarterOffer = require(script.Parent.Screens.StarterOffer)
local GeneralOffer = require(script.Parent.Screens.GeneralOffer)
local WaitingRoom = require(script.Parent.Screens.WaitingRoom)
local Loading = require(script.Parent.Screens.Loading)

local C = Theme.color

local MenuController = {}

-- Robux products that are crates (Store/Catalog): they play the crate opening.
-- (general: Conquest General's crate of the day.)
local CRATE_PRODUCTS: { [string]: boolean } = { crate1 = true, crate3 = true, crateFirst = true, general = true }
MenuController.__index = MenuController

export type Hooks = {
	-- The match's EngineConfig while one is open (How to Play's numbers).
	config: () -> any?,
	-- Settings changed (applied at once; saved with the profile).
	settingsChanged: ((PlayerSettings.Settings) -> ())?,
}

function MenuController.new(root: any, remotes: Instance, hooks: Hooks)
	local Start = remotes:WaitForChild("Start") :: RemoteEvent
	local Menu = remotes:WaitForChild("Menu") :: RemoteEvent
	local PartyRemote = remotes:WaitForChild("Party") :: RemoteEvent
	local ProfileRemote = remotes:WaitForChild("Profile") :: RemoteEvent
	local Granted = remotes:WaitForChild("Granted") :: RemoteEvent
	local Shop = remotes:WaitForChild("Shop") :: RemoteFunction
	local self = setmetatable({
		root = root,
		hooks = hooks,
		settings = PlayerSettings.defaults(),
		party = nil :: Party.View?,
		modal = nil :: Kit.Modal?,
		view = nil :: any, -- Store/Profile.View
		starterOffer = nil :: any, -- the starter pack's window while open
		shop = nil :: string?, -- the shop screen open now
		shopTab = nil :: string?,
		shopRemote = Shop,
		-- Set by the client: the stars a match just paid.
		starsGained = nil :: ((number) -> ())?,
		-- A menu sound by sound board key; OpenFrontClient sets it.
		sound = nil :: ((string) -> ())?,
		-- the waiting room (Screens/WaitingRoom), on a match server only
		room = nil :: any,
		makeRoom = nil :: any,
		soloCover = nil :: any, -- on a solo match's own server, until it starts
		visible = true,
		connections = {} :: { RBXScriptConnection },
	}, MenuController)

	local function openModal(make: () -> Kit.Modal)
		if self.modal then
			self.modal.close()
		end
		self.modal = make()
	end
	self.openModal = openModal

	local menu = MainMenu.new(root.menu, root, {
		startSolo = function(mapFolder: string, difficulty: string)
			Start:FireServer({ mode = "solo", map = mapFolder, difficulty = difficulty })
		end,
		joinQueue = function(id: string)
			Start:FireServer({ mode = "queue", id = id })
		end,
		leaveQueue = function()
			Start:FireServer({ mode = "unqueue" })
		end,
		watchQueue = function(id: string)
			Start:FireServer({ mode = "watch", id = id })
		end,
		pickMap = function(current: string, done: (string) -> ())
			openModal(function()
				return MapPicker.open(root.modal, current, function(folder: string)
					if self.sound then
						self.sound("menu.mapPick")
					end
					done(folder)
				end, function()
					-- How to Play over the picker; closing it returns there.
					local help = HowToPlay.open(root.modal, self.hooks.config())
					help.root.ZIndex = 60
				end)
			end)
		end,
		openHowToPlay = function()
			self:openHowToPlay()
		end,
		openCredits = function()
			self.openModal(function()
				return Credits.open(self.root.modal)
			end)
		end,
		openSettings = function()
			self:openSettings()
		end,
		toggleMusic = function()
			local s = table.clone(self.settings)
			s.music = not s.music
			self:_applySettings(s)
		end,
		openArsenal = function()
			self:_shop("arsenal")
		end,
		openLocker = function()
			self:_shop("locker")
		end,
		openFlagShop = function()
			self:_shop("flags")
		end,
		openStarter = function()
			self:openStarter()
		end,
		openGeneral = function()
			self:openGeneral()
		end,
		openParty = function()
			openModal(function()
				return Party.open(root.modal, self.party, function(request)
					PartyRemote:FireServer(request)
				end)
			end)
		end,
	})
	self.menu = menu
	-- A public match's own server shows the waiting room instead of the menu
	-- (Bruno, 2026-11-04), from the first frame. The server says which kind
	-- it is (WaitingRoom.ROLE_ATTRIBUTE): a client can't read
	-- game.PrivateServerId, so asking Roblox here never built the room.
	self.makeRoom = function()
		if self.room == nil then
			self.room = WaitingRoom.new(root.menu, root, {
				leave = function()
					Start:FireServer({ mode = "unqueue" })
				end,
				retry = function()
					Start:FireServer({ mode = "unqueue" })
				end,
			})
			self.room:setVisible(self.visible)
		end
	end
	local soloAsked = false
	local function roleChanged()
		local role = ReplicatedStorage:GetAttribute(WaitingRoomModel.ROLE_ATTRIBUTE)
		if role == WaitingRoomModel.ROLE_MATCH then
			self.makeRoom()
		elseif role == WaitingRoomModel.ROLE_SOLO and not soloAsked then
			-- A solo match's own server (audit F3): a cover until the match's
			-- snapshot arrives (setVisible(false) takes it down), and the
			-- server is told this client is ready, which starts the match.
			soloAsked = true
			self.soloCover = Loading.new(root.modal)
			self.soloCover:show("Deploying")
			Start:FireServer({ mode = "ready" })
		end
	end
	roleChanged()
	table.insert(self.connections, ReplicatedStorage:GetAttributeChangedSignal(WaitingRoomModel.ROLE_ATTRIBUTE):Connect(roleChanged))

	table.insert(self.connections, Menu.OnClientEvent:Connect(function(payload: any)
		if type(payload) ~= "table" then
			return
		end
		-- (a room the server sends is shown even if the attribute was missed)
		if type(payload.room) == "table" then
			self.makeRoom()
		end
		if self.room and not self.room:isReturning() then
			self.room:setRoom(if type(payload.room) == "table" then payload.room else nil)
		end
		menu:setLobbies(payload.lobbies or {}, payload.queued, payload.queueState)
		self.party = payload.party
		if payload.party and #payload.party.members > 1 then
			local names = {}
			for _, m in payload.party.members do
				table.insert(names, m.name)
			end
			menu.partyText.Text = `Squad: {table.concat(names, ", ")}`
		else
			menu.partyText.Text = ""
		end
	end))
	local function onView(view: any)
		if type(view) ~= "table" then
			return
		end
		local first = self.view == nil
		local before = if self.view then self.view.stars else nil
		self.view = view
		-- A profile that couldn't load plays unsaved (Store.luau): say so once
		-- (audit F13; the old menu's "PROGRESS NOT SAVED" line went with it).
		if first and view.saved == false then
			self:notice("Your progress couldn't load. You can play, but nothing is saved this session. Rejoin to try again.")
		end
		-- Stars a match just paid (the result card shows them).
		if before and view.stars > before and self.starsGained then
			self.starsGained(view.stars - before)
		end
		menu:setProfile(view)
		if first then
			self:setSettings(view.settings)
			-- A new player's first match starts by itself, as the tutorial
			-- (RoWorld: 14% of new players never started one). Only on a hub:
			-- a solo or match server already has its match.
			local role = ReplicatedStorage:GetAttribute(WaitingRoomModel.ROLE_ATTRIBUTE)
			if Tutorial.isNew(view) and (role == nil or role == WaitingRoomModel.ROLE_HUB) then
				task.delay(0.9, function()
					if self.visible and self.modal == nil and self.soloCover == nil then
						self.soloCover = Loading.new(root.modal)
						self.soloCover:show("Basic training")
						Start:FireServer({ mode = "solo", tutorial = true })
					end
				end)
			end
			-- The starter pack opens by itself once a session while it's
			-- for them (its first time starts its clock). Never on its way into
			-- the tutorial, nor over a match on a solo or match server (no
			-- offers during guided play, after RoWorld).
			local onHub = role == nil or role == WaitingRoomModel.ROLE_HUB
			if view.starter ~= nil and onHub and not Tutorial.isNew(view) then
				task.delay(1.5, function()
					if self.modal == nil and self.visible and self.soloCover == nil then
						self:openStarter()
					end
				end)
			end
		end
		if self.starterOffer and view.starter == nil then
			self.starterOffer.close() -- bought (or over)
		end
		-- A shop on screen redraws with what changed.
		if self.shop and self.modal then
			self:_shop(self.shop)
		end
	end
	table.insert(self.connections, ProfileRemote.OnClientEvent:Connect(onView))
	-- The first push may come before this listener: ask for it, until the
	-- profile has loaded.
	task.spawn(function()
		for _ = 1, 20 do
			if self.view then
				return
			end
			local ok, result = pcall(function()
				return Shop:InvokeServer({ op = "view" })
			end)
			if ok and type(result) == "table" and result.view then
				onView(result.view)
				return
			end
			task.wait(1)
		end
	end)
	table.insert(self.connections, Granted.OnClientEvent:Connect(function(grant: any)
		if type(grant) == "table" and type(grant.items) == "table" and grant.items[1] then
			if self.sound then
				self.sound("menu.purchase")
			end
			task.defer(function()
				if CRATE_PRODUCTS[grant.product] then
					self:_openCrate(grant.items)
				else
					self:_reveal(grant.items[1])
				end
			end)
		end
	end))
	local offers = FlagShop.offers(os.time())
	local cardFlag = if offers.event then offers.event.flags[1] else offers.daily[1]
	-- During an event the folder counts to the event's end (Bruno, 2026-11-11).
	menu:setFlagShop(if offers.event then offers.event.endsAt else offers.nextDailyAt, if offers.event then `{offers.event.name} flags` else nil)
	menu:setFlagCard(cardFlag)
	table.insert(self.connections, PartyRemote.OnClientEvent:Connect(function(payload: any)
		if type(payload) == "table" and payload.op == "invited" then
			self:_inviteNotice(payload.name, payload.userId, function()
				PartyRemote:FireServer({ op = "accept", userId = payload.userId })
			end)
		end
	end))
	return self
end

function MenuController.openHowToPlay(self: any)
	self.openModal(function()
		return HowToPlay.open(self.root.modal, self.hooks.config())
	end)
end

function MenuController.openSettings(self: any)
	self.openModal(function()
		return Settings.open(self.root.modal, self.settings, function(s)
			self:_applySettings(s)
		end, function()
			self:openHowToPlay()
		end)
	end)
end

function MenuController._applySettings(self: any, s: PlayerSettings.Settings)
	self.settings = PlayerSettings.sanitize(s)
	self.root:setUserScale(self.settings.uiScale)
	Dossier.soundsOn = self.settings.sounds
	self.menu:setMusicOn(self.settings.music)
	if self.hooks.settingsChanged then
		self.hooks.settingsChanged(self.settings)
	end
	-- Saved with the profile, a moment after the last change.
	self.settingsAt = os.clock()
	local at = self.settingsAt
	task.delay(1, function()
		if self.settingsAt == at then
			pcall(function()
				self.shopRemote:InvokeServer({ op = "settings", settings = self.settings })
			end)
		end
	end)
end

-- Settings loaded from the profile.
function MenuController.setSettings(self: any, raw: any)
	self.settings = PlayerSettings.sanitize(raw)
	self.root:setUserScale(self.settings.uiScale)
	Dossier.soundsOn = self.settings.sounds
	self.menu:setMusicOn(self.settings.music)
	if self.hooks.settingsChanged then
		self.hooks.settingsChanged(self.settings)
	end
end

-- Conquest General's window: perks, price and SUBSCRIBE (or "your perks
-- are on" for a General).
function MenuController.openGeneral(self: any)
	local view = self.view
	self.openModal(function()
		return GeneralOffer.open(self.root.modal, view ~= nil and view.general == true) :: any
	end)
end

-- The starter pack's offer window. Its first showing starts the clock.
function MenuController.openStarter(self: any)
	local view = self.view
	if view == nil or view.starter == nil then
		return
	end
	if view.starter == "ready" then
		pcall(function()
			self.shopRemote:InvokeServer({ op = "starterSeen" })
		end)
	end
	self.openModal(function()
		local offer = StarterOffer.open(self.root.modal, if view.starter == "active" then view.starterLeft else nil, function()
			local id = Products[Catalog.STARTER.product]
			if id then
				MarketplaceService:PromptProductPurchase(Players.LocalPlayer, id)
			end
		end)
		self.starterOffer = offer
		offer.root.Destroying:Connect(function()
			if self.starterOffer == offer then
				self.starterOffer = nil
			end
		end)
		return offer :: any
	end)
end

-- Opens (or redraws) a shop: "arsenal", "locker" or "flags".
function MenuController._shop(self: any, which: string)
	if self.view == nil then
		return -- the profile hasn't arrived yet
	end
	local root = self.root
	local ctx = {
		view = self.view,
		request = function(req: { [string]: any }): { [string]: any }?
			local ok, result = pcall(function()
				return self.shopRemote:InvokeServer(req)
			end)
			return if ok then result else nil
		end,
		prompt = function(key: string)
			if key == "general" and Catalog.SUBSCRIPTION.id ~= "" then
				MarketplaceService:PromptSubscriptionPurchase(Players.LocalPlayer, Catalog.SUBSCRIPTION.id)
				return
			end
			local product = Catalog.product(key)
			local id = Products[key]
			if product == nil or id == nil then
				return
			end
			if product.kind == "pass" then
				MarketplaceService:PromptGamePassPurchase(Players.LocalPlayer, id)
			else
				MarketplaceService:PromptProductPurchase(Players.LocalPlayer, id)
			end
		end,
		reveal = function(itemId: string)
			-- A stars purchase went through.
			if self.sound then
				self.sound("menu.purchase")
			end
			task.defer(function()
				self:_reveal(itemId)
			end)
		end,
		crate = function(itemId: string)
			if self.sound then
				self.sound("menu.purchase")
			end
			task.defer(function()
				self:_openCrate({ itemId })
			end)
		end,
	}
	-- A redraw (the profile changed) keeps the shop's tab, scroll and played
	-- intro; a fresh open starts from the last revealed kind.
	if not (self.shop == which and self.modal and self.shopMemo) then
		self.shopMemo = { tab = self.shopTab }
	end
	ctx.memo = self.shopMemo
	self.openModal(function()
		local modal
		if which == "arsenal" then
			modal = Shops.arsenal(root.modal, ctx)
		elseif which == "locker" then
			modal = Shops.locker(root.modal, ctx)
		else
			modal = Shops.flagShop(root.modal, ctx)
		end
		modal.root.Destroying:Connect(function()
			if self.modal == modal then
				self.shop = nil
			end
		end)
		return modal
	end)
	self.shop = which
end

-- A crate (stars or Robux; three items for the 3-pack): the crate opening in
-- its own layer, its last frame the "You got" moment. Without the crate
-- models (still loading, or failed) it is the plain card, one per item.
function MenuController._openCrate(self: any, items: { string })
	local item = Catalog.get(items[1])
	if item then
		self.shopTab = item.kind
	end
	if self.modal then
		self.modal.close()
		self.modal = nil
	end
	self.shop = nil
	local opening = CrateOpening.play({
		items = items,
		sound = self.sound,
		onDone = function()
			self.crate = nil
		end,
	})
	if opening == nil then
		self:_reveal(items[1])
		return
	end
	self.crate = opening
end

function MenuController._reveal(self: any, itemId: string)
	if self.sound then
		self.sound("menu.reveal")
	end
	local item = Catalog.get(itemId)
	if item then
		self.shopTab = item.kind
	end
	self.shop = nil
	self.openModal(function()
		return Shops.reveal(self.root.modal, itemId)
	end)
end

-- "Ada invited you to their party" with Accept, for 20 seconds.
-- A short pinned note on the menu (why a public match join didn't work);
-- one at a time, gone after 6 s.
function MenuController.notice(self: any, text: string)
	if self.noticeCard and self.noticeCard.Parent then
		self.noticeCard:Destroy()
	end
	if self.sound then
		self.sound("ui.error")
	end
	local card = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { Name = "MenuNotice", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 20), Size = UDim2.fromOffset(600, 70), Rotation = 0.5, ZIndex = 60, Parent = self.root.modal })
	Kit.stroke(C.sheetLine, 1.5, 0).Parent = card
	Dossier.art("pin", { AnchorPoint = Vector2.new(0.5, 0.75), Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.fromOffset(22, 30), ZIndex = 62, Parent = card })
	Kit.glyph("info", { ImageColor3 = C.stamp, Size = UDim2.fromOffset(30, 30), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 18, 0.5, 0), ZIndex = 61, Parent = card })
	Dossier.typed({ Text = text, TextColor3 = C.inkBlack, TextSize = 19, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 60, 0.5, 0), Size = UDim2.new(1, -76, 1, -12), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 61, Parent = card })
	self.noticeCard = card
	task.delay(6, function()
		if card.Parent then
			card:Destroy()
		end
	end)
end

function MenuController._inviteNotice(self: any, name: string, _userId: number, accept: () -> ())
	if self.sound then
		self.sound("menu.invite")
	end
	-- A pinned paper note with a yellow ACCEPT plate (the dossier look).
	local card = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { Name = "InviteNotice", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 20), Size = UDim2.fromOffset(600, 86), Rotation = -0.5, ZIndex = 60, Parent = self.root.modal })
	Kit.stroke(C.sheetLine, 1.5, 0).Parent = card
	Dossier.art("pin", { AnchorPoint = Vector2.new(0.5, 0.75), Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.fromOffset(22, 30), ZIndex = 62, Parent = card })
	Kit.glyph("party", { ImageColor3 = C.inkBlack, Size = UDim2.fromOffset(34, 34), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 18, 0.5, 0), ZIndex = 61, Parent = card })
	Dossier.typed({ Text = `{name} invited you to their party`, TextColor3 = C.inkBlack, TextSize = 21, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 64, 0.5, 0), ZIndex = 61, Parent = card })
	local ok = Dossier.rivetPlate(card, "ACCEPT", 22, true, { Position = UDim2.new(1, -78, 0.5, 0), Size = UDim2.fromOffset(130, 52), ZIndex = 61, Parent = card })
	ok.Activated:Connect(function()
		accept()
		card:Destroy()
	end)
	task.delay(20, function()
		if card.Parent then
			card:Destroy()
		end
	end)
end

function MenuController.setVisible(self: any, visible: boolean)
	self.visible = visible
	if not visible and self.soloCover then
		self.soloCover:hide()
	end
	self.menu:setVisible(visible)
	if self.room then
		self.room:setVisible(visible)
	end
	if not visible and self.modal then
		self.modal.close()
		self.modal = nil
	end
end

-- On a match server: the match is over (or LEAVE), the return teleport has
-- begun.
function MenuController.setReturning(self: any)
	self.makeRoom()
	self.room:setReturning()
end

function MenuController.destroy(self: any)
	for _, c in self.connections do
		c:Disconnect()
	end
	if self.crate then
		self.crate.close()
	end
	if self.room then
		self.room:destroy()
	end
	self.menu:destroy()
end

return MenuController
