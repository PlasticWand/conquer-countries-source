--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/execution/WinCheckExecution.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Once a second: the largest player (FFA) or team wins on holding more than
-- the required share of fallout-free land, or when the lobby timer or the
-- 170-minute hard limit runs out. Ranked modes are not ported (no ranked).

local GameTypes = require(script.Parent.Parent.GameTypes)

local HARD_TIME_LIMIT_SECONDS = 170 * 60

local WinCheckExecution = {}
WinCheckExecution.__index = WinCheckExecution

export type WinCheckExecution = typeof(setmetatable({} :: { active: boolean, mg: any }, WinCheckExecution))

function WinCheckExecution.new(): WinCheckExecution
	return setmetatable({ active = true, mg = nil }, WinCheckExecution)
end

function WinCheckExecution.init(self: WinCheckExecution, mg: any, _ticks: number)
	self.mg = mg
end

function WinCheckExecution.tick(self: WinCheckExecution, ticks: number)
	if ticks % 10 ~= 0 then
		return
	end
	if self.mg:config():gameConfig().gameMode == GameTypes.GameMode.Team then
		self:checkWinnerTeam()
	else
		self:checkWinnerFFA()
	end
end

-- The first of the largest, in player order (JS's stable sort, then [0]).
function WinCheckExecution.checkWinnerFFA(self: WinCheckExecution)
	local max = nil
	for _, p in self.mg:players() do
		if max == nil or p:numTilesOwned() > max:numTilesOwned() then
			max = p
		end
	end
	if max == nil then
		return
	end
	if self:_hasWon(max:numTilesOwned()) then
		self.mg:setWinner(max)
		self.active = false
	end
end

function WinCheckExecution._hasWon(self: WinCheckExecution, tilesOwned: number): boolean
	local mg = self.mg
	local timeElapsed = mg:elapsedGameSeconds()
	local maxTimerValue = mg:config():gameConfig().maxTimerValue
	if maxTimerValue ~= nil and timeElapsed >= maxTimerValue * 60 then
		return true
	end
	if timeElapsed >= HARD_TIME_LIMIT_SECONDS then
		return true
	end
	local numTilesWithoutFallout = mg:numLandTiles() - mg:numTilesWithFallout()
	-- Cross-multiplied: exact integer maths.
	return tilesOwned * 100 > numTilesWithoutFallout * mg:config():percentageTilesOwnedToWin(timeElapsed)
end

function WinCheckExecution.checkWinnerTeam(self: WinCheckExecution)
	local order = {}
	local tiles: { [any]: number } = {}
	for _, player in self.mg:players() do
		local team = player:team()
		if team ~= nil then
			if tiles[team] == nil then
				tiles[team] = 0
				table.insert(order, team)
			end
			tiles[team] += player:numTilesOwned()
		end
	end
	local maxTeam = nil
	for _, team in order do
		if maxTeam == nil or tiles[team] > tiles[maxTeam] then
			maxTeam = team
		end
	end
	if maxTeam == nil then
		return
	end
	if self:_hasWon(tiles[maxTeam]) then
		if maxTeam == "Bot" then
			return
		end
		self.mg:setWinner(maxTeam)
		self.active = false
	end
end

function WinCheckExecution.isActive(self: WinCheckExecution): boolean
	return self.active
end

function WinCheckExecution.activeDuringSpawnPhase(_self: WinCheckExecution): boolean
	return false
end

return WinCheckExecution
