--!strict
-- The map picker's catalog (docs/design/rofront-ui-pass.md, screens 8-15):
-- OpenFront's maps (Data/MapInfo: categories, featured ranks, names) that are
-- imported into this place (Data/ImportedMaps), grouped into the picker's
-- tabs. A map can sit in several tabs. Pure.

local OF = script.Parent.OpenFront
local ImportedMaps = require(OF.Data.ImportedMaps) :: { { folder: string, id: string, width: number, height: number } }
local Lang = require(OF.Lang)
local MapInfo = require(OF.Data.MapInfo) :: { any }

local MapCatalog = {}

export type Entry = {
	folder: string, -- what the server's Start request names
	id: string, -- MapInfo id
	type: string, -- OpenFront's GameMapType value
	name: string,
	width: number,
	height: number,
	categories: { string },
	featuredRank: number?,
	order: number, -- position in OpenFront's map table
}

export type Tab = { id: string, label: string, categories: { string }? }

-- The picker's tabs over OpenFront's categories (mapCategoryOrder).
MapCatalog.TABS = {
	{ id = "featured", label = Lang.t("map_categories.featured"), categories = { "featured" } },
	{ id = "world", label = Lang.t("map_categories.world"), categories = { "world", "continental" } },
	{ id = "europe", label = Lang.t("map_categories.europe"), categories = { "europe" } },
	{ id = "asia", label = Lang.t("map_categories.asia"), categories = { "asia" } },
	{ id = "americas", label = "Americas", categories = { "north_america", "south_america" } },
	{ id = "africaOceania", label = "Africa • Oceania", categories = { "africa", "oceania", "antarctica" } },
	{ id = "fantasy", label = "Fantasy", categories = { "fictional", "cosmic", "arcade" } },
	{ id = "all", label = Lang.t("map.all"), categories = nil },
} :: { Tab }

local entries: { Entry } = {}
local byFolder: { [string]: Entry } = {}
do
	local info: { [string]: any } = {}
	local order: { [string]: number } = {}
	for i, m in MapInfo do
		info[m.id] = m
		order[m.id] = i
	end
	for _, imported in ImportedMaps do
		local m = info[imported.id]
		if m then
			local entry: Entry = {
				folder = imported.folder,
				id = m.id,
				type = m.type,
				name = Lang.t(m.translationKey),
				width = imported.width,
				height = imported.height,
				categories = m.categories,
				featuredRank = m.featuredRank,
				order = order[m.id],
			}
			table.insert(entries, entry)
			byFolder[imported.folder] = entry
		end
	end
end

local function inTab(entry: Entry, tab: Tab): boolean
	if tab.categories == nil then
		return true
	end
	for _, c in tab.categories do
		if table.find(entry.categories, c) then
			return true
		end
	end
	return false
end

-- Featured maps first by rank, then by name.
local function before(a: Entry, b: Entry): boolean
	local ra, rb = a.featuredRank or math.huge, b.featuredRank or math.huge
	if ra ~= rb then
		return ra < rb
	end
	return a.name < b.name
end

-- The maps in one tab, in picker order.
function MapCatalog.inTab(tabId: string): { Entry }
	local out = {}
	for _, tab in MapCatalog.TABS do
		if tab.id == tabId then
			for _, e in entries do
				if inTab(e, tab) then
					table.insert(out, e)
				end
			end
		end
	end
	table.sort(out, before)
	return out
end

-- The tabs that have at least one playable map.
function MapCatalog.tabs(): { Tab }
	local out = {}
	for _, tab in MapCatalog.TABS do
		if #MapCatalog.inTab(tab.id) > 0 then
			table.insert(out, tab)
		end
	end
	return out
end

function MapCatalog.get(folder: string): Entry?
	return byFolder[folder]
end

function MapCatalog.all(): { Entry }
	return MapCatalog.inTab("all")
end

-- "2000 × 1000"
function MapCatalog.sizeText(entry: Entry): string
	return `{entry.width} × {entry.height}`
end

return MapCatalog
