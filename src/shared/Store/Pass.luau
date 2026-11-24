--!strict
-- The Campaign Pass (Bruno, 2026-11-23: "Campaign Pass", 199 R$ premium,
-- 30 days, 30 tiers, about 45 minutes a day to finish by day 25; on a menu
-- card and the result card). Pure: the season clock, XP for a match, the
-- daily and weekly missions, and the reward table. The player's progress
-- lives in their profile (Store/Profile: `pass`).

local Pass = {}

-- Seasons run back to back from EPOCH (2026-11-23 00:00 UTC), DAYS long.
Pass.EPOCH = 1795392000
Pass.DAYS = 30
Pass.TIERS = 30
Pass.XP_PER_TIER = 1000

-- A match: XP a minute alive (up to MAX_MINUTES), and for a win or a place
-- in the top tenth.
Pass.XP_PER_MINUTE = 20
Pass.MAX_MINUTES = 40
Pass.WIN_XP = 250
Pass.TOP_XP = 100

-- A tier's reward: any of stars, crates and items (cosmetics).
export type Reward = { stars: number?, crates: number?, items: { string }? }
export type Mission = { id: string, text: string, stat: string, goal: number, xp: number }
-- What a match adds to the missions' counters.
export type MatchStats = { minutes: number, won: boolean, top: boolean, public: boolean }

-- The season `now` falls in: its number (1 = the first), start and end.
-- Before EPOCH there is none.
function Pass.season(now: number): (number?, number, number)
	if now < Pass.EPOCH then
		return nil, Pass.EPOCH, Pass.EPOCH
	end
	local len = Pass.DAYS * 86400
	local n = (now - Pass.EPOCH) // len
	local starts = Pass.EPOCH + n * len
	return n + 1, starts, starts + len
end

-- The tier reached with `xp` (0 = none yet), and XP into the next tier.
function Pass.tier(xp: number): (number, number)
	local t = math.min(Pass.TIERS, xp // Pass.XP_PER_TIER)
	local into = if t >= Pass.TIERS then Pass.XP_PER_TIER else xp - t * Pass.XP_PER_TIER
	return t, into
end

function Pass.xpForMatch(stats: MatchStats): number
	local minutes = math.clamp(stats.minutes, 0, Pass.MAX_MINUTES)
	if minutes < 1 then
		return 0
	end
	local xp = math.floor(minutes * Pass.XP_PER_MINUTE)
	if stats.won then
		xp += Pass.WIN_XP
	end
	if stats.top then
		xp += Pass.TOP_XP
	end
	return xp
end

-- Missions. Each counts one stat over its day (UTC) or week (Monday-based,
-- UTC); three of each are dealt per period, the same for everyone.
local DAILY: { Mission } = {
	{ id = "d_play2", text = "Play 2 matches", stat = "matches", goal = 2, xp = 300 },
	{ id = "d_min20", text = "Play for 20 minutes", stat = "minutes", goal = 20, xp = 300 },
	{ id = "d_win1", text = "Win a match", stat = "wins", goal = 1, xp = 300 },
	{ id = "d_top1", text = "Finish in the top tenth", stat = "tops", goal = 1, xp = 300 },
	{ id = "d_public1", text = "Play a public match", stat = "publics", goal = 1, xp = 300 },
	{ id = "d_play3", text = "Play 3 matches", stat = "matches", goal = 3, xp = 300 },
}
local WEEKLY: { Mission } = {
	{ id = "w_play10", text = "Play 10 matches", stat = "matches", goal = 10, xp = 1000 },
	{ id = "w_win3", text = "Win 3 matches", stat = "wins", goal = 3, xp = 1000 },
	{ id = "w_min100", text = "Play for 100 minutes", stat = "minutes", goal = 100, xp = 1000 },
	{ id = "w_top5", text = "Finish in the top tenth 5 times", stat = "tops", goal = 5, xp = 1000 },
	{ id = "w_public5", text = "Play 5 public matches", stat = "publics", goal = 5, xp = 1000 },
}
Pass.DAILY_POOL = DAILY
Pass.WEEKLY_POOL = WEEKLY
Pass.PER_PERIOD = 3

-- `count` missions from `pool`, dealt by `seed` (a day or week number):
-- the same for everyone, no repeats within the period.
local function deal(pool: { Mission }, seed: number, count: number): { Mission }
	local order = table.clone(pool)
	local state = (seed * 2654435761) % 4294967296
	for i = #order, 2, -1 do
		state = (state * 1103515245 + 12345) % 2147483648
		local j = state % i + 1
		order[i], order[j] = order[j], order[i]
	end
	local out = {}
	for i = 1, math.min(count, #order) do
		table.insert(out, order[i])
	end
	return out
end

function Pass.day(now: number): number
	return now // 86400
end

-- Weeks start on Monday (1970-01-01 was a Thursday).
function Pass.week(now: number): number
	return (now // 86400 + 3) // 7
end

function Pass.dailyMissions(now: number): { Mission }
	return deal(DAILY, Pass.day(now), Pass.PER_PERIOD)
end

function Pass.weeklyMissions(now: number): { Mission }
	return deal(WEEKLY, Pass.week(now) + 7919, Pass.PER_PERIOD)
end

-- What a match adds to a mission stat.
function Pass.statOf(stats: MatchStats, stat: string): number
	if stat == "matches" then
		return if stats.minutes >= 1 then 1 else 0
	elseif stat == "minutes" then
		return math.floor(math.clamp(stats.minutes, 0, Pass.MAX_MINUTES))
	elseif stat == "wins" then
		return if stats.won then 1 else 0
	elseif stat == "tops" then
		return if stats.top then 1 else 0
	elseif stat == "publics" then
		return if stats.public and stats.minutes >= 1 then 1 else 0
	end
	return 0
end

-- Each season's name (Bruno, 2026-11-23: "Operation Iron Road").
Pass.NAMES = { "OPERATION IRON ROAD" }
function Pass.name(season: number): string
	return Pass.NAMES[season] or `SEASON {season}`
end

-- Season 1's exclusive items: skins (Store/Skins.CAMPAIGN), flags
-- (FlagList "campaign"), titles, match effects and the gold name
-- (Catalog.EXTRAS; shown in matches once the cosmetics are drawn).
Pass.ITEMS = table.freeze({
	flag1 = "o_campaign1_a",
	skin1 = "c1_trenches",
	flag2 = "o_campaign1_b",
	flag3 = "o_campaign1_c",
	skin2 = "c1_compass",
	recruit = "t_recruit",
	veteran = "t_veteran",
	warlord = "t_warlord",
	soldier = "t_soldier",
	flash = "x_conquest_gold",
	blast = "x_blast_ironroad",
	goldName = "n_gold",
})

-- The reward table (Bruno, 2026-11-23: "Take the proposal"): something
-- exciting every 3 to 5 premium tiers, stars sized to the weapon prices.
--   Free: 1,000 stars (1,500 from 15), crates at 5, 10, 15 (2), 20, 25 (2),
--         and 3 crates plus the SOLDIER title at 30.
--   Premium: titles at 1 (with 3,000 stars), 12, 22; flags at 5, 15, 25;
--         skins at 10, 30 (with the gold name); the conquest flash at 8;
--         the Iron Road blast at 18; 5 crates at 20; a crate at 4, 16, 24,
--         28; stars (3,000 / 4,000 / 5,000) on the rest.
local FREE: { Reward } = {}
local PREMIUM: { Reward } = {}
local I = Pass.ITEMS
local FREE_CRATES = { [5] = 1, [10] = 1, [15] = 2, [20] = 1, [25] = 2 }
local PREMIUM_AT: { [number]: Reward } = {
	[1] = { items = { I.recruit }, stars = 3000 },
	[5] = { items = { I.flag1 } },
	[8] = { items = { I.flash } },
	[10] = { items = { I.skin1 } },
	[12] = { items = { I.veteran } },
	[15] = { items = { I.flag2 } },
	[18] = { items = { I.blast } },
	[20] = { crates = 5 },
	[22] = { items = { I.warlord } },
	[25] = { items = { I.flag3 } },
	[30] = { items = { I.skin2, I.goldName } },
}
for t = 1, Pass.TIERS do
	if t == 30 then
		FREE[t] = { crates = 3, items = { I.soldier } }
	elseif FREE_CRATES[t] then
		FREE[t] = { crates = FREE_CRATES[t] }
	else
		FREE[t] = { stars = if t < 15 then 1000 else 1500 }
	end
	if PREMIUM_AT[t] then
		PREMIUM[t] = PREMIUM_AT[t]
	elseif t == 4 or t == 16 or t == 24 or t == 28 then
		PREMIUM[t] = { crates = 1 }
	else
		PREMIUM[t] = { stars = if t < 10 then 3000 elseif t < 20 then 4000 else 5000 }
	end
end
Pass.FREE = FREE
Pass.PREMIUM = PREMIUM

function Pass.reward(track: string, tier: number): Reward?
	if tier < 1 or tier > Pass.TIERS or tier ~= math.floor(tier) then
		return nil
	end
	if track == "free" then
		return FREE[tier]
	elseif track == "premium" then
		return PREMIUM[tier]
	end
	return nil
end

return Pass
