--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/ConstructionExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- A build order. Structures are placed at once (paid on placement) and sit
-- under construction for their constructionDuration, then hand over to
-- their own execution. Nukes and warships are not placed here: their
-- executions validate and pay.

local GameTypes = require(script.Parent.Parent.GameTypes)

local UnitType = GameTypes.UnitType

local ConstructionExecution = {}
ConstructionExecution.__index = ConstructionExecution

export type ConstructionExecution = typeof(setmetatable(
	{} :: {
		structure: any,
		active: boolean,
		mg: any,
		ticksUntilComplete: number,
		player: any,
		constructionType: string,
		tile: number,
		rocketDirectionUp: boolean?,
		amount: number?,
		troops: number?,
	},
	ConstructionExecution
))

function ConstructionExecution.new(
	player: any,
	constructionType: string,
	tile: number,
	rocketDirectionUp: boolean?,
	amount: number?,
	troops: number? -- Conquest's Paratroopers: the troops asked for
): ConstructionExecution
	return setmetatable({
		structure = nil,
		active = true,
		mg = nil,
		ticksUntilComplete = 0,
		player = player,
		constructionType = constructionType,
		tile = tile,
		rocketDirectionUp = rocketDirectionUp,
		amount = amount,
		troops = troops,
	}, ConstructionExecution)
end

function ConstructionExecution.init(self: ConstructionExecution, mg: any, _ticks: number)
	self.mg = mg
	if mg:config():isUnitDisabled(self.constructionType) then
		self.active = false
		return
	end
	if not mg:isValidRef(self.tile) then
		self.active = false
		return
	end
end

function ConstructionExecution.tick(self: ConstructionExecution, _ticks: number)
	if self.structure == nil then
		local info = self.mg:unitInfo(self.constructionType)
		if not GameTypes.isStructure[self.constructionType] then
			self:_completeConstruction()
			self.active = false
			return
		end
		local spawnTile = self.player:canBuild(self.constructionType, self.tile)
		if spawnTile == false then
			self.active = false
			return
		end
		self.structure = self.player:buildUnit(self.constructionType, spawnTile, {})
		local duration = info.constructionDuration or 0
		if duration > 0 then
			self.structure:setUnderConstruction(true)
			self.ticksUntilComplete = duration
			return
		end
		self:_completeConstruction()
		self.active = false
		return
	end

	if not self.structure:isActive() then
		self.active = false
		return
	end
	if self.player ~= self.structure:owner() then
		self.player = self.structure:owner()
	end
	if self.ticksUntilComplete == 0 then
		self.player = self.structure:owner()
		self:_completeConstruction()
		self.active = false
		return
	end
	self.ticksUntilComplete -= 1
end

function ConstructionExecution._completeConstruction(self: ConstructionExecution)
	if self.structure then
		self.structure:setUnderConstruction(false)
	end
	local player = self.player
	local mg = self.mg
	local Executions = script.Parent
	local t = self.constructionType
	if t == UnitType.AtomBomb or t == UnitType.HydrogenBomb or t == UnitType.MegaNuke or t == UnitType.Scattershot then
		local NukeExecution = require(Executions.NukeExecution) :: any
		for _ = 1, self.amount or 1 do
			mg:addExecution(NukeExecution.new(t, player, self.tile, nil, -1, 0, self.rocketDirectionUp))
		end
	elseif t == UnitType.MIRV then
		mg:addExecution((require(Executions.MIRVExecution) :: any).new(player, self.tile))
	elseif t == UnitType.Warship then
		mg:addExecution((require(Executions.WarshipExecution) :: any).new({ owner = player, patrolTile = self.tile }))
	elseif t == UnitType.Port then
		mg:addExecution((require(Executions.PortExecution) :: any).new(self.structure))
	elseif t == UnitType.MissileSilo then
		mg:addExecution((require(Executions.MissileSiloExecution) :: any).new(self.structure))
	elseif t == UnitType.DefensePost then
		mg:addExecution((require(Executions.DefensePostExecution) :: any).new(self.structure))
	elseif t == UnitType.SAMLauncher then
		mg:addExecution((require(Executions.SAMLauncherExecution) :: any).new(player, nil, self.structure))
	elseif t == UnitType.City then
		mg:addExecution((require(Executions.CityExecution) :: any).new(self.structure))
	elseif t == UnitType.Factory then
		mg:addExecution((require(Executions.FactoryExecution) :: any).new(self.structure))
	elseif t == UnitType.Artillery then
		mg:addExecution((require(Executions.ArtilleryExecution) :: any).new(self.structure))
	elseif t == UnitType.CoastalBattery then
		mg:addExecution((require(Executions.CoastalBatteryExecution) :: any).new(self.structure))
	elseif t == UnitType.Airfield or t == UnitType.Railgun then
		mg:addExecution((require(Executions.LauncherExecution) :: any).new(self.structure))
	elseif t == UnitType.AirStrike or t == UnitType.RailgunShot then
		mg:addExecution((require(Executions.StrikeExecution) :: any).new(t, player, self.tile))
	elseif t == UnitType.FieldWorks then
		mg:addExecution((require(Executions.FieldWorksExecution) :: any).new(player, self.tile))
	elseif t == UnitType.Sabotage then
		mg:addExecution((require(Executions.SabotageExecution) :: any).new(player, self.tile))
	elseif t == UnitType.Paratroopers then
		mg:addExecution((require(Executions.ParatroopersExecution) :: any).new(player, self.tile, self.troops))
	end
end

function ConstructionExecution.isActive(self: ConstructionExecution): boolean
	return self.active
end

function ConstructionExecution.activeDuringSpawnPhase(_self: ConstructionExecution): boolean
	return false
end

return ConstructionExecution
