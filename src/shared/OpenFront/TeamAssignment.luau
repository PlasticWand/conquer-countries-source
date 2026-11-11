--!strict
-- Ported from OpenFront v0.35.2 (packages/engine-lib/src/game/TeamAssignment.ts), © OpenFront and Contributors, AGPL-3.0. Modified for Roblox/Luau by the Conquest team.
--
-- Team games: which team each human and nation joins, and the team list.
-- assignTeams returns an ORDERED list of { info, team } (the source's Map
-- insertion order), because GameImpl adds players in that order and so it
-- decides their smallIDs. Pinned slots (teamIndex), clans (clanTag) and
-- friends are ported structurally; Conquest's PlayerInfos don't carry them yet.

local GameTypes = require(script.Parent.GameTypes)
local PseudoRandom = require(script.Parent.PseudoRandom)
local Util = require(script.Parent.Util)

local TeamAssignment = {}

-- GameTypes.ts ColoredTeams.
TeamAssignment.ColoredTeams = table.freeze({
	Red = "Red",
	Blue = "Blue",
	Teal = "Teal",
	Purple = "Purple",
	Yellow = "Yellow",
	Orange = "Orange",
	Green = "Green",
	Bot = "Bot",
	Humans = "Humans",
	Nations = "Nations",
})
local ColoredTeams = TeamAssignment.ColoredTeams

export type Assignment = { info: any, team: string }

function TeamAssignment.getMaxTeamSize(numPlayers: number, numTeams: number): number
	return math.ceil(numPlayers / numTeams)
end

function TeamAssignment.assignTeams(players: { any }, teams: { string }, isDuosTriosQuads: boolean, maxTeamSize: number?): { Assignment }
	local maxSize = maxTeamSize or TeamAssignment.getMaxTeamSize(#players, #teams)
	local order: { any } = {}
	local teamOf: { [any]: string } = {}
	local function set(p: any, team: string)
		if teamOf[p] == nil then
			table.insert(order, p)
		end
		teamOf[p] = team
	end
	local teamPlayerCount: { [string]: number } = {}

	-- Matchmade pins first, unconditionally.
	local unpinned = {}
	for _, p in players do
		local pinned = if p.teamIndex ~= nil then teams[p.teamIndex + 1] else nil
		if pinned == nil then
			table.insert(unpinned, p)
		else
			set(p, pinned)
			teamPlayerCount[pinned] = (teamPlayerCount[pinned] or 0) + 1
		end
	end

	-- Clans go to one team together; overflow members are kicked.
	local clanOrder: { string } = {}
	local clanGroups: { [string]: { any } } = {}
	local nonClanPlayers = {}
	for _, p in unpinned do
		if p.clanTag then
			if clanGroups[p.clanTag] == nil then
				clanGroups[p.clanTag] = {}
				table.insert(clanOrder, p.clanTag)
			end
			table.insert(clanGroups[p.clanTag], p)
		else
			table.insert(nonClanPlayers, p)
		end
	end
	local clans = {}
	for _, tag in clanOrder do
		table.insert(clans, clanGroups[tag])
	end
	clans = Util.stableSort(clans, function(a: { any }, b: { any }): boolean
		return #a > #b
	end)
	for _, clan in clans do
		local team: string? = nil
		local teamSize = 0
		for _, t in teams do
			local count = teamPlayerCount[t] or 0
			if team ~= nil and teamSize <= count then
				continue
			end
			teamSize = count
			team = t
		end
		if team == nil then
			continue
		end
		for _, player in clan do
			if teamSize < maxSize then
				teamSize += 1
				set(player, team)
			else
				set(player, "kicked")
			end
		end
		teamPlayerCount[team] = teamSize
	end

	-- Friends: a soft preference for the team holding most of your friends.
	local present: { [string]: boolean } = {}
	for _, p in players do
		if p.clientID ~= nil then
			present[p.clientID] = true
		end
	end
	local friendGraph: { [string]: { string } } = {}
	local function addEdge(a: string, b: string)
		local s = friendGraph[a]
		if s == nil then
			s = {}
			friendGraph[a] = s
		end
		if not table.find(s, b) then
			table.insert(s, b)
		end
	end
	for _, p in players do
		if p.clientID == nil then
			continue
		end
		for _, friendID in p.friends or {} do
			if present[friendID] then
				addEdge(p.clientID, friendID)
				addEdge(friendID, p.clientID)
			end
		end
	end
	local teamByClientID: { [string]: string } = {}
	for _, p in order do
		local team = teamOf[p]
		if p.clientID ~= nil and team ~= "kicked" then
			teamByClientID[p.clientID] = team
		end
	end

	local function placePlayer(p: any)
		local myFriends = if p.clientID ~= nil then friendGraph[p.clientID] else nil
		local bestTeam: string? = nil
		local bestFriendCount = -1
		local bestSize = if isDuosTriosQuads then -1 else math.huge
		for _, t in teams do
			local size = teamPlayerCount[t] or 0
			if size >= maxSize then
				continue
			end
			local friendsOnTeam = 0
			if myFriends ~= nil then
				for _, friendID in myFriends do
					if teamByClientID[friendID] == t then
						friendsOnTeam += 1
					end
				end
			end
			if
				friendsOnTeam > bestFriendCount
				or (friendsOnTeam == bestFriendCount and (if isDuosTriosQuads then size > bestSize else size < bestSize))
			then
				bestFriendCount = friendsOnTeam
				bestSize = size
				bestTeam = t
			end
		end
		if bestTeam == nil then
			set(p, "kicked")
			return
		end
		local team = bestTeam :: string
		teamPlayerCount[team] = (teamPlayerCount[team] or 0) + 1
		set(p, team)
		if p.clientID ~= nil then
			teamByClientID[p.clientID] = team
		end
	end

	-- Humans (and any other non-nations) first, then the nations shuffled
	-- with a seed from the first nation's id.
	local nationPlayers = {}
	local otherPlayers = {}
	for _, p in nonClanPlayers do
		if p.playerType == GameTypes.PlayerType.Nation then
			table.insert(nationPlayers, p)
		else
			table.insert(otherPlayers, p)
		end
	end
	if #nationPlayers > 0 then
		local random = PseudoRandom.new(Util.simpleHash(nationPlayers[1].id))
		nationPlayers = random:shuffleArray(nationPlayers)
	end
	for _, p in otherPlayers do
		placePlayer(p)
	end
	for _, p in nationPlayers do
		placePlayer(p)
	end

	local result = {}
	for _, p in order do
		table.insert(result, { info = p, team = teamOf[p] })
	end
	return result
end

-- resolveTeamsList: the teams for a Team game's playerTeams setting.
function TeamAssignment.resolveTeamsList(config: any, totalPlayers: number): { string }
	if config == GameTypes.HumansVsNations then
		return { ColoredTeams.Humans, ColoredTeams.Nations }
	end
	local numTeams: number
	if type(config) ~= "number" then
		local divisor = if config == GameTypes.Duos then 2 elseif config == GameTypes.Trios then 3 elseif config == GameTypes.Quads then 4 else 0
		if divisor == 0 then
			error(`Unknown TeamCountConfig {config}`)
		end
		-- At least 2, even when attendance can't fill two teams.
		numTeams = math.max(2, math.ceil(totalPlayers / divisor))
	else
		numTeams = config
	end
	if numTeams < 2 then
		error(`Too few teams: {numTeams}`)
	end
	if numTeams < 8 then
		local teams = { ColoredTeams.Red, ColoredTeams.Blue }
		if numTeams >= 3 then
			table.insert(teams, ColoredTeams.Yellow)
		end
		if numTeams >= 4 then
			table.insert(teams, ColoredTeams.Green)
		end
		if numTeams >= 5 then
			table.insert(teams, ColoredTeams.Purple)
		end
		if numTeams >= 6 then
			table.insert(teams, ColoredTeams.Orange)
		end
		if numTeams >= 7 then
			table.insert(teams, ColoredTeams.Teal)
		end
		return teams
	end
	local teams = {}
	for i = 1, numTeams do
		table.insert(teams, `Team {i}`)
	end
	return teams
end

return TeamAssignment
