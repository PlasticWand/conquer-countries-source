--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/TribeSpawner.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Creates the spawn executions for a match's tribes: positioned custom
-- tribes first, then random spots with themed names. Purchased tribe names
-- (an OpenFront store feature) are not ported.

local GameTypes = require(script.Parent.Parent.GameTypes)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local SpawnExecution = require(script.Parent.SpawnExecution)
local TribeNames = require(script.Parent.Parent.TribeNames)
local Util = require(script.Parent.Parent.Util)

local PlayerType = GameTypes.PlayerType

local TribeSpawner = {}
TribeSpawner.__index = TribeSpawner

export type TribeSpawner = typeof(setmetatable(
	{} :: {
		gs: any,
		gameID: string,
		random: PseudoRandom.PseudoRandom,
		tribeNameData: TribeNames.TribeNameData,
		usedCustomTribes: { [string]: true },
		nationTiles: { [number]: true },
	},
	TribeSpawner
))

-- `nationCells`: { x, y } spawn cells of nations, which custom tribes avoid.
function TribeSpawner.new(gs: any, gameID: string, nationCells: { { x: number, y: number } }?): TribeSpawner
	local nationTiles: { [number]: true } = {}
	local cells: { { x: number, y: number } } = nationCells or {}
	for _, c in cells do
		if gs:isValidCoord(c.x, c.y) then
			nationTiles[gs:ref(c.x, c.y)] = true
		end
	end
	return setmetatable({
		gs = gs,
		gameID = gameID,
		-- A different seed from the game runner's, so tribe IDs never collide.
		random = PseudoRandom.new(Util.simpleHash(gameID) + 2),
		tribeNameData = TribeNames.resolveTribeNameData(gs:config():gameConfig().gameMap),
		usedCustomTribes = {},
		nationTiles = nationTiles,
	}, TribeSpawner)
end

function TribeSpawner.spawnTribes(self: TribeSpawner, numTribes: number): { any }
	local tribes = {}
	local customTribes = self.tribeNameData.customTribes
	if customTribes ~= nil then
		for _, ct in customTribes do
			if ct.coordinates then
				if #tribes >= numTribes then
					break
				end
				local exec = self:_spawnPositionedTribe(ct)
				if exec ~= nil then
					table.insert(tribes, exec)
					self.usedCustomTribes[ct.name] = true
				end
			end
		end
	end
	while #tribes < numTribes do
		table.insert(tribes, self:spawnTribe(self:_randomTribeName()))
	end
	return tribes
end

function TribeSpawner.spawnTribe(self: TribeSpawner, tribeName: string): any
	return SpawnExecution.new(self.gameID, {
		name = tribeName,
		playerType = PlayerType.Bot,
		clientID = nil,
		id = self.random:nextID(),
	})
end

function TribeSpawner._spawnPositionedTribe(self: TribeSpawner, ct: TribeNames.CustomTribe): any?
	local coords = ct.coordinates :: { number }
	local compact = self.gs:config():gameConfig().gameMapSize == GameTypes.GameMapSize.Compact
	local x = if compact then math.floor(coords[1] / 2) else coords[1]
	local y = if compact then math.floor(coords[2] / 2) else coords[2]
	if not self.gs:isValidCoord(x, y) then
		return nil
	end
	local tile = self.gs:ref(x, y)
	if not self.gs:isLand(tile) or self.gs:hasOwner(tile) or self.gs:isImpassable(tile) or self.nationTiles[tile] then
		return nil
	end
	return SpawnExecution.new(self.gameID, {
		name = ct.name,
		playerType = PlayerType.Bot,
		clientID = nil,
		id = self.random:nextID(),
	}, tile)
end

function TribeSpawner._randomTribeName(self: TribeSpawner): string
	local data = self.tribeNameData
	-- Custom tribes first, without repeats until they run out.
	if data.customTribes ~= nil then
		local available = {}
		for _, ct in data.customTribes do
			if ct.coordinates == nil and not self.usedCustomTribes[ct.name] then
				table.insert(available, ct)
			end
		end
		if #available > 0 then
			local chosen = available[self.random:nextInt(0, #available) + 1]
			self.usedCustomTribes[chosen.name] = true
			return chosen.name
		end
	end
	local prefixIndex = self.random:nextInt(0, #data.prefixes)
	local suffixIndex = self.random:nextInt(0, #data.suffixes)
	return `{data.prefixes[prefixIndex + 1]} {data.suffixes[suffixIndex + 1]}`
end

return TribeSpawner
