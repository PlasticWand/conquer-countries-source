--!strict
-- Client adapter for the OpenFront port: remotes in and out, the confirmed
-- ClientState, the map renderer (Codex, Map/OpenFront) and the HUD (Ui/OpenFront).
--   - The current map's terrain comes from ReplicatedStorage.OpenFrontMaps,
--     which the server fills.
--   - A tap or click sends the tile and the attack ratio; the server decides
--     spawn/attack/boat, as OpenFront's inputEvent does.
--   - The Map module owns camera, picking, gestures and their cleanup.
--   - With a build-bar item chosen, the tap is a build_action instead
--     (OfActions); the player panel and the action sheet (right-click or
--     long-press) ask the server's Query remote what the player may do.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local OF = Shared:WaitForChild("OpenFront")
local ClientState = require(OF.ClientState)
local AudioCues = require(OF.AudioCues)
local FeelCues = require(OF.FeelCues)
local MapLoader = require(OF.MapLoader)

local MapCatalog = require(Shared.MapCatalog)
local Skins = require(Shared.Store.Skins)
local Products = require(Shared.Store.Products) :: { [string]: number }
local EngagePrompts = require(Shared.EngagePrompts)

local Renderer = require(script.Parent.Map.OpenFront.EditableRenderer)
local BuildPreviewController = require(script.Parent.Map.OpenFront.BuildPreviewController)
local Loading = require(script.Parent.Ui.Screens.Loading)
local MenuController = require(script.Parent.Ui.MenuController)
local OfActions = require(script.Parent.Ui.OpenFront.OfActions)
local OfHud = require(script.Parent.Ui.OpenFront.OfHud)
local TutorialController = require(script.Parent.Ui.OpenFront.TutorialController)
local Audio = require(script.Parent.Ui.OpenFront.Audio)
local Dossier = require(script.Parent.Ui.Dossier)
local Root = require(script.Parent.Ui.Root)

local OpenFrontClient = {}

function OpenFrontClient.start()
	local player = Players.LocalPlayer
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	end)
	local remotes = ReplicatedStorage:WaitForChild("OpenFrontRemotes")
	local Intent = remotes:WaitForChild("Intent") :: RemoteEvent
	local Start = remotes:WaitForChild("Start") :: RemoteEvent
	local Query = remotes:WaitForChild("Query") :: RemoteFunction

	local state = ClientState.new()
	local renderer: any = nil
	-- Studio-only probe for MCP checks.
	local debugInfo: { [string]: any } = {}
	if game:GetService("RunService"):IsStudio() then
		local probe = Instance.new("BindableFunction")
		probe.Name = "OpenFrontDebugClient"
		probe.OnInvoke = function(kind: string?, a: number?, b: number?)
			if kind == "owner" and a then
				return state:ownerAt(a)
			elseif kind == "terrain" and a and renderer then
				return buffer.readu8(renderer.core.terrain, a)
			elseif kind == "screen" and a and b and renderer then
				-- world tile -> screen position
				local sx, sy = renderer:worldToScreen(a + 0.5, b + 0.5)
				return { sx, sy }
			elseif kind == "render" and renderer then
				-- First-paint and raster metrics (Map/OpenFront README).
				return renderer:metrics()
			elseif kind == "preview" and renderer and renderer.scene then
				-- Read-only attribution for overlapping ranges in emulator captures.
				local scene=renderer.scene
				local discs,targets={},{}
				for key,f in scene.rangeViews do if f.Visible then
					local id=tonumber(key:match('^SamRange(%d+):'))
					local u=if id then state.units[id] else nil
					table.insert(discs,{key=key,radius=f.Size.X.Offset/128,unitID=id,
						owner=if u then u.owner else nil,tile=if u then u.tile else nil})
				end end
				for _,id in scene.nukeIds do local u=state.units[id]
					if u and u.active~=false and u.targetTile~=nil then table.insert(targets,{id=id,kind=u.type,owner=u.owner,targetTile=u.targetTile}) end
				end
				return {ghost=scene.buildPreview,trajectory=scene.preview,ranges=discs,nukeTargets=targets}
			elseif kind == "profile" and a then
				-- Where client frames go for `a` seconds (Bruno, 2026-11-08: FPS
				-- drops when big and conquering, and on pan/zoom): frame times,
				-- plus inclusive ms per call of every module-table function in the
				-- match's client modules (local helpers aren't seen). Studio only.
				local Map = script.Parent.Map.OpenFront
				local Ui = script.Parent.Ui.OpenFront
				local mods: { [string]: Instance } = {
					ClientState = OF.ClientState, AudioCues = OF.AudioCues, FeelCues = OF.FeelCues, HudModel = OF.HudModel,
					OfHud = Ui.OfHud, OfActions = Ui.OfActions, Audio = Ui.Audio,
				}
				for _, name in { "EditableRenderer", "SceneOverlay", "RasterCore", "EffectOverlay", "FeelOverlay", "FeelState", "NameStatusOverlay", "CoastOverlay", "MapInput", "CameraTransform", "FxState", "DeferredDirty", "SpawnOverlay", "MapGuiLayers", "NameClusters", "PlayerStatus" } do
					local m = Map:FindFirstChild(name)
					if m then
						mods[name] = m
					end
				end
				local times: { [string]: { n: number, ms: number, max: number } } = {}
				local undo = {}
				for modName, ms in mods do
					local ok, mod = pcall(require, ms :: ModuleScript)
					if ok and type(mod) == "table" then
						for key, fn in mod do
							if type(fn) == "function" then
								local label = modName .. "." .. tostring(key)
								local stat = { n = 0, ms = 0, max = 0 }
								times[label] = stat
								mod[key] = function(...)
									local t = os.clock()
									local r = table.pack(fn(...))
									local d = (os.clock() - t) * 1000
									stat.n += 1
									stat.ms += d
									if d > stat.max then
										stat.max = d
									end
									return table.unpack(r, 1, r.n)
								end
								table.insert(undo, function()
									mod[key] = fn
								end)
							end
						end
					end
				end
				local frames = {}
				local conn = game:GetService("RunService").RenderStepped:Connect(function(dt: number)
					table.insert(frames, dt * 1000)
				end)
				task.wait(a)
				conn:Disconnect()
				for _, u in undo do
					u()
				end
				table.sort(frames)
				local sum = 0
				for _, f in frames do
					sum += f
				end
				local top = {}
				for label, stat in times do
					if stat.n > 0 then
						table.insert(top, { label = label, perFrame = stat.ms / math.max(1, #frames), n = stat.n, max = stat.max })
					end
				end
				table.sort(top, function(x, y)
					return x.perFrame > y.perFrame
				end)
				local lines = {}
				for i = 1, math.min(30, #top) do
					local x = top[i]
					table.insert(lines, string.format("%s %.2fms/frame n=%d max=%.1f", x.label, x.perFrame, x.n, x.max))
				end
				return {
					frames = #frames,
					meanMs = if #frames > 0 then sum / #frames else 0,
					p95Ms = frames[math.max(1, math.ceil(#frames * 0.95))],
					maxMs = frames[#frames],
					top = lines,
				}
			elseif kind == "tap" and a and debugInfo.tap then
				-- A map tap on tile `a`, through the same handler as a real one.
				debugInfo.tap(a)
				return true
			end
			return {
				ready = state.ready,
				you = state.you,
				tick = state.tick,
				spawnPhase = state:inSpawnPhase(),
				players = #state.rosterOrder,
				attacks = #state.attacks,
				lastTap = debugInfo.lastTap,
				lastResult = debugInfo.lastResult,
			}
		end
		probe.Parent = player
	end

	-- Map surface sits under the HUD.
	local mapGui = Instance.new("ScreenGui")
	mapGui.Name = "OpenFrontMap"
	mapGui.IgnoreGuiInset = true
	-- IgnoreGuiInset alone selects DeviceSafeInsets. Its legacy fullscreen
	-- extension stretches qualifying map images independently of labels.
	mapGui.ScreenInsets = Enum.ScreenInsets.None
	mapGui.ClipToDeviceSafeArea = false
	mapGui.SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	mapGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	mapGui.ResetOnSpawn = false
	mapGui.DisplayOrder = 0
	local surface = Instance.new("Frame")
	surface.Name = "Surface"
	surface.Size = UDim2.fromScale(1, 1)
	surface.BackgroundColor3 = Color3.fromRGB(58, 58, 58)
	surface.BorderSizePixel = 0
	surface.Parent = mapGui
	mapGui.Parent = player:WaitForChild("PlayerGui")
	-- Bruno's picked sounds (Ui/OpenFront/Audio); AudioCues says which
	-- confirmed change makes which.
	local audio = Audio.new()
	local cues = AudioCues.new()
	-- The attack's second beat (FeelCues; Bruno, 2026-11-08).
	local feel = FeelCues.new()
	local menuShown = true
	local lastExpand: string? = nil

	local hud: any = nil
	local actionsUi: any = nil
	local buildPreview: any = nil
	-- In-match boosts (2026-11-23). `respawnPick`: Second Spawn is paid for
	-- (or a credit is waiting) and the next map tap is the new start.
	local respawnPick = false
	local BOOST_REASON: { [string]: string } = {
		wait = "Not yet: that boost is recharging.",
		nothing = "Nothing of yours is reloading.",
		late = "Too late in the match to start again.",
		used = "You've already started again this match.",
		tile = "Pick free land to start on.",
		dead = "You need land for that.",
	}
	local function boost(which: string, tile: number?)
		task.spawn(function()
			local r = Query:InvokeServer({ kind = "boost", boost = which, tile = tile })
			if type(r) ~= "table" then
				return
			end
			if r.ok and r.pick then
				respawnPick = true
				if hud then
					hud:notify("Tap free land to start again.", "info")
				end
				return
			end
			if r.ok then
				if which == "secondSpawn" then
					respawnPick = false
					if hud then
						hud.respawnUsed = true
					end
				end
				return
			end
			if r.reason ~= "needPurchase" then
				if hud and BOOST_REASON[r.reason] then
					hud:notify(BOOST_REASON[r.reason], "info")
				end
				return
			end
			local id = Products[which]
			local Granted = remotes:FindFirstChild("Granted") :: RemoteEvent?
			if id == nil or Granted == nil then
				return
			end
			-- Bought: ask again (Second Spawn then waits for the spot).
			local conn: RBXScriptConnection
			conn = Granted.OnClientEvent:Connect(function(grant: any)
				if type(grant) == "table" and grant.product == which then
					conn:Disconnect()
					local again = Query:InvokeServer({ kind = "boost", boost = which, tile = tile })
					if type(again) == "table" and again.ok and again.pick then
						respawnPick = true
						if hud then
							hud:notify("Tap free land to start again.", "info")
						end
					end
				end
			end)
			task.delay(180, function()
				if conn.Connected then
					conn:Disconnect()
				end
			end)
			game:GetService("MarketplaceService"):PromptProductPurchase(player, id)
		end)
	end
	-- The last solo setup (Restart in the pause menu) and the map's terrain
	-- bytes (the hover card's terrain name).
	local lastSolo: { map: string, difficulty: string }? = nil
	local hoverTerrain: buffer? = nil
	-- The tutorial and coach (Ui/OpenFront/TutorialController), built with the
	-- first HUD; its rookie floor trims every order's share (orderShare).
	local tutorial: any = nil
	-- The share of your troops an order sends now: the Attack bar's, under the
	-- rookie floor (nil while there is no HUD).
	local function orderRatio(): number
		local r = if hud then hud.ratio else 0.2
		return if tutorial then math.min(r, tutorial:orderShare()) else r
	end
	-- Notes an order for the tutorial: false when the floor holds it back
	-- entirely (nothing may go), so it isn't sent.
	local function noteOrder(onOwner: boolean, boat: boolean?): boolean
		if tutorial == nil then
			return true
		end
		local share = tutorial:orderShare()
		if hud and share < hud.ratio - 1e-6 then
			tutorial:floorHeld()
		end
		if share <= 0 then
			return false
		end
		if boat then
			tutorial:noteBoat()
		else
			tutorial:noteOrder(onOwner)
		end
		return true
	end

	-- Screens on the 1920x1080 canvas: the menu, the loading cover, dialogs.
	local root = Root.new()
	local loading = Loading.new(root.modal)
	local menu = MenuController.new(root, remotes, {
		config = function(): any
			return if state.ready then state:config() else nil
		end,
		settingsChanged = function(s)
			local changedExpand = lastExpand ~= nil and s.expandSound ~= lastExpand
			lastExpand = s.expandSound
			audio:setSettings(s)
			-- A sample of the expansion sound just chosen in Settings.
			if changedExpand and s.expandSound ~= "off" then
				audio:preview("act.send", 1)
			end
			if hud then
				hud:setMusicOn(s.music)
			end
			-- "Territory labels" (Bruno, feature 15).
			if renderer then
				renderer:setTerritoryLabelsVisible(s.territoryLabels)
			end
		end,
	})
	local loadingWatch: RBXScriptConnection? = nil
	local cancelReady: (() -> ())? = nil
	local function stopLoading()
		if loadingWatch then
			loadingWatch:Disconnect()
			loadingWatch = nil
		end
		if cancelReady then
			cancelReady()
			cancelReady = nil
		end
		loading:hide()
	end
	local function showMenu(on: boolean)
		menu:setVisible(on)
		root:showMatch(not on)
		menuShown = on
		audio:setMusic(if on then "menu" else "match")
		-- In a match the HUD's buttons click with Bruno's pick; the menus
		-- keep their stamp thud.
		Dossier.clickOverride = if on then nil else function()
			audio:play("ui.click")
		end
		if on then
			audio:setAmbience(nil, 0)
			audio:setLoop("act.send", false)
		end
	end
	showMenu(true)
	-- Music starts once the profile's settings arrive (settingsChanged); if
	-- they never do, the defaults after a while.
	task.delay(10, function()
		if not audio.settingsReady then
			audio:setSettings(menu.settings)
		end
	end)

	local function destroyRenderer()
		stopLoading()
		if buildPreview then
			buildPreview:destroy()
			buildPreview = nil
		end
		if renderer then
			renderer:destroy()
			renderer = nil
		end
	end

	-- An explicit fly-to marks where it lands (Codex's Focus bracket; Bruno,
	-- 2026-11-08). Plain pans never do.
	local function focusOn(x: number, y: number, zoom: number?)
		if renderer then
			renderer:goTo(x, y, zoom)
			renderer:focusAt(x, y)
		end
	end

	-- True when there was somewhere to go.
	local function goToPlayer(smallID: number, zoom: number?): boolean
		local anchor = state.names[smallID]
		if anchor and renderer then
			focusOn(anchor.x, anchor.y, zoom)
			return true
		end
		-- Name anchors follow on the server's schedule; until then, the capital.
		local p = state.players[smallID]
		local tile = p and p.spawnTile
		if tile and renderer then
			focusOn(tile % state.width + 0.5, tile // state.width + 0.5, zoom)
			return true
		end
		return false
	end

	-- ClientGameRunner: once the spawn phase is over, fly to your nation at
	-- zoom 8 (10 after a mid-match snapshot, as on reconnect). Solo ends the
	-- spawn phase when you place your capital.
	local wentToPlayer = false
	local goToZoom = 8

	local function rosterForRenderer(): { any }
		local out = {}
		for _, id in state.rosterOrder do
			local p = state.players[id]
			-- A human's territory skin (Store/Skins) as the renderer's pattern mask.
			local pattern = if p.skin then Skins.mask(p.skin) else nil
			table.insert(out, { id = p.id, smallID = p.smallID, playerType = p.type, team = p.team, pattern = pattern })
		end
		return out
	end

	state.Snapshot:Connect(function()
		destroyRenderer()
		wentToPlayer = false
		goToZoom = if state:inSpawnPhase() then 8 else 10
		-- The cover stays until the whole map is painted (instant map).
		local entry = MapCatalog.get((state.mapFolder or state.mapName) :: string)
		loading:show(if entry then entry.name else tostring(state.mapName))
		-- A public match found while in the menu.
		if menuShown and state.gameConfig.gameType ~= "Singleplayer" then
			audio:play("menu.lobby")
		end
		showMenu(false)
		local folder = ReplicatedStorage:WaitForChild("OpenFrontMaps"):WaitForChild((state.mapFolder or state.mapName) :: string)
		local size = if state.mapSize == "Compact" then "map4x" else "map"
		local terrain = MapLoader.readTerrain(folder, size)
		hoverTerrain = terrain
		if state.gameConfig.gameType == "Singleplayer" then
			lastSolo = { map = folder.Name, difficulty = state.gameConfig.difficulty or "Medium" }
		end
		renderer = Renderer.new(surface, terrain, state.width, state.height, { autoStep = true, firstPaint = "full", guiHost = mapGui })
		local current = renderer
		loadingWatch = game:GetService("RunService").Heartbeat:Connect(function()
			if renderer == current and renderer ~= nil then
				loading:setProgress(renderer:loadProgress())
			end
		end)
		cancelReady = renderer:onReady(function()
			if renderer == current then
				stopLoading()
			end
		end)
		renderer:setRoster(rosterForRenderer())
		renderer:setLocalPlayer(state.you)
		renderer:setTerritoryLabelsVisible(menu.settings.territoryLabels)
		renderer:applyTileStates(state.tileState, nil)
		renderer:attachState(state)
		local function onTap(tile: number)
			if not state.ready then return end
			-- (the tutorial's expand and attack steps take a near miss on your
			-- own land as a tap on the mark)
			if tutorial then
				tile = tutorial:redirectTap(tile)
			end
			debugInfo.lastTap = {tile = tile, x = tile % state.width, y = math.floor(tile / state.width)}
			-- Second Spawn: this tap is the new start (2026-11-23).
			if respawnPick then
				local me = state:me()
				if me ~= nil and me.alive then
					respawnPick = false
				else
					audio:play("act.spawn")
					boost("secondSpawn", tile)
					return
				end
			end
			if actionsUi and actionsUi:onMapTap(tile) then
				return
			end
			-- A tap on water orders nothing (the server's tile_action ignores
			-- it), so it isn't sent, nor counted as an order by the tutorial.
			local terrain = hoverTerrain
			if terrain and not state:inSpawnPhase() and tile < buffer.len(terrain) and bit32.band(buffer.readu8(terrain, tile), 0x80) == 0 then
				return
			end
			-- The source plays its spawn cue on the spawn intent itself.
			if state:inSpawnPhase() then
				audio:play("act.spawn")
			end
			local owner = state:ownerAt(tile)
			if not state:inSpawnPhase() and owner ~= state.you and not noteOrder(owner ~= 0) then
				audio:play("ui.error")
				return
			end
			Intent:FireServer({ type = "tile_action", tile = tile, ratio = orderRatio() })
			-- Game feel: the press answers at once, before the server does
			-- (Bruno, 2026-11-08). Your own land orders nothing.
			if actionsUi and state:ownerAt(tile) ~= state.you then
				actionsUi:markTap(tile)
				if not state:inSpawnPhase() then
					audio:play("act.tap")
				end
			end
		end
		debugInfo.tap = onTap
		renderer:bindInput(player.PlayerGui, mapGui, onTap,function(unitIds:{number},tile:number)
			audio:play("naval.move")
			Intent:FireServer({type='move_warship',unitIds=unitIds,tile=tile})
		end,function():boolean
			return actionsUi==nil or actionsUi.chosen==nil
		end,function(tile: number, screenX: number, screenY: number)
			if not state.ready or state:inSpawnPhase() or not actionsUi then return end
			if actionsUi.chosen ~= nil then actionsUi:choose(nil); return end
			if renderer:hasSelection() then renderer:clearSelection(); return end
			task.spawn(actionsUi.openContext, actionsUi, tile, screenX, screenY)
		end)
		-- A tap on your warship: its patrol circle and the warship card (Bruno,
		-- feature 13). The renderer's destroy disconnects this.
		current:onWarshipSelected(function(id: number?)
			if id then
				audio:play("naval.select")
			end
			current:setWarshipPatrolVisible(id)
			if actionsUi then actionsUi:showWarship(id) end
		end)
		buildPreview = BuildPreviewController.new(renderer, state, function(tile: number?, unit: string)
			local ok, result = pcall(function()
				return Query:InvokeServer({kind = "build_preview", tile = tile, unit = unit})
			end)
			return if ok then result else nil
		end)
		buildPreview:setRocketDirection(actionsUi == nil or actionsUi.rocketDirectionUp ~= false)
		buildPreview:setChosen(if actionsUi then actionsUi.chosen else nil)
		if game:GetService("RunService"):IsStudio() then
			local FilmCamera = require(script.Parent.Map.OpenFront.FilmCameraController)
			FilmCamera.new(current, player, function()
				if actionsUi then actionsUi:choose(nil) end
				if buildPreview then buildPreview:setChosen(nil); buildPreview:setPendingTile(nil) end
			end)
		end
	end)
	state.RosterChanged:Connect(function()
		if renderer then
			renderer:setRoster(rosterForRenderer())
		end
	end)
	-- Takeover: you command another nation in the same match. The map stays;
	-- it marks the new nation as yours and flies there.
	state.Rebound:Connect(function()
		-- No build or held selection from the old nation carries over; a
		-- late preview reply is dropped (setChosen moves its generation).
		if buildPreview then
			buildPreview:setChosen(nil)
			buildPreview:setPendingTile(nil)
		end
		if renderer then
			renderer:clearSelection()
			renderer:setLocalPlayer(state.you)
			wentToPlayer = goToPlayer(state.you, 10)
		end
	end)
	state.TilesChanged:Connect(function(changed)
		if renderer then
			renderer:applyTileStates(state.tileState, changed)
		end
		-- Your attack first takes the nation's land: a mark there and a clang.
		-- An attack on you first takes land beside yours: a red ping there
		-- (its whistle already sounded).
		for _, m in feel:tiles(state, changed) do
			local r: any = renderer
			if r and r.pulse then
				r:pulse(m.kind, m.tile)
			end
			if m.kind == "impact" then
				audio:play("act.impact")
			end
		end
	end)

	-- The HUD's and the action sheets' callbacks; both are built by buildHud.
	local hudActions = {
		goToPlayer = goToPlayer,
		restartSolo = function()
			local solo = lastSolo
			if solo then
				Start:FireServer({ mode = "solo", map = solo.map, difficulty = solo.difficulty })
			end
		end,
		fitMap = function()
			if renderer then renderer:centerAll() end
		end,
		openHowToPlay = function()
			menu:openHowToPlay()
		end,
		openSettings = function()
			menu:openSettings()
		end,
		toggleMusic = function()
			local s = table.clone(menu.settings)
			s.music = not s.music
			menu:_applySettings(s)
		end,
		openShop = function()
			menu:openShop("weapons")
		end,
		-- The result card's free crate line.
		openLocker = function()
			menu:_shop("locker")
		end,
		playerColor = function(smallID: number): Color3?
			local r: any = renderer
			if r and r.playerColor then
				return r:playerColor(smallID)
			end
			return nil
		end,
		hoverTile = function(): (number?, number?)
			if renderer == nil or not renderer:isReady() then
				return nil, nil
			end
			local pos = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
			local tile = renderer:screenToTile(pos.X, pos.Y)
			if tile == nil or hoverTerrain == nil then
				return tile, nil
			end
			return tile, buffer.readu8(hoverTerrain :: buffer, tile)
		end,
		chosenBuild = function(): string?
			return if actionsUi then actionsUi.chosen else nil
		end,
		reinforce = function()
			Intent:FireServer({ type = "reinforce" })
		end,
		-- The Arsenal's Takeover: spend a saved one; without one, Roblox's
		-- prompt for the 25 R$ product, then again once it's granted. The
		-- server sends a fresh snapshot with the nation as yours.
		takeover = function()
			task.spawn(function()
				local r = Query:InvokeServer({ kind = "takeover" })
				if type(r) ~= "table" or r.reason ~= "needPurchase" or Products.takeover == nil then
					return
				end
				local Granted = remotes:FindFirstChild("Granted") :: RemoteEvent?
				if Granted == nil then
					return
				end
				local conn: RBXScriptConnection
				conn = Granted.OnClientEvent:Connect(function(grant: any)
					if type(grant) == "table" and grant.product == "takeover" then
						conn:Disconnect()
						Query:InvokeServer({ kind = "takeover" })
					end
				end)
				task.delay(180, function()
					if conn.Connected then
						conn:Disconnect()
					end
				end)
				game:GetService("MarketplaceService"):PromptProductPurchase(player, Products.takeover)
			end)
		end,
		-- In-match boosts (2026-11-23; Runner.boostCheck): ask the server; it
		-- spends a saved credit, or says to prompt the product, after which
		-- we ask again. Second Spawn first only checks, then the next map
		-- tap picks the spot (respawnPick).
		useBoost = function(which: string, tile: number?)
			boost(which, tile)
		end,
		-- The result card's FREE CRATE: the server shows Roblox's rewarded
		-- video; when it completes Roblox grants the crate like a purchase
		-- (the menu's Granted handler opens it).
		watchAd = function()
			task.spawn(function()
				local shop = remotes:FindFirstChild("Shop") :: RemoteFunction?
				if shop then
					pcall(function()
						shop:InvokeServer({ op = "adCrate" })
					end)
				end
			end)
		end,
		cancelAttack = function(attackID: string)
			audio:play("act.retreat")
			Intent:FireServer({ type = "cancel_attack", attackID = attackID })
		end,
		cancelBoat = function(unitID: number)
			audio:play("act.retreat")
			Intent:FireServer({ type = "cancel_boat", unitID = unitID })
		end,
		backToMenu = function()
			-- Leave the match on the server too, so it stops streaming to us.
			Start:FireServer({ mode = "leave" })
			destroyRenderer()
			hud:showMatch(false)
			showMenu(true)
		end,
		-- A public match's PLAY AGAIN: leave it like EXIT, and the server
		-- queues this player for the next public match of the same kind.
		playAgain = function()
			Start:FireServer({ mode = "again" })
			destroyRenderer()
			hud:showMatch(false)
			showMenu(true)
		end,
		togglePause = function(paused: boolean)
			audio:play("ui.pause")
			Intent:FireServer({ type = "toggle_pause", paused = paused })
		end,
		-- A HUD cue by sound board key (Ui/OpenFront/SoundPicks).
		sound = function(key: string)
			audio:play(key)
		end,
	}
	-- The Campaign Pass's XP from the match (under the stars on the card).
	menu.passGained = function(gained: number, pass: any)
		if hud then
			hud:showPassXp(gained, pass)
		end
	end
	menu.starsGained = function(gained: number)
		audio:play("menu.stars")
		hud:showStars(gained, menu.view)
		-- A rewarded ad's free crate, when Roblox has one for this player.
		task.spawn(function()
			local ok, res = pcall(function(): any
				return game:GetService("AdService"):GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)
			end)
			local available = ok and type(res) == "table" and res.AdAvailabilityResult == Enum.AdAvailabilityResult.IsAvailable
			hud:setAdOffer(available == true)
		end)
		-- One of Roblox's own prompts, once each (Shared/EngagePrompts):
		-- notifications after the first match, favorite after a win or the
		-- third match. Saved as a coach tip either way, so it never repeats.
		local which = EngagePrompts.pick(menu.view)
		if which then
			task.delay(EngagePrompts.DELAY_S, function()
				local tips = remotes:FindFirstChild("Tutorial") :: RemoteEvent?
				if tips then
					tips:FireServer({ op = "tip", id = which })
				end
				if which == EngagePrompts.NOTIFY then
					local service = game:GetService("ExperienceNotificationService")
					local ok, can = pcall(function()
						return service:CanPromptOptInAsync()
					end)
					if ok and can then
						pcall(function()
							service:PromptOptIn()
						end)
					end
				else
					pcall(function()
						game:GetService("AvatarEditorService"):PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)
					end)
				end
			end)
		end
	end
	menu.sound = function(key: string)
		audio:play(key)
	end
	-- The HUD panels last sent to the renderer as label occluders (screen
	-- pixels), which the map toasts also keep out of.
	local hudPanelRects: { { x: number, y: number, w: number, h: number } } = {}
	local actionsActions = {
		goToPlayer = goToPlayer,
		-- A boost offered at the moment it helps (OfHud.offerBoost).
		offerBoost = function(which: string, line: string)
			if hud then
				hud:offerBoost(which, line)
			end
		end,
		-- A locked weapon in the ARSENAL fly-out: the unlock card (Shops.unlock).
		openUnlock = function(weaponId: string)
			menu:openUnlock(weaponId)
		end,
		buildChosen = function(unitType: string?)
			if buildPreview then buildPreview:setChosen(unitType) end
		end,
		-- OfActions calls this as its confirm card opens/moves/closes. A nil
		-- tile clears pending geometry; confirming still uses sendIntent above.
		buildPending = function(tile: number?)
			if buildPreview then buildPreview:setPendingTile(tile) end
		end,
		-- A tile's centre in screen pixels (AbsolutePosition space), for cards
		-- that sit beside it; nil without a map.
		tileToScreen = function(tile: number): Vector2?
			if renderer == nil or not state.ready then return nil end
			local sx, sy = renderer:worldToScreen(tile % state.width + 0.5, math.floor(tile / state.width) + 0.5)
			return Vector2.new(sx, sy)
		end,
		onCameraChanged = function(callback: () -> ()): () -> ()
			if renderer == nil then return function() end end
			return renderer:onCameraChanged(callback)
		end,
		deselectWarship = function()
			if renderer then renderer:clearSelection() end
		end,
		-- The toasts' anchor under a nation's name (Codex's name pose).
		nameScreenPosition = function(smallID: number): Vector2?
			if renderer == nil or not state.ready then return nil end
			local x, y = renderer:playerNameScreenPosition(smallID)
			return if x and y then Vector2.new(x, y) else nil
		end,
		-- A nation's name and troops as drawn (screen pixels), nil while hidden;
		-- toasts keep clear of it (2026-11-11 review M2/M3). `unshifted`: where
		-- it would be before the map moved it off a panel (stable for panels
		-- that place themselves by it, such as the build confirmation).
		nameScreenRect = function(smallID: number, unshifted: boolean?): { x: number, y: number, w: number, h: number }?
			if renderer == nil or not state.ready then return nil end
			return renderer:playerNameScreenRect(smallID, unshifted)
		end,
		hudRects = function(): { { x: number, y: number, w: number, h: number } }
			return hudPanelRects
		end,
		-- The wheel's Focus: centre the camera there at the current zoom.
		focusTile = function(tile: number)
			focusOn(tile % state.width + 0.5, tile // state.width + 0.5)
		end,
		rocketDirectionChanged = function(up: boolean)
			if buildPreview then buildPreview:setRocketDirection(up) end
		end,
		sendIntent = function(intent: { [string]: any })
			if intent.type == "attack" or intent.type == "boat" then
				local onOwner = intent.type == "attack" and intent.targetID ~= nil
				if not noteOrder(onOwner, intent.type == "boat") then
					audio:play("ui.error")
					return
				end
			end
			Intent:FireServer(intent)
		end,
		queryActions = function(otherSmallID: number): { [string]: any }?
			local ok, result = pcall(function()
				return Query:InvokeServer({ kind = "actions", other = otherSmallID })
			end)
			return if ok then result else nil
		end,
		queryProfile = function(otherSmallID: number): { [string]: any }?
			local ok, result = pcall(function()
				return Query:InvokeServer({ kind = "profile", other = otherSmallID })
			end)
			return if ok then result else nil
		end,
		queryTile = function(tile: number): { [string]: any }?
			local ok, result = pcall(function()
				return Query:InvokeServer({ kind = "actions", tile = tile, buildables = true })
			end)
			return if ok then result else nil
		end,
		ratio = function(): number
			return orderRatio()
		end,
		selectBeforeAttack = function(): boolean
			return menu.settings.selectBeforeAttack ~= false
		end,
		playerColor = hudActions.playerColor,
		sound = hudActions.sound,
		queryBuild = function(tile: number, unit: string): { [string]: any }?
			local ok, result = pcall(function()
				return Query:InvokeServer({ kind = "build_preview", tile = tile, unit = unit })
			end)
			return if ok then result else nil
		end,
	}
	-- Builds the HUD for the screen's layout (desktop, or a phone's), and
	-- builds it again when the layout changes: a phone may start upright
	-- before the landscape lock turns it, and Studio may report a tiny
	-- window at first (Bruno, 2026-10-27). A rebuild keeps the attack share,
	-- whether the match is showing, and the death and win cards already shown.
	local builtCompact: boolean? = nil
	local builtWidth = 0
	local function buildHud()
		local old = hud
		local keep = if old then { inMatch = old.inMatch, ratio = old.ratio, shownDeath = old.shownDeath, shownWin = old.shownWin } else nil
		-- Layout replacement cancels intent, including late preview replies and
		-- held releases, even when the full-bleed map surface has not resized.
		if buildPreview then
			buildPreview:setChosen(nil)
			buildPreview:setRocketDirection(true)
		end
		if renderer and renderer.input then renderer.input:cancel(true) end
		if actionsUi then
			actionsUi:destroy()
		end
		if old then
			old:destroy()
		end
		hud = OfHud.new(state, root.match, root, hudActions)
		hud.profileOf = function()
			return menu.view
		end
		hud:setMusicOn(menu.settings.music)
		actionsUi = OfActions.new(state, hud.match, actionsActions, hud.slotsHost)
		builtCompact, builtWidth = root.compact, root.width
		if keep then
			hud.ratio = keep.ratio
			hud.shownDeath, hud.shownWin = keep.shownDeath, keep.shownWin
			hud:showMatch(keep.inMatch == true)
			if state.ready then
				hud:setRatio(keep.ratio)
				hud:_refreshAll()
			end
		end
	end
	buildHud()
	-- The tutorial (a new player's first match) and the coach's tips after it
	-- (Ui/OpenFront/TutorialController, after RoWorld's).
	local TutorialRemote = remotes:WaitForChild("Tutorial") :: RemoteEvent
	local function terrainByte(tile: number): number
		local t = hoverTerrain
		if t == nil or tile < 0 or tile >= buffer.len(t) then
			return 0
		end
		return buffer.readu8(t, tile)
	end
	tutorial = TutorialController.new({
		state = state,
		layer = root.match,
		hud = function()
			return hud
		end,
		actionsUi = function()
			return actionsUi
		end,
		tileToScreen = actionsActions.tileToScreen,
		focusTile = function(tile: number, zoom: number?)
			focusOn(tile % state.width + 0.5, tile // state.width + 0.5, zoom)
		end,
		-- (GameMap's bits: land 0x80, shoreline 0x40, magnitude 31 impassable)
		isLand = function(tile: number): boolean
			local b = terrainByte(tile)
			return bit32.band(b, 0x80) ~= 0 and bit32.band(b, 0x1f) ~= 31
		end,
		isShore = function(tile: number): boolean
			local b = terrainByte(tile)
			return bit32.band(b, 0x80) ~= 0 and bit32.band(b, 0x40) ~= 0
		end,
		send = function(intent: { [string]: any })
			Intent:FireServer(intent)
		end,
		report = function(msg: { [string]: any })
			TutorialRemote:FireServer(msg)
		end,
		profile = function(): any?
			return menu.view
		end,
		touch = function(): boolean
			return root.compact or game:GetService("UserInputService").PreferredInput == Enum.PreferredInput.Touch
		end,
		sound = function(key: string)
			audio:play(key)
		end,
	})
	root.Changed.Event:Connect(function()
		-- A phone's bars are sized to its width: a phone that started upright
		-- and turned needs them again.
		if root.compact ~= builtCompact or (root.compact and math.abs(root.width - builtWidth) > 1) then
			buildHud()
		end
	end)

	-- A refused order knocks. One the server dropped for coming too fast
	-- (OpenFront's 10 a second) knocks too, at most every 2 s, so a fast
	-- tapper hears why taps went nowhere (audit F13) without a drum roll.
	local rateKnockAt = -math.huge
	remotes:WaitForChild("IntentResult").OnClientEvent:Connect(function(result)
		debugInfo.lastResult = result
		if type(result) ~= "table" or result.ok ~= false then
			return
		end
		if result.reason == "rateLimited" then
			if os.clock() - rateKnockAt < 2 then
				return
			end
			rateKnockAt = os.clock()
		end
		audio:play("ui.error")
	end)

	-- Match sounds from the confirmed state (AudioCues).
	state.Snapshot:Connect(function()
		cues:reset(state)
		feel:reset(state)
	end)
	-- A Takeover: the old nation's attacks and land history aren't yours.
	state.Rebound:Connect(function()
		cues:reset(state)
		feel:reset(state)
	end)
	state.UnitsChanged:Connect(function(changed, removed)
		local keys = cues:units(state, changed, removed)
		audio:playAll(keys)
		-- A bomb's fire crackles for a while after it lands.
		if table.find(keys, "wpn.atomHit") or table.find(keys, "wpn.hydrogenHit") then
			audio:playFor("wpn.fallout", 12)
		end
	end)
	state.Messages:Connect(function(messages)
		audio:playAll(cues:messages(state, messages))
		-- A boat that came home with all its troops: Codex's quieter "home"
		-- mark where it landed (Bruno, 2026-11-08).
		for _, m in messages do
			local tile = m.params and m.params.tile
			if m.kind == "BOAT_RETURNED" and type(tile) == "number" then
				local r: any = renderer
				if r and r.pulse then
					r:pulse("home", tile)
				end
			end
		end
	end)
	state.DiplomacyEvents:Connect(function(events)
		audio:playAll(cues:events(state, events))
	end)
	state.Bonus:Connect(function(bonuses)
		audio:playAll(cues:bonus(state, bonuses))
	end)
	state.TickApplied:Connect(function()
		local keys = cues:tick(state)
		audio:playAll(keys)
		feel:tick(state)
		-- Land falling fast: the alarm points at the fronts again.
		if table.find(keys, "alert.losing") then
			feel:armLosses(state)
			if hud then
				hud:pulseIncoming()
			end
		end
		-- "Troops sent" loops while your land grows (Bruno, after RoWorld),
		-- rising in pitch over a long run.
		audio:setPopRise(cues.popRise)
		audio:setLoop("act.send", cues.expanding and not menuShown)
	end)
	-- Artillery and Coastal Battery shots are heard only up close (Bruno,
	-- 2026-11-09): zoomed in to AudioCues.HEAR_ZOOM px a tile with the gun on
	-- the map's screen area.
	cues.hearAt = function(tile: number): boolean
		if renderer == nil or not renderer:isReady() or menuShown then
			return false
		end
		local x0 = renderer:worldToScreen(0, 0)
		local x1 = renderer:worldToScreen(1, 0)
		if x1 - x0 < AudioCues.HEAR_ZOOM then
			return false
		end
		local sx, sy = renderer:worldToScreen(tile % state.width + 0.5, tile // state.width + 0.5)
		local at, size = surface.AbsolutePosition, surface.AbsoluteSize
		return sx >= at.X and sy >= at.Y and sx <= at.X + size.X and sy <= at.Y + size.Y
	end
	-- Ambience follows the camera a few times a second: zoom is pixels a tile,
	-- the centre the tile under the middle of the map.
	local ambienceAt = 0
	game:GetService("RunService").Heartbeat:Connect(function()
		local now = os.clock()
		if now - ambienceAt < 0.25 then
			return
		end
		ambienceAt = now
		if renderer == nil or not state.ready or not renderer:isReady() or menuShown then
			audio:setAmbience(nil, 0)
			return
		end
		local x0 = renderer:worldToScreen(0, 0)
		local x1 = renderer:worldToScreen(1, 0)
		local mid = surface.AbsolutePosition + surface.AbsoluteSize / 2
		local center = renderer:screenToTile(mid.X, mid.Y)
		local terrain = hoverTerrain
		local key, gain = AudioCues.ambience(state, center, x1 - x0, function(tile: number): boolean
			return terrain ~= nil and bit32.band(buffer.readu8(terrain, tile), 0x80) == 0
		end)
		audio:setAmbience(key, gain)
	end)
	-- Name labels keep out of the HUD's visible panels (2026-11-11 review M1,
	-- Codex's setLabelOccluders): each visible panel in the match frame, or the
	-- panels inside a see-through holder (notes, offers, the top-right column,
	-- the wheel), plus Roblox's own buttons at the top left. Sent when they
	-- change, ten times a second at most.
	local occluderAt, occluderSig, occluderFor = 0, "", nil :: any
	game:GetService("RunService").Heartbeat:Connect(function()
		local now = os.clock()
		if now - occluderAt < 0.1 or renderer == nil or hud == nil then
			return
		end
		occluderAt = now
		local rects = {}
		local cam = workspace.CurrentCamera
		local screenArea = if cam then cam.ViewportSize.X * cam.ViewportSize.Y else math.huge
		local function add(o: GuiObject)
			local at, size = o.AbsolutePosition, o.AbsoluteSize
			-- (A full-screen layer, like the result card's dimmer, isn't a panel.)
			if #rects < 64 and size.X > 0 and size.Y > 0 and size.X * size.Y < screenArea * 0.5 then
				table.insert(rects, { x = math.floor(at.X), y = math.floor(at.Y), w = math.ceil(size.X), h = math.ceil(size.Y) })
			end
		end
		-- A panel plus any visible child that sticks out of it (the Reinforce
		-- plate sits above the command bar, outside its frame).
		local function addPanel(o: GuiObject)
			add(o)
			local at, size = o.AbsolutePosition, o.AbsoluteSize
			for _, c in o:GetChildren() do
				if c:IsA("GuiObject") and c.Visible then
					local cAt, cSize = c.AbsolutePosition, c.AbsoluteSize
					if cAt.X < at.X - 1 or cAt.Y < at.Y - 1 or cAt.X + cSize.X > at.X + size.X + 1 or cAt.Y + cSize.Y > at.Y + size.Y + 1 then
						add(c)
					end
				end
			end
		end
		local match = hud.match :: GuiObject
		if match.Visible and not menuShown then
			local gs = game:GetService("GuiService")
			local corner = gs.TopbarInset
			if corner.Min.X > 0 then
				add({ AbsolutePosition = Vector2.new(0, -gs:GetGuiInset().Y), AbsoluteSize = Vector2.new(corner.Min.X, corner.Height) } :: any)
			end
			for _, o in match:GetChildren() do
				-- Map ink drawn in the HUD frame (toasts, tap rings, the attack
				-- card's fold) isn't a panel: as one, a toast under a name would
				-- push the name it follows.
				if not o:IsA("GuiObject") or not o.Visible or o:GetAttribute("MapInk") then
					continue
				end
				if o.BackgroundTransparency >= 1 and not o:IsA("ImageLabel") and not o:IsA("ImageButton") then
					for _, c in o:GetChildren() do
						if c:IsA("GuiObject") and c.Visible then
							addPanel(c)
						end
					end
				else
					addPanel(o)
				end
			end
		end
		local parts = table.create(#rects)
		for i, r in rects do
			parts[i] = `{r.x},{r.y},{r.w},{r.h}`
		end
		local sig = table.concat(parts, ";")
		hudPanelRects = rects
		if sig ~= occluderSig or renderer ~= occluderFor then
			occluderSig, occluderFor = sig, renderer
			renderer:setLabelOccluders(rects)
		end
	end)
	remotes:WaitForChild("Snapshot").OnClientEvent:Connect(function(snap)
		-- A snapshot of the match on screen (a Takeover) rebinds in place:
		-- no new map, no loading cover (ClientState.Rebound below).
		state:applySnapshot(snap, renderer ~= nil)
	end)
	remotes:WaitForChild("Tick").OnClientEvent:Connect(function(delta)
		state:applyDelta(delta)
		-- Retried each tick: a player placed at the timer's end (autoSpawnUnplaced)
		-- has no capital until a tick or two after the spawn phase.
		if not wentToPlayer and renderer and not state:inSpawnPhase() and state:me() then
			wentToPlayer = goToPlayer(state.you, goToZoom)
		end
	end)
	remotes:WaitForChild("Status").OnClientEvent:Connect(function(status)
		if status.phase == "menu" then
			destroyRenderer()
			hud:showMatch(false)
			showMenu(true)
			-- a match server sending us back to a hub (the waiting room says so)
			if status.returning == true then
				menu:setReturning()
			end
			-- why a public match join didn't work (OpenFrontServer failJoin)
			if type(status.notice) == "string" and status.notice ~= "" then
				menu:notice(status.notice)
			end
		elseif status.phase == "next" then
			-- a won public match: when the next one starts (result card)
			hud:showNextMatch(if type(status.seconds) == "number" then status.seconds else nil)
		end
	end)

end

return OpenFrontClient
