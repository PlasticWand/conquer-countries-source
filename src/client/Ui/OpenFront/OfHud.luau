--!strict
-- The in-match HUD on the 1920x1080 canvas, in the classified-dossier look
-- after Bruno's reference (2026-10-27, docs/design/dossier-ui/hud-reference.png):
-- framed manila plaques on dark riveted rails, a pinned paper leaderboard,
-- paper notes and cards. OpenFront's in-game information, laid out as before
-- (docs/design/rofront-ui-pass.md, screen 16). Reads the confirmed
-- ClientState only; actions go out through the callbacks the client adapter
-- supplies.
--   - top-left icon row: music, how to play, leaderboard, fit the map,
--     settings, pause (solo), exit
--   - top centre: PROTECTED (spawn immunity) or the match clock, and WORLD
--     CONTROL: your share, the leader's (crown) and the goal marker
--   - top right: your rank pill, which opens the leaderboard (Tab); the
--     attacks list under it, with retreat
--   - left: notifications (EventsDisplay lines and diplomacy), repeats
--     collapse to "x3", danger lines stay longer
--   - the hover card: who owns the land under the mouse, its terrain, and
--     what a click would do
--   - one bottom command bar: you, troops and their growth, the attack share
--     chips with "Sends N troops", gold and its rate, build slots 1-0
--     (OfActions draws them in `slotsHost`) and the SHOP button
--   - the spawn prompt, the pause menu (solo) and the win / death card
-- Information sources (OpenFront v0.35.2, src/client/hud/layers):
--   ControlPanel.ts  troop rate, troops/max, gold, attack ratio (default 20%)
--   GameLeftSidebar/PlayerStats  leaderboard (# · name · land % · gold · troops)
--   AttacksDisplay.ts  outgoing/incoming attacks with retreat
--   SpawnTimer.ts / WinModal.ts / EventsDisplay.ts / GameRightSidebar.ts
-- The leaderboard refreshes once a second (GameLeftSidebar's tick interval);
-- clicking a row flies the camera to that player (GoToPlayerEvent).

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local OF = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("OpenFront")
local Config = require(OF.Config)
local DetMath = require(OF.DetMath)
local Format = require(OF.Format)
local HudModel = require(OF.HudModel)
local Lang = require(OF.Lang)
local ResultModel = require(OF.ResultModel)
local Catalog = require(ReplicatedStorage.Shared.Store.Catalog)
local MenuModel = require(ReplicatedStorage.Shared.MenuModel)

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)

local C = Theme.color
local F = Theme.font
local stencil = Dossier.stencil
local typed = Dossier.typed

-- Ink colours on paper.
local INK = C.inkBlack
local INK_SOFT = C.inkFaded
local GOOD = Color3.fromHex("#2E8A3E")
local GOOD_LIGHT = Color3.fromHex("#56D06B") -- on the dark inset
local RED = C.stamp
local GOLD_INK = Color3.fromHex("#B07A0E")
local INSET = Color3.fromHex("#2E2F24")

local OfHud = {}

-- Plays a HUD sound when the client gave a player.
local function cue(self: any, key: string)
	if self.actions.sound then
		self.actions.sound(key)
	end
end
OfHud.__index = OfHud

export type Actions = {
	-- A HUD sound by sound board key (Ui/OpenFront/SoundPicks).
	sound: ((key: string) -> ())?,
	cancelAttack: (attackID: string) -> (),
	cancelBoat: ((unitID: number) -> ())?,
	backToMenu: () -> (),
	goToPlayer: ((smallID: number) -> ())?,
	togglePause: (paused: boolean) -> (),
	restartSolo: (() -> ())?,
	playAgain: (() -> ())?, -- a public match's PLAY AGAIN (the next of its kind)
	fitMap: (() -> ())?,
	openHowToPlay: (() -> ())?,
	openSettings: (() -> ())?,
	toggleMusic: (() -> ())?,
	openShop: (() -> ())?,
	-- The territory colour of a player (the renderer's palette), if known.
	playerColor: ((smallID: number) -> Color3?)?,
	-- The tile under the mouse and its terrain byte, if over the map.
	hoverTile: (() -> (number?, number?))?,
	-- The chosen build type (a click builds it), if any.
	chosenBuild: (() -> string?)?,
	-- Conquest's Arsenal: call Reinforcements (the reinforce intent).
	reinforce: (() -> ())?,
	takeover: (() -> ())?, -- the Arsenal's Takeover
}

local BOARD_ROWS = 10
local BOARD_INTERVAL = 1 -- seconds (GameLeftSidebar.getTickIntervalMs)
local DEFAULT_RATIO = 0.2 -- ControlPanel.ts attackRatio default
local CHIPS = { 0.1, 0.2, 0.35, 0.5, 0.75 }
local NOTE_SECONDS = 8
local DANGER_SECONDS = 14
-- 2026-11-10 review: five wide slips covered the Atlantic and Europe, and a
-- line that kept repeating stayed for minutes.
local MAX_NOTES = 3
local NOTE_LIFE = 20 -- seconds a repeating line may stay at most
local SPAWN_SEGMENTS = 16 -- the deploying dial's ring
local BAR_W = 1910
local BAR_H = 144
-- How far the HUD may grow on wide screens (Bruno, 2026-10-27: roomier).
local HUD_MAX = 1.2
-- How big a phone's match HUD is drawn (Bruno, 2026-10-27: smaller, for
-- more map).
local PHONE_HUD = 0.8
-- The top row (icons, rank pill, attacks) is smaller still, for the race bar.
local PHONE_TOP = PHONE_HUD * 0.85

-- Config.ts troopIncreaseRate for a human, from the replicated troops and cap.
local function troopRate(troops: number, max: number): number
	if max <= 0 then
		return 0
	end
	local toAdd = (10 + DetMath.pow(troops, 0.73) / 4) * (1 - troops / max)
	return math.min(troops + toAdd, max) - troops
end

-- OpenFront's terrain classes from a terrain byte (land bit 7, magnitude 0..4).
local function terrainName(byte: number?): string?
	if byte == nil then
		return nil
	end
	if bit32.band(byte, 0x80) == 0 then
		return if bit32.band(byte, 0x20) ~= 0 then "Ocean" else "Lake"
	end
	local mag = bit32.band(byte, 0x1f)
	return if mag < 10 then "Plains" elseif mag < 20 then "Highland" else "Mountain"
end

-- An ink caption with its icon ("TROOPS", "GOLD").
local function caption(parent: Instance, icon: string, text: string, x: number, y: number, color: Color3?): TextLabel
	Kit.glyph(icon, { ImageColor3 = color or INK, Position = UDim2.fromOffset(x, y + 1), Size = UDim2.fromOffset(22, 22), Parent = parent })
	return stencil({ Text = text, TextSize = 23, TextColor3 = color or INK, Position = UDim2.fromOffset(x + 28, y - 4), Parent = parent })
end

-- A paper card (notes, the hover card, attacks, the spawn prompt).
local function paper(props: { [string]: any }): ImageLabel
	local p = Dossier.surface("ImageLabel", "tex_paper", C.sheet, props)
	Kit.stroke(C.sheetLine, 1.5, 0).Parent = p
	return p
end

function OfHud.new(state: any, host: Frame, root: any, actions: Actions)
	local self: any = setmetatable({
		state = state,
		actions = actions,
		root = root,
		ratio = DEFAULT_RATIO,
		boardAt = 0,
		boardOpen = false,
		incomingBoats = {} :: { [number]: boolean },
		attackRows = {} :: { [string]: any },
		-- Game feel: counting numbers, flashes' base colours, retreats pressed
		-- but not yet confirmed (row key -> os.clock()).
		counters = {} :: { [string]: any },
		flashBase = {} :: { [Instance]: Color3 },
		recalling = {} :: { [string]: number },
		countConn = nil :: RBXScriptConnection?,
		notes = {} :: { any },
		connections = {} :: { RBXScriptConnection },
		inMatch = false,
		pauseModal = nil :: any,
	}, OfHud)

	local match = Kit.new("Frame", { Name = "Hud", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = host })
	self.match = match
	local function hold(c: any)
		table.insert(self.connections, c)
	end

	-- Top-left icon row ------------------------------------------------------------
	local icons = Kit.new("Frame", { Name = "Icons", BackgroundTransparency = 1, Position = UDim2.fromOffset(root.topLeft, 12), Size = UDim2.fromOffset(500, 44), Parent = match })
	Kit.list(Enum.FillDirection.Horizontal, 8).Parent = icons
	local function iconButton(name: string, order: number, tip: string, fn: (() -> ())?): TextButton
		local b = Kit.roundIcon(name, { LayoutOrder = order, Parent = icons })
		if fn then
			b.Activated:Connect(fn)
			-- Taller on a phone; as wide as the row's spacing allows (audit F12).
			Dossier.hitPad(b, fn, 52, nil)
		end
		Kit.tip(b, function(card)
			Kit.text({ Text = tip, FontFace = F.uiBold, Parent = card })
		end)
		return b
	end
	self.icons = icons
	self.musicIcon = iconButton("music", 1, "Music", actions.toggleMusic)
	self.musicSlash = Kit.slash(self.musicIcon)
	iconButton("question", 2, "How to play (H)", actions.openHowToPlay)
	self.boardIcon = iconButton("leaderboard", 3, "Leaderboard (Tab)", function()
		self:_setBoardOpen(not self.boardOpen)
	end)
	iconButton("globe", 4, "Show the whole map", actions.fitMap)
	iconButton("settings", 5, "Settings", actions.openSettings)
	self.pauseButton = iconButton("pause", 6, "Pause", function()
		actions.togglePause(not state.paused)
	end)
	iconButton("exit", 7, "Leave the match", function()
		self:_confirmLeave()
	end)
	hold(root.Changed.Event:Connect(function()
		icons.Position = UDim2.fromOffset(root.topLeft, 12)
	end))

	-- Top centre: protection or clock, and world control -----------------------------
	-- A riveted rail with a dark inset (the clock, as wide as its text: Bruno,
	-- 2026-10-27) and a manila plaque with the race to the goal.
	local top = Dossier.rail({ Name = "TopBar", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(0, 132), AutomaticSize = Enum.AutomaticSize.X, Parent = match })
	self.top = top
	Kit.padding(0, 14).Parent = top
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = top
	local inset = Kit.new("Frame", { Name = "Clock", BackgroundColor3 = INSET, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 96), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Parent = top })
	Kit.corner(4).Parent = inset
	Kit.stroke(Color3.fromHex("#14150F"), 2, 0).Parent = inset
	Kit.new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 16), Parent = inset })
	self.clockIcon = Kit.glyph("shield", { ImageColor3 = GOOD_LIGHT, Position = UDim2.fromOffset(0, 14), Size = UDim2.fromOffset(20, 20), Parent = inset })
	self.clockCaption = stencil({ Text = "PROTECTED", TextSize = 21, TextColor3 = GOOD_LIGHT, Position = UDim2.fromOffset(26, 10), Parent = inset })
	self.clockText = stencil({ Text = "0:00", TextSize = 46, TextColor3 = GOOD_LIGHT, Position = UDim2.fromOffset(0, 36), Parent = inset })
	self.clockInset = inset
	local world = Dossier.plaque("ImageLabel", { Name = "World", Size = UDim2.fromOffset(500, 112), LayoutOrder = 2, Parent = top })
	Dossier.art("paperclip", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(4, -4), Size = UDim2.fromOffset(18, 58), Rotation = -6, ZIndex = 3, Parent = world })
	caption(world, "globe", "WORLD CONTROL", 20, 14)
	local goal = Kit.new("Frame", { BackgroundColor3 = C.hazard, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 12), Size = UDim2.fromOffset(98, 28), Parent = world })
	Kit.corner(3).Parent = goal
	Kit.stroke(Color3.fromHex("#A87C12"), 1.5, 0).Parent = goal
	self.goalText = stencil({ Text = "GOAL 80%", TextSize = 19, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Parent = goal })
	-- The race bar (Bruno, 2026-10-27: bigger, more noticeable): your share
	-- fills it in your colour, the leader's share is the paler fill behind
	-- with a tick at its end, and the goal is a bold yellow line.
	local race = Kit.new("Frame", { Name = "Race", BackgroundColor3 = INSET, BorderSizePixel = 0, Position = UDim2.fromOffset(18, 46), Size = UDim2.new(1, -36, 0, 24), Parent = world })
	Kit.corner(4).Parent = race
	Kit.stroke(Color3.fromHex("#14150F"), 2, 0).Parent = race
	self.leaderFill = Kit.new("Frame", { BackgroundColor3 = C.sheetLine, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = race })
	Kit.corner(4).Parent = self.leaderFill
	self.myFill = Kit.new("Frame", { BackgroundColor3 = C.red, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 2, Parent = race })
	Kit.corner(4).Parent = self.myFill
	self.leaderTick = Kit.new("Frame", { BackgroundColor3 = C.sheet, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(0, 4, 1, 8), ZIndex = 3, Parent = race })
	Kit.stroke(Color3.fromHex("#14150F"), 1, 0).Parent = self.leaderTick
	self.goalMark = Kit.new("Frame", { BackgroundColor3 = C.hazard, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.8, 0.5), Size = UDim2.new(0, 5, 1, 12), ZIndex = 4, Parent = race })
	Kit.stroke(Color3.fromHex("#14150F"), 1.5, 0).Parent = self.goalMark
	-- Under the bar: you on the left, the leader on the right.
	self.mySwatch = Kit.new("Frame", { BackgroundColor3 = C.red, BorderSizePixel = 0, Position = UDim2.fromOffset(20, 82), Size = UDim2.fromOffset(16, 16), Parent = world })
	Kit.corner(2).Parent = self.mySwatch
	Kit.stroke(INK, 1, 0.3).Parent = self.mySwatch
	self.myShare = stencil({ Text = "You 0%", TextSize = 22, TextColor3 = INK, Position = UDim2.fromOffset(42, 75), Parent = world })
	local leaderRow = Kit.new("Frame", { Name = "Leader", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20, 0, 76), Size = UDim2.fromOffset(280, 28), Parent = world })
	Kit.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent = leaderRow
	self.leaderCrown = Kit.glyph("crown", { ImageColor3 = GOLD_INK, Size = UDim2.fromOffset(20, 20), LayoutOrder = 1, Parent = leaderRow })
	self.leaderSwatch = Kit.new("Frame", { BackgroundColor3 = C.fgMuted, BorderSizePixel = 0, Size = UDim2.fromOffset(16, 16), LayoutOrder = 2, Parent = leaderRow })
	Kit.corner(2).Parent = self.leaderSwatch
	Kit.stroke(INK, 1, 0.3).Parent = self.leaderSwatch
	self.leaderShare = stencil({ Text = "", TextSize = 22, TextColor3 = INK, TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 3, Parent = leaderRow })
	Kit.new("UISizeConstraint", { MaxSize = Vector2.new(230, 28), Parent = self.leaderShare })

	-- Spawn prompt (replaces the top bar until you spawn) ----------------------------
	-- The deploying card (Bruno, 2026-10-28, mockup B): a plaque on the rail
	-- with the dark dial, its red ring draining with the seconds left.
	local spawn = Dossier.rail({ Name = "SpawnPrompt", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 12), Size = UDim2.fromOffset(0, 112), AutomaticSize = Enum.AutomaticSize.X, Visible = false, Parent = match })
	Kit.padding(12, 14).Parent = spawn
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = spawn
	local words = Dossier.plaque("ImageLabel", { Name = "Words", Size = UDim2.fromOffset(0, 88), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Parent = spawn })
	Kit.padding(10, 22).Parent = words
	Kit.list(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = words
	self.spawnTitle = stencil({ Text = "CHOOSE YOUR STARTING LOCATION", TextSize = 28, TextColor3 = INK, LayoutOrder = 1, Parent = words })
	self.spawnText = typed({ Text = `{if Kit.touch() then "Tap" else "Click"} any unclaimed land to place your capital.`, TextColor3 = INK, TextSize = 19, LayoutOrder = 2, Parent = words })
	local dial = Kit.new("Frame", { Name = "Dial", BackgroundColor3 = INSET, BorderSizePixel = 0, Size = UDim2.fromOffset(88, 88), LayoutOrder = 2, Parent = spawn })
	Kit.corner(8).Parent = dial
	Kit.stroke(Color3.fromHex("#1A1A12"), 2, 0).Parent = dial
	self.spawnRing = {}
	for i = 1, SPAWN_SEGMENTS do
		local a = (i - 1) / SPAWN_SEGMENTS * 2 * math.pi
		local seg = Kit.new("Frame", { BackgroundColor3 = RED, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 31 * math.sin(a), 0.5, -31 * math.cos(a)), Size = UDim2.fromOffset(5, 13), Rotation = math.deg(a), Parent = dial })
		Kit.corner(2).Parent = seg
		self.spawnRing[i] = seg
	end
	self.spawnCount = stencil({ Text = "", TextSize = 34, TextColor3 = GOOD_LIGHT, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(50, 40), TextXAlignment = Enum.TextXAlignment.Center, Parent = dial })
	self.spawnDial = dial
	self.spawn = spawn

	-- Paused with the pause window closed: the map stays live to look around
	-- (OpenFront's HeadsUpMessage while paused). fit() puts it under the top bar.
	local pausedNote = paper({ Name = "PausedNote", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 160), Size = UDim2.fromOffset(0, 82), AutomaticSize = Enum.AutomaticSize.X, Visible = false, Parent = match })
	Kit.padding(12, 26).Parent = pausedNote
	Kit.list(Enum.FillDirection.Vertical, 4).Parent = pausedNote
	stencil({ Text = "PAUSED", TextSize = 28, LayoutOrder = 1, Parent = pausedNote })
	typed({ Text = `{if Kit.touch() then "Tap" else "Click"} the play button to resume.`, TextColor3 = INK, TextSize = 19, LayoutOrder = 2, Parent = pausedNote })
	self.pausedNote = pausedNote

	-- Top right: rank tag / leaderboard, then attacks ------------------------------
	local right = Kit.new("Frame", { Name = "Right", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 10), Size = UDim2.fromOffset(410, 900), Parent = match })
	Kit.list(Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Top).Parent = right
	local pill = Dossier.surface("ImageButton", "tex_paper", C.sheet, { Name = "Rank", Size = UDim2.fromOffset(0, 46), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Parent = right })
	Kit.stroke(C.sheetLine, 1.5, 0).Parent = pill
	Kit.padding(0, 16).Parent = pill
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = pill
	Kit.glyph("leaderboard", { ImageColor3 = INK, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, Parent = pill })
	self.rankText = stencil({ Text = "#-", TextSize = 22, LayoutOrder = 2, Parent = pill })
	pill.Activated:Connect(function()
		Dossier.thud()
		self:_setBoardOpen(true)
	end)
	self.pill = pill
	self:_buildBoard(right)
	local attacks = paper({ Name = "Attacks", Size = UDim2.fromOffset(360, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Visible = false, Parent = right })
	Kit.padding(12, 14).Parent = attacks
	Kit.list(Enum.FillDirection.Vertical, 6).Parent = attacks
	self.attacksTitle = stencil({ Text = "ATTACKS", TextSize = 19, LayoutOrder = 0, Parent = attacks })
	self.attacks = attacks

	-- Left: notifications --------------------------------------------------------------
	local notes = Kit.new("Frame", { Name = "Notes", BackgroundTransparency = 1, Position = UDim2.fromOffset(16, 74), Size = UDim2.fromOffset(420, 600), Parent = match })
	Kit.list(Enum.FillDirection.Vertical, 8).Parent = notes
	self.notesHost = notes
	self.noteCount = 0

	-- Hover card (bottom right, above the command bar) --------------------------------
	local hover = paper({ Name = "Hover", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -20, 1, -196), Size = UDim2.fromOffset(320, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, Parent = match })
	Kit.padding(12, 16).Parent = hover
	Kit.list(Enum.FillDirection.Vertical, 6).Parent = hover
	self.hoverTitle = stencil({ Text = "", RichText = true, TextSize = 24, LayoutOrder = 1, Parent = hover })
	local actRow = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 2, Parent = hover })
	self.hoverIcon = Kit.glyph("sword", { ImageColor3 = GOOD, Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(0, 2), Parent = actRow })
	self.hoverAction = stencil({ Text = "", TextSize = 21, TextColor3 = GOOD, Position = UDim2.fromOffset(26, 0), Parent = actRow })
	self.hoverActionRow = actRow
	self.hover = hover

	-- The command bar: a rail of plaques -------------------------------------------------
	local bar = Dossier.rail({ Name = "CommandBar", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.fromOffset(BAR_W, BAR_H), Parent = match })
	self.bar = bar
	local function section(name: string, x: number, w: number): ImageLabel
		return Dossier.plaque("ImageLabel", { Name = name, Position = UDim2.fromOffset(x, 14), Size = UDim2.fromOffset(w, BAR_H - 28), Parent = bar })
	end
	-- You
	-- Bruno, 2026-10-27: the left side narrower, the slots wider.
	local you = section("You", 14, 196)
	self.swatch = Kit.new("Frame", { BackgroundColor3 = C.red, BorderSizePixel = 0, Position = UDim2.fromOffset(22, 38), Size = UDim2.fromOffset(40, 40), Parent = you })
	Kit.corner(3).Parent = self.swatch
	Kit.stroke(INK, 2, 0).Parent = self.swatch
	self.nameText = stencil({ Text = "", TextSize = 30, Position = UDim2.fromOffset(72, 28), Size = UDim2.fromOffset(108, 36), AutomaticSize = Enum.AutomaticSize.None, TextTruncate = Enum.TextTruncate.AtEnd, Parent = you })
	self.worldText = stencil({ Text = "", TextSize = 17, TextColor3 = INK_SOFT, Position = UDim2.fromOffset(72, 66), Parent = you })
	-- Troops
	local troops = section("Troops", 218, 262)
	Dossier.icon("icon_party", "troops", { Position = UDim2.fromOffset(12, 18), Size = UDim2.fromOffset(48, 84), Parent = troops })
	stencil({ Text = "TROOPS", TextSize = 23, Position = UDim2.fromOffset(68, 10), Parent = troops })
	self.rateText = stencil({ Text = "+0/s", TextSize = 22, TextColor3 = GOOD, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 12), Parent = troops })
	self.troopsText = stencil({ Text = "", RichText = true, TextSize = 38, Position = UDim2.fromOffset(68, 40), Parent = troops })
	local troopTrack = Kit.new("Frame", { BackgroundColor3 = INSET, BorderSizePixel = 0, Position = UDim2.fromOffset(68, 92), Size = UDim2.fromOffset(176, 11), Parent = troops })
	Kit.corner(3).Parent = troopTrack
	self.troopFill = Kit.new("Frame", { BackgroundColor3 = Color3.fromRGB(232, 92, 140), BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = troopTrack })
	Kit.corner(3).Parent = self.troopFill
	-- Attack share
	local attack = section("Attack", 486, 318)
	caption(attack, "sword", "ATTACK", 18, 14)
	self.ratioText = stencil({ Text = "20%", TextSize = 19, TextColor3 = RED, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 12), Visible = false, Parent = attack })
	self.ratioChips = {} :: { [number]: any }
	self.ratioSet = {} :: { [number]: (boolean) -> () }
	for i, r in CHIPS do
		local chip, set = Dossier.rivetPlate(attack, `{math.floor(r * 100 + 0.5)}%`, 23, false, { Name = `Share{i}`, Position = UDim2.fromOffset(16 + 28 + (i - 1) * 58, 58), Size = UDim2.fromOffset(54, 42), Parent = attack })
		local function pick()
			cue(self, "ui.slider")
			self:setRatio(r)
		end
		chip.Activated:Connect(pick)
		-- A taller tap area; side by side they touch, 62 apart (audit F12).
		Dossier.hitPad(chip, pick, 62, nil)
		self.ratioChips[r] = chip
		self.ratioSet[r] = set
	end
	self.sendsText = typed({ Text = "", TextColor3 = INK, TextSize = 21, Position = UDim2.fromOffset(16, 84), Parent = attack })
	-- Gold
	local gold = section("Gold", 810, 190)
	caption(gold, "gold", "GOLD", 18, 14)
	self.goldRate = stencil({ Text = "", TextSize = 22, TextColor3 = GOOD, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -18, 0, 12), Parent = gold })
	self.goldText = stencil({ Text = "0", TextSize = 48, Position = UDim2.fromOffset(18, 46), Parent = gold })
	-- Build slots (OfActions fills them) on a dark inset, and SHOP.
	local slotsBack = Kit.new("Frame", { Name = "SlotsBack", BackgroundColor3 = INSET, BorderSizePixel = 0, Position = UDim2.fromOffset(1006, 14), Size = UDim2.fromOffset(792, BAR_H - 28), Parent = bar })
	Kit.corner(4).Parent = slotsBack
	Kit.stroke(Color3.fromHex("#14150F"), 2, 0).Parent = slotsBack
	self.slotsHost = Kit.new("Frame", { Name = "Slots", BackgroundTransparency = 1, Position = UDim2.fromOffset(1013, 20), Size = UDim2.fromOffset(778, BAR_H - 40), Parent = bar })
	local shop = Dossier.plate(bar, "", { Name = "Shop", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(1853, BAR_H / 2), Size = UDim2.fromOffset(98, BAR_H - 28), Parent = bar }, 0)
	Kit.glyph("lock", { ImageColor3 = INK, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18), Size = UDim2.fromOffset(42, 42), Parent = shop })
	stencil({ Text = "SHOP", TextSize = 24, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16), Parent = shop })
	Dossier.clicky(shop, 1.05)
	Dossier.art("pin", { AnchorPoint = Vector2.new(0.5, 0.75), Position = UDim2.fromOffset(86, 6), Size = UDim2.fromOffset(20, 28), ZIndex = 3, Parent = shop })
	self.shopBadge = stencil({ Text = "", TextSize = 14, TextColor3 = C.sheet, BackgroundColor3 = RED, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -4, 0, 4), Visible = false, Parent = shop })
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = self.shopBadge })
	Kit.padding(2, 6).Parent = self.shopBadge
	shop.Activated:Connect(function()
		if actions.openShop then
			actions.openShop()
		end
	end)

	-- Reinforcements (Conquest's Arsenal): a plaque standing on the bar's
	-- right end (a child of the bar, so it scales with it).
	local reinforce = Dossier.plaque("ImageButton", { Name = "Reinforce", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -120, 0, 4), Size = UDim2.fromOffset(330, 58), Visible = false, Parent = bar })
	local rRow = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = reinforce })
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = rRow
	Kit.glyph("troops", { ImageColor3 = INK, Size = UDim2.fromOffset(28, 28), LayoutOrder = 1, Parent = rRow })
	self.reinforceText = stencil({ Text = "", TextSize = 22, LayoutOrder = 2, Parent = rRow })
	Dossier.art("pin", { AnchorPoint = Vector2.new(0.5, 0.75), Position = UDim2.new(1, -14, 0, 4), Size = UDim2.fromOffset(18, 26), Parent = reinforce })
	reinforce.Activated:Connect(function()
		if actions.reinforce and reinforce:GetAttribute("Ready") == true then
			Dossier.thud()
			actions.reinforce()
		end
	end)
	Kit.tip(reinforce, function(card)
		Kit.text({ Text = "Reinforcements", FontFace = F.uiHeavy, TextSize = 19, LayoutOrder = 1, Parent = card })
		Kit.text({ Text = `{math.floor(Config.REINFORCE_SHARE * 100)}% of your troop limit at once, for {Format.renderNumber(Config.REINFORCE_GOLD)} gold. Then {Config.REINFORCE_COOLDOWN // 10} seconds to reload.`, TextSize = 16, TextColor3 = C.fgSoft, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = card })
		Kit.text({ Text = "Key R", TextSize = 14, TextColor3 = C.fgMuted, LayoutOrder = 3, Parent = card })
	end)
	self.reinforceButton = reinforce
	if root.compact then
		self:_phone(match)
	end

	-- On screens wider than the canvas (Bruno's 2.3:1 Studio window), the
	-- bars, the leaderboard and the hover card grow into the spare room, up
	-- to HUD_MAX; on narrower ones they shrink to fit.
	local scales = {}
	for _, target in { top, bar, right } do
		table.insert(scales, Kit.new("UIScale", { Parent = target }))
	end
	local function fit()
		local s = root.scale.Scale
		local cam = workspace.CurrentCamera
		local avail = if cam and s > 0 then cam.ViewportSize.X / s else 1920
		-- A phone lays its HUD out at full size (OfHud._phone).
		local k = if root.compact then PHONE_TOP else math.clamp((avail - 24) / BAR_W, 0.7, HUD_MAX)
		for _, u in scales do
			u.Scale = k
		end
		self.hudScale = k
		if not root.compact then
			hover.Position = UDim2.new(1, -20, 1, -math.round(BAR_H * k + 80))
			pausedNote.Position = UDim2.new(0.5, 0, 0, math.round(6 + 132 * k + 10))
			-- OfActions keeps its cards above the bar and its build banner under
			-- the top rail from these (2026-11-10 review).
			match:SetAttribute("BarTop", math.round(6 + BAR_H * k))
			match:SetAttribute("RailBottom", math.round(6 + 132 * k))
		end
	end
	hold(root.Changed.Event:Connect(fit))
	fit()

	-- Win / death card: RoWorld's result screen in our dossier style ------------------------
	-- (Bruno, 2026-11-03; ResultModel has the words). A folder over the
	-- dimmed map: the kicker and verdict on a torn strip with the rubber stamp
	-- thumping on, the line under it, four paper tags (peak land, max troops,
	-- nations eliminated, match time), the Stars this match paid counting up
	-- beside PLAY AGAIN, the next Arsenal unlock and 2x Stars, then EXIT and a
	-- Keep playing link.
	local CARD_W, CARD_H = 760, 700
	local win = Kit.new("Frame", { Name = "Result", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 20, Parent = match })
	Kit.new("TextButton", { Name = "Dim", Text = "", AutoButtonColor = false, BackgroundColor3 = C.desk, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = win })
	local card = Kit.new("Frame", { Name = "Card", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(CARD_W, CARD_H), Parent = win })
	-- A moment worth a big card, as big as the screen's height allows: sized
	-- when it opens (_fitResult), since a phone may have started upright.
	self.winScale = Kit.new("UIScale", { Scale = 1.1, Parent = card }) :: UIScale
	self.winCardH = CARD_H
	Dossier.cardArt("ImageLabel", "folder_card", { Name = "Folder", Position = UDim2.fromOffset(0, 40), Size = UDim2.fromOffset(CARD_W, CARD_H - 40), Parent = card })
	Dossier.art("paperclip", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(18, 170), Size = UDim2.fromOffset(20, 66), Parent = card })
	local verdict = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Name = "Verdict", Position = UDim2.fromOffset(30, 0), Size = UDim2.fromOffset(700, 150), Rotation = -0.8, Parent = card })
	self.winKicker = typed({ Text = "", TextSize = 20, TextColor3 = INK, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.25), Parent = verdict })
	-- (10 higher than at first, off the strip's torn edge: Bruno, 2026-11-11.)
	self.winText = stencil({ Text = "", TextSize = 84, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.63, -10), Parent = verdict })
	Dossier.art("star_stamp", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(660, 520), Size = UDim2.fromOffset(160, 160), ImageTransparency = 0.78, Rotation = -12, Parent = card })
	-- The rubber stamp (its text and colour per verdict), and its thump.
	local stamp = Kit.new("Frame", { Name = "Stamp", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(628, 112), Size = UDim2.fromOffset(0, 58), AutomaticSize = Enum.AutomaticSize.X, Rotation = -7, ZIndex = 4, Parent = card })
	local stampStroke = Kit.stroke(RED, 4, 0.05)
	stampStroke.Parent = stamp
	Kit.padding(0, 12).Parent = stamp
	self.stampText = stencil({ Text = "", TextSize = 34, TextColor3 = RED, TextTransparency = 0.05, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 4, Parent = stamp })
	self.stampStroke = stampStroke
	self.stampScale = Kit.new("UIScale", { Parent = stamp })
	-- The line under the verdict ("Your team won with 80.0% of the land.").
	self.subText = typed({ Text = "", TextColor3 = INK, TextSize = 24, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(CARD_W / 2, 200), Size = UDim2.fromOffset(680, 32), TextXAlignment = Enum.TextXAlignment.Center, Parent = card })
	-- The four stat tags, pinned slightly askew.
	self.statValues = {}
	local STATS: { { any } } = {
		{ "globe", "PEAK LAND", GOLD_INK, -1.2 },
		{ "troops", "MAX TROOPS", Color3.fromHex("#2E6F8E"), 0.8 },
		{ "skull", "NATIONS ELIMINATED", RED, -0.6 },
		{ "clock", "MATCH DURATION", Color3.fromHex("#5B4A8A"), 1.1 },
	}
	for i, spec in STATS do
		local tag = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, { Name = `Stat{i}`, Position = UDim2.fromOffset(36 + (i - 1) * 176, 232), Size = UDim2.fromOffset(160, 124), Rotation = spec[4], Parent = card })
		Kit.glyph(spec[1], { ImageColor3 = spec[3], AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.24), Size = UDim2.fromOffset(30, 30), Parent = tag })
		self.statValues[i] = stencil({ Name = "Value", Text = "", TextSize = 40, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.56), Parent = tag })
		typed({ Text = spec[2], TextSize = 13, TextColor3 = INK, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.84), Parent = tag })
	end
	-- The Stars this match paid (when the server reports them): a gold
	-- plate counting up; a press opens the Arsenal.
	local starsPlate = Dossier.rivetPlate(card, "", 30, true, { Name = "Stars", Position = UDim2.fromOffset(170, 418), Size = UDim2.fromOffset(250, 76), Visible = false, Parent = card })
	local starsRow = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = starsPlate })
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = starsRow
	Kit.glyph("star", { ImageColor3 = INK, Size = UDim2.fromOffset(32, 32), LayoutOrder = 1, Parent = starsRow })
	self.starsText = stencil({ Text = "", TextSize = 36, LayoutOrder = 2, Parent = starsRow })
	starsPlate.Activated:Connect(function()
		if actions.openShop then
			actions.openShop()
		end
	end)
	self.starsPlate = starsPlate
	-- PLAY AGAIN, the card's main action (Bruno, 2026-11-12: 86% of new
	-- players never started a second match): the same kind of match as this
	-- one. Solo: a new one on this server (the pause menu's Restart); public:
	-- the next public match of this kind (the server queues it from the hub).
	local again = Dossier.plate(card, string.upper(Lang.t("win_modal.requeue")), { Name = "PlayAgain", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(520, 418), Size = UDim2.fromOffset(420, 80), Parent = card }, 36)
	Dossier.clicky(again, 1.03)
	-- Taped to the plate itself, so the tape grows and squashes with it.
	for _, t in { { 44, -1 }, { 376, 1 } } do
		Dossier.art("red_tape", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(t[1], 14), Size = UDim2.fromOffset(96, 26), Rotation = -40 * t[2], ScaleType = Enum.ScaleType.Stretch, ZIndex = 3, Parent = again })
	end
	again.Activated:Connect(function()
		local solo = self.state.gameConfig.gameType == "Singleplayer"
		if solo and actions.restartSolo then
			self.win.Visible = false
			actions.restartSolo()
		elseif actions.playAgain then
			actions.playAgain()
		else
			actions.backToMenu()
		end
	end)
	self.winAgain = again
	-- Under them, once the Stars are in: the next unlock and 2x Stars. They
	-- say what is true; a press opens the Arsenal.
	local function infoPlate(name: string, glyph: string): (ImageButton, TextLabel)
		local p = Dossier.rivetPlate(card, "", 22, false, { Name = name, Position = UDim2.fromOffset(CARD_W / 2, 506), Size = UDim2.fromOffset(330, 58), Visible = false, Parent = card })
		local row = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = p })
		Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
		Kit.glyph(glyph, { ImageColor3 = GOLD_INK, Size = UDim2.fromOffset(24, 24), LayoutOrder = 1, Parent = row })
		local label = stencil({ Text = "", TextSize = 22, LayoutOrder = 2, Parent = row })
		p.Activated:Connect(function()
			if actions.openShop then
				actions.openShop()
			end
		end)
		return p, label
	end
	-- Eliminated by an AI nation: take it over (the Arsenal's Takeover, 25 R$
	-- a use; the server says whom, ClientState.arsenal.takeover).
	-- Robux green with cream words and the Robux mark, like the menu's
	-- Robux badges, under a gold edge that breathes: it stands apart from
	-- the yellow PLAY AGAIN by colour, not size (Bruno, 2026-11-12).
	local takeover = Kit.new("ImageButton", { Name = "Takeover", AutoButtonColor = false, BackgroundColor3 = Color3.fromHex("#3F9B4F"), BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(CARD_W / 2, 506), Size = UDim2.fromOffset(560, 66), Visible = false, Parent = card })
	Kit.corner(6).Parent = takeover
	local takeoverEdge = Kit.stroke(Color3.fromHex("#F2C84B"), 4, 0)
	takeoverEdge.Parent = takeover
	Kit.new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.fromHex("#FFFFFF"), Color3.fromHex("#B9C9B5")), Parent = takeover })
	local takeoverRow = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = takeover })
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = takeoverRow
	stencil({ Name = "Label", Text = "TAKE OVER", TextSize = 28, TextColor3 = C.sheet, LayoutOrder = 1, Parent = takeoverRow })
	Kit.new("ImageLabel", { BackgroundTransparency = 1, Image = UiAssets.robux, Size = UDim2.fromOffset(28, 28), LayoutOrder = 2, Parent = takeoverRow })
	local takeoverProduct = Catalog.product("takeover")
	stencil({ Name = "Price", Text = tostring(if takeoverProduct then takeoverProduct.price else 25), TextSize = 28, TextColor3 = C.sheet, LayoutOrder = 3, Parent = takeoverRow })
	Dossier.clicky(takeover, 1.03)
	takeover.Activated:Connect(Dossier.click)
	local takeoverT0 = os.clock()
	hold(RunService.Heartbeat:Connect(function()
		if takeover.Visible then
			takeoverEdge.Transparency = 0.2 + 0.2 * math.sin((os.clock() - takeoverT0) * 2.4)
		end
	end))
	takeover.Activated:Connect(function()
		if actions.takeover then
			actions.takeover()
		end
	end)
	self.takeoverPlate = takeover
	self.goalPlate, self.unlockText = infoPlate("NextUnlock", "lock")
	self.doublePlate, self.doubleText = infoPlate("DoubleStars", "star")
	local exit = Dossier.rivetPlate(card, string.upper(Lang.t("win_modal.exit")), 26, false, { Name = "Exit", Position = UDim2.fromOffset(CARD_W / 2, 590), Size = UDim2.fromOffset(420, 64), Parent = card })
	exit.Activated:Connect(function()
		actions.backToMenu()
	end)
	-- Keep playing (or spectate): a small underlined link under EXIT, its tap
	-- area taller than its words (the card is about half size on a phone).
	local keep = Kit.new("TextButton", { Name = "Keep", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(CARD_W / 2, 648), Size = UDim2.fromOffset(360, 48), Parent = card })
	local keepText = typed({ Name = "Label", Text = "", RichText = true, TextColor3 = INK, TextSize = 22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = keep })
	Dossier.clicky(keep, 1.06)
	keep.Activated:Connect(function()
		win.Visible = false
	end)
	-- A public match, once won: when the next one of its kind starts (the
	-- server tells every few seconds; it counts down here between).
	self.nextText = typed({ Text = "", TextColor3 = INK, TextSize = 16, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(CARD_W / 2, 548), Visible = false, Parent = card })
	self.nextAt = nil :: number?
	self.win, self.winKeep = win, keepText
	self.winCard = card
	self.shownDeath, self.shownWin = false, false
	-- Your peaks and conquests this match, for the stat tags.
	self.resultTrack = ResultModel.newTracker()

	-- Input --------------------------------------------------------------------------------
	hold(UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not self.inMatch then
			return
		end
		local key = input.KeyCode
		-- T/Y (OpenFront's attackRatioDown/Up) and Q/E step the share by 10%,
		-- from 1% straight to 10% as ControlPanel does.
		local step = if key == Enum.KeyCode.E or key == Enum.KeyCode.Y then 0.1 elseif key == Enum.KeyCode.Q or key == Enum.KeyCode.T then -0.1 else 0
		if step ~= 0 then
			local nextRatio = math.clamp(math.floor((self.ratio + step) * 100 + 0.5) / 100, 0.01, 1)
			if nextRatio == 0.11 and self.ratio == 0.01 then
				nextRatio = 0.1
			end
			cue(self, "ui.slider")
			self:setRatio(nextRatio)
		elseif key == Enum.KeyCode.Tab then
			self:_setBoardOpen(not self.boardOpen)
		elseif key == Enum.KeyCode.H and actions.openHowToPlay then
			actions.openHowToPlay()
		elseif key == Enum.KeyCode.R and actions.reinforce and self.reinforceButton.Visible and self.reinforceButton:GetAttribute("Ready") == true then
			actions.reinforce()
		end
	end))

	-- State wiring ---------------------------------------------------------------------------
	hold(state.Snapshot:Connect(function()
		self.shownDeath, self.shownWin = false, false
		self.resultTrack = ResultModel.newTracker()
		self.starsPlate.Visible, self.goalPlate.Visible, self.doublePlate.Visible = false, false, false
		self.nextAt, self.nextText.Visible = nil, false
		self:_layoutResult()
		self.incomingBoats = {}
		self:_clearNotes()
		self:showMatch(true)
		self:_refreshAll()
	end) :: any)
	hold(state.StatsChanged:Connect(function()
		ResultModel.track(self.resultTrack, state:me(), self:_landTotal())
		self:_refreshPanel()
		self:_refreshTop()
		if os.clock() - (self.boardAt or 0) >= BOARD_INTERVAL then
			self:_refreshBoard()
		end
	end))
	hold(state.AttacksChanged:Connect(function()
		self:_refreshAttacks()
	end))
	hold(state.UnitsChanged:Connect(function()
		self:_refreshAttacks() -- boats
	end))
	hold(state.PhaseChanged:Connect(function()
		self:_refreshPhase()
	end))
	hold(state.TickApplied:Connect(function()
		self:_refreshClock()
		self:_checkDeath()
		self:_refreshReinforce()
	end))
	hold(state.Messages:Connect(function(messages)
		for _, m in messages do
			-- AttacksDisplay tracks incoming boats from these warnings.
			if m.kind == "NAVAL_INVASION_INBOUND" and m.params and m.params.unitId then
				self.incomingBoats[m.params.unitId] = true
			end
			local line = HudModel.messageLine(state, m)
			if line then
				self:notify(line.text, line.tone)
			end
		end
	end))
	hold(state.DiplomacyEvents:Connect(function(events)
		ResultModel.trackEvents(self.resultTrack, state:me(), events)
		for _, e in events do
			local line = HudModel.feedLine(state, e)
			if line then
				self:notify(line.text, "diplomacy")
			end
		end
	end))
	-- The hover card follows the mouse at 10 Hz.
	local hoverAt = 0
	hold(RunService.Heartbeat:Connect(function()
		if not self.inMatch or os.clock() - hoverAt < 0.1 then
			return
		end
		hoverAt = os.clock()
		self:_refreshHover()
		self:_expireNotes()
		self:_refreshNext()
	end))
	self:setRatio(DEFAULT_RATIO)
	return self
end

-- Phones (Bruno, 2026-10-27, after RoFront's phone HUD): a slim stats bar
-- along the bottom (troops, gold, the attack-share chips, what a tap sends,
-- BUILD) and the build drawer above it, closed until BUILD opens it
-- (picking a slot closes it again), with Reinforce and SHOP in it. The
-- clock joins the rank pill at the top right; the race to the goal sits
-- under the icons. The desktop top bar and command bar stay hidden; the
-- refresh code writes to the phone's widgets instead.
function OfHud._phone(self: any, match: Frame)
	local root, actions = self.root, self.actions
	local W = root.width
	self.isPhone = true

	-- Hidden for good: the desktop bars, and the music and leaderboard icons
	-- (Settings and the pill have them). The icons grow to touch size.
	self.top.Visible = false
	self.bar.Visible = false
	self.musicIcon.Visible = false
	self.boardIcon.Visible = false
	local iconScale = 1.3 * PHONE_TOP
	Kit.new("UIScale", { Scale = iconScale, Parent = self.icons })

	-- The clock, first in the rank pill.
	local pill = self.pill
	pill.Size = UDim2.fromOffset(0, 58)
	local clock = self.clockInset
	clock.Parent = pill
	clock.LayoutOrder = 0
	clock.Size = UDim2.fromOffset(0, 44)
	self.clockCaption.Visible = false
	self.clockIcon.Position = UDim2.fromOffset(0, 12)
	self.clockText.TextSize = 34
	self.clockText.Position = UDim2.fromOffset(28, 4)
	self.rankText.TextSize = 32

	-- The race to the goal (Bruno, 2026-10-27), slim, under the icons: you,
	-- your fill and the rival's behind it with a tick at its end, the bold
	-- goal line, the rival and the goal. Smaller and without names (Bruno,
	-- 2026-10-28): the rival is a swatch and a share, the crown sits before
	-- whoever leads, and the goal is gold text without a panel.
	-- Every part has a fixed width, so the shares changing every tick never
	-- resize the plaque (a varying width made placeRace rescale it each tick).
	local RACE_W, RACE_H = 620, 42
	local race = Dossier.plaque("ImageLabel", { Name = "Race", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 68), Size = UDim2.fromOffset(RACE_W, RACE_H), Parent = match })
	local raceScale = Kit.new("UIScale", { Scale = PHONE_HUD, Parent = race })
	-- Clear of the plaque's wooden frame (about 18 wide).
	Kit.padding(0, 24).Parent = race
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = race
	self.top = race -- _refreshPhase hides it while you pick a spawn
	local function share(text: string, width: number, color: Color3, order: number): TextLabel
		return stencil({ Text = text, TextSize = 26, TextColor3 = color, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromOffset(width, RACE_H - 8), TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = order, Parent = race })
	end
	self.mySwatch = Kit.new("Frame", { BackgroundColor3 = C.red, BorderSizePixel = 0, Size = UDim2.fromOffset(12, 12), LayoutOrder = 1, Parent = race })
	Kit.corner(2).Parent = self.mySwatch
	self.myShare = share("You 0%", 112, INK, 2)
	local raceTrack = Kit.new("Frame", { Name = "Track", BackgroundColor3 = INSET, BorderSizePixel = 0, Size = UDim2.fromOffset(170, 14), LayoutOrder = 3, Parent = race })
	Kit.corner(4).Parent = raceTrack
	Kit.stroke(Color3.fromHex("#14150F"), 1.5, 0).Parent = raceTrack
	self.leaderFill = Kit.new("Frame", { BackgroundColor3 = C.sheetLine, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = raceTrack })
	Kit.corner(4).Parent = self.leaderFill
	self.myFill = Kit.new("Frame", { BackgroundColor3 = C.red, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 2, Parent = raceTrack })
	Kit.corner(4).Parent = self.myFill
	self.leaderTick = Kit.new("Frame", { BackgroundColor3 = C.sheet, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(0, 3, 1, 6), ZIndex = 3, Parent = raceTrack })
	self.goalMark = Kit.new("Frame", { BackgroundColor3 = C.hazard, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.8, 0.5), Size = UDim2.new(0, 4, 1, 10), ZIndex = 4, Parent = raceTrack })
	Kit.stroke(Color3.fromHex("#14150F"), 1.5, 0).Parent = self.goalMark
	-- _refreshTop moves the crown: order 0 (before you) or 4 (before the leader).
	self.leaderCrown = Kit.glyph("crown", { ImageColor3 = GOLD_INK, Size = UDim2.fromOffset(20, 20), LayoutOrder = 4, Parent = race })
	self.leaderSwatch = Kit.new("Frame", { BackgroundColor3 = C.fgMuted, BorderSizePixel = 0, Size = UDim2.fromOffset(12, 12), LayoutOrder = 5, Parent = race })
	Kit.corner(2).Parent = self.leaderSwatch
	self.leaderShare = share("", 82, INK, 6)
	self.goalText = share("GOAL 80%", 88, GOLD_INK, 7)
	race.Visible = false
	-- On the icons' row between them and the rank pill when it fits there at
	-- a readable size (at least RACE_MIN), else under the icons at PHONE_HUD.
	local RACE_MIN = 0.7
	local iconsList = self.icons:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	local function placeRace()
		local s = root.scale.Scale
		if s <= 0 then
			return
		end
		local leftPx = self.icons.AbsolutePosition.X + iconsList.AbsoluteContentSize.X
		local rightPx = pill.AbsolutePosition.X
		local gap = (rightPx - leftPx) / s - 24
		local ox = root.gui.AbsolutePosition.X
		local scale = math.min(PHONE_HUD, gap / RACE_W)
		if scale >= RACE_MIN then
			raceScale.Scale = scale
			race.Position = UDim2.fromOffset(((leftPx + rightPx) / 2 - ox) / s, 12 + (44 * iconScale - RACE_H * scale) / 2)
		else
			raceScale.Scale = PHONE_HUD
			race.Position = UDim2.new(0.5, 0, 0, 20 + 44 * iconScale)
		end
	end
	for _, signal in { pill:GetPropertyChangedSignal("AbsolutePosition"), iconsList:GetPropertyChangedSignal("AbsoluteContentSize"), root.Changed.Event } do
		table.insert(self.connections, (signal :: any):Connect(placeRace))
	end
	task.defer(placeRace)

	-- The stats bar: every plaque two lines, all inside the rail's ends (its
	-- riveted caps are 24 wide), shrunk only when the screen is too narrow.
	local PAD, GAP, H = 26, 8, 78
	local widths = { troops = 236, gold = 172, chips = 5 * 58 + 4 * 4, sends = 112, build = 112 }
	local need = 2 * PAD + 4 * GAP + widths.troops + widths.gold + widths.chips + widths.sends + widths.build
	local fit = math.min(1, (W - 24) / need) * PHONE_HUD
	local bar = Dossier.rail({ Name = "PhoneBar", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.fromOffset(need, H + 16), Parent = match })
	Kit.new("UIScale", { Scale = fit, Parent = bar })
	Kit.padding(0, PAD).Parent = bar
	Kit.list(Enum.FillDirection.Horizontal, GAP, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = bar
	self.bar = bar
	local function plaque(name: string, width: number, order: number): ImageLabel
		return Dossier.plaque("ImageLabel", { Name = name, Size = UDim2.fromOffset(width, H), LayoutOrder = order, Parent = bar })
	end
	-- Troops: the count, then "/ limit" and the rate, then the fill.
	local troops = plaque("Troops", widths.troops, 1)
	-- Each plaque's lines are placed by their centres so the block sits in
	-- the middle of the plaque's paper (y 9..69).
	Kit.glyph("troops", { ImageColor3 = INK, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(14, 25), Size = UDim2.fromOffset(26, 26), Parent = troops })
	self.troopsText = stencil({ Text = "", TextSize = 32, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(46, 25), Parent = troops })
	self.troopLimit = stencil({ Text = "", TextSize = 19, TextColor3 = INK_SOFT, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(46, 46), Parent = troops })
	self.rateText = stencil({ Text = "+0/s", TextSize = 19, TextColor3 = GOOD, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16, 0, 46), Parent = troops })
	local track = Kit.new("Frame", { BackgroundColor3 = INSET, BorderSizePixel = 0, Position = UDim2.fromOffset(14, 56), Size = UDim2.new(1, -28, 0, 6), Parent = troops })
	Kit.corner(3).Parent = track
	self.troopFill = Kit.new("Frame", { BackgroundColor3 = Color3.fromRGB(232, 92, 140), BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = track })
	Kit.corner(3).Parent = self.troopFill
	-- Gold, then its rate.
	local gold = plaque("Gold", widths.gold, 2)
	Kit.glyph("gold", { ImageColor3 = INK, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(14, 30), Size = UDim2.fromOffset(26, 26), Parent = gold })
	self.goldText = stencil({ Text = "0", TextSize = 32, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(46, 30), Parent = gold })
	self.goldRate = stencil({ Text = "", TextSize = 19, TextColor3 = GOOD, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(46, 51), Parent = gold })
	-- The attack-share chips.
	local chips = Kit.new("Frame", { Name = "Attack", BackgroundTransparency = 1, Size = UDim2.fromOffset(widths.chips, H), LayoutOrder = 3, Parent = bar })
	self.ratioChips, self.ratioSet = {}, {}
	for i, r in CHIPS do
		local chip, set = Dossier.rivetPlate(chips, `{math.floor(r * 100 + 0.5)}%`, 30, false, { Name = `Share{i}`, Position = UDim2.fromOffset(29 + (i - 1) * 62, H / 2), Size = UDim2.fromOffset(58, 62), Parent = chips })
		local function pick()
			cue(self, "ui.slider")
			self:setRatio(r)
		end
		chip.Activated:Connect(pick)
		-- A taller tap area; side by side they touch, 62 apart (audit F12).
		Dossier.hitPad(chip, pick, 62, nil)
		self.ratioChips[r] = chip
		self.ratioSet[r] = set
	end
	-- What a tap sends: the caption, then the number.
	local sends = plaque("Sends", widths.sends, 4)
	stencil({ Text = "SENDS", TextSize = 18, TextColor3 = INK_SOFT, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 27), Parent = sends })
	self.sendsText = stencil({ Text = "", TextSize = 32, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 49), Parent = sends })
	-- BUILD opens and closes the drawer.
	local buildHolder = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(widths.build, H), LayoutOrder = 5, Parent = bar })
	local build, setBuild = Dossier.rivetPlate(buildHolder, "BUILD", 36, false, { Name = "Build", Position = UDim2.fromOffset(widths.build / 2, H / 2), Size = UDim2.fromOffset(widths.build, 68), Parent = buildHolder })
	self.buildButton = build -- (the tutorial's mark points at it)
	-- The desktop bar's name, share and percentage aren't shown.
	self.nameText = stencil({ Parent = nil })
	self.worldText = stencil({ Parent = nil })
	self.ratioText = stencil({ Parent = nil })
	self.swatch = Kit.new("Frame")

	-- The drawer above the bar: the build slots (OfActions fills them),
	-- Reinforce when unlocked, and SHOP.
	local drawer = Dossier.rail({ Name = "BuildDrawer", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6 - math.round((H + 16) * fit) - 8), Size = UDim2.fromOffset(0, 124), AutomaticSize = Enum.AutomaticSize.X, Visible = false, Parent = match })
	Kit.new("UIScale", { Scale = math.min(1, (W - 24) / 1110) * PHONE_HUD, Parent = drawer })
	Kit.padding(0, 26).Parent = drawer
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = drawer
	local slotsBack = Kit.new("Frame", { Name = "SlotsBack", BackgroundColor3 = INSET, BorderSizePixel = 0, Size = UDim2.fromOffset(0, 112), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 1, Parent = drawer })
	Kit.corner(4).Parent = slotsBack
	Kit.stroke(Color3.fromHex("#14150F"), 2, 0).Parent = slotsBack
	Kit.padding(4, 4).Parent = slotsBack
	local slots = Kit.new("Frame", { Name = "Slots", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 104), AutomaticSize = Enum.AutomaticSize.X, Parent = slotsBack })
	self.slotsHost = slots
	-- Reinforce: a plaque tile (Bruno, 2026-10-27: not a plate over the map).
	local reinforce = Dossier.plaque("ImageButton", { Name = "Reinforce", Size = UDim2.fromOffset(112, 104), Visible = false, LayoutOrder = 2, Parent = drawer })
	Kit.glyph("troops", { ImageColor3 = INK, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10), Size = UDim2.fromOffset(30, 30), Parent = reinforce })
	stencil({ Text = "REINFORCE", TextSize = 18, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 42), Parent = reinforce })
	self.reinforceText = stencil({ Text = "", TextSize = 26, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 62), Parent = reinforce })
	Dossier.clicky(reinforce, 1.05)
	reinforce.Activated:Connect(function()
		if actions.reinforce and reinforce:GetAttribute("Ready") == true then
			actions.reinforce()
		end
	end)
	self.reinforceButton = reinforce
	local shop = Dossier.plate(drawer, "", { Name = "Shop", Size = UDim2.fromOffset(96, 104), LayoutOrder = 3, Parent = drawer }, 0)
	Kit.glyph("lock", { ImageColor3 = INK, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 16), Size = UDim2.fromOffset(40, 40), Parent = shop })
	stencil({ Text = "SHOP", TextSize = 26, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -14), Parent = shop })
	self.shopBadge = stencil({ Text = "", TextSize = 16, TextColor3 = C.sheet, BackgroundColor3 = RED, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -4, 0, 4), Visible = false, Parent = shop })
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = self.shopBadge })
	Kit.padding(2, 6).Parent = self.shopBadge
	shop.Activated:Connect(function()
		if actions.openShop then
			actions.openShop()
		end
	end)
	local function setDrawer(open: boolean)
		drawer.Visible = open and bar.Visible
		setBuild(open)
		if not drawer.Visible then
			slots:SetAttribute("drawerClosed", os.clock()) -- ARSENAL's fly-out goes too
		end
	end
	local function toggleDrawer()
		setDrawer(not drawer.Visible)
	end
	build.Activated:Connect(toggleDrawer)
	Dossier.hitPad(build, toggleDrawer, widths.build + GAP, nil)
	-- The drawer goes with the bar (hidden until you spawn, and when you die).
	bar:GetPropertyChangedSignal("Visible"):Connect(function()
		if not bar.Visible then
			setDrawer(false)
		end
	end)
	-- Picking a slot closes the drawer, so the map is clear to place it
	-- (ARSENAL keeps it open for its fly-out; a pick there closes it).
	slots.ChildAdded:Connect(function(child)
		if child:IsA("GuiButton") and child:GetAttribute("keepDrawer") ~= true then
			child.Activated:Connect(function()
				setDrawer(false)
			end)
		end
	end)
	slots:GetAttributeChangedSignal("arsenalPicked"):Connect(function()
		setDrawer(false)
	end)
	self.drawer = drawer

	-- The spawn prompt and the notes under the icons; the attacks list narrower.
	self.spawn.Position = UDim2.new(0.5, 0, 0, 84)
	self.pausedNote.Position = UDim2.new(0.5, 0, 0, 84)
	self.notesHost.Position = UDim2.fromOffset(12, 104)
	self.notesHost.Size = UDim2.fromOffset(340, 120)
	local noteList = self.notesHost:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	noteList.VerticalAlignment = Enum.VerticalAlignment.Top
	noteList.Padding = UDim.new(0, 3)
	self.attacks.Size = UDim2.fromOffset(300, 0)
	for r, set in self.ratioSet do
		set(math.abs(r - self.ratio) < 0.001)
	end
end

function OfHud.showMatch(self: any, inMatch: boolean)
	self.inMatch = inMatch
	self.match.Visible = inMatch
	self.win.Visible = false
	if not inMatch then
		self:_closePause()
		self.hover.Visible = false
	end
end

-- Stars the match paid (from the saved profile); shown on the result card,
-- counting up, with the next unlock and 2x Stars under them (`profile` is
-- the profile view: stars, owned, doubleStars).
function OfHud.showStars(self: any, gained: number, profile: any?)
	self.starsPlate.Visible = true
	local goal = ResultModel.nextGoal(Catalog.ARSENAL, profile)
	self.goalPlate.Visible = goal ~= nil
	if goal then
		self.unlockText.Text = if goal.ready then `{goal.name}  ·  UNLOCK` else `{goal.name}  {Kit.commas(goal.have)} / {Kit.commas(goal.need)}`
	end
	local doubled = ResultModel.doubled(gained, profile)
	self.doublePlate.Visible = doubled ~= nil
	if doubled then
		self.doubleText.Text = `WITH 2X STARS: +{Kit.commas(doubled)}`
	end
	self:_layoutResult()
	-- The count-up (about a second), on a NumberValue the tween owns.
	local count = Instance.new("NumberValue")
	count.Value = 0
	self.starsText.Text = "+0"
	count.Changed:Connect(function(v: number)
		self.starsText.Text = `+{Kit.commas(math.floor(v + 0.5))}`
	end)
	local tween = TweenService:Create(count, TweenInfo.new(math.clamp(gained / 800, 0.4, 1.2), Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = gained })
	tween.Completed:Connect(function()
		self.starsText.Text = `+{Kit.commas(gained)}`
		count:Destroy()
	end)
	tween:Play()
end

-- When the next public match of this one's kind starts (nil: none known).
function OfHud.showNextMatch(self: any, seconds: number?)
	self.nextAt = if type(seconds) == "number" then os.clock() + seconds else nil
	self:_refreshNext()
end

function OfHud._refreshNext(self: any)
	local at = self.nextAt
	self.nextText.Visible = at ~= nil
	if at then
		local left = math.max(0, math.ceil(at - os.clock()))
		self.nextText.Text = if left > 0 then `Next public match in {Kit.clock(left)}` else "Next public match starting now"
	end
end

-- Places the result card's rows for what is shown: PLAY AGAIN centred until
-- the Stars arrive, then beside them; one info plate centred, two side by side.
function OfHud._layoutResult(self: any)
	local W = 760
	if self.starsPlate.Visible then
		self.winAgain.Position = UDim2.fromOffset(520, 418)
	else
		self.winAgain.Position = UDim2.fromOffset(W / 2, 418)
	end
	local both = self.goalPlate.Visible and self.doublePlate.Visible
	self.goalPlate.Position = UDim2.fromOffset(if both then 210 else W / 2, 506)
	self.doublePlate.Position = UDim2.fromOffset(if both then 550 else W / 2, 506)
end

-- The highest attack share allowed (the tutorial's rookie cap, after
-- RoWorld's; 1 = every stop): the share comes down to it, and the chips above
-- it are dimmed and do nothing.
function OfHud.setRatioCap(self: any, cap: number)
	self.ratioCap = cap
	for r, chip in self.ratioChips do
		local over = r > cap + 1e-6
		local veil = chip:FindFirstChild("CapVeil") :: Frame?
		if over and veil == nil then
			veil = Kit.new("Frame", { Name = "CapVeil", BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 20, Parent = chip })
			Kit.corner(4).Parent = veil
		elseif not over and veil then
			veil:Destroy()
		end
	end
	if self.ratio > cap + 1e-6 then
		self:setRatio(self.ratio)
	end
end

function OfHud.setRatio(self: any, ratio: number)
	local cap = self.ratioCap or 1
	if ratio > cap + 1e-6 then
		-- the highest stop under the cap
		local best = 0
		for r in self.ratioChips do
			if r <= cap + 1e-6 and r > best then
				best = r
			end
		end
		ratio = if best > 0 then best else ratio
	end
	self.ratio = ratio
	for r, set in self.ratioSet do
		set(math.abs(r - ratio) < 0.001)
	end
	self:_refreshPanel()
end

function OfHud._refreshAll(self: any)
	self:_refreshPanel()
	self:_refreshTop()
	self:_refreshBoard()
	self:_refreshAttacks()
	self:_refreshPhase()
	self:_refreshClock()
end

function OfHud._color(self: any, smallID: number?): Color3
	if smallID and self.actions.playerColor then
		local c = self.actions.playerColor(smallID)
		if c then
			return c
		end
	end
	return C.fgMuted
end

function OfHud._landTotal(self: any): number
	local state = self.state
	if state.landTotal > 0 then
		return state.landTotal
	end
	local total = 0
	for _, p in state.players do
		total += p.tiles
	end
	return math.max(1, total)
end

local function pct(x: number): string
	return string.format("%.2f%%", 100 * x)
end

-- Game feel (Bruno, 2026-11-08: "all six"; docs/design/NINTENDO_FEEL_RESEARCH.md
-- part 5) -----------------------------------------------------------------------------
-- Gold and troops count up after a big gain (a payout, a donation, a
-- conquest, troops coming home) with a flash of colour, like Mario's coin
-- counter; steady income and spending show at once.
local COUNT_SECONDS = 0.5
local FLASH_SECONDS = 0.6
local GOLD_FLASH = Color3.fromHex("#C8900F")
local TROOP_FLASH = Color3.fromHex("#2E8A3E")
-- A retreat shows "recalling" until the server confirms it, or this long.
local RECALL_SECONDS = 3

-- Flashes a label's text in `color`, fading back to its own.
function OfHud._flash(self: any, label: TextLabel, color: Color3)
	local base = self.flashBase[label]
	if base == nil then
		base = label.TextColor3
		self.flashBase[label] = base
	end
	label.TextColor3 = color
	TweenService:Create(label, TweenInfo.new(FLASH_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { TextColor3 = base }):Play()
end

-- Counts every counting number toward its goal, once a frame, until none is.
function OfHud._runCounters(self: any)
	if self.countConn then
		return
	end
	self.countConn = RunService.RenderStepped:Connect(function()
		local busy = false
		for _, c in self.counters do
			if c.at then
				local p = (os.clock() - c.at) / COUNT_SECONDS
				if p >= 1 then
					c.shown, c.at = c.target, nil
				else
					c.shown = c.from + (c.target - c.from) * (1 - (1 - p) * (1 - p))
					busy = true
				end
				c.render(c.shown)
			end
		end
		if not busy and self.countConn then
			self.countConn:Disconnect()
			self.countConn = nil
		end
	end)
end

-- Shows `value` on counter `key`: a gain of at least `big` counts up and
-- flashes; anything else is written at once. `render(v)` writes the text.
function OfHud._count(self: any, key: string, value: number, big: number, label: TextLabel, flash: Color3, render: (number) -> ())
	local c = self.counters[key]
	if c == nil then
		c = { shown = value, target = value, from = value, at = nil :: number? }
		self.counters[key] = c
	end
	c.render = render
	if c.at then
		-- Counting: later changes move the goal; a drop shows at once.
		if value < c.shown then
			c.shown, c.target, c.at = value, value, nil
		else
			c.target = value
		end
	elseif value - c.shown >= big then
		c.from, c.target, c.at = c.shown, value, os.clock()
		self:_flash(label, flash)
		self:_runCounters()
	else
		c.shown, c.target = value, value
	end
	render(c.shown)
end

-- An incoming attack's row: its edge blinks red twice (a new attack, or your
-- land falling fast), so the alarm points at something.
function OfHud._alarmRow(self: any, r: any)
	local stroke = r.frame:FindFirstChildOfClass("UIStroke")
	if stroke == nil then
		return
	end
	stroke.Color, stroke.Thickness = C.manilaLine, 1.5
	TweenService:Create(stroke, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 1, true), { Color = RED, Thickness = 4 }):Play()
	TweenService:Create(r.icon, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 1, true), { Size = UDim2.fromOffset(26, 26) }):Play()
end

-- The land-falling-fast alarm sounded: every incoming row blinks.
function OfHud.pulseIncoming(self: any)
	for _, r in self.attackRows do
		if r.incoming then
			self:_alarmRow(r)
		end
	end
end

function OfHud._refreshPanel(self: any)
	local state = self.state
	local me = state:me()
	if me == nil or not me.alive or state:inSpawnPhase() then
		self.bar.Visible = false -- ControlPanel hides until you spawn, and when you die
		return
	end
	self.bar.Visible = true
	self.swatch.BackgroundColor3 = self:_color(me.smallID)
	self.nameText.Text = me.displayName
	self.worldText.Text = `{pct(me.tiles / self:_landTotal())} of the world`
	local perSecond = troopRate(me.troops, me.maxTroops) * 10
	self.rateText.Text = `+{Format.renderTroops(perSecond)}/s`
	local maxTroops = me.maxTroops
	if self.isPhone then
		self.troopLimit.Text = `/ {Format.renderTroops(maxTroops)}`
	end
	self:_count("troops", me.troops, math.max(10, 0.05 * maxTroops), self.troopsText, TROOP_FLASH, function(v: number)
		if self.isPhone then
			self.troopsText.Text = Format.renderTroops(v)
		else
			self.troopsText.Text = `{Format.renderTroops(v)} <font color="#5E5748" size="22">/ {Format.renderTroops(maxTroops)}</font>`
		end
	end)
	self.troopFill.Size = UDim2.fromScale(if me.maxTroops > 0 then math.clamp(me.troops / me.maxTroops, 0, 1) else 0, 1)
	self.ratioText.Text = `{math.floor(self.ratio * 100 + 0.5)}%`
	self.sendsText.Text = if self.isPhone then Format.renderTroops(me.troops * self.ratio) else `Sends {Format.renderTroops(me.troops * self.ratio)} troops`
	self:_count("gold", state.gold, math.max(2000, 0.05 * state.gold), self.goldText, GOLD_FLASH, function(v: number)
		self.goldText.Text = Format.renderNumber(math.floor(v))
	end)
	local ok, rate = pcall(function()
		return state:config():goldAdditionRate({
			type = function()
				return "HUMAN"
			end,
			info = function()
				return { playerType = "HUMAN" }
			end,
		})
	end)
	self.goldRate.Text = if ok and type(rate) == "number" then `+{Format.renderNumber(rate * 10)}/s` else ""
end

-- The Reinforcements button: what it gives now, or how long until it's ready.
function OfHud._refreshReinforce(self: any)
	local state = self.state
	local button = self.reinforceButton
	local me = state:me()
	local arsenal = state.arsenal
	local unlocked = arsenal ~= nil and arsenal.weapons ~= nil and arsenal.weapons.reinforcements == true
	if not unlocked or me == nil or not me.alive or state:inSpawnPhase() then
		button.Visible = false
		return
	end
	button.Visible = true
	local wait = math.ceil(((arsenal :: any).reinforceReadyAt - state.tick) / 10)
	local add = math.floor(math.min(me.maxTroops * Config.REINFORCE_SHARE, me.maxTroops - me.troops))
	local ready = wait <= 0 and state.gold >= Config.REINFORCE_GOLD and add > 0
	button:SetAttribute("Ready", ready)
	local label = self.reinforceText
	if self.isPhone then
		-- The drawer's tile: just what it would do now.
		label.Text = if wait > 0 then `{wait}s` elseif add <= 0 then "FULL" else `+{Format.renderTroops(add)}`
	elseif wait > 0 then
		label.Text = `REINFORCE  ·  READY IN {wait}s`
	elseif add <= 0 then
		label.Text = "REINFORCE  ·  TROOPS FULL"
	else
		label.Text = `REINFORCE  +{Format.renderTroops(add)}  ·  {Format.renderNumber(Config.REINFORCE_GOLD)}`
	end
	label.TextTransparency = if ready then 0 else 0.45
	button.ImageColor3 = if ready then Color3.new(1, 1, 1) else Color3.fromRGB(200, 195, 185)
end

-- The music icon shows a slash while music is off (Bruno, 2026-10-28).
function OfHud.setMusicOn(self: any, on: boolean)
	self.musicSlash.Visible = not on
end

function OfHud._refreshTop(self: any)
	local state = self.state
	local total = self:_landTotal()
	local me = state:me()
	local leader, second = nil, nil
	for _, p in state.players do
		if p.alive then
			if leader == nil or p.tiles > leader.tiles or (p.tiles == leader.tiles and p.smallID < leader.smallID) then
				leader, second = p, leader
			elseif second == nil or p.tiles > second.tiles or (p.tiles == second.tiles and p.smallID < second.smallID) then
				second = p
			end
		end
	end
	-- Phones (Bruno, 2026-10-28): when you lead, the crown moves before you and
	-- the right side shows the runner-up instead.
	local iLead = me ~= nil and leader ~= nil and leader.smallID == me.smallID
	if self.isPhone then
		self.leaderCrown.LayoutOrder = if iLead then 0 else 4
		if iLead then
			leader = second
		end
		self.leaderSwatch.Visible = leader ~= nil
		self.leaderShare.Visible = leader ~= nil
		self.leaderTick.Visible = leader ~= nil
		self.leaderFill.Visible = leader ~= nil
	end
	local mine = if me then me.tiles / total else 0
	-- Never invisible once you hold land: at least a sliver.
	self.myFill.Size = UDim2.new(math.clamp(mine, 0, 1), if mine > 0 then 4 else 0, 1, 0)
	self.myFill.BackgroundColor3 = self:_color(if me then me.smallID else nil)
	self.mySwatch.BackgroundColor3 = self.myFill.BackgroundColor3
	self.myShare.Text = `You {pct(mine)}`
	-- The plaque's share follows every tick, like the race bar; its rank keeps the board's 1 s cadence.
	if self.myRank and me then
		self.rankText.Text = `#{self.myRank}  ·  {pct(mine)}`
	end
	if leader then
		local share = leader.tiles / total
		self.leaderFill.Size = UDim2.fromScale(math.clamp(share, 0, 1), 1)
		self.leaderTick.Position = UDim2.new(math.clamp(share, 0, 1), 2, 0.5, 0)
		self.leaderSwatch.BackgroundColor3 = self:_color(leader.smallID)
		self.leaderTick.BackgroundColor3 = self.leaderSwatch.BackgroundColor3
		self.leaderShare.Text = if self.isPhone then pct(share) else `{leader.displayName} {pct(share)}`
	end
	local elapsed = if state.startTick then math.max(0, (state.tick - state.startTick) / 10) else 0
	local goal = state:config():percentageTilesOwnedToWin(elapsed)
	self.goalText.Text = `GOAL {goal}%`
	self.goalMark.Position = UDim2.fromScale(goal / 100, 0.5)
end

-- The rank pill and the leaderboard ---------------------------------------------------------

function OfHud._buildBoard(self: any, right: Frame)
	-- A pinned sheet of paper (Bruno's reference).
	local board = paper({ Name = "Leaderboard", Size = UDim2.fromOffset(400, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Visible = false, Parent = right })
	Kit.padding(14, 16).Parent = board
	Kit.list(Enum.FillDirection.Vertical, 1).Parent = board
	local head = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 0, Parent = board })
	Kit.glyph("leaderboard", { ImageColor3 = INK, Size = UDim2.fromOffset(24, 24), Position = UDim2.fromOffset(0, 8), Parent = head })
	local stamp = Kit.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(32, 3), Size = UDim2.fromOffset(0, 32), AutomaticSize = Enum.AutomaticSize.X, Parent = head })
	Kit.stroke(RED, 2, 0).Parent = stamp
	Kit.padding(0, 6).Parent = stamp
	stencil({ Text = "LEADERBOARD", TextSize = 24, TextColor3 = RED, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, Parent = stamp })
	local alive = Kit.new("Frame", { BackgroundColor3 = C.manila, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -38, 0, 4), Size = UDim2.fromOffset(98, 30), Parent = head })
	Kit.stroke(C.manilaLine, 1.5, 0).Parent = alive
	self.aliveText = stencil({ Text = "", TextSize = 18, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, Parent = alive })
	local x = Kit.new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 4), Size = UDim2.fromOffset(30, 30), Parent = head })
	Kit.glyph("close", { ImageColor3 = INK, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(18, 18), Parent = x })
	x.Activated:Connect(function()
		Dossier.thud()
		self:_setBoardOpen(false)
	end)
	local cols = {
		{ key = "rank", x = 0, w = 30, align = Enum.TextXAlignment.Right },
		{ key = "name", x = 58, w = 132, align = Enum.TextXAlignment.Left },
		{ key = "land", x = 192, w = 58, align = Enum.TextXAlignment.Right },
		{ key = "gold", x = 254, w = 52, align = Enum.TextXAlignment.Right },
		{ key = "troops", x = 310, w = 56, align = Enum.TextXAlignment.Right },
	}
	local function row(order: number, header: boolean): any
		local r = Kit.new("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = C.manila, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, if header then 24 else 28), LayoutOrder = order, Parent = board })
		local stroke = Kit.stroke(INK, 2, 0)
		stroke.Enabled = false
		stroke.Parent = r
		local cells = { frame = r, stroke = stroke }
		for _, c in cols do
			cells[c.key] = stencil({
				Text = "",
				TextSize = if header then 15 else 20,
				TextColor3 = if header then INK_SOFT else INK,
				Position = UDim2.fromOffset(c.x, 0),
				Size = UDim2.new(0, c.w, 1, 0),
				AutomaticSize = Enum.AutomaticSize.None,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = c.align,
				Parent = r,
			})
		end
		if header then
			-- The rule under the column names.
			Kit.new("Frame", { BackgroundColor3 = INK, BackgroundTransparency = 0.5, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1), Parent = r })
		else
			cells.dot = Kit.new("Frame", { BackgroundColor3 = C.fgMuted, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 38, 0.5, 0), Size = UDim2.fromOffset(13, 13), Parent = r })
			Kit.corner(2).Parent = cells.dot
			Kit.stroke(INK, 1, 0.4).Parent = cells.dot
			r.Activated:Connect(function()
				local id = r:GetAttribute("SmallID")
				if type(id) == "number" and self.actions.goToPlayer then
					Dossier.thud()
					self.actions.goToPlayer(id)
				end
			end)
			r.MouseEnter:Connect(function()
				if Kit.covered(r) then
					return
				end
				if r:GetAttribute("Mine") ~= true then
					r.BackgroundTransparency = 0.4
				end
			end)
			r.MouseLeave:Connect(function()
				if r:GetAttribute("Mine") ~= true then
					r.BackgroundTransparency = 1
				end
			end)
		end
		return cells
	end
	local header = row(1, true)
	header.rank.Text, header.name.Text, header.land.Text, header.gold.Text, header.troops.Text = "#", "NATION", "LAND", "GOLD", "TROOPS"
	self.boardRows = {}
	for i = 1, BOARD_ROWS do
		self.boardRows[i] = row(1 + i, false)
	end
	self.boardGap = stencil({ Text = "•••", TextColor3 = INK_SOFT, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Center, Size = UDim2.new(1, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.None, LayoutOrder = 50, Parent = board })
	self.boardMine = row(51, false)
	self.board = board
	-- The pin, over the sheet's top-right corner (in the header row, which
	-- the list layout places first).
	Dossier.art("pin", { AnchorPoint = Vector2.new(0.5, 0.75), Position = UDim2.new(1, 10, 0, -10), Size = UDim2.fromOffset(24, 32), Parent = head })
end

function OfHud._setBoardOpen(self: any, open: boolean)
	if open and not self.boardOpen then
		cue(self, "ui.sheet")
	end
	self.boardOpen = open
	self.board.Visible = open
	self.pill.Visible = not open
	if open then
		self:_refreshBoard()
	end
end

function OfHud._refreshBoard(self: any)
	local state = self.state
	self.boardAt = os.clock()
	local list = {}
	for _, id in state.rosterOrder do
		local p = state.players[id]
		if p.alive then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		if a.tiles ~= b.tiles then
			return a.tiles > b.tiles
		end
		return a.smallID < b.smallID
	end)
	-- StatsColumns: share of the land without fallout (replicated).
	local total = self:_landTotal()
	local myRank = nil
	for i, p in list do
		if p.smallID == state.you then
			myRank = i
		end
	end
	local me = state:me()
	self.myRank = myRank
	self.rankText.Text = if myRank and me then `#{myRank}  ·  {pct(me.tiles / total)}` else `{#list} alive`
	self.aliveText.Text = `{#list} alive`
	if not self.boardOpen then
		return
	end
	local function fill(cells: any, rank: number?, p: any?)
		cells.frame.Visible = p ~= nil
		if p == nil then
			return
		end
		cells.frame:SetAttribute("SmallID", p.smallID)
		cells.rank.Text = tostring(rank)
		cells.name.Text = p.displayName
		cells.land.Text = pct(p.tiles / total)
		cells.gold.Text = Format.renderNumber(p.gold)
		cells.troops.Text = Format.renderTroops(p.troops)
		cells.dot.BackgroundColor3 = self:_color(p.smallID)
		-- Your row: a yellow plate, as in the reference.
		local mine = p.smallID == state.you
		cells.stroke.Enabled = mine
		cells.frame:SetAttribute("Mine", mine)
		cells.frame.BackgroundColor3 = if mine then C.hazard else C.manila
		cells.frame.BackgroundTransparency = if mine then 0 else 1
		cells.rank.TextColor3 = if rank == 1 then GOLD_INK else INK
	end
	for i, cells in self.boardRows do
		fill(cells, i, list[i])
	end
	local outside = myRank ~= nil and myRank > BOARD_ROWS
	self.boardGap.Visible = outside
	fill(self.boardMine, myRank, if outside then list[myRank :: number] else nil)
end

-- A retreat pressed answers at once (Bruno, 2026-11-08): the row says
-- "recalling…" and drops its button until the server confirms, or for
-- RECALL_SECONDS if it never does (a rejected retreat gets its button back).
function OfHud._recall(self: any, key: string)
	self.recalling[key] = os.clock()
	self:_refreshAttacks()
end

function OfHud._recalling(self: any, key: string, confirmed: boolean): boolean
	local at = self.recalling[key]
	if at == nil then
		return false
	elseif confirmed or os.clock() - at > RECALL_SECONDS then
		self.recalling[key] = nil
		return false
	end
	return true
end

-- Attacks (AttacksDisplay): one row per attack or boat, updated in place. As
-- the source: incoming attacks from tribes are left out; your attacks and
-- boats can retreat; boats heading for you show.
function OfHud._refreshAttacks(self: any)
	local state = self.state
	local rows = self.attackRows
	local seen = {}
	local order = 0
	local out = 0
	local function row(key: string, label: string, troops: number, incoming: boolean, cancel: (() -> ())?)
		order += 1
		local r = rows[key]
		local cancellable = cancel ~= nil
		if r and r.cancellable ~= cancellable then
			r.frame:Destroy()
			r = nil
		end
		if r == nil then
			local frame = Dossier.surface("ImageLabel", "tex_manila", C.manila, { Size = UDim2.new(1, 0, 0, 42), Parent = self.attacks })
			Kit.stroke(C.manilaLine, 1.5, 0).Parent = frame
			local icon = Kit.glyph(if incoming then "siren" else "sword", { ImageColor3 = if incoming then RED else INK, Size = UDim2.fromOffset(20, 20), AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Parent = frame })
			local name = stencil({ Text = "", TextSize = 18, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 38, 0.5, 0), Size = UDim2.fromOffset(180, 22), AutomaticSize = Enum.AutomaticSize.None, TextTruncate = Enum.TextTruncate.AtEnd, Parent = frame })
			local count = stencil({ Text = "", TextSize = 19, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, if cancellable then -50 else -12, 0.5, 0), Parent = frame })
			if cancel then
				local x = Kit.new("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = INK, BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(36, 32), Parent = frame })
				Kit.corner(3).Parent = x
				Kit.glyph("retreat", { ImageColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(18, 18), Parent = x })
				x.Activated:Connect(function()
					Dossier.thud()
					cancel()
				end)
				Kit.tip(x, function(card)
					Kit.text({ Text = "Retreat", FontFace = F.uiBold, Parent = card })
				end)
			end
			r = { frame = frame, icon = icon, name = name, count = count, cancellable = cancellable, incoming = incoming }
			rows[key] = r
			if incoming then
				self:_alarmRow(r)
			end
		end
		r.frame.LayoutOrder = order
		r.name.Text = label
		r.count.Text = Format.renderTroops(troops)
		r.count.TextColor3 = if incoming then RED else INK
		seen[key] = true
		if not incoming then
			out += 1
		end
	end
	for _, a in state.attacks do
		local otherId = if a.outgoing then a.target else a.attacker
		local other = state.players[otherId]
		if not a.outgoing and other and other.type == "BOT" then
			continue
		end
		local name = if other then other.displayName else "Wilderness"
		local id = a.id
		local key = "a" .. tostring(id)
		local recalling = self:_recalling(key, a.retreating)
		local cancel = if a.outgoing and not a.retreating and not recalling then function()
			self:_recall(key)
			self.actions.cancelAttack(id)
		end else nil
		row(key, name .. (if a.retreating then " (retreating)" elseif recalling then " (recalling…)" else ""), a.troops, not a.outgoing, cancel)
	end
	for id, u in state.units do
		if u.type ~= "Transport" or u.active == false then
			continue
		end
		if u.owner == state.you then
			local key = "b" .. tostring(id)
			local recalling = self:_recalling(key, u.retreating == true)
			local cancel = if not u.retreating and not recalling and self.actions.cancelBoat then function()
				self:_recall(key)
				self.actions.cancelBoat(id)
			end else nil
			row(key, "Boat" .. (if u.retreating then " (retreating)" elseif recalling then " (recalling…)" else ""), u.troops or 0, false, cancel)
		elseif self.incomingBoats[id] then
			local owner = state.players[u.owner]
			row("b" .. tostring(id), `Boat from {if owner then owner.displayName else "?"}`, u.troops or 0, true, nil)
		end
	end
	for id in self.incomingBoats do
		local u = state.units[id]
		if u == nil or u.active == false then
			self.incomingBoats[id] = nil
		end
	end
	for key, r in rows do
		if not seen[key] then
			r.frame:Destroy()
			rows[key] = nil
			self.recalling[key] = nil
		end
	end
	self.attacks.Visible = order > 0
	self.attacksTitle.Text = if out > 0 then `ATTACKS  ·  {out} out` else "ATTACKS"
end

-- The spawn prompt, pause and the win card -------------------------------------------------

function OfHud._refreshPhase(self: any)
	local state = self.state
	local spawning = state:inSpawnPhase()
	self.spawn.Visible = spawning
	self.top.Visible = not spawning
	local solo = state.gameConfig.gameType == "Singleplayer"
	-- GameRightSidebar: singleplayer keeps its pause button after a win too
	-- (the match runs on with "Keep playing").
	self.pauseButton.Visible = solo
	local paused = state.paused and solo
	if not paused then
		self.pauseDismissed = false
		self:_closePause()
	elseif not self.pauseDismissed then
		self:_openPause()
	end
	self.pausedNote.Visible = paused and self.pauseDismissed == true
	local icon = self.pauseButton:FindFirstChild("Icon") :: ImageLabel?
	if icon then
		Kit.setGlyph(icon, if paused then "play" else "pause")
	end
	if state.winner ~= nil and not self.shownWin then
		-- The winner is a player id, or a team's name in team games: everyone
		-- on the winning team sees VICTORY (ResultModel.card).
		self.shownWin = true
		self:_setResult(false)
		self:_showWin()
	end
	self:_refreshPanel()
end

-- WinModal.tick: "You died", once, after you had spawned.
function OfHud._checkDeath(self: any)
	local state = self.state
	local me = state:me()
	-- The Takeover offer while you're out and the nation that beat you lives;
	-- after a takeover you're alive again, and the card goes.
	local offer = state.arsenal and state.arsenal.takeover
	local plate = self.takeoverPlate
	plate.Visible = offer ~= nil and me ~= nil and not me.alive and state.winner == nil
	if plate.Visible then
		local label = plate:FindFirstChild("Label", true) :: TextLabel?
		if label then
			label.Text = `TAKE OVER {string.upper(offer.name)}`
		end
		self.goalPlate.Visible, self.doublePlate.Visible = false, false
	end
	if self.shownDeath and me ~= nil and me.alive and state.winner == nil then
		self.shownDeath = false
		self.win.Visible = false
	end
	if self.shownDeath or me == nil or me.alive or state:inSpawnPhase() or me.spawnTile == nil then
		return
	end
	self.shownDeath = true
	self:_setResult(true)
	self:_showWin()
	self:_refreshPanel()
end

-- The verdict on the result card (ResultModel.card: VICTORY, DEFEAT or
-- ELIMINATED, team-aware), its stamp, the line under it and the stat tags.
local STAMP_COLOR = {
	won = Color3.fromHex("#2E8A3E"),
	lost = Color3.fromHex("#B8322A"),
	died = Color3.fromHex("#B8322A"),
}
function OfHud._setResult(self: any, died: boolean)
	local state = self.state
	local seconds = if state.startTick then math.max(0, state.tick - state.startTick) // 10 else 0
	local card = ResultModel.card(state, died, seconds, self:_landTotal())
	-- RoWorld's spaced-out kicker ("M A T C H   C O M P L E T E").
	self.winKicker.Text = (string.gsub(card.kicker, "(.)", "%1 ")):sub(1, -2)
	self.winText.Text = card.title
	self.stampText.Text = card.stamp
	self.stampText.TextColor3 = STAMP_COLOR[card.kind]
	self.stampStroke.Color = STAMP_COLOR[card.kind]
	self.subText.Text = card.sub
	ResultModel.track(self.resultTrack, state:me(), self:_landTotal())
	local t = self.resultTrack
	self.statValues[1].Text = ResultModel.share(t.peakShare)
	self.statValues[2].Text = Format.renderTroops(t.maxTroops)
	self.statValues[3].Text = tostring(t.eliminated)
	self.statValues[4].Text = ResultModel.clock(seconds)
end

function OfHud._showWin(self: any)
	local me = self.state:me()
	self.winKeep.Text = `<u>{if me and me.alive then Lang.t("win_modal.keep") else Lang.t("win_modal.spectate")}</u>`
	self.win.Visible = true
	-- Fits the screen's height with a margin (on a phone it ran off the top,
	-- Bruno's 2026-11-04 videos); the verdict strip's tilt needs a little more.
	local root = self.root
	local margin = if root.compact then 20 else 48
	self.winScale.Scale = math.min(1.1, (root.height - margin) / (self.winCardH + 8))
	-- The card drops in, then the stamp thumps down on it.
	local card, scale = self.winCard, self.stampScale
	card.Position = UDim2.fromScale(0.5, 0.46)
	TweenService:Create(card, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0.5) }):Play()
	scale.Scale = 2.2
	self.stampText.TextTransparency = 1
	task.delay(0.35, function()
		if not self.win.Visible then
			return
		end
		self.stampText.TextTransparency = 0.05
		TweenService:Create(scale, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 1 }):Play()
		task.delay(0.15, Dossier.thud)
	end)
end

-- A small dossier window (pause, leave): a header paper with the title and
-- a line under it, then a column of plates. Returns the window and a function
-- adding a plate ("yellow" for the main action, "red" to leave, else pale).
local function smallWindow(host: Instance, title: string, subtitle: string?, rows: number, onClose: (() -> ())?): (Dossier.Window, (string, string, () -> ()) -> ())
	local h = 200 + rows * 84
	-- Shrunk to fit a phone's height.
	local w = Dossier.window(host, 560, h, math.min(h, if Kit.root then Kit.root.height - 24 else h), 36, onClose)
	Dossier.headerPaper(w, 24, 34, 512, 116, -0.5)
	Dossier.stencil({ Text = string.upper(title), TextSize = 56, AnchorPoint = Vector2.new(0, 0.5), Position = w.at(56, if subtitle then 78 else 92), Parent = w.header })
	if subtitle then
		Dossier.typed({ Text = subtitle, TextColor3 = INK, TextSize = 19, AnchorPoint = Vector2.new(0, 0.5), Position = w.at(58, 120), Parent = w.header })
	end
	Dossier.clip(w.header, w, 34, 60, 70, -6)
	Dossier.closeManila(w.header, w.at(508, 64), w.sz(52, 48), w.close)
	local n = 0
	local function add(kind: string, text: string, fn: () -> ())
		n += 1
		local y = 180 + (n - 1) * 84
		local b
		if kind == "yellow" then
			b = Dossier.plate(w.body, text, { AnchorPoint = Vector2.new(0.5, 0.5), Position = w.at(280, y + 34), Size = w.sz(480, 72), Parent = w.body }, 34)
			Dossier.clicky(b, 1.03)
		else
			b = Dossier.rivetPlate(w.body, text, 26, false, { Position = w.at(280, y + 34), Size = w.sz(480, 68), Parent = w.body })
			if kind == "red" then
				b.Image = ""
				b.BackgroundTransparency = 0
				b.BackgroundColor3 = RED
				Kit.corner(5).Parent = b
				local label = b:FindFirstChild("Label") :: TextLabel?
				if label then
					label.TextColor3 = C.sheet
				end
			end
		end
		b.Activated:Connect(fn)
	end
	return w, add
end

function OfHud._openPause(self: any)
	if self.pauseModal then
		return
	end
	local state = self.state
	local rows = if self.actions.restartSolo then 5 else 4
	-- Closing with the X keeps the game paused so the map can be looked at;
	-- RESUME, restart and leave unpause as before.
	local unpause = false
	local modal, add = smallWindow(self.root.modal, "Paused", `Solo match  ·  {MenuModel.difficultyName(state.gameConfig.difficulty or "Medium")}`, rows, function()
		self.pauseModal = nil
		if not self.state.paused then
			return
		end
		if unpause then
			self.actions.togglePause(false)
		else
			self.pauseDismissed = true
			self.pausedNote.Visible = true
		end
	end)
	add("yellow", "RESUME", function()
		unpause = true
		modal.close()
	end)
	add("pale", "HOW TO PLAY", function()
		if self.actions.openHowToPlay then
			self.actions.openHowToPlay()
		end
	end)
	add("pale", "SETTINGS", function()
		if self.actions.openSettings then
			self.actions.openSettings()
		end
	end)
	if self.actions.restartSolo then
		add("pale", "RESTART MATCH", function()
			self.pauseModal = nil
			unpause = true
			modal.close()
			self.actions.restartSolo()
		end)
	end
	add("red", "LEAVE MATCH", function()
		self.pauseModal = nil
		unpause = true
		modal.close()
		self.actions.backToMenu()
	end)
	self.pauseModal = modal
end

function OfHud._closePause(self: any)
	local modal = self.pauseModal
	if modal then
		self.pauseModal = nil
		modal.close()
	end
end

function OfHud._confirmLeave(self: any)
	local solo = self.state.gameConfig.gameType == "Singleplayer"
	local modal, add = smallWindow(self.root.modal, "Leave the match?", if solo then "This solo match ends." else "Your nation stays on the map without you.", 2)
	add("red", "LEAVE", function()
		modal.close()
		self.actions.backToMenu()
	end)
	add("pale", "STAY", function()
		modal.close()
	end)
end

function OfHud._refreshClock(self: any)
	local state = self.state
	if state.startTick == nil then
		-- Multiplayer spawn phase: the seconds left to choose (singleplayer
		-- waits for your spawn instead).
		-- The deploying card (Bruno, feature 2): the dial shows the seconds
		-- left and its ring drains; once your capital is down it reads
		-- "DEPLOYING IN n", in solo and multiplayer.
		local verb = if Kit.touch() then "Tap" else "Click"
		local me = state:me()
		local placed = me ~= nil and me.tiles > 0
		local ticksLeft, total = nil, nil
		if state.gameConfig.gameType ~= "Singleplayer" and state.ready then
			total = state:config():numSpawnPhaseTurns()
			ticksLeft = math.max(0, total - state.tick)
		elseif state.deployDeadline ~= nil and state.ready then
			-- Conquest's solo deploy countdown: placed, and still movable.
			placed = true
			total = 10 * (state.gameConfig.soloDeployCountdown or 5)
			ticksLeft = math.max(0, state.deployDeadline - state.tick)
		end
		local left = if ticksLeft then math.max(if placed then 1 else 0, math.ceil(ticksLeft / 10)) else nil
		self.spawnTitle.Text = if placed and left then `DEPLOYING IN {left}` else "CHOOSE YOUR STARTING LOCATION"
		-- A clock tick each second of DEPLOYING IN n.
		local ticking = if placed and left then left else nil
		if ticking and ticking ~= self.deployLeft then
			cue(self, "ui.tick")
		end
		self.deployLeft = ticking
		self.spawnText.Text = if placed then `{verb} elsewhere to move your capital.` else `{verb} any unclaimed land to place your capital.`
		self.spawnDial.Visible = left ~= nil
		if left and ticksLeft and total then
			self.spawnCount.Text = tostring(left)
			local lit = math.ceil(SPAWN_SEGMENTS * math.clamp(ticksLeft / math.max(1, total), 0, 1))
			for i, seg in self.spawnRing do
				seg.BackgroundColor3 = if i <= lit then RED else Color3.fromHex("#4A4A3C")
			end
		end
		return
	end
	local ticks = state.tick - state.startTick
	-- Game.isSpawnImmunityActive: the first spawnImmunityDuration ticks.
	local immune = ticks < state:config():spawnImmunityDuration()
	if immune then
		self.clockCaption.Text = "PROTECTED"
		self.clockCaption.TextColor3 = GOOD_LIGHT
		self.clockText.TextColor3 = GOOD_LIGHT
		self.clockText.Text = Kit.clock(math.ceil((state:config():spawnImmunityDuration() - ticks) / 10))
		Kit.setGlyph(self.clockIcon, "shield")
		self.clockIcon.ImageColor3 = GOOD_LIGHT
	else
		self.clockCaption.Text = "TIME"
		self.clockCaption.TextColor3 = C.sheetLine
		self.clockText.TextColor3 = C.sheet
		self.clockText.Text = Kit.clock(ticks // 10)
		Kit.setGlyph(self.clockIcon, "clock")
		self.clockIcon.ImageColor3 = C.sheetLine
	end
end

-- The hover card ------------------------------------------------------------------------

function OfHud._refreshHover(self: any)
	local state = self.state
	local hoverTile = self.actions.hoverTile
	local tile, terrain = nil, nil
	if hoverTile then
		tile, terrain = hoverTile()
	end
	-- Hidden over the HUD's panels, in dialogs and off the map.
	local mouse = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
	local overUi = false
	for _, o in self.root.gui.Parent:GetGuiObjectsAtPosition(mouse.X, mouse.Y) do
		if o.BackgroundTransparency < 0.95 and o:IsDescendantOf(self.root.gui) and o ~= self.hover and not o:IsDescendantOf(self.hover) then
			overUi = true
			break
		end
	end
	-- No hover on a touch screen or a phone layout (Bruno, 2026-10-27).
	if tile == nil or overUi or not state.ready or Kit.touch() or self.isPhone then
		self.hover.Visible = false
		return
	end
	local owner = state:ownerAt(tile)
	local p = if owner ~= 0 then state.players[owner] else nil
	local ground = terrainName(terrain) or ""
	local land = ground ~= "Ocean" and ground ~= "Lake"
	-- Bruno, 2026-11-10 (review U5): none over water, and none while the
	-- wheel, a build / launch confirmation or build mode has the player's
	-- attention (OfActions draws those in this match frame). The Arsenal
	-- fly-out too: it opens over the hover card's corner (2026-11-11).
	local chosen = if self.actions.chosenBuild then self.actions.chosenBuild() else nil
	local function shown(name: string): boolean
		local o = self.match:FindFirstChild(name)
		return o ~= nil and (o :: GuiObject).Visible
	end
	if not land or chosen ~= nil or shown("Wheel") or shown("ConfirmCard") or shown("ArsenalFly") then
		self.hover.Visible = false
		return
	end
	local who = if p then p.displayName else "Unclaimed"
	local tag = if p and p.type == "BOT" then "Tribe" elseif p and p.type == "NATION" then "Nation" else nil
	self.hoverTitle.Text = `{who}{if tag then `  <font color="#5E5748" size="16">{string.upper(tag)}</font>` else ""}  <font color="#5E5748">•</font>  {ground}`
	local me = state:me()
	local send = if me then Format.renderTroops(me.troops * self.ratio) else "0"
	local action: string?, icon, color = nil, "sword", GOOD
	if state:inSpawnPhase() then
		if owner == 0 then
			action, icon = "Click: start here", "target"
		end
	elseif me == nil or not me.alive then
		action = nil
	elseif owner == state.you then
		action, icon, color = "Your land", "flag", INK_SOFT
	elseif p and HudModel.isAlly(state, owner) then
		action, icon, color = "Your ally: you can't attack", "alliance", INK_SOFT
	elseif p then
		action, icon, color = `Click: attack with {send}`, "sword", RED
	else
		action = `Click: expand with {send}`
	end
	self.hoverActionRow.Visible = action ~= nil
	if action then
		self.hoverAction.Text = action
		self.hoverAction.TextColor3 = color
		Kit.setGlyph(self.hoverIcon, icon)
		self.hoverIcon.ImageColor3 = color
	end
	self.hover.Visible = true
end

-- Notifications -----------------------------------------------------------------------------

local TONE: { [string]: { color: Color3, icon: string } } = {
	danger = { color = Color3.fromHex("#B8322A"), icon = "siren" },
	good = { color = Color3.fromHex("#2E8A3E"), icon = "check" },
	diplomacy = { color = Color3.fromHex("#7A3FC0"), icon = "alliance" },
	info = { color = Color3.fromHex("#2C5E8A"), icon = "info" },
}

-- A notification's paper in its tone (Bruno, 2026-11-02: the whole border
-- in the colour, with a faint wash of it over the paper, not a line down the
-- left edge).
local NOTE_TINT = 0.1
local function tonedPaper(color: Color3, thickness: number, props: { [string]: any }): ImageLabel
	local p = paper(props)
	p.ImageColor3 = Color3.new(1, 1, 1):Lerp(color, NOTE_TINT)
	p.BackgroundColor3 = C.sheet:Lerp(color, NOTE_TINT)
	local stroke = p:FindFirstChildOfClass("UIStroke") :: UIStroke
	stroke.Color = color
	stroke.Thickness = thickness
	return p
end

function OfHud.notify(self: any, text: string, tone: string?)
	local style = TONE[tone or "info"] or TONE.info
	if self.isPhone then
		-- One short line (Bruno, 2026-10-27: small, out of the way).
		text = string.gsub(text, "^Conquered (.-), received (.-) gold$", "Conquered %1 · +%2")
	end
	local danger = tone == "danger"
	local seconds = (if danger then DANGER_SECONDS else NOTE_SECONDS) * (if self.isPhone then 0.6 else 1)
	-- A repeat of any line still showing counts up and moves to the top
	-- instead of stacking ("trade ship captured by Mongolia / Iceland" took
	-- turns and never merged), but never stays past NOTE_LIFE.
	for i, n in self.notes do
		if n.text == text and n.frame.Parent then
			n.count += 1
			n.counter.Text = `x{n.count}`
			n.counter.Visible = true
			n.expires = math.min(os.clock() + seconds, n.born + NOTE_LIFE)
			self.noteCount += 1
			n.frame.LayoutOrder = -self.noteCount
			table.remove(self.notes, i)
			table.insert(self.notes, n)
			return
		end
	end
	self.noteCount += 1
	if self.isPhone then
		-- A one-line slip, gone sooner.
		local slip = tonedPaper(style.color, 1.5, { Size = UDim2.new(1, 0, 0, 22), LayoutOrder = -self.noteCount, Parent = self.notesHost })
		Kit.glyph(style.icon, { ImageColor3 = style.color, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 8, 0.5, 0), Size = UDim2.fromOffset(13, 13), Parent = slip })
		-- Shrinks to fit before truncating, so the nation at the end of
		-- "Naval invasion incoming from …" stays readable (2026-10-28 video).
		local line = typed({ Text = text, TextColor3 = INK, TextSize = 13, TextScaled = true, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 26, 0.5, 0), Size = UDim2.new(1, -60, 1, 0), Parent = slip })
		Kit.new("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 9, Parent = line })
		local slipCounter = stencil({ Text = "", TextSize = 14, TextColor3 = style.color, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Visible = false, Parent = slip })
		table.insert(self.notes, { frame = slip, text = text, count = 1, counter = slipCounter, danger = danger, born = os.clock(), expires = os.clock() + seconds })
		self:_trimNotes()
		return
	end
	-- A paper slip framed and washed in the tone's colour.
	local card = tonedPaper(style.color, 2, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = -self.noteCount, Parent = self.notesHost })
	Kit.new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 50), PaddingRight = UDim.new(0, 44), Parent = card })
	Kit.glyph(style.icon, { ImageColor3 = style.color, Position = UDim2.fromOffset(-36, 0), Size = UDim2.fromOffset(22, 22), Parent = card })
	typed({ Text = text, TextColor3 = INK, TextSize = 18, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card })
	local counter = stencil({ Text = "", TextSize = 17, TextColor3 = style.color, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 36, 0, 0), Visible = false, Parent = card })
	table.insert(self.notes, {
		frame = card,
		text = text,
		count = 1,
		counter = counter,
		danger = danger,
		born = os.clock(),
		expires = os.clock() + seconds,
	})
	self:_trimNotes()
end

-- Over MAX_NOTES, the oldest routine line goes first, so a pile of trade-ship
-- news can't push out an atom-bomb alert (2026-11-10 review).
function OfHud._trimNotes(self: any)
	while #self.notes > MAX_NOTES do
		local at = 1
		for i, n in self.notes do
			if not n.danger then
				at = i
				break
			end
		end
		local old = table.remove(self.notes, at)
		old.frame:Destroy()
	end
end

function OfHud._expireNotes(self: any)
	-- Not over the result card (2026-11-10 review: they showed behind it).
	local hide = self.win.Visible
	if self.notesHost.Visible == hide then
		self.notesHost.Visible = not hide
	end
	-- Phones: while a build or launch banner (OfActions, top centre) is up,
	-- the notes move under it; it hid their text (2026-11-04 videos).
	if self.isPhone then
		local banner = self.match:FindFirstChild("BuildBanner") :: GuiObject?
		local y = if banner and banner.Visible then 158 else 104
		if self.notesHost.Position.Y.Offset ~= y then
			self.notesHost.Position = UDim2.fromOffset(12, y)
		end
	end
	local now = os.clock()
	for i = #self.notes, 1, -1 do
		local n = self.notes[i]
		if now >= n.expires then
			n.frame:Destroy()
			table.remove(self.notes, i)
		end
	end
end

function OfHud._clearNotes(self: any)
	for _, n in self.notes do
		n.frame:Destroy()
	end
	self.notes = {}
end

function OfHud.destroy(self: any)
	for _, c in self.connections do
		c:Disconnect()
	end
	if self.countConn then
		self.countConn:Disconnect()
		self.countConn = nil
	end
	self:_closePause()
	self.match:Destroy()
end

return OfHud
