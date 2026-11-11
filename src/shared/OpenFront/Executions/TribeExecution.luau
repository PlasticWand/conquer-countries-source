--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/TribeExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A tribe (PlayerType Bot) acts every 40-80 ticks. It accepts every
-- alliance, deletes captured structures, attacks neighbouring traitors,
-- expands into free land, then picks random targets.

local AiAttackBehavior = require(script.Parent.AiAttackBehavior)
local AllianceExtensionExecution = require(script.Parent.AllianceExtensionExecution)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local Util = require(script.Parent.Parent.Util)

local TribeExecution = {}
TribeExecution.__index = TribeExecution

export type TribeExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		random: PseudoRandom.PseudoRandom,
		mg: any,
		tribe: any,
		neighborsTerraNullius: boolean,
		attackBehavior: AiAttackBehavior.AiAttackBehavior?,
		attackRate: number,
		attackTick: number,
		triggerRatio: number,
		reserveRatio: number,
		expandRatio: number,
	},
	TribeExecution
))

function TribeExecution.new(tribe: any): TribeExecution
	local random = PseudoRandom.new(Util.simpleHash(tribe:id()))
	local attackRate = random:nextInt(40, 80)
	local attackTick = random:nextInt(0, attackRate)
	local triggerRatio = random:nextInt(50, 60) / 100
	local reserveRatio = random:nextInt(30, 40) / 100
	local expandRatio = random:nextInt(10, 20) / 100
	return setmetatable({
		active = true,
		random = random,
		mg = nil,
		tribe = tribe,
		neighborsTerraNullius = true,
		attackBehavior = nil,
		attackRate = attackRate,
		attackTick = attackTick,
		triggerRatio = triggerRatio,
		reserveRatio = reserveRatio,
		expandRatio = expandRatio,
	}, TribeExecution)
end

function TribeExecution.activeDuringSpawnPhase(_self: TribeExecution): boolean
	return false
end

function TribeExecution.init(self: TribeExecution, mg: any, _ticks: number)
	self.mg = mg
end

function TribeExecution.tick(self: TribeExecution, ticks: number)
	if ticks % self.attackRate ~= self.attackTick then
		return
	end
	if not self.tribe:isAlive() then
		-- removeOnDeath is called from the tribe's PlayerExecution
		self.active = false
		return
	end
	if self.attackBehavior == nil then
		local behavior = AiAttackBehavior.new(
			self.random,
			self.mg,
			self.tribe,
			self.triggerRatio,
			self.reserveRatio,
			self.expandRatio
		)
		self.attackBehavior = behavior
		-- Send an attack on the first tick
		behavior:sendAttack(self.mg:terraNullius())
		return
	end
	self:_acceptAllAllianceRequests()
	self:_deleteNextStructure()
	self:_maybeAttack()
end

function TribeExecution._acceptAllAllianceRequests(self: TribeExecution)
	for _, req in self.tribe:incomingAllianceRequests() do
		req:accept()
	end
	for _, alliance in self.tribe:alliances() do
		-- Only a human ally can ask to renew (the events panel's button); the
		-- tribe agrees.
		if alliance:onlyOneAgreedToExtend() then
			local human = alliance:other(self.tribe)
			self.mg:addExecution(AllianceExtensionExecution.new(self.tribe, human:id()))
		end
	end
end

local STRUCTURES = {
	["City"] = true,
	["Defense Post"] = true,
	["SAM Launcher"] = true,
	["Missile Silo"] = true,
	["Port"] = true,
	["Factory"] = true,
}

function TribeExecution._deleteNextStructure(self: TribeExecution)
	if not self.tribe:canDeleteUnit() then
		return
	end
	for _, unit in self.tribe:units() do
		if STRUCTURES[unit:type()] and not unit:isMarkedForDeletion() then
			self.mg:addExecution(require(script.Parent.DeleteUnitExecution).new(self.tribe, unit:id()))
			return
		end
	end
end

function TribeExecution._maybeAttack(self: TribeExecution)
	local behavior = self.attackBehavior
	if behavior == nil then
		error("not initialized")
	end
	local toAttack = behavior:getNeighborTraitorToAttack()
	if toAttack ~= nil then
		local odds = if self.tribe:isFriendly(toAttack) then 6 else 3
		if self.random:chance(odds) then
			-- Break an alliance with it before attacking
			local alliance = self.tribe:allianceWith(toAttack)
			if alliance ~= nil then
				self.tribe:breakAlliance(alliance)
			end
			if behavior:sendAttack(toAttack) then
				return
			end
		end
	end
	if self.neighborsTerraNullius then
		local hasFree = false
		for _, n in self.tribe:nearby() do
			if not n:isPlayer() then
				hasFree = true
				break
			end
		end
		if hasFree then
			if behavior:sendAttack(self.mg:terraNullius()) then
				return
			end
		else
			self.neighborsTerraNullius = false
		end
	end
	behavior:attackRandomTarget()
end

function TribeExecution.isActive(self: TribeExecution): boolean
	return self.active
end

return TribeExecution
