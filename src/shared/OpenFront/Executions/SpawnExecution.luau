--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/SpawnExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Places (or moves) a player's starting disc. A given tile is used as is;
-- otherwise a random free spot at least minDistanceBetweenPlayers from other
-- spawns (relaxed after 750 tries). The first spawn starts the player's
-- PlayerExecution, and a TribeExecution for tribes.

local ExecUtil = require(script.Parent.Util)
local GameTypes = require(script.Parent.Parent.GameTypes)
local PlayerExecution = require(script.Parent.PlayerExecution)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local TribeExecution = require(script.Parent.TribeExecution)
local Util = require(script.Parent.Parent.Util)

local PlayerType = GameTypes.PlayerType

local MAX_SPAWN_TRIES = 1_000
local RELAX_MIN_DIST_AT = 750

local SpawnExecution = {}
SpawnExecution.__index = SpawnExecution

export type SpawnExecution = typeof(setmetatable(
	{} :: {
		random: PseudoRandom.PseudoRandom,
		active: boolean,
		mg: any,
		queuedDuringSpawnPhase: boolean,
		playerInfo: any,
		tile: number?,
		fromIntent: boolean,
	},
	SpawnExecution
))

-- `fromIntent`: built from a client's spawn request (honoured only if sent
-- during the spawn phase). Internal callers place players deliberately.
function SpawnExecution.new(gameID: string, playerInfo: any, tile: number?, fromIntent: boolean?): SpawnExecution
	return setmetatable({
		random = PseudoRandom.new(Util.simpleHash(playerInfo.id) + Util.simpleHash(gameID)),
		active = true,
		mg = nil,
		queuedDuringSpawnPhase = false,
		playerInfo = playerInfo,
		tile = tile,
		fromIntent = fromIntent == true,
	}, SpawnExecution)
end

function SpawnExecution.init(self: SpawnExecution, mg: any, _ticks: number)
	self.mg = mg
	self.queuedDuringSpawnPhase = mg:inSpawnPhase()
end

function SpawnExecution.tick(self: SpawnExecution, _ticks: number)
	self.active = false
	local mg = self.mg
	-- An intent's tile is untrusted: reject anything off the map first.
	if self.tile ~= nil and not mg:isValidRef(self.tile) then
		return
	end
	local player
	if mg:hasPlayer(self.playerInfo.id) then
		player = mg:player(self.playerInfo.id)
	else
		player = mg:addPlayer(self.playerInfo)
	end
	if self.fromIntent and not self.queuedDuringSpawnPhase then
		return
	end
	-- Random spawn: no re-rolling.
	if mg:config():isRandomSpawn() and player:hasSpawned() then
		return
	end

	local prevTiles = player:tiles():values()
	for _, t in prevTiles do
		player:relinquish(t)
	end
	local center, tiles = self:_getSpawn(if mg:config():isRandomSpawn() then nil else self.tile)
	if center == nil or tiles == nil then
		for _, t in prevTiles do
			player:conquer(t)
		end
		return
	end
	for _, t in tiles do
		player:conquer(t)
	end
	if not player:hasSpawned() then
		mg:addExecution(PlayerExecution.new(player))
		if player:type() == PlayerType.Bot then
			mg:addExecution(TribeExecution.new(player))
		end
	end
	player:setSpawnTile(center)
	if mg:config():gameConfig().gameType == "Singleplayer" and self.playerInfo.playerType == PlayerType.Human then
		-- In singleplayer, the spawn phase ends when the player picks a spot.
		-- Conquest: with soloDeployCountdown it ends that many seconds after
		-- the first pick (DeployCountdownExecution); moving the capital
		-- doesn't restart it (Bruno, 2026-10-29: "just 5s and that's it").
		local countdown = mg:config():gameConfig().soloDeployCountdown
		if type(countdown) == "number" and countdown > 0 then
			if mg.deployDeadline == nil then
				mg.deployDeadline = mg:ticks() + math.ceil(countdown * 1000 / mg:config():msPerTick())
			end
		else
			mg:endSpawnPhase()
		end
	end
end

function SpawnExecution.isActive(self: SpawnExecution): boolean
	return self.active
end

function SpawnExecution.activeDuringSpawnPhase(_self: SpawnExecution): boolean
	return true
end

function SpawnExecution._getSpawn(self: SpawnExecution, center: number?): (number?, { number }?)
	local mg = self.mg
	if center ~= nil then
		local tiles = ExecUtil.getSpawnTiles(mg, center, false) :: { number }
		if #tiles == 0 then
			return nil, nil
		end
		return center, tiles
	end
	local spawnArea = self:_getTeamSpawnArea()
	local tries = 0
	while tries < MAX_SPAWN_TRIES do
		tries += 1
		local c = self:_randTile(spawnArea)
		if mg:isLand(c) and not mg:hasOwner(c) and not mg:isBorder(c) then
			local tooClose = false
			if tries <= RELAX_MIN_DIST_AT then
				local minDist = mg:config():minDistanceBetweenPlayers()
				for _, p in mg:allPlayers() do
					if p:id() ~= self.playerInfo.id then
						local spawnTile = p:spawnTile()
						if spawnTile ~= nil and mg:manhattanDist(spawnTile, c) < minDist then
							tooClose = true
							break
						end
					end
				end
			end
			if not tooClose then
				local tiles = ExecUtil.getSpawnTiles(mg, c, true)
				if tiles ~= nil then
					return c, tiles
				end
			end
		end
	end
	return nil, nil
end

function SpawnExecution._randTile(self: SpawnExecution, area: any?): number
	local mg = self.mg
	if area then
		local x = self.random:nextInt(area.x, area.x + area.width)
		local y = self.random:nextInt(area.y, area.y + area.height)
		return mg:ref(x, y)
	end
	local x = self.random:nextInt(0, mg:width())
	local y = self.random:nextInt(0, mg:height())
	return mg:ref(x, y)
end

function SpawnExecution._getTeamSpawnArea(self: SpawnExecution): any?
	local player = self.mg:player(self.playerInfo.id)
	local team = player:team()
	if team == nil then
		return nil
	end
	return self.mg:teamSpawnArea(team)
end

return SpawnExecution
