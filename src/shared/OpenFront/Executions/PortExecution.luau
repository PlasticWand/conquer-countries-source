--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/PortExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A finished port. Every 10 ticks (offset by its build tick) it rolls, once
-- per level, to send a trade ship to a port of a trading partner on the
-- same water body. The pick is weighted: by level, again for the closest
-- ports (not too close), and again for friendly owners.

local GameTypes = require(script.Parent.Parent.GameTypes)
local PseudoRandom = require(script.Parent.Parent.PseudoRandom)
local Util = require(script.Parent.Parent.Util)

local UnitType = GameTypes.UnitType

local PortExecution = {}
PortExecution.__index = PortExecution

export type PortExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		mg: any,
		port: any,
		random: PseudoRandom.PseudoRandom,
		checkOffset: number,
		tradeShipSpawnRejections: number,
	},
	PortExecution
))

function PortExecution.new(port: any): PortExecution
	return setmetatable({
		active = true,
		mg = nil,
		port = port,
		random = nil :: any,
		checkOffset = 0,
		tradeShipSpawnRejections = 0,
	}, PortExecution)
end

function PortExecution.init(self: PortExecution, mg: any, _ticks: number)
	self.mg = mg
	self.random = PseudoRandom.new(mg:ticks())
	self.checkOffset = mg:ticks() % 10
end

function PortExecution.tick(self: PortExecution, _ticks: number)
	local mg = self.mg
	if not self.port:isActive() then
		self.active = false
		return
	end
	if self.port:isUnderConstruction() then
		return
	end
	if not self.port:hasTrainStation() then
		self:_createStation()
	end
	if (mg:ticks() + self.checkOffset) % 10 ~= 0 then
		return
	end
	if not self:shouldSpawnTradeShip() then
		return
	end
	local ports = self:tradingPorts()
	if #ports == 0 then
		return
	end
	local port = self.random:randElement(ports)
	mg:addExecution(require(script.Parent.TradeShipExecution).new(self.port:owner(), self.port, port))
end

function PortExecution.shouldSpawnTradeShip(self: PortExecution): boolean
	local mg = self.mg
	local numTradeShips = mg:unitCount(UnitType.TradeShip)
	local portLevels = self.port:owner():unitCount(UnitType.Port)
	for _ = 1, self.port:level() do
		local spawnRate = mg:config():tradeShipSpawnRate(self.tradeShipSpawnRejections, numTradeShips, portLevels)
		if self.random:chance(spawnRate) then
			self.tradeShipSpawnRejections = 0
			return true
		end
		self.tradeShipSpawnRejections += 1
	end
	return false
end

function PortExecution._createStation(self: PortExecution)
	local mg = self.mg
	if mg:hasUnitNearby(self.port:tile(), mg:config():trainStationMaxRange(), UnitType.Factory) then
		mg:addExecution((require(script.Parent.TrainStationExecution) :: any).new(self.port))
	end
end

-- A probability list: a port listed twice is twice as likely to be picked.
function PortExecution.tradingPorts(self: PortExecution): { any }
	local mg = self.mg
	local myPort = self.port
	local owner = myPort:owner()
	-- Set<number> in insertion order
	local sourceComponents: { number } = {}
	local seenComp: { [number]: true } = {}
	for _, neighbor in mg:neighbors(myPort:tile()) do
		if mg:isWater(neighbor) then
			local comp = mg:getWaterComponent(neighbor)
			if comp ~= nil and not seenComp[comp] then
				seenComp[comp] = true
				table.insert(sourceComponents, comp)
			end
		end
	end
	local candidates = {}
	for _, p in mg:players() do
		if p ~= owner and p:canTrade(owner) then
			for _, other in p:units(UnitType.Port) do
				for _, comp in sourceComponents do
					if mg:hasWaterComponent(other:tile(), comp) then
						table.insert(candidates, other)
						break
					end
				end
			end
		end
	end
	local ports = Util.stableSort(candidates, function(p1, p2)
		return mg:manhattanDist(myPort:tile(), p1:tile()) < mg:manhattanDist(myPort:tile(), p2:tile())
	end)
	local config = mg:config()
	local weighted = {}
	local bonusCount = config:proximityBonusPortsNb(#ports)
	for i, otherPort in ports do
		local level = otherPort:level()
		local function push()
			for _ = 1, level do
				table.insert(weighted, otherPort)
			end
		end
		push()
		local tooClose = mg:manhattanDist(myPort:tile(), otherPort:tile()) < config:tradeShipShortRangeDebuff()
		local closeBonus = i - 1 < bonusCount
		if not tooClose and closeBonus then
			push()
		end
		if not tooClose and owner:isFriendly(otherPort:owner()) then
			push()
		end
	end
	return weighted
end

function PortExecution.isActive(self: PortExecution): boolean
	return self.active
end

function PortExecution.activeDuringSpawnPhase(_self: PortExecution): boolean
	return false
end

return PortExecution
