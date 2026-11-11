--!strict
-- Visual tokens for every screen: the "Mix" direction Bruno chose on
-- 2026-10-20 (docs/design/ui-concepts-v3, PLAN_WELCOME M6). A modern navy
-- layout with warm ivory cards, thin brass hairlines and teal for the primary
-- action and the selection; coral marks danger. Large type, rounded corners.
--
-- Colours are semantic. On ivory cards use ink*; on navy rails use cream*.
-- Older names (olive, signal, ...) are kept and mapped onto this palette.

local Theme = {}

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

Theme.color = {
	-- Surfaces
	olive = hex("#17384B"), -- navy rails: top bar, command bar, tabs
	oliveLight = hex("#22495F"),
	oliveLine = hex("#3A6178"),
	navyDeep = hex("#0F2633"),
	paper = hex("#F2E8D1"), -- ivory cards
	paperDeep = hex("#E7DAB9"), -- chips, inset rows
	paperLine = hex("#C5A465"), -- brass hairlines
	shadow = hex("#0B1A24"),
	-- Text
	ink = hex("#1D2B36"), -- on ivory
	inkSoft = hex("#56636D"),
	inkMuted = hex("#8C8A7C"),
	cream = hex("#F7F1E3"), -- on navy
	creamSoft = hex("#A9BFCB"),
	-- Signals
	signal = hex("#1E8C86"), -- teal: primary actions and the selection
	signalDark = hex("#156660"),
	coral = hex("#D9644A"), -- danger, incoming attacks
	coralDark = hex("#A9432D"),
	alert = hex("#F4CDBF"), -- incoming attack rows
	alertInk = hex("#8A2A14"),
	good = hex("#5E9E55"),
	goodLight = hex("#A9D18C"),
	gold = hex("#E3B54C"),
	player = hex("#4FB7B0"), -- your nation (matches the map's inner glow family)

	-- Legacy names still used by older modules (map them onto the new palette).
	background = hex("#0F2633"),
	panel = hex("#F2E8D1"),
	panelOpaque = hex("#F2E8D1"),
	panelRaised = hex("#E7DAB9"),
	border = hex("#C5A465"),
	borderSoft = hex("#C5A465"),
	text = hex("#1D2B36"),
	textSecondary = hex("#56636D"),
	textMuted = hex("#8C8A7C"),
	brass = hex("#C5A465"),
	brassDark = hex("#9C7F45"),
	playerFront = hex("#2F8C86"),
	healthy = hex("#3F7F3A"),
	enemy = hex("#B5401C"),
	danger = hex("#B5401C"),

	-- 2026-10-24 RoFront-level pass (docs/design/rofront-ui-pass.md): dark
	-- navy glass panels, an amber primary action, cyan for live and section
	-- labels, green for Robux purchases, gold stars.
	scrim = hex("#05080F"),
	surface = hex("#121827"), -- panels and modals
	surface2 = hex("#1A2134"), -- rows, cards, chips
	surface3 = hex("#242D44"), -- hover, pressed
	line = hex("#2B3651"), -- hairlines
	line2 = hex("#3D4B6C"),
	fg = hex("#F4F6FB"), -- text on dark
	fgSoft = hex("#B3BDD5"),
	fgMuted = hex("#7A86A4"),
	amber = hex("#FFB534"), -- the one primary action
	amberDark = hex("#D2850F"),
	amberInk = hex("#1C1405"),
	cyan = hex("#4CC4F0"), -- live, section labels, JOIN
	cyanDark = hex("#1C7FA8"),
	buy = hex("#2EA35B"), -- Robux buttons
	buyDark = hex("#207B43"),
	star = hex("#FFC93C"),
	red = hex("#FF5B57"),
	redDark = hex("#B93633"),
	ok = hex("#46D17B"),
	violet = hex("#6E3FD6"),
	violetDark = hex("#45238F"),
	rarityCommon = hex("#9AA4B8"),
	rarityRare = hex("#4F8DFF"),
	rarityEpic = hex("#B05CFF"),
	rarityLegendary = hex("#FFB534"),

	-- 2026-10-26 dossier main menu (Bruno's concept, docs/design/dossier-ui):
	-- manila folders on an olive board, typed paper, red stamps, hazard yellow.
	manila = hex("#D9C79C"),
	manilaDark = hex("#C2AC7B"),
	manilaLine = hex("#9C8656"),
	sheet = hex("#F2ECDD"), -- typed paper and pinned notes
	sheetLine = hex("#CFC3A6"),
	board = hex("#8E8C6E"),
	boardDark = hex("#6F6D53"),
	desk = hex("#1E2019"),
	inkBlack = hex("#1F1D19"),
	inkFaded = hex("#5E5748"),
	stamp = hex("#B8322A"),
	hazard = hex("#E9BE2A"),
	tape = hex("#EFE6C6"),
	mapFrame = hex("#2C3333"),
}

Theme.font = {
	-- Condensed caps for numbers, labels and buttons.
	label = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Regular),
	labelBold = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold),
	labelSemibold = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.SemiBold),
	-- Running text.
	body = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Regular),
	bodySemibold = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.SemiBold),
	bodyBold = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold),
	-- Kept for map-style titles (results, nation names in cards).
	display = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold),
	-- 2026-10-24 pass: wide caps for titles and buttons, Builder Sans for the rest.
	head = Font.new("rbxasset://fonts/families/BuilderExtended.json", Enum.FontWeight.Bold),
	headHeavy = Font.new("rbxasset://fonts/families/BuilderExtended.json", Enum.FontWeight.ExtraBold),
	headSemi = Font.new("rbxasset://fonts/families/BuilderExtended.json", Enum.FontWeight.SemiBold),
	ui = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
	uiSemi = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.SemiBold),
	uiBold = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
	uiHeavy = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold),
	-- 2026-10-26 dossier: heavy condensed caps (Roblox ships no stencil face)
	-- and a typewriter for labels on paper.
	stencil = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold),
	typewriter = Font.new("rbxasset://fonts/families/SpecialElite.json"),
}

-- The 2026-10-24 screens are laid out on a 1920x1080 canvas, scaled
-- uniformly to the screen (Root.luau).
Theme.CANVAS_W = 1920
Theme.CANVAS_H = 1080
-- Phones (Root.compact) use a canvas this tall instead, as wide as the screen.
Theme.COMPACT_H = 540

Theme.size = {
	body = 16,
	small = 13,
	title = 20,
	big = 28,
	radius = 10,
	gap = 8,
	pad = 12,
	touch = 44,
	bar = 52, -- top rail
	command = 84, -- bottom command bar
}

-- Design canvas: 1280x720 on desktop; short landscape phones use a 430 px tall
-- canvas so text and touch targets keep a usable physical size.
Theme.DESIGN_W = 1280
Theme.DESIGN_H = 720
Theme.PHONE_DESIGN_H = 430

function Theme.hex(c: Color3): string
	return "#" .. c:ToHex()
end

return Theme
