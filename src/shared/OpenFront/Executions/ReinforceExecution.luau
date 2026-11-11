--!strict
--!native
-- Conquest's Arsenal, not OpenFront: Reinforcements. For gold, a player who
-- unlocked it gets a share of their troop limit at once (never above the
-- limit), then waits out a cooldown. Only with gameConfig.extraWeapons.
-- Counters: the gold, the cooldown, and the cap at the troop limit.

local Config = require(script.Parent.Parent.Config)
local Format = require(script.Parent.Parent.Format)

local ReinforceExecution = {}
ReinforceExecution.__index = ReinforceExecution

function ReinforceExecution.new(player: any)
	return setmetatable({ player = player, active = true, mg = nil :: any }, ReinforceExecution)
end

function ReinforceExecution.init(self: any, mg: any, _ticks: number)
	self.mg = mg
end

-- Troops it would add now, or nil and why not.
function ReinforceExecution.check(mg: any, player: any): (number?, string?)
	if not player:hasExtraWeapon("reinforcements") then
		return nil, "locked"
	end
	if not player:isAlive() or mg:inSpawnPhase() then
		return nil, "notNow"
	end
	if (player.reinforceReadyAt or 0) > mg:ticks() then
		return nil, "cooldown"
	end
	if player:gold() < Config.REINFORCE_GOLD then
		return nil, "gold"
	end
	local max = mg:config():maxTroops(player)
	local add = math.floor(math.min(max * Config.REINFORCE_SHARE, max - player:troops()))
	if add <= 0 then
		return nil, "full"
	end
	return add, nil
end

function ReinforceExecution.tick(self: any, _ticks: number)
	self.active = false
	local mg, player = self.mg, self.player
	local add = ReinforceExecution.check(mg, player)
	if add == nil then
		return
	end
	player:removeGold(Config.REINFORCE_GOLD)
	player:addTroops(add)
	player.reinforceReadyAt = mg:ticks() + Config.REINFORCE_COOLDOWN
	mg:displayMessage("events_display.reinforcements_arrived", "REINFORCEMENTS", player:id(), nil, { troops = Format.renderTroops(add) })
end

function ReinforceExecution.isActive(self: any): boolean
	return self.active
end

function ReinforceExecution.activeDuringSpawnPhase(_self: any): boolean
	return false
end

return ReinforceExecution
