--!strict
-- Pictures for store items, from the uploaded pages: flags (FlagArt),
-- skin previews and Arsenal cards (StoreArt). Each returns an ImageLabel
-- showing one cell of a page. Arsenal cards with a dossier photo (Bruno,
-- 2026-10-27: "pinned recon photo") show that instead.

local FlagArt = require(script.Parent.FlagArt)
local Kit = require(script.Parent.Kit)
local StoreArt = require(script.Parent.StoreArt)
local UiAssets = require(script.Parent.UiAssets)

local Art = {}

local function cellImage(image: string, x: number, y: number, w: number, h: number, props: { [string]: any }): ImageLabel
	local label = Kit.new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = image,
		ImageRectOffset = Vector2.new(x, y),
		ImageRectSize = Vector2.new(w, h),
		ScaleType = Enum.ScaleType.Crop,
	})
	for k, v in props do
		if k ~= "Parent" then
			(label :: any)[k] = v
		end
	end
	label.Parent = props.Parent
	return label
end

function Art.flag(id: string, props: { [string]: any }): ImageLabel
	local cell = FlagArt.cells[id]
	if cell == nil then
		return cellImage("", 0, 0, 0, 0, props)
	end
	local own = string.sub(id, 1, 2) == "o_"
	local size = if own then FlagArt.own else FlagArt.country
	local pages = if own then FlagArt.OWN_PAGES else FlagArt.COUNTRY_PAGES
	-- 2 px of padding around each picture in its cell.
	return cellImage(pages[cell[1]] or "", cell[2] * size.w + 2, cell[3] * size.h + 2, size.w - 4, size.h - 4, props)
end

-- A flag big and whole, for a crate card's picture window (FlagArt's card
-- pages: each cell is the window's shape with the flag centred in it).
function Art.flagCard(id: string, props: { [string]: any }): ImageLabel
	local cell = FlagArt.cardCells[id]
	if cell == nil then
		return Art.flag(id, props)
	end
	local size = FlagArt.card
	return cellImage(FlagArt.CARD_PAGES[cell[1]] or "", cell[2] * size.w, cell[3] * size.h, size.w, size.h, props)
end

function Art.skin(id: string, props: { [string]: any }): ImageLabel
	local cell = StoreArt.skins[id]
	local s = StoreArt.skinCell
	if cell == nil then
		return cellImage("", 0, 0, 0, 0, props)
	end
	return cellImage(StoreArt.SKINS, cell[1] * s, cell[2] * s, s, s, props)
end

-- Where a flag's or skin's picture is: its page, the cell (x, y, w, h, the
-- same rectangle Art.flag and Art.skin show) and the page's size in pixels
-- (scripts/art/flags.py: 960 x 1008; scripts/art/store_art.py: 1024 x 1024).
-- For a 3D Texture, which can't crop the way an ImageLabel does. `card`
-- gives a flag's crate-card picture (Art.flagCard) instead.
export type Cell = { image: string, x: number, y: number, w: number, h: number, pageW: number, pageH: number }
function Art.cell(id: string, card: boolean?): Cell?
	local big = if card then FlagArt.cardCells[id] else nil
	if big then
		local size = FlagArt.card
		return { image = FlagArt.CARD_PAGES[big[1]] or "", x = big[2] * size.w, y = big[3] * size.h, w = size.w, h = size.h, pageW = size.pageW, pageH = size.pageH }
	end
	local flag = FlagArt.cells[id]
	if flag then
		local own = string.sub(id, 1, 2) == "o_"
		local size = if own then FlagArt.own else FlagArt.country
		local pages = if own then FlagArt.OWN_PAGES else FlagArt.COUNTRY_PAGES
		return { image = pages[flag[1]] or "", x = flag[2] * size.w + 2, y = flag[3] * size.h + 2, w = size.w - 4, h = size.h - 4, pageW = 960, pageH = 1008 }
	end
	local skin = StoreArt.skins[id]
	if skin then
		local s = StoreArt.skinCell
		return { image = StoreArt.SKINS, x = skin[1] * s, y = skin[2] * s, w = s, h = s, pageW = 1024, pageH = 1024 }
	end
	return nil
end

-- Arsenal item -> its photo in UiAssets.dossier.
local PHOTOS: { [string]: string } = {
	w_reinforce = "arsenal_reinforcements",
	w_mega = "arsenal_mega",
	w_artillery = "arsenal_artillery",
	w_scatter = "arsenal_scatter",
	w_airstrike = "arsenal_airstrike",
	w_railgun = "arsenal_railgun",
	w_paratroopers = "arsenal_paratroopers",
	w_coastal = "arsenal_coastal",
	w_sabotage = "arsenal_sabotage",
	w_fieldworks = "arsenal_fieldworks",
	w_rapidreload = "arsenal_rapidreload",
	w_general = "arsenal_general",
	b_double = "arsenal_2xstars",
}

function Art.card(id: string, props: { [string]: any }): ImageLabel
	local photo = UiAssets.dossier[PHOTOS[id] or ""]
	if photo and photo ~= "" then
		local label = cellImage(photo, 0, 0, 0, 0, props)
		label.ImageRectSize = Vector2.zero
		return label
	end
	local cell = StoreArt.cards[id]
	if cell == nil then
		return cellImage("", 0, 0, 0, 0, props)
	end
	return cellImage(StoreArt.ARSENAL, cell[1] * StoreArt.cardW, cell[2] * StoreArt.cardH, StoreArt.cardW, StoreArt.cardH, props)
end

-- A title, match effect or the gold name (Catalog.EXTRAS) has no picture
-- of its own yet: its kind's icon in its rarity's colour.
local EXTRA_GLYPH = { title = "crown", conquest = "flag", blast = "explosion", name = "star" }
local EXTRA_INK = { rare = Color3.fromHex("#3D8BEA"), epic = Color3.fromHex("#9B5CF0"), legendary = Color3.fromHex("#E3A82A"), common = Color3.fromHex("#8C8A7C") }
function Art.extra(kind: string, rarity: string, props: { [string]: any }): ImageLabel
	local merged = table.clone(props)
	merged.ImageColor3 = merged.ImageColor3 or EXTRA_INK[rarity] or EXTRA_INK.common
	merged.ScaleType = Enum.ScaleType.Fit
	return Kit.glyph(EXTRA_GLYPH[kind] or "star", merged)
end

-- Any cosmetic's picture: a skin's pattern, a flag, or an extra's icon.
function Art.cosmetic(item: { id: string, kind: string, rarity: string }, props: { [string]: any }): ImageLabel
	if item.kind == "skin" then
		return Art.skin(item.id, props)
	elseif item.kind == "flag" then
		return Art.flag(item.id, props)
	end
	return Art.extra(item.kind, item.rarity, props)
end

return Art
