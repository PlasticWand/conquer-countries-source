--!strict
-- Ported from RoWorld 2be8efb (src/client/UI/Tutorial.luau, src/client/UI/Coach.luau, src/client/UI/UIAdvisor.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
--
-- A new player's first match, step by step, then one-time coach tips in the
-- matches after (Bruno, 2026-11-10: port RoWorld's tutorial, rookie
-- protections kept). Shared/Tutorial holds the numbers and runs the steps;
-- this draws them in the match HUD, in the dossier style:
--   * a paper card at the top centre under the HUD's top bar: "2 / 6", one
--     short line, a bar for a goal with progress, and Skip; green with
--     "Nice!" when a step is done;
--   * a mark where to tap: two rings closing on a dot with "Tap here" under
--     it (a map spot), or closing around a control's edge;
--   * the coach: one tip card at a time with the same mark on what it talks
--     about, each tip once per player (saved on the server), muted while the
--     tutorial runs.
-- Rookie protections, applied by OpenFrontClient through orderShare(): the
-- tutorial's troop floor and Attack bar cap while it runs, and in a player's
-- first Tutorial.ROOKIE_MATCHES matches a floor after it.
-- Reports go to the server's Tutorial remote: funnel steps, Skip, the City's
-- gold, tips seen.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Tutorial = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Tutorial"))

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)

local C = Theme.color
local stencil = Dossier.stencil
local typed = Dossier.typed

local AMBER = C.hazard
local GREEN = Color3.fromHex("#2E8A3E")
local RED = C.stamp
local TINTS: { [string]: Color3 } = { amber = AMBER, green = GREEN, red = RED }

-- Spawn spots tried for the roomiest one; free land this far (tiles) from
-- every start is roomy enough; the camera's zoom on it (a thumb hits the land
-- around it).
local SPAWN_TRIES = 240
local SPAWN_ROOM = 60 -- (RoWorld's 35 left our World start boxed in by nations)
local SPAWN_ZOOM = 6
-- Own tiles looked at per scan (neighbours, the frontier, the coast).
local SCAN_TILES = 3000
local SCAN_EVERY = 0.4

-- The coach's tips (RoWorld's, for our controls). `again`: offered every time
-- (paced by a cool-down), not once per player.
local TIPS: { [string]: { icon: string, touch: string, desktop: string, again: boolean? } } = {
	attacked = {
		icon = "shield",
		touch = "You are under attack! Every front is in the Attacks list. Defense Posts make borders much harder to take.",
		desktop = "You are under attack! Every front is in the Attacks list. Defense Posts (4) make borders much harder to take.",
	},
	floor = {
		icon = "troops",
		again = true,
		touch = `Keep {math.floor(Tutorial.ROOKIE_FLOOR * 100 + 0.5)}% of your army at home, or neighbours walk right in. In your first {Tutorial.ROOKIE_MATCHES} matches, attacks hold that much back.`,
		desktop = `Keep {math.floor(Tutorial.ROOKIE_FLOOR * 100 + 0.5)}% of your army at home, or neighbours walk right in. In your first {Tutorial.ROOKIE_MATCHES} matches, attacks hold that much back.`,
	},
	select = {
		icon = "target",
		touch = "Target selected: check their troops, then press ATTACK.",
		desktop = "Target selected: check their troops, then press ATTACK.",
	},
	expand = {
		icon = "sword",
		touch = "Tap empty land next to you to expand.",
		desktop = "Click empty land next to you to expand.",
	},
	contact = {
		icon = "alliance",
		touch = "You now border %s. Tap their land to size them up, then press ATTACK.",
		desktop = "You now border %s. Click their land to attack, or right-click it for more.",
	},
	ratio = {
		icon = "troops",
		touch = "Tap a % on the Attack bar to choose how many troops each tap sends.",
		desktop = "The Attack bar sets how many of your troops each click sends.",
	},
	city = {
		icon = "city",
		touch = "You can afford a City. Tap BUILD and place one on your land to raise your troop limit.",
		desktop = "You can afford a City (1). Cities raise your troop limit: place one on your land.",
	},
	boat = {
		icon = "boat",
		touch = "You reached the sea. Tap a distant coast to send a boat invasion.",
		desktop = "You reached the sea. Click a distant coast to send a boat invasion.",
	},
}
local PRIORITY = { "attacked", "floor", "select", "expand", "contact", "ratio", "city", "boat" }
local TIP_LIFETIME = 16
-- What the tutorial's steps taught is not said again as a tip.
local TAUGHT = { "expand", "ratio", "city", "contact", "select" }

export type Deps = {
	state: any, -- ClientState
	-- The match layer the HUD's frame fills (Ui/Root's root.match): the card
	-- and mark live here, not in the HUD's frame, which a layout change
	-- destroys and builds again.
	layer: Frame,
	hud: () -> any, -- the current OfHud
	actionsUi: () -> any, -- the current OfActions
	tileToScreen: (number) -> Vector2?,
	focusTile: (number, number?) -> (),
	isLand: (number) -> boolean, -- passable land
	isShore: (number) -> boolean,
	send: ({ [string]: any }) -> (), -- an intent
	report: ({ [string]: any }) -> (), -- the Tutorial remote
	profile: () -> any?, -- Store/Profile's view
	touch: () -> boolean,
	sound: (string) -> (),
}

local TutorialController = {}
TutorialController.__index = TutorialController

local function chosenCity(actionsUi: any): boolean
	return actionsUi ~= nil and actionsUi.chosen == "City"
end

local function ring(parent: Instance, thickness: number): Frame
	local f = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(20, 20), Parent = parent })
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = f })
	Kit.stroke(AMBER, thickness, 0).Parent = f
	return f
end

function TutorialController.new(deps: Deps)
	local self: any = setmetatable({
		deps = deps,
		run = Tutorial.newRun(),
		gameID = nil :: string?,
		matchesBefore = nil :: number?,
		aliveSeconds = 0,
		t = 0,
		parent = nil :: Instance?,
		-- What the player did since the last frame.
		ordered = false,
		orderedOwner = false,
		orderedLand = false,
		-- The spawn step's spot.
		spot = nil :: number?,
		spotFocused = false,
		spotStarts = -1, -- the starts known when the spot was picked
		-- Own tiles (kept from tile changes), and what the last scan found.
		mine = {} :: { [number]: true },
		scanAt = 0,
		neighbour = nil :: number?,
		neighbourTile = nil :: number?, -- their land on your border
		frontier = nil :: number?,
		inland = nil :: number?, -- your land away from your name
		coast = false,
		-- The rookie floor after the tutorial (a share of the troop limit).
		rookieFloor = nil :: number?,
		-- The coach.
		seen = {} :: { [string]: boolean },
		queue = {} :: { { id: string, arg: string? } },
		tip = nil :: string?,
		tipAge = 0,
		tipTarget = nil :: (() -> Vector2?)?,
		muted = false,
		floorTipAt = -math.huge,
		attackCardWas = false,
		connections = {} :: { RBXScriptConnection },
	}, TutorialController)
	self:_build()
	local state = deps.state
	table.insert(self.connections, state.Snapshot:Connect(function()
		self:_onSnapshot()
	end))
	table.insert(self.connections, state.TilesChanged:Connect(function(changed: { number })
		local me = state.you
		for _, tile in changed do
			if state:ownerAt(tile) == me then
				self.mine[tile] = true
			else
				self.mine[tile] = nil
			end
		end
	end))
	table.insert(self.connections, RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(function()
			self:_frame(dt)
		end)
		if not ok then
			warn(`[Tutorial] {err}`)
		end
	end))
	if state.ready then
		self:_onSnapshot()
	end
	return self
end

-- Drawing --------------------------------------------------------------------------------

function TutorialController._build(self: any)
	-- The mark.
	local mark = Kit.new("Frame", { Name = "TutorialMark", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 40, Visible = false })
	self.mark = mark
	self.ringA = ring(mark, 4)
	self.ringB = ring(mark, 3)
	-- (Nothing here has a background: the map ignores taps on anything that
	-- does (MapInput's blocked), and the mark sits on the very tile to tap. The
	-- dot is a thick stroke on a tiny ring; the word is outlined text.)
	local dot = Kit.new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(6, 6), Parent = mark })
	Kit.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })
	Kit.stroke(AMBER, 5, 0).Parent = dot
	self.dot = dot
	local word = stencil({ Text = "Tap here", TextSize = 24, TextColor3 = C.sheet, TextStrokeColor3 = C.inkBlack, TextStrokeTransparency = 0, AnchorPoint = Vector2.new(0.5, 0), Parent = mark })
	self.word = word

	-- The card (the tutorial's step, or a coach tip).
	local card = Dossier.surface("ImageLabel", "tex_paper", C.sheet, { Name = "TutorialCard", AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, ZIndex = 41, Visible = false })
	self.card = card
	self.cardStroke = Kit.stroke(AMBER, 3, 0)
	self.cardStroke.Parent = card
	Kit.corner(4).Parent = card
	Kit.new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 10), Parent = card })
	Kit.list(Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = card
	self.cardScale = Kit.new("UIScale", { Parent = card })
	self.count = stencil({ Text = "1 / 6", TextSize = 24, TextColor3 = AMBER, LayoutOrder = 1, Parent = card })
	self.icon = Kit.glyph("info", { ImageColor3 = AMBER, Size = UDim2.fromOffset(26, 26), LayoutOrder = 1, Visible = false, Parent = card })
	local middle = Kit.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(340, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = card })
	Kit.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent = middle
	self.middle = middle
	self.text = typed({ Text = "", TextSize = 20, TextColor3 = C.inkBlack, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = 1, Parent = middle })
	local bar = Kit.new("Frame", { Name = "Bar", BackgroundColor3 = Color3.fromHex("#2E2F24"), BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 8), LayoutOrder = 2, Visible = false, Parent = middle })
	Kit.corner(4).Parent = bar
	self.bar = bar
	self.fill = Kit.new("Frame", { BackgroundColor3 = AMBER, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = bar })
	Kit.corner(4).Parent = self.fill
	local button = Kit.new("TextButton", { Name = "Skip", Text = "", AutoButtonColor = false, BackgroundColor3 = C.inkBlack, BorderSizePixel = 0, Size = UDim2.fromOffset(84, 48), LayoutOrder = 3, Parent = card })
	Kit.corner(4).Parent = button
	self.buttonText = stencil({ Text = "SKIP", TextSize = 20, TextColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = button })
	-- A phone's coach tip closes with a ✓ (Bruno, 2026-11-10): the icon art,
	-- since the stencil font has no ✓ or ✕ (it drew an empty box).
	self.buttonIcon = Kit.glyph("check", { ImageColor3 = C.sheet, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(30, 30), Visible = false, Parent = button })
	Dossier.clicky(button, 1.06)
	button.Activated:Connect(function()
		if self.tip then
			self:_dismissTip()
		else
			self.run.press()
			-- (a stopped run hands over its last events on the next update)
			self:_frameTutorial(0)
		end
	end)
	self.button = button
end

-- The match layer (the HUD's frame fills it, so their units agree).
function TutorialController._attach(self: any): Instance?
	local hud = self.deps.hud()
	if hud == nil or hud.match == nil or not hud.match.Visible then
		return nil
	end
	local parent = self.deps.layer
	if parent ~= self.parent then
		self.parent = parent
		self.mark.Parent = parent
		self.card.Parent = parent
	end
	return parent
end

-- A screen point (AbsolutePosition space) in the HUD frame's units.
function TutorialController._toParent(self: any, at: Vector2): (Vector2, number)
	local parent = self.parent
	local gui = parent and parent:FindFirstAncestorOfClass("ScreenGui")
	local uiScale = if gui then gui:FindFirstChildOfClass("UIScale") else nil
	local s = if uiScale then uiScale.Scale else 1
	local origin = if parent then parent.AbsolutePosition else Vector2.zero
	return (at - origin) / s, s
end

-- A control's centre and radius (screen space), when it is on screen.
local function around(gui: GuiObject?): (Vector2?, number?)
	if gui == nil or not gui:IsDescendantOf(game) then
		return nil, nil
	end
	local node: Instance? = gui
	while node and node:IsA("GuiObject") do
		if not node.Visible then
			return nil, nil
		end
		node = node.Parent
	end
	local size = gui.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return nil, nil
	end
	return gui.AbsolutePosition + size / 2, math.max(size.X, size.Y) / 2
end

-- Draws the mark at `p` (screen space; nil hides it). `radius`: a control's,
-- and the rings close onto its edge instead of a dot.
function TutorialController._drawMark(self: any, p: Vector2?, radius: number?, wordText: string?)
	local parent = self.parent
	if p == nil or parent == nil then
		self.mark.Visible = false
		return
	end
	local local_, s = self:_toParent(p)
	local size = parent.AbsoluteSize / s
	if local_.X < 0 or local_.Y < 0 or local_.X > size.X or local_.Y > size.Y then
		self.mark.Visible = false
		return
	end
	self.mark.Visible = true
	-- two rings closing on the dot, half a beat apart: a finger coming down
	local k1 = (self.t % 1.1) / 1.1
	local k2 = ((self.t + 0.55) % 1.1) / 1.1
	local r = if radius then radius / s else nil
	local inner = if r then r + 6 else 16
	local outer = inner + (if r then 22 else 30)
	for _, pair in { { self.ringA, k1 }, { self.ringB, k2 } } do
		local f: Frame, k: number = pair[1], pair[2]
		local d = 2 * (outer - (outer - inner) * k)
		f.Position = UDim2.fromOffset(local_.X, local_.Y)
		f.Size = UDim2.fromOffset(d, d)
		local stroke = f:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Transparency = 1 - k * 0.95
	end
	self.dot.Visible = r == nil
	self.dot.Position = UDim2.fromOffset(local_.X, local_.Y)
	self.word.Visible = wordText ~= ""
	self.word.Text = wordText or (if self.deps.touch() then "Tap here" else "Click here")
	-- under the mark; over it near the bottom of the screen
	local gap = outer + 8
	local below = local_.Y + gap + 34 < size.Y
	self.word.AnchorPoint = Vector2.new(0.5, if below then 0 else 1)
	self.word.Position = UDim2.fromOffset(local_.X, if below then local_.Y + gap else local_.Y - gap)
end

-- The card's place: top centre, under the HUD's top bar (or the phone's race).
function TutorialController._placeCard(self: any)
	local parent = self.parent
	if parent == nil then
		return
	end
	local hud = self.deps.hud()
	local y = 80
	local top = hud and hud.top
	if top and top.Visible and top.AbsoluteSize.Y > 0 then
		local bottom = self:_toParent(top.AbsolutePosition + Vector2.new(0, top.AbsoluteSize.Y))
		y = bottom.Y + 10
	end
	local _, s = self:_toParent(Vector2.zero)
	self.card.Position = UDim2.new(0.5, 0, 0, y)
	self.cardScale.Scale = if hud and hud.isPhone then 1.05 else 1
	self.middle.Size = UDim2.fromOffset(if hud and hud.isPhone then 330 else 380, 0)
	local _ = s
end

function TutorialController._showCard(self: any, count: string?, icon: string?, text: string, tint: string, button: string, bar: number?)
	local color = TINTS[tint] or AMBER
	self.count.Visible = count ~= nil
	self.count.Text = count or ""
	self.count.TextColor3 = color
	self.icon.Visible = icon ~= nil
	if icon then
		Kit.setGlyph(self.icon, icon)
		self.icon.ImageColor3 = color
	end
	self.text.Text = text
	self.cardStroke.Color = color
	self.bar.Visible = bar ~= nil
	if bar then
		self.fill.Size = UDim2.fromScale(math.clamp(bar, 0, 1), 1)
		self.fill.BackgroundColor3 = color
	end
	-- ("check": the ✓ icon instead of a word)
	local check = button == "check"
	self.buttonIcon.Visible = check
	self.buttonText.Visible = not check
	self.buttonText.Text = if check then "" else button
	self.card.Visible = true
	self:_placeCard()
end

function TutorialController._pop(self: any)
	local scale = self.cardScale
	local base = scale.Scale
	scale.Scale = base * 0.94
	task.delay(0.05, function()
		scale.Scale = base * 0.98
	end)
	task.delay(0.1, function()
		scale.Scale = base
	end)
end

-- Reading the match ---------------------------------------------------------------------

function TutorialController._onSnapshot(self: any)
	local state = self.deps.state
	if state.gameID == self.gameID then
		return
	end
	self.gameID = state.gameID
	self.matchesBefore = nil
	self.aliveSeconds = 0
	self.spot, self.spotFocused, self.spotStarts = nil, false, -1
	self.neighbour, self.neighbourTile, self.frontier, self.inland, self.coast = nil, nil, nil, nil, false
	self.rookieFloor = nil
	self.queue, self.tip = {}, nil
	self.attackCardWas = false
	-- own tiles, once (none during the spawn phase)
	local mine: { [number]: true } = {}
	local me = state:me()
	if me and me.tiles > 0 then
		local n = state.width * state.height
		local you = state.you
		for tile = 0, n - 1 do
			if bit32.band(buffer.readu16(state.tileState, tile * 2), 0xfff) == you then
				mine[tile] = true
			end
		end
	end
	self.mine = mine
	-- The tutorial runs in its own match, unless the player already finished
	-- or skipped it.
	local view = self.deps.profile()
	local how = view and view.tutorial
	if state.gameConfig.tutorial == true and how ~= "done" and how ~= "skipped" then
		self.run.begin()
		self.muted = true
		local hud = self.deps.hud()
		if hud then
			hud:setRatio(Tutorial.DEFAULT_RATIO)
		end
	elseif self.run.active then
		self.run.stop("left")
		self:_frameTutorial(0)
	end
end

-- A roomy place to start: of SPAWN_TRIES free land tiles, one far from every
-- start, and away from the map's top and bottom (RoWorld: its first pick on the
-- world map was the middle of Antarctica).
function TutorialController._findSpot(self: any): number?
	local state, deps = self.deps.state, self.deps
	local w, h = state.width, state.height
	if w <= 0 or h <= 0 then
		return nil
	end
	local starts = {}
	for _, p in state.players do
		if p.spawnTile then
			table.insert(starts, p.spawnTile)
		end
	end
	self.spotStarts = #starts
	local best, bestD = nil, -math.huge
	for _ = 1, SPAWN_TRIES * 4 do
		local t = math.random(0, w * h - 1)
		if deps.isLand(t) and not deps.isShore(t) and state:ownerAt(t) == 0 then
			local x, y = t % w, t // w
			local d = SPAWN_ROOM
			for _, s in starts do
				d = math.min(d, math.sqrt((x - s % w) ^ 2 + (y - s // w) ^ 2))
			end
			local off = math.abs(y / h - 0.45)
			d -= math.max(0, off - 0.27) * 300
			if d > bestD then
				best, bestD = t, d
			end
		end
	end
	return best
end

-- Neighbours, a frontier tile with free land beside it, and whether the land
-- touches the sea: from up to SCAN_TILES of your tiles.
function TutorialController._scan(self: any)
	local state, deps = self.deps.state, self.deps
	local w, h = state.width, state.height
	local you = state.you
	local found: { [number]: number } = {}
	local frontier: number? = nil
	local coast = false
	local n = 0
	-- (your land 4 to 14 tiles from your name, all yours around it)
	local anchor = state.names[you]
	local inland: number? = nil
	for tile in self.mine do
		n += 1
		if n > SCAN_TILES then
			break
		end
		if not coast and deps.isShore(tile) then
			coast = true
		end
		local x, y = tile % w, tile // w
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			local nx, ny = x + d[1], y + d[2]
			if nx >= 0 and ny >= 0 and nx < w and ny < h then
				local nb = ny * w + nx
				local owner = state:ownerAt(nb)
				if owner == 0 then
					if frontier == nil and deps.isLand(nb) then
						frontier = nb
					end
				elseif owner ~= you then
					found[owner] = found[owner] or nb
				end
			end
		end
		if inland == nil and anchor then
			local d = math.sqrt((x + 0.5 - anchor.x) ^ 2 + (y + 0.5 - anchor.y) ^ 2)
			if d >= 4 and d <= 14 and self.mine[tile + 1] and self.mine[tile - 1] and self.mine[tile + w] and self.mine[tile - w] then
				inland = tile
			end
		end
	end
	self.inland = inland
	-- (the same neighbour while it still borders you)
	if self.neighbour == nil or not found[self.neighbour] then
		self.neighbour = nil
		for id in found do
			local p = state:player(id)
			if p and p.alive then
				self.neighbour = id
				break
			end
		end
	end
	self.neighbourTile = if self.neighbour then found[self.neighbour] else nil
	self.frontier = frontier
	self.coast = coast
end

-- A tile at a player's name (their centre), for the mark.
function TutorialController._playerTile(self: any, id: number): number?
	local state = self.deps.state
	local a = state.names[id]
	if a then
		return math.floor(a.y) * state.width + math.floor(a.x)
	end
	local p = state:player(id)
	return p and p.spawnTile
end

function TutorialController._tileScreen(self: any, tile: number?): Vector2?
	if tile == nil then
		return nil
	end
	return self.deps.tileToScreen(tile)
end

-- What the player did ----------------------------------------------------------------

-- An order went out (OpenFrontClient): on someone's land, or on empty land.
function TutorialController.noteOrder(self: any, onOwner: boolean)
	self.ordered = true
	if onOwner then
		self.orderedOwner = true
		self:_completeTip("contact")
		self:_completeTip("select")
	else
		self.orderedLand = true
		self:_completeTip("expand")
	end
end

function TutorialController.noteBoat(self: any)
	self.ordered = true
	self.orderedOwner = true
	self:_completeTip("boat")
end

function TutorialController.noteRatio(self: any)
	self:_completeTip("ratio")
end

-- The floor under the army now (a share of the troop limit; nil: none).
function TutorialController.troopFloor(self: any): number?
	if self.run.active then
		return self.runFloor
	end
	return self.rookieFloor
end

-- The most of the army an order may send now (1: no limit; 0: nothing).
function TutorialController.orderShare(self: any): number
	local me = self.deps.state:me()
	if me == nil then
		return 1
	end
	return Tutorial.floorShare(me.troops, me.maxTroops, self:troopFloor())
end

-- The floor held an order back: the first time in a match, then at most
-- once a minute, a tip on the Attack bar says why (the tutorial's card says
-- nothing more while it runs).
function TutorialController.floorHeld(self: any)
	if self.run.active or os.clock() - self.floorTipAt < 60 then
		return
	end
	self.floorTipAt = os.clock()
	self:_offer("floor")
end

-- The tutorial ----------------------------------------------------------------------------

function TutorialController._target(self: any, target: string?): (Vector2?, number?)
	if target == nil then
		return nil, nil
	end
	local hud = self.deps.hud()
	local actionsUi = self.deps.actionsUi()
	local state = self.deps.state
	if target == "spot" then
		return self:_tileScreen(self.spot), nil
	elseif target == "frontier" then
		-- (no free land beside you: a neighbour's border, which a tap also takes)
		return self:_tileScreen(self.frontier or self.neighbourTile), nil
	elseif target == "neighbour" then
		return self:_tileScreen(self.neighbourTile), nil
	elseif target == "attack" then
		return around(actionsUi and actionsUi.attackMain)
	elseif target == "ownLand" then
		return self:_tileScreen(self.inland or self:_playerTile(state.you)), nil
	elseif target == "troops" then
		local text = hud and hud.troopsText
		return around(if text then text.Parent :: GuiObject else nil)
	elseif target == "ratio" then
		return around(hud and hud.ratioChips and hud.ratioChips[Tutorial.RATIO_GOAL])
	elseif target == "confirm" then
		return around(actionsUi and actionsUi.confirmYes)
	elseif target == "city" then
		local slot = actionsUi and actionsUi.itemButtons and actionsUi.itemButtons["City"]
		local p, r = around(slot)
		if p then
			return p, r
		end
		return around(hud and hud.buildButton)
	end
	return nil, nil
end

function TutorialController._observe(self: any): Tutorial.Observation
	local state, deps = self.deps.state, self.deps
	local me = state:me()
	local hud = deps.hud()
	local actionsUi = deps.actionsUi()
	local cityBuilt = false
	for _, u in state.units do
		if u.type == "City" and u.owner == state.you then
			cityBuilt = true
			break
		end
	end
	local chosen = actionsUi and actionsUi.chosen
	local nb = self.neighbour
	local nbPlayer = if nb then state:player(nb) else nil
	local o = {
		touch = deps.touch(),
		spawned = me ~= nil and (me.spawnTile ~= nil or me.tiles > 0),
		alive = me ~= nil and me.alive,
		playing = state.ready and not state:inSpawnPhase(),
		over = state.winner ~= nil,
		ordered = self.ordered,
		orderedOwner = self.orderedOwner,
		orderedLand = self.orderedLand,
		troops = if me then me.troops else 0,
		maxTroops = if me then me.maxTroops else 0,
		ratio = if hud then hud.ratio else Tutorial.DEFAULT_RATIO,
		aliveSeconds = self.aliveSeconds,
		hasSpot = self.spot ~= nil,
		spotFree = self.spot ~= nil and state:ownerAt(self.spot) == 0,
		neighbour = if nbPlayer then nb else nil,
		neighbourName = if nbPlayer then nbPlayer.displayName else nil,
		cityBuilt = cityBuilt,
		placingCity = chosen == "City",
		confirmOpen = chosen == "City" and actionsUi.confirmCard ~= nil and actionsUi.confirmCard.Visible,
		attackCardOpen = actionsUi ~= nil and actionsUi.attackCard ~= nil and actionsUi.attackCard.Visible == true,
	}
	self.ordered, self.orderedOwner, self.orderedLand = false, false, false
	return o
end

function TutorialController._runEvents(self: any, events: { { [string]: any } })
	local deps = self.deps
	for _, e in events do
		if e.kind == "step" then
			deps.report({ op = "step", n = e.n, passed = e.passed })
		elseif e.kind == "spawn" and self.spot then
			deps.send({ type = "tile_action", tile = self.spot, ratio = Tutorial.DEFAULT_RATIO })
		elseif e.kind == "cityGold" then
			deps.report({ op = "cityGold" })
		elseif e.kind == "sound" then
			deps.sound(e.key)
		elseif e.kind == "pop" then
			self:_pop()
		elseif e.kind == "finished" then
			local hud = deps.hud()
			if hud then
				hud:setRatioCap(1)
			end
			if e.how == "skipped" then
				deps.report({ op = "skip", n = self.run.i })
			elseif e.how == "left" then
				deps.report({ op = "left" })
			elseif e.how == "done" then
				for _, id in TAUGHT do
					self:_markSeen(id)
				end
			end
		elseif e.kind == "closed" then
			self.muted = false
		end
	end
end

-- Per frame ------------------------------------------------------------------------------

function TutorialController._frame(self: any, dt: number)
	self.t += dt
	local state = self.deps.state
	local parent = self:_attach()
	if parent == nil or not state.ready then
		self.mark.Visible = false
		self.card.Visible = false
		return
	end
	local me = state:me()
	if me and me.alive and not state:inSpawnPhase() then
		self.aliveSeconds += dt
	end
	if self.matchesBefore == nil then
		local view = self.deps.profile()
		if view then
			self.matchesBefore = tonumber(view.matches) or 0
			self.seen = {}
			for _, id in view.tipsSeen or {} do
				self.seen[id] = true
			end
		end
	end
	self.scanAt -= dt
	if self.scanAt <= 0 then
		self.scanAt = SCAN_EVERY
		if next(self.mine) ~= nil then
			self:_scan()
		end
	end
	local run = self.run
	if run.active or run.ending > 0 then
		self:_frameTutorial(dt)
		return
	end
	self:_frameRookie()
	self:_frameCoach(dt)
end

function TutorialController._frameTutorial(self: any, dt: number)
	local run = self.run
	local state = self.deps.state
	-- the spawn step's spot, found once and shown
	if run.active and run.i == 1 and state:inSpawnPhase() then
		-- (picked again once the others' starts appear: picked before them,
		-- "far from every start" meant nothing)
		local me = state:me()
		local starts = 0
		for _, p in state.players do
			if p.spawnTile then
				starts += 1
			end
		end
		local stale = starts ~= self.spotStarts and os.clock() - (self.spotAt or 0) > 1
		if not (me and me.spawnTile) and (self.spot == nil or state:ownerAt(self.spot) ~= 0 or stale) then
			local was = self.spot
			self.spot = self:_findSpot()
			self.spotAt = os.clock()
			if self.spot ~= was then
				self.spotFocused = false
			end
		end
		if self.spot and not self.spotFocused then
			self.spotFocused = true
			self.deps.focusTile(self.spot, SPAWN_ZOOM)
		end
	end
	local f = run.update(self:_observe(), dt)
	self.runFloor = f.troopFloor
	local hud = self.deps.hud()
	if hud and (hud.ratioCap or 1) ~= f.ratioCap then
		hud:setRatioCap(f.ratioCap)
	end
	self:_runEvents(f.events)
	if f.card.visible then
		self:_showCard(f.card.count, nil, f.card.text, f.card.tint, string.upper(f.card.skip), f.card.bar)
	else
		self.card.Visible = false
	end
	local p, r = self:_target(f.mark.target)
	self:_drawMark(p, r, f.mark.word)
end

-- In a player's first ROOKIE_MATCHES matches the floor holds from the time it
-- arms (Tutorial.floorArmed).
function TutorialController._frameRookie(self: any)
	if self.rookieFloor ~= nil or self.matchesBefore == nil or not Tutorial.rookie(self.matchesBefore) then
		return
	end
	local me = self.deps.state:me()
	if me and me.alive and Tutorial.floorArmed(me.troops, me.maxTroops, self.aliveSeconds) then
		self.rookieFloor = Tutorial.ROOKIE_FLOOR
	end
end

-- The coach -------------------------------------------------------------------------------

function TutorialController._markSeen(self: any, id: string)
	if not self.seen[id] then
		self.seen[id] = true
		self.deps.report({ op = "tip", id = id })
	end
end

function TutorialController._offer(self: any, id: string, arg: string?, target: (() -> Vector2?)?)
	local tip = TIPS[id]
	if tip == nil or self.muted or id == self.tip or (not tip.again and self.seen[id]) then
		return
	end
	for _, q in self.queue do
		if q.id == id then
			return
		end
	end
	table.insert(self.queue, { id = id, arg = arg, target = target })
	table.sort(self.queue, function(a, b)
		return (table.find(PRIORITY, a.id) or 99) < (table.find(PRIORITY, b.id) or 99)
	end)
end

-- The player did what a tip teaches: close it, and never offer it again.
function TutorialController._completeTip(self: any, id: string)
	if self.run.active then
		return
	end
	self:_markSeen(id)
	for i = #self.queue, 1, -1 do
		if self.queue[i].id == id then
			table.remove(self.queue, i)
		end
	end
	if self.tip == id then
		self:_dismissTip()
	end
end

function TutorialController._dismissTip(self: any)
	self.tip = nil
	self.tipTarget = nil
	self.card.Visible = false
	self.mark.Visible = false
end

function TutorialController._frameCoach(self: any, dt: number)
	local state, deps = self.deps.state, self.deps
	local me = state:me()
	local hud = deps.hud()
	local actionsUi = deps.actionsUi()
	local playing = state.ready and not state:inSpawnPhase() and me ~= nil and me.alive and state.winner == nil
	if not playing or self.muted then
		if self.tip then
			self:_dismissTip()
		end
		self.mark.Visible = false
		return
	end
	-- What is happening offers tips (RoWorld's UIAdvisor.check_tips).
	local secs = if state.startTick then (state.tick - state.startTick) / 10 else 0
	if secs > 3.4 then
		self:_offer("expand", nil, function()
			return self:_tileScreen(self.frontier)
		end)
	end
	if secs > 22 then
		self:_offer("ratio", nil, function()
			return (around(hud and hud.ratioChips and hud.ratioChips[Tutorial.RATIO_GOAL]))
		end)
	end
	local cityCost = state.costs and state.costs["City"]
	if secs > 25 and cityCost and cityCost > 0 and me.gold >= cityCost then
		self:_offer("city", nil, function()
			local p = self:_target("city")
			return p
		end)
	end
	if self.neighbour and secs > 8 then
		local nb = self.neighbour
		local p = state:player(nb)
		self:_offer("contact", if p then p.displayName else "them", function()
			return self:_tileScreen(self:_playerTile(nb))
		end)
	end
	if self.coast and secs > 40 then
		self:_offer("boat")
	end
	local cardOpen = actionsUi and actionsUi.attackCard and actionsUi.attackCard.Visible
	if cardOpen and not self.attackCardWas then
		self:_offer("select", nil, function()
			return (around(actionsUi.attackMain))
		end)
	end
	self.attackCardWas = cardOpen == true
	for _, a in state.attacks do
		if a.outgoing == false then
			self:_offer("attacked", nil, function()
				return (around(hud and hud.attacks))
			end)
			break
		end
	end
	if chosenCity(actionsUi) then
		self:_completeTip("city")
	end
	-- (the Attack bar used: its tip is done)
	local ratio = hud and hud.ratio
	if ratio and self.ratioWas and math.abs(ratio - self.ratioWas) > 1e-6 then
		self:_completeTip("ratio")
	end
	self.ratioWas = ratio
	-- One tip at a time.
	if self.tip == nil and #self.queue > 0 then
		local q = table.remove(self.queue, 1) :: any
		local tip = TIPS[q.id]
		if tip.again or not self.seen[q.id] then
			self.tip = q.id
			self.tipTarget = q.target
			self.tipAge = 0
			if not tip.again then
				self:_markSeen(q.id)
			end
			local text = if deps.touch() then tip.touch else tip.desktop
			if string.find(text, "%s", 1, true) then
				text = string.format(text, q.arg or "them")
			end
			self:_showCard(nil, tip.icon, text, "amber", if hud and hud.isPhone then "check" else "GOT IT", nil)
			self:_pop()
			deps.sound("ui.card")
		end
	end
	if self.tip then
		self.tipAge += dt
		local life = if hud and hud.isPhone then TIP_LIFETIME * 0.65 else TIP_LIFETIME
		if self.tipAge > life then
			self:_dismissTip()
			return
		end
		self:_placeCard()
		local p: Vector2? = nil
		if self.tipTarget then
			local ok, v = pcall(self.tipTarget)
			p = if ok then v else nil
		end
		self:_drawMark(p, nil, "")
	else
		self.mark.Visible = false
	end
end

function TutorialController.destroy(self: any)
	for _, c in self.connections do
		c:Disconnect()
	end
	table.clear(self.connections)
	self.mark:Destroy()
	self.card:Destroy()
end

return TutorialController
