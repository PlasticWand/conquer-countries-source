--!strict
-- The store on the server (docs/design/rofront-ui-pass.md; items in
-- docs/design/store-items.md): each player's saved record (Store/Profile)
-- behind ProfileStore's session lock, Robux receipts granted once and saved
-- before Roblox is told, the 2x Stars pass, the shops' star purchases and
-- equips, settings, and the stars each match pays.
--   Remotes: Shop (RemoteFunction) takes { op = "view" } | { op = "unlock", id } |
--   { op = "crate" } | { op = "equip", kind, id? } | { op = "chooseFlag", id }
--   | { op = "settings", settings } and answers { ok, reason?, item? };
--   Profile (RemoteEvent) pushes Store/Profile.view after every change;
--   Granted (RemoteEvent) tells the buyer what a Robux purchase gave.
-- Studio uses its own store and falls back to memory when the place can't
-- reach DataStores. A record that can't be loaded on a live server: the
-- player plays unsaved and their record is never overwritten.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)
local Profile = require(Shared.Store.Profile)
local ProfileStore = require(Shared.ProfileStore)
local Products = require(Shared.Store.Products) :: { [string]: number }
local Analytics = require(script.Parent.Analytics)

local Store = {}

local AUTOSAVE_SECONDS = 120
local REQUESTS_PER_10S = 30

type Entry = {
	record: Profile.Record,
	saved: boolean, -- false: never write (load failed or the lock was lost)
	dirty: boolean,
	doubleStars: boolean,
	general: boolean, -- subscribed to Conquest General (Catalog.SUBSCRIPTION)
	-- Whether Roblox has answered yet for the 2x Stars pass and the
	-- subscription (a failed check is asked again each minute).
	passKnown: boolean,
	generalKnown: boolean,
	requests: { number },
}

local entries: { [number]: Entry } = {}
local loading: { [number]: boolean } = {}
local productKey: { [number]: string } = {}
for key, id in Products do
	productKey[id] = key
end
local rng = Random.new()
local function roll(): number
	return rng:NextNumber()
end

local deps: ProfileStore.Deps
local profileRemote: RemoteEvent
local grantedRemote: RemoteEvent

-- Called with a leaving player before their last save (OpenFrontServer pays
-- the stars of the match they are leaving), so the save doesn't depend on
-- which PlayerRemoving handler happens to run first.
local leavingHook: ((Player) -> ())? = nil
function Store.onLeaving(fn: (Player) -> ())
	leavingHook = fn
end

-- Called with the player after every profile change (OpenFrontServer: a
-- weapon unlocked mid-match reaches that match at once).
local changedHook: ((Player) -> ())? = nil
function Store.onChanged(fn: (Player) -> ())
	changedHook = fn
end

-- Called once with each player whose profile has loaded (OpenFrontServer:
-- analytics' new-player funnel).
local loadedHook: ((Player) -> ())? = nil
function Store.onLoaded(fn: (Player) -> ())
	loadedHook = fn
end

local function push(player: Player)
	local e = entries[player.UserId]
	if e then
		profileRemote:FireClient(player, Profile.view(e.record, e.saved, e.doubleStars, e.general))
		if changedHook then
			task.spawn(changedHook, player)
		end
	end
end

local function save(player: Player, release: boolean): boolean
	local e = entries[player.UserId]
	if e == nil or not e.saved then
		return false
	end
	local ok, reason = ProfileStore.save(deps, player.UserId, e.record, release)
	if ok then
		e.dirty = false
	elseif reason == "lockLost" then
		e.saved = false
	end
	return ok
end

local function load(player: Player)
	if loading[player.UserId] or entries[player.UserId] then
		return
	end
	loading[player.UserId] = true
	local record, reason = ProfileStore.load(deps, player.UserId)
	loading[player.UserId] = nil
	if player.Parent == nil then
		if record then
			ProfileStore.save(deps, player.UserId, record, true)
		end
		return
	end
	local double, passKnown = false, false
	pcall(function()
		double = MarketplaceService:UserOwnsGamePassAsync(player.UserId, Products.doubleStars)
		passKnown = true
	end)
	-- (they may have left while Roblox answered)
	if not player:IsDescendantOf(Players) then
		if record then
			ProfileStore.save(deps, player.UserId, record, true)
		end
		return
	end
	entries[player.UserId] = {
		record = record or Profile.new(),
		saved = record ~= nil,
		dirty = false,
		doubleStars = double,
		general = false,
		passKnown = passKnown,
		generalKnown = false,
		requests = {},
	}
	if record == nil then
		warn(`[Store] {player.UserId} plays unsaved: {reason}`)
	end
	push(player)
	if loadedHook then
		task.spawn(loadedHook, player)
	end
end

local function allowed(e: Entry): boolean
	local now = os.clock()
	while #e.requests > 0 and now - e.requests[1] > 10 do
		table.remove(e.requests, 1)
	end
	if #e.requests >= REQUESTS_PER_10S then
		return false
	end
	table.insert(e.requests, now)
	return true
end

local function onShop(player: Player, request: any): any
	local e = entries[player.UserId]
	if e == nil or type(request) ~= "table" or not allowed(e) then
		return { ok = false, reason = "busy" }
	end
	local result: { [string]: any } = { ok = false }
	-- The Store funnel (Analytics): a window opened, a Robux prompt shown.
	-- Nothing to save.
	if request.op == "shopOpened" and type(request.where) == "string" then
		Analytics.shopOpened(player, request.where)
		return { ok = true }
	elseif request.op == "shopPrompted" and type(request.product) == "string" then
		if request.product == "general" or Catalog.product(request.product) ~= nil then
			Analytics.shopPrompted(player, request.product)
		end
		return { ok = true }
	end
	if request.op == "view" then
		return { ok = true, view = Profile.view(e.record, e.saved, e.doubleStars, e.general) }
	elseif request.op == "unlock" and type(request.id) == "string" then
		local ok, reason = Profile.unlockWithStars(e.record, request.id)
		result = { ok = ok, reason = reason }
	elseif request.op == "crate" then
		local item, reason = Profile.crateWithStars(e.record, roll)
		result = { ok = item ~= nil, reason = reason, item = if item then item.id else nil }
	elseif request.op == "equip" and type(request.kind) == "string" and (request.id == nil or type(request.id) == "string") then
		result = { ok = Profile.equip(e.record, request.kind, request.id) }
	elseif request.op == "chooseFlag" and type(request.id) == "string" then
		result = { ok = Profile.chooseFlag(e.record, request.id, os.time()) }
	elseif request.op == "starterSeen" then
		-- The starter pack's offer is on their screen: its clock starts.
		result = { ok = Profile.starterSeen(e.record, os.time()) }
		if not result.ok then
			return { ok = true }
		end
	elseif request.op == "claimGift" then
		-- The launch event's free starter pack (Catalog.LAUNCH_GIFT).
		local grant = Profile.claimGift(e.record, os.time())
		result = { ok = grant ~= nil, reason = if grant then nil else "over", items = if grant then grant.items else nil }
		if grant then
			Analytics.giftClaimed(player, #grant.items)
		end
	elseif request.op == "adCrate" then
		-- A rewarded video ad for a free Cosmetic Crate (2026-11-15 review,
		-- Bruno: "Do them all"). Roblox grants the crate1 product through
		-- ProcessReceipt when the ad completes; nothing is saved here.
		return Store.showAdCrate(player)
	elseif request.op == "settings" then
		local PlayerSettings = require(Shared.PlayerSettings)
		e.record.settings = PlayerSettings.sanitize(request.settings)
		result = { ok = true }
	end
	if result.ok then
		e.dirty = true
		push(player)
	end
	return result
end

-- Rewarded video ads (AdService): the reward is the Cosmetic Crate product,
-- granted like a purchase. One ad at a time a player, and AD_COOLDOWN_S
-- between completed ones on this server (Roblox applies its own limits too).
Store.AD_PRODUCT = "crate1"
Store.AD_COOLDOWN_S = 10 * 60
local adReward: any = nil
local adBusy: { [Player]: boolean } = {}
local adDoneAt: { [Player]: number } = {}

function Store.showAdCrate(player: Player): { [string]: any }
	local id = Products[Store.AD_PRODUCT]
	if id == nil or RunService:IsStudio() then
		return { ok = false, reason = "unavailable" }
	end
	if adBusy[player] or os.clock() - (adDoneAt[player] or -math.huge) < Store.AD_COOLDOWN_S then
		return { ok = false, reason = "wait" }
	end
	adBusy[player] = true
	task.spawn(function()
		local ok, result = pcall(function(): any
			local AdService = game:GetService("AdService")
			if adReward == nil then
				adReward = AdService:CreateAdRewardFromDevProductId(id)
			end
			return AdService:ShowRewardedVideoAdAsync(player, adReward)
		end)
		adBusy[player] = nil
		local completed = ok and result == Enum.ShowAdResult.ShowCompleted
		if completed then
			adDoneAt[player] = os.clock()
		elseif not ok then
			warn(`[Store] rewarded ad failed: {result}`)
		end
		if player.Parent ~= nil then
			Analytics.adWatched(player, completed)
		end
	end)
	return { ok = true }
end

-- Invite rewards (Catalog.REFERRAL). An inviter may be on another server
-- (their profile is session-locked there), so a credit goes into a small
-- separate key per inviter, which their own server collects: on joining and
-- every REFERRAL_COLLECT_S while they play.
Store.REFERRAL_COLLECT_S = 5 * 60
local referralStore: any = nil

local function referralKey(userId: number): string
	return `ref_{userId}`
end

-- The friend who invited a brand-new player, from Roblox's join data
-- (ReferredByPlayerId, set for every invite type), or the invite's launch
-- data. It can take a few seconds to arrive.
local function readReferrer(player: Player): number?
	for _ = 1, 10 do
		local ok, data = pcall(function(): any
			return player:GetJoinData()
		end)
		if ok and type(data) == "table" then
			local id = tonumber((data :: any).ReferredByPlayerId)
			if id == nil and type(data.LaunchData) == "string" then
				id = tonumber(string.match(data.LaunchData, "^ref:(%d+)$"))
			end
			if id and id > 0 then
				return id
			end
		end
		task.wait(1)
		if player.Parent == nil then
			return nil
		end
	end
	return nil
end

local function noteReferrer(player: Player)
	local inviter = readReferrer(player)
	local e = entries[player.UserId]
	if inviter and e and Profile.setReferrer(e.record, inviter, player.UserId) then
		e.dirty = true
	end
end

-- Adds one friend's credit to the inviter's key (a few tries).
local function creditInviter(inviterId: number)
	if referralStore == nil then
		return
	end
	for attempt = 1, 3 do
		local ok = pcall(function()
			referralStore:UpdateAsync(referralKey(inviterId), function(n: any): any
				return (if type(n) == "number" then n else 0) + 1
			end)
		end)
		if ok then
			return
		end
		task.wait(attempt * 2)
	end
	warn(`[Store] invite credit for {inviterId} failed`)
end

-- Collects the player's waiting credits and pays the stars (the day's limit;
-- the rest go back for later).
local function collectReferrals(player: Player)
	local e = entries[player.UserId]
	if referralStore == nil or e == nil or not e.saved then
		return
	end
	local taken = 0
	local ok = pcall(function()
		referralStore:UpdateAsync(referralKey(player.UserId), function(n: any): any
			taken = if type(n) == "number" and n > 0 then n else 0
			return if taken > 0 then 0 else nil
		end)
	end)
	if not ok or taken <= 0 or entries[player.UserId] ~= e then
		return
	end
	local stars, left = Profile.payReferrals(e.record, taken, os.time() // 86400)
	if stars > 0 then
		e.dirty = true
		push(player)
		grantedRemote:FireClient(player, { items = {}, stars = stars, product = "referral" })
		Analytics.referralPaid(player, stars // Catalog.REFERRAL.stars)
	end
	if left > 0 then
		pcall(function()
			referralStore:UpdateAsync(referralKey(player.UserId), function(n: any): any
				return (if type(n) == "number" then n else 0) + left
			end)
		end)
	end
end

-- MarketplaceService.ProcessReceipt: grant once, save, then confirm.
local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local e = entries[receipt.PlayerId]
	local key = productKey[receipt.ProductId]
	if player == nil or e == nil or key == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- Granted once, and confirmed only once it is saved (Profile.processReceipt):
	-- an unsaved session can't keep it, so Roblox offers it again later.
	local confirm, grant = Profile.processReceipt(e.record, e.saved, key, tostring(receipt.PurchaseId), roll, os.time(), function(): boolean
		return save(player, false)
	end)
	if grant then
		e.dirty = true
		push(player)
		grantedRemote:FireClient(player, { items = grant.items, stars = grant.stars, product = key })
		Analytics.shopPurchased(player, key)
	end
	return if confirm then Enum.ProductPurchaseDecision.PurchaseGranted else Enum.ProductPurchaseDecision.NotProcessedYet
end

-- Stars for a finished (or abandoned) match; returns what was paid.
function Store.matchEnded(player: Player, result: Profile.MatchResult): number
	local e = entries[player.UserId]
	if e == nil then
		return 0
	end
	local stars = Profile.applyMatch(e.record, result, e.doubleStars or e.record.owned.b_double == true, e.general)
	e.dirty = true
	push(player)
	-- An invited player's first real match: their inviter earns the reward.
	local inviter = if result.minutes >= Catalog.REFERRAL.minMinutes then Profile.referralDue(e.record) else nil
	if inviter then
		task.spawn(creditInviter, inviter)
	end
	return stars
end

-- Matches the player has played (finished or left), or nil before the
-- profile loads.
function Store.matchesOf(player: Player): number?
	local e = entries[player.UserId]
	return if e then e.record.matches else nil
end

-- The player's saved tutorial state (nil: never began it).
function Store.tutorialOf(player: Player): string?
	local e = entries[player.UserId]
	return if e then e.record.tutorial else nil
end

-- The tutorial (Shared/Tutorial): where it got to, a coach tip shown, and
-- its stars (once per player; what was paid now).
function Store.setTutorial(player: Player, how: string)
	local e = entries[player.UserId]
	if e and Profile.setTutorial(e.record, how) then
		e.dirty = true
		push(player)
	end
end

function Store.tipSeen(player: Player, id: string)
	local e = entries[player.UserId]
	if e and Profile.tipSeen(e.record, id) then
		e.dirty = true
		push(player)
	end
end

function Store.payTutorial(player: Player, stars: number): number
	local e = entries[player.UserId]
	if e == nil then
		return 0
	end
	local paid = Profile.payTutorial(e.record, stars)
	if paid > 0 then
		e.dirty = true
		push(player)
	end
	return paid
end

-- Spends one of the player's saved Takeovers (the Arsenal's, 25 R$ a use);
-- false when they have none. Refund puts it back (the takeover failed).
function Store.spendTakeover(player: Player): boolean
	local e = entries[player.UserId]
	if e == nil or not Profile.spendTakeover(e.record) then
		return false
	end
	e.dirty = true
	push(player)
	return true
end

function Store.refundTakeover(player: Player)
	local e = entries[player.UserId]
	if e ~= nil then
		e.record.takeovers += 1
		e.dirty = true
		push(player)
	end
end

-- Conquest General (Catalog.SUBSCRIPTION): whether Roblox says the player is
-- subscribed, and the day's crate once per UTC day while they are (on
-- joining, on subscribing, and at the first check of a new day).
local function generalStatus(player: Player): boolean?
	local id = Catalog.SUBSCRIPTION.id
	if id == "" then
		return false
	end
	for _ = 1, 3 do
		local ok, status = pcall(function()
			return MarketplaceService:GetUserSubscriptionStatusAsync(player, id)
		end)
		if ok and type(status) == "table" then
			return status.IsSubscribed == true
		end
		task.wait(2)
	end
	return nil
end

local function generalCrate(player: Player)
	local e = entries[player.UserId]
	if e == nil or not e.general then
		return
	end
	local items, stars = {}, 0
	-- The month's General skin, theirs to keep.
	local skin = Catalog.generalSkin(os.time())
	if skin and not e.record.owned[skin] then
		e.record.owned[skin] = true
		table.insert(items, skin)
	end
	-- The day's crate.
	if Profile.generalDue(e.record, os.time() // 86400) then
		local item = Profile.openCrate(e.record, roll)
		if item then
			table.insert(items, item.id)
		else
			e.record.stars += Profile.DUPLICATE_STARS
			stars = Profile.DUPLICATE_STARS
		end
	end
	if #items == 0 and stars == 0 then
		return
	end
	e.dirty = true
	push(player)
	grantedRemote:FireClient(player, { items = items, stars = stars, product = "general" })
end

local function checkGeneral(player: Player)
	local e = entries[player.UserId]
	if e == nil then
		return
	end
	local on = generalStatus(player)
	if on == nil or entries[player.UserId] ~= e then
		return
	end
	local wasKnown = e.generalKnown
	e.generalKnown = true
	if on ~= e.general then
		e.general = on
		push(player)
		-- (A new subscription mid-session, not one found when they joined.)
		if on and wasKnown then
			Analytics.shopPurchased(player, "general")
		end
	end
	generalCrate(player)
end

-- The player's Arsenal weapons and what they wear, for a match.
function Store.loadout(player: Player): { weapons: { [string]: boolean }, skin: string?, flag: string? }
	local e = entries[player.UserId]
	if e == nil then
		return { weapons = {} }
	end
	return { weapons = Profile.weapons(e.record), skin = e.record.equipped.skin, flag = e.record.equipped.flag }
end

function Store.start(remotes: Folder)
	-- The remotes first: the DataStore probe below can take seconds in
	-- Studio, and clients wait for them (a Shop call before a profile has
	-- loaded answers "busy").
	profileRemote = Instance.new("RemoteEvent")
	profileRemote.Name = "Profile"
	profileRemote.Parent = remotes
	-- What a Robux purchase gave ({ items, stars, product }: the product key
	-- tells a crate, which plays the crate opening, from a direct unlock).
	grantedRemote = Instance.new("RemoteEvent")
	grantedRemote.Name = "Granted"
	grantedRemote.Parent = remotes
	local shop = Instance.new("RemoteFunction")
	shop.Name = "Shop"
	shop.OnServerInvoke = onShop
	shop.Parent = remotes
	local storeName = if RunService:IsStudio() then "ConquestStore_Studio" else "ConquestStore_v1"
	local real: any = nil
	local ok = pcall(function()
		real = DataStoreService:GetDataStore(storeName)
		if RunService:IsStudio() then
			real:GetAsync("probe")
		end
	end)
	deps = {
		store = if ok and real then real else ProfileStore.memoryStore(),
		codec = { new = Profile.new, encode = Profile.encode, decode = Profile.decode },
		session = HttpService:GenerateGUID(false),
		now = os.time,
		wait = task.wait,
		loadAttempts = if ok then 5 else 1,
		retrySeconds = 2,
		log = function(message: string)
			warn(message)
		end,
	}
	if not ok then
		warn("[Store] DataStores unavailable here: profiles are kept in memory for this session")
	else
		pcall(function()
			referralStore = DataStoreService:GetDataStore(if RunService:IsStudio() then "ConquestReferrals_Studio" else "ConquestReferrals_v1")
		end)
	end
	MarketplaceService.ProcessReceipt = processReceipt
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, bought: boolean)
		local e = entries[player.UserId]
		if bought and e and passId == Products.doubleStars then
			e.doubleStars = true
			push(player)
			Analytics.shopPurchased(player, "doubleStars")
		end
	end)
	if RunService:IsStudio() then
		-- Studio-only probe for MCP checks: Invoke("newPlayer") resets the
		-- tutorial and its tips; Invoke("resetGift") unclaims the launch
		-- gift; Invoke("brandNew") makes a first-time player; Invoke("stars", n) gives every
		-- player n stars; returns each profile's view.
		local probe = Instance.new("BindableFunction")
		probe.Name = "StoreDebug"
		probe.OnInvoke = function(code: string?, amount: number?)
			local out = {}
			for _, player in Players:GetPlayers() do
				local e = entries[player.UserId]
				if e then
					if code == "stars" and type(amount) == "number" then
						e.record.stars += amount
						e.dirty = true
						push(player)
					elseif code == "newPlayer" then
						-- The tutorial and its tips as for a new player (the
						-- Studio store only; matches stay as they are).
						e.record.tutorial = nil
						e.record.tipsSeen = {}
						e.record.tutorialPaid = false
						e.dirty = true
						push(player)
					elseif code == "brandNew" then
						-- A first-time player (the Studio store only): no
						-- matches, no tutorial or tips, the launch gift unclaimed.
						e.record.matches = 0
						e.record.tutorial = nil
						e.record.tipsSeen = {}
						e.record.tutorialPaid = false
						e.record.giftClaimed = false
						for _, id in Catalog.STARTER.items do
							e.record.owned[id] = nil
						end
						e.dirty = true
						push(player)
					elseif code == "resetGift" then
						-- The launch gift unclaimed and its items gone (the
						-- Studio store only), to test the event again.
						e.record.giftClaimed = false
						for _, id in Catalog.STARTER.items do
							e.record.owned[id] = nil
						end
						e.dirty = true
						push(player)
					end
					out[player.Name] = Profile.view(e.record, e.saved, e.doubleStars, e.general)
				end
			end
			return out
		end
		probe.Parent = game:GetService("ServerStorage")
	end
	local function joined(player: Player)
		load(player)
		task.spawn(noteReferrer, player)
		task.spawn(collectReferrals, player)
		checkGeneral(player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(joined, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(joined, player)
	end
	-- Conquest General: a new subscription (or a lapsed one), and each new
	-- UTC day's crate for those who stay.
	Players.UserSubscriptionStatusChanged:Connect(function(player: Player, subscriptionId: string)
		if subscriptionId == Catalog.SUBSCRIPTION.id then
			checkGeneral(player)
		end
	end)
	task.spawn(function()
		local collectAt = os.clock() + Store.REFERRAL_COLLECT_S
		while true do
			task.wait(60)
			if os.clock() >= collectAt then
				collectAt = os.clock() + Store.REFERRAL_COLLECT_S
				for _, player in Players:GetPlayers() do
					task.spawn(collectReferrals, player)
				end
			end
			for _, player in Players:GetPlayers() do
				local e = entries[player.UserId]
				if e and not e.generalKnown then
					-- Roblox didn't answer before: ask again (it grants the crate).
					task.spawn(checkGeneral, player)
				else
					task.spawn(generalCrate, player)
				end
				if e and not e.passKnown then
					task.spawn(function()
						local ok, owns = pcall(function()
							return MarketplaceService:UserOwnsGamePassAsync(player.UserId, Products.doubleStars)
						end)
						if ok and entries[player.UserId] == e then
							e.passKnown = true
							if owns and not e.doubleStars then
								e.doubleStars = true
								push(player)
							end
						end
					end)
				end
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		if leavingHook then
			pcall(leavingHook, player)
		end
		save(player, true)
		entries[player.UserId] = nil
		adBusy[player], adDoneAt[player] = nil, nil
	end)
	game:BindToClose(function()
		-- Every save gets to finish (Roblox allows 30 s), not a fixed 3 s.
		local left = 0
		for _, player in Players:GetPlayers() do
			left += 1
			task.spawn(function()
				if leavingHook then
					pcall(leavingHook, player)
				end
				save(player, true)
				left -= 1
			end)
		end
		local t0 = os.clock()
		while left > 0 and os.clock() - t0 < 25 do
			task.wait(0.1)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			for _, player in Players:GetPlayers() do
				local e = entries[player.UserId]
				if e and e.dirty then
					save(player, false)
				end
			end
		end
	end)
end

-- Sends the profile again (for example after the client's menu is built).
function Store.push(player: Player)
	push(player)
end

return Store
