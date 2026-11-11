--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/nation/BotAnnexation.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Hard and Impossible nations take tribes in an order that walls others
-- in, so the engine annexes those for free (PlayerExecution hands a
-- territory surrounded by one player to that player).
--   - walledInBots: tribes that border only us and aren't under attack yet.
--   - planBotAttacks: a checkerboard of tribes across our front and the row
--     behind is left to be annexed; the tribes walling them in go first.
-- Sets and maps keep JS insertion order (ties and float sums depend on it).

local GameTypes = require(script.Parent.Parent.Parent.GameTypes)
local Rail = require(script.Parent.Parent.Parent.Rail)
local Util = require(script.Parent.Parent.Parent.Util)

local OrderedSet = Rail.OrderedSet
local PlayerType = GameTypes.PlayerType

local BotAnnexation = {}

type Surroundings = { bot: any, bordersUs: boolean, open: boolean, bots: Rail.OrderedSet }

-- Mirrors PlayerExecution's surrounded check over the bot's border tiles.
local Scanner = {}
Scanner.__index = Scanner

function Scanner.new(game: any, player: any): any
	return setmetatable({ game = game, player = player, nbuf = { 0, 0, 0, 0 }, attackable = {} :: { [number]: any } }, Scanner)
end

function Scanner._attackableBot(self: any, smallID: number): any?
	local cached = self.attackable[smallID]
	if cached == nil then
		local owner = self.game:playerBySmallID(smallID)
		cached = if owner:isPlayer() and owner:type() == PlayerType.Bot and not self.player:isFriendly(owner) then owner else false
		self.attackable[smallID] = cached
	end
	return if cached == false then nil else cached
end

-- nil once the bot turns out open (with closedOnly) or borders a bot
-- outside `within`.
function Scanner.scan(self: any, bot: any, closedOnly: boolean, within: Rail.OrderedSet?): Surroundings?
	local map = self.game:map()
	local us = self.player:smallID()
	local me = bot:smallID()
	local s: Surroundings = { bot = bot, bordersUs = false, open = false, bots = OrderedSet.new() }
	local gaveUp = false
	local nbuf = self.nbuf
	for _, tile in bot:borderTiles():values() do
		if gaveUp then
			break
		end
		if map:isOceanShore(tile) or map:isOnEdgeOfMap(tile) then
			s.open = true
			gaveUp = closedOnly
		else
			local n = map:neighbors4(tile, nbuf)
			for i = 1, n do
				local id = map:ownerID(nbuf[i])
				if id ~= me then
					if id == us then
						s.bordersUs = true
					else
						local other = if id == 0 then nil else self:_attackableBot(id)
						if other == nil then
							s.open = true
							gaveUp = closedOnly
						elseif within ~= nil and not within:has(other) then
							gaveUp = true
						else
							s.bots:add(other)
						end
						if gaveUp then
							break
						end
					end
				end
			end
		end
	end
	return if gaveUp then nil else s
end

local NO_BOTS = OrderedSet.new()

local function attackedBy(player: any): { [any]: boolean }
	local targets = {}
	for _, a in player:outgoingAttacks() do
		local t = a:target()
		if t:isPlayer() then
			targets[t] = true
		end
	end
	return targets
end

local function ownsStructures(player: any): boolean
	for _, u in player:units() do
		if GameTypes.isStructure[u:type()] then
			return true
		end
	end
	return false
end

function BotAnnexation.walledInBots(game: any, player: any, bots: { any }): { any }
	local scanner = Scanner.new(game, player)
	local attacking = attackedBy(player)
	local out = {}
	for _, bot in bots do
		if not attacking[bot] then
			local s = scanner:scan(bot, true, NO_BOTS)
			if s ~= nil and s.bordersUs then
				table.insert(out, bot)
			end
		end
	end
	return out
end

function BotAnnexation.planBotAttacks(game: any, player: any, bots: { any }): { any }
	local scanner = Scanner.new(game, player)
	local regionOrder: { any } = {}
	local region: { [any]: Surroundings } = {}
	local function setRegion(bot: any, s: Surroundings)
		if region[bot] == nil then
			table.insert(regionOrder, bot)
		end
		region[bot] = s
	end
	for _, bot in bots do
		setRegion(bot, scanner:scan(bot, false) :: Surroundings)
	end
	local front = {}
	for _, bot in bots do
		if region[bot].bordersUs then
			table.insert(front, bot)
		end
	end
	-- Open tribes behind the front are never kept; only closed ones matter.
	local behind: { [any]: boolean } = {}
	for _, bot in front do
		for _, other in region[bot].bots.list do
			if region[other] == nil and not behind[other] then
				behind[other] = true
				local s = scanner:scan(other, true)
				if s ~= nil then
					setRegion(other, s)
				end
			end
		end
	end
	local attacking = attackedBy(player)
	-- Largest first; each neighbour earns a share of the land it walls in.
	local candidates = {}
	for _, bot in regionOrder do
		local s = region[bot]
		if not s.open and s.bots:size() > 0 and not attacking[s.bot] and not ownsStructures(s.bot) then
			table.insert(candidates, s)
		end
	end
	candidates = Util.stableSort(candidates, function(a: Surroundings, b: Surroundings)
		return a.bot:numTilesOwned() > b.bot:numTilesOwned()
	end)
	local kept: { [any]: boolean } = {}
	local nextToKept: { [any]: boolean } = {}
	local walledIn: { [any]: number } = {}
	for _, s in candidates do
		if not nextToKept[s.bot] then
			kept[s.bot] = true
			local share = s.bot:numTilesOwned() / s.bots:size()
			for _, other in s.bots.list do
				nextToKept[other] = true
				walledIn[other] = (walledIn[other] or 0) + share
			end
		end
	end
	-- Most land per tribe troop, counting the land it walls in.
	local function value(bot: any): number
		return (bot:numTilesOwned() + (walledIn[bot] or 0)) / math.max(1, bot:troops())
	end
	local function byValue(a: any, b: any): boolean
		return value(a) > value(b)
	end
	local targets = {}
	for _, bot in bots do
		local s = region[bot]
		local walled = s.bordersUs and not s.open and s.bots:size() == 0
		if not kept[bot] and not walled then
			table.insert(targets, bot)
		end
	end
	targets = Util.stableSort(targets, byValue)
	-- Behind water or the map edge, kept tribes can be all we border.
	local anyFront = false
	for _, bot in targets do
		if region[bot].bordersUs then
			anyFront = true
			break
		end
	end
	if not anyFront then
		local keptFront = {}
		for _, bot in front do
			if kept[bot] then
				table.insert(keptFront, bot)
			end
		end
		for _, bot in Util.stableSort(keptFront, byValue) do
			table.insert(targets, bot)
		end
	end
	return targets
end

return BotAnnexation
