--!strict
-- Conquest's Arsenal (not OpenFront; docs/design/ARSENAL_V2.md, Bruno
-- 2026-11-08): structures take damage from Artillery shells (and later Air
-- Strikes and Railgun slugs). RoWorld's rule (reference/roworld 2be8efb,
-- Core/Rules.luau STRUCT_HP): a structure's health is lowered only by these
-- weapons; at 0 it loses a level and is whole again, or is destroyed at
-- level 1. Health exists only when the match has extra weapons on (Config
-- unitInfo maxHealth), so matches without the Arsenal stay OpenFront's.

local GameTypes = require(script.Parent.GameTypes)

local StructureDamage = {}

-- Max health by type (RoWorld's STRUCT_HP).
StructureDamage.MAX_HEALTH = table.freeze({
	City = 1000,
	Port = 1000,
	Factory = 1000,
	["SAM Launcher"] = 1000,
	["Missile Silo"] = 1000,
	["Defense Post"] = 600,
	Artillery = 600,
	Airfield = 800,
	Railgun = 1000,
	["Coastal Battery"] = 800, -- our own (ARSENAL_V2)
})

-- Lowers `unit`'s health by `damage`; at 0 it loses a level (whole again) or
-- is destroyed at level 1, credited to `attacker` (a Player).
function StructureDamage.damage(unit: any, damage: number, attacker: any)
	if not unit:isActive() or not unit:hasHealth() then
		return
	end
	local left = unit:health() - math.floor(damage)
	if left > 0 then
		unit._health = left
		return
	end
	if unit:level() > 1 then
		unit:decreaseLevel(attacker)
		unit._health = math.floor(unit:maxHealth())
	else
		unit:delete(true, attacker)
	end
end

-- Damages every structure within `radius` tiles of `tile` not owned by
-- `attacker` or a friend of theirs.
function StructureDamage.inRadius(mg: any, attacker: any, tile: number, radius: number, damage: number)
	local hit = {}
	for _, entry in mg:nearbyUnits(tile, radius, GameTypes.Structures, nil, true) do
		local u = entry.unit
		local owner = u:owner()
		if owner ~= attacker and not attacker:isFriendly(owner) then
			table.insert(hit, u)
		end
	end
	for _, u in hit do
		StructureDamage.damage(u, damage, attacker)
	end
end

return StructureDamage
