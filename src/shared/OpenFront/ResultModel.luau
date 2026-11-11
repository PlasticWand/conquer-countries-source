--!strict
-- Ported from RoWorld 2be8efb (src/client/UI/GameOver.luau), © lukechatton and contributors, AGPL-3.0. Modified for Conquest.
-- Winner lines from OpenFront v0.35.2 (WinModal.ts, en.json win_modal), © OpenFront and Contributors, AGPL-3.0.
--
-- What the result card says (Bruno, 2026-11-03: RoWorld's layout in our
-- style): the kicker, the verdict, the line under it, the four stat cards and
-- the Stars rows. Pure, so Lune tests it; OfHud lays it out.
--
--   * A team game: the winner is a team's name, not a player id. Everyone on
--     that team sees VICTORY and "Your team won with 80.0% of the land.";
--     the others see DEFEAT and "Red team won with ...".
--   * Free for all: VICTORY and "You conquered the world with 14.7% of the
--     land.", or DEFEAT and OpenFront's "{player} has won!" /
--     "Nation {nation} has won!".
--   * Killed before the end: ELIMINATED, "Your last territory fell at 4:12."
--   * The stat cards: your peak share of the land, your most troops, the
--     players and nations you wiped out (ConquestEvent) and the match length.
--   * Under the Stars: the next Arsenal weapon you don't own with your
--     balance towards it, and, without the 2x Stars pass, what this match
--     would have paid with it. They say what is true and prompt nothing.

local ResultModel = {}

export type Kind = "won" | "lost" | "died"

export type Tracker = {
	peakShare: number, -- 0..1 of the land
	maxTroops: number,
	eliminated: number,
}

export type Card = {
	kind: Kind,
	kicker: string,
	title: string,
	stamp: string,
	sub: string,
	team: string?, -- the winning team, in a team game
}

local function share(x: number): string
	return string.format("%.1f%%", 100 * math.max(0, x))
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local h, m, s = seconds // 3600, (seconds // 60) % 60, seconds % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end
ResultModel.clock = clock
ResultModel.share = share

function ResultModel.newTracker(): Tracker
	return { peakShare = 0, maxTroops = 0, eliminated = 0 }
end

-- Once per stats update, with your player view and the land total.
function ResultModel.track(t: Tracker, me: any?, landTotal: number)
	if me == nil or not me.alive then
		return
	end
	t.peakShare = math.max(t.peakShare, me.tiles / math.max(1, landTotal))
	t.maxTroops = math.max(t.maxTroops, me.troops)
end

-- With the events a delta brought you: counts your conquests.
function ResultModel.trackEvents(t: Tracker, me: any?, events: { any })
	if me == nil then
		return
	end
	for _, e in events do
		if e.type == "ConquestEvent" and e.conquerorId == me.id then
			t.eliminated += 1
		end
	end
end

-- The winner, as the state carries it: a player (by id) or a team's name.
function ResultModel.winner(state: any): (any?, string?)
	local w = state.winner
	if w == nil then
		return nil, nil
	end
	for _, p in state.players do
		if p.id == w then
			return p, nil
		end
	end
	return nil, tostring(w)
end

local function teamTiles(state: any, team: string): number
	local tiles = 0
	for _, p in state.players do
		if p.team ~= nil and tostring(p.team) == team then
			tiles += p.tiles
		end
	end
	return tiles
end

-- The card for a decided match ("won"/"lost"), or for your death ("died",
-- `seconds` = when you fell).
function ResultModel.card(state: any, died: boolean, seconds: number, landTotal: number): Card
	local me = state:me()
	landTotal = math.max(1, landTotal)
	if died then
		return {
			kind = "died",
			kicker = "YOUR NATION HAS FALLEN",
			title = "ELIMINATED",
			stamp = "KILLED IN ACTION",
			sub = `Your last territory fell at {clock(seconds)}.`,
		}
	end
	local player, team = ResultModel.winner(state)
	if team ~= nil then
		local mine = me ~= nil and me.team ~= nil and tostring(me.team) == team
		local land = share(teamTiles(state, team) / landTotal)
		return {
			kind = if mine then "won" else "lost",
			kicker = "MATCH COMPLETE",
			title = if mine then "VICTORY" else "DEFEAT",
			stamp = if mine then "MISSION ACCOMPLISHED" else "MISSION FAILED",
			sub = if mine then `Your team won with {land} of the land.` else `{team} team won with {land} of the land.`,
			team = team,
		}
	end
	local won = me ~= nil and player ~= nil and player.id == me.id
	if won then
		return {
			kind = "won",
			kicker = "MATCH COMPLETE",
			title = "VICTORY",
			stamp = "MISSION ACCOMPLISHED",
			sub = `You conquered the world with {share((me :: any).tiles / landTotal)} of the land.`,
		}
	end
	local name = if player then player.displayName or player.name else "Someone"
	local land = if player then ` with {share(player.tiles / landTotal)} of the land` else ""
	return {
		kind = "lost",
		kicker = "MATCH COMPLETE",
		title = "DEFEAT",
		stamp = "MISSION FAILED",
		sub = if player and player.type == "NATION" then `Nation {name} won{land}.` else `{name} won{land}.`,
	}
end

export type Goal = { name: string, have: number, need: number, ready: boolean }

-- The next Arsenal weapon you don't own (priced in stars), or nil.
function ResultModel.nextGoal(arsenal: { any }, profile: any?): Goal?
	if profile == nil then
		return nil
	end
	local owned: { [string]: boolean } = {}
	for _, id in profile.owned or {} do
		owned[id] = true
	end
	for _, w in arsenal do
		if w.stars and not owned[w.id] then
			return { name = string.upper(w.name), have = profile.stars, need = w.stars, ready = profile.stars >= w.stars }
		end
	end
	return nil
end

-- What this match would have paid with 2x Stars, or nil if you own it.
function ResultModel.doubled(gained: number, profile: any?): number?
	if profile == nil or profile.doubleStars or gained <= 0 then
		return nil
	end
	return gained * 2
end

return ResultModel
