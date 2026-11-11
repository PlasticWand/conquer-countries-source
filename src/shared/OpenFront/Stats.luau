--!strict
--!native
-- Ported from OpenFront v0.35.2 (packages/engine/src/game/StatsImpl.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Phase A subset: only the counters the simulation reads back. The game
-- skips the conquest gold transfer for a human who never sent an attack.
-- The rest are no-ops that keep call sites identical to OpenFront's. Full
-- end-of-game stats come with the results screen (Phase E).

local Stats = {}
Stats.__index = Stats

export type Stats = typeof(setmetatable({} :: { attacksSent: { [any]: number } }, Stats))

function Stats.new(): Stats
	return setmetatable({ attacksSent = {} }, Stats)
end

function Stats.attack(self: Stats, player: any, _target: any, _troops: number)
	self.attacksSent[player] = (self.attacksSent[player] or 0) + 1
end

function Stats.attacksSentBy(self: Stats, player: any): number
	return self.attacksSent[player] or 0
end

function Stats.attackMaxIncoming(_self: Stats, _target: any, _troops: number) end
function Stats.attackCancel(_self: Stats, _player: any, _target: any, _troops: number) end
function Stats.goldWar(_self: Stats, _player: any, _captured: any, _gold: number) end
function Stats.recordKill(_self: Stats, _killer: any, _killed: any, _tick: number) end
function Stats.recordKilledBy(_self: Stats, _killed: any, _killerClientID: string?) end
function Stats.recordDeathPosition(_self: Stats, _player: any, _position: number) end
function Stats.recordTickSample(_self: Stats, _player: any, _tiles: number, _troops: number, _alliances: number) end
function Stats.betray(_self: Stats, _player: any) end
function Stats.allianceFormed(_self: Stats, ...: any) end
function Stats.allianceEnded(_self: Stats, ...: any) end
function Stats.boatSendTrade(_self: Stats, ...: any) end
function Stats.boatArriveTrade(_self: Stats, ...: any) end
function Stats.boatCapturedTrade(_self: Stats, ...: any) end
function Stats.boatDestroyTrade(_self: Stats, ...: any) end
function Stats.boatSendTroops(_self: Stats, ...: any) end
function Stats.boatArriveTroops(_self: Stats, ...: any) end
function Stats.boatDestroyTroops(_self: Stats, ...: any) end
function Stats.boatCapturedTroops(_self: Stats, ...: any) end
function Stats.boatLose(_self: Stats, ...: any) end
function Stats.bombLaunch(_self: Stats, ...: any) end
function Stats.bombLand(_self: Stats, ...: any) end
function Stats.bombIntercept(_self: Stats, ...: any) end
function Stats.goldWork(_self: Stats, ...: any) end
function Stats.goldDonationReceived(_self: Stats, ...: any) end
function Stats.unitBuild(_self: Stats, ...: any) end
function Stats.unitCapture(_self: Stats, ...: any) end
function Stats.unitUpgrade(_self: Stats, ...: any) end
function Stats.unitDestroy(_self: Stats, ...: any) end
function Stats.unitLose(_self: Stats, ...: any) end
function Stats.playerKilled(_self: Stats, ...: any) end
function Stats.recordFinalTiles(_self: Stats, ...: any) end
function Stats.recordSpawnTile(_self: Stats, ...: any) end
function Stats.trainSelfTrade(_self: Stats, ...: any) end
function Stats.trainExternalTrade(_self: Stats, ...: any) end

return Stats
