--!strict
-- Roblox Analytics: the new-player funnel, the tutorial's funnel and a few
-- custom events. Roblox accepts these only from published servers, so Studio
-- skips them. Every call is pcall'd: analytics must never break gameplay.
--
-- New players only (the onboarding funnel counts each step once a player).
-- A player's matches run on several servers (a hub, their solo server, a
-- public match's server), so a step is decided from the saved profile's match
-- count (Store.matchesOf: matches played before this one), never from what one
-- server has seen (2026-11-10: the old per-server count logged "second match"
-- when the second match ended, and nothing called this module after the
-- pre-OpenFront engine went):
--   1 Joined           a profile with no match and no tutorial state loads
--   2 Match started    their first match starts
--   3 Spawned          their capital is placed in it
--   4 First attack     their first order on land, a neighbour or a coast
--   5 Played 3 min     alive 3 minutes of it
--   6 Played 10 min    alive 10 minutes of it
--   7 Match finished   it pays its stars (won, lost or left)
--   8 Second match     their second match starts
-- The tutorial's own funnel ("Tutorial", Shared/Tutorial.FUNNEL) is logged
-- per match from the client's reports, after RoWorld's.

local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local Analytics = {}

local ENABLED = not RunService:IsStudio()

Analytics.STEPS = {
	joined = { number = 1, name = "Joined" },
	started = { number = 2, name = "Match started" },
	spawned = { number = 3, name = "Spawned" },
	attack = { number = 4, name = "First attack" },
	played3 = { number = 5, name = "Played 3 min" },
	played10 = { number = 6, name = "Played 10 min" },
	finished = { number = 7, name = "Match finished" },
	second = { number = 8, name = "Second match started" },
}

type Session = { joinedAt: number, attacked: boolean }
local sessions: { [Player]: Session } = {}

local function step(player: Player, id: string)
	local s = Analytics.STEPS[id]
	if not ENABLED or s == nil then
		return
	end
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, s.number, s.name)
	end)
end

local function custom(player: Player, name: string, value: number)
	if not ENABLED then
		return
	end
	pcall(function()
		AnalyticsService:LogCustomEvent(player, name, value)
	end)
end

-- The profile loaded: a new player's funnel begins.
function Analytics.joined(player: Player, matches: number?, tutorial: string?)
	sessions[player] = { joinedAt = os.clock(), attacked = false }
	if matches == 0 and tutorial == nil then
		step(player, "joined")
	end
end

function Analytics.left(player: Player)
	local s = sessions[player]
	if s and not s.attacked then
		custom(player, "LeftBeforeFirstAttack", math.floor(os.clock() - s.joinedAt))
	end
	sessions[player] = nil
end

-- A match started with `before` matches already played.
function Analytics.matchStarted(player: Player, before: number)
	if before == 0 then
		step(player, "started")
	elseif before == 1 then
		step(player, "second")
	end
end

-- The rest are once per match; the caller remembers what it logged.
function Analytics.spawned(player: Player, before: number)
	if before == 0 then
		step(player, "spawned")
	end
end

function Analytics.attacked(player: Player, before: number, secondsIntoMatch: number)
	local s = sessions[player]
	if s then
		s.attacked = true
	end
	if before == 0 then
		custom(player, "SecondsToFirstAttack", math.floor(secondsIntoMatch))
		step(player, "attack")
	end
end

-- Alive `minutes` (3 or 10) in a match.
function Analytics.played(player: Player, before: number, minutes: number)
	if before == 0 then
		step(player, if minutes >= 10 then "played10" else "played3")
	end
end

function Analytics.matchFinished(player: Player, before: number, minutes: number, placement: number)
	if before == 0 then
		step(player, "finished")
	end
	custom(player, "MatchMinutes", math.floor(minutes * 10) / 10)
	custom(player, "Placement", placement)
end

-- The tutorial's funnel: step `n` (Shared/Tutorial.FUNNEL) in the match
-- `matchId` (its funnel session).
function Analytics.tutorialStep(player: Player, matchId: string, n: number, name: string)
	if not ENABLED then
		return
	end
	pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, "Tutorial", matchId, n, name)
	end)
end

-- Skip pressed on the tutorial's step `n` (its index in Shared/Tutorial.STEPS).
function Analytics.tutorialSkipped(player: Player, n: number)
	custom(player, "TutorialSkippedAtStep", n)
end

return Analytics
