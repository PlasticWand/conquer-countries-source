--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/MissileSiloExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A finished silo: holds one missile per level, each reloading
-- SiloCooldown ticks after it was fired (oldest first).

local Config = require(script.Parent.Parent.Config)

local MissileSiloExecution = {}
MissileSiloExecution.__index = MissileSiloExecution

export type MissileSiloExecution = typeof(setmetatable({} :: { active: boolean, mg: any, silo: any }, MissileSiloExecution))

function MissileSiloExecution.new(silo: any): MissileSiloExecution
	return setmetatable({ active = true, mg = nil, silo = silo }, MissileSiloExecution)
end

function MissileSiloExecution.init(self: MissileSiloExecution, mg: any, _ticks: number)
	self.mg = mg
end

function MissileSiloExecution.tick(self: MissileSiloExecution, _ticks: number)
	if self.silo:isUnderConstruction() then
		return
	end
	if not self.silo:isActive() then
		self.active = false
		return
	end
	local frontTime = self.silo:missileTimerQueue()[1]
	if frontTime == nil then
		return
	end
	-- (Conquest's Rapid Reload halves it; Config.rapidReload.)
	local cooldown = Config.rapidReload(self.silo:owner(), self.mg:config():SiloCooldown()) - (self.mg:ticks() - frontTime)
	if cooldown <= 0 then
		self.silo:reloadMissile()
	end
end

function MissileSiloExecution.isActive(self: MissileSiloExecution): boolean
	return self.active
end

function MissileSiloExecution.activeDuringSpawnPhase(_self: MissileSiloExecution): boolean
	return false
end

return MissileSiloExecution
