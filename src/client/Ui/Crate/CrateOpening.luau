--!strict
-- The supply crate opening (Bruno, 2026-11-02; storyboard on the Claude Design
-- canvas "Supply Crate Opening"). The crate drops onto the desk and rattles.
-- It takes three taps: each makes it crouch, jump and rattle, and breaks
-- something (the catches, then the straps, then the lid blows off). It spins
-- to face the camera as it pushes in, and a soft halo blooms over the open
-- crate. Each card, back first, peeks up out of the glow over the rim (the
-- camera looking down into the crate), rises clear of the crate, moves out
-- over the front edge and drops in front of it, flipping sideways like a
-- playing card as it falls (the item's print on its face). Settled, it
-- becomes a 2D card at the same place and its name and rarity fade in. A
-- 3-pack's cards come one at a time, rarest last: tap the first and
-- it slides right, tap the second and it slides left, the last stays in the
-- middle. The crate dims behind a landed card. A Legendary starts as the
-- normal crate and turns into the dark one while it waits for the first tap.
-- SKIP shows the result at once.
--
-- The 3D plays in one ViewportFrame, the card inside it with the crate so the
-- walls and glow hide it until it comes out (Bruno: it "spawns in over the
-- crate" in a view of its own); the crate dims once the 2D card has taken
-- over. Poses come from CrateTrack (exported from
-- art/crate/crate.blend), timing from CrateTimeline. A ViewportFrame draws no
-- particles or lights, so the halo, flashes, sparks and dust are 2D on top.
-- Everything is cleaned up on close.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared.Store.Catalog)

local Art = require(script.Parent.Parent.Art)
local Dossier = require(script.Parent.Parent.Dossier)
local Kit = require(script.Parent.Parent.Kit)
local Theme = require(script.Parent.Parent.Theme)
local UiAssets = require(script.Parent.Parent.UiAssets)
local CrateTimeline = require(script.Parent.CrateTimeline)
local CrateTrack = require(script.Parent.CrateTrack)

local C = Theme.color
local stencil = Dossier.stencil

local CrateOpening = {}

local PARTS = { "Body", "Lid", "Strap0", "Strap1", "Catch0", "Catch1" }
local CARD_SIZE = Vector3.new(0.62, 0.82, 0.012)
-- The glowing edge: wider than the card, thinner, centred, so both faces show.
local EDGE_SIZE = CARD_SIZE + Vector3.new(0.05, 0.05, -0.006)
-- Where things are on a card, as fractions of it from its top-left: the
-- picture window and the name banner of the front art (art/crate/card_art.py
-- draws them there; change both together).
local CARD_LAYOUT = {
	window = { x = 0.045 / 0.62, y = 0.045 / 0.82, w = 0.53 / 0.62, h = 0.5 / 0.82 },
	banner = { x = 0.03 / 0.62, y = (0.41 + 0.152) / 0.82, w = 0.56 / 0.62, h = 0.13 / 0.82 },
}
-- The print on the card's face fills the window, just proud of the face.
local PRINT_SIZE = Vector3.new(CARD_SIZE.X * CARD_LAYOUT.window.w, CARD_SIZE.Y * CARD_LAYOUT.window.h, 0.002)
local PRINT_AT = Vector3.new(0, CARD_SIZE.Y * (0.5 - CARD_LAYOUT.window.y - CARD_LAYOUT.window.h / 2), CARD_SIZE.Z / 2 + 0.001)
local RARITY_SWATCH: { [string]: Color3 } = {
	common = Color3.fromHex("#C9C6BC"),
	rare = Color3.fromHex("#2F8BF0"),
	epic = Color3.fromHex("#A132F0"),
	legendary = Color3.fromHex("#F2B724"),
}
local RARITY_INK: { [string]: Color3 } = {
	common = Color3.fromHex("#6B6B66"),
	rare = Color3.fromHex("#2C66C9"),
	epic = Color3.fromHex("#8B2FD1"),
	legendary = Color3.fromHex("#E2761B"),
}
local GOLD = Color3.fromRGB(255, 196, 70)
local WOOD = Color3.fromRGB(120, 84, 48)
local DIM = Color3.fromRGB(105, 103, 96)
-- The depot's view is tinted down so the room stays in shadow (Bruno: moody),
-- and further when a card lands.
local DEPOT_TINT = Color3.fromRGB(120, 116, 108)
local DEPOT_DIM = Color3.fromRGB(48, 47, 44)
-- The card's picture window (card_art.py's dark well), behind a flag's margins.
local WELL = Color3.fromRGB(8, 8, 9)

export type Options = {
	items: { string },
	sound: ((string) -> ())?,
	onDone: () -> (),
}

-- True once the server has loaded both crates.
function CrateOpening.ready(): boolean
	local models = ReplicatedStorage:FindFirstChild("CrateModels")
	local std = models and models:FindFirstChild("Standard")
	local leg = models and models:FindFirstChild("Legendary")
	return std ~= nil and leg ~= nil and #std:GetChildren() >= 7 and #leg:GetChildren() >= 7
end

local function tween(obj: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local t = TweenService:Create(obj, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function color(rgb: { number }): Color3
	return Color3.new(rgb[1], rgb[2], rgb[3])
end

-- A screen point for a world point, through a viewport's camera.
local function project(cam: Camera, size: Vector2, p: Vector3): Vector2
	local rel = cam.CFrame:PointToObjectSpace(p)
	local tanY = math.tan(math.rad(cam.FieldOfView) / 2)
	local depth = math.max(-rel.Z, 1e-3)
	local nx = rel.X / (depth * tanY * size.X / size.Y)
	local ny = rel.Y / (depth * tanY)
	return Vector2.new((nx + 1) / 2 * size.X, (1 - ny) / 2 * size.Y)
end

-- Plays the opening for `items` (one, or three for a 3-pack) in its own
-- ScreenGui. Returns nil when the crates aren't loaded (show the card
-- instead). The result closes like a Kit.Modal.
function CrateOpening.play(opts: Options): Kit.Modal?
	if not CrateOpening.ready() or #opts.items == 0 then
		return nil
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local sound = opts.sound or function(_: string) end
	local items = opts.items
	local n = #items
	local rarities = {}
	for i, id in items do
		local c = Catalog.get(id)
		rarities[i] = if c and c.rarity then c.rarity else "common"
	end
	local order = CrateTimeline.order(rarities)
	local look = CrateTimeline.LOOK[CrateTimeline.best(rarities)]
	local glow = color(look.glow)
	local first = CrateTrack.firstFrame
	local segments = CrateTrack.segments
	local connections: { RBXScriptConnection } = {}
	local closed = false
	-- Studio only: Workspace's CrateTimeScale attribute (0.02-1, read every
	-- frame so it can change mid-opening) plays it in slow motion.
	local studio = RunService:IsStudio()
	local function slow(): number
		return if studio then math.clamp(tonumber(workspace:GetAttribute("CrateTimeScale")) or 1, 0.02, 1) else 1
	end

	local gui = Kit.new("ScreenGui", {
		Name = "CrateOpening",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ScreenInsets = Enum.ScreenInsets.None,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 20,
	}) :: ScreenGui
	local root = Kit.new("Frame", { Name = "Root", BackgroundColor3 = C.desk, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = gui }) :: Frame
	gui.Parent = playerGui -- so sizes below read the real screen

	local function viewport(name: string, z: number): (ViewportFrame, Camera)
		local v = Kit.new("ViewportFrame", {
			Name = name,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = z,
			Ambient = Color3.fromRGB(150, 146, 136),
			LightColor = Color3.fromRGB(255, 238, 210),
			LightDirection = Vector3.new(0.55, -0.7, 0.45),
			Parent = root,
		}) :: ViewportFrame
		local cam = Instance.new("Camera")
		cam.Parent = v
		v.CurrentCamera = cam
		return v, cam
	end
	-- The depot has a view of its own behind the crate's (it is always behind
	-- the crate and the card), darkened so the room stays in shadow while the
	-- crate keeps its light. Its camera follows the crate's.
	local depotView, depotCam = viewport("Depot", 2)
	depotView.ImageColor3 = DEPOT_TINT
	local crateView, crateCam = viewport("Crate", 2)
	-- A soft vignette over the depot, under the halo and the cards: the room
	-- falls into shadow at the edges.
	-- (A gradient's 0 end is at its Rotation's start: 90 top, 270 bottom, 0 left, 180 right.)
	local VIGNETTE: { { rotation: number, anchor: Vector2, size: UDim2 } } = {
		{ rotation = 90, anchor = Vector2.new(0, 0), size = UDim2.fromScale(1, 0.28) },
		{ rotation = 270, anchor = Vector2.new(0, 1), size = UDim2.fromScale(1, 0.28) },
		{ rotation = 0, anchor = Vector2.new(0, 0), size = UDim2.fromScale(0.2, 1) },
		{ rotation = 180, anchor = Vector2.new(1, 0), size = UDim2.fromScale(0.2, 1) },
	}
	for _, edge in VIGNETTE do
		local f = Kit.new("Frame", {
			Name = "Vignette",
			BackgroundColor3 = Color3.new(0, 0, 0),
			BorderSizePixel = 0,
			AnchorPoint = edge.anchor,
			Position = UDim2.fromScale(edge.anchor.X, edge.anchor.Y),
			Size = edge.size,
			ZIndex = 2,
			Parent = root,
		})
		local g = Instance.new("UIGradient")
		g.Rotation = edge.rotation
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
	end
	-- The halo sits behind the card, over the crate's mouth.
	local haze = Kit.new("ImageLabel", {
		Name = "Haze",
		Image = UiAssets.dossier.crate_haze,
		ImageColor3 = glow,
		ImageTransparency = 1,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		ZIndex = 3,
		Parent = root,
	}) :: ImageLabel
	local flash = Kit.new("Frame", { Name = "Flash", BackgroundColor3 = glow, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = root }) :: Frame
	local fx = Kit.new("Frame", { Name = "Sparks", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 6, Parent = root }) :: Frame
	local ui = Kit.new("Frame", { Name = "Ui", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 7, Parent = root }) :: Frame

	-- The supply depot (or a plain desk until it has loaded), then both crates
	-- in it (the dark one hidden until it's needed).
	local models = ReplicatedStorage:FindFirstChild("CrateModels") :: Folder
	local depot = models:FindFirstChild("Depot")
	if depot then
		depot:Clone().Parent = depotView
	else
		local desk = Instance.new("Part")
		desk.Anchored = true
		desk.Size = Vector3.new(40, 0.1, 40)
		desk.CFrame = CFrame.new(0, -0.05, 0)
		desk.Color = Color3.fromRGB(38, 40, 26)
		desk.Material = Enum.Material.SmoothPlastic
		desk.Parent = depotView
	end
	local function cloneSet(name: string): { [string]: MeshPart }
		local model = (models:FindFirstChild(name) :: Model):Clone()
		model.Parent = crateView
		local set = {}
		for _, p in model:GetChildren() do
			if p:IsA("MeshPart") then
				set[p.Name] = p
			end
		end
		return set
	end
	local std, leg = cloneSet("Standard"), cloneSet("Legendary")
	local base: { [Instance]: Vector3 } = {}
	for _, set in { std, leg } do
		for _, p in set do
			base[p] = p.Size
		end
	end
	-- Light: the standard crate's inner glow; Rare and up borrow the dark
	-- crate's seams (same planks) in their colour, leaking while it waits.
	local stdGlow, legGlow = std.Glow, leg.Glow
	stdGlow.Material = Enum.Material.Neon
	stdGlow.Color = glow
	legGlow.Material = Enum.Material.Neon
	legGlow.Color = color(CrateTimeline.LOOK.legendary.glow)
	local seams: MeshPart? = nil
	if look.seams and not look.legendary then
		local s = legGlow:Clone()
		s.Color = glow
		s.Transparency = 1
		s.Parent = stdGlow.Parent
		base[s] = base[legGlow]
		seams = s
	end
	local dark = false -- the dark crate is showing
	local function showSet()
		for _, name in PARTS do
			std[name].Transparency = if dark then 1 else 0
			leg[name].Transparency = if dark then 0 else 1
		end
		stdGlow.Transparency = if dark then 1 else 0
		legGlow.Transparency = if dark then 0.1 else 1
	end
	showSet()

	-- One 3D card, reused for each item (Bruno: a collectible trading card that
	-- flips sideways like a playing card). Its back art (the rarity frame, a
	-- star) is on the Front face, which faces the camera as it comes out; its
	-- front art (frame, picture window, name banner) is on the Back face, the
	-- side it turns to as it drops, with the item's print in the window. A
	-- glowing edge in its colour sits behind both. As it settles the 2D card
	-- fades in over it, the same art at the same place, adding the name.
	local card = Instance.new("Part")
	card.Anchored = true
	card.CanCollide = false
	card.Material = Enum.Material.SmoothPlastic
	card.Color = C.inkBlack
	card.Size = CARD_SIZE
	card.Parent = crateView -- in the crate's view, so its walls and glow hide it until it comes out
	local back = Instance.new("Decal")
	back.Face = Enum.NormalId.Front
	back.Parent = card
	local front = Instance.new("Decal")
	front.Face = Enum.NormalId.Back
	front.Parent = card
	local print_ = Instance.new("Part")
	print_.Anchored = true
	print_.CanCollide = false
	print_.Material = Enum.Material.SmoothPlastic
	print_.Color = WELL
	print_.Size = PRINT_SIZE
	print_.Parent = crateView
	local printTex = Instance.new("Texture")
	printTex.Face = Enum.NormalId.Back
	printTex.Parent = print_
	local edge = Instance.new("Part")
	edge.Anchored = true
	edge.CanCollide = false
	edge.Material = Enum.Material.Neon
	edge.Size = EDGE_SIZE
	edge.Parent = crateView

	-- Posing ------------------------------------------------------------------------------
	local function pose(track: string, frame: number): (CFrame, Vector3)
		local s = CrateTimeline.sample(CrateTrack.parts[track], first, frame)
		return CFrame.new(s[1], s[2], s[3], s[4], s[5], s[6], s[7]), Vector3.new(s[8], s[9], s[10])
	end
	local function place(part: BasePart, track: string, offset: { number }, frame: number, grow: number?)
		local cf, sc = pose(track, frame)
		part.CFrame = cf * CFrame.new(offset[1] * sc.X, offset[2] * sc.Y, offset[3] * sc.Z)
		part.Size = (base[part] or part.Size) * sc * (grow or 1)
	end
	local overlays: { [string]: MeshPart } = {} -- legendary flares, following their part
	local frameNow = first
	local cardShown = false
	local edgeFade = 0 -- the 3D card's glow fades out as the 2D card fades in
	-- A pack's next card starts from the low camera: ease into the track.
	local camFrom: CFrame? = nil
	local camBlend = 0
	local function aspect(): number
		local size = root.AbsoluteSize
		return if size.Y > 0 then size.X / size.Y else 16 / 9
	end
	-- The crate at `frame`; the card at `cardFrame` (it waits inside the
	-- crate at the start of its rise until its turn).
	local function poseAll(frame: number, cardFrame: number?)
		frameNow = frame
		for _, name in PARTS do
			local hide = CrateTimeline.hidden(CrateTrack.hidden[name], frame)
			for _, set in { std, leg } do
				place(set[name], name, CrateTrack.offset[name], frame)
			end
			if hide then
				std[name].Transparency, leg[name].Transparency = 1, 1
			end
			local o = overlays[name]
			if o then
				place(o, name, CrateTrack.offset[name], frame, 1.03)
				if hide then
					o.Transparency = 1
				end
			end
		end
		place(stdGlow, "Body", CrateTrack.offset.Glow, frame)
		place(legGlow, "Body", CrateTrack.offset.LegendaryGlow, frame)
		if seams then
			place(seams, "Body", CrateTrack.offset.LegendaryGlow, frame)
		end
		local cam = CrateTimeline.camera(CrateTrack.camera, first, frame)
		local cf = CFrame.lookAt(Vector3.new(cam[1], cam[2], cam[3]), Vector3.new(cam[4], cam[5], cam[6]))
		if camFrom then
			local a = math.clamp(camBlend / 0.35, 0, 1)
			cf = camFrom:Lerp(cf, a * a * (3 - 2 * a))
			if a >= 1 then
				camFrom = nil
			end
		end
		local fov = CrateTimeline.verticalFov(CrateTrack.horizontalFov, aspect(), CrateTrack.renderAspect)
		crateCam.CFrame, crateCam.FieldOfView = cf, fov
		depotCam.CFrame, depotCam.FieldOfView = cf, fov
		local cfc, sc = pose("Card", cardFrame or math.min(frame, CrateTimeline.CARD_RISE))
		card.CFrame, card.Size = cfc, CARD_SIZE * sc
		edge.CFrame, edge.Size = cfc, EDGE_SIZE * sc
		print_.CFrame = cfc * CFrame.new(0, PRINT_AT.Y * sc.Y, PRINT_AT.Z * sc.Z)
		print_.Size = PRINT_SIZE * sc
		local hidden = if cardShown then 0 else 1
		card.Transparency, print_.Transparency = hidden, hidden
		back.Transparency, front.Transparency, printTex.Transparency = hidden, hidden, hidden
		edge.Transparency = math.max(hidden, edgeFade)
	end
	-- Where the crate's mouth and foot are on screen (the halo, sparks, dust).
	local function mouth(lift: number?): Vector2
		local cf, sc = pose("Body", frameNow)
		return project(crateCam, root.AbsoluteSize, (cf * CFrame.new(0, (0.84 + (lift or 0)) * sc.Y, 0)).Position)
	end
	local function foot(): Vector2
		local cf = pose("Body", frameNow)
		return project(crateCam, root.AbsoluteSize, (cf * CFrame.new(0, 0.02, -0.55)).Position)
	end
	local function crateWidth(): number
		local cf = pose("Body", frameNow)
		local a = project(crateCam, root.AbsoluteSize, (cf * CFrame.new(-0.7, 0.84, 0)).Position)
		local b = project(crateCam, root.AbsoluteSize, (cf * CFrame.new(0.7, 0.84, 0)).Position)
		return (a - b).Magnitude
	end

	-- 2D effects ----------------------------------------------------------------------------
	local k = math.clamp(root.AbsoluteSize.Y / 720, 0.55, 1.8)
	local function sparks(at: Vector2, count: number, tint: Color3, spread: number, up: number, dust: boolean?)
		for _ = 1, count do
			local size = math.round((if dust then math.random(10, 22) else math.random(4, 9)) * k)
			local s = Kit.new("Frame", {
				BackgroundColor3 = tint,
				BackgroundTransparency = if dust then 0.45 else 0,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(at.X, at.Y),
				Size = UDim2.fromOffset(size, size),
				Rotation = math.random(0, 90),
				ZIndex = 6,
				Parent = fx,
			})
			if dust then
				Kit.corner(size).Parent = s
			end
			local a = math.rad(math.random(0, 360))
			local d = (math.random() * 0.6 + 0.4) * spread * k
			local target = at + Vector2.new(math.cos(a) * d, math.sin(a) * d * (if dust then 0.35 else 1) - up * k)
			local life = if dust then 0.7 + math.random() * 0.4 else 0.5 + math.random() * 0.5
			tween(s, life, { Position = UDim2.fromOffset(target.X, target.Y), BackgroundTransparency = 1, Rotation = s.Rotation + math.random(-180, 180) }, Enum.EasingStyle.Quart)
			task.delay(life, function()
				s:Destroy()
			end)
		end
	end
	local function flashOnce(strength: number, tint: Color3, seconds: number)
		flash.BackgroundColor3 = tint
		flash.BackgroundTransparency = 1 - strength
		tween(flash, seconds, { BackgroundTransparency = 1 })
	end
	local hazeOn = false
	local function hazeSize(scale: number)
		local w = crateWidth() * scale
		haze.Size = UDim2.fromOffset(w, w * 0.8)
	end

	-- Controls ------------------------------------------------------------------------------
	local catcher = Kit.new("TextButton", { Name = "Tap", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 7, Parent = ui }) :: TextButton
	local prompt = stencil({
		Name = "TapPrompt",
		Text = "TAP TO OPEN",
		TextSize = math.round(46 * k),
		TextColor3 = C.sheet,
		TextStrokeTransparency = 0.5,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.92),
		TextTransparency = 1,
		ZIndex = 12,
		Parent = ui,
	})
	local promptScale = Instance.new("UIScale")
	promptScale.Parent = prompt
	local function showPrompt(text: string?, side: boolean?)
		if text then
			prompt.Text = text
			-- Beside a landed card rather than over it.
			-- (the left is free while one waits: the first card goes right).
			prompt.Position = if side then UDim2.fromScale(0.15, 0.55) else UDim2.fromScale(0.5, 0.92)
			tween(prompt, 0.25, { TextTransparency = 0 })
		else
			tween(prompt, 0.15, { TextTransparency = 1 })
		end
	end
	local skip = Kit.new("TextButton", {
		Name = "Skip",
		Text = "SKIP  ›",
		FontFace = Theme.font.stencil,
		TextSize = math.round(26 * k),
		TextColor3 = C.sheet,
		AutoButtonColor = false,
		BackgroundColor3 = C.inkBlack,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -math.round(24 * k), 0, math.round(24 * k)),
		Size = UDim2.fromOffset(math.round(130 * k), math.round(52 * k)),
		ZIndex = 13,
		Parent = ui,
	}) :: TextButton
	Kit.corner(6).Parent = skip
	Dossier.clicky(skip, 1.06)

	local function close()
		if closed then
			return
		end
		closed = true
		for _, c in connections do
			c:Disconnect()
		end
		gui:Destroy()
		opts.onDone()
	end

	-- 2D cards ----------------------------------------------------------------------------
	local size0 = root.AbsoluteSize
	-- A pack's row: card size and the step between places.
	local function rowCard(): (number, number)
		local h = math.min(size0.Y * 0.62, size0.X * 0.25 * CARD_SIZE.Y / CARD_SIZE.X)
		return h * CARD_SIZE.X / CARD_SIZE.Y, h
	end
	local function rowPlace(k_: number): UDim2
		local w = rowCard()
		return UDim2.fromOffset(size0.X / 2 + CrateTimeline.slot(k_, n) * (w + math.round(56 * k)), size0.Y * 0.52)
	end
	local cards2d: { TextButton } = {}
	local focused: GuiObject? = nil
	-- A tap on a 2D card (it sits over the tap catcher): set by the timeline.
	local onCard: (TextButton) -> () = function(_: TextButton) end
	-- The 2D card: the same front art as the 3D card's face, the picture in
	-- its window, the name and rarity on the banner, all in a CanvasGroup so
	-- it can fade in over the 3D card. Epic and Legendary get a foil shine.
	local shines: { Tween } = {}
	local function makeCard(i: number): TextButton
		local id = items[i]
		local item = Catalog.get(id)
		local rarity = rarities[i]
		local c = Kit.new("TextButton", {
			Name = `Card{i}`,
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			ZIndex = 8,
			Parent = ui,
		}) :: TextButton
		local face = Kit.new("CanvasGroup", { Name = "Face", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 8, Parent = c }) :: CanvasGroup
		Kit.new("ImageLabel", { Name = "Art", Image = UiAssets.dossier["crate_front_" .. rarity] or "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 8, Parent = face })
		local win = CARD_LAYOUT.window
		local pic = { Position = UDim2.fromScale(win.x, win.y), Size = UDim2.fromScale(win.w, win.h), BackgroundTransparency = 0, BackgroundColor3 = WELL, BorderSizePixel = 0, ZIndex = 9, Parent = face }
		if item and item.kind == "skin" then
			Art.skin(id, pic)
		else
			Art.flagCard(id, pic)
		end
		local ban = CARD_LAYOUT.banner
		stencil({
			Text = string.upper(if item then item.name else id),
			TextScaled = true,
			TextColor3 = C.inkBlack,
			AutomaticSize = Enum.AutomaticSize.None,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			Position = UDim2.fromScale(ban.x + ban.w * 0.06, ban.y + ban.h * 0.08),
			Size = UDim2.fromScale(ban.w * 0.88, ban.h * 0.56),
			ZIndex = 10,
			Parent = face,
		})
		stencil({
			Text = string.upper(Catalog.RARITY_NAME[rarity] or rarity),
			TextScaled = true,
			TextColor3 = RARITY_INK[rarity] or C.inkBlack,
			AutomaticSize = Enum.AutomaticSize.None,
			TextXAlignment = Enum.TextXAlignment.Center,
			Position = UDim2.fromScale(ban.x + ban.w * 0.2, ban.y + ban.h * 0.62),
			Size = UDim2.fromScale(ban.w * 0.6, ban.h * 0.28),
			ZIndex = 10,
			Parent = face,
		})
		if rarity == "epic" or rarity == "legendary" then
			-- A band of light that sweeps across the card every few seconds.
			local shine = Kit.new("Frame", { Name = "Shine", BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 11, Parent = face })
			local g = Instance.new("UIGradient")
			g.Rotation = 25
			g.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.42, 1),
				NumberSequenceKeypoint.new(0.5, if rarity == "legendary" then 0.45 else 0.6),
				NumberSequenceKeypoint.new(0.58, 1),
				NumberSequenceKeypoint.new(1, 1),
			})
			g.Offset = Vector2.new(-1, 0)
			g.Parent = shine
			local sweep = TweenService:Create(g, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, false, if rarity == "legendary" then 1.2 else 2), { Offset = Vector2.new(1, 0) })
			table.insert(shines, sweep)
			c:SetAttribute("Shine", #shines)
		end
		local scale = Instance.new("UIScale")
		scale.Parent = c
		c.Activated:Connect(function()
			onCard(c)
		end)
		return c
	end
	-- A card pose's exact rectangle on screen (the card faces the camera
	-- when it settles, so it is a true rectangle there).
	local function cardRect(cf: CFrame?, sz: Vector3?): (UDim2, UDim2)
		local at, size = cf or card.CFrame, sz or card.Size
		local corners = {}
		for _, sx in { -0.5, 0.5 } do
			for _, sy in { -0.5, 0.5 } do
				table.insert(corners, project(crateCam, size0, (at * CFrame.new(size.X * sx, size.Y * sy, 0)).Position))
			end
		end
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		for _, p in corners do
			minX, minY, maxX, maxY = math.min(minX, p.X), math.min(minY, p.Y), math.max(maxX, p.X), math.max(maxY, p.Y)
		end
		return UDim2.fromOffset((minX + maxX) / 2, (minY + maxY) / 2), UDim2.fromOffset(maxX - minX, maxY - minY)
	end
	local tag: GuiObject? = nil
	local function youGot()
		if tag then
			return
		end
		local t = Dossier.sheet("ImageLabel", "header_paper", "tex_paper", C.sheet, {
			Name = "YouGot",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, math.round(18 * k)),
			Size = UDim2.fromOffset(math.round(360 * k), math.round(74 * k)),
			Rotation = -1,
			ZIndex = 8,
			Parent = ui,
		})
		stencil({ Text = "YOU GOT", TextSize = math.round(48 * k), TextColor3 = C.inkBlack, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 9, Parent = t })
		tag = t
	end
	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		showPrompt(nil)
		skip.Visible = false
		catcher.Visible = false
		youGot()
		tween(crateView, 0.45, { ImageColor3 = DIM })
		tween(depotView, 0.45, { ImageColor3 = DEPOT_DIM })
		tween(haze, 0.6, { ImageTransparency = 0.75 })
		if n > 1 then
			for k_, i in order do
				cards2d[i]:SetAttribute("Home", rowPlace(k_))
			end
		end
		local nice = Dossier.rivetPlate(ui, "NICE", math.round(40 * k), true, {
			Name = "Nice",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -math.round(28 * k), 1, -math.round(24 * k)),
			Size = UDim2.fromOffset(math.round(300 * k), math.round(86 * k)),
			ZIndex = 11,
			Parent = ui,
		})
		nice.Activated:Connect(close)
	end

	-- Timeline ------------------------------------------------------------------------------
	-- Stages: drop, wait (before tap `taps + 1`), tap, rise (card `turn`),
	-- landed (waiting for a tap on a pack's card), done.
	local stage = "drop"
	local t = 0
	local taps = 0
	local turn = 0
	local queued = false
	local landedOnce, broke, turning = false, false, false
	local rattled = -1
	local transformOn = look.legendary
	local swapped: { [string]: boolean } = {}
	local ignited = false
	local function flare(name: string)
		local src = std[name]
		local o = src:Clone()
		o.TextureID = ""
		o.Material = Enum.Material.Neon
		o.Color = GOLD
		o.Transparency = 1
		o.Parent = src.Parent
		base[o] = base[src]
		overlays[name] = o
		tween(o, CrateTimeline.FLARE, { Transparency = 0.05 })
		task.delay(CrateTimeline.FLARE, function()
			if closed then
				return
			end
			swapped[name] = true
			std[name].Transparency = 1
			leg[name].Transparency = 0
			tween(o, CrateTimeline.FLARE_FADE, { Transparency = 1 })
			task.delay(CrateTimeline.FLARE_FADE, function()
				if overlays[name] == o then
					overlays[name] = nil
				end
				o:Destroy()
			end)
		end)
		sparks(mouth(), 8, GOLD, 120, 40)
	end
	local function transform(into: number)
		for name, at in CrateTimeline.TRANSFORM do
			if into >= at and not overlays[name] and not swapped[name] then
				if name == "Body" then
					sound("menu.crateTransform")
					flashOnce(0.35, GOLD, 0.35)
					stdGlow.Transparency = 1
				end
				flare(name)
			end
		end
		if into >= CrateTimeline.SEAMS_IGNITE and not ignited then
			ignited = true
			dark = true
			legGlow.Transparency = 1
			tween(legGlow, 0.3, { Transparency = 0.1 })
			sparks(mouth(), 14, GOLD, 200, 30)
		end
	end
	local function ready(): boolean
		return not transformOn or ignited
	end
	-- The item's picture on the 3D card's face: its cell of the page, cropped
	-- to the print's shape and centred, as the 2D card's ImageLabel crops it.
	local function setPrint(id: string)
		local cell = Art.cell(id, true)
		if cell == nil then
			printTex.Texture = ""
			return
		end
		local _, sc = pose("Card", CrateTimeline.CARD_SETTLED)
		local fw, fh = PRINT_SIZE.X * sc.X, PRINT_SIZE.Y * sc.Y
		local cx, cy, cw, ch = cell.x, cell.y, cell.w, cell.h
		if cw / ch > fw / fh then
			local nw = ch * fw / fh
			cx += (cw - nw) / 2
			cw = nw
		else
			local nh = cw * fh / fw
			cy += (ch - nh) / 2
			ch = nh
		end
		-- The page tiles from the face's top-left; a positive offset moves the
		-- face into the page (checked in Studio). The cells' see-through
		-- margins show the print's paper, as the 2D card shows its own.
		printTex.Texture = cell.image
		printTex.StudsPerTileU = fw * cell.pageW / cw
		printTex.StudsPerTileV = fh * cell.pageH / ch
		printTex.OffsetStudsU = cx * fw / cw
		printTex.OffsetStudsV = cy * fh / ch
	end
	local function startRise()
		turn += 1
		stage = "rise"
		t = 0
		turning = false
		local i = order[turn]
		setPrint(items[i])
		front.Texture = UiAssets.dossier["crate_front_" .. rarities[i]] or ""
		back.Texture = UiAssets.dossier["crate_back_" .. rarities[i]] or ""
		edge.Color = RARITY_SWATCH[rarities[i]] or glow
		edgeFade = 0
		cardShown = true
		camFrom = if turn > 1 then crateCam.CFrame else nil
		camBlend = 0
		tween(crateView, 0.3, { ImageColor3 = Color3.new(1, 1, 1) })
		tween(depotView, 0.3, { ImageColor3 = DEPOT_TINT })
		sound("menu.cardRise")
	end
	-- The 2D card over the 3D one as it lands: the same place every frame,
	-- fading in (`a` 0 to 1) while the 3D card's glow fades out.
	local function overlay(a: number): TextButton
		local i = order[turn]
		local existing: TextButton? = cards2d[i]
		local c = existing or makeCard(i)
		cards2d[i] = c
		c.Position, c.Size = cardRect()
		local face = c:FindFirstChild("Face") :: CanvasGroup
		face.GroupTransparency = 1 - a
		edgeFade = a
		return c
	end
	local function startShine(c: TextButton)
		local s = c:GetAttribute("Shine")
		if type(s) == "number" and shines[s] then
			shines[s]:Play()
		end
	end
	-- Settled face up: the 2D card has faded in exactly over the 3D card,
	-- which goes; the crate dims behind it.
	local function settle()
		stage = "landed"
		local c = overlay(1)
		cardShown = false
		poseAll(frameNow, CrateTimeline.CARD_SETTLED)
		startShine(c)
		tween(crateView, 0.4, { ImageColor3 = DIM })
		tween(depotView, 0.4, { ImageColor3 = DEPOT_DIM })
		sound("menu.reveal")
		youGot()
		if n == 1 then
			finish()
		elseif turn == n then
			-- The last card settles into the middle of the row.
			local w, h = rowCard()
			tween(c, 0.45, { Position = rowPlace(turn), Size = UDim2.fromOffset(w, h) }, Enum.EasingStyle.Back)
			finish()
		else
			showPrompt("TAP TO KEEP", true)
		end
	end
	-- A tapped pack card slides to its place; then the next one rises.
	local function moveAside()
		stage = "moving"
		showPrompt(nil)
		local c = cards2d[order[turn]]
		local w, h = rowCard()
		sound("menu.cardSlide")
		tween(c, 0.4, { Position = rowPlace(turn), Size = UDim2.fromOffset(w, h) }, Enum.EasingStyle.Back)
		task.delay(0.25, function()
			if not closed and not finished then
				startRise()
			end
		end)
	end
	local function startTap()
		taps += 1
		stage = "tap"
		t = 0
		broke = false
		showPrompt(nil)
		sound("menu.crateTap")
		sparks(foot(), 6 + taps * 3, Color3.fromRGB(150, 140, 115), 120 + taps * 30, 6, true)
	end
	local function tap()
		if stage == "wait" and ready() then
			startTap()
		elseif stage == "landed" then
			moveAside()
		elseif stage == "drop" or stage == "wait" or stage == "tap" then
			queued = true
		end
	end
	local function skipToEnd()
		if finished then
			return
		end
		if look.legendary then
			dark = true
			for _, name in PARTS do
				local o = overlays[name]
				if o then
					o:Destroy()
					overlays[name] = nil
				end
			end
			showSet()
			ignited = true
		end
		stage = "done"
		cardShown = false
		poseAll(segments.card[2], CrateTimeline.CARD_SETTLED)
		hazeOn = true
		local m = mouth(0.25)
		haze.Position = UDim2.fromOffset(m.X, m.Y)
		hazeSize(look.haze)
		haze.ImageTransparency = 0.55
		local w, h = rowCard()
		for k_, i in order do
			local c = cards2d[i] or makeCard(i)
			cards2d[i] = c
			local face = c:FindFirstChild("Face") :: CanvasGroup
			face.GroupTransparency = 0
			if n == 1 then
				c.Position, c.Size = cardRect()
			else
				c.Position, c.Size = rowPlace(k_), UDim2.fromOffset(w, h)
			end
			startShine(c)
		end
		finish()
	end
	-- A pack's waiting card goes aside; once all are in, a card comes forward
	-- (and goes back on a second tap).
	onCard = function(c: TextButton)
		if stage == "landed" and cards2d[order[turn]] == c then
			moveAside()
			return
		end
		if not finished or n == 1 then
			return
		end
		local scale = c:FindFirstChildOfClass("UIScale") :: UIScale
		if focused == c then
			focused = nil
			c.ZIndex = 8
			tween(c, 0.25, { Position = c:GetAttribute("Home") :: UDim2 })
			tween(scale, 0.25, { Scale = 1 })
			return
		end
		if focused then
			local other = focused :: GuiObject
			other.ZIndex = 8
			tween(other:FindFirstChildOfClass("UIScale") :: UIScale, 0.2, { Scale = 1 })
			tween(other, 0.2, { Position = other:GetAttribute("Home") :: UDim2 })
		end
		focused = c
		c.ZIndex = 10
		tween(c, 0.3, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Back)
		tween(scale, 0.3, { Scale = 1.5 }, Enum.EasingStyle.Back)
	end
	table.insert(connections, catcher.Activated:Connect(tap))
	table.insert(connections, skip.Activated:Connect(skipToEnd))
	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.Space or key == Enum.KeyCode.Return or key == Enum.KeyCode.ButtonA then
			if finished then
				close()
			else
				tap()
			end
		elseif key == Enum.KeyCode.ButtonB or key == Enum.KeyCode.Escape then
			skipToEnd()
		end
	end))

	local WAITS = { segments.wait0, segments.wait1, segments.wait2 }
	local TAPS = { segments.tap1, segments.tap2, segments.tap3 }
	table.insert(connections, RunService.RenderStepped:Connect(function(dt: number)
		if closed or stage == "done" then
			return
		end
		t += dt * slow()
		if hazeOn then
			local m = mouth(0.25)
			haze.Position = UDim2.fromOffset(m.X, m.Y)
		end
		if stage == "drop" then
			local frame = CrateTimeline.at(segments.drop, t)
			poseAll(frame)
			if not landedOnce and frame >= CrateTimeline.LAND then
				landedOnce = true
				sound("menu.crateLand")
				sparks(foot(), 12, Color3.fromRGB(150, 140, 115), 170, 10, true)
			end
			if frame >= segments.drop[2] then
				stage = "wait"
				t = 0
				showPrompt("TAP TO OPEN")
			end
		elseif stage == "wait" then
			local seg = WAITS[taps + 1]
			local frame = CrateTimeline.at(seg, t, true)
			poseAll(frame)
			local loop = math.floor(t / ((seg[2] - seg[1]) / CrateTimeline.FPS))
			if loop ~= rattled and frame >= seg[1] + 4 then
				rattled = loop
				sound("menu.crateRattle")
			end
			promptScale.Scale = 1 + 0.05 * math.sin(t * 5)
			local pulse = CrateTimeline.LEAK[taps + 1] + 0.12 * math.sin(t * 6)
			if seams then
				seams.Transparency = pulse
			end
			if transformOn and taps == 0 then
				local into = t - CrateTimeline.TRANSFORM_DELAY
				if into >= 0 then
					transform(into)
				end
			end
			if ignited then
				legGlow.Transparency = pulse * 0.7
			end
			if queued and ready() then
				queued = false
				startTap()
			end
		elseif stage == "tap" then
			local seg = TAPS[taps]
			local frame = CrateTimeline.at(seg, t)
			poseAll(frame)
			if not broke and frame >= CrateTimeline.TAP_BREAK[taps] then
				broke = true
				if taps == 1 then
					sound("menu.crateCatch")
					sparks(mouth(-0.1), 10, Color3.fromRGB(200, 190, 170), 140, 30)
				elseif taps == 2 then
					sound("menu.crateStrap")
					sparks(mouth(), 16, Color3.fromRGB(230, 220, 200), 220, 50)
					sparks(mouth(), 8, WOOD, 160, 20)
				else
					sound("menu.crateOpen")
					flashOnce(if look.legendary then 0.6 else 0.35, glow, if look.legendary then 0.7 else 0.45)
					sparks(mouth(), look.sparks, glow, if look.legendary then 380 else 260, 70)
					sparks(mouth(), 10, WOOD, 200, 30)
					-- The halo blooms over the open crate and settles.
					hazeOn = true
					local m = mouth(0.25)
					haze.Position = UDim2.fromOffset(m.X, m.Y)
					hazeSize(look.haze * 0.5)
					haze.ImageTransparency = 0.05
					local w = crateWidth() * look.haze
					tween(haze, 0.9, { Size = UDim2.fromOffset(w, w * 0.8), ImageTransparency = 0.45 }, Enum.EasingStyle.Quint)
					if seams then
						tween(seams, 0.3, { Transparency = 0.1 })
					end
				end
			end
			if frame >= seg[2] then
				if taps < 3 then
					stage = "wait"
					t = 0
					showPrompt(if taps == 1 then "TAP AGAIN" else "ONE MORE")
					if queued then
						queued = false
						startTap()
					end
				else
					queued = false
					startRise()
				end
			end
		elseif stage == "rise" then
			-- The crate holds its last pose over these frames; the camera
			-- follows the card up and back down.
			local cardFrame = CrateTimeline.at(segments.card, t)
			camBlend = t
			poseAll(cardFrame, cardFrame)
			if not turning and cardFrame >= CrateTimeline.CARD_TURN[1] then
				turning = true
				sound("menu.cardFlip")
			end
			if cardFrame >= CrateTimeline.CARD_FADE and cardFrame < CrateTimeline.CARD_SETTLED then
				local a = (cardFrame - CrateTimeline.CARD_FADE) / (CrateTimeline.CARD_SETTLED - CrateTimeline.CARD_FADE)
				overlay(a * a * (3 - 2 * a))
			end
			if cardFrame >= CrateTimeline.CARD_SETTLED then
				settle()
			end
		end
	end))

	poseAll(first)
	return ({ root = root, window = root, header = root, body = ui, close = close } :: any) :: Kit.Modal
end

return CrateOpening
