--!strict
-- The OpenFront port's action UI, for Roblox: touch-sized, no hover-only
-- information, in the classified-dossier look (2026-10-27: paper sheets,
-- manila and yellow buttons, ink text, dark key tiles for the build slots). What it shows comes from the pure
-- HudModel (Shared.OpenFront) and the server's playerActions answer;
-- everything it does goes out as Runner intents through `actions`.
--   - Build bar (UnitDisplay.ts): ten items on keys 1..0 with price and
--     levels owned. Choosing one makes the next map tap a build_action
--     (atom and hydrogen bombs stay chosen, as OpenFront keeps their ghost).
--     The same key, Esc or the item again clears it; buildChosen tells the
--     map's ghost preview. U flips the rocket arc (swapDirection).
--   - Action sheet (MainRadialMenu.ts): right-click or long-press on the map.
--     The radial menu's items (HudModel.contextMenu) as touch buttons near
--     the press: attack/donate/spawn, info, boat, alliance, build and attack
--     lists with bulk amounts, delete. Spectators get the read-only panel.
--   - Player panel (PlayerPanel.ts): a player's numbers and relation, and
--     alliance, target, embargo, emoji, donations and quick chat. While open
--     and you are alive, it asks the server again every tick, as the
--     source's tick() does.
--   - Emoji table (EmojiTable.ts) and quick chat (ChatModal.ts) sheets.
--   - Alliance cards (ActionableEvents.ts): accept/reject a request, renew
--     an alliance about to expire.
-- Not yet: the send gold/troops amount modals (the default amounts go out).

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OF = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("OpenFront")
local Emoji = require(OF.Data.Emoji)
local ArsenalUnits = require(OF.ArsenalUnits)
local Format = require(OF.Format)
local HudModel = require(OF.HudModel)
local Lang = require(OF.Lang)

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)

-- The dossier's ink on paper, under the names this module was written with.
local T = Theme.color
local C = setmetatable({
	fg = T.inkBlack,
	fgSoft = T.inkFaded,
	fgMuted = Color3.fromHex("#8A8170"),
	creamSoft = T.inkFaded,
	gold = Color3.fromHex("#B07A0E"),
	star = Color3.fromHex("#B07A0E"),
	coral = T.stamp,
	red = T.stamp,
	amber = T.hazard,
	line = T.sheetLine,
	surface = T.sheet,
}, { __index = T }) :: any
local A = UiAssets.dossier

local OfActions = {}

-- Game feel (below): the pop-in curve, shared by toasts and cards.
local POP_FROM: number, POP_OVER: number, POP_SECONDS: number
local popScale: (number) -> number

-- Plays a HUD sound when the client gave a player.
local function cue(self: any, key: string)
	if self.actions.sound then
		self.actions.sound(key)
	end
end
OfActions.__index = OfActions

type ScreenRect = { x: number, y: number, w: number, h: number }

local function overlaps(ax: number, ay: number, aw: number, ah: number, r: ScreenRect): boolean
	return ax < r.x + r.w and r.x < ax + aw and ay < r.y + r.h and r.y < ay + ah
end

export type Actions = {
	sendIntent: (intent: { [string]: any }) -> (),
	-- A HUD sound by sound board key (Ui/OpenFront/SoundPicks).
	sound: ((key: string) -> ())?,
	-- GameRunner.playerActions on the server; may yield.
	queryActions: (otherSmallID: number) -> { [string]: any }?,
	-- GameRunner.playerProfile: a nation's relation toward you; may yield.
	queryProfile: ((otherSmallID: number) -> { [string]: any }?)?,
	-- The same for a map tile, with buildableUnits (the radial menu's call).
	queryTile: ((tile: number) -> { [string]: any }?)?,
	-- The chosen build type changed (nil: none), for the map's ghost.
	buildChosen: ((unitType: string?) -> ())?,
	-- Fly the camera to a player (GoToPlayerEvent).
	goToPlayer: ((smallID: number) -> ())?,
	-- The control panel's attack ratio (0..1).
	ratio: (() -> number)?,
	-- The rocket arc flipped (SwapRocketDirectionEvent), for the aim preview.
	rocketDirectionChanged: ((up: boolean) -> ())?,
	-- The "Select before attacking" setting (on unless the player turned it off).
	selectBeforeAttack: (() -> boolean)?,
	-- A player's territory colour, for the attack card's swatch.
	playerColor: ((smallID: number) -> Color3?)?,
	-- Runner.buildPreview for a tile and type (buildable, with canUpgrade); may yield.
	queryBuild: ((tile: number, unit: string) -> { [string]: any }?)?,
	-- Holds the map's ghost, range and aim on a tile while the ✓ ✕ card is open (nil frees it).
	buildPending: ((tile: number?) -> ())?,
	-- A tile's centre in screen pixels (AbsolutePosition space).
	tileToScreen: ((tile: number) -> Vector2?)?,
	-- Calls back when the map camera moves; returns a disconnect.
	onCameraChanged: ((callback: () -> ()) -> () -> ())?,
	-- Ends the map's warship selection (the warship card's close).
	deselectWarship: (() -> ())?,
	-- Centres the camera on a tile (the wheel's Focus).
	focusTile: ((tile: number) -> ())?,
	-- A player's name on the map in screen pixels, nil when not shown.
	nameScreenPosition: ((smallID: number) -> Vector2?)?,
	-- That name and troops as drawn ({x, y, w, h}, screen pixels), nil when not
	-- shown; with `unshifted`, where it sits before the map moves it off panels.
	nameScreenRect: ((smallID: number, unshifted: boolean?) -> ScreenRect?)?,
	-- The HUD's visible panels (screen pixels), as sent to the map's labels.
	hudRects: (() -> { ScreenRect })?,
}

local KEYCODES = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
	Enum.KeyCode.Five,
	Enum.KeyCode.Six,
	Enum.KeyCode.Seven,
	Enum.KeyCode.Eight,
	Enum.KeyCode.Nine,
	Enum.KeyCode.Zero,
	Enum.KeyCode.Minus, -- the ARSENAL slot (Conquest's Arsenal)
}
-- UnitDisplay shows no count for bombs (not "countable").
local UNCOUNTED = { ["Atom Bomb"] = true, ["Hydrogen Bomb"] = true, MIRV = true, ["Mega Nuke"] = true, Scattershot = true, ["Air Strike"] = true, ["Railgun Shot"] = true, Paratroopers = true, Sabotage = true }
local SLOT_ICON = {
	City = "city",
	Factory = "factory",
	Port = "port",
	["Defense Post"] = "defense",
	["SAM Launcher"] = "sam",
	["Missile Silo"] = "silo",
	Warship = "warship",
	["Atom Bomb"] = "atom",
	["Hydrogen Bomb"] = "hydrogen",
	MIRV = "mirv",
	["Mega Nuke"] = "explosion",
	Scattershot = "mirv",
	Artillery = "defense",
	Airfield = "port",
	["Air Strike"] = "explosion",
	Railgun = "silo",
	["Railgun Shot"] = "explosion",
	Paratroopers = "boat",
	["Coastal Battery"] = "port",
	Sabotage = "explosion",
	["Field Works"] = "defense",
}
-- The dossier's slot art (off-white silhouettes) by build type.
local SLOT_ART = {
	City = "slot_city",
	Factory = "slot_factory",
	Port = "slot_port",
	["Defense Post"] = "slot_defense",
	["SAM Launcher"] = "slot_sam",
	["Missile Silo"] = "slot_silo",
	Warship = "slot_warship",
	["Atom Bomb"] = "slot_atom",
	["Hydrogen Bomb"] = "slot_hydrogen",
	MIRV = "slot_mirv",
	["Mega Nuke"] = "slot_mega",
	Scattershot = "slot_scatter",
	Artillery = "slot_artillery",
	Airfield = "slot_airfield",
	["Air Strike"] = "slot_airstrike",
	Railgun = "slot_railgun",
	["Railgun Shot"] = "slot_railgunshot",
	Paratroopers = "slot_paratroopers",
	["Coastal Battery"] = "slot_coastal",
	Sabotage = "slot_sabotage",
	["Field Works"] = "slot_fieldworks",
}

-- Kit.button's kinds in the dossier look: primary is a yellow plate, danger
-- red, the rest manila; ink text in the stencil face. Kit.setEnabled still
-- dims them.
local BUTTON: { [string]: { bg: Color3, text: Color3, stroke: Color3 } } = {
	primary = { bg = T.hazard, text = T.inkBlack, stroke = Color3.fromHex("#8A6A12") },
	danger = { bg = T.stamp, text = T.sheet, stroke = Color3.fromHex("#6E1A14") },
	secondary = { bg = T.manila, text = T.inkBlack, stroke = T.manilaLine },
	chip = { bg = T.manila, text = T.inkBlack, stroke = T.manilaLine },
	dark = { bg = T.manila, text = T.inkBlack, stroke = T.manilaLine },
}
local function button(kind: string, props: { [string]: any }): TextButton
	local style = BUTTON[kind] or BUTTON.dark
	local b = Kit.button(kind :: any, props)
	-- Stencil caps, unless the caller chose a face (the emoji table).
	if props.FontFace == nil then
		b.FontFace = Theme.font.stencil
	end
	-- The stencil face reads small: a size up.
	b.TextSize = math.max(b.TextSize + 7, 24)
	b.TextColor3 = style.text
	b:SetAttribute("BaseColor", style.bg)
	b.BackgroundColor3 = style.bg
	local stroke = b:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = style.stroke
		stroke.Thickness = 1.5
	end
	local corner = b:FindFirstChildOfClass("UICorner")
	if corner then
		corner.CornerRadius = UDim.new(0, 4)
	end
	b.Activated:Connect(Dossier.thud)
	return b
end

-- A chip that is chosen fills yellow.
local function setChipSelected(b: TextButton, selected: boolean)
	local bg = if selected then T.hazard else T.manila
	b:SetAttribute("BaseColor", bg)
	b.BackgroundColor3 = bg
	b.TextColor3 = T.inkBlack
end

-- A sheet of paper (the action sheet, player panel, pickers, cards).
local function panel(props: { [string]: any }): Frame
	local frame = Dossier.surface("ImageLabel", "tex_paper", T.sheet, props)
	-- Takes clicks, so nothing under the sheet reacts.
	frame.Active = true
	Kit.stroke(T.sheetLine, 1.5, 0).Parent = frame
	return frame
end

local function text(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = { TextColor3 = C.fg, FontFace = Theme.font.typewriter, TextSize = 17 }
	for k, v in props do
		defaults[k] = v
	end
	return Kit.label(defaults)
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- A riveted plate (yellow, pale, or red for a launch) with a picture or a
-- glyph and stencil text, as in mockup A.
local function plate(parent: Instance, kind: "yellow" | "pale" | "red", pic: string?, glyph: string?, label: string, props: { [string]: any }): (GuiButton, TextLabel?)
	local b: any
	if kind == "red" then
		b = Kit.new("TextButton", Dossier.merge({ Text = "", AutoButtonColor = false, BackgroundColor3 = T.stamp, BorderSizePixel = 0 }, props))
		Kit.corner(5).Parent = b
		Kit.stroke(Color3.fromHex("#6E1A14"), 2, 0).Parent = b
		b.Activated:Connect(Dossier.click)
		Dossier.clicky(b, 1.05)
	else
		b = Dossier.rivetPlate(parent, "", 20, kind == "yellow", Dossier.merge({ AnchorPoint = Vector2.new(0, 0) }, props))
	end
	local row = Kit.new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = b })
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = row
	local ink = if kind == "red" then T.sheet else T.inkBlack
	local h = (props.Size :: UDim2).Y.Offset
	local iconProps = { Size = UDim2.fromOffset(h - 16, h - 16), LayoutOrder = 1, Parent = row }
	if not (pic and Dossier.art(pic, iconProps)) and glyph then
		Kit.glyph(glyph, Dossier.merge({ ImageColor3 = ink }, iconProps))
	end
	local text: TextLabel? = nil
	if label ~= "" then
		text = Dossier.stencil({ Name = "Label", Text = label, TextSize = 20, TextColor3 = ink, LayoutOrder = 2, Parent = row })
	end
	b.Parent = parent
	return b, text
end

-- Dims a plate that can't be used now. (It leaves Visible alone: the
-- confirm card hides the ✓ it doesn't use, and showing it again put the red
-- launch ✓ over every build's yellow one.)
local function setUsable(b: GuiButton, usable: boolean)
	b.Active = usable
	b.Interactable = usable
	for _, d in b:GetDescendants() do
		if d:IsA("TextLabel") then
			d.TextTransparency = if usable then 0 else 0.5
		elseif d:IsA("ImageLabel") then
			d.ImageTransparency = if usable then 0 else 0.5
		end
	end
	-- Greyed, so a plate you can't use never reads as ready.
	if b:IsA("ImageButton") then
		b.ImageColor3 = if usable then Color3.new(1, 1, 1) else Color3.fromRGB(150, 146, 138)
	elseif b:IsA("TextButton") then
		b.BackgroundTransparency = if usable then 0 else 0.45
	end
end

-- A pinned paper slip (mockup A), scaled up on desktop.
local function slip(self: any, name: string, w: number, h: number): ImageLabel
	local s = Dossier.surface("ImageLabel", "tex_paper", T.sheet, { Name = name, Size = UDim2.fromOffset(w, h), Visible = false, ZIndex = 6, Parent = self.parent })
	s.Active = true
	Kit.stroke(T.sheetLine, 1, 0.2).Parent = s
	Kit.new("UIScale", { Scale = if self.phone then 1 else 1.4, Parent = s })
	Dossier.art("pin", { Position = UDim2.new(0.5, -12, 0, -14), Size = UDim2.fromOffset(24, 30), ZIndex = 8, Parent = s })
	return s
end

-- The attack card and the confirm card (mockup A).
local CARD_W, CARD_H = 300, 150
local RELATION_INK = { NEUTRAL = T.stamp, ALLY = Color3.fromHex("#2E8A3E"), TEAM = Color3.fromHex("#2F5E9E") }
local CONFIRM_W, CONFIRM_H = 180, 112
-- Seconds between the clicks of a double-click attack.
local DOUBLE_CLICK = 0.35
-- Wide enough for "WARSHIP PATROLS HERE · 500K".
local CONFIRM_WIDE = 300
local LAUNCHES = { ["Atom Bomb"] = true, ["Hydrogen Bomb"] = true, MIRV = true, ["Mega Nuke"] = true, Scattershot = true, ["Air Strike"] = true, ["Railgun Shot"] = true, Paratroopers = true, Sabotage = true }
local WARSHIP_W, WARSHIP_H = 320, 132
local STATUS_INK = { PATROLLING = Color3.fromHex("#2F5E9E"), ["IN COMBAT"] = T.stamp, RETREATING = Color3.fromHex("#B07A0E"), REPAIRING = Color3.fromHex("#2E8A3E") }

-- How much a phone's side sheets enlarge their contents.
local SHEET_SCALE = 1.5

-- `slotsHost` is the HUD command bar's slot area.
function OfActions.new(state: any, parent: Frame, actions: Actions, slotsHost: Frame)
	local self = setmetatable({
		state = state,
		actions = actions,
		chosen = nil :: string?,
		rocketDirectionUp = true, -- UIState.rocketDirectionUp
		focus = nil :: number?, -- smallID in the player panel
		-- Game feel: running animations, ATTACK's folding copies, the tap
		-- rings' pool, and the cards' pop-in state.
		anims = {} :: { [RBXScriptConnection]: boolean },
		folds = {} :: { [Instance]: boolean },
		tapRings = {} :: { Frame },
		tapTokens = {} :: { [Instance]: {} },
		popTokens = {} :: { [Instance]: {} },
		popOffset = {} :: { [Instance]: Vector2 },
		panelSig = nil :: string?,
		panelBusy = false,
		panelReadOnly = false,
		prompts = HudModel.newPrompts(),
		connections = {} :: { any },
		itemButtons = {} :: { [string]: any },
		arsenalSlot = nil :: any, -- the ARSENAL slot and its fly-out
		arsenalFly = nil :: any, -- (desktop)
		arsenalBack = nil :: any, -- a phone's BACK slot in the swapped row
		arsenalOpen = false,
		attackCard = nil :: any, -- built below
		confirmCard = nil :: any,
		warshipCard = nil :: any,
		warshipId = nil :: number?,
		banner = nil :: any,
	}, OfActions)

	-- Build slots, in the HUD's command bar (UnitDisplay.ts): key number, icon,
	-- price (red when you can't afford it), count; a gap before the bombs; a
	-- tooltip with OpenFront's one-line description and why a slot is dim.
	self.parent = parent -- (ARSENAL's fly-out needs it already)
	local bar = slotsHost
	Kit.list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left).Parent = bar
	self.bar = bar
	self.phone = Kit.root ~= nil and Kit.root.compact == true -- (_buildSlots reads it)
	self:_buildSlots()
	-- The phone's build drawer closing takes ARSENAL's fly-out with it.
	table.insert(self.connections, bar:GetAttributeChangedSignal("drawerClosed"):Connect(function()
		self:_toggleArsenal(false)
	end))

	-- Alliance cards (bottom left, above the command bar) ------------------------------
	-- (On a phone, above the build drawer and Reinforce, so they never cover
	-- the slots.)
	local compact = Kit.root ~= nil and Kit.root.compact == true
	-- On a desktop, 10 above the command bar's real top, which OfHud keeps in
	-- the match frame's BarTop as the bar scales (a fixed -132 sat 11-20 into
	-- it, 2026-11-10 review).
	local function barCardsY(): number
		if compact then
			return -250
		end
		local barTop = parent:GetAttribute("BarTop")
		return -((if type(barTop) == "number" then barTop else 150) + 10)
	end
	local cardsY = barCardsY()
	self.cardsY = cardsY
	self.offerTimers = {} :: { { fill: Frame, prompt: any } }
	local cards = Kit.new("Frame", { Name = "AllianceCards", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, cardsY), Size = UDim2.fromOffset(if compact then 320 else 380, 400) })
	Kit.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom).Parent = cards
	cards.Parent = parent
	self.cards = cards
	if not compact then
		table.insert(self.connections, parent:GetAttributeChangedSignal("BarTop"):Connect(function()
			self.cardsY = barCardsY()
			self:_placeCards()
		end))
	end

	-- On a phone (Bruno, 2026-10-27) the player panel and the action sheet
	-- are full-height sheets at the right, half the screen wide, scrolling,
	-- their contents at SHEET_SCALE so the buttons are big enough to tap.
	local phone = Kit.root ~= nil and Kit.root.compact == true
	self.phone = phone
	local function sideSheet(name: string, z: number): any
		local s = Kit.scroll({ Name = name, BackgroundColor3 = T.sheet, BackgroundTransparency = 0, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 8), Size = UDim2.new(0.5 / SHEET_SCALE, 0, 1 / SHEET_SCALE, -16 / SHEET_SCALE), ScrollBarThickness = 6, ScrollBarImageColor3 = T.inkBlack, Visible = false, ZIndex = z, Parent = parent })
		s.Active = true
		Kit.stroke(T.sheetLine, 1.5, 0).Parent = s
		Kit.new("UIScale", { Scale = SHEET_SCALE, Parent = s })
		return s
	end

	-- Player panel (right side) -----------------------------------------------------------
	local sheet = if phone then sideSheet("PlayerPanel", 1) else panel({ Name = "PlayerPanel", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(380, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, Parent = parent })
	Kit.padding(12).Parent = sheet
	Kit.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top).Parent = sheet
	self.sheet = sheet

	-- The wheel (the radial menu), centred on the press (Bruno, 2026-10-28,
	-- mockup B, on every device). Its gaps let taps through to the map, which
	-- closes it.
	local menu = Kit.new("Frame", { Name = "Wheel", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(0, 0), Visible = false, ZIndex = 5, Parent = parent })
	Kit.new("UIScale", { Scale = if phone then 1 else 1.3, Parent = menu })
	self.menu = menu
	self.parent = parent

	-- Emoji / chat / player-picker sheet (centre) ----------------------------------------
	local picker = panel({ Name = "Picker", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(440, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, Parent = parent })
	Kit.padding(12).Parent = picker
	Kit.list(Enum.FillDirection.Vertical, 8).Parent = picker
	self.picker = picker

	-- The attack card and the build / launch confirmation (Bruno, 2026-10-28).
	self:_buildAttackCard()
	self:_buildWarshipCard()
	self:_buildConfirm()
	self:_buildBanner()
	self:_placeCards()

	-- Wiring -------------------------------------------------------------------------------
	self:_noteBoats(nil)
	table.insert(self.connections, state.StatsChanged:Connect(function()
		self:_refreshBar()
		if self.focus then
			self:_refreshPanelNumbers()
		end
		if self.attackCard.Visible then
			self:_showAttack()
		end
	end))
	table.insert(self.connections, state.UnitsChanged:Connect(function(changed)
		self:_refreshBar()
		if self.warshipId then
			self:_showWarship()
		end
		self:_noteBoats(changed)
	end))
	table.insert(self.connections, state.DiplomacyEvents:Connect(function(events)
		self.prompts:onEvents(state, events)
	end))
	table.insert(self.connections, state.TickApplied:Connect(function()
		self:_refreshCards()
		self:_tickPanel()
		self:_noteAttacks()
	end))
	table.insert(self.connections, state.Snapshot:Connect(function()
		-- What's already under way isn't news.
		self.attackTroops = nil
		self.seenBoats = nil
		self:_noteBoats(nil)
		self.prompts = HudModel.newPrompts()
		self:choose(nil)
		self:closeMenu()
		self:closePlayer()
		self:closeAttack()
		self:showWarship(nil)
		self:_buildSlots()
		self:_refreshBar()
	end))
	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, processed)
		self:_notePointer(input)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			if self.picker.Visible then
				self.picker.Visible = false
			elseif self.arsenalOpen then
				self:_toggleArsenal(false)
			elseif self.confirmCard.Visible then
				self:closeConfirm()
			elseif self.attackCard.Visible then
				self:closeAttack()
			elseif self.warshipCard.Visible then
				-- The map clears its selection on Escape too, which calls
				-- showWarship(nil).
				self:showWarship(nil)
			elseif self.menu.Visible then
				self:closeMenu()
			elseif self.chosen then
				self:choose(nil)
			else
				self:closePlayer()
			end
			return
		end
		if input.KeyCode == Enum.KeyCode.U then
			self:flipRocket()
			return
		end
		local index = table.find(KEYCODES, input.KeyCode)
		-- canUseBuildKeybinds: only while the bar is up (spawned, alive).
		-- "-" opens ARSENAL; while it's open, 1-9 pick from it.
		if index and self.bar.Visible then
			local base: { HudModel.BuildItem }, extra: { HudModel.BuildItem } = {}, {}
			for _, item in HudModel.buildItems(state) do
				table.insert(if item.arsenal then extra else base, item)
			end
			if index == 11 then
				self:_toggleArsenal()
			elseif self.arsenalOpen then
				if extra[index] then
					self:_pressItem(extra[index].type)
				end
			elseif base[index] then
				self:_pressItem(base[index].type)
			end
		end
	end))
	self:_refreshBar()
	return self
end

-- Which Arsenal weapons the viewer has, as a string: the slots are rebuilt
-- when it changes mid-match (an unlock bought in the match).
local function arsenalSig(state: any): string
	local weapons = state.arsenal and state.arsenal.weapons or {}
	local out = {}
	for _, e in ArsenalUnits.BUILD do
		if weapons[e.key] then
			table.insert(out, e.key)
		end
	end
	return table.concat(out, ",")
end

-- One build slot (UnitDisplay's): key, count, icon, price, tooltip.
function OfActions._slot(self: any, item: any, width: number, order: number, parent: Instance): any
	local state = self.state
	-- A dark key tile (the slot_tile art, else charcoal).
	local tileArt = A.slot_tile or ""
	local b = Kit.new("ImageButton", { Name = item.type, AutoButtonColor = false, BackgroundColor3 = Color3.fromHex("#23241C"), BackgroundTransparency = if tileArt ~= "" then 1 else 0, BorderSizePixel = 0, Image = tileArt, ScaleType = Enum.ScaleType.Stretch, Size = UDim2.fromOffset(width, 104), LayoutOrder = order, Parent = parent }) :: any
	Kit.corner(4).Parent = b
	local stroke = Kit.stroke(T.hazard, 3, 0)
	stroke.Enabled = false
	stroke.Parent = b
	Kit.label({ Name = "Key", Text = item.key, FontFace = Theme.font.stencil, TextSize = 17, TextColor3 = T.sheetLine, Position = UDim2.fromOffset(6, 3), Parent = b })
	Kit.label({ Name = "Count", Text = "", FontFace = Theme.font.stencil, TextSize = 17, TextColor3 = T.sheet, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 3), Parent = b })
	local iconProps = { Name = "Icon", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 24), Size = UDim2.fromOffset(50, 50), Parent = b }
	if Dossier.art(SLOT_ART[item.type] or "", iconProps) == nil then
		Kit.glyph(SLOT_ICON[item.type] or "build", Dossier.merge({ ImageColor3 = T.sheet }, iconProps))
	end
	Kit.label({ Name = "Cost", Text = "", FontFace = Theme.font.stencil, TextSize = 23, TextColor3 = T.hazard, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -3), Parent = b })
	b.Activated:Connect(function()
		Dossier.thud()
		self:_pressItem(item.type)
	end)
	b.MouseEnter:Connect(function()
		if Kit.covered(b) then
			return
		end
		b.ImageColor3 = Color3.fromRGB(255, 240, 200)
		b.BackgroundColor3 = Color3.fromHex("#33352A")
	end)
	b.MouseLeave:Connect(function()
		b.ImageColor3 = Color3.new(1, 1, 1)
		b.BackgroundColor3 = Color3.fromHex("#23241C")
	end)
	Kit.tip(b, function(card)
		for _, it in HudModel.buildItems(state) do
			if it.type == item.type then
				local info = HudModel.slotInfo(state, it)
				Kit.text({ Text = it.name, FontFace = Theme.font.uiHeavy, TextSize = 19, LayoutOrder = 1, Parent = card })
				if it.cost ~= math.huge then
					Kit.text({ Text = if it.cost == 0 then "Free" else `{Format.renderNumber(it.cost)} gold`, FontFace = Theme.font.uiBold, TextSize = 16, TextColor3 = C.star, LayoutOrder = 2, Parent = card })
				end
				Kit.text({ Text = info.desc, TextSize = 16, TextColor3 = C.fgSoft, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = card })
				if info.reason then
					Kit.text({ Text = info.reason, FontFace = Theme.font.uiBold, TextSize = 16, TextColor3 = C.red, LayoutOrder = 4, Parent = card })
				end
				Kit.text({ Text = `Key {it.key}`, TextSize = 14, TextColor3 = C.fgMuted, LayoutOrder = 5, Parent = card })
			end
		end
	end, {
		-- 2026-11-10 review (Bruno): a weapon's tip sits above the open fly-out,
		-- never over the weapons; the bar's own tips wait while it's open.
		skip = function(): boolean
			return parent.Name ~= "ArsenalFly" and self.arsenalOpen and self.arsenalFly ~= nil
		end,
		above = function(): GuiObject?
			return if parent.Name == "ArsenalFly" then parent :: GuiObject else nil
		end,
	})
	self.itemButtons[item.type] = b
	return b
end

-- The build slots for this match: OpenFront's ten, then one ARSENAL slot
-- when any Arsenal weapon is unlocked (Bruno, 2026-11-08: the bar would
-- otherwise grow to about twenty). ARSENAL ("-") opens a fly-out above it
-- with a slot per weapon, keyed 1-9 while it's open. Rebuilt on every
-- snapshot.
function OfActions._buildSlots(self: any)
	local state, bar = self.state, self.bar
	for _, b in self.itemButtons do
		b:Destroy()
	end
	self.itemButtons = {}
	if self.arsenalSlot then
		self.arsenalSlot:Destroy()
		if self.arsenalFly then
			self.arsenalFly:Destroy()
		end
		if self.arsenalBack then
			self.arsenalBack:Destroy()
		end
		self.arsenalSlot, self.arsenalFly, self.arsenalBack = nil, nil, nil
	end
	self.arsenalOpen = false
	if bar:FindFirstChild("Gap") == nil then
		Kit.new("Frame", { Name = "Gap", BackgroundTransparency = 1, Size = UDim2.fromOffset(6, 104), LayoutOrder = 15, Parent = bar })
	end
	local base: { HudModel.BuildItem }, extra: { HudModel.BuildItem } = {}, {}
	for _, item in HudModel.buildItems(state) do
		table.insert(if item.arsenal then extra else base, item)
	end
	self.arsenalSig = arsenalSig(state)
	-- Ten slots at 73; with ARSENAL, eleven at 66 so it never runs under SHOP.
	local width = if #extra == 0 then 73 else 66
	for i, item in base do
		self:_slot(item, width, i * 2, bar)
	end
	if #extra == 0 then
		return
	end

	local slot = Kit.new("ImageButton", { Name = "Arsenal", AutoButtonColor = false, BackgroundColor3 = Color3.fromHex("#4A3A12"), BorderSizePixel = 0, Size = UDim2.fromOffset(width, 104), LayoutOrder = 22, Parent = bar }) :: any
	-- The phone's build drawer stays open for the fly-out (OfHud).
	slot:SetAttribute("keepDrawer", true)
	Kit.corner(4).Parent = slot
	local stroke = Kit.stroke(T.hazard, 3, 0)
	stroke.Enabled = false
	stroke.Parent = slot
	Kit.label({ Name = "Key", Text = "-", FontFace = Theme.font.stencil, TextSize = 17, TextColor3 = T.sheetLine, Position = UDim2.fromOffset(6, 3), Parent = slot })
	Kit.label({ Name = "Count", Text = tostring(#extra), FontFace = Theme.font.stencil, TextSize = 17, TextColor3 = T.sheet, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 3), Parent = slot })
	Kit.glyph("shield", { Name = "Icon", ImageColor3 = T.hazard, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 24), Size = UDim2.fromOffset(46, 46), Parent = slot })
	Kit.label({ Name = "Cost", Text = "ARSENAL", FontFace = Theme.font.stencil, TextSize = 15, TextColor3 = T.hazard, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Parent = slot })
	Kit.tip(slot, function(card)
		Kit.text({ Text = "Arsenal", FontFace = Theme.font.uiHeavy, TextSize = 19, LayoutOrder = 1, Parent = card })
		Kit.text({ Text = "Your Arsenal weapons", TextSize = 16, TextColor3 = C.fgSoft, LayoutOrder = 2, Parent = card })
		Kit.text({ Text = "Key -", TextSize = 14, TextColor3 = C.fgMuted, LayoutOrder = 3, Parent = card })
	end, {
		skip = function(): boolean
			return self.arsenalOpen
		end,
	})

	slot.Activated:Connect(function()
		Dossier.thud()
		self:_toggleArsenal()
	end)
	self.arsenalSlot = slot

	-- On a phone (Bruno, 2026-11-10: the fly-out took too much of the screen)
	-- ARSENAL swaps the drawer's row instead: BACK and the weapons, in the
	-- same row and its width, so nothing new covers the map. _refreshBar
	-- shows one set or the other.
	if self.phone then
		local rowWidth = 11 * width + 6 + 11 * 4 -- ten slots, the gap, ARSENAL
		local w = math.min(width, math.floor((rowWidth - 4 * #extra) / (#extra + 1)))
		local back = Kit.new("ImageButton", { Name = "ArsenalBack", AutoButtonColor = false, BackgroundColor3 = Color3.fromHex("#4A3A12"), BorderSizePixel = 0, Size = UDim2.fromOffset(w, 104), LayoutOrder = 30, Visible = false, Parent = bar }) :: any
		back:SetAttribute("keepDrawer", true)
		Kit.corner(4).Parent = back
		Kit.glyph("chevronRight", { Name = "Icon", ImageColor3 = T.hazard, Rotation = 180, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 24), Size = UDim2.fromOffset(46, 46), Parent = back })
		Kit.label({ Name = "Cost", Text = "BACK", FontFace = Theme.font.stencil, TextSize = 15, TextColor3 = T.hazard, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Parent = back })
		back.Activated:Connect(function()
			Dossier.thud()
			self:_toggleArsenal(false)
		end)
		self.arsenalBack = back
		for i, item in extra do
			self:_slot(item, w, 30 + i, bar)
		end
		return
	end

	-- The fly-out: a dark rail of slots above ARSENAL, four to a row,
	-- growing upwards and leftwards from the slot's right edge. It lives on
	-- the HUD's top layer (the bar's neighbours would cover it) and is placed
	-- and sized to the slot each time it opens (_toggleArsenal).
	local cols = math.min(#extra, 4)
	local rows = math.ceil(#extra / 4)
	local fly = Kit.new("Frame", { Name = "ArsenalFly", BackgroundColor3 = Color3.fromHex("#1A1B15"), BorderSizePixel = 0, AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(cols * 73 + (cols - 1) * 4 + 16, rows * 104 + (rows - 1) * 4 + 16), Visible = false, ZIndex = 8, Parent = self.parent })
	Kit.corner(6).Parent = fly
	Kit.stroke(T.hazard, 2, 0.2).Parent = fly
	Kit.padding(8, 8).Parent = fly
	Kit.new("UIGridLayout", { CellSize = UDim2.fromOffset(73, 104), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = fly })
	Kit.new("UIScale", { Name = "Fit", Parent = fly })
	for i, item in extra do
		self:_slot(item, 73, i, fly)
	end
	self.arsenalFly = fly
end

-- Opens or closes the Arsenal: the fly-out, or on a phone the swapped row.
function OfActions._toggleArsenal(self: any, open: boolean?)
	if self.arsenalSlot == nil then
		return
	end
	local want = if open == nil then not self.arsenalOpen else open
	if want == self.arsenalOpen then
		return
	end
	self.arsenalOpen = want
	local fly = self.arsenalFly
	if fly == nil then
		self:_refreshBar()
		return
	end
	fly.Visible = want
	if want then
		-- ARSENAL's tip stood where the weapons open (Bruno, 2026-11-10).
		Kit.hideTip()
		-- Over the slot, at the slot's own scale (the phone drawer has its own).
		local slot = self.arsenalSlot
		local x, y, s = self:_toParent(slot.AbsolutePosition + Vector2.new(slot.AbsoluteSize.X, 0))
		local fit = slot.AbsoluteSize.Y / 104 / s
		fly.Position = UDim2.fromOffset(x + 8 * fit, y - 12 * fit)
		local scale = fly:FindFirstChild("Fit") :: UIScale
		self:_animate(function(elapsed: number): boolean
			local k = math.clamp(elapsed / 0.12, 0, 1)
			scale.Scale = fit * (0.85 + 0.15 * (1 - (1 - k) ^ 3))
			return k >= 1
		end)
	end
end

-- Build bar ----------------------------------------------------------------------------

function OfActions.choose(self: any, unitType: string?)
	local changed = self.chosen ~= unitType
	self.chosen = unitType
	if changed then
		self:closeConfirm()
		if unitType then
			self:closeAttack()
		end
		self:_refreshBanner()
	end
	for t, b in self.itemButtons do
		local stroke = b:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Enabled = t == unitType
		end
	end
	if self.arsenalSlot then
		local stroke = self.arsenalSlot:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Enabled = unitType ~= nil and ArsenalUnits.KEY[unitType] ~= nil
		end
		if unitType ~= nil and self.arsenalOpen then
			self:_toggleArsenal(false)
			-- The phone's build drawer closes on this, as on a slot pick (OfHud).
			self.bar:SetAttribute("arsenalPicked", os.clock())
		end
	end
	if changed and self.actions.buildChosen then
		self.actions.buildChosen(unitType)
	end
end

-- SwapRocketDirectionEvent: U or the toggle in your own panel.
function OfActions.flipRocket(self: any)
	self.rocketDirectionUp = not self.rocketDirectionUp
	if self.actions.rocketDirectionChanged then
		self.actions.rocketDirectionChanged(self.rocketDirectionUp)
	end
	if self.focus ~= nil and self.focus == self.state.you then
		task.spawn(self.openPlayer, self, self.focus)
	end
end

-- A map tap: closes an open action sheet (as a click outside the radial
-- menu does). With a type chosen it asks to confirm the build or launch at
-- that tile (Bruno, 2026-10-28: ✓ ✕; a later tap moves it). Otherwise, with
-- "Select before attacking" on, another player's land opens the attack
-- card; while the card is open any other tap closes it. True if it was used.
function OfActions.onMapTap(self: any, tile: number): boolean
	if self.menu.Visible then
		self:closeMenu()
		return true
	end
	local chosen = self.chosen
	if chosen ~= nil then
		self:_askBuild(chosen, tile)
		return true
	end
	local wantsCard = self:_cardTile(tile)
	-- A double-click with the mouse on the same nation attacks at once
	-- (Bruno, 2026-10-29): by sea on their ocean coast, by land elsewhere,
	-- as the card's main button chooses for the second click's tile.
	local now = os.clock()
	local owner = self.state:ownerAt(tile)
	local double = wantsCard and self.pointerKind == Enum.UserInputType.MouseButton1 and self.lastCardTap ~= nil and now - self.lastCardTap.at <= DOUBLE_CLICK and self.lastCardTap.owner == owner
	self.lastCardTap = if wantsCard and not double then { at = now, owner = owner } else nil
	if double then
		self:openAttackCard(tile, true)
		return true
	end
	if self.attackCard.Visible then
		if wantsCard then
			self:openAttackCard(tile)
		else
			self:closeAttack()
		end
		return true
	end
	if wantsCard then
		self:openAttackCard(tile)
		return true
	end
	return false
end

-- Whether a tap on `tile` opens the attack card.
function OfActions._cardTile(self: any, tile: number): boolean
	local state = self.state
	local on = self.actions.selectBeforeAttack == nil or self.actions.selectBeforeAttack()
	if not on or state:inSpawnPhase() then
		return false
	end
	local me = state:me()
	local owner = state:ownerAt(tile)
	return me ~= nil and me.alive and owner ~= 0 and owner ~= state.you and state.players[owner] ~= nil
end

-- The press point of the last map tap, in input space (MapInput hands over
-- only the tile; the confirm card sits beside the point).
function OfActions._notePointer(self: any, input: InputObject)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		self.pointer = Vector2.new(input.Position.X, input.Position.Y)
		self.pointerKind = t
	end
end

-- Attack card (Bruno, 2026-10-28; mockup A) --------------------------------------------

function OfActions._buildAttackCard(self: any)
	local card = slip(self, "AttackCard", CARD_W, CARD_H)
	card.AnchorPoint = Vector2.new(0, 1)
	self.attackCard = card
	self.attackSwatch = Kit.new("Frame", { BackgroundColor3 = T.sheetLine, BorderSizePixel = 0, Position = UDim2.fromOffset(14, 14), Size = UDim2.fromOffset(12, 12), Parent = card })
	Kit.stroke(T.inkBlack, 1, 0.4).Parent = self.attackSwatch
	self.attackName = Dossier.stencil({ Text = "", TextSize = 24, AutomaticSize = Enum.AutomaticSize.None, Position = UDim2.fromOffset(32, 6), Size = UDim2.fromOffset(150, 28), TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	local stamp = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -44, 0, 9), Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Rotation = -5, Parent = card })
	Kit.padding(0, 6).Parent = stamp
	self.attackStampLine = Kit.stroke(T.stamp, 2.5, 0.05)
	self.attackStampLine.Parent = stamp
	self.attackStamp = Dossier.stencil({ Text = "", TextSize = 16, TextColor3 = T.stamp, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, Parent = stamp })
	local close = Kit.new("TextButton", { Name = "Close", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 4), Size = UDim2.fromOffset(32, 32), Parent = card })
	Kit.glyph("close", { ImageColor3 = T.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(18, 18), Parent = close })
	close.Activated:Connect(function()
		Dossier.click()
		self:closeAttack()
	end)
	self.attackInfo = Dossier.typed({ Text = "", TextSize = 15, Position = UDim2.fromOffset(14, 42), Parent = card })
	self.attackMain, self.attackMainLabel = plate(card, "yellow", nil, "sword", "ATTACK", { Name = "Main", Position = UDim2.fromOffset(12, 80), Size = UDim2.fromOffset(176, 50) })
	self.attackMainIcon = (self.attackMain:FindFirstChild("Row") :: Frame):FindFirstChildWhichIsA("ImageLabel")
	self.attackAlly, self.attackAllyLabel = plate(card, "pale", nil, "alliance", "ALLY", { Name = "Ally", Position = UDim2.fromOffset(196, 80), Size = UDim2.fromOffset(92, 50) })
	self.attackMain.Activated:Connect(function()
		self:_pressAttack("main")
	end)
	self.attackAlly.Activated:Connect(function()
		self:_pressAttack("ally")
	end)
end

-- Opens (or retargets) the card for the player owning `tile`; `press` also
-- presses its main button once the server's answer is in (a double-click).
function OfActions.openAttackCard(self: any, tile: number, press: boolean?)
	local query = self.actions.queryTile
	if query == nil then
		return
	end
	self:closeMenu()
	if self.warshipId then
		if self.actions.deselectWarship then
			self.actions.deselectWarship()
		end
		self:showWarship(nil)
	end
	local token = {}
	self.attackToken = token
	self.attackTile = tile
	task.spawn(function()
		local acts = query(tile)
		if self.attackToken ~= token then
			return
		end
		local ratio = if self.actions.ratio then self.actions.ratio() else 0.2
		local card = if acts then HudModel.attackCard(self.state, tile, acts, ratio) else nil
		if card == nil then
			self:closeAttack()
			return
		end
		local opening = not self.attackCard.Visible
		if opening and not press then
			cue(self, "ui.card")
		end
		self.attackData = card
		self:_showAttack()
		if opening and not press then
			self:_popCard(self.attackCard, function()
				self:_placeCards()
			end)
		end
		if press then
			self:_pressAttack("main")
		end
	end)
end

function OfActions.closeAttack(self: any)
	self.attackToken = nil
	self.attackData = nil
	self.attackCard.Visible = false
	self:_placeCards()
end

-- The card's text from attackData, the amount at the current attack ratio.
function OfActions._showAttack(self: any)
	local card = self.attackData
	if card == nil then
		return
	end
	local state = self.state
	local other = state.players[card.other]
	if other == nil or not other.alive then
		self:closeAttack()
		return
	end
	self.attackName.Text = string.upper(card.name)
	local color = if self.actions.playerColor then self.actions.playerColor(card.other) else nil
	self.attackSwatch.BackgroundColor3 = color or T.sheetLine
	self.attackStamp.Text = card.relation
	self.attackStamp.TextColor3 = RELATION_INK[card.relation] or T.stamp
	self.attackStampLine.Color = self.attackStamp.TextColor3
	local total = if state.landTotal > 0 then state.landTotal else 1
	self.attackInfo.Text = `{card.kind} · {Format.renderTroops(other.troops)} troops · {string.format("%.2f", 100 * other.tiles / total)}% land`
	local me = state:me()
	local ratio = if self.actions.ratio then self.actions.ratio() else 0.2
	local amount = ratio * (if me then me.troops else 0)
	local main = card.main
	local word = if main.id == "send" then "SEND" elseif card.boat then "INVADE" else "ATTACK"
	local mainLabel: TextLabel = self.attackMainLabel
	mainLabel.Text = `{word} · {Format.renderTroops(amount)}`
	if self.attackMainIcon then
		Kit.setGlyph(self.attackMainIcon, if main.id == "send" then "troops" elseif card.boat then "boat" else "sword")
	end
	setUsable(self.attackMain, main.enabled)
	local ally = card.ally
	self.attackAlly.Visible = ally ~= nil
	if ally then
		local allyLabel: TextLabel = self.attackAllyLabel
		allyLabel.Text = if ally.id == "ally_break" then "BREAK" else "ALLY"
		setUsable(self.attackAlly, ally.enabled)
	end
	self.attackCard.Visible = true
	self:_placeCards()
end

-- Main: attack / invade / send troops with the troops at the ratio now;
-- either button closes the card (Bruno: the card closes after Attack).
function OfActions._pressAttack(self: any, which: string)
	local card = self.attackData
	if card == nil then
		return
	end
	local item = if which == "main" then card.main else card.ally
	if item and item.enabled and item.intent then
		local intent = table.clone(item.intent)
		if which == "main" then
			local me = self.state:me()
			local ratio = if self.actions.ratio then self.actions.ratio() else 0.2
			local amount = ratio * (if me then me.troops else 0)
			intent.troops = if intent.type == "donate_troops" then math.floor(amount) else amount
		end
		self.actions.sendIntent(intent)
		if which == "main" then
			-- The stamp, then the card folds toward the target (Bruno, 2026-11-08).
			cue(self, "ui.confirm")
			self:_foldCard(self.attackTile)
		end
	end
	self:closeAttack()
end

-- Warship card (Bruno, 2026-10-28, feature 13) -----------------------------------------
-- A tap on your warship selects it on the map, which shows its patrol
-- circle and calls showWarship; the next tap on the sea moves it.

-- Bruno's pick (2026-10-29): a recon photo clipped to the paper, the stats
-- typed beside it, the status stamped across the photo's corner and
-- veterancy as stars.
function OfActions._buildWarshipCard(self: any)
	local card = slip(self, "WarshipCard", WARSHIP_W, WARSHIP_H)
	card.AnchorPoint = Vector2.new(0, 1)
	self.warshipCard = card
	-- The print: a white border round the photo, a little askew.
	local frame = Kit.new("Frame", { Name = "Photo", BackgroundColor3 = Color3.fromHex("#F2EDE1"), BorderSizePixel = 0, Position = UDim2.fromOffset(14, 22), Size = UDim2.fromOffset(122, 88), Rotation = -3, ZIndex = 6, Parent = card })
	Kit.stroke(T.sheetLine, 1, 0.3).Parent = frame
	-- The warship silhouette on a dark print (Bruno, 2026-10-29: nicer than
	-- the recon photo, which stays uploaded but unused).
	local dark = Kit.new("Frame", { Name = "Print", BackgroundColor3 = Color3.fromHex("#3B4146"), BorderSizePixel = 0, Position = UDim2.fromOffset(5, 5), Size = UDim2.new(1, -10, 1, -10), ZIndex = 6, Parent = frame })
	Dossier.art("bld_warship", { ImageColor3 = Color3.fromHex("#E8DFC8"), Position = UDim2.fromScale(0.08, 0.1), Size = UDim2.fromScale(0.84, 0.8), ZIndex = 6, Parent = dark })
	Dossier.age(dark)
	Dossier.art("paperclip", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(30, 22), Size = UDim2.fromOffset(12, 42), Rotation = 8, ZIndex = 8, Parent = card })
	local stamp = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(104, 100), Size = UDim2.fromOffset(0, 24), AutomaticSize = Enum.AutomaticSize.X, Rotation = -12, ZIndex = 8, Parent = card })
	Kit.padding(0, 6).Parent = stamp
	self.warshipStampLine = Kit.stroke(T.stamp, 2.5, 0.05)
	self.warshipStampLine.Parent = stamp
	self.warshipStamp = Dossier.stencil({ Text = "", TextSize = 16, TextColor3 = T.stamp, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 8, Parent = stamp })
	-- The typed column beside the photo.
	local x = 152
	self.warshipSwatch = Kit.new("Frame", { BackgroundColor3 = T.sheetLine, BorderSizePixel = 0, Position = UDim2.fromOffset(x, 16), Size = UDim2.fromOffset(12, 12), Parent = card })
	Kit.stroke(T.inkBlack, 1, 0.4).Parent = self.warshipSwatch
	Dossier.stencil({ Text = "WARSHIP", TextSize = 22, AutomaticSize = Enum.AutomaticSize.None, Position = UDim2.fromOffset(x + 18, 8), Size = UDim2.fromOffset(110, 26), Parent = card })
	self.warshipHealth = Dossier.typed({ Text = "", TextSize = 14, TextColor3 = T.inkBlack, Position = UDim2.fromOffset(x, 40), Parent = card })
	local bar = Kit.new("Frame", { Name = "Health", BackgroundColor3 = T.sheetLine, BackgroundTransparency = 0.6, BorderSizePixel = 0, Position = UDim2.fromOffset(x, 60), Size = UDim2.fromOffset(WARSHIP_W - x - 16, 8), Parent = card })
	Kit.stroke(T.inkBlack, 1, 0.5).Parent = bar
	self.warshipFill = Kit.new("Frame", { BackgroundColor3 = Color3.fromHex("#2E8A3E"), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = bar })
	local stars = Kit.new("Frame", { Name = "Veterancy", BackgroundTransparency = 1, Position = UDim2.fromOffset(x - 2, 74), Size = UDim2.fromOffset(120, 22), Parent = card })
	Kit.list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = stars
	self.warshipStars = stars
	Dossier.typed({ Text = "Tap the sea to move it", TextSize = 12, TextColor3 = T.inkFaded, AutomaticSize = Enum.AutomaticSize.None, TextWrapped = true, Position = UDim2.fromOffset(x, 98), Size = UDim2.fromOffset(WARSHIP_W - x - 12, 30), Parent = card })
	local close = Kit.new("TextButton", { Name = "Close", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -6, 0, 4), Size = UDim2.fromOffset(32, 32), Parent = card })
	Kit.glyph("close", { ImageColor3 = T.inkBlack, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(18, 18), Parent = close })
	close.Activated:Connect(function()
		Dossier.click()
		if self.actions.deselectWarship then
			self.actions.deselectWarship()
		end
		self:showWarship(nil)
	end)
end

-- Shows the card for your warship `unitId` (the map selected it), or hides
-- it (nil: the selection ended).
function OfActions.showWarship(self: any, unitId: number?)
	self.warshipId = unitId
	if unitId ~= nil then
		self:closeAttack()
		self:closeMenu()
	end
	self:_showWarship()
end

function OfActions._showWarship(self: any)
	local card = if self.warshipId then HudModel.warshipCard(self.state, self.warshipId) else nil
	if card == nil then
		self.warshipId = nil
		self.warshipCard.Visible = false
		self:_placeCards()
		return
	end
	local color = if self.actions.playerColor then self.actions.playerColor(self.state.you) else nil
	self.warshipSwatch.BackgroundColor3 = color or T.sheetLine
	self.warshipStamp.Text = card.status
	self.warshipStamp.TextColor3 = STATUS_INK[card.status] or T.stamp
	self.warshipStampLine.Color = self.warshipStamp.TextColor3
	local share = if card.maxHealth > 0 then math.clamp(card.health / card.maxHealth, 0, 1) else 0
	self.warshipFill.Size = UDim2.fromScale(share, 1)
	self.warshipFill.BackgroundColor3 = if share > 0.75 then Color3.fromHex("#2E8A3E") elseif share > 0.4 then Color3.fromHex("#B07A0E") else T.stamp
	self.warshipHealth.Text = `Hull {Format.renderNumber(card.health)} / {Format.renderNumber(card.maxHealth)}`
	-- Gold stars earned, faded ones still to earn.
	if self.warshipStarsShown ~= `{card.veterancy}/{card.maxVeterancy}` then
		self.warshipStarsShown = `{card.veterancy}/{card.maxVeterancy}`
		clear(self.warshipStars)
		for i = 1, card.maxVeterancy do
			local earned = i <= card.veterancy
			Kit.glyph("star", { ImageColor3 = if earned then C.star else T.inkFaded, ImageTransparency = if earned then 0 else 0.65, Size = UDim2.fromOffset(20, 20), LayoutOrder = i, Parent = self.warshipStars })
		end
	end
	self.warshipCard.Visible = true
	self:_placeCards()
end

-- The attack and warship cards sit at the bottom left, just above the
-- phone's stats bar (RoWorld's place, Bruno 2026-10-28) or the desktop
-- command bar. On a phone the alliance cards move up above whichever shows;
-- on a desktop they always stand where they would be above them, so Accept
-- and Reject never jump from under the cursor (Bruno, 2026-11-10).
function OfActions._placeCards(self: any)
	local cardY = if self.phone then -96 else self.cardsY
	local k = if self.phone then 1 else 1.4
	local top = if self.phone then self.cardsY else cardY - math.max(CARD_H, WARSHIP_H) * k - 22
	for _, entry in { { self.attackCard, CARD_H }, { self.warshipCard, WARSHIP_H } } do
		local card, h = entry[1], entry[2]
		if card then
			local off = self.popOffset[card] or Vector2.zero
			card.Position = UDim2.new(0, 16 + off.X, 1, cardY + off.Y)
			if card.Visible and self.phone then
				top = math.min(top, cardY - h * k - 22)
			end
		end
	end
	self.cards.Position = UDim2.new(0, 16, 1, top)
end

-- What's left of an offer, 1 to 0: a request until it lapses, a renewal
-- until the alliance ends.
function OfActions._offerLeft(self: any, p: any): number
	local state = self.state
	local config = state:config()
	if p.kind == "request" then
		local span = config:allianceRequestDuration()
		return if span > 0 then math.clamp(1 - (state.tick - p.createdAt) / span, 0, 1) else 0
	end
	local span = config:allianceExtensionPromptOffset()
	for _, a in state.diplomacy.alliances do
		if a.id == p.allianceID and span > 0 then
			return math.clamp((a.expiresAt - state.tick) / span, 0, 1)
		end
	end
	return 0
end

-- Build / launch confirmation (Bruno, 2026-10-28; mockup A) ----------------------------

function OfActions._buildConfirm(self: any)
	local card = slip(self, "ConfirmCard", CONFIRM_W, CONFIRM_H)
	self.confirmCard = card
	self.confirmTitle = Dossier.stencil({ Text = "", TextSize = 20, AutomaticSize = Enum.AutomaticSize.None, Position = UDim2.fromOffset(6, 4), Size = UDim2.new(1, -12, 0, 32), TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Parent = card })
	-- ✕ and ✓ stay centred when the card widens for a long title.
	local no = plate(card, "pale", nil, "close", "", { Name = "Cancel", Position = UDim2.new(0.5, -78, 0, 42), Size = UDim2.fromOffset(72, 58) })
	-- ✕ cancels the build altogether (Bruno, 2026-10-28): choose again to build.
	no.Activated:Connect(function()
		cue(self, "ui.cancel")
		self:closeConfirm()
		self:choose(nil)
	end)
	self.confirmYes = plate(card, "yellow", nil, "check", "", { Name = "Confirm", Position = UDim2.new(0.5, 6, 0, 42), Size = UDim2.fromOffset(72, 58) })
	self.confirmLaunch = plate(card, "red", nil, "check", "", { Name = "Launch", Position = UDim2.new(0.5, 6, 0, 42), Size = UDim2.fromOffset(72, 58) })
	for _, b in { self.confirmYes, self.confirmLaunch } do
		b.Activated:Connect(function()
			self:_confirmBuild()
		end)
	end
end

-- A tap with a type chosen: the card beside the tap, for that tile.
function OfActions._askBuild(self: any, unitType: string, tile: number)
	local name, cost = unitType, nil
	for _, item in HudModel.buildItems(self.state) do
		if item.type == unitType then
			name, cost = item.name, item.cost
		end
	end
	local launch = LAUNCHES[unitType] == true
	local warship = unitType == "Warship"
	-- Paratroopers say what they carry: "DROP 12.5K · 250K" (ARSENAL_V2).
	local para = unitType == "Paratroopers"
	local paraTroops = if para then self:_paraTroops(nil) else 0
	-- "WARSHIP PATROLS HERE · 500K" (Bruno, feature 13) needs the wide card.
	self.confirmCard.Size = UDim2.fromOffset(if warship or para then CONFIRM_WIDE else CONFIRM_W, CONFIRM_H)
	local function title(upgrade: boolean, price: number?)
		-- (The Arsenal's strikes are free: their structure was the price.)
		local tail = if price == 0 then " · free" elseif price and price ~= math.huge then ` · {Format.renderNumber(price)}` else ""
		self.confirmTitle.Text = string.upper(if para then `Drop {Format.renderTroops(paraTroops)}{tail}` elseif launch then `Launch {name}{tail}` elseif upgrade then `Upgrade {name}{tail}` elseif warship then `{name} patrols here{tail}` else `{name}{tail}`)
	end
	title(false, cost)
	self.confirmYes.Visible = not launch
	self.confirmLaunch.Visible = launch
	setUsable(self.confirmYes, true)
	setUsable(self.confirmLaunch, true)
	local token = {}
	self.confirmFor = { unit = unitType, tile = tile, token = token }
	-- The server decides build or upgrade (Runner._buildAction): ask, then
	-- retitle "UPGRADE CITY · 250K" (Bruno, 2026-10-28), or grey ✓ out where
	-- nothing can be built.
	local query = self.actions.queryBuild
	if query then
		task.spawn(function()
			local reply = query(tile, unitType)
			local f = self.confirmFor
			if f == nil or f.token ~= token or reply == nil or reply.buildable == nil then
				return
			end
			local bu = reply.buildable
			if bu.canUpgrade ~= false and not launch then
				title(true, if bu.upgradeCosts then bu.upgradeCosts[1] or bu.cost else bu.cost)
			end
			if para and reply.paraAim then
				paraTroops = self:_paraTroops(reply.paraAim.troops)
				title(false, cost)
			end
			local able = bu.canUpgrade ~= false or bu.canBuild ~= false
			setUsable(self.confirmYes, able)
			setUsable(self.confirmLaunch, able)
		end)
	end
	local opening = not self.confirmCard.Visible
	if opening then
		cue(self, "ui.card")
	end
	self.confirmCard.Visible = true
	if opening then
		self:_popCard(self.confirmCard, function()
			self:_placeConfirm()
		end)
	end
	-- The map holds its ghost, range and aim on this tile until ✓ or ✕
	-- (Codex's pending placement), and the card follows the tile.
	if self.actions.buildPending then
		self.actions.buildPending(tile)
	end
	if self.confirmCamera == nil and self.actions.onCameraChanged then
		self.confirmCamera = self.actions.onCameraChanged(function()
			self:_placeConfirm()
		end)
	end
	self:_placeConfirm()
end

-- Beside the tile (or the press point without a map hook): right of it, else
-- left, below or above, whichever first keeps off your own name and troops
-- (2026-11-11 review U6: it covered them when building near the capital),
-- between the top rail and the bottom bar.
function OfActions._placeConfirm(self: any)
	local f, card, parent = self.confirmFor, self.confirmCard, self.parent
	if f == nil then
		return
	end
	local gui = parent:FindFirstAncestorOfClass("ScreenGui")
	local uiScale = if gui then gui:FindFirstChildOfClass("UIScale") else nil
	local s = if uiScale then uiScale.Scale else 1
	local k = if self.phone then 1 else 1.4
	local w, h = parent.AbsoluteSize.X / s, parent.AbsoluteSize.Y / s
	local cw, ch = card.Size.X.Offset * k, CONFIRM_H * k
	local at = if self.actions.tileToScreen then self.actions.tileToScreen(f.tile) else nil
	at = at or self.pointer
	local x, y = w / 2, h / 2
	if at then
		x, y = (at.X - parent.AbsolutePosition.X) / s, (at.Y - parent.AbsolutePosition.Y) / s
	end
	local top, bottom = 8, h - 8
	local rail, bar = parent:GetAttribute("RailBottom"), parent:GetAttribute("BarTop")
	if type(rail) == "number" then
		top = math.max(top, rail + 8)
	end
	if type(bar) == "number" then
		-- (BarTop is the bottom bar's reach up from the bottom edge.)
		bottom = math.min(bottom, h - bar - 8)
	end
	local function fit(cx: number, cy: number): (number, number)
		return math.clamp(cx, 8, math.max(8, w - cw - 8)), math.clamp(cy, top, math.max(top, bottom - ch))
	end
	-- Your name's anchor rect, before the map moved it off this card (the
	-- card is a label occluder: the drawn rect would chase it).
	local name: ScreenRect? = nil
	if self.actions.nameScreenRect and self.state.you then
		local r = self.actions.nameScreenRect(self.state.you, true)
		if r then
			name = { x = (r.x - parent.AbsolutePosition.X) / s, y = (r.y - parent.AbsolutePosition.Y) / s, w = r.w / s, h = r.h / s }
		end
	end
	local candidates = {
		{ x + 28, y - ch / 2 },
		{ x - 28 - cw, y - ch / 2 },
		{ x - cw / 2, y + 28 },
		{ x - cw / 2, y - 28 - ch },
	}
	local bestX, bestY, bestCost = nil :: number?, nil :: number?, math.huge
	for i, c in candidates do
		local cx, cy = fit(c[1], c[2])
		local cost = 0
		-- (Pushed back over the tile by an edge: not beside it any more.)
		if overlaps(cx, cy, cw, ch, { x = x - 6, y = y - 6, w = 12, h = 12 }) then
			cost += 1e6
		end
		if name then
			local r = name :: ScreenRect
			local ox = math.max(0, math.min(cx + cw, r.x + r.w) - math.max(cx, r.x))
			local oy = math.max(0, math.min(cy + ch, r.y + r.h) - math.max(cy, r.y))
			cost += ox * oy
		end
		cost += i -- ties keep the order above
		if cost < bestCost then
			bestX, bestY, bestCost = cx, cy, cost
		end
	end
	local off = self.popOffset[card] or Vector2.zero
	card.Position = UDim2.fromOffset((bestX :: number) + off.X, (bestY :: number) + off.Y)
end

function OfActions.closeConfirm(self: any)
	local had = self.confirmFor ~= nil
	self.confirmFor = nil
	self.confirmCard.Visible = false
	if self.confirmCamera then
		self.confirmCamera()
		self.confirmCamera = nil
	end
	if had and self.actions.buildPending then
		self.actions.buildPending(nil)
	end
end

-- What a Paratroopers drop would carry now: the attack-ratio share of our
-- troops, at most `cap` (the server's paraAim.troops) when known.
function OfActions._paraTroops(self: any, cap: number?): number
	local me = self.state:me()
	local ratio = if self.actions.ratio then self.actions.ratio() else 0.2
	local amount = ratio * (if me then me.troops else 0)
	return if cap then math.min(amount, cap) else amount
end

-- ✓: build or launch there, then leave build mode (Bruno: no repeated
-- launches; the source keeps bombs chosen).
function OfActions._confirmBuild(self: any)
	local f = self.confirmFor
	if f then
		cue(self, "ui.confirm")
		-- Paratroopers carry the attack-ratio share, like a boat (the server caps it).
		local troops = if f.unit == "Paratroopers" then math.floor(self:_paraTroops(nil)) else nil
		self.actions.sendIntent({ type = "build_action", unit = f.unit, tile = f.tile, rocketDirectionUp = self.rocketDirectionUp, troops = troops })
	end
	self:closeConfirm()
	self:choose(nil)
end

-- Game feel (Bruno, 2026-11-08: "Let's do all of them";
-- docs/design/NINTENDO_FEEL_RESEARCH.md) -------------------------------------------------
-- Presentation only: a tap answers at once, cards and toasts pop in from
-- their centre with a small overshoot, and ATTACK stamps the card and folds
-- it toward the target. Timings are starting points for Bruno's eye.

-- Pop-in: from POP_FROM past POP_OVER, settling at 1, over POP_SECONDS.
POP_FROM, POP_OVER, POP_SECONDS = 0.85, 1.08, 0.15
-- The tap ring: contracts onto the tile, then fades.
local TAP_IN, TAP_OUT, TAP_FROM, TAP_TO = 0.07, 0.13, 1.8, 0.85
local TAP_RINGS = 3
-- ATTACK: the copy holds a beat (the stamp), then folds toward the target.
local FOLD_HOLD, FOLD_SECONDS, FOLD_TO = 0.06, 0.15, 0.15

local function easeOut(x: number): number
	local c = math.clamp(x, 0, 1)
	return 1 - (1 - c) * (1 - c)
end

-- The pop-in's scale at `p` (0..1 of POP_SECONDS).
function popScale(p: number): number
	if p >= 1 then
		return 1
	elseif p < 0.4 then
		return POP_FROM + (POP_OVER - POP_FROM) * easeOut(p / 0.4)
	end
	return POP_OVER + (1 - POP_OVER) * easeOut((p - 0.4) / 0.6)
end

-- Runs `step(elapsed)` every frame until it returns true; destroy stops it.
function OfActions._animate(self: any, step: (number) -> boolean)
	local started = os.clock()
	local anims = self.anims
	local conn: RBXScriptConnection
	conn = game:GetService("RunService").RenderStepped:Connect(function()
		if step(os.clock() - started) then
			conn:Disconnect()
			anims[conn] = nil
		end
	end)
	anims[conn] = true
end

-- Parent-space units for a screen point (the HUD has its own UIScale), and
-- that scale.
function OfActions._toParent(self: any, at: Vector2): (number, number, number)
	local parent = self.parent
	local gui = parent:FindFirstAncestorOfClass("ScreenGui")
	local uiScale = if gui then gui:FindFirstChildOfClass("UIScale") else nil
	local s = if uiScale then uiScale.Scale else 1
	return (at.X - parent.AbsolutePosition.X) / s, (at.Y - parent.AbsolutePosition.Y) / s, s
end

-- The moment a tap orders an expansion or attack: a ring that contracts onto
-- the tile and fades, before the server answers. It says "heard", not
-- "done" (the server reports only failures).
function OfActions.markTap(self: any, tile: number)
	local toScreen = self.actions.tileToScreen
	if toScreen == nil then
		return
	end
	local rings = self.tapRings
	local ring: Frame
	if #rings >= TAP_RINGS then
		ring = table.remove(rings, 1) :: any
	else
		ring = Kit.new("Frame", { Name = "TapRing", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(28, 28), ZIndex = 3, Visible = false, Parent = self.parent })
		ring:SetAttribute("MapInk", true) -- (not a panel the map's labels avoid)
		Kit.corner(14).Parent = ring
		Kit.stroke(T.sheet, 3, 0).Parent = ring
		local rim = Kit.new("Frame", { Name = "Rim", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 6, 1, 6), Parent = ring })
		Kit.corner(17).Parent = rim
		Kit.stroke(T.inkBlack, 1.5, 0.3).Parent = rim
		Kit.new("UIScale", { Parent = ring })
	end
	table.insert(rings, ring)
	local token = {}
	self.tapTokens[ring] = token
	local scale = ring:FindFirstChildOfClass("UIScale") :: UIScale
	local stroke = ring:FindFirstChildOfClass("UIStroke") :: UIStroke
	local rimStroke = (ring:FindFirstChild("Rim") :: Frame):FindFirstChildOfClass("UIStroke") :: UIStroke
	self:_animate(function(e: number): boolean
		if self.tapTokens[ring] ~= token or ring.Parent == nil then
			return true
		end
		local at = toScreen(tile)
		if at == nil or e >= TAP_IN + TAP_OUT then
			ring.Visible = false
			return true
		end
		local x, y = self:_toParent(at)
		ring.Position = UDim2.fromOffset(x, y)
		ring.Visible = true
		local fade = 0
		if e < TAP_IN then
			scale.Scale = TAP_FROM + (1 - TAP_FROM) * easeOut(e / TAP_IN)
		else
			local p = (e - TAP_IN) / TAP_OUT
			scale.Scale = 1 + (TAP_TO - 1) * p
			fade = p
		end
		stroke.Transparency = fade
		rimStroke.Transparency = 0.3 + 0.7 * fade
		return false
	end)
end

-- Pops a card in from its centre: `place` positions it each frame with
-- self.popOffset[card] added, so the centre stays put while it grows.
function OfActions._popCard(self: any, card: GuiObject, place: () -> ())
	local cardScale = card:FindFirstChildOfClass("UIScale") :: UIScale
	local k = if self.phone then 1 else 1.4
	local token = {}
	self.popTokens[card] = token
	self:_animate(function(e: number): boolean
		if self.popTokens[card] ~= token or card.Parent == nil then
			return true
		end
		local m = popScale(e / POP_SECONDS)
		local a, size = card.AnchorPoint, card.Size
		local w, h = size.X.Offset * k, size.Y.Offset * k
		self.popOffset[card] = Vector2.new(w * (1 - m) * (0.5 - a.X), h * (1 - m) * (0.5 - a.Y))
		cardScale.Scale = k * m
		place()
		if m == 1 then
			self.popOffset[card] = nil
			self.popTokens[card] = nil
			return true
		end
		return false
	end)
end

-- ATTACK pressed: a copy of the card holds a beat, then shrinks toward the
-- target tile; the real card closes at once and is free to reopen.
function OfActions._foldCard(self: any, tile: number?)
	local card = self.attackCard
	local k = if self.phone then 1 else 1.4
	local w, h = card.Size.X.Offset * k, card.Size.Y.Offset * k
	local a = card.AnchorPoint
	local pos = card.Position
	local parent = self.parent
	local _, _, s = self:_toParent(parent.AbsolutePosition)
	local pw, ph = parent.AbsoluteSize.X / s, parent.AbsoluteSize.Y / s
	local cx = pos.X.Scale * pw + pos.X.Offset + w * (0.5 - a.X)
	local cy = pos.Y.Scale * ph + pos.Y.Offset + h * (0.5 - a.Y)
	local ghost = card:Clone()
	ghost.Name = "AttackFold"
	ghost:SetAttribute("MapInk", true)
	ghost.Active = false
	for _, d in ghost:GetDescendants() do
		if d:IsA("GuiButton") then
			d.Interactable = false
		end
	end
	ghost.AnchorPoint = Vector2.new(0.5, 0.5)
	ghost.Position = UDim2.fromOffset(cx, cy)
	ghost.Parent = parent
	local scale = ghost:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = k
	local tx, ty = cx, cy
	local toScreen = self.actions.tileToScreen
	if tile and toScreen then
		local at = toScreen(tile)
		if at then
			tx, ty = self:_toParent(at)
		end
	end
	self.folds[ghost] = true
	self:_animate(function(e: number): boolean
		if ghost.Parent == nil then
			return true
		end
		local p = (e - FOLD_HOLD) / FOLD_SECONDS
		if p >= 1 then
			self.folds[ghost] = nil
			ghost:Destroy()
			return true
		end
		if p > 0 then
			local q = p * p -- ease in: it lifts off, then speeds away
			ghost.Position = UDim2.fromOffset(cx + (tx - cx) * q, cy + (ty - cy) * q)
			scale.Scale = k * (1 + (FOLD_TO - 1) * q)
		end
		return false
	end)
end

-- Toasts on the map (Bruno, 2026-10-28, feature 3, after RoWorld) ---------------------
-- "Expanding with N" under your name, "Attacking X with N" on theirs, "Boat to
-- X with N" at the landing, "Missile launched" at the target: map-label ink
-- that rises and fades over TOAST_SECONDS, following the map as it moves.

local TOAST_SECONDS = 2
local MAX_TOASTS = 4

-- `anchor` gives the screen point (pixels) each frame, nil while hidden.
-- `avoid` gives map names (screen pixels) the toast must not cover: it moves
-- off them, below for a toast under its anchor (dy > 0), else above
-- (2026-11-11 review M2/M3: "Expanding with" over your troops, "Icelar"). It
-- hides while it would cross a HUD panel, as the map's labels do.
function OfActions._toast(self: any, text: string, anchor: () -> Vector2?, dy: number, avoid: (() -> { ScreenRect })?)
	cue(self, "ui.toast")
	local parent = self.parent
	self.toasts = self.toasts or {}
	if #self.toasts >= MAX_TOASTS then
		local oldest = table.remove(self.toasts, 1)
		oldest.stop()
	end
	local label = Dossier.stencil({ Name = "Toast", Text = text, TextSize = if self.phone then 22 else 30, TextColor3 = T.sheet, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 4, Visible = false, Parent = parent })
	-- (Map ink, not a panel: the map's labels mustn't move away from it.)
	label:SetAttribute("MapInk", true)
	-- Pops in from its centre before the rise (Bruno, 2026-11-08).
	local pop = Kit.new("UIScale", { Scale = POP_FROM, Parent = label })
	-- Ink round the letters, as the map's labels (not a box).
	local outline = Kit.stroke(T.inkBlack, 2, 0)
	outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	outline.Parent = label
	local started = os.clock()
	local entry: any = {}
	local conn: RBXScriptConnection
	local function stop()
		if conn then
			conn:Disconnect()
		end
		label:Destroy()
		local i = table.find(self.toasts, entry)
		if i then
			table.remove(self.toasts, i)
		end
	end
	entry.stop = stop
	table.insert(self.toasts, entry)
	conn = game:GetService("RunService").RenderStepped:Connect(function()
		local elapsed = os.clock() - started
		local t = elapsed / TOAST_SECONDS
		pop.Scale = popScale(elapsed / POP_SECONDS)
		if t >= 1 or label.Parent == nil then
			stop()
			return
		end
		local at = anchor()
		if at == nil then
			label.Visible = false
			return
		end
		local gui = parent:FindFirstAncestorOfClass("ScreenGui")
		local uiScale = if gui then gui:FindFirstChildOfClass("UIScale") else nil
		local s = if uiScale then uiScale.Scale else 1
		-- Rises 24 units; fades over the last half. Worked in screen pixels.
		local cx, cy = at.X, at.Y + (dy - 24 * t) * s
		local size = label.AbsoluteSize / math.max(pop.Scale, 0.01)
		local hw, hh = size.X / 2, size.Y / 2
		if avoid then
			local rects = avoid()
			-- Twice, for a name pushed onto by moving off another.
			for _ = 1, 2 do
				for _, r in rects do
					if overlaps(cx - hw, cy - hh, hw * 2, hh * 2, r) then
						cy = if dy > 0 then r.y + r.h + hh + 2 * s else r.y - hh - 2 * s
					end
				end
			end
		end
		local covered = false
		if self.actions.hudRects then
			for _, r in self.actions.hudRects() do
				if overlaps(cx - hw, cy - hh, hw * 2, hh * 2, r) then
					covered = true
					break
				end
			end
		end
		label.Visible = not covered
		label.Position = UDim2.fromOffset((cx - parent.AbsolutePosition.X) / s, (cy - parent.AbsolutePosition.Y) / s)
		local fade = math.clamp((t - 0.5) * 2, 0, 1)
		label.TextTransparency = fade
		;(label:FindFirstChildOfClass("UIStroke") :: UIStroke).Transparency = fade
	end)
end

function OfActions._noteAttacks(self: any)
	local state = self.state
	local news
	news, self.attackTroops = HudModel.sendToasts(state, self.attackTroops)
	for _, n in news do
		local who = if n.target == 0 or state.players[n.target] == nil then state.you else n.target
		local below = who == state.you
		self:_toast(n.text, function(): Vector2?
			return if self.actions.nameScreenPosition then self.actions.nameScreenPosition(who) else nil
		end, if below then 34 else -30, self:_namesToAvoid({ who }))
	end
end

-- The drawn names of these players, for a toast to keep off.
function OfActions._namesToAvoid(self: any, ids: { number }): () -> { ScreenRect }
	return function(): { ScreenRect }
		local rects = {}
		local lookup = self.actions.nameScreenRect
		if lookup then
			for _, id in ids do
				local r = lookup(id)
				if r then
					table.insert(rects, r)
				end
			end
		end
		return rects
	end
end

-- A new boat of yours: "Boat to X with N" at its landing. A new bomb of
-- yours: "Missile launched" at its target (Bruno, feature 10), once the
-- server has launched it.
function OfActions._noteBoats(self: any, changed: { any }?)
	local state = self.state
	-- The units there already (a snapshot, a rebuilt HUD) aren't news.
	if self.seenBoats == nil then
		self.seenBoats = {}
		for id in state.units do
			self.seenBoats[id] = true
		end
	end
	local list: { any } = changed or {}
	for _, u in list do
		local launch = LAUNCHES[u.type] == true
		if (u.type == "Transport" or launch) and u.owner == state.you and u.active ~= false and not self.seenBoats[u.id] then
			self.seenBoats[u.id] = true
			local dst = u.targetTile
			-- (The name of whoever holds the target, which a toast there would cover.)
			local held = if dst then state:ownerAt(dst) else 0
			local avoid = if held ~= 0 then self:_namesToAvoid({ held }) else nil
			if launch and dst then
				-- (The Arsenal's strikes say what they are.)
				self:_toast(if u.type == "Air Strike" then "Air Strike inbound" elseif u.type == "Railgun Shot" then "Railgun fired" elseif u.type == "Paratroopers" then `Paratroopers away with {Format.renderTroops(u.troops or 0)}` elseif u.type == "Sabotage" then "Fuse lit" else "Missile launched", function(): Vector2?
					return if self.actions.tileToScreen then self.actions.tileToScreen(dst) else nil
				end, -30, avoid)
			elseif dst then
				local owner = state:ownerAt(dst)
				local who = if owner ~= 0 and owner ~= state.you then state.players[owner] else nil
				local troops = Format.renderTroops(u.troops or 0)
				self:_toast(if who then `Boat to {who.displayName} with {troops}` else `Boat landing with {troops}`, function(): Vector2?
					return if self.actions.tileToScreen then self.actions.tileToScreen(dst) else nil
				end, -26, avoid)
			end
		end
	end
end

-- Build-mode banner (Bruno, 2026-10-28, after RoWorld): what to tap while a
-- type is chosen, and Cancel.
function OfActions._buildBanner(self: any)
	local b = Dossier.surface("ImageLabel", "tex_paper", T.sheet, { Name = "BuildBanner", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, if self.phone then 100 else 140), Size = UDim2.fromOffset(0, 50), AutomaticSize = Enum.AutomaticSize.X, Visible = false, ZIndex = 6, Parent = self.parent })
	-- A desktop's sits 12 under the top rail's real bottom (OfHud's RailBottom),
	-- which grows with the HUD; a fixed 140 nearly touched it (2026-11-10 review).
	if not self.phone then
		local parent = self.parent
		local function place()
			local rail = parent:GetAttribute("RailBottom")
			if type(rail) == "number" then
				b.Position = UDim2.new(0.5, 0, 0, rail + 12)
			end
		end
		place()
		table.insert(self.connections, parent:GetAttributeChangedSignal("RailBottom"):Connect(place))
	end
	b.Active = true
	Kit.stroke(T.sheetLine, 1, 0.2).Parent = b
	Kit.new("UIScale", { Scale = if self.phone then 1 else 1.4, Parent = b })
	Kit.padding(0, 12).Parent = b
	Kit.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent = b
	Kit.glyph("target", { ImageColor3 = T.stamp, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, Parent = b })
	self.bannerText = Dossier.typed({ Text = "", TextSize = 16, TextColor3 = T.inkBlack, LayoutOrder = 2, Parent = b })
	local cancel = plate(b, "pale", nil, "close", "CANCEL", { Name = "Cancel", Size = UDim2.fromOffset(118, 38), LayoutOrder = 3 })
	cancel.Activated:Connect(function()
		self:choose(nil)
	end)
	self.banner = b
end

function OfActions._refreshBanner(self: any)
	local chosen = self.chosen
	self.banner.Visible = chosen ~= nil
	if chosen == nil then
		return
	end
	local name = chosen
	for _, item in HudModel.buildItems(self.state) do
		if item.type == chosen then
			name = item.name
		end
	end
	self.bannerText.Text = if LAUNCHES[chosen] then `Tap a target, then ✓ to launch the {name}`
		elseif chosen == "Warship" then "Tap water near your port, then ✓"
		else `Tap your land, then ✓ to build the {name}`
end

-- UnitDisplay's click: a chosen item always deselects; another one selects
-- only if it can be used now.
function OfActions._pressItem(self: any, unitType: string)
	if self.chosen == unitType then
		self:choose(nil)
		return
	end
	for _, item in HudModel.buildItems(self.state) do
		if item.type == unitType and item.enabled then
			self:choose(unitType)
		end
	end
end

function OfActions._refreshBar(self: any)
	local state = self.state
	if not state.ready then
		return
	end
	-- UnitDisplay renders nothing in the spawn phase or when you're dead.
	local me = state:me()
	local show = me ~= nil and me.alive and not state:inSpawnPhase()
	self.bar.Visible = show
	if not show and self.chosen ~= nil then
		self:choose(nil)
	end
	if not show then
		self:_toggleArsenal(false)
	end
	if not show and self.menu.Visible then
		self:closeMenu() -- the radial menu is for the living
	end
	if not show and self.attackCard.Visible then
		self:closeAttack()
	end
	if arsenalSig(state) ~= self.arsenalSig then
		self:_buildSlots()
	end
	local config = state:config()
	-- A phone's drawer row shows the buildings or, after ARSENAL, the weapons.
	local swapped = self.arsenalBack ~= nil
	if swapped then
		self.arsenalBack.Visible = self.arsenalOpen
		self.arsenalSlot.Visible = not self.arsenalOpen
		local gap = self.bar:FindFirstChild("Gap")
		if gap then
			(gap :: Frame).Visible = not self.arsenalOpen
		end
	end
	for _, item in HudModel.buildItems(state) do
		local b = self.itemButtons[item.type]
		if b then
			-- Disabled unit types are left out, as the source does.
			b.Visible = not config:isUnitDisabled(item.type) and (not swapped or (item.arsenal == true) == self.arsenalOpen);
			(b:FindFirstChild("Cost") :: TextLabel).Text = if item.cost == math.huge then "" elseif item.cost == 0 then "FREE" else Format.renderNumber(item.cost);
			(b:FindFirstChild("Count") :: TextLabel).Text = if item.count > 0 and not UNCOUNTED[item.type] then tostring(item.count) else ""
			-- Stay clickable so a chosen item can always be deselected; dim
			-- when it can't be used, the price red when you can't afford it.
			b.Active = true
			local cost = b:FindFirstChild("Cost") :: TextLabel
			cost.TextColor3 = if item.cost > state.gold then Color3.fromHex("#F0574A") else T.hazard
			local icon = b:FindFirstChild("Icon") :: ImageLabel
			icon.ImageTransparency = if item.enabled then 0 else 0.55
			b.ImageTransparency = if item.enabled then 0 else 0.25
		end
	end
end

-- Alliance cards -----------------------------------------------------------------------

-- An alliance request or renewal on a phone (Bruno, 2026-10-27): one small
-- strip, the other nation's name, then yes and no.
function OfActions._cardStrip(self: any, p: any, order: number)
	local state = self.state
	local other = state.players[p.other]
	local name = if other then other.displayName else "?"
	local strip = panel({ Size = UDim2.new(1, 0, 0, 36), LayoutOrder = order, Parent = self.cards })
	Kit.stroke(C.gold, 2, 0).Parent = strip
	-- Shrinks to fit before truncating ("West Antarctica wants an…", 2026-10-28 video).
	local line = text({ Text = if p.kind == "request" then `{name} wants an alliance` else `Renew alliance: {name}?`, TextSize = 13, TextScaled = true, TextTruncate = Enum.TextTruncate.AtEnd, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.new(1, -96, 1, 0), Parent = strip })
	Kit.new("UITextSizeConstraint", { MaxTextSize = 13, MinTextSize = 9, Parent = line })
	local function choice(kind: string, glyph: string, x: number, fn: () -> ())
		local b = button(kind, { Text = "", Size = UDim2.fromOffset(38, 28), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0), Parent = strip })
		Kit.glyph(glyph, { ImageColor3 = if kind == "primary" then T.inkBlack else T.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(16, 16), Parent = b })
		local function choose()
			fn()
			self.prompts:dismiss(p)
			self.cardsSig = nil
		end
		b.Activated:Connect(choose)
		-- Bigger tap areas, meeting between ✓ and ✕, inside the strip (audit F12).
		Dossier.hitPad(b, choose, 42, 40)
	end
	choice("primary", "check", -46, function()
		if other then
			self.actions.sendIntent(if p.kind == "request" then { type = "allianceRequest", recipient = other.id } else { type = "allianceExtension", recipient = other.id })
		end
	end)
	choice("dark", "close", -4, function()
		if other and p.kind == "request" then
			self.actions.sendIntent({ type = "allianceReject", requestor = other.id })
		end
	end)
end

function OfActions._refreshCards(self: any)
	local state = self.state
	local list = self.prompts:tick(state)
	local signature = {}
	for _, p in list do
		table.insert(signature, `{p.kind}{p.other}{p.createdAt}`)
	end
	local sig = table.concat(signature, ",")
	if sig == self.cardsSig then
		for _, t in self.offerTimers do
			t.fill.Size = UDim2.fromScale(self:_offerLeft(t.prompt), 1)
		end
		return
	end
	self.cardsSig = sig
	clear(self.cards)
	self.offerTimers = {}
	for i, p in list do
		if self.phone then
			self:_cardStrip(p, i)
			continue
		end
		local card = panel({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i, Parent = self.cards })
		Kit.padding(10).Parent = card
		Kit.list(Enum.FillDirection.Vertical, 8).Parent = card
		Kit.stroke(C.gold, 2, 0).Parent = card
		text({ Text = p.text, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card })
		-- Time left on the offer (2026-11-10 review: offers stayed up with no hint
		-- of how long).
		local track = Kit.new("Frame", { Name = "Timer", BackgroundColor3 = T.sheetLine, BackgroundTransparency = 0.6, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 4), LayoutOrder = 3, Parent = card })
		local fill = Kit.new("Frame", { BackgroundColor3 = C.gold, BorderSizePixel = 0, Size = UDim2.fromScale(self:_offerLeft(p), 1), Parent = track })
		table.insert(self.offerTimers, { fill = fill, prompt = p })
		local row = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.size.touch), LayoutOrder = 2 })
		Kit.list(Enum.FillDirection.Horizontal, 6).Parent = row
		row.Parent = card
		local other = state.players[p.other]
		if p.kind == "request" then
			local accept = button("primary", { Text = Lang.t("events_display.accept_alliance"), Size = UDim2.fromOffset(150, Theme.size.touch), LayoutOrder = 1, Parent = row })
			accept.Activated:Connect(function()
				if other then
					self.actions.sendIntent({ type = "allianceRequest", recipient = other.id })
				end
				self.prompts:dismiss(p)
				self.cardsSig = nil
			end)
			local reject = button("dark", { Text = Lang.t("events_display.reject_alliance"), Size = UDim2.fromOffset(150, Theme.size.touch), LayoutOrder = 2, Parent = row })
			reject.Activated:Connect(function()
				if other then
					self.actions.sendIntent({ type = "allianceReject", requestor = other.id })
				end
				self.prompts:dismiss(p)
				self.cardsSig = nil
			end)
		else
			local renew = button("primary", { Text = Lang.t("events_display.renew_alliance"), Size = UDim2.fromOffset(170, Theme.size.touch), LayoutOrder = 1, Parent = row })
			renew.Activated:Connect(function()
				if other then
					self.actions.sendIntent({ type = "allianceExtension", recipient = other.id })
				end
				self.prompts:dismiss(p)
				self.cardsSig = nil
			end)
			local ignore = button("dark", { Text = Lang.t("events_display.ignore"), Size = UDim2.fromOffset(130, Theme.size.touch), LayoutOrder = 2, Parent = row })
			ignore.Activated:Connect(function()
				self.prompts:dismiss(p)
				self.cardsSig = nil
			end)
		end
	end
end

-- Player panel -------------------------------------------------------------------------

function OfActions.closePlayer(self: any)
	self.focus = nil
	self.panelSig = nil
	self.sheet.Visible = false
	self.picker.Visible = false
end

function OfActions._refreshPanelNumbers(self: any)
	local p = self.state.players[self.focus]
	if p == nil or self.numbers == nil then
		return
	end
	if self.expiryLabel and self.expiresAt then
		local seconds = math.max(0, math.floor((self.expiresAt - self.state.tick) / 10))
		self.expiryLabel.Text = `{Lang.t("player_panel.alliance_time_remaining")} {seconds}s`
	end
	self.numbers.Text = `{Lang.t("player_panel.troops")} {Format.renderTroops(p.troops)}   ·   {Lang.t("player_panel.gold")} {Format.renderNumber(p.gold)}   ·   {Lang.t("player_panel.betrayals")} {p.betrayals or 0}`
	local tick = self.state.tick
	if self.traitorLabel then
		local left = if p.traitorUntil then math.max(0, math.ceil((p.traitorUntil - tick) / 10)) else 0
		self.traitorLabel.Text = if left > 0 then `{Lang.t("player_panel.traitor")}  {left}s` else Lang.t("player_panel.traitor")
	end
	if self.alliesLabel then
		local rows = {}
		for i, id in p.allies do
			local ally = self.state.players[id]
			local expires = (p.allyExpiry or {})[i]
			table.insert(rows, { name = if ally then ally.displayName else "?", left = if expires then math.max(0, (expires - tick) // 10) else math.huge })
		end
		-- Soonest-expiring first, then by name.
		table.sort(rows, function(a, b)
			if a.left ~= b.left then
				return a.left < b.left
			end
			return a.name < b.name
		end)
		local parts = {}
		for _, r in rows do
			table.insert(parts, if r.left == math.huge then r.name else `{r.name} {r.left}s`)
		end
		self.alliesLabel.Text = `{Lang.t("player_panel.alliances")}: {table.concat(parts, ", ")}`
	end
end

-- What the panel's buttons depend on: rebuild only when it changes.
local function panelSignature(state: any, smallID: number, acts: { [string]: any }?): string
	local can = (acts and acts.interaction) or {}
	local p = state.players[smallID]
	local info = can.allianceInfo
	local parts = { tostring(acts ~= nil), tostring(acts and acts.canEmbargoAll), tostring(acts and acts.canSendEmojiAllPlayers) }
	for _, k in { "canBreakAlliance", "canSendAllianceRequest", "canTarget", "canEmbargo", "canSendEmoji", "canSendQuickChat", "canDonateTroops", "canDonateGold" } do
		table.insert(parts, tostring(can[k]))
	end
	table.insert(parts, if info then `{info.expiresAt}` else "-")
	table.insert(parts, if p then `{p.traitor}{p.disconnected}{#p.allies}` else "?")
	local me = state:me()
	table.insert(parts, if me then tostring(table.find(me.embargoes, smallID) ~= nil) else "-")
	return table.concat(parts, "|")
end

-- Opens (or refreshes) the panel for a player; asks the server what we may
-- do. `readOnly` (spectators) shows it with nothing enabled, as the
-- source's emptyPlayerActions.
function OfActions.openPlayer(self: any, smallID: number, readOnly: boolean?)
	local state = self.state
	if state.players[smallID] == nil then
		return
	end
	cue(self, "ui.sheet")
	self.focus = smallID
	self.panelReadOnly = readOnly == true
	local acts = if readOnly then {} else self.actions.queryActions(smallID)
	if self.focus ~= smallID then
		return -- closed or changed while waiting
	end
	self:_buildPanel(smallID, acts)
end

-- PlayerPanel.tick: while the panel is open and you are alive, refresh what
-- you may do (one question in flight at a time).
function OfActions._tickPanel(self: any)
	local focus = self.focus
	if focus == nil or self.panelBusy or self.panelReadOnly then
		return
	end
	local me = self.state:me()
	if me == nil or not me.alive then
		return
	end
	self.panelBusy = true
	task.spawn(function()
		local acts = self.actions.queryActions(focus)
		self.panelBusy = false
		if self.focus == focus and acts ~= nil and panelSignature(self.state, focus, acts) ~= self.panelSig then
			self:_buildPanel(focus, acts)
		end
	end)
end

function OfActions._buildPanel(self: any, smallID: number, acts: { [string]: any }?)
	local state = self.state
	local p = state.players[smallID]
	if p == nil then
		return
	end
	self.panelSig = panelSignature(state, smallID, acts)
	local can = (acts and acts.interaction) or {}
	local sheet = self.sheet
	clear(sheet)
	sheet.Visible = true

	local header = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1 })
	header.Parent = sheet
	text({ Text = p.displayName, FontFace = Theme.font.display, TextSize = 22, Size = UDim2.new(1, -80, 1, 0), AutomaticSize = Enum.AutomaticSize.None, TextTruncate = Enum.TextTruncate.AtEnd, Parent = header })
	if self.actions.goToPlayer then
		-- The source's name click: fly the camera to them.
		local go = button("dark", { Text = "Go", TextSize = 14, Size = UDim2.fromOffset(38, 30), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -40, 0, 0), Parent = header })
		local function goTo()
			self.actions.goToPlayer(smallID)
		end
		go.Activated:Connect(goTo)
		Dossier.hitPad(go, goTo, 44, nil)
	end
	local close = button("dark", { Text = "X", Size = UDim2.fromOffset(34, 30), AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Parent = header })
	local function closePanel()
		self:closePlayer()
	end
	close.Activated:Connect(closePanel)
	Dossier.hitPad(close, closePanel, 40, nil)
	self.numbers = text({ Text = "", TextSize = 15, TextColor3 = C.creamSoft, LayoutOrder = 2, Parent = sheet })
	self:_refreshPanelNumbers()

	-- Relation tags.
	local tags = {}
	if HudModel.isFriendly(state, state.you, smallID) then
		table.insert(tags, Lang.t("relation.friendly"))
	end
	if table.find(p.embargoes, state.you) then
		-- other.hasEmbargoAgainst(me), as PlayerPanel shows it.
		table.insert(tags, `{Lang.t("player_panel.trading")}: {Lang.t("player_panel.stopped")}`)
	end
	if p.disconnected then
		table.insert(tags, "AFK")
	end
	if #tags > 0 then
		text({ Text = table.concat(tags, "  ·  "), TextSize = 14, TextColor3 = C.gold, LayoutOrder = 3, Parent = sheet })
	end
	-- Traitor badge with its countdown, and this player's alliances with
	-- their remaining time (PlayerPanel's renderTraitorBadge and
	-- renderAlliances), both refreshed every tick.
	self.traitorLabel = if p.traitor then text({ Text = "", TextSize = 14, TextColor3 = C.coral, LayoutOrder = 3, Parent = sheet }) else nil
	self.alliesLabel = if #p.allies > 0 then text({ Text = "", TextSize = 14, TextColor3 = C.creamSoft, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 5, Parent = sheet }) else nil
	-- A nation's relation toward you (playerProfile), asked once.
	if p.type == "NATION" and self.actions.queryProfile and not self.panelReadOnly then
		local relationLabel = text({ Text = "", TextSize = 14, TextColor3 = C.creamSoft, LayoutOrder = 3, Parent = sheet })
		local query = self.actions.queryProfile
		task.spawn(function()
			local profile = query(smallID)
			local names = { [0] = "hostile", [1] = "distrustful", [2] = "neutral", [3] = "friendly" }
			if profile and names[profile.relation] and relationLabel.Parent then
				relationLabel.Text = `{Lang.t("relation." .. names[profile.relation])}`
			end
		end)
	end
	-- Alliance expiry, counted down each tick by _refreshPanelNumbers.
	local info = can.allianceInfo
	self.expiresAt = if info then info.expiresAt else nil
	self.expiryLabel = if info then text({ Text = "", TextSize = 14, TextColor3 = C.creamSoft, LayoutOrder = 4, Parent = sheet }) else nil
	self:_refreshPanelNumbers()

	local order = 10
	local function action(label: string, enabled: boolean, kind: any, fn: () -> ())
		order += 1
		local b = button(kind, { Text = label, Size = UDim2.new(1, 0, 0, Theme.size.touch), LayoutOrder = order, Parent = sheet })
		Kit.setEnabled(b, enabled)
		b.Activated:Connect(function()
			if b.Active then
				fn()
			end
		end)
	end
	local send = self.actions.sendIntent
	-- PlayerPanel hides itself after these actions.
	local function sendAndClose(intent: { [string]: any })
		send(intent)
		self:closePlayer()
	end
	if smallID == state.you then
		-- Your own panel: the rocket arc, emoji to everyone, and trading with
		-- enemies on or off (embargo_all).
		local arc = Lang.t(if self.rocketDirectionUp then "player_panel.arc_up" else "player_panel.arc_down")
		action(`{Lang.t("player_panel.flip_rocket_trajectory")} ({arc})`, not self.panelReadOnly, "dark", function()
			self:flipRocket()
		end)
		action(Lang.t("player_panel.emotes"), acts ~= nil and acts.canSendEmojiAllPlayers == true, "dark", function()
			self:_showEmoji("AllPlayers")
		end)
		action(Lang.t("player_panel.stop_trade_enemies"), acts ~= nil and acts.canEmbargoAll == true, "dark", function()
			send({ type = "embargo_all", action = "start" })
		end)
		action(Lang.t("player_panel.start_trade_enemies"), acts ~= nil and acts.canEmbargoAll == true, "dark", function()
			send({ type = "embargo_all", action = "stop" })
		end)
		return
	end
	if can.canBreakAlliance then
		action(Lang.t("player_panel.break_alliance"), true, "danger", function()
			sendAndClose({ type = "breakAlliance", recipient = p.id })
		end)
	else
		action(Lang.t("player_panel.send_alliance"), can.canSendAllianceRequest == true, "primary", function()
			sendAndClose({ type = "allianceRequest", recipient = p.id })
		end)
	end
	action(Lang.t("player_panel.target"), can.canTarget == true, "dark", function()
		sendAndClose({ type = "targetPlayer", target = p.id })
	end)
	if can.canEmbargo == false then
		action(Lang.t("player_panel.start_trade"), true, "dark", function()
			sendAndClose({ type = "embargo", targetID = p.id, action = "stop" })
		end)
	else
		action(Lang.t("player_panel.stop_trade"), can.canEmbargo == true, "dark", function()
			sendAndClose({ type = "embargo", targetID = p.id, action = "start" })
		end)
	end
	action(Lang.t("player_panel.emotes"), can.canSendEmoji == true, "dark", function()
		self:_showEmoji(p.id)
	end)
	action(Lang.t("player_panel.chat"), can.canSendQuickChat == true, "dark", function()
		self:_showChat(p.id)
	end)
	action(Lang.t("player_panel.send_troops"), can.canDonateTroops == true, "dark", function()
		sendAndClose({ type = "donate_troops", recipient = p.id, troops = nil })
	end)
	action(Lang.t("player_panel.send_gold"), can.canDonateGold == true, "dark", function()
		sendAndClose({ type = "donate_gold", recipient = p.id, gold = nil })
	end)
end

-- Action sheet (MainRadialMenu) -----------------------------------------------------------

function OfActions.closeMenu(self: any)
	if self.menu.Visible then
		cue(self, "ui.wheelClose")
	end
	self.menuToken = nil
	self.menu.Visible = false
	clear(self.menu)
end

-- Right-click / long-press on `tile` at a screen point (input space).
function OfActions.openContext(self: any, tile: number, screenX: number, screenY: number)
	local state = self.state
	self:closeMenu()
	self:closeAttack()
	local me = state:me()
	if me == nil or not me.alive then
		-- Spectators (dead, not spawned): the read-only player panel.
		local owner = state:ownerAt(tile)
		if owner ~= 0 and owner ~= state.you then
			self:openPlayer(owner, true)
		end
		return
	end
	local query = self.actions.queryTile
	if query == nil then
		return
	end
	local token = {}
	self.menuToken = token
	task.spawn(function()
		local acts = query(tile)
		if self.menuToken ~= token or acts == nil then
			return
		end
		local ratio = if self.actions.ratio then self.actions.ratio() else 0.2
		local menu = HudModel.contextMenu(state, tile, acts, ratio, self.rocketDirectionUp)
		local wheel = HudModel.wheel(state, menu)
		self.menuAt = Vector2.new(screenX, screenY)
		self:_showMenu(menu, { { title = wheel.title, items = wheel.items } })
	end)
end

-- A sub-list of the radial menu (build, weapons, bulk amounts) as wheel tiles.
local function subTiles(items: { any }): { any }
	local out = {}
	for _, m in items do
		local unit = string.match(m.id, "^%a+_(.+)$")
		local bulk = string.match(m.id, "^upgrade_")
		table.insert(out, {
			id = m.id,
			label = m.label,
			glyph = if bulk then "plus" else SLOT_ICON[unit or ""] or "build",
			enabled = m.enabled,
			intent = m.intent,
			sub = m.sub,
			cost = m.cost,
		})
	end
	return out
end

-- OpenFront's infoEmojiElement: More (the whole table), then the first 8.
local function emojiTiles(recipient: string): { any }
	local out: { any } = { { id = "emoji_more", label = "More", glyph = "emoji", enabled = true, more = recipient } }
	for i = 0, 7 do
		table.insert(out, { id = `emoji_{i}`, label = "", emoji = Emoji.flat[i], enabled = true, intent = { type = "emoji", recipient = recipient, emoji = i } })
	end
	return out
end

local WHEEL_TILE = 78
local WHEEL_GAP = 8

-- Draws the top of `stack` as a ring of riveted tiles round a red centre
-- (mockup B): the root, then the build / weapons / emoji ring, then bulk
-- amounts. The centre closes the root and steps back from a deeper ring.
function OfActions._showMenu(self: any, menu: any, stack: { { title: string?, items: { any } } })
	local wheel = self.menu
	cue(self, if not wheel.Visible then "ui.wheelOpen" else "ui.ring")
	clear(wheel)
	local level = stack[#stack]
	local root = #stack == 1
	local send = self.actions.sendIntent
	local items = level.items
	-- The ring grows so its tiles never touch.
	local radius = math.max(104, #items * (WHEEL_TILE + WHEEL_GAP) / (2 * math.pi))
	local size = 2 * radius + WHEEL_TILE
	wheel.Size = UDim2.fromOffset(size, size)

	local function back()
		local shorter = table.clone(stack)
		table.remove(shorter)
		self:_showMenu(menu, shorter)
	end
	local function activate(item: any)
		if not item.enabled then
			return
		end
		if item.sub then
			local deeper = table.clone(stack)
			table.insert(deeper, { title = string.upper(item.label), items = subTiles(item.sub) })
			self:_showMenu(menu, deeper)
		elseif item.ring == "emoji" and menu.selected then
			local who = self.state.players[menu.selected]
			local recipient = if menu.selected == self.state.you or who == nil then "AllPlayers" else who.id
			local deeper = table.clone(stack)
			table.insert(deeper, { title = "EMOJI", items = emojiTiles(recipient) })
			self:_showMenu(menu, deeper)
		elseif item.more then
			self:closeMenu()
			self:_showEmoji(item.more)
		elseif item.focus then
			self:closeMenu()
			if self.actions.focusTile then
				self.actions.focusTile(menu.tile)
			end
		elseif item.panel == "player" and menu.selected then
			self:closeMenu()
			task.spawn(self.openPlayer, self, menu.selected)
		else
			if item.intent then
				send(item.intent)
			end
			self:closeMenu()
		end
	end

	-- The title on a paper strip above the ring.
	local strip = Dossier.surface("ImageLabel", "tex_paper", T.sheet, { Name = "Title", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0, -6), Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 5, Parent = wheel })
	Kit.stroke(T.sheetLine, 1, 0.2).Parent = strip
	Kit.padding(0, 16).Parent = strip
	Dossier.stencil({ Text = level.title or "", TextSize = 20, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, ZIndex = 5, Parent = strip })

	-- The red centre: close, or back from a deeper ring.
	local centre = Kit.new("TextButton", { Name = "Centre", Text = "", AutoButtonColor = false, BackgroundColor3 = T.stamp, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(60, 60), ZIndex = 6, Parent = wheel })
	Kit.corner(30).Parent = centre
	Kit.stroke(Color3.fromHex("#6E1A14"), 2, 0).Parent = centre
	if root then
		Kit.glyph("close", { ImageColor3 = T.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(26, 26), ZIndex = 6, Parent = centre })
	else
		-- ← with BACK under it (Bruno, 2026-10-29), drawn from bars: the atlas
		-- has no left arrow.
		local arrow = Kit.new("Frame", { Name = "Arrow", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -7), Size = UDim2.fromOffset(26, 18), ZIndex = 6, Parent = centre })
		Kit.new("Frame", { BackgroundColor3 = T.sheet, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 3, 0.5, 0), Size = UDim2.fromOffset(22, 4), ZIndex = 6, Parent = arrow })
		for _, turn in { -45, 45 } do
			Kit.new("Frame", { BackgroundColor3 = T.sheet, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 1, 0.5, if turn < 0 then -4 else 4), Size = UDim2.fromOffset(12, 4), Rotation = turn, ZIndex = 6, Parent = arrow })
		end
		Dossier.stencil({ Text = "BACK", TextSize = 13, TextColor3 = T.sheet, AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, 5), Size = UDim2.fromOffset(50, 14), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 6, Parent = centre })
	end
	Dossier.clicky(centre, 1.08)
	centre.Activated:Connect(function()
		Dossier.click()
		if root then
			self:closeMenu()
		else
			back()
		end
	end)

	for i, item in items do
		local angle = (i - 1) / #items * 2 * math.pi
		local x, y = size / 2 + radius * math.sin(angle), size / 2 - radius * math.cos(angle)
		local tile = Dossier.rivetPlate(wheel, "", 20, item.primary == true, { Name = item.id, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(WHEEL_TILE, WHEEL_TILE), ZIndex = 5 })
		tile.Parent = wheel
		if item.emoji then
			-- A fixed box, centred (Kit.label sizes itself to its text otherwise,
			-- which pushed the emoji to a corner).
			local e = Kit.label({ Text = item.emoji, TextSize = 36, FontFace = Font.fromEnum(Enum.Font.SourceSans), TextColor3 = T.inkBlack, ZIndex = 6, Parent = tile })
			e.AutomaticSize = Enum.AutomaticSize.None
			e.AnchorPoint = Vector2.new(0.5, 0.5)
			e.Position = UDim2.fromScale(0.5, 0.5)
			e.Size = UDim2.fromScale(1, 1)
			e.TextXAlignment = Enum.TextXAlignment.Center
			e.TextYAlignment = Enum.TextYAlignment.Center
		else
			Kit.glyph(item.glyph, { ImageColor3 = T.inkBlack, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, if item.cost then 8 else 12), Size = UDim2.fromOffset(30, 30), ZIndex = 6, Parent = tile })
			local label = string.upper(item.label)
			if item.timerFraction then
				label = `{label} {math.ceil(item.timerFraction * 100)}%`
			end
			Dossier.stencil({ Text = label, TextSize = 14, TextColor3 = T.inkBlack, AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(4, if item.cost then 40 else 46), Size = UDim2.new(1, -8, 0, 18), ZIndex = 6, Parent = tile })
			if item.cost and item.cost > 0 then
				Dossier.typed({ Text = Format.renderNumber(item.cost), TextSize = 12, TextColor3 = if self.state.gold >= item.cost then C.gold else T.stamp, AutomaticSize = Enum.AutomaticSize.None, TextXAlignment = Enum.TextXAlignment.Center, Position = UDim2.fromOffset(4, 58), Size = UDim2.new(1, -8, 0, 14), ZIndex = 6, Parent = tile })
			end
		end
		setUsable(tile, item.enabled)
		tile.Activated:Connect(function()
			activate(item)
		end)
	end
	wheel.Visible = true
	self:_placeMenu()
end

-- Centred on the press, kept on screen. Input points are in screen pixels;
-- the HUD is scaled (UIScale), so convert through the parent's absolute frame.
function OfActions._placeMenu(self: any)
	local wheel, parent, at = self.menu, self.parent, self.menuAt
	if at == nil then
		return
	end
	local gui = parent:FindFirstAncestorOfClass("ScreenGui")
	local uiScale = if gui then gui:FindFirstChildOfClass("UIScale") else nil
	local s = if uiScale then uiScale.Scale else 1
	local k = if self.phone then 1 else 1.3
	local abs, size = parent.AbsolutePosition, parent.AbsoluteSize
	local localX, localY = (at.X - abs.X) / s, (at.Y - abs.Y) / s
	local w, h = size.X / s, size.Y / s
	local half = wheel.Size.X.Offset * k / 2
	-- Room above for the title strip, and clear of the top and bottom bars.
	local top = 40 * k + (if self.phone then 50 else 130)
	local bottom = if self.phone then 70 else 150
	wheel.Position = UDim2.fromOffset(
		math.clamp(localX, half + 4, math.max(half + 4, w - half - 4)),
		math.clamp(localY, half + top, math.max(half + top, h - half - bottom))
	)
end

-- Emoji table (to one player, or "AllPlayers") ----------------------------------------

function OfActions._showEmoji(self: any, recipient: string)
	local picker = self.picker
	clear(picker)
	picker.Visible = true
	text({ Text = Lang.t("player_panel.emotes"), FontFace = Theme.font.labelBold, LayoutOrder = 1, Parent = picker })
	local grid = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 })
	local layout = Kit.new("UIGridLayout", { CellSize = UDim2.fromOffset(Theme.size.touch, Theme.size.touch), CellPadding = UDim2.fromOffset(4, 4), SortOrder = Enum.SortOrder.LayoutOrder })
	layout.Parent = grid
	grid.Parent = picker
	for id = 0, Emoji.count - 1 do
		local b = button("chip", { Text = Emoji.flat[id], TextSize = 24, FontFace = Font.fromEnum(Enum.Font.SourceSans), LayoutOrder = id, Parent = grid })
		b.Activated:Connect(function()
			self.actions.sendIntent({ type = "emoji", recipient = recipient, emoji = id })
			picker.Visible = false
		end)
	end
	local cancel = button("dark", { Text = Lang.t("events_display.ignore"), Size = UDim2.new(1, 0, 0, Theme.size.touch), LayoutOrder = 3, Parent = picker })
	cancel.Activated:Connect(function()
		picker.Visible = false
	end)
end

-- Quick chat: a category, a phrase, and for [P1] phrases the player meant.

function OfActions._showChat(self: any, recipient: string, category: string?)
	local picker = self.picker
	clear(picker)
	picker.Visible = true
	local cats = HudModel.quickChat()
	local tabs = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 1 })
	Kit.list(Enum.FillDirection.Horizontal, 4).Parent = tabs
	tabs.Parent = picker
	local current = category or cats[1].name
	for i, c in cats do
		local tab = button("chip", { Text = c.label, TextSize = 14, Size = UDim2.fromOffset(68, 36), LayoutOrder = i, Parent = tabs })
		setChipSelected(tab, c.name == current)
		tab.Activated:Connect(function()
			self:_showChat(recipient, c.name)
		end)
	end
	local list = Kit.new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 280), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, LayoutOrder = 2 })
	Kit.list(Enum.FillDirection.Vertical, 4).Parent = list
	list.Parent = picker
	for _, c in cats do
		if c.name ~= current then
			continue
		end
		for i, e in c.entries do
			local b = button("dark", { Text = e.text, TextSize = 15, TextWrapped = true, Size = UDim2.new(1, -8, 0, Theme.size.touch), LayoutOrder = i, Parent = list })
			b.Activated:Connect(function()
				if e.requiresPlayer then
					self:_pickPlayer(function(target: string)
						self.actions.sendIntent({ type = "quick_chat", recipient = recipient, quickChatKey = e.key, target = target })
					end)
				else
					self.actions.sendIntent({ type = "quick_chat", recipient = recipient, quickChatKey = e.key })
					picker.Visible = false
				end
			end)
		end
	end
	local cancel = button("dark", { Text = Lang.t("events_display.ignore"), Size = UDim2.new(1, 0, 0, Theme.size.touch), LayoutOrder = 3, Parent = picker })
	cancel.Activated:Connect(function()
		picker.Visible = false
	end)
end

function OfActions._pickPlayer(self: any, done: (string) -> ())
	local state = self.state
	local picker = self.picker
	clear(picker)
	picker.Visible = true
	local list = Kit.new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 320), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6, LayoutOrder = 1 })
	Kit.list(Enum.FillDirection.Vertical, 4).Parent = list
	list.Parent = picker
	local players = {}
	for _, p in state.players do
		if p.alive and p.smallID ~= state.you then
			table.insert(players, p)
		end
	end
	table.sort(players, function(a, b)
		return a.displayName < b.displayName
	end)
	for i, p in players do
		local b = button("dark", { Text = p.displayName, TextSize = 15, Size = UDim2.new(1, -8, 0, Theme.size.touch), LayoutOrder = i, Parent = list })
		b.Activated:Connect(function()
			done(p.id)
			picker.Visible = false
		end)
	end
end

function OfActions.destroy(self: any)
	for _, c in self.connections do
		c:Disconnect()
	end
	if self.confirmCamera then
		self.confirmCamera()
		self.confirmCamera = nil
	end
	self.attackToken, self.confirmFor = nil, nil
	for conn in self.anims do
		conn:Disconnect()
	end
	table.clear(self.anims)
	for ghost in self.folds do
		ghost:Destroy()
	end
	for _, ring in self.tapRings or {} do
		ring:Destroy()
	end
	local toasts: { any } = table.clone(self.toasts or {})
	for _, toast in toasts do
		toast.stop()
	end
	if self.arsenalFly then
		self.arsenalFly:Destroy()
	end
	self.bar:Destroy()
	self.cards:Destroy()
	self.sheet:Destroy()
	self.menu:Destroy()
	self.picker:Destroy()
	self.attackCard:Destroy()
	self.warshipCard:Destroy()
	self.confirmCard:Destroy()
	self.banner:Destroy()
end

return OfActions
