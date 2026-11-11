--!strict
-- Settings as a dossier window, laid out 1:1 to Bruno's reference (2026-10-26,
-- docs/design/dossier-ui/settings-reference.png, 1493 x 1053): each setting a
-- folder with its icon, a line saying what it does, and riveted On / Off (or
-- size) plates; DONE closes. Changes apply at once and are saved with the
-- profile. Bruno's settings pass (2026-10-28, feature 15): Music is a volume
-- slider, "Territory labels" and "Select before attacking" join, and How to
-- Play opens from here. The rows scroll under the header (on a phone, the
-- same rows scaled to the screen's width under the full-screen header).
-- "Expansion sound" (Bruno, 2026-10-30) picks the pops while your land
-- grows, or turns them off.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local PlayerSettings = require(ReplicatedStorage:WaitForChild("Shared").PlayerSettings)

local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)

local C = Theme.color

local Settings = {}

local WINDOW_H = 960
-- Reference pixels from one folder's top to the next.
local ROW_STEP = 173
local FIRST_ROW = 185

-- `onChange` receives a fresh copy each time something changes;
-- `onHowToPlay`, when given, opens How to Play.
function Settings.open(host: Instance, current: PlayerSettings.Settings, onChange: (PlayerSettings.Settings) -> (), onHowToPlay: (() -> ())?): Kit.Modal
	local s = table.clone(current)
	local rows = 8
	local lastBottom = FIRST_ROW + (rows - 1) * ROW_STEP + 156
	local doneY = lastBottom + 82
	local w: Dossier.Window
	local frame: Dossier.Window -- the header and DONE
	-- Reference pixels the rows move by (they start at the scrolling page's top).
	local ox, oy = 0, 0
	if Dossier.phone() then
		local pw = Dossier.phoneWindow(host, "SETTINGS")
		local k = (pw.width - 36) / 1395
		local page = Kit.scroll({ Name = "Rows", Size = UDim2.fromScale(1, 1), AutomaticCanvasSize = Enum.AutomaticSize.None, CanvasSize = UDim2.fromOffset(0, math.round((doneY + 62 - FIRST_ROW + 24) * k)), ScrollBarThickness = 8, ScrollBarImageColor3 = Color3.fromHex("#1E2019"), Parent = pw.body })
		w = Dossier.rescaled(pw, k, page)
		frame = w
		ox, oy = 12 / k - 45, 8 / k - FIRST_ROW
	else
		frame = Dossier.window(host, 1493, 1053, WINDOW_H, 36)
		-- The folders scroll between the header and DONE.
		local k = frame.k
		local page = Kit.scroll({ Name = "Rows", Position = frame.at(0, FIRST_ROW - 8), Size = frame.sz(1493, 870 - FIRST_ROW), AutomaticCanvasSize = Enum.AutomaticSize.None, CanvasSize = UDim2.fromOffset(0, math.round((lastBottom - FIRST_ROW + 16) * k)), ScrollBarThickness = 8, ScrollBarImageColor3 = Color3.fromHex("#1E2019"), Parent = frame.body })
		w = Dossier.rescaled(frame, k, page)
		oy = 8 - FIRST_ROW
		doneY = 946
	end
	local at, sz = w.at, w.sz

	if ox == 0 then
		-- Header.
		local fat, head = frame.at, frame.header
		Dossier.headerPaper(frame, 55, 30, 1360, 135, -0.5)
		Dossier.clip(head, frame, 92, 68, 96, -4)
		Dossier.starStamp(head, frame, 200, 115, 88, 0.72)
		Dossier.bigCaps(frame, 82, { Text = "SETTINGS", AnchorPoint = Vector2.new(0, 0.5), Position = fat(248, 95), Parent = head })
		Dossier.art("stamp_secret", { AnchorPoint = Vector2.new(0.5, 0.5), Position = fat(1120, 95), Size = frame.sz(340, 92), Rotation = -5, Parent = head })
		Dossier.tape(head, frame, "tape", 1395, 150, 110, 34, -8)
		Dossier.closeRed(head, fat(1398, 90), frame.sz(84, 84), frame.close)
	end

	-- One folder per setting; `i` counts from 1 down the page.
	local function row(i: number, iconName: string, glyph: string, title: string, note: string, ruleW: number): GuiObject
		local y = FIRST_ROW + (i - 1) * ROW_STEP
		local card = Dossier.cardArt("ImageLabel", "folder_card", { Name = title, Position = at(45 + ox, y + oy), Size = sz(1395, 156), Parent = w.body })
		local function r(x: number, yy: number): UDim2
			return at(x, yy)
		end
		Dossier.clip(card, w, 14, 70, 90, 0)
		Dossier.icon(iconName, glyph, { AnchorPoint = Vector2.new(0.5, 0.5), Position = r(100, 86), Size = sz(92, 92), Parent = card })
		Dossier.starStamp(card, w, 190, 86, 92, 0.75)
		Dossier.stencil({ Text = string.upper(title), TextSize = Dossier.capSize(w, 32), AnchorPoint = Vector2.new(0, 0.5), Position = r(268, 64), Parent = card })
		Kit.new("Frame", { BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = r(268, 90), Size = UDim2.fromOffset(math.round(ruleW * w.k), 2), Parent = card })
		Dossier.typed({ Text = note, TextColor3 = C.inkBlack, TextSize = math.round(25 * w.k), AnchorPoint = Vector2.new(0, 0.5), Position = r(268, 116), Parent = card })
		return card
	end
	-- The inset panel a row's controls sit in.
	local function inset(card: GuiObject, x: number, width: number)
		local panel = Dossier.surface("ImageLabel", "tex_manila", C.manilaDark, { Position = at(x, 22), Size = sz(width, 118), ImageColor3 = Color3.fromRGB(220, 205, 176), Parent = card })
		Kit.corner(6).Parent = panel
		Kit.stroke(C.manilaLine, 2, 0.1).Parent = panel
	end
	local function toggle(i: number, iconName: string, glyph: string, title: string, note: string, key: string)
		local card = row(i, iconName, glyph, title, note, 645)
		inset(card, 950, 400)
		local on, setOnOn = Dossier.rivetPlate(card, "On", Dossier.capSize(w, 27), false, { Name = "On", Position = at(1053, 82), Size = sz(166, 82), Parent = card })
		local off, setOffOn = Dossier.rivetPlate(card, "Off", Dossier.capSize(w, 27), false, { Name = "Off", Position = at(1240, 82), Size = sz(166, 82), Parent = card })
		local function paint()
			local value = (s :: any)[key] == true
			setOnOn(value)
			setOffOn(not value)
		end
		on.Activated:Connect(function()
			(s :: any)[key] = true
			paint()
			onChange(table.clone(s))
		end)
		off.Activated:Connect(function()
			(s :: any)[key] = false
			paint()
			onChange(table.clone(s))
		end)
		paint()
	end

	-- Music: a volume slider (0 mutes). The knob follows a press or drag
	-- anywhere on the track; the profile save waits for the last change.
	local musicCard = row(1, "set_music", "music", "Music", "Background music volume.", 440)
	inset(musicCard, 790, 560)
	local track = Kit.new("TextButton", { Name = "Track", Text = "", AutoButtonColor = false, BackgroundColor3 = C.inkBlack, BackgroundTransparency = 0.75, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 0.5), Position = at(830, 82), Size = sz(390, 18), Parent = musicCard })
	Kit.corner(9).Parent = track
	local fill = Kit.new("Frame", { Name = "Fill", BackgroundColor3 = C.hazard, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = track })
	Kit.corner(9).Parent = fill
	local knob = Kit.new("Frame", { Name = "Knob", BackgroundColor3 = C.sheet, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = sz(46, 46), Parent = track })
	Kit.corner(23).Parent = knob
	Kit.stroke(C.inkBlack, 3, 0).Parent = knob
	local level = Dossier.stencil({ Text = "", TextSize = Dossier.capSize(w, 27), AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0, 0.5), Position = at(1250, 82), Size = sz(90, 60), TextXAlignment = Enum.TextXAlignment.Right, Parent = musicCard })
	local function paintVolume()
		local v = if s.music then s.musicVolume else 0
		fill.Size = UDim2.fromScale(v, 1)
		knob.Position = UDim2.fromScale(v, 0.5)
		level.Text = `{math.round(v * 100)}%`
	end
	local function setFrom(x: number)
		local v = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		v = math.round(v * 20) / 20
		if v == (if s.music then s.musicVolume else 0) then
			return
		end
		s.music = v > 0
		if v > 0 then
			s.musicVolume = v
		end
		paintVolume()
		onChange(table.clone(s))
	end
	local dragging = false
	local held: { RBXScriptConnection } = {}
	track.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = true
			setFrom(input.Position.X)
		end
	end)
	table.insert(held, UserInputService.InputChanged:Connect(function(input)
		local t = input.UserInputType
		if dragging and (t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch) then
			setFrom(input.Position.X)
		end
	end))
	table.insert(held, UserInputService.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	frame.root.Destroying:Connect(function()
		for _, c in held do
			c:Disconnect()
		end
	end)
	paintVolume()

	toggle(2, "icon_sound", "sound", "Sound effects", "Clicks, alerts and battle sounds.", "sounds")

	-- Expansion sound: Pop, Suction or Off.
	local expandCard = row(3, "icon_sound", "sound", "Expansion sound", "Pops while your land grows.", 440)
	inset(expandCard, 763, 587)
	local expandSetters: { [string]: (boolean) -> () } = {}
	for i, value in PlayerSettings.EXPAND_SOUNDS do
		local label = if value == "pop" then "Pop" elseif value == "suction" then "Suction" else "Off"
		local plate, setPlate = Dossier.rivetPlate(expandCard, label, Dossier.capSize(w, 27), value == s.expandSound, { Name = label, Position = at(866 + (i - 1) * 187, 82), Size = sz(166, 82), Parent = expandCard })
		expandSetters[value] = setPlate
		plate.Activated:Connect(function()
			s.expandSound = value
			for v, set in expandSetters do
				set(v == value)
			end
			onChange(table.clone(s))
		end)
	end

	toggle(4, "set_emoji", "emoji", "Emojis", "Show the emojis other players send.", "emojis")
	toggle(5, "icon_flag", "flag", "Territory labels", "Nation names and troops on the map.", "territoryLabels")
	toggle(6, "idea_target", "target", "Select before attacking", "A tap on a nation opens its card first.", "selectBeforeAttack")

	local sizeCard = row(7, "set_eye", "eye", "UI size", "Panels and text, larger or smaller.", 440)
	local setters: { [number]: (boolean) -> () } = {}
	for i, value in PlayerSettings.UI_SCALES do
		local x = 832 + (i - 1) * 124
		local chip, setChip = Dossier.rivetPlate(sizeCard, `{math.floor(value * 100 + 0.5)}%`, Dossier.capSize(w, 24), value == s.uiScale, { Name = `Scale{i}`, Position = at(x, 90), Size = sz(114, 78), Parent = sizeCard })
		setters[value] = setChip
		chip.Activated:Connect(function()
			s.uiScale = value
			for v, set in setters do
				set(v == value)
			end
			onChange(table.clone(s))
		end)
	end

	-- How to Play (RoWorld's "Show tips again", Bruno).
	local tipsCard = row(8, "idea_crown", "question", "How to play", "The controls and the rules again.", 440)
	local open = Dossier.rivetPlate(tipsCard, "Open", Dossier.capSize(w, 27), true, { Name = "Open", Position = at(1150, 82), Size = sz(300, 82), Parent = tipsCard })
	open.Activated:Connect(function()
		if onHowToPlay then
			-- Opening it closes this window (MenuController.openModal).
			onHowToPlay()
		else
			frame.close()
		end
	end)

	-- DONE.
	local fat, fsz = frame.at, frame.sz
	local done = Dossier.plate(frame.body, "", { Name = "Done", AnchorPoint = Vector2.new(0.5, 0.5), Position = fat(760 + ox, doneY + (if ox == 0 then 0 else oy)), Size = fsz(1340, 124), Parent = frame.body }, 0)
	Dossier.bigCaps(frame, 62, { Text = "DONE", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Parent = done })
	Dossier.clicky(done, 1.02)
	Dossier.tape(done, frame, "red_tape", 40, 30, 120, 30, 36)
	Dossier.tape(done, frame, "red_tape", 1300, 30, 120, 30, -36)
	done.Activated:Connect(frame.close)
	return (frame :: any) :: Kit.Modal
end

return Settings
