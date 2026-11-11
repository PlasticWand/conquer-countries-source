--!strict
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/NationCreation.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The nations in a game (createNationsForGame):
--   - nations = "disabled": none; a number: exactly that many (manifest
--     nations shuffled, then the map's additional nations, then generated
--     joke names)
--   - "default": public Humans vs Nations matches the human count; public
--     compact maps use 25% of the manifest's; otherwise all of them
-- Every nation gets an id from the game's PseudoRandom, in this order.

local GameTypes = require(script.Parent.GameTypes)

local NationCreation = {}

local NOUN = "\0noun"
local PLURAL_NOUN = "\0plural"

export type Nation = { spawnCell: { x: number, y: number }?, playerInfo: { [string]: any } }

local NAME_TEMPLATES: { { any } } = {
	{ "World Famous", NOUN },
	{ "Famous", PLURAL_NOUN },
	{ "Comically Large", NOUN },
	{ "Comically Small", NOUN },
	{ "Massive", PLURAL_NOUN },
	{ "Friendly", NOUN },
	{ "Evil", NOUN },
	{ "Malicious", NOUN },
	{ "Spiteful", NOUN },
	{ "Suspicious", NOUN },
	{ "Canonically Evil", NOUN },
	{ "Limited Edition", NOUN },
	{ "Patent Pending", NOUN },
	{ "Patented", NOUN },
	{ "Space", NOUN },
	{ "Defend The", PLURAL_NOUN },
	{ "Anarchist", NOUN },
	{ "Republic of", PLURAL_NOUN },
	{ "Slippery", NOUN },
	{ "Wealthy", PLURAL_NOUN },
	{ "Certified", NOUN },
	{ "Dr", NOUN },
	{ "Runaway", NOUN },
	{ "Chrome", NOUN },
	{ "All New", NOUN },
	{ "Top Shelf", PLURAL_NOUN },
	{ "Invading", PLURAL_NOUN },
	{ "Loyal To", PLURAL_NOUN },
	{ "United States of", NOUN },
	{ "United States of", PLURAL_NOUN },
	{ "Flowing Rivers of", NOUN },
	{ "House of", PLURAL_NOUN },
	{ "Certified Organic", NOUN },
	{ "Unregulated", NOUN },
	{ "Slightly Damp", NOUN },
	{ "Suspiciously Quiet", PLURAL_NOUN },
	{ "Weaponized", NOUN },
	{ "Accidentally Evil", NOUN },
	{ "Extremely Loud", PLURAL_NOUN },
	{ "Bootleg", NOUN },
	{ "Questionable", NOUN },
	{ "Off-Brand", NOUN },
	{ "Counterfeit", PLURAL_NOUN },
	{ "Sentient", PLURAL_NOUN },
	{ "Feral", PLURAL_NOUN },
	{ "Aggressively Friendly", PLURAL_NOUN },
	{ "Mildly Threatening", NOUN },
	{ "Dangerously Cute", PLURAL_NOUN },
	{ "Legally Distinct", NOUN },
	{ "Deeply Confused", PLURAL_NOUN },
	{ "Order of the", NOUN },
	{ "Knights of the", NOUN },
	{ "Cult of the", NOUN },
	{ "League of", PLURAL_NOUN },
	{ "Band of", PLURAL_NOUN },
	{ "Council of", PLURAL_NOUN },
	{ "Assembly of", PLURAL_NOUN },
	{ "Haunted", NOUN },
	{ "Cursed", NOUN },
	{ "Blessed", NOUN },
	{ "Radioactive", PLURAL_NOUN },
	{ "Deep Fried", NOUN },
	{ "Gluten Free", PLURAL_NOUN },
	{ "Turbocharged", NOUN },
	{ "Nomadic", PLURAL_NOUN },
	{ "Vengeful", PLURAL_NOUN },
	{ "Legendary", PLURAL_NOUN },
	{ "Outlaw", PLURAL_NOUN },
	{ "AFK", NOUN },
	{ "Noob", NOUN },
	{ "Pro", NOUN },
	{ "Tryhard", PLURAL_NOUN },
	{ "Sweaty", PLURAL_NOUN },
	{ "Griefing", PLURAL_NOUN },
	{ "Speedrunning", PLURAL_NOUN },
	{ "Nerfed", PLURAL_NOUN },
	{ "Buffed", PLURAL_NOUN },
	{ "OP", NOUN },
	{ "Overpowered", NOUN },
	{ "Underpowered", PLURAL_NOUN },
	{ "Modded", PLURAL_NOUN },
	{ "Prestige", NOUN },
	{ "Hardcore", PLURAL_NOUN },
	{ "Clutch", NOUN },
	{ "Cracked", NOUN },
	{ "Unranked", PLURAL_NOUN },
	{ "Max Level", NOUN },
	{ "Ironman", NOUN },
	{ NOUN, "For Hire" },
	{ PLURAL_NOUN, "That Bite" },
	{ PLURAL_NOUN, "Are Opps" },
	{ NOUN, "Hotel" },
	{ PLURAL_NOUN, "The Movie" },
	{ NOUN, "Corporation" },
	{ PLURAL_NOUN, "Inc" },
	{ NOUN, "Democracy" },
	{ NOUN, "Network" },
	{ NOUN, "Railway" },
	{ NOUN, "Congress" },
	{ NOUN, "Alliance" },
	{ NOUN, "Island" },
	{ NOUN, "Kingdom" },
	{ NOUN, "Empire" },
	{ NOUN, "Dynasty" },
	{ NOUN, "Cartel" },
	{ NOUN, "Cabal" },
	{ NOUN, "Land" },
	{ NOUN, "Oligarchy" },
	{ NOUN, "Nationalist" },
	{ NOUN, "State" },
	{ NOUN, "Duchy" },
	{ NOUN, "Ocean" },
	{ NOUN, "Syndicate" },
	{ NOUN, "Republic" },
	{ NOUN, "Province" },
	{ NOUN, "Dominion" },
	{ NOUN, "Commune" },
	{ NOUN, "Federation" },
	{ NOUN, "Parliament" },
	{ NOUN, "Tribunal" },
	{ NOUN, "Armada" },
	{ NOUN, "Rebellion" },
	{ NOUN, "Resistance" },
	{ NOUN, "Expedition" },
	{ NOUN, "Preservation Society" },
	{ NOUN, "Defense League" },
	{ NOUN, "Thunderdome" },
	{ NOUN, "Uprising" },
	{ NOUN, "Enthusiasts" },
	{ NOUN, "Appreciation Society" },
	{ NOUN, "Fan Club" },
	{ NOUN, "Simulation" },
	{ PLURAL_NOUN, "Anonymous" },
	{ PLURAL_NOUN, "With Attitude" },
	{ PLURAL_NOUN, "Gone Wrong" },
	{ PLURAL_NOUN, "on Vacation" },
	{ PLURAL_NOUN, "in Disguise" },
	{ PLURAL_NOUN, "With Hats" },
	{ PLURAL_NOUN, "on Ice" },
	{ PLURAL_NOUN, "United" },
	{ PLURAL_NOUN, "Unhinged" },
	{ PLURAL_NOUN, "Unleashed" },
	{ PLURAL_NOUN, "Reloaded" },
	{ PLURAL_NOUN, "After Dark" },
	{ PLURAL_NOUN, "From Space" },
	{ PLURAL_NOUN, "of Doom" },
	{ PLURAL_NOUN, "Without Borders" },
	{ NOUN, "Meta" },
	{ PLURAL_NOUN, "OP Please Nerf" },
	{ "Alternate", NOUN, "Universe" },
	{ "Famous", NOUN, "Collection" },
	{ "Supersonic", NOUN, "Spaceship" },
	{ "Secret", NOUN, "Agenda" },
	{ "Ballistic", NOUN, "Missile" },
	{ "The", PLURAL_NOUN, "are SPIES" },
	{ "Traveling", NOUN, "Circus" },
	{ "The", PLURAL_NOUN, "Lied" },
	{ "Sacred", NOUN, "Knowledge" },
	{ "Quantum", NOUN, "Computer" },
	{ "Hadron", NOUN, "Collider" },
	{ "Large", NOUN, "Obliterator" },
	{ "Interstellar", NOUN, "Pirates" },
	{ "Alien", NOUN, "Clan" },
	{ "Grand", NOUN, "Alliance" },
	{ "Royal", NOUN, "Army" },
	{ "Holy", NOUN, "Empire" },
	{ "Eternal", NOUN, "Cabal" },
	{ "Invading", NOUN, "Empire" },
	{ "Immortal", NOUN, "Pirates" },
	{ "Shadow", NOUN, "Cabal" },
	{ "Secret", NOUN, "Dynasty" },
	{ "The Great", NOUN, "Army" },
	{ "The", NOUN, "Matrix" },
	{ "Tax-Free", NOUN, "Paradise" },
	{ "Self-Proclaimed", NOUN, "Experts" },
	{ "Forbidden", NOUN, "Zone" },
	{ "Reluctant", NOUN, "Monarchy" },
	{ "Chaotic", NOUN, "Collective" },
	{ "Unsanctioned", NOUN, "Olympics" },
	{ "The", NOUN, "Conspiracy" },
	{ "The", NOUN, "Incident" },
	{ "The", NOUN, "Situation" },
	{ "Premium", NOUN, "Subscription" },
	{ "Clearance", NOUN, "Warehouse" },
	{ "Budget", NOUN, "Emporium" },
	{ "Overnight", NOUN, "Delivery" },
	{ "National", NOUN, "Reserve" },
	{ "The", NOUN, "Dimension" },
	{ "The", NOUN, "Prophecy" },
	{ "The", NOUN, "Awakening" },
	{ "The", NOUN, "Inquisition" },
	{ "Legendary", NOUN, "Drop" },
	{ "Elite", NOUN, "Squad" },
	{ "The", NOUN, "Saga" },
}

local NOUNS: { string } = {
	"Snail", "Cow", "Giraffe", "Donkey", "Horse", "Mushroom", "Salad", "Kitten",
	"Fork", "Apple", "Pancake", "Tree", "Fern", "Seashell", "Turtle", "Casserole",
	"Gnome", "Frog", "Cheese", "Mold", "Clown", "Boat", "Robot", "Millionaire",
	"Billionaire", "Pigeon", "Fish", "Bumblebee", "Jelly", "Wizard", "Worm", "Rat",
	"Pumpkin", "Zombie", "Grass", "Bear", "Skunk", "Sandwich", "Butter", "Soda",
	"Pickle", "Potato", "Book", "Friend", "Feather", "Flower", "Oil", "Train",
	"Fan", "Salmon", "Cod", "Sink", "Villain", "Bug", "Car", "Soup",
	"Puppy", "Rock", "Stick", "Succulent", "Nerd", "Mercenary", "Ninja", "Burger",
	"Tomato", "Penguin", "Waffle", "Toaster", "Hamster", "Pretzel", "Walrus", "Raccoon",
	"Llama", "Noodle", "Goblin", "Muffin", "Coconut", "Biscuit", "Cactus", "Moose",
	"Platypus", "Yeti", "Sponge", "Spatula", "Trampoline", "Dolphin", "Taco", "Chainsaw",
	"Spoon", "Doorknob", "Bathrobe", "Lampshade", "Crowbar", "Shoelace", "Wheelbarrow", "Barnacle",
	"Armadillo", "Cabbage", "Wig", "Plunger", "Kazoo", "Napkin", "Pelican", "Turnip",
	"Canoe", "Igloo", "Stapler", "Ferret", "Anchovy", "Dumpling", "Mattress", "Parsnip",
	"Gargoyle", "Crayon", "Corgi", "Macaroni", "Blender", "Ukulele", "Flamingo", "Nugget",
	"Porcupine", "Tadpole", "Papaya", "Chinchilla", "Teapot", "Baguette", "Squid", "Otter",
	"Badger", "Hedgehog", "Mantis", "Scorpion", "Vulture", "Falcon", "Jackal", "Hyena",
	"Panther", "Stingray", "Octopus", "Basilisk", "Dragon", "Sphinx", "Phoenix", "Kraken",
	"Leviathan", "Mammoth", "Chimera", "Griffin", "Minotaur", "Cyclops", "Brick", "Anvil",
	"Torpedo", "Lantern", "Compass", "Telescope", "Pendulum", "Furnace", "Cauldron", "Beacon",
	"Anchor", "Dagger", "Gauntlet", "Helmet", "Shield", "Banner", "Trumpet", "Bagpipe",
	"Tambourine", "Accordion", "Xylophone", "Avocado", "Broccoli", "Radish", "Artichoke", "Kumquat",
	"Pomegranate", "Mango", "Truffle", "Croissant", "Lasagna", "Soufflé", "Spaghetti", "Tsunami",
	"Tornado", "Avalanche", "Volcano", "Glacier", "Comet", "Meteor", "Nebula", "Supernova",
	"Quasar", "Abyss", "Labyrinth", "Caterpillar", "Chameleon", "Narwhal", "Capybara", "Pangolin",
	"Axolotl", "Sloth", "Lemur", "Alpaca", "Tapir", "Wombat", "Ocelot", "Manatee",
	"Ibis", "Kiwi", "Creeper", "Enderman", "Skeleton", "Necromancer", "Paladin", "Warlock",
	"Ranger", "Boss", "NPC", "Assassin", "Viking", "Samurai", "Pirate", "Champion",
	"Gladiator", "Demon", "Angel", "Fullsender", "Fullsender", "Fullsender", "Mito", "Mito",
	"Mito", "Mitochondria", "Mitochondria", "Mitochondria",
}

local O_TO_OES = { Potato = true, Tomato = true, Volcano = true, Torpedo = true }
local SPECIAL_PLURALS = {
	Cactus = "Cacti",
	Platypus = "Platypuses",
	Moose = "Moose",
	Octopus = "Octopi",
	Cyclops = "Cyclopes",
	Samurai = "Samurai",
	Fish = "Fish",
	Salmon = "Salmon",
	Cod = "Cod",
	Enderman = "Endermen",
	Mitochondria = "Mitochondria",
}

local function endsWith(s: string, suffix: string): boolean
	return string.sub(s, -#suffix) == suffix
end

local function pluralize(noun: string): string
	local special = SPECIAL_PLURALS[noun]
	if special then
		return special
	end
	if endsWith(noun, "s") or endsWith(noun, "ch") or endsWith(noun, "sh") or endsWith(noun, "x") or endsWith(noun, "z") then
		return noun .. "es"
	end
	if endsWith(noun, "y") and not string.find("aeiou", string.sub(noun, -2, -2), 1, true) then
		return string.sub(noun, 1, -2) .. "ies"
	end
	if O_TO_OES[noun] then
		return noun .. "es"
	end
	return noun .. "s"
end

local function generateNationName(random: any): string
	local template = NAME_TEMPLATES[random:nextInt(0, #NAME_TEMPLATES) + 1]
	local noun = NOUNS[random:nextInt(0, #NOUNS) + 1]
	local parts = {}
	for _, part in template do
		if part == PLURAL_NOUN then
			table.insert(parts, pluralize(noun))
		elseif part == NOUN then
			table.insert(parts, noun)
		else
			table.insert(parts, part)
		end
	end
	return table.concat(parts, " ")
end

local function generateUniqueNationName(random: any, usedNames: { [string]: boolean }): string
	for _ = 1, 1000 do
		local name = generateNationName(random)
		if not usedNames[name] then
			return name
		end
	end
	local counter = 1
	local base = generateNationName(random)
	while usedNames[`{base} {counter}`] do
		counter += 1
	end
	return `{base} {counter}`
end

local function nationInfo(name: string, id: string, flag: string?): { [string]: any }
	return { name = name, playerType = GameTypes.PlayerType.Nation, clientID = nil, id = id, isLobbyCreator = false, nationFlag = flag }
end

local function cellOf(n: any): { x: number, y: number }?
	local c = n.coordinates
	return if c ~= nil then { x = c[1], y = c[2] } else nil
end

local function slice(list: { any }, count: number): { any }
	return table.move(list, 1, math.min(count, #list), 1, {})
end

-- 25% of the manifest's nations on compact maps (at least 1).
function NationCreation.getCompactMapNationCount(manifestCount: number, isCompact: boolean): number
	if manifestCount == 0 then
		return 0
	end
	if isCompact then
		return math.max(1, math.floor(manifestCount * 0.25))
	end
	return manifestCount
end

local function createRandomNations(targetCount: number, manifest: { any }, additional: { any }, toNation: (any) -> Nation, random: any): { Nation }
	local shuffled = random:shuffleArray(manifest)
	if targetCount <= #manifest then
		local out = {}
		for _, n in slice(shuffled, targetCount) do
			table.insert(out, toNation(n))
		end
		return out
	end
	local nations = {}
	local usedNames: { [string]: boolean } = {}
	for _, n in shuffled do
		local nation = toNation(n)
		table.insert(nations, nation)
		usedNames[nation.playerInfo.name] = true
	end
	local remaining = targetCount - #manifest
	if remaining > 0 and #additional > 0 then
		local candidates = {}
		for _, n in additional do
			if not usedNames[n.name] then
				table.insert(candidates, n)
			end
		end
		local picked = slice(random:shuffleArray(candidates), remaining)
		for _, extra in picked do
			table.insert(nations, { spawnCell = cellOf(extra), playerInfo = nationInfo(extra.name, random:nextID(), extra.flag) })
			usedNames[extra.name] = true
		end
		remaining -= #picked
	end
	for _ = 1, remaining do
		local name = generateUniqueNationName(random, usedNames)
		usedNames[name] = true
		table.insert(nations, { spawnCell = nil, playerInfo = nationInfo(name, random:nextID(), nil) })
	end
	return nations
end

-- gameConfig: OpenFront GameConfig fields; manifestNations and
-- additionalNations as MapLoader returns them ({ name, coordinates, flag }).
function NationCreation.createNationsForGame(
	gameConfig: { [string]: any },
	manifestNations: { any },
	additionalNations: { any },
	numHumans: number,
	random: any
): { Nation }
	local function toNation(n: any): Nation
		return { spawnCell = cellOf(n), playerInfo = nationInfo(n.name, random:nextID(), n.flag) }
	end
	local configNations = gameConfig.nations
	if configNations == "disabled" then
		return {}
	end
	if type(configNations) == "number" then
		return createRandomNations(configNations, manifestNations, additionalNations, toNation, random)
	end
	local isCompact = gameConfig.gameMapSize == GameTypes.GameMapSize.Compact
	local isHvN = gameConfig.gameMode == GameTypes.GameMode.Team and gameConfig.playerTeams == "Humans Vs Nations"
	if gameConfig.gameType == GameTypes.GameType.Public then
		if isHvN then
			return createRandomNations(numHumans, manifestNations, additionalNations, toNation, random)
		end
		if isCompact then
			local target = NationCreation.getCompactMapNationCount(#manifestNations, true)
			local out = {}
			for _, n in slice(random:shuffleArray(manifestNations), target) do
				table.insert(out, toNation(n))
			end
			return out
		end
	end
	local out = {}
	for _, n in manifestNations do
		table.insert(out, toNation(n))
	end
	return out
end

return NationCreation
