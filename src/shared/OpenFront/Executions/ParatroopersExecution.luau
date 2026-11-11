--!strict
--!native
-- Conquest's own Arsenal item (not OpenFront or RoWorld;
-- docs/design/ARSENAL_V2.md, Paratroopers, Bruno 2026-11-09).
--
-- A plane takes off from our nearest City or Airfield in reach
-- (Player.paraSpawn) carrying troops, and flies a straight air path to the
-- target tile at SPEED tiles a tick: a public unit with troops, targetTile
-- and sourceTile. Enemy SAMs whose range covers it fire an ordinary SAM
-- missile at the point where they meet (SAMMissileExecution destroys it,
-- with its troops). On landing it acts like a boat: home if the tile is
-- now ours, water or a friend's; otherwise it takes the tile and attacks
-- its owner from there.

local AttackExecution = require(script.Parent.AttackExecution)
local Config = require(script.Parent.Parent.Config)
local GameTypes = require(script.Parent.Parent.GameTypes)
local PathFinding = require(script.Parent.Parent.Pathfinding.PathFinding)

local UnitType = GameTypes.UnitType

local ParatroopersExecution = {}
ParatroopersExecution.__index = ParatroopersExecution

-- Straight-line tiles from the City or Airfield to the target.
ParatroopersExecution.REACH = 120
-- Path tiles a tick.
ParatroopersExecution.SPEED = 4
-- At most this share of the troop cap a drop.
ParatroopersExecution.MAX_SHARE = 0.25
-- Ticks from one launch to the next (Rapid Reload halves it).
ParatroopersExecution.COOLDOWN = 60 * 10
-- Ticks a landing zone holds out though enemy land surrounds it
-- (PlayerExecution._heldByDrop); OpenFront would hand an enclosed pocket to
-- the enemy at its next cluster check.
ParatroopersExecution.HOLD = 30 * 10

export type ParatroopersExecution = typeof(setmetatable(
	{} :: {
		active: boolean,
		mg: any,
		player: any,
		dst: number,
		troops: number?,
		plane: any,
		path: { number },
		index: number,
	},
	ParatroopersExecution
))

function ParatroopersExecution.new(player: any, dst: number, troops: number?): ParatroopersExecution
	return setmetatable({ active = true, mg = nil, player = player, dst = dst, troops = troops, plane = nil, path = {}, index = 1 }, ParatroopersExecution)
end

function ParatroopersExecution.init(self: ParatroopersExecution, mg: any, _ticks: number)
	self.mg = mg
end

-- The troops a drop would carry: the asked amount, at most MAX_SHARE of the
-- troop cap and what the player has.
function ParatroopersExecution.troopsFor(mg: any, player: any, asked: number?): number
	local cap = mg:config():maxTroops(player) * ParatroopersExecution.MAX_SHARE
	return math.floor(math.max(0, math.min(asked or 0, cap, player:troops())))
end

function ParatroopersExecution._launch(self: ParatroopersExecution, ticks: number)
	local mg, player = self.mg, self.player
	local src = player:canBuild(UnitType.Paratroopers, self.dst)
	if src == false then
		self.active = false
		return
	end
	local troops = ParatroopersExecution.troopsFor(mg, player, self.troops)
	if troops <= 0 then
		self.active = false
		return
	end
	player.paraReadyAt = ticks + Config.rapidReload(player, ParatroopersExecution.COOLDOWN)
	self.path = PathFinding.AirPathFinder.new(mg):findPath(src :: number, self.dst)
	self.index = 1
	-- waitTicks gives it the bombs' state, where SAMs mark what they're
	-- chasing (Unit.setTargetedBySAM).
	local plane = player:buildUnit(UnitType.Paratroopers, src :: number, { troops = troops, targetTile = self.dst, waitTicks = 0 })
	-- Where it took off, for the client's flight line (Replication).
	plane._sourceTile = src
	self.plane = plane
	local target = mg:owner(self.dst)
	if target:isPlayer() then
		mg:displayIncomingUnit(plane:id(), "events_display.paratroopers_inbound", "PARATROOPERS_INBOUND", target:id())
	end
end

-- The nearest enemy SAM covering the plane fires at the path tile where its
-- missile (defaultSamMissileSpeed Manhattan steps a tick) first catches the
-- plane, if that comes before the landing.
function ParatroopersExecution._checkSams(self: ParatroopersExecution)
	local plane = self.plane
	if plane:targetedBySAM() then
		return
	end
	local mg, player = self.mg, self.player
	local config = mg:config()
	local ticks = mg:ticks()
	local best: any, bestD = nil, math.huge
	for _, entry in mg:nearbyUnits(plane:tile(), config:maxSamRange(), UnitType.SAMLauncher) do
		local sam = entry.unit
		local owner = sam:owner()
		if sam:isActive() and not sam:isInCooldown() and not sam:isDark() and owner ~= player and not player:isFriendly(owner) then
			local r = config:dynamicSamRange(sam, ticks)
			local d = entry.distSquared
			if d <= r * r and (d < bestD or (d == bestD and sam:id() < best:id())) then
				best, bestD = sam, d
			end
		end
	end
	if best == nil then
		return
	end
	local samTile = best:tile()
	local sx, sy = mg:x(samTile), mg:y(samTile)
	local missileSpeed = config:defaultSamMissileSpeed()
	local path, last = self.path, #self.path
	local t = 1
	while true do
		local i = math.min(self.index + ParatroopersExecution.SPEED * t, last)
		local at = path[i]
		if math.abs(mg:x(at) - sx) + math.abs(mg:y(at) - sy) <= missileSpeed * t then
			best:launch()
			plane:setTargetedBySAM(true)
			mg:addExecution((require(script.Parent.SAMMissileExecution) :: any).new(samTile, best:owner(), best, plane, at))
			return
		end
		if i == last then
			return
		end
		t += 1
	end
end

function ParatroopersExecution._land(self: ParatroopersExecution)
	local mg, player, plane = self.mg, self.player, self.plane
	local dst = self.dst
	local troops = plane:troops()
	local owner = mg:owner(dst)
	plane:setReachedTarget()
	plane:delete(false)
	self.active = false
	if not player:isAlive() then
		return
	end
	if mg:isWater(dst) or owner == player or (owner:isPlayer() and player:isFriendly(owner)) then
		player:addTroops(troops)
		mg:displayMessage("events_display.paratroopers_returned", "BOAT_RETURNED", player:id(), nil, { troops = troops, tile = dst })
		return
	end
	player:conquer(dst)
	player.paraZones = player.paraZones or {}
	table.insert(player.paraZones, { tile = dst, untilTick = mg:ticks() + ParatroopersExecution.HOLD })
	mg:addExecution(AttackExecution.new(troops, player, owner:id(), dst, false))
end

function ParatroopersExecution.tick(self: ParatroopersExecution, ticks: number)
	if self.plane == nil then
		self:_launch(ticks)
		return
	end
	local plane = self.plane
	if not plane:isActive() then
		-- Shot down (or gone with its owner): its troops are lost.
		self.active = false
		local by = plane:destroyer()
		if by ~= nil then
			self.mg:displayMessage("events_display.paratroopers_shot_down", "UNIT_DESTROYED", self.player:id(), nil, {
				name = by:displayName(),
			})
		end
		return
	end
	local last = #self.path
	for _ = 1, ParatroopersExecution.SPEED do
		if self.index >= last then
			break
		end
		self.index += 1
		plane:move(self.path[self.index])
	end
	if self.index >= last then
		self:_land()
		return
	end
	self:_checkSams()
end

function ParatroopersExecution.isActive(self: ParatroopersExecution): boolean
	return self.active
end

function ParatroopersExecution.activeDuringSpawnPhase(_self: ParatroopersExecution): boolean
	return false
end

return ParatroopersExecution
