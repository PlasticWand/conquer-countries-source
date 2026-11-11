--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/TransportShipUtils.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Where a transport ship lands and launches.

local SpatialQuery = require(script.Parent.Pathfinding.SpatialQuery)

local TransportShipUtils = {}

-- The launch shore for a boat to `tile`, or false.
function TransportShipUtils.canBuildTransportShip(game: any, player: any, tile: number): number | false
	if player:unitCount("Transport") >= game:config():boatMaxNumber() then
		return false
	end
	local dst = TransportShipUtils.targetTransportTile(game, player, tile)
	if dst == nil then
		return false
	end
	local other = game:owner(tile)
	if other == player then
		return false
	end
	if other:isPlayer() and not player:canAttackPlayer(other) then
		return false
	end
	return SpatialQuery.new(game):closestShoreByWater(player, dst) or false
end

-- The landing shore near `tile` that the attacker's boats can reach.
function TransportShipUtils.targetTransportTile(gm: any, attacker: any, tile: number): number?
	return SpatialQuery.new(gm):closestReachableShore(gm:owner(tile), attacker, tile)
end

function TransportShipUtils.bestShoreDeploymentSource(gm: any, player: any, dst: number): number?
	return SpatialQuery.new(gm):closestShoreByWater(player, dst)
end

return TransportShipUtils
