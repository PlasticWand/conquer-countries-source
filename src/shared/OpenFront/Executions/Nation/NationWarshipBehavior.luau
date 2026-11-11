--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/NationWarshipBehavior.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Nation warships:
--   - a first warship near a random own port (1 in 50 each decision)
--   - retaliation when a boat is sunk, a trade ship captured, or an enemy
--     boat heads for our shore uncovered (build or move a warship there;
--     the chance grows with difficulty)
--   - clearing sea lanes for boats (Hard and up)
--   - countering warship infestations when another player has many
--     warships and we are among the richest nations (Hard and up)

local Emoji = require(script.Parent.Parent.Parent.Data.Emoji)
local GameTypes = require(script.Parent.Parent.Parent.GameTypes)
local Rail = require(script.Parent.Parent.Parent.Rail)
local Util = require(script.Parent.Parent.Parent.Util)

local AllPlayers = GameTypes.AllPlayers
local Difficulty = GameTypes.Difficulty
local PlayerType = GameTypes.PlayerType
local UnitType = GameTypes.UnitType
local OrderedSet = Rail.OrderedSet

local function Construction(): any
	return require(script.Parent.Parent.ConstructionExecution)
end

local NationWarshipBehavior = {}
NationWarshipBehavior.__index = NationWarshipBehavior

export type NationWarshipBehavior = typeof(setmetatable(
	{} :: {
		trackedTransportShips: Rail.OrderedSet,
		trackedTradeShips: Rail.OrderedSet,
		trackedIncomingTransportShips: Rail.OrderedSet,
		dealtWithTransportShip: Rail.OrderedSet,
		random: any,
		game: any,
		player: any,
		emojiBehavior: any,
	},
	NationWarshipBehavior
))

function NationWarshipBehavior.new(random: any, game: any, player: any, emojiBehavior: any): NationWarshipBehavior
	return setmetatable({
		trackedTransportShips = OrderedSet.new(),
		trackedTradeShips = OrderedSet.new(),
		trackedIncomingTransportShips = OrderedSet.new(),
		dealtWithTransportShip = OrderedSet.new(),
		random = random,
		game = game,
		player = player,
		emojiBehavior = emojiBehavior,
	}, NationWarshipBehavior)
end

function NationWarshipBehavior._cost(self: NationWarshipBehavior, unitType: string, extraUnits: number?): number
	return self.game:unitInfo(unitType).cost(self.game, self.player, extraUnits or 0)
end

function NationWarshipBehavior.maybeSpawnWarship(self: NationWarshipBehavior): boolean
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.Warship) then
		return false
	end
	if not self.random:chance(50) then
		return false
	end
	local ports = player:units(UnitType.Port)
	local ships = player:units(UnitType.Warship)
	if #ports > 0 and #ships == 0 and player:gold() > self:_cost(UnitType.Warship) then
		local port = self.random:randElement(ports)
		local targetTile = self:_warshipSpawnTile(port:tile(), 250)
		if targetTile == nil then
			return false
		end
		if player:canBuild(UnitType.Warship, targetTile) == false then
			return false
		end
		game:addExecution(Construction().new(player, UnitType.Warship, targetTile))
		return true
	end
	return false
end

function NationWarshipBehavior._warshipSpawnTile(self: NationWarshipBehavior, portTile: number, radius: number): number?
	local game = self.game
	for _ = 1, 50 do
		local x = self.random:nextInt(game:x(portTile) - radius, game:x(portTile) + radius)
		local y = self.random:nextInt(game:y(portTile) - radius, game:y(portTile) + radius)
		if game:isValidCoord(x, y) then
			local tile = game:ref(x, y)
			if game:isWater(tile) then
				return tile
			end
		end
	end
	return nil
end

function NationWarshipBehavior.trackShipsAndRetaliate(self: NationWarshipBehavior)
	self:_trackTransportShipsAndRetaliate()
	self:_trackTradeShipsAndRetaliate()
	self:_trackIncomingTransportsAndRetaliate()
end

function NationWarshipBehavior._trackTransportShipsAndRetaliate(self: NationWarshipBehavior)
	if self.game:config():isUnitDisabled(UnitType.TransportShip) then
		return
	end
	for _, u in self.player:units(UnitType.TransportShip) do
		self.trackedTransportShips:add(u)
	end
	for _, ship in self.trackedTransportShips:values() do
		if not ship:isActive() then
			if ship:wasDestroyedByEnemy() and ship:destroyer() ~= nil then
				self:_maybeRetaliateWithWarship(ship:tile(), ship:destroyer(), "transport")
			end
			self.trackedTransportShips:delete(ship)
		end
	end
end

function NationWarshipBehavior._trackTradeShipsAndRetaliate(self: NationWarshipBehavior)
	for _, u in self.player:units(UnitType.TradeShip) do
		self.trackedTradeShips:add(u)
	end
	for _, ship in self.trackedTradeShips:values() do
		if not ship:isActive() then
			self.trackedTradeShips:delete(ship)
		elseif ship:owner():id() ~= self.player:id() then
			self:_maybeRetaliateWithWarship(ship:tile(), ship:owner(), "trade")
			self.trackedTradeShips:delete(ship)
		end
	end
end

function NationWarshipBehavior._trackIncomingTransportsAndRetaliate(self: NationWarshipBehavior)
	local game, player = self.game, self.player
	for _, p in game:units(UnitType.TransportShip) do
		local target = p:targetTile()
		-- JS truthiness: tile 0 counts as no target.
		-- Conquest (performance, exact): the cheap ownership test first; the
		-- conditions are pure reads, so their order doesn't change the result.
		if
			target ~= nil
			and target ~= 0
			and game:ownerID(target) == player:smallID()
			and p:owner():smallID() ~= player:smallID()
			and p:isActive()
			and not p:transportShipState().isRetreating
		then
			self.trackedIncomingTransportShips:add(p)
		end
	end
	for _, transport in self.trackedIncomingTransportShips:values() do
		local target = transport:targetTile()
		if not transport:isActive() or target == nil or transport:transportShipState().isRetreating then
			self.trackedIncomingTransportShips:delete(transport)
			self.dealtWithTransportShip:delete(transport)
		elseif not self.dealtWithTransportShip:has(transport) then
			if game:manhattanDist(transport:tile(), target) < 20 then
				self.dealtWithTransportShip:add(transport)
			elseif not transport:owner():isAlliedWith(player) then
				local covered = game:hasUnitNearby(target, 90, UnitType.Warship, player:id(), true)
				if not covered then
					for _, w in player:units(UnitType.Warship) do
						local patrol = w:warshipState().patrolTile
						if patrol ~= nil and game:manhattanDist(target, patrol) < 90 then
							covered = true
							break
						end
					end
				end
				if covered then
					self.dealtWithTransportShip:add(transport)
				else
					local ocean = self:_warshipSpawnTile(target, 30)
					if ocean ~= nil then
						self:_maybeRetaliateWithWarship(ocean, transport:owner(), "transport")
						self.dealtWithTransportShip:add(transport)
						break
					end
				end
			end
		end
	end
end

function NationWarshipBehavior._maybeRetaliateWithWarship(self: NationWarshipBehavior, tile: number, enemy: any, reason: string)
	local player = self.player
	if enemy == player then
		return
	end
	if #self:_warshipsCovering(tile) > 0 then
		return
	end
	if #player:units(UnitType.Warship) >= 10 then
		self:_maybeMoveWarship(tile)
		return
	end
	local d = self.game:config():gameConfig().difficulty
	if
		(d == Difficulty.Medium and self.random:nextInt(0, 100) < 15)
		or (d == Difficulty.Hard and self.random:nextInt(0, 100) < 50)
		or (d == Difficulty.Impossible and self.random:nextInt(0, 100) < 80)
	then
		if player:canBuild(UnitType.Warship, tile) == false then
			self:_maybeMoveWarship(tile)
			return
		end
		self.game:addExecution(Construction().new(player, UnitType.Warship, tile))
		self.emojiBehavior:maybeSendEmoji(enemy, Emoji.WARSHIP_RETALIATION)
		player:updateRelation(enemy, if reason == "trade" then -7.5 else -15)
	end
end

-- Sends (or builds) warships to a hostile warship blocking our boats:
-- as many as theirs on Hard, one more on Impossible.
function NationWarshipBehavior.clearSeaLane(self: NationWarshipBehavior, blocker: any)
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.Warship) then
		return
	end
	local d = game:config():gameConfig().difficulty
	local target = blocker:tile()
	local fleet = self:_hostileWarshipsNear(target)
	local wanted
	if d == Difficulty.Hard then
		wanted = fleet
	elseif d == Difficulty.Impossible then
		wanted = fleet + 1
	else
		return
	end
	local covering = self:_warshipsCovering(target)
	local component = game:getWaterComponent(target)
	local spare = {}
	for _, w in player:units(UnitType.Warship) do
		local state = w:warshipState()
		if
			not table.find(covering, w)
			and state.state == "patrolling"
			and game:getWaterComponent(w:tile()) == component
			and (state.patrolTile == nil or self:_hostileWarshipsNear(state.patrolTile) == 0)
		then
			table.insert(spare, w)
		end
	end
	spare = Util.stableSort(spare, function(a, b)
		return game:manhattanDist(a:tile(), target) < game:manhattanDist(b:tile(), target)
	end)
	local recruits = table.move(spare, 1, math.min(#spare, math.max(0, wanted - #covering)), 1, {})
	local builds = wanted - #covering - #recruits
	if builds > 0 then
		if #player:units(UnitType.Warship) + builds > 10 then
			return
		end
		local total = 0
		for i = 0, builds - 1 do
			total += self:_cost(UnitType.Warship, i)
		end
		if player:gold() < total then
			return
		end
		if player:canBuild(UnitType.Warship, target) == false then
			return
		end
	end
	for _, w in recruits do
		w:updateWarshipState({ patrolTile = target })
	end
	for _ = 1, builds do
		game:addExecution(Construction().new(player, UnitType.Warship, target))
	end
end

function NationWarshipBehavior._hostileWarshipsNear(self: NationWarshipBehavior, tile: number): number
	local n = 0
	for _, entry in self.game:nearbyUnits(tile, self.game:config():warshipTargettingRange(), UnitType.Warship) do
		if entry.unit:owner():canAttackPlayer(self.player, true) then
			n += 1
		end
	end
	return n
end

function NationWarshipBehavior._warshipsCovering(self: NationWarshipBehavior, tile: number): { any }
	local game = self.game
	local component = game:getWaterComponent(tile)
	local range = game:config():warshipPatrolRange()
	local out = {}
	for _, w in self.player:units(UnitType.Warship) do
		local patrol = w:warshipState().patrolTile
		if patrol ~= nil and game:getWaterComponent(w:tile()) == component and game:manhattanDist(patrol, tile) <= range then
			table.insert(out, w)
		end
	end
	return out
end

function NationWarshipBehavior._maybeMoveWarship(self: NationWarshipBehavior, tile: number)
	local game = self.game
	if not game:isWater(tile) then
		return
	end
	local candidates = {}
	for _, w in self.player:units(UnitType.Warship) do
		local patrol = w:warshipState().patrolTile
		if patrol ~= nil and game:manhattanDist(w:tile(), patrol) < 130 then
			table.insert(candidates, w)
		end
	end
	candidates = Util.stableSort(candidates, function(a, b)
		return game:manhattanDist(a:tile(), tile) < game:manhattanDist(b:tile(), tile)
	end)
	if candidates[1] then
		candidates[1]:updateWarshipState({ patrolTile = tile })
	end
end

function NationWarshipBehavior.counterWarshipInfestation(self: NationWarshipBehavior)
	if not self:_shouldCounterWarshipInfestation() then
		return
	end
	local isTeamGame = self.player:team() ~= nil
	if not self:_isRichPlayer(isTeamGame) then
		return
	end
	local target = if isTeamGame then self:_findTeamGameWarshipTarget() else self:_findFreeForAllWarshipTarget()
	if target ~= nil then
		self:_buildCounterWarship(target)
	end
end

function NationWarshipBehavior._shouldCounterWarshipInfestation(self: NationWarshipBehavior): boolean
	local game, player = self.game, self.player
	if game:config():isUnitDisabled(UnitType.Warship) then
		return false
	end
	local d = game:config():gameConfig().difficulty
	if d ~= Difficulty.Hard and d ~= Difficulty.Impossible then
		return false
	end
	if game:unitCount(UnitType.Warship) <= 10 then
		return false
	end
	if self:_cost(UnitType.Warship) > player:gold() then
		return false
	end
	if #player:units(UnitType.Port) == 0 then
		return false
	end
	if #player:units(UnitType.Warship) >= 10 then
		return false
	end
	return true
end

-- Among the three richest nations (of our team, in team games).
function NationWarshipBehavior._isRichPlayer(self: NationWarshipBehavior, isTeamGame: boolean): boolean
	local players = {}
	for _, p in self.game:players() do
		if p:type() ~= PlayerType.Human and (not isTeamGame or p:team() == self.player:team()) then
			table.insert(players, p)
		end
	end
	players = Util.stableSort(players, function(a, b)
		return a:gold() > b:gold()
	end)
	for i = 1, math.min(3, #players) do
		if players[i]:id() == self.player:id() then
			return true
		end
	end
	return false
end

function NationWarshipBehavior._findTeamGameWarshipTarget(self: NationWarshipBehavior): { player: any, warship: any }?
	local order, teams = {}, {}
	for _, p in self.game:players() do
		if not self.player:isFriendly(p) and p:id() ~= self.player:id() then
			local team = p:team()
			if team ~= nil then
				local key = tostring(team)
				local data = teams[key]
				if data == nil then
					data = { count = 0, players = {} }
					teams[key] = data
					table.insert(order, key)
				end
				data.count += #p:units(UnitType.Warship)
				table.insert(data.players, p)
			end
		end
	end
	for _, key in order do
		local data = teams[key]
		if data.count > 15 then
			local most = nil
			for _, p in data.players do
				local count = #p:units(UnitType.Warship)
				local maxCount = if most then #most:units(UnitType.Warship) else 0
				if count > maxCount then
					most = p
				end
			end
			if most then
				local warships = most:units(UnitType.Warship)
				if #warships > 3 then
					return { player = most, warship = self.random:randElement(warships) }
				end
			end
		end
	end
	return nil
end

function NationWarshipBehavior._findFreeForAllWarshipTarget(self: NationWarshipBehavior): { player: any, warship: any }?
	for _, enemy in self.game:players() do
		if not self.player:isFriendly(enemy) and enemy:id() ~= self.player:id() then
			local warships = enemy:units(UnitType.Warship)
			if #warships > 10 then
				return { player = enemy, warship = self.random:randElement(warships) }
			end
		end
	end
	return nil
end

function NationWarshipBehavior._buildCounterWarship(self: NationWarshipBehavior, target: { player: any, warship: any })
	local tile = target.warship:tile()
	if self.player:canBuild(UnitType.Warship, tile) == false then
		self:_maybeMoveWarship(tile)
		return
	end
	self.game:addExecution(Construction().new(self.player, UnitType.Warship, tile))
	self.emojiBehavior:sendEmoji(AllPlayers, Emoji.WARSHIP_RETALIATION)
end

return NationWarshipBehavior
