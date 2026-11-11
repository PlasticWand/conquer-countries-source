--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/SharedWaterCache.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- For each non-tribe player, the water bodies on its coast that a trading
-- partner also touches (the ocean always counts, as -1), or nil. Nations
-- use it to decide where ports can trade. Rebuilt every 30 ticks; each
-- player's coast is rescanned only when its land or the water changed.

local GameTypes = require(script.Parent.Parent.Parent.GameTypes)

local TTL_TICKS = 30
local OCEAN_SENTINEL = -1

local SharedWaterCache = {}
SharedWaterCache.__index = SharedWaterCache

export type SharedWaterCache = typeof(setmetatable(
	{} :: { game: any, tick: number, byPlayer: { [any]: { [number]: boolean } | false }?, playerWater: { [any]: any } },
	SharedWaterCache
))

function SharedWaterCache.new(game: any): SharedWaterCache
	return setmetatable({ game = game, tick = -math.huge, byPlayer = nil, playerWater = {} }, SharedWaterCache)
end

-- A set (comp -> true) or nil.
function SharedWaterCache.get(self: SharedWaterCache, player: any): { [number]: boolean }?
	local tick = self.game:ticks()
	if self.byPlayer == nil or tick - self.tick >= TTL_TICKS then
		self.byPlayer = self:_build()
		self.tick = tick
	end
	local v = (self.byPlayer :: any)[player]
	return if v then v else nil
end

function SharedWaterCache._waterFor(self: SharedWaterCache, player: any, waterVersion: number): any
	local game = self.game
	-- Conquest: only shore tiles are read, so shoreVersion (Player.luau).
	local tileVersion = player:shoreVersion()
	local cached = self.playerWater[player]
	if cached ~= nil and cached.tileVersion == tileVersion and cached.waterVersion == waterVersion then
		return cached
	end
	local hasOcean = false
	local lakes: { number } = {}
	local seen: { [number]: boolean } = {}
	local function visit(n: number)
		if not game:isWater(n) then
			return
		end
		if game:map():isOcean(n) then
			hasOcean = true
			return
		end
		local comp = game:getWaterComponent(n)
		if comp ~= nil and not seen[comp] then
			seen[comp] = true
			table.insert(lakes, comp)
		end
	end
	player:borderTiles():forEach(function(tile: number)
		if game:isShore(tile) then
			game:forEachNeighbor(tile, visit)
		end
	end)
	local entry = { tileVersion = tileVersion, waterVersion = waterVersion, hasOcean = hasOcean, lakes = lakes }
	self.playerWater[player] = entry
	return entry
end

function SharedWaterCache._build(self: SharedWaterCache): { [any]: { [number]: boolean } | false }
	local game = self.game
	local map: any = game:map()
	local waterVersion = if map.waterVersion then map:waterVersion() else 0
	local order, water = {}, {}
	local partners: { [number]: { any } } = {}
	for _, player in game:players() do
		if player:type() ~= GameTypes.PlayerType.Bot then
			local w = self:_waterFor(player, waterVersion)
			table.insert(order, player)
			water[player] = w
			for _, c in w.lakes do
				partners[c] = partners[c] or {}
				table.insert(partners[c], player)
			end
		end
	end
	local result: { [any]: any } = {}
	for _, player in order do
		local w = water[player]
		local shared: { [number]: boolean } = {}
		local any = false
		if w.hasOcean then
			shared[OCEAN_SENTINEL] = true
			any = true
		end
		for _, c in w.lakes do
			for _, other in (partners[c] or {}) :: { any } do
				if other ~= player and player:canTrade(other) then
					shared[c] = true
					any = true
					break
				end
			end
		end
		result[player] = if any then shared else false
	end
	return result
end

return SharedWaterCache
