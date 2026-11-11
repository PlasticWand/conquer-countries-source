--!strict
--!native
-- Conquest's own Arsenal item (not OpenFront or RoWorld;
-- docs/design/ARSENAL_V2.md, Field Works; Codex's idea, Bruno 2026-11-09).
--
-- Temporary earthworks on our own land near a front (Player.fieldWorksSpawn).
-- Built in BUILD ticks, they stand LIFETIME ticks, then go; they go at once
-- if their tile stops being ours. While finished and not dark they give our
-- tiles within RADIUS OpenFront's defence-post effect (AttackExecution reads
-- it). The game's `fieldWorksCount` counts standing ones, so the attack
-- lookup stays OpenFront's when there are none.

local Config = require(script.Parent.Parent.Config)
local GameTypes = require(script.Parent.Parent.GameTypes)

local UnitType = GameTypes.UnitType

local FieldWorksExecution = {}
FieldWorksExecution.__index = FieldWorksExecution

FieldWorksExecution.RADIUS = 15
-- Tiles from the placement to enemy land.
FieldWorksExecution.NEAR_FRONT = 5
FieldWorksExecution.BUILD = 10
FieldWorksExecution.LIFETIME = 60 * 10
FieldWorksExecution.MAX = 2
-- Ticks from one placement to the next (Rapid Reload halves it).
FieldWorksExecution.COOLDOWN = 30 * 10

export type FieldWorksExecution = typeof(setmetatable(
	{} :: { active: boolean, mg: any, player: any, tile: number, works: any, builtAt: number },
	FieldWorksExecution
))

function FieldWorksExecution.new(player: any, tile: number): FieldWorksExecution
	return setmetatable({ active = true, mg = nil, player = player, tile = tile, works = nil, builtAt = 0 }, FieldWorksExecution)
end

function FieldWorksExecution.init(self: FieldWorksExecution, mg: any, _ticks: number)
	self.mg = mg
end

function FieldWorksExecution._remove(self: FieldWorksExecution)
	if self.works:isActive() then
		self.works:delete(false)
	end
	self.mg.fieldWorksCount -= 1
	self.active = false
end

function FieldWorksExecution.tick(self: FieldWorksExecution, ticks: number)
	local mg, player = self.mg, self.player
	if self.works == nil then
		local spawn = player:canBuild(UnitType.FieldWorks, self.tile)
		if spawn == false then
			self.active = false
			return
		end
		player.fieldWorksReadyAt = ticks + Config.rapidReload(player, FieldWorksExecution.COOLDOWN)
		local works = player:buildUnit(UnitType.FieldWorks, spawn :: number, {})
		works:setUnderConstruction(true)
		-- When it goes, for the client's countdown (Replication).
		works._expiresAt = ticks + FieldWorksExecution.BUILD + FieldWorksExecution.LIFETIME
		self.works = works
		self.builtAt = ticks
		mg.fieldWorksCount = (mg.fieldWorksCount or 0) + 1
		return
	end
	local works = self.works
	if not works:isActive() or mg:owner(works:tile()) ~= works:owner() then
		self:_remove()
		return
	end
	if works:isUnderConstruction() and ticks - self.builtAt >= FieldWorksExecution.BUILD then
		works:setUnderConstruction(false)
	end
	if ticks >= works._expiresAt then
		self:_remove()
	end
end

function FieldWorksExecution.isActive(self: FieldWorksExecution): boolean
	return self.active
end

function FieldWorksExecution.activeDuringSpawnPhase(_self: FieldWorksExecution): boolean
	return false
end

return FieldWorksExecution
