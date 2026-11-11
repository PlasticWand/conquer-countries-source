--!strict
-- Conquest's Arsenal (not OpenFront; docs/design/ARSENAL_V2.md): the extra
-- unit types a player builds once unlocked, in build-bar order, each with its
-- unlock key (Catalog's `weapon`, Profile.weapons, Player.hasExtraWeapon).
-- Every one also needs the match's extraWeapons switch. Nations never get
-- them.

local ArsenalUnits = {}

export type Entry = { type: string, key: string, lang: string }

-- Bombs first (after OpenFront's MIRV), then structures.
ArsenalUnits.BUILD = table.freeze({
	table.freeze({ type = "Mega Nuke", key = "megaNuke", lang = "mega_nuke" }),
	table.freeze({ type = "Scattershot", key = "scattershot", lang = "scattershot" }),
	table.freeze({ type = "Artillery", key = "artillery", lang = "artillery" }),
	table.freeze({ type = "Coastal Battery", key = "coastalBattery", lang = "coastal_battery" }),
	table.freeze({ type = "Field Works", key = "fieldWorks", lang = "field_works" }),
	table.freeze({ type = "Airfield", key = "airStrike", lang = "airfield" }),
	table.freeze({ type = "Air Strike", key = "airStrike", lang = "air_strike" }),
	table.freeze({ type = "Railgun", key = "railgun", lang = "railgun" }),
	table.freeze({ type = "Railgun Shot", key = "railgun", lang = "railgun_shot" }),
	table.freeze({ type = "Paratroopers", key = "paratroopers", lang = "paratroopers" }),
	table.freeze({ type = "Sabotage", key = "sabotage", lang = "sabotage" }),
}) :: { Entry }

-- Unit type -> unlock key.
local KEY: { [string]: string } = {}
for _, e in ArsenalUnits.BUILD do
	KEY[e.type] = e.key
end
ArsenalUnits.KEY = table.freeze(KEY)

-- Every unlock key the viewer is told about: the build items, the
-- Arsenal's actions (Reinforcements) and upgrades (Rapid Reload).
local KEYS = { "reinforcements", "rapidReload" }
for _, e in ArsenalUnits.BUILD do
	if not table.find(KEYS, e.key) then
		table.insert(KEYS, e.key)
	end
end
ArsenalUnits.KEYS = table.freeze(KEYS)

-- Aimed bombs: launched from a silo at a tile, like an Atom Bomb.
ArsenalUnits.AIMED = table.freeze({ ["Mega Nuke"] = true, Scattershot = true }) :: { [string]: boolean }

-- Strikes: launched from their own structure, not a silo (StrikeExecution).
ArsenalUnits.STRIKES = table.freeze({ ["Air Strike"] = "Airfield", ["Railgun Shot"] = "Railgun" }) :: { [string]: string }

return ArsenalUnits
