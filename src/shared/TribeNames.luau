--!strict
-- Names for neutral tribes (PLAN_WELCOME M3): original, generated from our own
-- word lists, never real peoples or another game's names. Pure.

local Rng = require(script.Parent.Rng)

local TribeNames = {}

local FIRST = {
	"Ash", "Bramble", "Cinder", "Dusk", "Ember", "Fern", "Frost", "Gale", "Hollow", "Iron",
	"Juniper", "Kestrel", "Lantern", "Moss", "Nettle", "Oak", "Pebble", "Quill", "Reed", "Salt",
	"Thistle", "Umber", "Vale", "Willow", "Yarrow", "Amber", "Birch", "Clover", "Drift", "Elder",
	"Flint", "Heron", "Lark", "Marsh", "Otter", "Pine", "Rook", "Slate", "Tide", "Wren",
}

local SECOND = {
	"folk", "kin", "riders", "watch", "hollow", "band", "clan", "walkers", "keepers", "reach",
	"dwellers", "wardens", "hearth", "steads", "menders", "callers", "fold", "march", "runners", "weavers",
}

-- `count` distinct names in a seeded order ("Thistlewatch", "The Mossfolk", ...).
function TribeNames.generate(rng: Rng.Rng, count: number): { string }
	local names = {}
	local used: { [string]: boolean } = {}
	local attempts = 0
	while #names < count and attempts < count * 20 do
		attempts += 1
		local word = FIRST[Rng.int(rng, 1, #FIRST)] .. SECOND[Rng.int(rng, 1, #SECOND)]
		local name = if Rng.int(rng, 1, 3) == 1 then "The " .. word else word
		if not used[word] then
			used[word] = true
			table.insert(names, name)
		end
	end
	while #names < count do
		table.insert(names, `Tribe {#names + 1}`)
	end
	return names
end

return TribeNames
