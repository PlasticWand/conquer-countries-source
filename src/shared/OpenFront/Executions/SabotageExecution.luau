--!strict
--!native
-- Conquest's own Arsenal item (not OpenFront or RoWorld;
-- docs/design/ARSENAL_V2.md, Sabotage, Bruno 2026-11-09).
--
-- Lights a fuse (a public `Sabotage` unit on the target, with targetUnit)
-- on the enemy building Player.sabotageTarget picks. After FUSE ticks the
-- building goes dark for DARK ticks (Unit.isDark): it doesn't fire, launch,
-- defend or earn. The game's `darkCount` counts dark buildings, so the
-- defence-post lookup stays OpenFront's when there are none.

local Config = require(script.Parent.Parent.Config)
local GameTypes = require(script.Parent.Parent.GameTypes)

local UnitType = GameTypes.UnitType

local SabotageExecution = {}
SabotageExecution.__index = SabotageExecution

-- Tiles from our land to the building.
SabotageExecution.REACH = 60
SabotageExecution.FUSE = 5 * 10
SabotageExecution.DARK = 30 * 10
-- Ticks from one lit fuse to the next (Rapid Reload halves it).
SabotageExecution.COOLDOWN = 90 * 10

export type SabotageExecution = typeof(setmetatable(
	{} :: { active: boolean, mg: any, player: any, tile: number, fuse: any, target: any, litAt: number, darkUntil: number? },
	SabotageExecution
))

function SabotageExecution.new(player: any, tile: number): SabotageExecution
	return setmetatable({ active = true, mg = nil, player = player, tile = tile, fuse = nil, target = nil, litAt = 0, darkUntil = nil }, SabotageExecution)
end

function SabotageExecution.init(self: SabotageExecution, mg: any, _ticks: number)
	self.mg = mg
end

-- "unit_type.sam_launcher" for a SAM Launcher.
local function unitKey(unit: any): string
	local lang = string.lower((string.gsub(unit:type(), " ", "_")))
	return `unit_type.{lang}`
end

function SabotageExecution.tick(self: SabotageExecution, ticks: number)
	local mg, player = self.mg, self.player
	if self.fuse == nil then
		if player:canBuild(UnitType.Sabotage, self.tile) == false then
			self.active = false
			return
		end
		local target = player:sabotageTarget(self.tile)
		self.target = target
		player.sabotageReadyAt = ticks + Config.rapidReload(player, SabotageExecution.COOLDOWN)
		self.fuse = player:buildUnit(UnitType.Sabotage, target:tile(), { targetUnit = target, targetTile = target:tile() })
		self.litAt = ticks
		mg:displayIncomingUnit(self.fuse:id(), "events_display.sabotage_inbound", "SABOTAGE_INBOUND", target:owner():id())
		return
	end
	if self.darkUntil == nil then
		if ticks - self.litAt < SabotageExecution.FUSE then
			return
		end
		local target, fuse = self.target, self.fuse
		local owner = target:owner()
		if fuse:isActive() then
			fuse:setReachedTarget()
			fuse:delete(false)
		end
		-- Gone, or ours or a friend's now: it fizzles.
		if not target:isActive() or owner == player or player:isFriendly(owner) then
			self.active = false
			return
		end
		self.darkUntil = ticks + SabotageExecution.DARK
		target:setDarkUntil(self.darkUntil)
		mg.darkCount = (mg.darkCount or 0) + 1
		mg:displayMessage("events_display.sabotaged", "SABOTAGED", owner:id(), nil, {
			unit = unitKey(target),
			name = player:displayName(),
		})
		return
	end
	if ticks >= (self.darkUntil :: number) then
		mg.darkCount -= 1
		self.active = false
	end
end

function SabotageExecution.isActive(self: SabotageExecution): boolean
	return self.active
end

function SabotageExecution.activeDuringSpawnPhase(_self: SabotageExecution): boolean
	return false
end

return SabotageExecution
