--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/NationExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- One AI nation.
--   - Spawn phase: spawns near its manifest position (or randomly) and hops
--     to a new spot every attackRate ticks until the phase ends.
--   - Then, every attackRate ticks (by difficulty, offset by attackTick):
--     emoji, embargo relations, alliances, MIRVs, structures, warships,
--     embargoes on hostile players, attacks, warship counters and nukes.
--     Structures are also considered at 1/3 and 2/3 of the interval.
--   - Every tick: retaliates against ships that hit it (not on Easy),
--     follows up boat landings and nuke strikes.

local GameTypes = require(script.Parent.Parent.GameTypes)
local HumanProtection = require(script.Parent.Parent.HumanProtection)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local Util = require(script.Parent.Parent.Util)

local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType

local Relation = { Hostile = 0, Distrustful = 1, Neutral = 2, Friendly = 3 }

local Nation = script.Parent.Nation

local NationExecution = {}
NationExecution.__index = NationExecution

export type NationExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		random: PseudoRandom.PseudoRandom,
		behaviorsInitialized: boolean,
		spawnExecAdded: boolean,
		emojiBehavior: any,
		mirvBehavior: any,
		attackBehavior: any,
		allianceBehavior: any,
		warshipBehavior: any,
		nukeBehavior: any,
		structureBehavior: any,
		mg: any,
		player: any,
		attackRate: number,
		attackTick: number,
		triggerRatio: number,
		reserveRatio: number,
		expandRatio: number,
		embargoMalusApplied: { [string]: boolean },
		gameID: string,
		nation: any,
	},
	NationExecution
))

function NationExecution.new(gameID: string, nation: any): NationExecution
	local random = PseudoRandom.new(Util.simpleHash(nation.playerInfo.id) + Util.simpleHash(gameID))
	local self = setmetatable({
		active = true,
		random = random,
		behaviorsInitialized = false,
		spawnExecAdded = false,
		emojiBehavior = nil,
		mirvBehavior = nil,
		attackBehavior = nil,
		allianceBehavior = nil,
		warshipBehavior = nil,
		nukeBehavior = nil,
		structureBehavior = nil,
		mg = nil,
		player = nil,
		attackRate = 0,
		attackTick = 0,
		triggerRatio = 0,
		reserveRatio = 0,
		expandRatio = 0,
		embargoMalusApplied = {},
		gameID = gameID,
		nation = nation,
	}, NationExecution)
	self.triggerRatio = random:nextInt(50, 60) / 100
	self.reserveRatio = random:nextInt(30, 40) / 100
	self.expandRatio = random:nextInt(10, 20) / 100
	return self
end

local ATTACK_RATES = {
	[Difficulty.Easy] = { 65, 100 }, -- slower reactions
	[Difficulty.Medium] = { 55, 70 },
	[Difficulty.Hard] = { 45, 60 },
	[Difficulty.Impossible] = { 30, 50 }, -- faster reactions
}

function NationExecution.init(self: NationExecution, mg: any, _ticks: number?)
	self.mg = mg
	local r = ATTACK_RATES[mg:config():gameConfig().difficulty]
	self.attackRate = self.random:nextInt(r[1], r[2])
	self.attackTick = self.random:nextInt(0, self.attackRate)
	if not mg:hasPlayer(self.nation.playerInfo.id) then
		self.player = mg:addPlayer(self.nation.playerInfo)
	else
		self.player = mg:player(self.nation.playerInfo.id)
	end
end

function NationExecution.tick(self: NationExecution, ticks: number)
	local mg = self.mg
	local player = self.player
	if
		self.behaviorsInitialized
		and player ~= nil
		and player:isAlive()
		and mg:config():gameConfig().difficulty ~= Difficulty.Easy
		and player:unitsConstructed(UnitType.Port) > 0
		and not mg:config():isUnitDisabled(UnitType.Warship)
	then
		self.warshipBehavior:trackShipsAndRetaliate()
	end
	if player == nil then
		return
	end
	-- Conquest's Takeover: a human commands this nation now; its AI stops.
	if player:type() ~= PlayerType.Nation then
		self.active = false
		return
	end

	if mg:inSpawnPhase() then
		if player:hasSpawned() then
			-- Hop to a new spot now and then during the spawn phase.
			if ticks % self.attackRate ~= self.attackTick then
				return
			end
		elseif self.spawnExecAdded then
			return
		end
		local SpawnExecution = require(script.Parent.SpawnExecution)
		if self.nation.spawnCell == nil then
			mg:addExecution(SpawnExecution.new(self.gameID, self.nation.playerInfo))
			self.spawnExecAdded = true
			return
		end
		local team = player:team()
		if team ~= nil then
			local area = mg:teamSpawnArea(team)
			if area ~= nil then
				local cell = self.nation.spawnCell
				local inArea = cell.x >= area.x and cell.x < area.x + area.width and cell.y >= area.y and cell.y < area.y + area.height
				if not inArea then
					mg:addExecution(SpawnExecution.new(self.gameID, self.nation.playerInfo))
					self.spawnExecAdded = true
					return
				end
			end
		end
		local rl = self:_randomSpawnLand()
		if rl == nil then
			return
		end
		mg:addExecution(SpawnExecution.new(self.gameID, self.nation.playerInfo, rl))
		self.spawnExecAdded = true
		return
	end

	if self.spawnExecAdded and not player:hasSpawned() then
		return
	end
	if not player:isAlive() then
		self.active = false
		return
	end
	if not self.behaviorsInitialized then
		self:_initializeBehaviors()
		self.attackBehavior:forceSendAttack(mg:terraNullius())
		return
	end

	self.attackBehavior:followUpLandings()
	self.nukeBehavior:followUpStrikes()

	if ticks % self.attackRate ~= self.attackTick then
		-- Structures also at 1/3 and 2/3 of the interval, so gold gets spent.
		if player:isAlive() then
			local offset = ticks % self.attackRate
			local oneThird = (self.attackTick + self.attackRate // 3) % self.attackRate
			local twoThirds = (self.attackTick + (self.attackRate * 2) // 3) % self.attackRate
			if offset == oneThird or offset == twoThirds then
				self.structureBehavior:handleStructures()
			end
		end
		return
	end

	-- Conquest: RoWorld's endgame capitulation (off in OpenFront's own rules).
	if HumanProtection.considerCapitulation(mg, player) then
		return
	end

	self.emojiBehavior:maybeSendCasualEmoji()
	self:_updateRelationsFromEmbargos()
	self.allianceBehavior:handleAllianceRequests()
	self.allianceBehavior:handleAllianceExtensionRequests()
	self.mirvBehavior:considerMIRV()
	self.structureBehavior:handleStructures()
	self.warshipBehavior:maybeSpawnWarship()
	self:_handleEmbargoesToHostileNations()
	self.attackBehavior:maybeAttack()
	self.warshipBehavior:counterWarshipInfestation()
	self.nukeBehavior:maybeSendNuke()
end

function NationExecution._initializeBehaviors(self: NationExecution)
	local random, mg, player = self.random, self.mg, self.player
	self.emojiBehavior = (require(Nation.NationEmojiBehavior) :: any).new(random, mg, player)
	self.mirvBehavior = (require(Nation.NationMIRVBehavior) :: any).new(random, mg, player, self.emojiBehavior)
	self.allianceBehavior = (require(Nation.NationAllianceBehavior) :: any).new(random, mg, player, self.emojiBehavior)
	self.warshipBehavior = (require(Nation.NationWarshipBehavior) :: any).new(random, mg, player, self.emojiBehavior)
	self.attackBehavior = (require(script.Parent.AiAttackBehavior) :: any).new(
		random,
		mg,
		player,
		self.triggerRatio,
		self.reserveRatio,
		self.expandRatio,
		self.allianceBehavior,
		self.emojiBehavior,
		self.warshipBehavior
	)
	self.nukeBehavior = (require(Nation.NationNukeBehavior) :: any).new(random, mg, player, self.attackBehavior, self.emojiBehavior)
	self.structureBehavior = (require(Nation.NationStructureBehavior) :: any).new(random, mg, player)
	self.behaviorsInitialized = true
end

function NationExecution._randomSpawnLand(self: NationExecution): number?
	local mg = self.mg
	local delta = 25
	for _ = 1, 50 do
		local cell = self.nation.spawnCell
		local x = self.random:nextInt(cell.x - delta, cell.x + delta)
		local y = self.random:nextInt(cell.y - delta, cell.y + delta)
		if mg:isValidCoord(x, y) then
			local tile = mg:ref(x, y)
			if mg:isLand(tile) and not mg:hasOwner(tile) and not mg:isImpassable(tile) then
				if not (mg:terrainType(tile) == GameTypes.TerrainType.Mountain and self.random:chance(2)) then
					return tile
				end
			end
		end
	end
	return nil
end

function NationExecution._updateRelationsFromEmbargos(self: NationExecution)
	local player = self.player
	local malus = -20
	for _, other in self.mg:players() do
		if other:id() ~= player:id() then
			if other:hasManualEmbargoAgainst(player) and not self.embargoMalusApplied[other:id()] then
				player:updateRelation(other, malus)
				self.embargoMalusApplied[other:id()] = true
			elseif not other:hasManualEmbargoAgainst(player) and self.embargoMalusApplied[other:id()] then
				player:updateRelation(other, -malus)
				self.embargoMalusApplied[other:id()] = nil
			end
		end
	end
end

function NationExecution._handleEmbargoesToHostileNations(self: NationExecution)
	local player = self.player
	local config = self.mg:config():gameConfig()
	local difficulty = config.difficulty
	local higher = difficulty == Difficulty.Hard or difficulty == Difficulty.Impossible
	local teamGame = config.gameMode == GameTypes.GameMode.Team
	for _, other in self.mg:players() do
		if other:id() ~= player:id() then
			-- Team games on higher difficulties: no trade outside the team.
			if teamGame and higher and other:type() ~= PlayerType.Bot and not player:isOnSameTeam(other) then
				if not player:hasEmbargoAgainst(other) then
					player:addEmbargo(other, false)
				end
			elseif player:relation(other) <= Relation.Hostile and not player:hasEmbargoAgainst(other) and not player:isOnSameTeam(other) then
				-- Hostile: embargo, kept until neutral again.
				player:addEmbargo(other, false)
			elseif player:relation(other) >= Relation.Neutral and player:hasEmbargoAgainst(other) and difficulty ~= Difficulty.Hard and difficulty ~= Difficulty.Impossible then
				player:stopEmbargo(other)
			elseif player:relation(other) >= Relation.Friendly and player:hasEmbargoAgainst(other) and difficulty ~= Difficulty.Impossible then
				player:stopEmbargo(other)
			end
		end
	end
end

function NationExecution.isActive(self: NationExecution): boolean
	return self.active
end

function NationExecution.activeDuringSpawnPhase(_self: NationExecution): boolean
	return true
end

return NationExecution
