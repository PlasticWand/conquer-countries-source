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
--   7 Match finished   it ends for them with a result (won, lost or
--                      eliminated; leaving alive is LeftMatchAlive instead)
--   8 Second match     their second match starts
-- The tutorial's own funnel ("Tutorial", Shared/Tutorial.FUNNEL) is logged
-- per match from the client's reports, after RoWorld's.
--
-- Recurring funnels (Bruno, 2026-11-11: "make sure we have the appropriate
-- funnels"), one session each:
--   "Match"  every player's every match (session: the match id): Match
--            started, Spawned, First attack, Played 3 min, Played 10 min,
--            Match finished. Returning players' matches, not only the first.
--   "Store"  a shop visit (session: one per window opened): Opened (field 1:
--            the window), Prompted (field 1: the product), Purchased (a
--            developer product or the 2x Stars pass granted in that visit).
-- Custom events: SecondsToFirstAttack (first match), LeftBeforeFirstAttack
-- (seconds into a match a player left without ever attacking in it; only for
-- match members, never a hub's teleports), MatchMinutes, Placement,
-- TutorialSkippedAtStep, TutorialPassedOver (a step passed over, not done),
-- LeftMatchAlive (minutes alive in a match left before its result).
-- Server health (2026-11-15 review: Creator Hub's server heartbeat P10 read
-- about 5), once a minute per running match, logged against one of its
-- players: ServerFps (this server's Heartbeat rate over the minute),
-- StepMeanMs and StepWorstMs (that match's 10 Hz tick cost). Fields: map,
-- kind (public, solo or hub-solo) and the matches running on the server.

local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Analytics = {}

local ENABLED = not RunService:IsStudio()

-- Studio sends nothing; instead the last 40 events it would send are kept in
-- ServerStorage's "AnalyticsRecent" attribute (one per line) for MCP checks.
local recent: { string } = {}
local function trace(text: string)
	if ENABLED then
		return
	end
	table.insert(recent, text)
	if #recent > 40 then
		table.remove(recent, 1)
	end
	pcall(function()
		game:GetService("ServerStorage"):SetAttribute("AnalyticsRecent", table.concat(recent, "\n"))
	end)
end

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

Analytics.MATCH_FUNNEL = { "Match started", "Spawned", "First attack", "Played 3 min", "Played 10 min", "Match finished" }
Analytics.STORE_FUNNEL = { "Opened", "Prompted", "Purchased" }
-- The windows and in-match spots a Store visit can start from.
Analytics.STORE_PLACES = { locker = true, arsenal = true, flags = true, general = true, starter = true }

-- `matchStartedAt`: the os.clock() its current match started; nil outside one.
type Session = { joinedAt: number, attacked: boolean, matchStartedAt: number? }
local sessions: { [Player]: Session } = {}
local shopVisits: { [Player]: string } = {}

local function funnel(player: Player, name: string, session: string, n: number, stepName: string, field: string?)
	trace(`{name} {n} {stepName}{if field then ` ({field})` else ""} [{string.sub(session, 1, 8)}]`)
	if not ENABLED then
		return
	end
	pcall(function()
		if field then
			AnalyticsService:LogFunnelStepEvent(player, name, session, n, stepName, {
				[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = field,
			})
		else
			AnalyticsService:LogFunnelStepEvent(player, name, session, n, stepName)
		end
	end)
end

local function matchStep(player: Player, matchId: string, n: number)
	funnel(player, "Match", matchId, n, Analytics.MATCH_FUNNEL[n])
end

local function step(player: Player, id: string)
	local s = Analytics.STEPS[id]
	if s then
		trace(`onboarding {s.number} {s.name}`)
	end
	if not ENABLED or s == nil then
		return
	end
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, s.number, s.name)
	end)
end

local function custom(player: Player, name: string, value: number)
	trace(`custom {name} = {value}`)
	if not ENABLED then
		return
	end
	pcall(function()
		AnalyticsService:LogCustomEvent(player, name, value)
	end)
end

-- One minute of server health for a running match (see the header).
function Analytics.serverHealth(player: Player, map: string, kind: string, matchesHere: number, fps: number, stepMeanMs: number, stepWorstMs: number)
	local here = if matchesHere >= 4 then "4+" else tostring(matchesHere)
	trace(`health {map} {kind} x{here}: {math.floor(fps)} fps, step {math.floor(stepMeanMs * 10) / 10} / {math.floor(stepWorstMs)} ms`)
	if not ENABLED then
		return
	end
	local fields = {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = map,
		[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = kind,
		[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = here,
	}
	pcall(function()
		AnalyticsService:LogCustomEvent(player, "ServerFps", math.floor(fps * 10) / 10, fields)
		AnalyticsService:LogCustomEvent(player, "StepMeanMs", math.floor(stepMeanMs * 100) / 100, fields)
		AnalyticsService:LogCustomEvent(player, "StepWorstMs", math.floor(stepWorstMs * 10) / 10, fields)
	end)
end

-- The profile loaded: a new player's funnel begins.
function Analytics.joined(player: Player, matches: number?, tutorial: string?)
	sessions[player] = { joinedAt = os.clock(), attacked = false }
	if matches == 0 and tutorial == nil then
		step(player, "joined")
	end
end

-- Left this server. Only a match member who never attacked in their match
-- counts (a hub's players leave it for their match's server all the time).
function Analytics.left(player: Player)
	local s = sessions[player]
	if s and s.matchStartedAt and not s.attacked then
		custom(player, "LeftBeforeFirstAttack", math.floor(os.clock() - s.matchStartedAt))
	end
	sessions[player] = nil
	shopVisits[player] = nil
end

-- A match `matchId` started with `before` matches already played.
function Analytics.matchStarted(player: Player, before: number, matchId: string)
	local s = sessions[player]
	if s == nil then
		s = { joinedAt = os.clock(), attacked = false }
		sessions[player] = s
	end
	s.matchStartedAt = os.clock()
	s.attacked = false
	if before == 0 then
		step(player, "started")
	elseif before == 1 then
		step(player, "second")
	end
	matchStep(player, matchId, 1)
end

-- The rest are once per match; the caller remembers what it logged.
function Analytics.spawned(player: Player, before: number, matchId: string)
	if before == 0 then
		step(player, "spawned")
	end
	matchStep(player, matchId, 2)
end

function Analytics.attacked(player: Player, before: number, secondsIntoMatch: number, matchId: string)
	local s = sessions[player]
	if s then
		s.attacked = true
	end
	if before == 0 then
		custom(player, "SecondsToFirstAttack", math.floor(secondsIntoMatch))
		step(player, "attack")
	end
	matchStep(player, matchId, 3)
end

-- Alive `minutes` (3 or 10) in a match.
function Analytics.played(player: Player, before: number, minutes: number, matchId: string)
	if before == 0 then
		step(player, if minutes >= 10 then "played10" else "played3")
	end
	matchStep(player, matchId, if minutes >= 10 then 5 else 4)
end

-- Their stars were paid: the match ended for them. `sawResult`: it had a
-- winner, or they were eliminated, so they saw a result card ("Match
-- finished"). Otherwise they left while still in it: LeftMatchAlive (value:
-- minutes alive) and no "Match finished" (2026-11-12: leaving counted as
-- finishing, so the funnels overstated it).
function Analytics.matchFinished(player: Player, before: number, minutes: number, placement: number, matchId: string, sawResult: boolean)
	if sawResult then
		if before == 0 then
			step(player, "finished")
		end
		matchStep(player, matchId, 6)
	else
		custom(player, "LeftMatchAlive", math.floor(minutes * 10) / 10)
	end
	custom(player, "MatchMinutes", math.floor(minutes * 10) / 10)
	custom(player, "Placement", placement)
	local s = sessions[player]
	if s then
		s.matchStartedAt = nil
	end
end

-- The Store funnel. A visit starts when a shop window opens; `where` is one
-- of STORE_PLACES (unknown ones are dropped).
function Analytics.shopOpened(player: Player, where: string)
	if not Analytics.STORE_PLACES[where] then
		return
	end
	local visit = HttpService:GenerateGUID(false)
	shopVisits[player] = visit
	funnel(player, "Store", visit, 1, "Opened", where)
end

-- A Robux purchase prompt for product `key`, in the current visit.
function Analytics.shopPrompted(player: Player, key: string)
	local visit = shopVisits[player]
	if visit then
		funnel(player, "Store", visit, 2, "Prompted", key)
	end
end

-- Product `key` granted (receipt processed or pass bought) during a visit.
function Analytics.shopPurchased(player: Player, key: string)
	local visit = shopVisits[player]
	if visit then
		funnel(player, "Store", visit, 3, "Purchased", key)
	end
end

-- The tutorial's funnel: step `n` (Shared/Tutorial.FUNNEL) in the match
-- `matchId` (its funnel session). `passed`: passed over, not done (stuck, or
-- nobody to attack), also counted as TutorialPassedOver (value: the step).
function Analytics.tutorialStep(player: Player, matchId: string, n: number, name: string, passed: boolean?)
	funnel(player, "Tutorial", matchId, n, name)
	if passed then
		custom(player, "TutorialPassedOver", n)
	end
end

-- The launch gift claimed (value: the items it unlocked).
function Analytics.giftClaimed(player: Player, items: number)
	custom(player, "LaunchGiftClaimed", items)
end

-- The free crate was opened (once per player; Profile.openFreeCrate).
function Analytics.freeCrateOpened(player: Player)
	custom(player, "FreeCrateOpened", 1)
end

-- Invite rewards collected: how many invited friends were paid for.
function Analytics.referralPaid(player: Player, friends: number)
	custom(player, "ReferralPaid", friends)
end

-- A rewarded video ad for a free crate: 1 when it played to the end
-- (the crate is granted), 0 when it was cut short or failed.
function Analytics.adWatched(player: Player, completed: boolean)
	custom(player, "RewardedAdCrate", if completed then 1 else 0)
end

-- Something bought with stars (Bruno, 2026-11-16: "Measure star buys"): an
-- Arsenal unlock (`what` its id) or a crate ("crate"); value: the stars
-- spent. Field 1: what; field 2: where the visit opened ("" outside one).
function Analytics.boughtWithStars(player: Player, what: string, stars: number)
	trace(`custom BoughtWithStars = {stars} ({what})`)
	if not ENABLED then
		return
	end
	local fields = {
		[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = what,
	}
	pcall(function()
		AnalyticsService:LogCustomEvent(player, "BoughtWithStars", stars, fields)
	end)
end

-- Skip pressed on the tutorial's step `n` (its index in Shared/Tutorial.STEPS).
function Analytics.tutorialSkipped(player: Player, n: number)
	custom(player, "TutorialSkippedAtStep", n)
end

return Analytics
