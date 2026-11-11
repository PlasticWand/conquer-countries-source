--!strict
-- Territory skins (the Locker's Skins tab): our own patterns, drawn over a
-- player's territory colour by the map renderer (RasterCore pattern masks:
-- a set bit picks the territory's secondary shade). Each is a small bit
-- grid ("#" set, "." clear); `scale` is the renderer's shift (1 = each
-- pattern cell covers 2x2 tiles). Pure.

local Skins = {}

export type Rarity = "common" | "rare" | "epic" | "legendary"
export type Skin = { id: string, name: string, rarity: Rarity, scale: number, rows: { string } }

Skins.LIST = {
	{ id = "s_stripes", name = "Stripes", rarity = "common", scale = 1, rows = { "##..", ".##.", "..##", "#..#" } },
	{ id = "s_checker", name = "Checker", rarity = "common", scale = 1, rows = { "##..", "##..", "..##", "..##" } },
	{ id = "s_dots", name = "Dots", rarity = "common", scale = 0, rows = { "......", ".##...", ".##...", "......", "....##", "....##" } },
	{ id = "s_grid", name = "Grid", rarity = "common", scale = 0, rows = { "#######", "#......", "#......", "#......", "#......", "#......", "#......" } },
	{ id = "s_rows", name = "Furrows", rarity = "common", scale = 1, rows = { "####", "....", "....", "...." } },
	{ id = "s_hatch", name = "Crosshatch", rarity = "common", scale = 0, rows = { "#...#", ".#.#.", "..#..", ".#.#.", "#...#" } },
	{ id = "s_waves", name = "Waves", rarity = "rare", scale = 0, rows = { "..##....", ".#..#...", "#....#..", "......##" } },
	{ id = "s_chevron", name = "Chevron", rarity = "rare", scale = 0, rows = { "#.....#.", ".#...#..", "..#.#...", "...#....", "........", "........" } },
	{ id = "s_diamonds", name = "Diamonds", rarity = "rare", scale = 0, rows = { "...#...", "..#.#..", ".#...#.", "#.....#", ".#...#.", "..#.#..", "...#..." } },
	{ id = "s_bricks", name = "Masonry", rarity = "rare", scale = 0, rows = { "########", "#.......", "#.......", "########", "....#...", "....#..." } },
	{ id = "s_plaid", name = "Plaid", rarity = "epic", scale = 0, rows = { "#..##..#", "........", "........", "#..##..#", "#..##..#", "........", "........", "#..##..#" } },
	{ id = "s_hex", name = "Honeycomb", rarity = "epic", scale = 0, rows = { ".####...", "#....#..", "#....#..", ".####...", "......##", "......##" } },
	{ id = "s_circuit", name = "Wiring", rarity = "epic", scale = 0, rows = { "#####...", "....#...", "....####", "#.......", "#..##...", "####...." } },
	{ id = "s_ripple", name = "Ripple", rarity = "epic", scale = 0, rows = { "..####..", ".#....#.", "#..##..#", "#.#..#.#", "#..##..#", ".#....#.", "..####..", "........" } },
	{ id = "s_stars", name = "Night Sky", rarity = "legendary", scale = 0, rows = { "........#.", "...#......", "..###.....", "...#......", "........#.", ".......###", "#.......#.", "..........", ".....#....", ".........." } },
	{ id = "s_scales", name = "Dragonscale", rarity = "legendary", scale = 0, rows = { "..####..", ".#....#.", "#......#", "#......#", "##....##", "..####.." } },
} :: { Skin }

-- Conquest General's skins (Catalog.SUBSCRIPTION.skins): one a month for
-- subscribers, theirs to keep; never in crates.
Skins.GENERAL = {
	-- Five-pointed rank stars on a quiet field.
	{ id = "g_rank", name = "General's Stars", rarity = "legendary", scale = 0, rows = { "............", ".....#......", ".....#......", "....###.....", ".#########..", "..#######...", "...#####....", "...##.##....", "..##...##...", "..#.....#...", "............", "............" } },
	-- One a month after it (2026-11-11, Bruno: "12 months, my picks"; months in Catalog).
	{ id = "g_eagle", name = "Iron Eagle", rarity = "legendary", scale = 0, rows = { "................", ".......##.......", "......####......", ".#....####....#.", ".##..######..##.", ".###.######.###.", "..############..", "...##########...", ".....######.....", "......#..#......", ".....##..##.....", "................", "................" } },
	{ id = "g_chevrons", name = "Sergeant's Chevrons", rarity = "legendary", scale = 0, rows = { ".............", "......#......", ".....###.....", "....##.##....", "...##...##...", "..##..#..##..", ".##..###..##.", "....##.##....", "...##...##...", "..##.....##..", ".##.......##.", ".............", "............." } },
	{ id = "g_medal", name = "Medal of Valor", rarity = "legendary", scale = 0, rows = { "............", "...##..##...", "....#..#....", ".....##.....", "....####....", "...#....#...", "..#..##..#..", "..#.####.#..", "..#..##..#..", "...#....#...", "....####....", "............" } },
	{ id = "g_shield", name = "Bastion Shield", rarity = "legendary", scale = 0, rows = { "............", "..########..", "..#..##..#..", "..#..##..#..", "..########..", "..#..##..#..", "..#..##..#..", "...#.##.#...", "....#..#....", ".....##.....", "............", "............" } },
	{ id = "g_wings", name = "Pilot's Wings", rarity = "legendary", scale = 0, rows = { "..................", "........##........", ".######.##.######.", "..#####.##.#####..", "...####.##.####...", "....###.##.###....", "........##........", "..................", ".................." } },
	{ id = "g_laurel", name = "Victory Laurel", rarity = "legendary", scale = 0, rows = { "..............", "...#......#...", "..##......##..", "..#........#..", ".##........##.", ".#..........#.", ".##........##.", "..#........#..", "..##......##..", "...##....##...", ".....#..#.....", "..............", ".............." } },
	{ id = "g_tank", name = "Armored Column", rarity = "legendary", scale = 0, rows = { "................", "......#####.....", "......##########", "...##########...", "..############..", "..#.##.##.##.#..", "...##########...", "................", "................", "................" } },
	{ id = "g_crown", name = "Marshal's Crown", rarity = "legendary", scale = 0, rows = { "............", "............", ".#...##...#.", ".##..##..##.", ".###.##.###.", ".##########.", ".##########.", ".#........#.", ".##########.", "............", "............", "............" } },
	{ id = "g_blades", name = "Crossed Blades", rarity = "legendary", scale = 0, rows = { "..............", "..#........#..", "...#......#...", "....#....#....", ".....#..#.....", "......##......", "......##......", ".....#..#.....", "...###..###...", "...#......#...", "..#........#..", "..............", ".............." } },
	{ id = "g_chute", name = "Airborne", rarity = "legendary", scale = 0, rows = { "............", "...######...", "..########..", ".##########.", ".#..#..#..#.", "..#.#..#.#..", "...##..##...", "....####....", ".....##.....", "............", "............", "............" } },
	{ id = "g_sight", name = "Marksman's Sight", rarity = "legendary", scale = 0, rows = { "............", ".....##.....", "...######...", "..#..##..#..", ".#...##...#.", ".####..####.", ".####..####.", ".#...##...#.", "..#..##..#..", "...######...", ".....##.....", "............" } },
} :: { Skin }

local byId: { [string]: Skin } = {}
for _, s in Skins.LIST do
	byId[s.id] = s
end
for _, s in Skins.GENERAL do
	byId[s.id] = s
end

function Skins.get(id: string): Skin?
	return byId[id]
end

-- The renderer's mask: width*height bits, LSB first, row by row.
function Skins.mask(id: string): { width: number, height: number, scale: number, bytes: buffer }?
	local skin = byId[id]
	if skin == nil then
		return nil
	end
	local h = #skin.rows
	local w = #skin.rows[1]
	local bytes = buffer.create(math.ceil(w * h / 8))
	for y, row in skin.rows do
		for x = 1, w do
			if string.sub(row, x, x) == "#" then
				local i = (y - 1) * w + (x - 1)
				local b = buffer.readu8(bytes, i // 8)
				buffer.writeu8(bytes, i // 8, bit32.bor(b, bit32.lshift(1, i % 8)))
			end
		end
	end
	return { width = w, height = h, scale = skin.scale, bytes = bytes }
end

return Skins
