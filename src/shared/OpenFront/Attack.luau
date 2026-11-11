--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/AttackImpl.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- One attack: who, against whom, how many troops are still committed, and
-- the tiles on its front. AttackExecution drives it. The border keeps JS
-- Set insertion order (nations sample defence-post spots from it).
-- clusteredPositions (front-label anchors) is ported with the label work.

local TileSet = require(script.Parent.TileSet)

local Attack = {}
Attack.__index = Attack

export type Attack = typeof(setmetatable(
	{} :: {
		_id: string,
		_target: any, -- Player or TerraNullius
		_attacker: any, -- Player
		_troops: number,
		_sourceTile: number?,
		_border: TileSet.TileSet, -- a JS Set: insertion order matters to nations
		_borderSize: number,
		_isActive: boolean,
		_retreating: boolean,
		_retreated: boolean,
	},
	Attack
))

function Attack.new(id: string, target: any, attacker: any, troops: number, sourceTile: number?): Attack
	return setmetatable({
		_id = id,
		_target = target,
		_attacker = attacker,
		_troops = troops,
		_sourceTile = sourceTile,
		_border = TileSet.new(),
		_borderSize = 0,
		_isActive = true,
		_retreating = false,
		_retreated = false,
	}, Attack)
end

function Attack.sourceTile(self: Attack): number?
	return self._sourceTile
end

function Attack.target(self: Attack): any
	return self._target
end

function Attack.attacker(self: Attack): any
	return self._attacker
end

function Attack.troops(self: Attack): number
	return self._troops
end

function Attack.setTroops(self: Attack, troops: number)
	self._troops = math.max(0, troops)
end

function Attack.isActive(self: Attack): boolean
	return self._isActive
end

function Attack.id(self: Attack): string
	return self._id
end

local function without(list: { any }, item: any): { any }
	local out = table.create(#list)
	for _, v in list do
		if v ~= item then
			table.insert(out, v)
		end
	end
	return out
end

-- AttackImpl.ts delete: unlink from both players' lists. Like the original's
-- filter(), it swaps in new arrays, so a loop already walking the old array
-- is not disturbed (AttackExecution.init relies on this).
function Attack.delete(self: Attack)
	local target = self._target
	if target:isPlayer() then
		target._incomingAttacks = without(target._incomingAttacks, self)
	end
	self._attacker._outgoingAttacks = without(self._attacker._outgoingAttacks, self)
	self._isActive = false
end

function Attack.orderRetreat(self: Attack)
	self._retreating = true
end

function Attack.executeRetreat(self: Attack)
	self._retreated = true
end

function Attack.retreating(self: Attack): boolean
	return self._retreating
end

function Attack.retreated(self: Attack): boolean
	return self._retreated
end

function Attack.borderTiles(self: Attack): TileSet.TileSet
	return self._border
end

function Attack.borderSize(self: Attack): number
	return self._borderSize
end

function Attack.clearBorder(self: Attack)
	self._borderSize = 0
	self._border:clear()
end

function Attack.addBorderTile(self: Attack, tile: number)
	if not self._border:has(tile) then
		self._borderSize += 1
		self._border:add(tile)
	end
end

function Attack.removeBorderTile(self: Attack, tile: number)
	if self._border:has(tile) then
		self._borderSize -= 1
		self._border:delete(tile)
	end
end

return Attack
