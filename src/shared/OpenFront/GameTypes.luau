--!strict
-- Ported from OpenFront v0.35.2 (packages/engine-api/src/game/GameTypes.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- The enums the engine port needs, with OpenFront's own string values so
-- configs and records read the same. Grows as more of GameTypes.ts is ported.

local GameTypes = {}

GameTypes.Difficulty = table.freeze({
	Easy = "Easy",
	Medium = "Medium",
	Hard = "Hard",
	Impossible = "Impossible",
})
export type Difficulty = "Easy" | "Medium" | "Hard" | "Impossible"

GameTypes.GameType = table.freeze({
	Singleplayer = "Singleplayer",
	Public = "Public",
	Private = "Private",
})
export type GameType = "Singleplayer" | "Public" | "Private"

GameTypes.GameMode = table.freeze({
	FFA = "Free For All",
	Team = "Team",
})

GameTypes.GameMapSize = table.freeze({
	Normal = "Normal",
	Compact = "Compact",
})

-- Team-count presets (GameTypes.ts Duos/Trios/Quads/HumansVsNations).
GameTypes.Duos = "Duos"
GameTypes.Trios = "Trios"
GameTypes.Quads = "Quads"
GameTypes.HumansVsNations = "Humans Vs Nations"

GameTypes.PlayerType = table.freeze({
	Bot = "BOT", -- tribes
	Human = "HUMAN",
	Nation = "NATION",
})
export type PlayerType = "BOT" | "HUMAN" | "NATION"

GameTypes.UnitType = table.freeze({
	TransportShip = "Transport",
	Warship = "Warship",
	Shell = "Shell",
	SAMMissile = "SAMMissile",
	Port = "Port",
	AtomBomb = "Atom Bomb",
	HydrogenBomb = "Hydrogen Bomb",
	TradeShip = "Trade Ship",
	MissileSilo = "Missile Silo",
	DefensePost = "Defense Post",
	SAMLauncher = "SAM Launcher",
	City = "City",
	MIRV = "MIRV",
	MIRVWarhead = "MIRV Warhead",
	Train = "Train",
	Factory = "Factory",
	-- Conquest's Arsenal (not OpenFront; only with gameConfig.extraWeapons).
	MegaNuke = "Mega Nuke",
	-- The Arsenal's second round (docs/design/ARSENAL_V2.md, 2026-11-08).
	Scattershot = "Scattershot",
	-- The Arsenal's second round (docs/design/ARSENAL_V2.md, 2026-11-08).
	Artillery = "Artillery",
	ArtilleryShell = "Artillery Shell",
	Airfield = "Airfield",
	AirStrike = "Air Strike",
	Railgun = "Railgun",
	RailgunShot = "Railgun Shot",
	-- Our own (ARSENAL_V2, 2026-11-09): the plane that drops them.
	Paratroopers = "Paratroopers",
	CoastalBattery = "Coastal Battery",
	Sabotage = "Sabotage", -- the lit fuse on its target
	FieldWorks = "Field Works",
})
export type UnitType = string

-- GameTypes.ts AllPlayers: the "everyone" emoji recipient.
GameTypes.AllPlayers = "AllPlayers"

local U = GameTypes.UnitType
-- GameTypes.ts unit groups, in OpenFront's order (callers iterate them).
-- Conquest adds its Arsenal's Mega Nuke, so a blast never deletes the bomb itself.
GameTypes.Nukes = table.freeze({ U.AtomBomb, U.HydrogenBomb, U.MIRVWarhead, U.MIRV, U.MegaNuke, U.Scattershot })
GameTypes.BuildableAttacks = table.freeze({ U.AtomBomb, U.HydrogenBomb, U.MIRV, U.Warship })
-- Conquest appends its Arsenal's Artillery (nukes destroy it, spacing and
-- capture apply); without the Arsenal none exist, so OpenFront's order holds.
GameTypes.Structures = table.freeze({ U.City, U.DefensePost, U.SAMLauncher, U.MissileSilo, U.Port, U.Factory, U.Artillery, U.Airfield, U.Railgun, U.CoastalBattery })
GameTypes.BuildMenus = table.freeze({
	U.City, U.DefensePost, U.SAMLauncher, U.MissileSilo, U.Port, U.Factory,
	U.AtomBomb, U.HydrogenBomb, U.MIRV, U.Warship,
})
GameTypes.PlayerBuildable = table.freeze({
	U.City, U.DefensePost, U.SAMLauncher, U.MissileSilo, U.Port, U.Factory,
	U.AtomBomb, U.HydrogenBomb, U.MIRV, U.Warship, U.TransportShip,
})

local function setOf(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, t in list do
		set[t] = true
	end
	return table.freeze(set)
end
GameTypes.isStructure = setOf(GameTypes.Structures)
GameTypes.isNuke = setOf(GameTypes.Nukes)

-- Bulk upgrades: the most of one structure bought in a single intent.
GameTypes.MAX_UPGRADE_AMOUNT = 50

-- Numeric, like the TS enum (TerrainType.Plains == 0).
GameTypes.TerrainType = table.freeze({
	Plains = 0,
	Highland = 1,
	Mountain = 2,
	Ocean = 3,
	Impassable = 4,
})
export type TerrainType = number

return table.freeze(GameTypes)
